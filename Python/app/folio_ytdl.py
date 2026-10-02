"""
Folio <-> yt-dlp bridge.

Runs inside the Python interpreter embedded in the app. Native code hands us a
few C function pointers (as integers) through `setup()`:

  js_eval(const char *source) -> char *   evaluates JavaScript with JavaScriptCore
  free(void *)                             frees strings returned by js_eval
  progress(double fraction, const char *)  reports progress to the UI
  cancelled() -> int                       non-zero when the user tapped Cancel

iOS apps cannot launch Deno/Node, so a small JS-challenge provider plugs
JavaScriptCore into yt-dlp's EJS solver. That is what makes YouTube work.
"""

import ctypes
import glob
import json
import os
import re
import shutil
import sys
import traceback
import urllib.request
import zipfile

_js_eval = None
_js_free = None
_progress = None
_cancelled = None
_cache_dir = None
_update_dir = None
_provider_registered = False

AUDIO_FORMAT = (
    'bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio[ext=mp3]/'
    'bestaudio[ext=aac]/bestaudio[ext=flac]/bestaudio[ext=wav]/'
    'best[acodec^=mp4a][ext=mp4]/bestaudio/best'
)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

def setup(js_addr, free_addr, progress_addr, cancel_addr, cache_dir, update_dir):
    global _js_eval, _js_free, _progress, _cancelled, _cache_dir, _update_dir
    _js_eval = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_char_p)(js_addr)
    _js_free = ctypes.CFUNCTYPE(None, ctypes.c_void_p)(free_addr)
    _progress = ctypes.CFUNCTYPE(None, ctypes.c_double, ctypes.c_char_p)(progress_addr)
    _cancelled = ctypes.CFUNCTYPE(ctypes.c_int)(cancel_addr)
    _cache_dir = cache_dir
    _update_dir = update_dir
    os.makedirs(cache_dir, exist_ok=True)
    os.makedirs(update_dir, exist_ok=True)
    os.environ.setdefault('XDG_CACHE_HOME', cache_dir)

    # Wheels downloaded by "Update yt-dlp" take priority over the bundled copy.
    # Pure-Python wheels are zip files, which Python can import directly.
    for whl in sorted(glob.glob(os.path.join(update_dir, '*.whl'))):
        if whl not in sys.path:
            sys.path.insert(0, whl)
    return json.dumps({'ok': True, 'version': version()})


def version():
    try:
        from yt_dlp.version import __version__
        return __version__
    except Exception:
        return 'unknown'


def _report(fraction, message):
    if _progress is not None:
        try:
            _progress(float(fraction), (message or '').encode('utf-8', 'replace'))
        except Exception:
            pass


# ---------------------------------------------------------------------------
# JavaScriptCore challenge provider
# ---------------------------------------------------------------------------

# iOS 15.0's JavaScriptCore predates a few ES2022 helpers the solver uses.
_POLYFILLS = r'''
(function () {
  function def(o, k, v) { if (!o[k]) { Object.defineProperty(o, k, { value: v, writable: true, configurable: true }); } }
  def(Object, 'hasOwn', function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); });
  function at(i) { i = Math.trunc(i) || 0; if (i < 0) { i += this.length; } return (i < 0 || i >= this.length) ? undefined : this[i]; }
  def(Array.prototype, 'at', at);
  def(String.prototype, 'at', function (i) { var v = at.call(this, i); return v === undefined ? undefined : String(v); });
  def(Array.prototype, 'findLast', function (f, t) { for (var i = this.length - 1; i >= 0; i--) { if (f.call(t, this[i], i, this)) { return this[i]; } } return undefined; });
  def(Array.prototype, 'findLastIndex', function (f, t) { for (var i = this.length - 1; i >= 0; i--) { if (f.call(t, this[i], i, this)) { return i; } } return -1; });
  if (typeof globalThis.structuredClone !== 'function') { globalThis.structuredClone = function (v) { return v === undefined ? v : JSON.parse(JSON.stringify(v)); }; }
})();
'''


