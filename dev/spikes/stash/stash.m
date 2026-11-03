// Throwaway spike: validates hiding tiling pages by moving their windows to a
// second native desktop (the "stash") on the same display, and showing them by
// moving them back. Only windows this process creates are moved or closed.
//
// The desktop that is current at start is "visible"; the other user desktop on
// that display is the "stash". Run `stash` without arguments for usage.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <time.h>

extern char **environ;

#define SKYLIGHT_PATH "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
#define BRIDGED_SYM "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
#define HK_SPACE_LEFT 79
#define HK_SPACE_RIGHT 81
#define CPS_USER_GENERATED 0x200
#define MAXW 48

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface NSObject (StashBridged)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)sid;
- (instancetype)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)sid;
- (instancetype)initWithSpaces:(NSArray *)spaces;
@end

// ---------------------------------------------------------------- symbols

static int g_cid;
static int (*f_SLSMainConnectionID)(void);
static CFArrayRef (*f_SLSCopyManagedDisplaySpaces)(int);
static CFArrayRef (*f_SLSCopySpacesForWindows)(int, int, CFArrayRef);
static uint64_t (*f_SLSManagedDisplayGetCurrentSpace)(int, CFStringRef);
static CFStringRef (*f_SLSCopyBestManagedDisplayForPoint)(int, CGPoint);
static CGError (*f_CGSGetSymbolicHotKeyValue)(int, uint16_t *, uint16_t *, uint32_t *);
static bool (*f_CGSIsSymbolicHotKeyEnabled)(int);
static AXError (*f_AXUIElementGetWindow)(AXUIElementRef, uint32_t *);
static CGError (*f_SLPSSetFrontProcessWithOptions)(ProcessSerialNumber *, uint32_t, uint32_t);
static CGError (*f_SLPSPostEventRecordTo)(ProcessSerialNumber *, uint8_t *);
static CGError (*f_SLPSGetFrontProcess)(ProcessSerialNumber *);
static int64_t (*f_bridged_perform)(void *);

static uint64_t g_t0;
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static double ms_since(uint64_t t) { return ((double)now_ns() - (double)t) / 1e6; }

static double mon_t(void);

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    double rel = mon_t();
    if (rel >= 0) printf("[%8.1fms +%7.1f] ", ms_since(g_t0), rel);
    else printf("[%8.1fms          ] ", ms_since(g_t0));
    vprintf(fmt, ap);
    printf("\n");
    fflush(stdout);
    va_end(ap);
}
#define LOG(...) logf_(__VA_ARGS__)

static void *sym(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) printf("  [warn] dlsym(%s) = NULL\n", name);
    return p;
}

// Walks the in-memory LC_SYMTAB of a loaded image (port of yabai macho_dlsym.h).
static void *macho_find_symbol(const char *image, const char *target) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || strcmp(nm, image)) continue;
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct segment_command_64 *le = NULL;
        const struct symtab_command *st = NULL;
        const uint8_t *p = (const uint8_t *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++) {
            const struct load_command *lc = (const void *)p;
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT))
                le = (const void *)lc;
            if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
            p += lc->cmdsize;
        }
        if (!le || !st) return NULL;
        uintptr_t base = (uintptr_t)(le->vmaddr - le->fileoff + slide);
        const char *strs = (const char *)(base + st->stroff);
        const struct nlist_64 *syms = (const void *)(base + st->symoff);
        for (uint32_t s = 0; s < st->nsyms; s++)
            if (!strcmp(strs + syms[s].n_un.n_strx, target)) return (void *)(syms[s].n_value + slide);
        return NULL;
    }
    return NULL;
}

static void load_symbols(void) {
    dlopen(SKYLIGHT_PATH, RTLD_NOW | RTLD_GLOBAL);
    *(void **)&f_SLSMainConnectionID = sym("SLSMainConnectionID");
    *(void **)&f_SLSCopyManagedDisplaySpaces = sym("SLSCopyManagedDisplaySpaces");
    *(void **)&f_SLSCopySpacesForWindows = sym("SLSCopySpacesForWindows");
    *(void **)&f_SLSManagedDisplayGetCurrentSpace = sym("SLSManagedDisplayGetCurrentSpace");
    *(void **)&f_SLSCopyBestManagedDisplayForPoint = sym("SLSCopyBestManagedDisplayForPoint");
    *(void **)&f_CGSGetSymbolicHotKeyValue = sym("CGSGetSymbolicHotKeyValue");
    *(void **)&f_CGSIsSymbolicHotKeyEnabled = sym("CGSIsSymbolicHotKeyEnabled");
    *(void **)&f_AXUIElementGetWindow = sym("_AXUIElementGetWindow");
    *(void **)&f_SLPSSetFrontProcessWithOptions = sym("_SLPSSetFrontProcessWithOptions");
    *(void **)&f_SLPSPostEventRecordTo = sym("SLPSPostEventRecordTo");
    *(void **)&f_SLPSGetFrontProcess = sym("_SLPSGetFrontProcess");
    *(void **)&f_bridged_perform = macho_find_symbol(SKYLIGHT_PATH, BRIDGED_SYM);
    g_cid = f_SLSMainConnectionID ? f_SLSMainConnectionID() : 0;
}

// ---------------------------------------------------------------- topology

typedef struct { uint64_t sid; int type; } SpaceRec;
typedef struct { char uuid[64]; uint64_t current; int n; SpaceRec sp[64]; } DisplayRec;
typedef struct { int n; DisplayRec d[8]; } Topo;

static void topo_load(Topo *t) {
    memset(t, 0, sizeof *t);
    CFArrayRef raw = f_SLSCopyManagedDisplaySpaces(g_cid);
    if (!raw) return;
    NSArray *arr = CFBridgingRelease(raw);
    for (NSDictionary *disp in arr) {
        if (t->n >= 8) break;
        DisplayRec *d = &t->d[t->n++];
        strlcpy(d->uuid, [disp[@"Display Identifier"] UTF8String] ?: "?", sizeof d->uuid);
        d->current = [disp[@"Current Space"][@"id64"] unsignedLongLongValue];
        for (NSDictionary *s in disp[@"Spaces"]) {
            if (d->n >= 64) break;
            d->sp[d->n].sid = [s[@"id64"] unsignedLongLongValue];
            d->sp[d->n].type = [s[@"type"] intValue];
            d->n++;
        }
    }
}

static int topo_find(const Topo *t, uint64_t sid, int *si) {
    for (int i = 0; i < t->n; i++)
        for (int j = 0; j < t->d[i].n; j++)
            if (t->d[i].sp[j].sid == sid) { if (si) *si = j; return i; }
    return -1;
}

static NSString *topo_order(void) {
    Topo t;
    topo_load(&t);
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < t.n; i++)
        for (int j = 0; j < t.d[i].n; j++) [a addObject:[NSString stringWithFormat:@"%llu", t.d[i].sp[j].sid]];
    return [a componentsJoinedByString:@","];
}

// ---------------------------------------------------------------- session

static struct {
    char uuid[64];
    uint64_t vis, stash;
    CGPoint cursor0;
    pid_t front0;
    uint32_t front0_wid;
    char front0_name[64];
    bool te_was_running;
    CGRect vf;
    char dir[1024];
    NSString *order0;
    bool active, cleaned;
    int seq;
    int nspace_notifs;
} S;

static uint64_t display_current(void) {
    return f_SLSManagedDisplayGetCurrentSpace(g_cid, (__bridge CFStringRef)@(S.uuid));
}

// ---------------------------------------------------------------- windows

static CFArrayRef cf_wids(const uint32_t *wids, int n) {
    CFNumberRef nums[MAXW];
    for (int i = 0; i < n; i++) {
        int32_t v = (int32_t)wids[i];
        nums[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    }
    CFArrayRef a = CFArrayCreate(NULL, (const void **)nums, n, &kCFTypeArrayCallBacks);
    for (int i = 0; i < n; i++) CFRelease(nums[i]);
    return a;
}

static NSArray<NSNumber *> *window_spaces(uint32_t wid) {
    CFArrayRef a = cf_wids(&wid, 1);
    CFArrayRef r = f_SLSCopySpacesForWindows(g_cid, 0x7, a);
    CFRelease(a);
    return r ? CFBridgingRelease(r) : @[];
}

static bool spaces_is(NSArray *s, uint64_t sid) { return s.count == 1 && [s[0] unsignedLongLongValue] == sid; }
static bool on_space(uint32_t wid, uint64_t sid) { return spaces_is(window_spaces(wid), sid); }
static const char *spaces_cstr(NSArray *s) { return [[s componentsJoinedByString:@","] UTF8String] ?: ""; }
static const char *where(uint32_t wid) {
    NSArray *s = window_spaces(wid);
    if (spaces_is(s, S.vis)) return "visible";
    if (spaces_is(s, S.stash)) return "stash";
    static char b[8][64];
    static int k;
    char *o = b[k++ % 8];
    snprintf(o, 64, "[%s]", spaces_cstr(s));
    return o;
}

typedef struct { bool ok, onscreen; pid_t pid; char owner[128], title[256]; CGRect bounds; int layer; } WinRec;

static WinRec win_info(uint32_t wid) {
    WinRec w = {0};
    const void *v = (const void *)(uintptr_t)wid;
    CFArrayRef ids = CFArrayCreate(NULL, &v, 1, NULL);
    CFArrayRef raw = CGWindowListCreateDescriptionFromArray(ids);
    CFRelease(ids);
    if (!raw) return w;
    NSArray *arr = CFBridgingRelease(raw);
    NSDictionary *d = arr.firstObject;
    if (!d || [d[(id)kCGWindowNumber] unsignedIntValue] != wid) return w;
    w.ok = true;
    w.pid = [d[(id)kCGWindowOwnerPID] intValue];
    strlcpy(w.owner, [d[(id)kCGWindowOwnerName] UTF8String] ?: "", sizeof w.owner);
    strlcpy(w.title, [d[(id)kCGWindowName] UTF8String] ?: "", sizeof w.title);
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &w.bounds);
    w.layer = [d[(id)kCGWindowLayer] intValue];
    w.onscreen = [d[(id)kCGWindowIsOnscreen] boolValue];
    return w;
}

// One WindowServer query for several windows.
static void cg_query(const uint32_t *wids, int n, bool *exists, bool *onscreen, CGRect *bounds) {
    for (int i = 0; i < n; i++) {
        exists[i] = onscreen[i] = false;
        if (bounds) bounds[i] = CGRectZero;
    }
    if (n <= 0) return;
    const void *vals[MAXW * 2];
    for (int i = 0; i < n; i++) vals[i] = (const void *)(uintptr_t)wids[i];
    CFArrayRef ids = CFArrayCreate(NULL, vals, n, NULL);
    CFArrayRef raw = CGWindowListCreateDescriptionFromArray(ids);
    CFRelease(ids);
    if (!raw) return;
    NSArray *arr = CFBridgingRelease(raw);
    for (NSDictionary *d in arr) {
        uint32_t w = [d[(id)kCGWindowNumber] unsignedIntValue];
        for (int i = 0; i < n; i++) {
            if (wids[i] != w) continue;
            exists[i] = true;
            onscreen[i] = [d[(id)kCGWindowIsOnscreen] boolValue];
            if (bounds) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &bounds[i]);
        }
    }
}

static bool rect_eq(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) <= 1 && fabs(a.origin.y - b.origin.y) <= 1 &&
           fabs(a.size.width - b.size.width) <= 1 && fabs(a.size.height - b.size.height) <= 1;
}
#define RECT_FMT "(%.0f,%.0f %.0fx%.0f)"
#define RECT_ARGS(r) (r).origin.x, (r).origin.y, (r).size.width, (r).size.height

// Real (titled, non-trivial, layer 0) windows of `pid` on space `sid`.
static int app_windows_on(pid_t pid, uint64_t sid) {
    NSArray *arr = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    int n = 0;
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowOwnerPID] intValue] != pid || [d[(id)kCGWindowLayer] intValue] != 0) continue;
        if (![d[(id)kCGWindowName] length]) continue;
        CGRect b;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &b);
        if (b.size.width < 60 || b.size.height < 60) continue;
        if (on_space([d[(id)kCGWindowNumber] unsignedIntValue], sid)) n++;
    }
    return n;
}

// Layer-0, non-trivial windows on `sid`, excluding `ex`.
static int windows_on_space(uint64_t sid, const uint32_t *ex, int nex, uint32_t *out, int max) {
    NSArray *arr = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    int n = 0;
    for (NSDictionary *d in arr) {
        if (n >= max) break;
        if ([d[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &b);
        if (b.size.width < 60 || b.size.height < 60) continue;
        uint32_t w = [d[(id)kCGWindowNumber] unsignedIntValue];
        bool skip = false;
        for (int i = 0; i < nex; i++) skip |= ex[i] == w;
        if (!skip && on_space(w, sid)) out[n++] = w;
    }
    return n;
}

// ---------------------------------------------------------------- AX

static uint32_t ax_wid(AXUIElementRef el) {
    uint32_t w = 0;
    if (el && f_AXUIElementGetWindow && f_AXUIElementGetWindow(el, &w) == kAXErrorSuccess) return w;
    return 0;
}

static NSArray *ax_windows(pid_t pid, AXError *err) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef v = NULL;
    AXError e = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &v);
    CFRelease(app);
    if (err) *err = e;
    return (e == kAXErrorSuccess && v) ? CFBridgingRelease(v) : @[];
}

static NSString *ax_str(AXUIElementRef el, CFStringRef attr, AXError *err) {
    CFTypeRef v = NULL;
    AXError e = AXUIElementCopyAttributeValue(el, attr, &v);
    if (err) *err = e;
    if (e != kAXErrorSuccess || !v) return nil;
    id o = CFBridgingRelease(v);
    return [o isKindOfClass:[NSString class]] ? o : nil;
}

