// Python.h must come before any system header.
#include <Python/Python.h>

#import "FolioPython.h"
#import <JavaScriptCore/JavaScriptCore.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - C callbacks handed to Python (via ctypes)

static atomic_int gCancelled = 0;
static FolioProgressBlock gProgress = nil;   // only touched on the Python thread

/// Evaluates JavaScript with JavaScriptCore. console.log output is returned;
/// errors are returned prefixed with "\x01ERR:". Caller frees with folio_free.
static char *folio_js_eval(const char *source) {
    @autoreleasepool {
        NSString *src = source ? [NSString stringWithUTF8String:source] : nil;
        if (src == nil) { return strdup("\x01" "ERR:invalid script"); }

        JSContext *ctx = [[JSContext alloc] init];
        NSMutableString *output = [NSMutableString string];
        __block NSString *error = nil;
        ctx.exceptionHandler = ^(JSContext *context, JSValue *exception) {
            error = [exception toString] ?: @"JavaScript exception";
        };
        [ctx evaluateScript:@"var console = {};"];
        ctx[@"console"][@"log"] = ^(JSValue *value) {
            NSString *s = [value toString];
            if (s) { [output appendString:s]; [output appendString:@"\n"]; }
        };
        [ctx evaluateScript:src];

        NSString *result = error ? [@"\x01" "ERR:" stringByAppendingString:error] : output;
        const char *utf8 = [result UTF8String];
        return strdup(utf8 ? utf8 : "");
    }
}

static void folio_free(void *ptr) {
    free(ptr);
}

static void folio_progress(double fraction, const char *message) {
    FolioProgressBlock block = gProgress;
    if (block == nil) { return; }
    NSString *text = message ? [NSString stringWithUTF8String:message] : @"";
    if (text == nil) { text = @""; }
    dispatch_async(dispatch_get_main_queue(), ^{ block(fraction, text); });
}

static int folio_cancelled(void) {
    return atomic_load(&gCancelled);
}

#pragma mark - FolioPython

@implementation FolioPython {
    NSThread *_thread;
    NSCondition *_condition;
    NSMutableArray<dispatch_block_t> *_jobs;
    BOOL _initialized;
    NSString *_initError;
    NSString *_setupJSON;
    PyThreadState *_threadState;   // saved while idle so the GIL is free between jobs
}

+ (FolioPython *)shared {
    static FolioPython *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[FolioPython alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jobs = [NSMutableArray array];
        _condition = [[NSCondition alloc] init];
        // A dedicated thread with a big stack: Python and the JS challenge solver
        // both recurse deeply, and GCD threads only have 512 KB.
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
        _thread.name = @"Folio Python";
        _thread.stackSize = 16 * 1024 * 1024;
        _thread.qualityOfService = NSQualityOfServiceUserInitiated;
        [_thread start];
    }
    return self;
}

- (void)threadMain {
    while (YES) {
        [_condition lock];
        while (_jobs.count == 0) { [_condition wait]; }
        dispatch_block_t job = _jobs.firstObject;
        [_jobs removeObjectAtIndex:0];
        [_condition unlock];
        if (_threadState) { PyEval_RestoreThread(_threadState); _threadState = NULL; }
        @autoreleasepool { job(); }
        if (Py_IsInitialized()) { _threadState = PyEval_SaveThread(); }
    }
}

- (void)enqueue:(dispatch_block_t)job {
    [_condition lock];
    [_jobs addObject:[job copy]];
    [_condition signal];
    [_condition unlock];
}

#pragma mark Interpreter

static NSString *FolioJSONError(NSString *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"ok": @NO, @"error": message ?: @"Unknown error"}
                                                   options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"ok\":false}";
}

/// Must be called on the Python thread.
- (NSString *)currentPythonError {
    NSString *message = @"Python error";
    PyObject *exc = PyErr_GetRaisedException();
    if (exc) {
        PyObject *str = PyObject_Str(exc);
        if (str) {
            const char *c = PyUnicode_AsUTF8(str);
            if (c) { message = [NSString stringWithFormat:@"%s: %s", Py_TYPE(exc)->tp_name, c]; }
            Py_DECREF(str);
        }
        Py_DECREF(exc);
    }
    PyErr_Clear();
    NSLog(@"[Folio] %@", message);
    return message;
}