def _eval_js(source):
    from yt_dlp.extractor.youtube.jsc.provider import JsChallengeProviderError

    ptr = _js_eval((_POLYFILLS + source).encode('utf-8'))
    if not ptr:
        raise JsChallengeProviderError('JavaScriptCore returned no result')
    try:
        out = ctypes.string_at(ptr).decode('utf-8', 'replace')
    finally:
        _js_free(ptr)
    if out.startswith('\x01ERR:'):
        raise JsChallengeProviderError('JavaScriptCore error: ' + out[5:])
    return out


def _register_provider():
    global _provider_registered
    if _provider_registered:
        return
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    from yt_dlp.extractor.youtube.jsc.provider import register_preference, register_provider

    class FolioJavaScriptCoreJCP(EJSBaseJCP):
        PROVIDER_NAME = 'folio-javascriptcore'
        PROVIDER_VERSION = '1.0.0'
        JS_RUNTIME_NAME = 'JavaScriptCore'
        BUG_REPORT_LOCATION = 'the Folio app'

        def is_available(self):
            return _js_eval is not None and self._available

        def _run_js_runtime(self, stdin, /):
            _report(-2, 'Solving YouTube challenge…')
            return _eval_js(stdin)

    register_provider(FolioJavaScriptCoreJCP)

    def _preference(provider, requests):
        return 2000

    register_preference(FolioJavaScriptCoreJCP)(_preference)
    _provider_registered = True


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

class _Logger:
    def __init__(self):
        self.last_error = None

    def debug(self, msg):
        if msg.startswith('[download] Destination'):
            return
        if msg.startswith('[youtube]') or msg.startswith('[info]'):
            _report(-2, re.sub(r'^\[[^\]]+\]\s*', '', msg)[:120])

    def info(self, msg):
        self.debug(msg)

    def warning(self, msg):
        pass

    def error(self, msg):
        self.last_error = re.sub(r'^ERROR:\s*', '', str(msg))


def _fmt_bytes(n):
    if not n:
        return ''
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return f'{n:.0f} {unit}' if unit in ('B', 'KB') else f'{n:.1f} {unit}'
        n /= 1024