static AXUIElementRef ax_child(AXUIElementRef el, CFStringRef attr, AXError *err) {
    CFTypeRef v = NULL;
    AXError e = AXUIElementCopyAttributeValue(el, attr, &v);
    if (err) *err = e;
    if (e != kAXErrorSuccess || !v) return NULL;
    return (AXUIElementRef)v;
}

static AXError ax_get_pos(AXUIElementRef el, CGPoint *p) {
    CFTypeRef v = NULL;
    AXError e = AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &v);
    if (e == kAXErrorSuccess && v) AXValueGetValue(v, kAXValueTypeCGPoint, p);
    if (v) CFRelease(v);
    return e;
}

static AXError ax_get_size(AXUIElementRef el, CGSize *s) {
    CFTypeRef v = NULL;
    AXError e = AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &v);
    if (e == kAXErrorSuccess && v) AXValueGetValue(v, kAXValueTypeCGSize, s);
    if (v) CFRelease(v);
    return e;
}

static bool ax_frame(AXUIElementRef el, CGRect *r) {
    *r = CGRectZero;
    return ax_get_pos(el, &r->origin) == kAXErrorSuccess && ax_get_size(el, &r->size) == kAXErrorSuccess;
}

static AXError ax_set_pos(AXUIElementRef el, CGPoint p) {
    AXValueRef v = AXValueCreate(kAXValueTypeCGPoint, &p);
    AXError e = AXUIElementSetAttributeValue(el, kAXPositionAttribute, v);
    CFRelease(v);
    return e;
}

static AXError ax_set_size(AXUIElementRef el, CGSize s) {
    AXValueRef v = AXValueCreate(kAXValueTypeCGSize, &s);
    AXError e = AXUIElementSetAttributeValue(el, kAXSizeAttribute, v);
    CFRelease(v);
    return e;
}

static void ax_set_frame(AXUIElementRef el, CGRect r, AXError *ep, AXError *es) {
    AXError a = ax_set_pos(el, r.origin);
    AXError b = ax_set_size(el, r.size);
    if (ep) *ep = a;
    if (es) *es = b;
}

static AXUIElementRef ax_find(pid_t pid, uint32_t wid) {
    for (id el in ax_windows(pid, NULL))
        if (ax_wid((__bridge AXUIElementRef)el) == wid) return (AXUIElementRef)CFRetain((__bridge CFTypeRef)el);
    return NULL;
}

static const char *ax_list_cstr(pid_t pid) {
    AXError e;
    NSArray *ws = ax_windows(pid, &e);
    NSMutableArray *ids = [NSMutableArray array];
    for (id el in ws) [ids addObject:@(ax_wid((__bridge AXUIElementRef)el))];
    static char b[4][256];
    static int k;
    char *o = b[k++ % 4];
    snprintf(o, 256, "err=%d ids=[%s]", e, [[ids componentsJoinedByString:@","] UTF8String]);
    return o;
}

static uint32_t ax_focused_wid(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementRef w = ax_child(app, kAXFocusedWindowAttribute, NULL);
    CFRelease(app);
    uint32_t wid = ax_wid(w);
    if (w) CFRelease(w);
    return wid;
}

static pid_t ax_system_focused_pid(void) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    AXUIElementRef app = ax_child(sys, kAXFocusedApplicationAttribute, NULL);
    CFRelease(sys);
    pid_t p = -1;
    if (app) { AXUIElementGetPid(app, &p); CFRelease(app); }
    return p;
}

static int ax_bool(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return -1;
    int r = CFBooleanGetValue(v) ? 1 : 0;
    CFRelease(v);
    return r;
}

// ---------------------------------------------------------------- input / processes

static CGPoint cursor_pos(void) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    return p;
}

static void cursor_restore(CGPoint p) {
    CGWarpMouseCursorPosition(p);
    CGAssociateMouseAndMouseCursorPosition(true);
}

static bool hk_post(int id, char *err, size_t len) {
    uint16_t ch = 0, kc = 0;
    uint32_t mods = 0;
    CGError e = f_CGSGetSymbolicHotKeyValue ? f_CGSGetSymbolicHotKeyValue(id, &ch, &kc, &mods) : -1;
    if (e) { snprintf(err, len, "CGSGetSymbolicHotKeyValue(%d) err=%d", id, e); return false; }
    if (!f_CGSIsSymbolicHotKeyEnabled(id)) { snprintf(err, len, "symbolic hotkey %d disabled", id); return false; }
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, kc, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, kc, false);
    CGEventSetFlags(d, mods);
    CGEventSetFlags(u, mods);
    CGEventPost(kCGHIDEventTap, d);
    CGEventPost(kCGHIDEventTap, u);
    CFRelease(d);
    CFRelease(u);
    return true;
}

static void key_post(CGKeyCode kc, bool down, CGEventFlags flags) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, kc, down);
    CGEventSetFlags(e, flags);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

// Quick Cmd-Tab: switches to the previously active app without showing the switcher.
static void cmd_tab(void) {
    key_post(55, true, kCGEventFlagMaskCommand);
    usleep(30000);
    key_post(48, true, kCGEventFlagMaskCommand);
    usleep(15000);
    key_post(48, false, kCGEventFlagMaskCommand);
    usleep(30000);
    key_post(55, false, 0);
}

static pid_t front_pid(void) {
    ProcessSerialNumber psn = {0};
    if (!f_SLPSGetFrontProcess || f_SLPSGetFrontProcess(&psn)) return -1;
    pid_t p = -1;
    GetProcessPID(&psn, &p);
    return p;
}

static const char *app_name(pid_t pid) {
    static char b[8][64];
    static int k;
    char *o = b[k++ % 8];
    NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    snprintf(o, 64, "%s", a.localizedName.UTF8String ?: "?");
    return o;
}

static bool app_activate(pid_t pid) {
    return [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
}

// yabai/HyprMac focus-without-raise: front the process for `wid`, then post the
// two key-window event records.
static void slps_front_key(pid_t pid, uint32_t wid, CGError rc[3]) {
    ProcessSerialNumber psn = {0};
    rc[0] = rc[1] = rc[2] = -1;
    if (GetProcessForPID(pid, &psn) != noErr) return;
    rc[0] = f_SLPSSetFrontProcessWithOptions(&psn, wid, CPS_USER_GENERATED);
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x08] = 0x01;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &wid, 4);
    memset(bytes + 0x20, 0xff, 0x10);
    rc[1] = f_SLPSPostEventRecordTo(&psn, bytes);
    bytes[0x08] = 0x02;
    rc[2] = f_SLPSPostEventRecordTo(&psn, bytes);
}

static pid_t g_child;
static int g_hk_to_stash, g_hk_to_vis;

static pid_t spawn_argv(const char *const argv[]) {
    pid_t p = 0;
    int rc = posix_spawn(&p, argv[0], NULL, NULL, (char *const *)argv, environ);
    if (rc) { LOG("posix_spawn(%s) failed: %d", argv[0], rc); return 0; }
    return p;
}

static int run_wait(const char *const argv[]) {
    pid_t p = spawn_argv(argv);
    if (!p) return -1;
    int st = 0;
    waitpid(p, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

// ---------------------------------------------------------------- bridged ops

static double bmove(const uint32_t *wids, int n, uint64_t sid) {
    if (n <= 0) return 0;
    Class c = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    CFArrayRef a = cf_wids(wids, n);
    uint64_t t = now_ns();
    id op = [[c alloc] initWithWindows:(__bridge NSArray *)a spaceID:sid];
    f_bridged_perform((__bridge void *)op);
    double d = ms_since(t);
    CFRelease(a);
    return d;
}

// Instant switch: show `target`, hide `hide`, set current. Hiding is explicit so
// it also works while the Dock is mid-animation.
static double bswitch(uint64_t target, uint64_t hide) {
    Class cs = objc_getClass("SLSBridgedShowSpacesOperation"), ch = objc_getClass("SLSBridgedHideSpacesOperation"),
          cc = objc_getClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    uint64_t t = now_ns();
    f_bridged_perform((__bridge void *)[[cs alloc] initWithSpaces:@[@(target)]]);
    f_bridged_perform((__bridge void *)[[ch alloc] initWithSpaces:@[@(hide)]]);
    f_bridged_perform((__bridge void *)[[cc alloc] initWithDisplayIdentifier:@(S.uuid) spaceID:target]);
    return ms_since(t);
}

// ---------------------------------------------------------------- monitor

// bounce-early reacts to the first sign of the stash (its windows going on screen
// as the Dock animation starts); bounce-late waits for current==stash or the
// space-change notification. hybrid = preempt, then bounce-late if needed.
typedef enum { R_NONE, R_BOUNCE, R_BOUNCE_LATE, R_PREEMPT, R_HYBRID } React;
static const char *react_name[] = {"none", "bounce-early", "bounce-late", "preempt", "hybrid"};
#define SRC_WS 1
#define SRC_AX 2
#define SRC_POLL 4

typedef struct Mon {
    bool on;
    int bounce_level;  // minimum switch-signal level that triggers a bounce: 0 shown, 1 current==stash, 2 notification
    int preempt_mask;  // SRC_* sources allowed to trigger preemption
    char preempt_src[48], bounce_src[64];
    uint64_t t0;
    React react;
    pid_t app;
    uint32_t subj[8], sprobe[MAXW], vprobe[MAXW];
    int nsubj, nsprobe, nvprobe;
    uint64_t cur;
    pid_t front;
    bool shown, vis_off;
    double t_ws_act, t_ax_act, t_front, t_ws_space, t_cur_stash, t_shown, t_vis_off, t_unshown, t_ax_focus, t_ax_main;
    double t_react, t_react_done, t_bounce, t_bounce_done, t_back;
    int nshown, nspace;
    double shown_ms;
    uint64_t shown_since;
    bool reacted, bounced;
    int bounce_delay_ms;
    uint64_t bounce_at;
    char why[96];
} Mon;
static Mon M;

static double mon_t(void) { return M.on ? ms_since(M.t0) : -1; }
#define FIRST(f) do { if (M.f < 0) M.f = mon_t(); } while (0)

static void mon_start(React r, pid_t app, const uint32_t *subj, int nsubj) {
    memset(&M, 0, sizeof M);
    M.react = r;
    M.app = app;
    M.bounce_level = r == R_BOUNCE ? 0 : 1;
    M.preempt_mask = SRC_WS | SRC_AX;
    M.nsubj = nsubj;
    for (int i = 0; i < nsubj; i++) M.subj[i] = subj[i];
    M.nsprobe = windows_on_space(S.stash, subj, nsubj, M.sprobe, MAXW);
    M.nvprobe = windows_on_space(S.vis, subj, nsubj, M.vprobe, MAXW);
    double *f[] = {&M.t_ws_act, &M.t_ax_act, &M.t_front, &M.t_ws_space, &M.t_cur_stash, &M.t_shown, &M.t_vis_off,
                   &M.t_unshown, &M.t_ax_focus, &M.t_ax_main, &M.t_react, &M.t_react_done, &M.t_bounce, &M.t_bounce_done,
                   &M.t_back};
    for (size_t i = 0; i < sizeof f / sizeof *f; i++) *f[i] = -1;
    M.cur = display_current();
    M.front = front_pid();
    M.t0 = now_ns();
    M.on = true;
    LOG("[mon] start react=%s app=%d stash_probes=%d visible_probes=%d cur=%llu front=%s(%d)", react_name[r], app,
        M.nsprobe, M.nvprobe, M.cur, app_name(M.front), M.front);
}

static void do_bounce(const char *why) {
    M.bounced = true;
    FIRST(t_bounce);
    snprintf(M.bounce_src, sizeof M.bounce_src, "%s", why);
    uint32_t mv[8];
    int n = 0;
    for (int i = 0; i < M.nsubj; i++) if (!on_space(M.subj[i], S.vis)) mv[n++] = M.subj[i];
    double dm = bmove(mv, n, S.vis);
    double ds = bswitch(S.vis, S.stash);
    M.t_bounce_done = mon_t();
    LOG("[react] BOUNCE (%s): moved %d window(s) to visible (%.1fms), instant switch (%.1fms)", why, n, dm, ds);
    // A WM would now focus the returned window; the Dock's switch fronted the stash's app.
    if (M.app > 0 && M.nsubj) {
        CGError rc[3];
        AXUIElementRef el = ax_find(M.app, M.subj[0]);
        if (el) {
            AXUIElementPerformAction(el, kAXRaiseAction);
            AXUIElementSetAttributeValue(el, kAXMainAttribute, kCFBooleanTrue);
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute, kCFBooleanTrue);
            CFRelease(el);
        }
        app_activate(M.app);
        slps_front_key(M.app, M.subj[0], rc);
        LOG("[react] focused returned window (SLPS rc %d/%d/%d)", rc[0], rc[1], rc[2]);
    }
}

static void do_preempt(const char *why) {
    M.reacted = true;
    FIRST(t_react);
    snprintf(M.preempt_src, sizeof M.preempt_src, "%s", why);
    int have = app_windows_on(M.app, S.vis);
    if (have) { LOG("[react] PREEMPT (%s): app has %d window(s) on visible; nothing to do", why, have); return; }
    double dm = bmove(M.subj, M.nsubj, S.vis);
    M.t_react_done = mon_t();
    LOG("[react] PREEMPT (%s): moved %d window(s) to visible (%.1fms)", why, M.nsubj, dm);
}

static void mon_on_activate(pid_t pid, const char *src, int bit) {
    if (!M.on || pid != M.app || !(M.preempt_mask & bit)) return;
    if ((M.react == R_PREEMPT || M.react == R_HYBRID) && !M.reacted) do_preempt(src);
}

static void mon_on_switch_seen(const char *src, int level) {
    if (!M.on || level < M.bounce_level || M.bounced) return;
    if (M.bounce_delay_ms > 0) {
        if (!M.bounce_at) {
            M.bounce_at = now_ns() + (uint64_t)M.bounce_delay_ms * 1000000ull;
            snprintf(M.why, sizeof M.why, "%s, +%dms delay", src, M.bounce_delay_ms);
            LOG("[react] bounce scheduled in %dms (%s)", M.bounce_delay_ms, src);
        }
        return;
    }
    if (M.react == R_BOUNCE || M.react == R_BOUNCE_LATE) do_bounce(src);
    else if (M.react == R_HYBRID && M.reacted) do_bounce(src);
}

static void mon_poll(void) {
    @autoreleasepool {
        uint64_t cur = display_current();
        if (cur != M.cur) {
            LOG("[poll] current space %llu -> %llu", M.cur, cur);
            M.cur = cur;
            if (cur == S.stash) FIRST(t_cur_stash);
        }
        pid_t fp = front_pid();
        if (fp != M.front) {
            LOG("[poll] front process %s(%d) -> %s(%d)", app_name(M.front), M.front, app_name(fp), fp);
            M.front = fp;
            if (fp == M.app) FIRST(t_front);
        }
        bool ex[MAXW], on[MAXW];
        cg_query(M.sprobe, M.nsprobe, ex, on, NULL);
        bool sprobe_on = false;
        for (int i = 0; i < M.nsprobe; i++) sprobe_on |= on[i];
        cg_query(M.vprobe, M.nvprobe, ex, on, NULL);
        bool vis_off = M.nvprobe > 0;
        for (int i = 0; i < M.nvprobe; i++) vis_off &= !on[i];
        cg_query(M.subj, M.nsubj, ex, on, NULL);
        bool subj_stash_on = false;
        for (int i = 0; i < M.nsubj; i++) if (on[i] && on_space(M.subj[i], S.stash)) subj_stash_on = true;
        bool shown = cur == S.stash || sprobe_on || subj_stash_on;
        if (shown != M.shown) {
            LOG("[poll] stash shown %d -> %d (cur=%llu stash_probe_onscreen=%d stashed_subject_onscreen=%d)", M.shown, shown,
                cur, sprobe_on, subj_stash_on);
            if (shown) {
                FIRST(t_shown);
                M.nshown++;
                M.shown_since = now_ns();
            } else {
                M.t_unshown = mon_t();
                M.shown_ms += ms_since(M.shown_since);
            }
            M.shown = shown;
        }
        if (vis_off != M.vis_off) {
            LOG("[poll] all visible-desktop probes offscreen %d -> %d", M.vis_off, vis_off);
            if (vis_off) FIRST(t_vis_off);
            M.vis_off = vis_off;
        }
        if (M.t_bounce >= 0 && M.t_back < 0 && !shown && cur == S.vis) M.t_back = mon_t();
        if (M.bounce_at && !M.bounced && now_ns() >= M.bounce_at) do_bounce(M.why);
        if (shown) mon_on_switch_seen(cur == S.stash ? "poll: current==stash" : "poll: stash windows onscreen",
                                      cur == S.stash ? 1 : 0);
        if (fp == M.app && M.app > 0) mon_on_activate(fp, "poll: front process", SRC_POLL);
    }
}

static void mon_stop(void) {
    if (M.shown) M.shown_ms += ms_since(M.shown_since);
    LOG("[mon] stop");
    M.on = false;
}

static bool g_nsevents;

// One run loop slice. With g_nsevents, drains NSEvents the way [NSApp run] does,
// which AppKit needs to turn window-server space changes into notifications.
static void run_slice(double secs) {
    if (!g_nsevents) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, true);
        return;
    }
    NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:secs]
                                       inMode:NSDefaultRunLoopMode dequeue:YES];
    if (e) [NSApp sendEvent:e];
}

