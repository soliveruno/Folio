import Foundation

/// JavaScript injected into every EPUB chapter. It handles layout (pages or scroll),
/// position reporting, highlights, taps and chapter-to-chapter swipes.
/// Everything is event driven (no timers polling), to keep battery use low.
enum ReaderScript {
    static let source = #"""
(function () {
  if (window.__folio) { return; }
  var F = {};
  window.__folio = F;

  var mode = 'scroll';
  var W = window.innerWidth, H = window.innerHeight;
  var PAD_TOP = 30, PAD_BOTTOM = 44, PAD_SIDE = 24;
  var lastF = 0;
  var reportTimer = null, resizeTimer = null, selTimer = null;
  var touch = null;

  function post(m) {
    try { window.webkit.messageHandlers.folio.postMessage(m); } catch (e) {}
  }
  function se() { return document.scrollingElement || document.documentElement; }
  function styleEl(id) {
    var s = document.getElementById(id);
    if (!s) {
      s = document.createElement('style');
      s.id = id;
      (document.head || document.documentElement).appendChild(s);
    }
    return s;
  }
  function viewport() {
    var head = document.head || document.documentElement;
    var m = document.querySelector('meta[name=viewport]');
    if (!m) { m = document.createElement('meta'); m.setAttribute('name', 'viewport'); head.appendChild(m); }
    m.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
  }

  function layoutCSS() {
    W = window.innerWidth; H = window.innerHeight;
    if (mode === 'paged') {
      return 'html{height:' + H + 'px !important;max-height:' + H + 'px !important;width:' + W + 'px !important;' +
        'margin:0 !important;padding:' + PAD_TOP + 'px 0 ' + PAD_BOTTOM + 'px 0 !important;box-sizing:border-box !important;' +
        '-webkit-column-width:' + W + 'px !important;column-width:' + W + 'px !important;' +
        '-webkit-column-gap:0 !important;column-gap:0 !important;column-fill:auto !important;' +
        'overflow-x:scroll !important;overflow-y:hidden !important;}' +
        'body{margin:0 !important;padding:0 ' + PAD_SIDE + 'px !important;box-sizing:border-box !important;' +
        'min-height:0 !important;height:auto !important;max-width:none !important;}' +
        'img,svg,video,figure{max-height:' + Math.max(80, H - PAD_TOP - PAD_BOTTOM - 8) + 'px !important;' +
        '-webkit-column-break-inside:avoid;break-inside:avoid;}' +
        'img{object-fit:contain;}';
    }
    return 'html{height:auto !important;width:auto !important;margin:0 !important;padding:0 !important;' +
      'overflow-x:hidden !important;-webkit-column-width:auto !important;column-width:auto !important;}' +
      'body{margin:0 !important;padding:' + PAD_TOP + 'px ' + PAD_SIDE + 'px ' + (PAD_BOTTOM + 70) + 'px !important;' +
      'box-sizing:border-box !important;max-width:none !important;}';
  }

  function pageCount() { return Math.max(1, Math.round(se().scrollWidth / W)); }
  function currentPage() { return Math.max(0, Math.round(se().scrollLeft / W)); }

  function state() {
    var el = se();
    if (mode === 'paged') {
      var pages = pageCount();
      var page = Math.min(currentPage(), pages - 1);
      return { f: (page + 1) / pages, page: page, pages: pages };
    }
    var sh = el.scrollHeight, ch = window.innerHeight, st = el.scrollTop;
    var f = sh <= ch ? 1 : Math.min(1, (st + ch) / sh);
    return { f: f, page: Math.floor(st / ch), pages: Math.max(1, Math.ceil(sh / ch)) };
  }
  function report(type) {
    var s = state();
    lastF = s.f;
    s.t = type || 'pos';
    post(s);
  }
  function scheduleReport() {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(function () { report('pos'); }, 150);
  }

  function goFraction(f) {
    var el = se();
    if (mode === 'paged') {
      el.scrollTop = 0;
      var pages = pageCount();
      var p = Math.min(pages - 1, Math.max(0, Math.ceil(f * pages - 0.001) - 1));
      el.scrollLeft = p * W;
    } else {
      el.scrollLeft = 0;
      var sh = el.scrollHeight, ch = window.innerHeight;
      el.scrollTop = Math.max(0, Math.min(sh - ch, f * sh - ch));
    }
  }
  function goElement(node) {
    if (!node || !node.getBoundingClientRect) { return false; }
    var el = se();
    var r = node.getBoundingClientRect();
    if (mode === 'paged') {
      var x = r.left + el.scrollLeft;
      el.scrollLeft = Math.max(0, Math.floor((x + 1) / W)) * W;
    } else {
      el.scrollTop = Math.max(0, r.top + el.scrollTop - window.innerHeight * 0.25);
    }
    return true;
  }
  function byFragment(frag) {
    var id = frag;
    try { id = decodeURIComponent(frag); } catch (e) {}
    return document.getElementById(id) || document.getElementsByName(id)[0] || null;
  }
  function goTarget(t) {
    if (!t) { goFraction(0); return; }
    if (t.type === 'fraction') { goFraction(t.value || 0); }
    else if (t.type === 'end') { goFraction(1); }
    else if (t.type === 'fragment') { if (!goElement(byFragment(t.value))) { goFraction(0); } }
    else if (t.type === 'highlight') {
      if (!goElement(document.querySelector('mark.__hl[data-id="' + t.value + '"]'))) { goFraction(0); }
    }
  }

  // ---------- Highlights (stored as character offsets in the chapter text) ----------

  function textOffset(node, offset) {
    var r = document.createRange();
    r.setStart(document.body, 0);
    r.setEnd(node, offset);
    return r.toString().length;
  }

  function applyHL(id, start, end, color) {
    if (!(end > start)) { return; }
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
    var nodes = [], n;
    while ((n = walker.nextNode())) { nodes.push(n); }
    var pos = 0;
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var len = node.data.length;
      var ns = pos, ne = pos + len;
      pos = ne;
      if (ne <= start) { continue; }
      if (ns >= end) { break; }
      var s = Math.max(0, start - ns), e = Math.min(len, end - ns);
      if (e <= s) { continue; }
      var target = node;
      if (e < len) { target.splitText(e); }
      if (s > 0) { target = target.splitText(s); }
      if (!/\S/.test(target.data)) { continue; }
      var parent = target.parentNode;
      if (!parent || /^(style|script|title)$/i.test(parent.nodeName)) { continue; }
      var mark = document.createElement('mark');
      mark.className = '__hl';
      mark.setAttribute('data-id', id);
      mark.setAttribute('data-c', color || 'yellow');
      parent.replaceChild(mark, target);
      mark.appendChild(target);
    }
  }

  F.highlightSelection = function (id, color) {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { return null; }
    var r = sel.getRangeAt(0);
    if (!document.body.contains(r.commonAncestorContainer)) { return null; }
    var text = r.toString().replace(/\s+/g, ' ').trim();
    if (!text) { return null; }
    var s = textOffset(r.startContainer, r.startOffset);
    var e = textOffset(r.endContainer, r.endOffset);
    sel.removeAllRanges();
    applyHL(id, s, e, color);
    post({ t: 'sel', has: false });
    return { s: s, e: e, text: text };
  };

  F.removeHighlight = function (id) {
    var marks = document.querySelectorAll('mark.__hl[data-id="' + id + '"]');
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i], p = m.parentNode;
      if (!p) { continue; }
      while (m.firstChild) { p.insertBefore(m.firstChild, m); }
      p.removeChild(m);
      p.normalize();
    }
  };

  F.selectedText = function () {
    var s = window.getSelection();
    return s ? s.toString().replace(/\s+/g, ' ').trim() : '';
  };
  F.clearSelection = function () {
    var s = window.getSelection();
    if (s) { s.removeAllRanges(); }
    post({ t: 'sel', has: false });
  };

  // ---------- Setup / configuration ----------

  F.setup = function (cfg) {
    viewport();
    mode = cfg.mode || 'scroll';
    styleEl('__folio_theme').textContent = cfg.css || '';
    styleEl('__folio_layout').textContent = layoutCSS();
    var hls = cfg.hls || [];
    for (var i = 0; i < hls.length; i++) { applyHL(hls[i].id, hls[i].s, hls[i].e, hls[i].c); }
    goTarget(cfg.target);
    // Re-apply once layout has fully settled (fonts, images), then reveal the page
    setTimeout(function () {
      goTarget(cfg.target);
      report('ready');
    }, 30);
  };

  F.configure = function (cfg) {
    var keep = lastF;
    if (cfg.mode) { mode = cfg.mode; }
    if (typeof cfg.css === 'string') { styleEl('__folio_theme').textContent = cfg.css; }
    styleEl('__folio_layout').textContent = layoutCSS();
    goFraction(keep);
    report('pos');
  };

  F.go = function (t) {
    goTarget(t);
    report('pos');
  };

  // ---------- Input ----------

  function turn(d) {
    var el = se();
    var pages = pageCount();
    var p = currentPage() + d;
    if (p < 0) { post({ t: 'prev' }); return; }
    if (p >= pages) { post({ t: 'next' }); return; }
    if (el.scrollTo) { el.scrollTo({ left: p * W, top: 0, behavior: 'smooth' }); } else { el.scrollLeft = p * W; }
  }

  // Called from native tap recogniser; returns what the tap did.
  F.tapAt = function (x, y) {
    var sel = window.getSelection();
    if (sel && !sel.isCollapsed) { return 'sel'; }
    var node = document.elementFromPoint(x, y);
    while (node && node !== document.documentElement) {
      var name = (node.nodeName || '').toLowerCase();
      if (name === 'a' && node.getAttribute && node.getAttribute('href')) { return 'link'; }
      if (node.classList && node.classList.contains('__hl')) {
        post({ t: 'hl', id: node.getAttribute('data-id') });
        return 'hl';
      }
      node = node.parentNode;
    }
    if (mode === 'paged') {
      if (x < W * 0.25) { turn(-1); return 'page'; }
      if (x > W * 0.75) { turn(1); return 'page'; }
    }
    return 'center';
  };

  window.addEventListener('scroll', scheduleReport, { passive: true });

  window.addEventListener('resize', function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      if (window.innerWidth === W && window.innerHeight === H) { return; }
      var keep = lastF;
      styleEl('__folio_layout').textContent = layoutCSS();
      goFraction(keep);
      report('pos');
    }, 120);
  });

  document.addEventListener('selectionchange', function () {
    clearTimeout(selTimer);
    selTimer = setTimeout(function () {
      var s = window.getSelection();
      post({ t: 'sel', has: !!(s && !s.isCollapsed && s.toString().trim().length > 0) });
    }, 180);
  });

  // Swiping past the last page / pulling past the end moves to the next chapter.
  document.addEventListener('touchstart', function (e) {
    if (e.touches.length !== 1) { touch = null; return; }
    var el = se(), t = e.touches[0];
    touch = {
      x: t.clientX, y: t.clientY,
      atStart: mode === 'paged' ? el.scrollLeft <= 2 : el.scrollTop <= 2,
      atEnd: mode === 'paged'
        ? el.scrollLeft + W >= el.scrollWidth - 2
        : el.scrollTop + window.innerHeight >= el.scrollHeight - 2
    };
  }, { passive: true });

  document.addEventListener('touchend', function (e) {
    var s = touch;
    touch = null;
    if (!s || !e.changedTouches || e.changedTouches.length < 1) { return; }
    var sel = window.getSelection();
    if (sel && !sel.isCollapsed) { return; }
    var t = e.changedTouches[0];
    var dx = t.clientX - s.x, dy = t.clientY - s.y;
    if (mode === 'paged') {
      if (Math.abs(dx) < 50 || Math.abs(dx) < Math.abs(dy)) { return; }
      if (dx < 0 && s.atEnd) { post({ t: 'next' }); }
      else if (dx > 0 && s.atStart) { post({ t: 'prev' }); }
    } else {
      if (Math.abs(dy) < 80 || Math.abs(dy) < Math.abs(dx)) { return; }
      if (dy < 0 && s.atEnd) { post({ t: 'next' }); }
      else if (dy > 110 && s.atStart) { post({ t: 'prev' }); }
    }
  }, { passive: true });
})();
"""#
}