def download(url, out_dir):
    """Downloads the audio of `url` (a video, track or playlist) into out_dir.
    Returns JSON: {"ok": true, "items": [...]} or {"ok": false, "error": "..."}"""
    logger = _Logger()
    items = []
    try:
        import yt_dlp
        from yt_dlp.utils import DownloadCancelled

        _register_provider()
        os.makedirs(out_dir, exist_ok=True)

        def progress_hook(d):
            if _cancelled is not None and _cancelled():
                raise DownloadCancelled('Cancelled')
            info = d.get('info_dict') or {}
            prefix = ''
            if info.get('playlist_index') and info.get('n_entries'):
                prefix = f"{info['playlist_index']}/{info['n_entries']} · "
            status = d.get('status')
            if status == 'downloading':
                total = d.get('total_bytes') or d.get('total_bytes_estimate') or 0
                done = d.get('downloaded_bytes') or 0
                frac = min(done / total, 1.0) if total else -1.0
                parts = [p for p in (_fmt_bytes(done) + (' of ' + _fmt_bytes(total) if total else ''),
                                     (_fmt_bytes(d.get('speed')) + '/s') if d.get('speed') else '') if p]
                _report(frac, prefix + ' · '.join(parts))
            elif status == 'finished':
                path = d.get('filename') or info.get('filepath')
                if path and not any(i['path'] == path for i in items):
                    items.append({
                        'path': path,
                        'title': info.get('track') or info.get('title') or os.path.basename(path),
                        'artist': info.get('artist') or info.get('creator') or info.get('uploader') or info.get('channel'),
                        'album': info.get('album'),
                        'thumbnail': info.get('thumbnail'),
                        'duration': info.get('duration'),
                    })
                _report(1.0, prefix + 'Processing…')

        opts = {
            'format': AUDIO_FORMAT,
            'outtmpl': os.path.join(out_dir, '%(title).120B [%(id)s].%(ext)s'),
            'windowsfilenames': True,
            'noplaylist': True,
            'quiet': True,
            'noprogress': True,
            'logger': logger,
            'progress_hooks': [progress_hook],
            'cachedir': os.path.join(_cache_dir or out_dir, 'yt-dlp'),
            'js_runtimes': {},          # no external runtimes on iOS – our provider is used instead
            'socket_timeout': 30,
            'retries': 5,
            'fragment_retries': 5,
            'continuedl': True,
            'overwrites': False,
            'fixup': 'never',           # fixups need ffmpeg, which iOS can't run
            'ignoreerrors': 'only_download',
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.extract_info(url, download=True)

        if not items:
            return json.dumps({'ok': False, 'error': logger.last_error or 'Nothing was downloaded.'})
        return json.dumps({'ok': True, 'items': items, 'warning': logger.last_error})
    except Exception as e:  # noqa: BLE001 – everything is reported to the UI
        name = type(e).__name__
        if name == 'DownloadCancelled':
            return json.dumps({'ok': False, 'cancelled': True, 'error': 'Cancelled', 'items': items})
        msg = logger.last_error or str(e) or name
        traceback.print_exc()
        return json.dumps({'ok': False, 'error': msg, 'items': items})


# ---------------------------------------------------------------------------
# Updating yt-dlp without rebuilding the app
# ---------------------------------------------------------------------------

def _pypi_wheel(package, version=None):
    url = f'https://pypi.org/pypi/{package}/json' if not version else f'https://pypi.org/pypi/{package}/{version}/json'
    import ssl
    ctx = None
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except Exception:
        pass
    with urllib.request.urlopen(url, timeout=30, context=ctx) as r:
        data = json.load(r)
    for f in data['urls']:
        if f['packagetype'] == 'bdist_wheel' and f['filename'].endswith('py3-none-any.whl'):
            return data['info']['version'], f['url'], f['filename'], ctx
    raise RuntimeError(f'No wheel found for {package}')


def _vt(v):
    return tuple(int(x) for x in re.findall(r'\d+', v or '0'))


def _fetch(url, dest, ctx):
    with urllib.request.urlopen(url, timeout=60, context=ctx) as r, open(dest, 'wb') as f:
        shutil.copyfileobj(r, f)


def update():
    """Downloads the newest yt-dlp (and the matching JS solver package) from PyPI.
    Takes effect the next time Folio starts."""
    try:
        _report(-2, 'Checking PyPI…')
        latest, url, filename, ctx = _pypi_wheel('yt-dlp')
        current = version()
        installed = [os.path.basename(p) for p in glob.glob(os.path.join(_update_dir, 'yt_dlp-*.whl'))]
        if _vt(latest) <= _vt(current) or filename in installed:
            return json.dumps({'ok': True, 'updated': False, 'version': latest})

        staging = os.path.join(_update_dir, 'staging')
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging)
        _report(-2, f'Downloading yt-dlp {latest}…')
        ytdlp_path = os.path.join(staging, filename)
        _fetch(url, ytdlp_path, ctx)

        # The JS solver package version must match the one yt-dlp expects
        with zipfile.ZipFile(ytdlp_path) as z:
            info = z.read('yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py').decode()
        m = re.search(r"VERSION\s*=\s*'([^']+)'", info)
        if m:
            _report(-2, f'Downloading JS solver {m.group(1)}…')
            _, ejs_url, ejs_name, _ = _pypi_wheel('yt-dlp-ejs', m.group(1))
            _fetch(ejs_url, os.path.join(staging, ejs_name), ctx)

        for old in glob.glob(os.path.join(_update_dir, '*.whl')):
            os.remove(old)
        for new in glob.glob(os.path.join(staging, '*.whl')):
            shutil.move(new, os.path.join(_update_dir, os.path.basename(new)))
        shutil.rmtree(staging, ignore_errors=True)
        return json.dumps({'ok': True, 'updated': True, 'version': latest})
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        return json.dumps({'ok': False, 'error': str(e) or type(e).__name__})


def reset_updates():
    """Removes downloaded updates and goes back to the yt-dlp bundled with the app."""
    for old in glob.glob(os.path.join(_update_dir or '', '*.whl')):
        os.remove(old)
    return json.dumps({'ok': True})