static void pump(int ms) {
    uint64_t end = now_ns() + (uint64_t)ms * 1000000ull;
    do {
        @autoreleasepool {
            run_slice(0.001);
            if (g_child > 0) {
                int st;
                if (waitpid(g_child, &st, WNOHANG) == g_child) {
                    LOG("[spawn] pid %d exited %d", g_child, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
                    g_child = 0;
                }
            }
            if (M.on) mon_poll();
        }
    } while (now_ns() < end);
}

// Polls until every window is on `sid`; returns ms or -1.
static double wait_spaces(const uint32_t *wids, int n, uint64_t sid, int timeout_ms) {
    uint64_t t = now_ns(), end = t + (uint64_t)timeout_ms * 1000000ull;
    for (;;) {
        bool all = true;
        for (int i = 0; i < n && all; i++) all = on_space(wids[i], sid);
        if (all) return ms_since(t);
        if (now_ns() > end) return -1;
        run_slice(0.0005);
    }
}

// ---------------------------------------------------------------- notifications

static AXObserverRef g_obs[16];
static pid_t g_obs_pid[16];
static int g_nobs;

static void ax_cb(AXObserverRef obs, AXUIElementRef el, CFStringRef notif, void *refcon) {
    pid_t pid = 0;
    AXUIElementGetPid(el, &pid);
    uint32_t wid = (uint32_t)(uintptr_t)refcon;
    uint32_t elw = ax_wid(el);
    NSString *n = (__bridge NSString *)notif;
    LOG("[ax] %s pid=%d(%s) registered_wid=%u element_wid=%u", n.UTF8String, pid, app_name(pid), wid, elw);
    if (!M.on || pid != M.app) return;
    if ([n isEqualToString:(id)kAXApplicationActivatedNotification]) {
        FIRST(t_ax_act);
        mon_on_activate(pid, "ax: AXApplicationActivated", SRC_AX);
    } else if ([n isEqualToString:(id)kAXFocusedWindowChangedNotification]) {
        FIRST(t_ax_focus);
    } else if ([n isEqualToString:(id)kAXMainWindowChangedNotification]) {
        FIRST(t_ax_main);
    }
}

static AXObserverRef obs_for(pid_t pid) {
    for (int i = 0; i < g_nobs; i++) if (g_obs_pid[i] == pid) return g_obs[i];
    AXObserverRef o = NULL;
    if (AXObserverCreate(pid, ax_cb, &o) != kAXErrorSuccess || g_nobs >= 16) return NULL;
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), kCFRunLoopDefaultMode);
    g_obs[g_nobs] = o;
    g_obs_pid[g_nobs++] = pid;
    return o;
}

static void observe_app(pid_t pid) {
    static pid_t done[8];
    static int ndone;
    for (int i = 0; i < ndone; i++) if (done[i] == pid) return;
    AXObserverRef o = obs_for(pid);
    if (!o) { LOG("AXObserverCreate(%d) failed", pid); return; }
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFStringRef ns[] = {kAXApplicationActivatedNotification, kAXFocusedWindowChangedNotification,
                        kAXMainWindowChangedNotification, kAXWindowCreatedNotification};
    for (int i = 0; i < 4; i++) {
        AXError e = AXObserverAddNotification(o, app, ns[i], NULL);
        if (e) LOG("AXObserverAddNotification(app %d, %s) err=%d", pid, [(__bridge NSString *)ns[i] UTF8String], e);
    }
    CFRelease(app);
    if (ndone < 8) done[ndone++] = pid;
}

static void observe_workspace(void) {
    NSNotificationCenter *nc = [NSWorkspace sharedWorkspace].notificationCenter;
    [nc addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
                    NSRunningApplication *a = n.userInfo[NSWorkspaceApplicationKey];
                    LOG("[ws] didActivateApplication %s(%d)", a.localizedName.UTF8String, a.processIdentifier);
                    if (M.on && a.processIdentifier == M.app) {
                        FIRST(t_ws_act);
                        mon_on_activate(a.processIdentifier, "ws: didActivateApplication", SRC_WS);
                    }
                }];
    [nc addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
                    uint64_t cur = display_current();
                    S.nspace_notifs++;
                    LOG("[ws] activeSpaceDidChange current=%llu (%s)", cur,
                        cur == S.vis ? "visible" : cur == S.stash ? "stash" : "other");
                    if (!M.on) return;
                    M.nspace++;
                    FIRST(t_ws_space);
                    if (cur == S.stash) mon_on_switch_seen("ws: activeSpaceDidChange + current==stash", 2);
                }];
}

// ---------------------------------------------------------------- test windows

typedef enum { K_TE, K_CHROME } Kind;
typedef struct {
    bool alive;
    Kind kind;
    uint32_t wid;
    pid_t pid;
    AXUIElementRef ax;
    char file[1024], token[96], label[24];
} TW;
static TW g_tw[MAXW];
static int g_ntw;

static const char *label_of(uint32_t wid) {
    for (int i = 0; i < g_ntw; i++) if (g_tw[i].wid == wid) return g_tw[i].label;
    static char b[8][64];
    static int k;
    char *o = b[k++ % 8];
    WinRec w = win_info(wid);
    snprintf(o, 64, "%s:%u", w.owner, wid);
    return o;
}

static pid_t te_pid(void) {
    NSArray *a = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"];
    return a.count ? [a.firstObject processIdentifier] : 0;
}

static bool tw_find_ax(TW *t, int timeout_ms) {
    uint64_t end = now_ns() + (uint64_t)timeout_ms * 1000000ull;
    while (now_ns() < end) {
        @autoreleasepool {
            pid_t pids[4];
            int np = 0;
            if (t->kind == K_TE) {
                pid_t p = te_pid();
                if (p) pids[np++] = p;
            } else {
                for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.google.Chrome"])
                    if (np < 4) pids[np++] = a.processIdentifier;
            }
            for (int k = 0; k < np; k++) {
                for (id el in ax_windows(pids[k], NULL)) {
                    NSString *title = ax_str((__bridge AXUIElementRef)el, kAXTitleAttribute, NULL);
                    if (![title containsString:@(t->token)]) continue;
                    uint32_t w = ax_wid((__bridge AXUIElementRef)el);
                    if (!w) continue;
                    t->wid = w;
                    t->pid = pids[k];
                    t->ax = (AXUIElementRef)CFRetain((__bridge CFTypeRef)el);
                    return true;
                }
            }
        }
        for (int k = 0; k < 100; k++) run_slice(0.001);
    }
    return false;
}

// Opens `n` TextEdit documents in one `open` call; fills `out` with registry indices.
static int te_open(int n, const char *prefix, int *out) {
    NSMutableArray *paths = [NSMutableArray array];
    int first = g_ntw;
    for (int i = 0; i < n && g_ntw < MAXW; i++) {
        TW *t = &g_tw[g_ntw++];
        memset(t, 0, sizeof *t);
        t->kind = K_TE;
        snprintf(t->token, sizeof t->token, "tilos-stash-%d-%02d", getpid(), ++S.seq);
        snprintf(t->label, sizeof t->label, "%s%d", prefix, i);
        snprintf(t->file, sizeof t->file, "%s/%s.txt", S.dir, t->token);
        NSString *body = [NSString stringWithFormat:@"tilos stash spike test window %s. Safe to close.\n", t->label];
        [body writeToFile:@(t->file) atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [paths addObject:@(t->file)];
    }
    const char *argv[MAXW + 5] = {"/usr/bin/open", "-g", "-a", "TextEdit"};
    int ac = 4;
    for (NSString *p in paths) argv[ac++] = p.UTF8String;
    argv[ac] = NULL;
    int rc = run_wait(argv);
    int found = 0;
    for (int i = first; i < g_ntw; i++) {
        TW *t = &g_tw[i];
        if (!tw_find_ax(t, 10000)) { LOG("open: %s (%s) not found via AX (open rc=%d)", t->label, t->token, rc); continue; }
        t->alive = true;
        if (out) out[found] = i;
        found++;
        WinRec w = win_info(t->wid);
        LOG("open: %s wid=%u pid=%d on %s frame=" RECT_FMT, t->label, t->wid, t->pid, where(t->wid), RECT_ARGS(w.bounds));
    }
    observe_app(te_pid());
    return found;
}

static void tw_wids(const int *idx, int n, uint32_t *out) {
    for (int i = 0; i < n; i++) out[i] = g_tw[idx[i]].wid;
}

static bool tw_close(int i) {
    TW *t = &g_tw[i];
    if (!t->alive) return true;
    if (!win_info(t->wid).ok) {
        LOG("close: %s wid=%u already gone", t->label, t->wid);
        t->alive = false;
        goto done;
    }
    if (!on_space(t->wid, S.vis)) {
        LOG("close: %s on %s; moving to visible first", t->label, where(t->wid));
        bmove(&t->wid, 1, S.vis);
        wait_spaces(&t->wid, 1, S.vis, 1000);
    }
    {
        AXUIElementRef w = t->ax ? (AXUIElementRef)CFRetain(t->ax) : ax_find(t->pid, t->wid);
        AXUIElementRef cb = w ? ax_child(w, kAXCloseButtonAttribute, NULL) : NULL;
        if (!cb && w) {
            CFRelease(w);
            w = ax_find(t->pid, t->wid);
            cb = w ? ax_child(w, kAXCloseButtonAttribute, NULL) : NULL;
        }
        if (w) CFRelease(w);
        if (!cb) { LOG("close: %s wid=%u has no AX close button", t->label, t->wid); return false; }
        AXError e = AXUIElementPerformAction(cb, kAXPressAction);
        CFRelease(cb);
        for (int k = 0; k < 150; k++) {
            if (!win_info(t->wid).ok) {
                t->alive = false;
                break;
            }
            pump(20);
        }
        LOG("close: %s wid=%u press err=%d gone=%d", t->label, t->wid, e, !t->alive);
        if (t->alive) return false;
    }
done:
    if (t->ax) { CFRelease(t->ax); t->ax = NULL; }
    if (t->file[0]) unlink(t->file);
    return true;
}

static void tw_close_all(void) {
    for (int i = 0; i < g_ntw; i++) tw_close(i);
}

// ---------------------------------------------------------------- focus helpers

typedef struct { AXError raise, main, foc; bool act; CGError sl[3]; } FocusRc;

static void ax_focus_triple(AXUIElementRef el, FocusRc *r) {
    r->raise = AXUIElementPerformAction(el, kAXRaiseAction);
    r->main = AXUIElementSetAttributeValue(el, kAXMainAttribute, kCFBooleanTrue);
    r->foc = AXUIElementSetAttributeValue(el, kAXFocusedAttribute, kCFBooleanTrue);
}

// HyprMac HyprWindow.focus(): AX triple, activate, SkyLight front + key records,
// AX re-assert 50ms later. Steps: bit0 AX triple, bit1 activate, bit2 SkyLight.
static FocusRc focus_steps(int i, int steps) {
    TW *t = &g_tw[i];
    FocusRc r = {.raise = -1, .main = -1, .foc = -1, .sl = {-1, -1, -1}};
    if (steps & 1) ax_focus_triple(t->ax, &r);
    if (steps & 2) r.act = app_activate(t->pid);
    if (steps & 4) slps_front_key(t->pid, t->wid, r.sl);
    if ((steps & 1) && (steps & 6)) {
        pump(50);
        FocusRc r2;
        ax_focus_triple(t->ax, &r2);
    }
    return r;
}

static void focus_full(int i) { focus_steps(i, 7); }

// Fronts the user's originally frontmost app and window (no move, no resize).
static bool front_restore(void) {
    if (S.front0 <= 0) return false;
    app_activate(S.front0);
    CGError rc[3];
    if (S.front0_wid) slps_front_key(S.front0, S.front0_wid, rc);
    for (int k = 0; k < 25; k++) {
        pump(20);
        if (front_pid() == S.front0) return true;
    }
    LOG("front_restore: front is %s(%d), wanted %s(%d)", app_name(front_pid()), front_pid(), S.front0_name, S.front0);
    return false;
}

static void ensure_visible_desktop(void) {
    if (display_current() != S.vis) {
        LOG("ensure_visible_desktop: current=%llu; instant switch back", display_current());
        bswitch(S.vis, S.stash);
        pump(300);
    }
}

static void tw_to(const int *idx, int n, uint64_t sid) {
    uint32_t w[MAXW];
    int k = 0;
    for (int i = 0; i < n; i++) if (g_tw[idx[i]].alive && !on_space(g_tw[idx[i]].wid, sid)) w[k++] = g_tw[idx[i]].wid;
    if (!k) return;
    bmove(w, k, sid);
    if (wait_spaces(w, k, sid, 1500) < 0) LOG("tw_to: not all of %d window(s) reached %llu", k, sid);
}

// ---------------------------------------------------------------- z-order

static NSString *zorder_str(void) {
    NSArray *arr = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &b);
        if (b.size.width < 60 || b.size.height < 60) continue;
        [a addObject:@(label_of([d[(id)kCGWindowNumber] unsignedIntValue]))];
    }
    return [a componentsJoinedByString:@" > "];
}