/// Starts the interpreter once. Returns an error message or nil.
- (NSString *)ensureInitialized {
    if (_initialized) { return _initError; }
    _initialized = YES;

    NSString *resources = [[NSBundle mainBundle] resourcePath];
    NSString *home = [resources stringByAppendingPathComponent:@"python"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:home]) {
        _initError = @"The Python runtime is missing from this build.";
        return _initError;
    }

    setenv("NO_COLOR", "1", 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);

    PyPreConfig preconfig;
    PyConfig config;
    PyStatus status;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    PyConfig_InitIsolatedConfig(&config);
    preconfig.utf8_mode = 1;
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;

    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        _initError = [NSString stringWithFormat:@"Python pre-init failed: %s", status.err_msg ?: ""];
        return _initError;
    }

    wchar_t *wHome = Py_DecodeLocale(home.UTF8String, NULL);
    status = PyConfig_SetString(&config, &config.home, wHome);
    PyMem_RawFree(wHome);
    if (!PyStatus_Exception(status)) { status = PyConfig_Read(&config); }
    if (!PyStatus_Exception(status)) { status = Py_InitializeFromConfig(&config); }
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        _initError = [NSString stringWithFormat:@"Python failed to start: %s", status.err_msg ?: ""];
        return _initError;
    }

    // app_packages (yt-dlp, certifi…) as a site dir, our bridge module on sys.path
    NSString *packages = [resources stringByAppendingPathComponent:@"app_packages"];
    NSString *app = [resources stringByAppendingPathComponent:@"app"];
    PyObject *site = PyImport_ImportModule("site");
    if (site) {
        PyObject *res = PyObject_CallMethod(site, "addsitedir", "s", packages.UTF8String);
        Py_XDECREF(res);
        Py_DECREF(site);
    }
    PyObject *sysPath = PySys_GetObject("path");   // borrowed
    if (sysPath) {
        PyObject *p = PyUnicode_FromString(app.UTF8String);
        if (p) { PyList_Insert(sysPath, 0, p); Py_DECREF(p); }
    }
    if (PyErr_Occurred()) { [self currentPythonError]; }

    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSArray *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = [caches.firstObject stringByAppendingPathComponent:@"yt-dlp"];
    NSString *updateDir = [support.firstObject stringByAppendingPathComponent:@"Folio/yt-dlp-updates"];

    PyObject *args = Py_BuildValue("(KKKKss)",
                                   (unsigned long long)(uintptr_t)&folio_js_eval,
                                   (unsigned long long)(uintptr_t)&folio_free,
                                   (unsigned long long)(uintptr_t)&folio_progress,
                                   (unsigned long long)(uintptr_t)&folio_cancelled,
                                   cacheDir.UTF8String,
                                   updateDir.UTF8String);
    NSString *json = [self call:"setup" args:args];
    if ([json containsString:@"\"ok\": true"] || [json containsString:@"\"ok\":true"]) {
        _setupJSON = json;
        return nil;
    }
    _initError = json;
    return _initError;
}

/// Calls folio_ytdl.<name>(*args) and returns its JSON string. Steals `args`.
- (NSString *)call:(const char *)name args:(PyObject *)args {
    if (args == NULL) { return FolioJSONError([self currentPythonError]); }
    PyObject *module = PyImport_ImportModule("folio_ytdl");
    if (module == NULL) { Py_DECREF(args); return FolioJSONError([self currentPythonError]); }
    PyObject *fn = PyObject_GetAttrString(module, name);
    Py_DECREF(module);
    if (fn == NULL) { Py_DECREF(args); return FolioJSONError([self currentPythonError]); }
    PyObject *result = PyObject_CallObject(fn, args);
    Py_DECREF(fn);
    Py_DECREF(args);
    if (result == NULL) { return FolioJSONError([self currentPythonError]); }
    NSString *json = nil;
    const char *utf8 = PyUnicode_Check(result) ? PyUnicode_AsUTF8(result) : NULL;
    if (utf8) { json = [NSString stringWithUTF8String:utf8]; }
    Py_DECREF(result);
    if (PyErr_Occurred()) { [self currentPythonError]; }
    return json ?: FolioJSONError(@"Unexpected result from Python");
}

#pragma mark Public API

- (void)prepare:(FolioResultBlock)completion {
    FolioResultBlock done = [completion copy];
    [self enqueue:^{
        NSString *error = [self ensureInitialized];
        NSString *json = error ? ([error hasPrefix:@"{"] ? error : FolioJSONError(error)) : self->_setupJSON;
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }];
}

- (void)downloadURL:(NSString *)url
        toDirectory:(NSString *)directory
           progress:(FolioProgressBlock)progress
         completion:(FolioResultBlock)completion {
    FolioProgressBlock onProgress = [progress copy];
    FolioResultBlock done = [completion copy];
    NSString *u = [url copy];
    NSString *d = [directory copy];
    [self enqueue:^{
        atomic_store(&gCancelled, 0);
        NSString *json;
        NSString *error = [self ensureInitialized];
        if (error) {
            json = [error hasPrefix:@"{"] ? error : FolioJSONError(error);
        } else {
            gProgress = onProgress;
            json = [self call:"download" args:Py_BuildValue("(ss)", u.UTF8String, d.UTF8String)];
            gProgress = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }];
}

- (void)updateWithProgress:(FolioProgressBlock)progress completion:(FolioResultBlock)completion {
    FolioProgressBlock onProgress = [progress copy];
    FolioResultBlock done = [completion copy];
    [self enqueue:^{
        NSString *json;
        NSString *error = [self ensureInitialized];
        if (error) {
            json = [error hasPrefix:@"{"] ? error : FolioJSONError(error);
        } else {
            gProgress = onProgress;
            json = [self call:"update" args:PyTuple_New(0)];
            gProgress = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }];
}

- (void)resetUpdates:(FolioResultBlock)completion {
    FolioResultBlock done = [completion copy];
    [self enqueue:^{
        NSString *json;
        NSString *error = [self ensureInitialized];
        json = error ? ([error hasPrefix:@"{"] ? error : FolioJSONError(error))
                     : [self call:"reset_updates" args:PyTuple_New(0)];
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }];
}

- (void)cancel {
    atomic_store(&gCancelled, 1);
}

@end