// ---------------------------------------------------------------- session setup / cleanup

static int real_te_windows(pid_t pid) {
    NSArray *arr = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    int n = 0;
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowOwnerPID] intValue] != pid || [d[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([d[(id)kCGWindowName] length]) n++;
    }
    return n + (int)ax_windows(pid, NULL).count;
}

static void session_cleanup(const char *why) {
    if (!S.active || S.cleaned) return;
    S.cleaned = true;
    M.on = false;
    LOG("cleanup (%s)", why);
    tw_close_all();
    pid_t tp = te_pid();
    if (!S.te_was_running && tp) {
        pump(300);
        int other = real_te_windows(tp);
        if (other == 0) {
            LOG("cleanup: TextEdit was not running before and has no windows; terminate=%d",
                [[NSRunningApplication runningApplicationWithProcessIdentifier:tp] terminate]);
            pump(1500);
        } else {
            LOG("cleanup: TextEdit has %d real window(s); leaving it running", other);
        }
    }
    ensure_visible_desktop();
    front_restore();
    ensure_visible_desktop();
    cursor_restore(S.cursor0);
    int left = 0;
    for (int i = 0; i < g_ntw; i++) left += g_tw[i].alive;
    CGPoint c = cursor_pos();
    NSString *order = topo_order();
    LOG("cleanup done: current=%llu (visible %llu) front=%s(%d) cursor=(%.0f,%.0f) saved=(%.0f,%.0f) test windows left=%d "
        "space order %s (start %s)",
        display_current(), S.vis, app_name(front_pid()), front_pid(), c.x, c.y, S.cursor0.x, S.cursor0.y, left,
        order.UTF8String, S.order0.UTF8String);
}

static void on_signal(int sig) {
    LOG("signal %d", sig);
    session_cleanup("signal");
    signal(sig, SIG_DFL);
    raise(sig);
}

static void at_exit(void) { session_cleanup("exit"); }

static bool screen_visible_frame(CGRect *out) {
    CGFloat primary_h = NSMaxY([NSScreen screens].firstObject.frame);
    for (NSScreen *s in [NSScreen screens]) {
        CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
        if (!u) continue;
        NSString *us = CFBridgingRelease(CFUUIDCreateString(NULL, u));
        CFRelease(u);
        if ([us caseInsensitiveCompare:@(S.uuid)] != NSOrderedSame) continue;
        NSRect v = s.visibleFrame;
        *out = CGRectMake(v.origin.x, primary_h - NSMaxY(v), v.size.width, v.size.height);
        return true;
    }
    return false;
}

static int session_init(bool need_ax) {
    if (need_ax && !AXIsProcessTrusted()) {
        printf("STOP: AXIsProcessTrusted() = false\n");
        return 2;
    }
    memset((void *)&S, 0, sizeof S);
    S.cursor0 = cursor_pos();
    S.te_was_running = te_pid() != 0;
    strlcpy(S.dir, [[[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent] UTF8String], sizeof S.dir);
    Topo t;
    topo_load(&t);
    int cd = 0;
    CFStringRef s = f_SLSCopyBestManagedDisplayForPoint(g_cid, S.cursor0);
    for (int i = 0; s && i < t.n; i++) if ([(__bridge NSString *)s isEqualToString:@(t.d[i].uuid)]) cd = i;
    if (s) CFRelease(s);
    strlcpy(S.uuid, t.d[cd].uuid, sizeof S.uuid);
    S.vis = t.d[cd].current;
    int vi = 0;
    topo_find(&t, S.vis, &vi);
    for (int j = vi + 1; j < t.d[cd].n && !S.stash; j++) if (t.d[cd].sp[j].type == 0) S.stash = t.d[cd].sp[j].sid;
    for (int j = vi - 1; j >= 0 && !S.stash; j--) if (t.d[cd].sp[j].type == 0) S.stash = t.d[cd].sp[j].sid;
    S.order0 = topo_order();
    int si = 0;
    topo_find(&t, S.stash, &si);
    g_hk_to_stash = si < vi ? HK_SPACE_LEFT : HK_SPACE_RIGHT;
    g_hk_to_vis = si < vi ? HK_SPACE_RIGHT : HK_SPACE_LEFT;
    S.front0 = front_pid();
    strlcpy(S.front0_name, app_name(S.front0), sizeof S.front0_name);
    S.front0_wid = ax_focused_wid(S.front0);
    if (!screen_visible_frame(&S.vf)) S.vf = CGRectMake(0, 40, 1600, 1000);
    printf("session: display=%s visible=%llu stash=%llu order=[%s] front=%s(%d) focused_wid=%u cursor=(%.0f,%.0f) "
           "visible_frame=" RECT_FMT " TextEdit_running_before=%d\n",
           S.uuid, S.vis, S.stash, S.order0.UTF8String, S.front0_name, S.front0, S.front0_wid, S.cursor0.x, S.cursor0.y,
           RECT_ARGS(S.vf), S.te_was_running);
    if (!S.stash) {
        printf("STOP: no second user desktop on this display; not creating Spaces\n");
        return 3;
    }
    if (!f_bridged_perform) {
        printf("STOP: SLSPerformAsynchronousBridgedWindowManagementOperation unresolved\n");
        return 3;
    }
    S.active = true;
    atexit(at_exit);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGSEGV, on_signal);
    signal(SIGBUS, on_signal);
    signal(SIGABRT, on_signal);
    observe_workspace();
    return 0;
}

static const char *yesno(bool b) { return b ? "yes" : "no"; }
static const char *ms_str(double v) {
    static char b[16][16];
    static int k;
    char *o = b[k++ % 16];
    if (v < 0) snprintf(o, 16, "-");
    else snprintf(o, 16, "%.1f", v);
    return o;
}

// ---------------------------------------------------------------- 1. round trip

// Stashes `subj` in one call and returns them in one call. `ref` (or -1) is a
// window that stays on the visible desktop and is raised before the return.
static void roundtrip(const int *subj, int n, int ref, const char *title) {
    printf("\n## %s\n", title);
    uint32_t w[MAXW];
    tw_wids(subj, n, w);
    ensure_visible_desktop();
    tw_to(subj, n, S.vis);
    focus_full(subj[0]);
    pump(400);
    pid_t app = g_tw[subj[0]].pid;
    CGRect f0[MAXW], f1[MAXW], f2[MAXW];
    bool ex[MAXW], on[MAXW];
    cg_query(w, n, ex, on, f0);
    pid_t front_before = front_pid();
    uint32_t focus_before = ax_focused_wid(app);
    NSString *z0 = zorder_str();
    LOG("before stash: front=%s(%d) %s focused=%s z: %s", app_name(front_before), front_before, label_of(focus_before),
        label_of(focus_before), z0.UTF8String);
    LOG("AX kAXWindows before: %s", ax_list_cstr(app));

    int notif0 = S.nspace_notifs;
    uint64_t cur0 = display_current();
    CGPoint c0 = cursor_pos();
    double t_call = bmove(w, n, S.stash);
    double t_moved = wait_spaces(w, n, S.stash, 2000);
    double t_moved_total = t_moved < 0 ? -1 : t_moved + t_call;
    pump(600);
    cg_query(w, n, ex, on, f1);
    bool any_on = false, frames_kept = true;
    for (int i = 0; i < n; i++) { any_on |= on[i]; frames_kept &= rect_eq(f0[i], f1[i]); }
    pid_t front_after = front_pid();
    uint32_t focus_after = ax_focused_wid(app);
    CGPoint c1 = cursor_pos();
    bool switched = display_current() != cur0 || S.nspace_notifs != notif0;
    LOG("stash: call=%.1fms all_on_stash=%sms onscreen_any=%d frames_kept=%d desk_switched=%d cursor_moved=%d front=%s(%d) "
        "app_focused=%s",
        t_call, ms_str(t_moved_total), any_on, frames_kept, switched, fabs(c1.x - c0.x) + fabs(c1.y - c0.y) > 0.5,
        app_name(front_after), front_after, label_of(focus_after));
    LOG("AX kAXWindows while stashed: %s", ax_list_cstr(app));

    if (ref >= 0) {
        AXUIElementPerformAction(g_tw[ref].ax, kAXRaiseAction);
        pump(200);
    }
    NSString *z1 = zorder_str();
    LOG("before return: front=%s z: %s", app_name(front_pid()), z1.UTF8String);

    // Return; write W0's frame immediately after the call returns.
    CGRect target = CGRectMake(S.vf.origin.x + 80, S.vf.origin.y + 60, 700, 480);
    notif0 = S.nspace_notifs;
    cur0 = display_current();
    double t_back_call = bmove(w, n, S.vis);
    uint64_t tw0 = now_ns();
    AXError ep, es;
    ax_set_frame(g_tw[subj[0]].ax, target, &ep, &es);
    double t_write = ms_since(tw0);
    CGRect rb;
    bool rok = ax_frame(g_tw[subj[0]].ax, &rb);
    bool spaces_at_write = on_space(w[0], S.vis);
    double t_back = wait_spaces(w, n, S.vis, 2000);
    double t_back_total = t_back < 0 ? -1 : t_back + t_back_call + t_write;
    // Second write after membership is confirmed (for comparison).
    CGRect target2 = CGRectMake(S.vf.origin.x + 820, S.vf.origin.y + 100, 640, 420);
    AXError ep2 = -1, es2 = -1;
    if (n > 1) ax_set_frame(g_tw[subj[1]].ax, target2, &ep2, &es2);
    pump(250);
    cg_query(w, n, ex, on, f2);
    bool all_on = true;
    for (int i = 0; i < n; i++) all_on &= on[i];
    bool kept_rest = true;
    for (int i = 2; i < n; i++) kept_rest &= rect_eq(f0[i], f2[i]);
    bool w0_landed = rect_eq(f2[0], target), w1_landed = n > 1 && rect_eq(f2[1], target2);
    bool switched2 = display_current() != cur0 || S.nspace_notifs != notif0;
    NSString *z2 = zorder_str();
    LOG("return: call=%.1fms all_on_visible=%sms all_onscreen=%d desk_switched=%d", t_back_call, ms_str(t_back_total), all_on,
        switched2);
    LOG("return: W0 AX write right after call: pos err=%d size err=%d (%.1fms), window already on visible at write=%d, "
        "AX readback ok=%d " RECT_FMT ", CG after 250ms " RECT_FMT " landed=%d",
        ep, es, t_write, spaces_at_write, rok, RECT_ARGS(rb), RECT_ARGS(f2[0]), w0_landed);
    if (n > 1)
        LOG("return: W1 AX write after membership confirmed: err=%d/%d CG " RECT_FMT " landed=%d", ep2, es2, RECT_ARGS(f2[1]),
            w1_landed);
    LOG("return: untouched windows kept frame=%d; front=%s(%d) app_focused=%s", kept_rest, app_name(front_pid()), front_pid(),
        label_of(ax_focused_wid(app)));
    LOG("after return z: %s", z2.UTF8String);
    LOG("AX kAXWindows after return: %s", ax_list_cstr(app));

    printf("\n| step | call ms | membership ms | desktop switched | frames kept | onscreen | notes |\n|---|---|---|---|---|---|---|\n");
    printf("| stash %d (one call) | %.1f | %s | %s | %s | any=%s | front before %s, after %s |\n", n, t_call,
           ms_str(t_moved_total), yesno(switched), yesno(frames_kept), yesno(any_on), app_name(front_before), app_name(front_after));
    printf("| return %d (one call) | %.1f | %s | %s | untouched=%s | all=%s | W0 AX write right after call: err %d/%d, "
           "landed=%s; post-confirm write landed=%s |\n",
           n, t_back_call, ms_str(t_back_total), yesno(switched2), yesno(kept_rest), yesno(all_on), ep, es, yesno(w0_landed),
           n > 1 ? yesno(w1_landed) : "n/a");
    printf("\nz-order front>back\n- before stash: %s\n- before return: %s\n- after return: %s\n", z0.UTF8String,
           z1.UTF8String, z2.UTF8String);
}

static int cmd_roundtrip(void) {
    int idx[4];
    if (te_open(4, "W", idx) < 4) return 1;
    snprintf(g_tw[idx[3]].label, sizeof g_tw[idx[3]].label, "R");
    roundtrip(idx, 3, idx[3], "1. round trip + layout (TextEdit, 3 stashed + 1 reference R)");
    return 0;
}

// ---------------------------------------------------------------- 2. AX handle while stashed

static int cmd_axstash(void) {
    printf("\n## 2. AX handle while stashed\n");
    int idx[2];
    if (te_open(2, "AX", idx) < 2) return 1;
    TW *a = &g_tw[idx[0]], *b = &g_tw[idx[1]];
    uint32_t w[2] = {a->wid, b->wid};
    CGRect f0;
    ax_frame(a->ax, &f0);
    bmove(w, 2, S.stash);
    if (wait_spaces(w, 2, S.stash, 2000) < 0) { LOG("stash failed"); return 1; }
    pump(200);
    AXError et, ep, es, er;
    NSString *title = ax_str(a->ax, kAXTitleAttribute, &et);
    NSString *role = ax_str(a->ax, kAXRoleAttribute, &er);
    CGPoint p = {0};
    CGSize sz = {0};
    ep = ax_get_pos(a->ax, &p);
    es = ax_get_size(a->ax, &sz);
    LOG("stashed read: title err=%d '%s' role err=%d %s pos err=%d (%.0f,%.0f) size err=%d %.0fx%.0f (pre-stash " RECT_FMT ")",
        et, title.UTF8String, er, role.UTF8String, ep, p.x, p.y, es, sz.width, sz.height, RECT_ARGS(f0));
    CGRect target = CGRectMake(S.vf.origin.x + 200, S.vf.origin.y + 150, 600, 400);
    AXError wp, ws;
    uint64_t t = now_ns();
    ax_set_frame(a->ax, target, &wp, &ws);
    double tw = ms_since(t);
    pump(200);
    CGRect rb;
    bool rok = ax_frame(a->ax, &rb);
    WinRec cg = win_info(a->wid);
    LOG("stashed write: pos err=%d size err=%d (%.1fms); AX readback ok=%d " RECT_FMT "; CG bounds " RECT_FMT
        " onscreen=%d on %s",
        wp, ws, tw, rok, RECT_ARGS(rb), RECT_ARGS(cg.bounds), cg.onscreen, where(a->wid));
    bool cg_landed_stashed = rect_eq(cg.bounds, target);
    bmove(&a->wid, 1, S.vis);
    double tb = wait_spaces(&a->wid, 1, S.vis, 2000);
    pump(250);
    CGRect after;
    ax_frame(a->ax, &after);
    WinRec cg2 = win_info(a->wid);
    bool kept = rect_eq(cg2.bounds, target);
    LOG("after return (%sms): AX " RECT_FMT " CG " RECT_FMT " onscreen=%d -> stashed write still in effect=%d", ms_str(tb),
        RECT_ARGS(after), RECT_ARGS(cg2.bounds), cg2.onscreen, kept);

    // Close button of the stashed window B, via the pre-stash handle.
    AXError ec;
    AXUIElementRef cb = ax_child(b->ax, kAXCloseButtonAttribute, &ec);
    AXError epress = -1;
    double gone_ms = -1;
    int notif0 = S.nspace_notifs;
    uint64_t cur0 = display_current();
    if (cb) {
        uint64_t t1 = now_ns();
        epress = AXUIElementPerformAction(cb, kAXPressAction);
        CFRelease(cb);
        for (int k = 0; k < 200; k++) {
            if (!win_info(b->wid).ok) { gone_ms = ms_since(t1); break; }
            pump(10);
        }
    }
    bool switched = display_current() != cur0 || S.nspace_notifs != notif0;
    LOG("stashed close: close button err=%d press err=%d gone_from_CG=%sms desk_switched=%d", ec, epress, ms_str(gone_ms), switched);
    if (gone_ms >= 0) { b->alive = false; unlink(b->file); }

    printf("\n| check (pre-stash AXUIElementRef) | AX err | result |\n|---|---|---|\n");
    printf("| read title while stashed | %d | '%s' |\n", et, title.UTF8String ?: "");
    printf("| read position/size while stashed | %d/%d | (%.0f,%.0f %.0fx%.0f) vs pre-stash " RECT_FMT " |\n", ep, es, p.x,
           p.y, sz.width, sz.height, RECT_ARGS(f0));
    printf("| write position/size while stashed | %d/%d | AX readback " RECT_FMT ", CG while stashed " RECT_FMT " landed=%s |\n",
           wp, ws, RECT_ARGS(rb), RECT_ARGS(cg.bounds), yesno(cg_landed_stashed));
    printf("| frame after unstash | - | CG " RECT_FMT " still in effect=%s |\n", RECT_ARGS(cg2.bounds), yesno(kept));
    printf("| AXPress close button while stashed | %d/%d | window gone in %s ms, desktop switched=%s |\n", ec, epress,
           ms_str(gone_ms), yesno(switched));
    return 0;
}

// ---------------------------------------------------------------- 3. notifications while stashed

static struct { double t_destroy[MAXW], t_title[MAXW], t_moved[MAXW], t_created; uint64_t t0; uint32_t created_wid; } N;

static void n_cb(AXObserverRef obs, AXUIElementRef el, CFStringRef notif, void *refcon) {
    uint32_t wid = (uint32_t)(uintptr_t)refcon;
    NSString *n = (__bridge NSString *)notif;
    int i = -1;
    for (int k = 0; k < g_ntw; k++) if (g_tw[k].wid == wid) i = k;
    double t = ms_since(N.t0);
    LOG("[ax3] %s wid=%u element_wid=%u (t=%.1fms since last action)", n.UTF8String, wid, ax_wid(el), t);
    if ([n isEqualToString:(id)kAXUIElementDestroyedNotification] && i >= 0 && N.t_destroy[i] < 0) N.t_destroy[i] = t;
    if ([n isEqualToString:(id)kAXTitleChangedNotification] && i >= 0 && N.t_title[i] < 0) N.t_title[i] = t;
    if ([n isEqualToString:(id)kAXWindowMovedNotification] && i >= 0 && N.t_moved[i] < 0) N.t_moved[i] = t;
    if ([n isEqualToString:(id)kAXWindowCreatedNotification] && N.t_created < 0) { N.t_created = t; N.created_wid = ax_wid(el); }
}

static int cmd_notify(void) {
    printf("\n## 3. notifications while stashed\n");
    int idx[2];
    if (te_open(2, "N", idx) < 2) return 1;
    for (int i = 0; i < MAXW; i++) N.t_destroy[i] = N.t_title[i] = N.t_moved[i] = -1;
    N.t_created = -1;
    pid_t pid = g_tw[idx[0]].pid;
    AXObserverRef o = NULL;
    AXObserverCreate(pid, n_cb, &o);
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), kCFRunLoopDefaultMode);
    for (int k = 0; k < 2; k++) {
        TW *t = &g_tw[idx[k]];
        CFStringRef ns[] = {kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMovedNotification};
        for (int j = 0; j < 3; j++) {
            AXError e = AXObserverAddNotification(o, t->ax, ns[j], (void *)(uintptr_t)t->wid);
            if (e) LOG("add %s on %s err=%d", [(__bridge NSString *)ns[j] UTF8String], t->label, e);
        }
    }
    AXUIElementRef appel = AXUIElementCreateApplication(pid);
    AXError eapp = AXObserverAddNotification(o, appel, kAXWindowCreatedNotification, (void *)0);
    LOG("observers registered (app-level created err=%d)", eapp);
    uint32_t w[2] = {g_tw[idx[0]].wid, g_tw[idx[1]].wid};
    bmove(w, 2, S.stash);
    wait_spaces(w, 2, S.stash, 2000);
    pump(500);
    for (int i = 0; i < MAXW; i++) N.t_moved[i] = N.t_title[i] = -1;  // ignore anything fired by the stash itself

    TW *a = &g_tw[idx[0]], *b = &g_tw[idx[1]];
    // (a) AX move while stashed.
    CGPoint p;
    ax_get_pos(a->ax, &p);
    N.t0 = now_ns();
    AXError em = ax_set_pos(a->ax, CGPointMake(p.x + 40, p.y + 30));
    pump(800);
    LOG("(a) AX position write while stashed err=%d -> moved notification %sms", em, ms_str(N.t_moved[idx[0]]));

    // (b) Title change while stashed: rename the backing file (TextEdit follows renames).
    char newpath[1100];
    snprintf(newpath, sizeof newpath, "%s/%s-renamed.txt", S.dir, a->token);
    N.t0 = now_ns();
    int rr = rename(a->file, newpath);
    if (!rr) strlcpy(a->file, newpath, sizeof a->file);
    pump(2500);
    NSString *nt = ax_str(a->ax, kAXTitleAttribute, NULL);
    LOG("(b) rename file rc=%d -> title notification %sms, AX title now '%s'", rr, ms_str(N.t_title[idx[0]]), nt.UTF8String);

    // (c) New window of the same app while its other windows sit in the stash.
    int notif0 = S.nspace_notifs;
    uint64_t cur0 = display_current();
    N.t0 = now_ns();
    int cidx[1];
    int got = te_open(1, "NC", cidx);
    pump(300);
    bool switched_c = display_current() != cur0 || S.nspace_notifs != notif0;
    LOG("(c) new TextEdit window while others stashed: created notification %sms (wid=%u) new window on %s desk_switched=%d",
        ms_str(N.t_created), N.created_wid, got ? where(g_tw[cidx[0]].wid) : "?", switched_c);
    if (got) tw_close(cidx[0]);

    // (d) Close A while stashed via AX close button.
    AXUIElementRef cb = ax_child(a->ax, kAXCloseButtonAttribute, NULL);
    N.t0 = now_ns();
    AXError ep = cb ? AXUIElementPerformAction(cb, kAXPressAction) : -1;
    if (cb) CFRelease(cb);
    double cg_gone_a = -1;
    for (int k = 0; k < 300 && (cg_gone_a < 0 || N.t_destroy[idx[0]] < 0); k++) {
        if (cg_gone_a < 0 && !win_info(a->wid).ok) cg_gone_a = ms_since(N.t0);
        pump(5);
    }
    LOG("(d) AX close while stashed: press err=%d destroyed notification %sms CG gone %sms", ep, ms_str(N.t_destroy[idx[0]]),
        ms_str(cg_gone_a));
    if (cg_gone_a >= 0) { a->alive = false; unlink(a->file); }

    // (e) Close B while stashed via AppleScript if Automation is already granted; else AX.
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:@"com.apple.TextEdit"];
    OSStatus perm = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false);
    const char *how;
    double cg_gone_b = -1;
    int osa_rc = -99;
    N.t0 = now_ns();
    if (perm == noErr) {
        how = "AppleScript";
        char script[512];
        snprintf(script, sizeof script, "tell application \"TextEdit\" to close document \"%s.txt\" saving no", b->token);
        const char *argv[] = {"/usr/bin/osascript", "-e", script, NULL};
        g_child = spawn_argv(argv);
        osa_rc = 0;
    } else {
        how = "AX close (AppleScript skipped: Automation not pre-authorized)";
        AXUIElementRef cb2 = ax_child(b->ax, kAXCloseButtonAttribute, NULL);
        if (cb2) { AXUIElementPerformAction(cb2, kAXPressAction); CFRelease(cb2); }
    }
    for (int k = 0; k < 600 && (cg_gone_b < 0 || N.t_destroy[idx[1]] < 0); k++) {
        if (cg_gone_b < 0 && !win_info(b->wid).ok) cg_gone_b = ms_since(N.t0);
        pump(5);
    }
    LOG("(e) close B via %s (AEDeterminePermission=%d): destroyed notification %sms CG gone %sms", how, (int)perm,
        ms_str(N.t_destroy[idx[1]]), ms_str(cg_gone_b));
    if (cg_gone_b >= 0) { b->alive = false; unlink(b->file); }
    (void)osa_rc;
    CFRelease(appel);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), kCFRunLoopDefaultMode);
    CFRelease(o);

    printf("\n| event while stashed | trigger | notification | latency ms | CG agrees |\n|---|---|---|---|---|\n");
    printf("| AX position write | err %d | kAXWindowMoved | %s | - |\n", em, ms_str(N.t_moved[idx[0]]));
    printf("| backing file renamed | rename rc %d | kAXTitleChanged | %s | AX title '%s' |\n", rr, ms_str(N.t_title[idx[0]]),
           nt.UTF8String ?: "");
    printf("| new window of same app (open -g) | - | kAXWindowCreated (app) | %s | new window on %s, desktop switched=%s |\n",
           ms_str(N.t_created), got ? "visible (see log)" : "?", yesno(switched_c));
    printf("| AX close button press | err %d | kAXUIElementDestroyed | %s | CG gone %s ms |\n", ep,
           ms_str(N.t_destroy[idx[0]]), ms_str(cg_gone_a));
    printf("| close via %s | perm %d | kAXUIElementDestroyed | %s | CG gone %s ms |\n", perm == noErr ? "AppleScript" : "AX",
           (int)perm, ms_str(N.t_destroy[idx[1]]), ms_str(cg_gone_b));
    return 0;
}

// ---------------------------------------------------------------- 4. activation

static bool dock_probe(void);
typedef enum { A_CMDTAB, A_ACTIVATE, A_OPEN } AMethod;
static const char *am_name[] = {"cmd-tab", "activateWithOptions", "open -a"};

typedef struct {
    char label[64];
    Mon m;
    bool activated, switched, act_ret;
    uint64_t final_cur;
    pid_t front_end;
    char subj_where[32];
    bool order_changed, subj_focused, probed, desynced;
} ARes;

static ARes g_ares[64];
static int g_nares;

// subject is stashed before the trigger; `other` (or -1) stays visible.
static ARes act_run(int subj, int other, bool stashed_was_main, AMethod m, React r, const char *open_name, const char *tag) {
    ARes res = {0};
    snprintf(res.label, sizeof res.label, "%s%s / %s", tag, am_name[m], react_name[r]);
    printf("\n### %s\n", res.label);
    TW *t = &g_tw[subj];
    ensure_visible_desktop();
    int both[2] = {subj, other};
    tw_to(both, other >= 0 ? 2 : 1, S.vis);
    if (other >= 0) {
        focus_full(stashed_was_main ? other : subj);
        pump(250);
        focus_full(stashed_was_main ? subj : other);
    } else {
        focus_full(subj);
    }
    pump(350);
    if (front_pid() != t->pid) LOG("prime: subject app not front after focus (front=%s)", app_name(front_pid()));
    front_restore();
    pump(300);
    LOG("prime: front=%s(%d) app main/focused=%s", app_name(front_pid()), front_pid(), label_of(ax_focused_wid(t->pid)));
    bmove(&t->wid, 1, S.stash);
    wait_spaces(&t->wid, 1, S.stash, 1500);
    pump(300);
    LOG("pre-trigger: subject on %s, app windows on visible=%d, current=%llu", where(t->wid), app_windows_on(t->pid, S.vis),
        display_current());
    NSString *order_before = topo_order();
    mon_start(r, t->pid, &t->wid, 1);
    switch (m) {
    case A_CMDTAB:
        cmd_tab();
        M.t0 = now_ns();
        LOG("trigger: synthesized Cmd-Tab (t0 = Cmd up)");
        break;
    case A_ACTIVATE:
        res.act_ret = app_activate(t->pid);
        LOG("trigger: activateWithOptions(IgnoringOtherApps) returned %d", res.act_ret);
        break;
    case A_OPEN: {
        const char *argv[] = {"/usr/bin/open", "-a", open_name, NULL};
        g_child = spawn_argv(argv);
        LOG("trigger: spawned open -a %s", open_name);
        break;
    }
    }
    pump(2500);
    mon_stop();
    res.m = M;
    res.final_cur = display_current();
    res.front_end = front_pid();
    res.activated = M.t_front >= 0 || M.t_ws_act >= 0 || M.t_ax_act >= 0;
    res.switched = M.nshown > 0 || M.t_cur_stash >= 0;
    snprintf(res.subj_where, sizeof res.subj_where, "%s", where(t->wid));
    res.subj_focused = res.front_end == t->pid && ax_focused_wid(t->pid) == t->wid;
    res.order_changed = ![topo_order() isEqualToString:order_before];
    LOG("result: activated=%d switched_to_stash=%d stash_shown_total=%.1fms final_current=%llu front_end=%s subject_on=%s "
        "subject_focused=%d space_order_changed=%d preempt_src='%s' bounce_src='%s'",
        res.activated, res.switched, M.shown_ms, res.final_cur, app_name(res.front_end), res.subj_where, res.subj_focused,
        res.order_changed, M.preempt_src, M.bounce_src);
    ensure_visible_desktop();
    tw_to(&subj, 1, S.vis);
    front_restore();
    pump(400);
    if (res.m.bounced) {
        res.probed = true;
        res.desynced = dock_probe();
        front_restore();
    }
    if (g_nares < 64) g_ares[g_nares++] = res;
    return res;
}

static void print_ares(int from) {
    printf("\n| run | activated | switched | ws didActivate | ax AppActivated | front=app | stash shown first | cur==stash | "
           "ws spaceChange | reaction start | reaction done | stash hidden again | stash visible total ms | final | subject | "
           "subject focused | Dock desynced after |\n"
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n");
    for (int i = from; i < g_nares; i++) {
        ARes *r = &g_ares[i];
        double rs = r->m.t_bounce >= 0 ? r->m.t_bounce : r->m.t_react;
        double rd = r->m.t_bounce_done >= 0 ? r->m.t_bounce_done : r->m.t_react_done;
        printf("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %.1f | %s | %s | %s | %s |\n", r->label, yesno(r->activated),
               yesno(r->switched), ms_str(r->m.t_ws_act), ms_str(r->m.t_ax_act), ms_str(r->m.t_front), ms_str(r->m.t_shown),
               ms_str(r->m.t_cur_stash), ms_str(r->m.t_ws_space), ms_str(rs), ms_str(rd),
               ms_str(r->m.t_unshown), r->m.shown_ms,
               r->final_cur == S.vis ? "visible" : r->final_cur == S.stash ? "STASH" : "other", r->subj_where,
               yesno(r->subj_focused), r->probed ? yesno(r->desynced) : "-");
    }
    printf("(times are ms after the trigger; '-' = never)\n");
}

static bool parse_has(const char *list, const char *tok) {
    if (!list || !*list) return true;
    return [[@(list) componentsSeparatedByString:@","] containsObject:@(tok)];
}

// Default schedule: per method one baseline, one early and two late bounces, and
// repeated event-driven preemption (cmd-tab is the tight race, so more reps).
static void activation_suite(int subj, int other, const char *open_name, const char *methods, const char *reacts,
                             bool mixed, const char *tag) {
    int from = g_nares;
    const char *mt[] = {"cmdtab", "activate", "open"};
    for (int m = 0; m < 3 && !mixed; m++) {
        if (!parse_has(methods, mt[m])) continue;
        int prep = getenv("STASH_PREEMPT_REPS") ? atoi(getenv("STASH_PREEMPT_REPS")) : (m == A_CMDTAB ? 6 : 3);
        int reps[] = {1, 1, 2, prep, 0};
        bool preempt_failed = false;
        for (int r = 0; r <= R_PREEMPT; r++) {
            if (!parse_has(reacts, react_name[r])) continue;
            for (int k = 0; k < reps[r]; k++) {
                ARes a = act_run(subj, -1, false, (AMethod)m, (React)r, open_name, tag);
                if (r == R_PREEMPT && a.switched) preempt_failed = true;
            }
        }
        if ((reacts && strstr(reacts, "hybrid")) || preempt_failed)
            for (int k = 0; k < 2; k++) act_run(subj, -1, false, (AMethod)m, R_HYBRID, open_name, tag);
    }
    if (mixed && other >= 0) {
        for (int m = 0; m < 3; m++) {
            if (!parse_has(methods, mt[m])) continue;
            char tg[48];
            snprintf(tg, sizeof tg, "%smixed(stashed was main) ", tag);
            act_run(subj, other, true, (AMethod)m, R_NONE, open_name, tg);
        }
        char tg[48];
        snprintf(tg, sizeof tg, "%smixed(visible was main) ", tag);
        act_run(subj, other, false, A_ACTIVATE, R_NONE, open_name, tg);
    }
    print_ares(from);
}

static int cmd_activate(const char *methods, const char *reacts) {
    printf("\n## 4. activation with the app's only window in the stash (TextEdit)\n");
    int idx[2];
    if (te_open(1, "A", idx) < 1) return 1;
    observe_app(g_tw[idx[0]].pid);
    activation_suite(idx[0], -1, "TextEdit", methods, reacts, false, "");
    int v[1];
    if (te_open(1, "V", v) < 1) return 1;
    printf("\n## 4b. TextEdit with one window visible (V) and one stashed (A)\n");
    activation_suite(idx[0], v[0], "TextEdit", methods, "", true, "");
    return 0;
}

// ---------------------------------------------------------------- 5. navigate into stash

// After a bounce, posts the hotkey pointing from the stash to the visible desktop.
// If the Dock still believes the stash is current, it animates (stash windows go
// on screen) and thereby re-syncs; if in sync, the key is a no-op at the edge.
// Only meaningful with two desktops where visible is at an edge.
static bool dock_probe(void) {
    pump(400);
    mon_start(R_NONE, -1, NULL, 0);
    char err[128] = "";
    hk_post(g_hk_to_vis, err, sizeof err);
    M.t0 = now_ns();
    pump(1500);
    mon_stop();
    bool desynced = M.nshown > 0;
    LOG("dock probe (hotkey %d toward visible): dock was %s", g_hk_to_vis, desynced ? "DESYNCED (believed stash; now re-synced)" : "in sync");
    if (desynced) pump(400);
    ensure_visible_desktop();
    return desynced;
}

static CFMachPortRef g_tap;
static int g_tap_swallowed;

static CGEventRef tap_cb(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return e;
    }
    CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    CGEventFlags f = CGEventGetFlags(e);
    bool toward = (g_hk_to_stash == HK_SPACE_LEFT && kc == 123) || (g_hk_to_stash == HK_SPACE_RIGHT && kc == 124);
    if (toward && (f & kCGEventFlagMaskControl) && !(f & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate))) {
        g_tap_swallowed++;
        LOG("[tap] swallowed %s keycode %u flags 0x%llx", type == kCGEventKeyDown ? "keyDown" : "keyUp", kc, (unsigned long long)f);
        return NULL;
    }
    return e;
}

typedef struct { char spec[24]; Mon m; bool desynced, probed; int swallowed; } NavRes;

static int cmd_navigate(const char *which) {
    printf("\n## 5. user navigates into the stash with ctrl+fn+arrow\n");
    int idx[1];
    if (te_open(1, "P", idx) < 1) return 1;
    bmove(&g_tw[idx[0]].wid, 1, S.stash);
    wait_spaces(&g_tw[idx[0]].wid, 1, S.stash, 1500);
    CGPoint c0 = cursor_pos();
    NSArray *specs = [@(which ?: "early,late,notify,notify+150,tap") componentsSeparatedByString:@","];
    NavRes res[16];
    int nr = 0;
    for (NSString *sp in specs) {
        if (nr >= 16) break;
        NavRes *r = &res[nr++];
        memset(r, 0, sizeof *r);
        strlcpy(r->spec, sp.UTF8String, sizeof r->spec);
        printf("\n### %s\n", r->spec);
        ensure_visible_desktop();
        pump(600);
        bool tap = [sp isEqualToString:@"tap"];
        if (tap) {
            g_tap_swallowed = 0;
            g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                     CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp), tap_cb, NULL);
            if (!g_tap) { LOG("CGEventTapCreate failed"); nr--; continue; }
            CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
            CFRelease(src);
            CGEventTapEnable(g_tap, true);
            LOG("active session event tap installed: swallows ctrl+arrow toward the stash");
        }
        mon_start(tap ? R_BOUNCE_LATE : R_BOUNCE, 0, NULL, 0);
        if ([sp hasPrefix:@"early"]) M.bounce_level = 0;
        else if ([sp hasPrefix:@"late"]) M.bounce_level = 1;
        else M.bounce_level = 2;
        NSRange plus = [sp rangeOfString:@"+"];
        if (plus.location != NSNotFound) M.bounce_delay_ms = [[sp substringFromIndex:plus.location + 1] intValue];
        char err[128] = "";
        if (!hk_post(g_hk_to_stash, err, sizeof err)) { LOG("hotkey failed: %s", err); mon_stop(); return 1; }
        M.t0 = now_ns();
        LOG("posted %s a space (hotkey %d)", g_hk_to_stash == HK_SPACE_LEFT ? "left" : "right", g_hk_to_stash);
        pump(2500);
        mon_stop();
        r->m = M;
        if (tap) {
            r->swallowed = g_tap_swallowed;
            CGEventTapEnable(g_tap, false);
            CFMachPortInvalidate(g_tap);
            CFRelease(g_tap);
            g_tap = NULL;
        }
        LOG("result: bounced=%d (%s) final current=%llu stash shown total %.1fms", M.bounced, M.bounce_src, M.cur, M.shown_ms);
        ensure_visible_desktop();
        if (M.bounced || M.nshown) {
            r->probed = true;
            r->desynced = dock_probe();
        }
    }
    cursor_restore(c0);
    printf("\n| run | stash shown first | cur==stash | ws spaceChange | bounce start | bounce done | stash hidden again | "
           "stash visible total ms | final | Dock desynced after | tap swallowed |\n|---|---|---|---|---|---|---|---|---|---|---|\n");
    for (int k = 0; k < nr; k++) {
        Mon *m = &res[k].m;
        printf("| %s | %s | %s | %s | %s | %s | %s | %.1f | %s | %s | %d |\n", res[k].spec, ms_str(m->t_shown),
               ms_str(m->t_cur_stash), ms_str(m->t_ws_space), ms_str(m->t_bounce), ms_str(m->t_bounce_done),
               ms_str(m->t_unshown), m->shown_ms, m->cur == S.vis ? "visible" : "STASH",
               res[k].probed ? yesno(res[k].desynced) : "-", res[k].swallowed);
    }
    printf("(ms after the key event; early = bounce when stash windows first go on screen, late = current==stash, "
           "notify = activeSpaceDidChange, +N = delay)\n");
    return 0;
}

// ---------------------------------------------------------------- 6. page flip

typedef enum { F_HIDE_FIRST, F_SHOW_FIRST, F_PRELAYOUT } FlipMode;
static const char *flip_name[] = {"hide-first", "show-first", "pre-layout while stashed, then hide-first"};

static void layout_rects(int n, int variant, CGRect *out) {
    CGRect v = S.vf;
    CGRect cells[4];
    if (n <= 2) {
        cells[0] = CGRectMake(v.origin.x, v.origin.y, floor(v.size.width / 2), v.size.height);
        cells[1] = CGRectMake(v.origin.x + floor(v.size.width / 2), v.origin.y, v.size.width - floor(v.size.width / 2), v.size.height);
    } else {
        CGFloat hw = floor(v.size.width / 2), hh = floor(v.size.height / 2);
        cells[0] = CGRectMake(v.origin.x, v.origin.y, hw, hh);
        cells[1] = CGRectMake(v.origin.x + hw, v.origin.y, v.size.width - hw, hh);
        cells[2] = CGRectMake(v.origin.x, v.origin.y + hh, hw, v.size.height - hh);
        cells[3] = CGRectMake(v.origin.x + hw, v.origin.y + hh, v.size.width - hw, v.size.height - hh);
    }
    for (int i = 0; i < n; i++) out[i] = cells[(i + variant) % n];
}

typedef struct { char label[80]; double t1, t2, t_ax, t_settled; int ax_err, notifs; bool switched, settled; char front[64]; } FlipRes;

static FlipRes flip(const int *A, const int *B, int n, FlipMode mode, int variant) {
    FlipRes r = {0};
    uint32_t wa[8], wb[8];
    tw_wids(A, n, wa);
    tw_wids(B, n, wb);
    CGRect tgt[8];
    layout_rects(n, variant, tgt);
    int notif0 = S.nspace_notifs;
    uint64_t cur0 = display_current();
    uint64_t t0 = now_ns();
    if (mode == F_PRELAYOUT) {
        for (int i = 0; i < n; i++) {
            AXError a, b;
            ax_set_frame(g_tw[B[i]].ax, tgt[i], &a, &b);
            r.ax_err |= a | b;
        }
        r.t_ax = ms_since(t0);
    }
    if (mode == F_SHOW_FIRST) {
        bmove(wb, n, S.vis);
        r.t1 = ms_since(t0);
        bmove(wa, n, S.stash);
        r.t2 = ms_since(t0);
    } else {
        bmove(wa, n, S.stash);
        r.t1 = ms_since(t0);
        bmove(wb, n, S.vis);
        r.t2 = ms_since(t0);
    }
    if (mode != F_PRELAYOUT) {
        for (int i = 0; i < n; i++) {
            AXError a, b;
            ax_set_frame(g_tw[B[i]].ax, tgt[i], &a, &b);
            r.ax_err |= a | b;
        }
        r.t_ax = ms_since(t0);
    }
    r.t_settled = -1;
    uint64_t end = t0 + 3000ull * 1000000ull;
    while (now_ns() < end) {
        bool ex[16], on[16];
        CGRect bb[16];
        cg_query(wb, n, ex, on, bb);
        bool ok = true;
        for (int i = 0; i < n && ok; i++) ok = on[i] && rect_eq(bb[i], tgt[i]) && on_space(wb[i], S.vis);
        if (ok) {
            cg_query(wa, n, ex, on, NULL);
            for (int i = 0; i < n && ok; i++) ok = !on[i] && on_space(wa[i], S.stash);
        }
        if (ok) { r.t_settled = ms_since(t0); r.settled = true; break; }
        run_slice(0.0005);
    }
    pump(300);
    r.notifs = S.nspace_notifs - notif0;
    r.switched = display_current() != cur0 || r.notifs;
    snprintf(r.front, sizeof r.front, "%s", app_name(front_pid()));
    if (!r.settled) {
        bool ex[16], on[16];
        CGRect bb[16];
        cg_query(wb, n, ex, on, bb);
        for (int i = 0; i < n; i++)
            LOG("unsettled: B%d on %s onscreen=%d frame " RECT_FMT " target " RECT_FMT, i, where(wb[i]), on[i], RECT_ARGS(bb[i]),
                RECT_ARGS(tgt[i]));
    }
    snprintf(r.label, sizeof r.label, "%d+%d %s", n, n, flip_name[mode]);
    LOG("flip %s: call1=%.1fms call2=%.1fms ax_layout_done=%.1fms settled=%sms ax_err=%d desk_switched=%d front=%s", r.label,
        r.t1, r.t2, r.t_ax, ms_str(r.t_settled), r.ax_err, r.switched, r.front);
    return r;
}

static int cmd_flip(void) {
    printf("\n## 6. page flip timing\n");
    FlipRes res[16];
    int nr = 0;
    for (int size = 2; size <= 4; size += 2) {
        int A[4], B[4];
        char pa[8], pb[8];
        snprintf(pa, sizeof pa, "A%d_", size);
        snprintf(pb, sizeof pb, "B%d_", size);
        if (te_open(size, pa, A) < size || te_open(size, pb, B) < size) return 1;
        uint32_t wb[4];
        tw_wids(B, size, wb);
        bmove(wb, size, S.stash);
        wait_spaces(wb, size, S.stash, 2000);
        CGRect tgt[4];
        layout_rects(size, 1, tgt);
        for (int i = 0; i < size; i++) ax_set_frame(g_tw[A[i]].ax, tgt[i], NULL, NULL);
        pump(300);
        int *X = A, *Y = B;
        for (int mode = 0; mode < 3; mode++) {
            focus_full(X[0]);
            pump(300);
            res[nr++] = flip(X, Y, size, (FlipMode)mode, mode);
            int *tmp = X;
            X = Y;
            Y = tmp;
            pump(400);
        }
        for (int i = 0; i < size; i++) { tw_close(A[i]); tw_close(B[i]); }
    }
    printf("\n| flip | call 1 ms | call 2 ms | AX layout done ms | settled ms (B onscreen at target, A offscreen on stash) | "
           "AX err | desktop switched | front after |\n|---|---|---|---|---|---|---|---|\n");
    for (int i = 0; i < nr; i++)
        printf("| %s | %.1f | %.1f | %.1f | %s | %d | %s | %s |\n", res[i].label, res[i].t1, res[i].t2, res[i].t_ax,
               ms_str(res[i].t_settled), res[i].ax_err, yesno(res[i].switched), res[i].front);
    return 0;
}

// ---------------------------------------------------------------- 7. focus after unstash

static int cmd_focus(void) {
    printf("\n## 7. focus a just-returned window\n");
    int idx[2];
    if (te_open(2, "F", idx) < 2) return 1;
    TW *t = &g_tw[idx[0]];
    snprintf(g_tw[idx[1]].label, sizeof g_tw[idx[1]].label, "G");
    const char *vn[] = {"", "AX raise+main+focused", "activate only", "AX + activate", "SkyLight only", "AX + SkyLight",
                        "activate + SkyLight", "AX + activate + SkyLight (HyprMac)"};
    int variants[] = {1, 2, 3, 4, 7};
    printf("\n| steps | rep | AX rc raise/main/focused | activate ret | SLPS rc front/post1/post2 | front (SLPS) | "
           "NSWorkspace front | AX system focused app | app kAXFocusedWindow==W | W AXMain/AXFocused | focused | "
           "desktop switched |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n");
    for (int v = 0; v < 5; v++) {
        for (int rep = 0; rep < 2; rep++) {
            ensure_visible_desktop();
            // G becomes the app's key window, then the user's app goes front.
            focus_full(idx[1]);
            pump(300);
            front_restore();
            pump(300);
            LOG("prime: front=%s app focused=%s", app_name(front_pid()), label_of(ax_focused_wid(t->pid)));
            bmove(&t->wid, 1, S.stash);
            wait_spaces(&t->wid, 1, S.stash, 1500);
            pump(150);
            bmove(&t->wid, 1, S.vis);
            wait_spaces(&t->wid, 1, S.vis, 1500);
            int notif0 = S.nspace_notifs;
            uint64_t cur0 = display_current();
            pid_t f0 = front_pid();
            FocusRc rc = focus_steps(idx[0], variants[v]);
            pump(400);
            pid_t fp = front_pid();
            NSRunningApplication *ws = [NSWorkspace sharedWorkspace].frontmostApplication;
            pid_t sysf = ax_system_focused_pid();
            uint32_t fw = ax_focused_wid(t->pid);
            int am = ax_bool(t->ax, kAXMainAttribute), af = ax_bool(t->ax, kAXFocusedAttribute);
            bool ok = fp == t->pid && fw == t->wid && sysf == t->pid;
            bool sw = display_current() != cur0 || S.nspace_notifs != notif0;
            LOG("focus[%s] rep %d: front before %s -> %s, ws=%s sys=%s fw=%u (W=%u) main=%d focused=%d ok=%d", vn[variants[v]], rep,
                app_name(f0), app_name(fp), ws.localizedName.UTF8String, app_name(sysf), fw, t->wid, am, af, ok);
            printf("| %s | %d | %d/%d/%d | %s | %d/%d/%d | %s | %s | %s | %s | %d/%d | %s | %s |\n", vn[variants[v]], rep, rc.raise,
                   rc.main, rc.foc, (variants[v] & 2) ? yesno(rc.act) : "-", rc.sl[0], rc.sl[1], rc.sl[2], app_name(fp),
                   ws.localizedName.UTF8String, app_name(sysf), yesno(fw == t->wid), am, af, ok ? "YES" : "no", yesno(sw));
        }
    }
    return 0;
}

// ---------------------------------------------------------------- 8. Chrome

static int chrome_open(void) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.google.Chrome"];
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.google.Chrome"];
    if (!url) { LOG("Chrome not installed; skipping"); return -1; }
    LOG("Chrome at %s, %lu running instance(s)", url.path.UTF8String, (unsigned long)apps.count);
    NSMutableSet *before = [NSMutableSet set];
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    for (NSDictionary *d in all) if ([d[(id)kCGWindowOwnerName] isEqualToString:@"Google Chrome"]) [before addObject:d[(id)kCGWindowNumber]];
    TW *t = &g_tw[g_ntw];
    memset(t, 0, sizeof *t);
    t->kind = K_CHROME;
    snprintf(t->token, sizeof t->token, "tilos-stash-chrome-%d-%02d", getpid(), ++S.seq);
    snprintf(t->label, sizeof t->label, "C0");
    snprintf(t->file, sizeof t->file, "%s/%s.html", S.dir, t->token);
    NSString *html = [NSString stringWithFormat:@"<!doctype html><title>%s</title><body>tilos stash spike test window. Safe to close.</body>", t->token];
    [html writeToFile:@(t->file) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *fileurl = [NSURL fileURLWithPath:@(t->file)].absoluteString;
    int notif0 = S.nspace_notifs;
    const char *argv[] = {"/usr/bin/open", "-na", url.path.UTF8String, "--args", "--new-window", fileurl.UTF8String, NULL};
    int rc = run_wait(argv);
    LOG("open -na Chrome --new-window rc=%d", rc);
    uint32_t found[8];
    int nf = 0;
    pid_t fpid = 0;
    uint64_t end = now_ns() + 10000ull * 1000000ull;
    while (now_ns() < end && nf == 0) {
        pump(100);
        NSArray *now = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        nf = 0;
        for (NSDictionary *d in now) {
            if (![d[(id)kCGWindowOwnerName] isEqualToString:@"Google Chrome"] || [d[(id)kCGWindowLayer] intValue] != 0) continue;
            if ([before containsObject:d[(id)kCGWindowNumber]]) continue;
            if (![d[(id)kCGWindowName] containsString:@(t->token)]) continue;
            if (nf < 8) found[nf++] = [d[(id)kCGWindowNumber] unsignedIntValue];
            fpid = [d[(id)kCGWindowOwnerPID] intValue];
        }
    }
    if (nf != 1) {
        LOG("Chrome window identification: %d candidate(s) with token; skipping Chrome test", nf);
        unlink(t->file);
        return -1;
    }
    t->wid = found[0];
    t->pid = fpid;
    g_ntw++;
    t->alive = true;
    pump(300);
    bool switched = S.nspace_notifs != notif0 || display_current() != S.vis;
    LOG("Chrome test window wid=%u pid=%d on %s; desktop switched during open=%d", t->wid, t->pid, where(t->wid), switched);
    ensure_visible_desktop();
    if (!on_space(t->wid, S.vis)) {
        bmove(&t->wid, 1, S.vis);
        wait_spaces(&t->wid, 1, S.vis, 1500);
    }
    pump(200);
    t->ax = ax_find(t->pid, t->wid);
    if (!t->ax) { LOG("Chrome window has no AX element on the visible desktop; skipping"); return -2; }
    observe_app(t->pid);
    // Make it a normal size so round-trip layout writes are meaningful.
    ax_set_frame(t->ax, CGRectMake(S.vf.origin.x + 300, S.vf.origin.y + 120, 900, 640), NULL, NULL);
    pump(200);
    return g_ntw - 1;
}

static int cmd_chrome(const char *methods, const char *reacts) {
    printf("\n## 8. Chromium (Google Chrome)\n");
    int c = chrome_open();
    if (c < 0) return c == -1 ? 0 : 1;
    roundtrip(&c, 1, -1, "8a. Chrome round trip");
    printf("\n## 8b. Chrome activation with its test window stashed (user's own Chrome windows live on the stash desktop too)\n");
    activation_suite(c, -1, "Google Chrome", methods, reacts, false, "chrome ");
    tw_close(c);
    return 0;
}

// ---------------------------------------------------------------- 9. edge cases

static AXUIElementRef menu_item(pid_t pid, NSString *menu, NSString *prefix) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementRef bar = ax_child(app, kAXMenuBarAttribute, NULL);
    CFRelease(app);
    if (!bar) return NULL;
    CFTypeRef kids = NULL;
    AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute, &kids);
    CFRelease(bar);
    AXUIElementRef found = NULL;
    for (id mb in (__bridge NSArray *)kids) {
        if (![ax_str((__bridge AXUIElementRef)mb, kAXTitleAttribute, NULL) isEqualToString:menu]) continue;
        CFTypeRef menus = NULL;
        AXUIElementCopyAttributeValue((__bridge AXUIElementRef)mb, kAXChildrenAttribute, &menus);
        for (id m in (__bridge NSArray *)menus) {
            CFTypeRef items = NULL;
            AXUIElementCopyAttributeValue((__bridge AXUIElementRef)m, kAXChildrenAttribute, &items);
            for (id it in (__bridge NSArray *)items)
                if ([ax_str((__bridge AXUIElementRef)it, kAXTitleAttribute, NULL) hasPrefix:prefix] && !found)
                    found = (AXUIElementRef)CFRetain((__bridge CFTypeRef)it);
            if (items) CFRelease(items);
        }
        if (menus) CFRelease(menus);
    }
    if (kids) CFRelease(kids);
    return found;
}

static NSArray *te_sheets(TW *t) {
    NSMutableArray *out = [NSMutableArray array];
    CFTypeRef kids = NULL;
    AXUIElementCopyAttributeValue(t->ax, kAXChildrenAttribute, &kids);
    for (id k in (__bridge NSArray *)kids)
        if ([ax_str((__bridge AXUIElementRef)k, kAXRoleAttribute, NULL) isEqualToString:(id)kAXSheetRole]) [out addObject:k];
    if (kids) CFRelease(kids);
    return out;
}

// Depth-first search for a button with `title`; returns a retained element.
static AXUIElementRef ax_find_button(AXUIElementRef el, NSString *title, int depth) {
    if (depth > 8) return NULL;
    if ([ax_str(el, kAXRoleAttribute, NULL) isEqualToString:(id)kAXButtonRole] &&
        [ax_str(el, kAXTitleAttribute, NULL) isEqualToString:title])
        return (AXUIElementRef)CFRetain(el);
    CFTypeRef kids = NULL;
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids);
    AXUIElementRef found = NULL;
    for (id k in (__bridge NSArray *)kids) {
        found = ax_find_button((__bridge AXUIElementRef)k, title, depth + 1);
        if (found) break;
    }
    if (kids) CFRelease(kids);
    return found;
}

static uint32_t new_window_of(pid_t pid, NSSet *before) {
    NSArray *arr = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowOwnerPID] intValue] != pid || [d[(id)kCGWindowLayer] intValue] != 0) continue;
        if (![before containsObject:d[(id)kCGWindowNumber]]) return [d[(id)kCGWindowNumber] unsignedIntValue];
    }
    return 0;
}

static NSSet *windows_of(pid_t pid) {
    NSMutableSet *s = [NSMutableSet set];
    NSArray *arr = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    for (NSDictionary *d in arr) if ([d[(id)kCGWindowOwnerPID] intValue] == pid) [s addObject:d[(id)kCGWindowNumber]];
    return s;
}

static int cmd_edge(void) {
    printf("\n## 9. minimized and sheet edge cases\n");
    int idx[2];
    if (te_open(2, "E", idx) < 2) return 1;
    TW *m = &g_tw[idx[0]], *s = &g_tw[idx[1]];

    // Minimized.
    AXError e1 = AXUIElementSetAttributeValue(m->ax, kAXMinimizedAttribute, kCFBooleanTrue);
    pump(900);
    WinRec w0 = win_info(m->wid);
    LOG("minimize err=%d -> AXMinimized=%d onscreen=%d spaces=%s", e1, ax_bool(m->ax, kAXMinimizedAttribute), w0.onscreen,
        where(m->wid));
    double c1 = bmove(&m->wid, 1, S.stash);
    double t1 = wait_spaces(&m->wid, 1, S.stash, 1500);
    int min_stashed = ax_bool(m->ax, kAXMinimizedAttribute);
    LOG("stash minimized: call=%.1fms on_stash=%sms spaces=%s AXMinimized=%d", c1, ms_str(t1), where(m->wid), min_stashed);
    double c2 = bmove(&m->wid, 1, S.vis);
    double t2 = wait_spaces(&m->wid, 1, S.vis, 1500);
    LOG("return minimized: call=%.1fms on_visible=%sms spaces=%s AXMinimized=%d", c2, ms_str(t2), where(m->wid),
        ax_bool(m->ax, kAXMinimizedAttribute));
    int notif0 = S.nspace_notifs;
    AXError e2 = AXUIElementSetAttributeValue(m->ax, kAXMinimizedAttribute, kCFBooleanFalse);
    pump(900);
    WinRec w1 = win_info(m->wid);
    char w1_where[32];
    snprintf(w1_where, sizeof w1_where, "%s", where(m->wid));
    LOG("unminimize err=%d -> AXMinimized=%d onscreen=%d spaces=%s current=%llu desk_switched=%d", e2,
        ax_bool(m->ax, kAXMinimizedAttribute), w1.onscreen, where(m->wid), display_current(), S.nspace_notifs != notif0);
    // Variant: stash while minimized, unminimize while still stashed.
    AXUIElementSetAttributeValue(m->ax, kAXMinimizedAttribute, kCFBooleanTrue);
    pump(900);
    bmove(&m->wid, 1, S.stash);
    double t3 = wait_spaces(&m->wid, 1, S.stash, 1500);
    notif0 = S.nspace_notifs;
    AXError e3 = AXUIElementSetAttributeValue(m->ax, kAXMinimizedAttribute, kCFBooleanFalse);
    pump(1200);
    WinRec w2 = win_info(m->wid);
    char w2_where[32];
    snprintf(w2_where, sizeof w2_where, "%s", where(m->wid));
    bool sw3 = S.nspace_notifs != notif0 || display_current() != S.vis;
    LOG("unminimize while stashed (moved in %sms): err=%d AXMinimized=%d onscreen=%d spaces=%s current=%llu desk_switched=%d",
        ms_str(t3), e3, ax_bool(m->ax, kAXMinimizedAttribute), w2.onscreen, where(m->wid), display_current(), sw3);
    ensure_visible_desktop();
    tw_to(&idx[0], 1, S.vis);

    // Sheet (File > Page Setup...).
    focus_full(idx[1]);
    pump(400);
    NSSet *before = windows_of(s->pid);
    AXUIElementRef item = menu_item(s->pid, @"File", @"Page Setup");
    AXError ep = item ? AXUIElementPerformAction(item, kAXPressAction) : -1;
    if (item) CFRelease(item);
    pump(1200);
    NSArray *sheets = te_sheets(s);
    uint32_t sheet_wid = new_window_of(s->pid, before);
    LOG("Page Setup press err=%d -> AX sheets=%lu new CG window=%u on %s", ep, (unsigned long)sheets.count, sheet_wid,
        sheet_wid ? where(sheet_wid) : "-");
    const char *sheet_res = "no sheet appeared; skipped";
    char buf[256];
    if (sheets.count && sheet_wid) {
        bmove(&s->wid, 1, S.stash);
        double ts = wait_spaces(&s->wid, 1, S.stash, 1500);
        pump(300);
        WinRec sw = win_info(sheet_wid);
        const char *sheet_where_stashed = where(sheet_wid);
        LOG("window stashed (%sms): sheet on %s onscreen=%d", ms_str(ts), sheet_where_stashed, sw.onscreen);
        bmove(&s->wid, 1, S.vis);
        double tb = wait_spaces(&s->wid, 1, S.vis, 1500);
        pump(300);
        WinRec sw2 = win_info(sheet_wid);
        LOG("window back (%sms): sheet on %s onscreen=%d", ms_str(tb), where(sheet_wid), sw2.onscreen);
        snprintf(buf, sizeof buf, "stashed: sheet on %s onscreen=%d; returned: sheet on %s onscreen=%d", sheet_where_stashed,
                 sw.onscreen, where(sheet_wid), sw2.onscreen);
        sheet_res = buf;
        if (!on_space(sheet_wid, S.vis)) {
            bmove(&sheet_wid, 1, S.vis);
            wait_spaces(&sheet_wid, 1, S.vis, 1000);
        }
    }
    // Dismiss any sheet with its Cancel button.
    for (id sh in te_sheets(s)) {
        AXUIElementRef b = ax_find_button((__bridge AXUIElementRef)sh, @"Cancel", 0);
        LOG("sheet Cancel button %s press err=%d", b ? "found" : "NOT found", b ? AXUIElementPerformAction(b, kAXPressAction) : -1);
        if (b) CFRelease(b);
    }
    pump(600);
    LOG("sheets left: %lu", (unsigned long)te_sheets(s).count);
    printf("\n| case | result |\n|---|---|\n");
    printf("| stash minimized window | moved=%s (%s ms), still minimized while stashed=%s |\n", yesno(t1 >= 0), ms_str(t1),
           yesno(min_stashed == 1));
    printf("| return, then unminimize | onscreen=%d on %s, desktop switched=no |\n", w1.onscreen, w1_where);
    printf("| unminimize while stashed | onscreen=%d, window stays on %s, desktop switched=%s |\n", w2.onscreen, w2_where, yesno(sw3));
    printf("| sheet travels with window | %s |\n", sheet_res);
    return 0;
}

// ---------------------------------------------------------------- env / events

static id pref(NSString *key, NSString *domain) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain));
}

static int cmd_env(void) {
    printf("os: %s\n", [NSProcessInfo processInfo].operatingSystemVersionString.UTF8String);
    printf("AXIsProcessTrusted=%d bridged perform=%p\n", AXIsProcessTrusted(), f_bridged_perform);
    printf("AppleSpacesSwitchOnActivate=%s mru-spaces=%s reduceMotion=%d\n",
           [[pref(@"AppleSpacesSwitchOnActivate", @"NSGlobalDomain") description] UTF8String] ?: "(unset => ON)",
           [[pref(@"mru-spaces", @"com.apple.dock") description] UTF8String] ?: "(unset => ON)",
           [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion]);
    uint32_t ws[MAXW];
    int nv = windows_on_space(S.vis, NULL, 0, ws, MAXW);
    printf("visible %llu windows:", S.vis);
    for (int i = 0; i < nv; i++) printf(" %s", label_of(ws[i]));
    int ns = windows_on_space(S.stash, NULL, 0, ws, MAXW);
    printf("\nstash %llu windows:", S.stash);
    for (int i = 0; i < ns; i++) printf(" %s", label_of(ws[i]));
    printf("\n");
    return 0;
}

static int cmd_events(int secs) {
    mon_start(R_NONE, -1, NULL, 0);
    pump(secs * 1000);
    mon_stop();
    return 0;
}

// Posts one symbolic hotkey (79 left / 81 right) and only observes.
static int cmd_hotkey(int hk) {
    mon_start(R_NONE, -1, NULL, 0);
    char err[128] = "";
    if (!hk_post(hk, err, sizeof err)) LOG("hotkey failed: %s", err);
    M.t0 = now_ns();
    LOG("posted hotkey %d", hk);
    pump(2000);
    mon_stop();
    LOG("result: current=%llu (%s)", display_current(), display_current() == S.vis ? "visible" : "stash");
    return 0;
}

static void usage(void) {
    printf("usage: stash <cmd>\n"
           "  env                          visible/stash desktops and their windows\n"
           "  events [secs]                log space/front/AX events only (no actions)\n"
           "  roundtrip                    1. stash/return 3 TextEdit windows in one call each\n"
           "  axstash                      2. pre-stash AX handle: read/write/close while stashed\n"
           "  notify                       3. AX notifications while stashed\n"
           "  activate [methods] [reacts]  4. app activation with its window stashed\n"
           "                                  methods: cmdtab,activate,open  reacts: none,bounce,preempt,hybrid\n"
           "  navigate [specs]             5. ctrl+fn+arrow into the stash, bounce back; specs: early,late,notify,\n"
           "                                  notify+<ms>,tap (default early,late,notify,notify+150,tap)\n"
           "  flip                         6. page flip timing (2+2, 4+4)\n"
           "  focus                        7. focus a just-returned window\n"
           "  chrome [methods] [reacts]    8. Chrome round trip + activation\n"
           "  edge                         9. minimized / sheet\n"
           "  all                          1-9 in sequence\n"
           "  hotkey <79|81>               post ctrl+fn+Left/Right once and observe (Dock state probe)\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        g_t0 = now_ns();
        setvbuf(stdout, NULL, _IOLBF, 0);
        // Accessory app with a finished launch, like a real WM agent. STASH_APPMODE
        // selects other setups for comparison: prohibited, accessory-nofinish.
        [NSApplication sharedApplication];
        const char *mode = getenv("STASH_APPMODE") ?: "accessory-events";
        [NSApp setActivationPolicy:!strcmp(mode, "prohibited") ? NSApplicationActivationPolicyProhibited
                                                               : NSApplicationActivationPolicyAccessory];
        if (!strcmp(mode, "accessory") || !strcmp(mode, "accessory-events")) [NSApp finishLaunching];
        g_nsevents = !strcmp(mode, "accessory-events");
        load_symbols();
        AXUIElementRef sys = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(sys, 2.0);
        CFRelease(sys);
        if (argc < 2) { usage(); return 1; }
        const char *c = argv[1];
        const char *a2 = argc > 2 ? argv[2] : NULL, *a3 = argc > 3 ? argv[3] : NULL;
        int rc = session_init(true);
        if (rc) return rc;
        if (!strcmp(c, "env")) { S.active = false; return cmd_env(); }
        if (!strcmp(c, "events")) { S.active = false; return cmd_events(a2 ? atoi(a2) : 10); }
        if (!strcmp(c, "hotkey") && a2) { S.active = false; return cmd_hotkey(atoi(a2)); }
        if (!strcmp(c, "roundtrip")) rc = cmd_roundtrip();
        else if (!strcmp(c, "axstash")) rc = cmd_axstash();
        else if (!strcmp(c, "notify")) rc = cmd_notify();
        else if (!strcmp(c, "activate")) rc = cmd_activate(a2, a3);
        else if (!strcmp(c, "navigate")) rc = cmd_navigate(a2);
        else if (!strcmp(c, "flip")) rc = cmd_flip();
        else if (!strcmp(c, "focus")) rc = cmd_focus();
        else if (!strcmp(c, "chrome")) rc = cmd_chrome(a2, a3);
        else if (!strcmp(c, "edge")) rc = cmd_edge();
        else if (!strcmp(c, "all")) {
            int (*fs[])(void) = {cmd_roundtrip, cmd_axstash, cmd_notify};
            for (int i = 0; i < 3; i++) { fs[i](); tw_close_all(); }
            cmd_activate(NULL, NULL); tw_close_all();
            cmd_navigate(NULL); tw_close_all();
            cmd_flip(); tw_close_all();
            cmd_focus(); tw_close_all();
            cmd_chrome(NULL, NULL); tw_close_all();
            cmd_edge(); tw_close_all();
        } else {
            S.active = false;
            usage();
            return 1;
        }
        session_cleanup("end");
        return rc;
    }
}
