// Throwaway spike: which methods move another app's window to a native macOS
// Space (Desktop N) with SIP enabled, and how desktop switching behaves.
//
// Desktop numbers (n) are global Mission Control "Desktop N" labels: user
// spaces counted across displays in CGSCopyManagedDisplaySpaces order, which
// is also what the "Switch to Desktop N" hotkeys (118 + n - 1) address.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <libproc.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <signal.h>
#import <time.h>

#define SKYLIGHT_PATH "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
#define BRIDGED_SYM "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
#define HK_DESKTOP_BASE 118
#define HK_SPACE_LEFT 79
#define HK_SPACE_RIGHT 81
#define POLL_MS 2000

@interface NSObject (SpikeBridged)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)sid;
- (instancetype)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)sid;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (void)invokeFallback;
@end

// ---------------------------------------------------------------- symbols

static int g_cid;
static int (*f_SLSMainConnectionID)(void);
static CFArrayRef (*f_SLSCopyManagedDisplaySpaces)(int);
static CFArrayRef (*f_SLSCopySpacesForWindows)(int, int, CFArrayRef);
static uint64_t (*f_SLSManagedDisplayGetCurrentSpace)(int, CFStringRef);
static CFStringRef (*f_SLSCopyManagedDisplayForWindow)(int, uint32_t);
static CFStringRef (*f_SLSCopyBestManagedDisplayForPoint)(int, CGPoint);
static bool (*f_SLSManagedDisplayIsAnimating)(int, CFStringRef);
static void (*f_SLSMoveWindowsToManagedSpace)(int, CFArrayRef, uint64_t);
static CGError (*f_SLSSpaceSetCompatID)(int, uint64_t, int);
static int (*f_SLSSpaceGetCompatID)(int, uint64_t);
static CGError (*f_SLSSetWindowListWorkspace)(int, uint32_t *, int, int);
static CGError (*f_CGSGetSymbolicHotKeyValue)(int, uint16_t *, uint16_t *, uint32_t *);
static bool (*f_CGSIsSymbolicHotKeyEnabled)(int);
static AXError (*f_AXUIElementGetWindow)(AXUIElementRef, uint32_t *);
static int64_t (*f_bridged_perform)(void *);

static uint64_t g_t0;
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static double ms_since(uint64_t t) { return (double)(now_ns() - t) / 1e6; }
static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("[%8.1fms] ", ms_since(g_t0));
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
// Returns 1 if the visitor stopped, 0 if the walk ended, -1 image not loaded,
// -2 no symtab/linkedit.
typedef bool (^symtab_visitor)(const char *name, uint8_t type, uint64_t addr);
static int macho_walk(const char *image, uint32_t *nsyms_out, symtab_visitor v) {
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
        if (!le || !st) return -2;
        uintptr_t base = (uintptr_t)(le->vmaddr - le->fileoff + slide);
        const char *strs = (const char *)(base + st->stroff);
        const struct nlist_64 *syms = (const void *)(base + st->symoff);
        if (nsyms_out) *nsyms_out = st->nsyms;
        for (uint32_t s = 0; s < st->nsyms; s++) {
            if (v(strs + syms[s].n_un.n_strx, syms[s].n_type, syms[s].n_value + slide)) return 1;
        }
        return 0;
    }
    return -1;
}

static void *macho_find_symbol(const char *image, const char *target) {
    __block void *found = NULL;
    macho_walk(image, NULL, ^bool(const char *name, uint8_t type, uint64_t addr) {
        if (strcmp(name, target)) return false;
        found = (void *)addr;
        return true;
    });
    return found;
}

static void load_symbols(void) {
    dlopen(SKYLIGHT_PATH, RTLD_NOW | RTLD_GLOBAL);
    *(void **)&f_SLSMainConnectionID = sym("SLSMainConnectionID");
    *(void **)&f_SLSCopyManagedDisplaySpaces = sym("SLSCopyManagedDisplaySpaces");
    *(void **)&f_SLSCopySpacesForWindows = sym("SLSCopySpacesForWindows");
    *(void **)&f_SLSManagedDisplayGetCurrentSpace = sym("SLSManagedDisplayGetCurrentSpace");
    *(void **)&f_SLSCopyManagedDisplayForWindow = sym("SLSCopyManagedDisplayForWindow");
    *(void **)&f_SLSCopyBestManagedDisplayForPoint = sym("SLSCopyBestManagedDisplayForPoint");
    *(void **)&f_SLSManagedDisplayIsAnimating = sym("SLSManagedDisplayIsAnimating");
    *(void **)&f_SLSMoveWindowsToManagedSpace = sym("SLSMoveWindowsToManagedSpace");
    *(void **)&f_SLSSpaceSetCompatID = sym("SLSSpaceSetCompatID");
    *(void **)&f_SLSSetWindowListWorkspace = sym("SLSSetWindowListWorkspace");
    *(void **)&f_SLSSpaceGetCompatID = sym("SLSSpaceGetCompatID");
    *(void **)&f_CGSGetSymbolicHotKeyValue = sym("CGSGetSymbolicHotKeyValue");
    *(void **)&f_CGSIsSymbolicHotKeyEnabled = sym("CGSIsSymbolicHotKeyEnabled");
    *(void **)&f_AXUIElementGetWindow = sym("_AXUIElementGetWindow");
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

// Global desktop number -> display index and space index.
static bool topo_desktop(const Topo *t, int desk, int *di, int *si) {
    int k = 0;
    for (int i = 0; i < t->n; i++)
        for (int j = 0; j < t->d[i].n; j++)
            if (t->d[i].sp[j].type == 0 && ++k == desk) { *di = i; *si = j; return true; }
    return false;
}

static int topo_desktop_number(const Topo *t, uint64_t sid) {
    int k = 0;
    for (int i = 0; i < t->n; i++)
        for (int j = 0; j < t->d[i].n; j++)
            if (t->d[i].sp[j].type == 0) { k++; if (t->d[i].sp[j].sid == sid) return k; }
    return 0;
}

static int topo_find(const Topo *t, uint64_t sid, int *si) {
    for (int i = 0; i < t->n; i++)
        for (int j = 0; j < t->d[i].n; j++)
            if (t->d[i].sp[j].sid == sid) { if (si) *si = j; return i; }
    return -1;
}

static uint64_t display_current(const char *uuid) {
    return f_SLSManagedDisplayGetCurrentSpace(g_cid, (__bridge CFStringRef)@(uuid));
}

static int user_desktop_count(const DisplayRec *d) {
    int k = 0;
    for (int j = 0; j < d->n; j++) k += d->sp[j].type == 0;
    return k;
}

// ---------------------------------------------------------------- windows

static CFArrayRef cf_wid_array(uint32_t wid) {
    int32_t v = (int32_t)wid;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)&n, 1, &kCFTypeArrayCallBacks);
    CFRelease(n);
    return a;
}

static NSArray<NSNumber *> *window_spaces(uint32_t wid) {
    CFArrayRef a = cf_wid_array(wid);
    CFArrayRef r = f_SLSCopySpacesForWindows(g_cid, 0x7, a);
    CFRelease(a);
    return r ? CFBridgingRelease(r) : @[];
}

static bool spaces_is(NSArray *s, uint64_t sid) { return s.count == 1 && [s[0] unsignedLongLongValue] == sid; }
static const char *spaces_cstr(NSArray *s) { return [[s componentsJoinedByString:@","] UTF8String] ?: ""; }

typedef struct { bool ok; pid_t pid; char owner[128]; char title[256]; CGRect bounds; int layer; bool onscreen; } WinRec;

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

static bool rect_eq(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) <= 1 && fabs(a.origin.y - b.origin.y) <= 1 &&
           fabs(a.size.width - b.size.width) <= 1 && fabs(a.size.height - b.size.height) <= 1;
}
#define RECT_FMT "(%.0f,%.0f %.0fx%.0f)"
#define RECT_ARGS(r) (r).origin.x, (r).origin.y, (r).size.width, (r).size.height

// ---------------------------------------------------------------- AX

static uint32_t ax_wid(AXUIElementRef el) {
    uint32_t w = 0;
    if (f_AXUIElementGetWindow && f_AXUIElementGetWindow(el, &w) == kAXErrorSuccess) return w;
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

static NSString *ax_str(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    id o = CFBridgingRelease(v);
    return [o isKindOfClass:[NSString class]] ? o : nil;
}

static AXUIElementRef ax_child(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return NULL;
    return (AXUIElementRef)v;
}

static bool ax_frame(AXUIElementRef el, CGRect *r) {
    CFTypeRef p = NULL, s = NULL;
    bool ok = false;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &p) == kAXErrorSuccess &&
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &s) == kAXErrorSuccess) {
        ok = AXValueGetValue(p, kAXValueTypeCGPoint, &r->origin) && AXValueGetValue(s, kAXValueTypeCGSize, &r->size);
    }
    if (p) CFRelease(p);
    if (s) CFRelease(s);
    return ok;
}

static AXUIElementRef ax_find(pid_t pid, uint32_t wid) {
    for (id el in ax_windows(pid, NULL))
        if (ax_wid((__bridge AXUIElementRef)el) == wid) return (AXUIElementRef)CFRetain((__bridge CFTypeRef)el);
    return NULL;
}

// 1 listed, 0 not listed, -1 AX error.
static int ax_lists(pid_t pid, uint32_t wid, char *detail, size_t len) {
    AXError e;
    NSArray *ws = ax_windows(pid, &e);
    NSMutableArray *ids = [NSMutableArray array];
    bool hit = false;
    for (id el in ws) {
        uint32_t w = ax_wid((__bridge AXUIElementRef)el);
        [ids addObject:@(w)];
        hit |= w == wid;
    }
    if (detail) snprintf(detail, len, "kAXWindows err=%d ids=[%s]", e, [[ids componentsJoinedByString:@","] UTF8String]);
    if (e != kAXErrorSuccess && e != kAXErrorNoValue) return -1;
    return hit;
}

// ---------------------------------------------------------------- input

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

typedef struct { CGError err; bool enabled; uint16_t ch, kc; uint32_t mods; } HotKey;

static HotKey hk_get(int id) {
    HotKey h = {0};
    h.err = f_CGSGetSymbolicHotKeyValue ? f_CGSGetSymbolicHotKeyValue(id, &h.ch, &h.kc, &h.mods) : -1;
    h.enabled = f_CGSIsSymbolicHotKeyEnabled ? f_CGSIsSymbolicHotKeyEnabled(id) : false;
    return h;
}

static const char *mods_str(uint32_t m) {
    static char b[64];
    snprintf(b, sizeof b, "%s%s%s%s%s", (m & kCGEventFlagMaskControl) ? "ctrl+" : "",
             (m & kCGEventFlagMaskAlternate) ? "opt+" : "", (m & kCGEventFlagMaskShift) ? "shift+" : "",
             (m & kCGEventFlagMaskCommand) ? "cmd+" : "", (m & kCGEventFlagMaskSecondaryFn) ? "fn+" : "");
    return b;
}

static bool hk_post(int id, char *err, size_t len) {
    HotKey h = hk_get(id);
    if (h.err) { snprintf(err, len, "CGSGetSymbolicHotKeyValue(%d) err=%d", id, h.err); return false; }
    if (!h.enabled) { snprintf(err, len, "symbolic hotkey %d disabled", id); return false; }
    if (h.kc == 0xffff) { snprintf(err, len, "symbolic hotkey %d has no key", id); return false; }
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, h.kc, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, h.kc, false);
    CGEventSetFlags(d, h.mods);
    CGEventSetFlags(u, h.mods);
    CGEventPost(kCGHIDEventTap, d);
    CGEventPost(kCGHIDEventTap, u);
    CFRelease(d);
    CFRelease(u);
    return true;
}

// Synthetic high-velocity dock swipe (yabai space_manager_focus_space_using_gesture).
// SPIKE_GESTURE selects a variant: yabai (default, session tap), hid (HID tap),
// pair (each dock event followed by a kCGSEventGesture event), phases
// (began/changed/ended with progress ramp, paired).
static const char *gesture_variant(void) { return getenv("SPIKE_GESTURE") ?: "yabai"; }

static void gesture_emit(CGEventTapLocation tap, bool pair, int phase, double progress, double velocity) {
    CGEventRef e = CGEventCreate(NULL);
    CGEventSetIntegerValueField(e, (CGEventField)55, 30);   // kCGSEventTypeField = kCGSEventDockControl
    CGEventSetIntegerValueField(e, (CGEventField)110, 23);  // kCGEventGestureHIDType = kIOHIDEventTypeDockSwipe
    CGEventSetIntegerValueField(e, (CGEventField)123, 1);   // kCGEventGestureSwipeMotion = horizontal
    CGEventSetDoubleValueField(e, (CGEventField)124, progress); // kCGEventGestureSwipeProgress
    CGEventSetDoubleValueField(e, (CGEventField)129, velocity); // kCGEventGestureSwipeVelocityX
    CGEventSetIntegerValueField(e, (CGEventField)132, phase);   // kCGEventGesturePhase
    CGEventPost(tap, e);
    CFRelease(e);
    if (pair) {
        CGEventRef g = CGEventCreate(NULL);
        CGEventSetIntegerValueField(g, (CGEventField)55, 29); // kCGSEventGesture
        CGEventPost(tap, g);
        CFRelease(g);
    }
}

static void gesture_post(int delta) {
    const char *v = gesture_variant();
    double sign = (delta > 0 ? 1.0 : -1.0) * (getenv("SPIKE_GESTURE_SIGN") ? atof(getenv("SPIKE_GESTURE_SIGN")) : 1.0);
    CGEventTapLocation tap = !strcmp(v, "hid") ? kCGHIDEventTap : kCGSessionEventTap;
    bool pair = !strcmp(v, "pair") || !strcmp(v, "phases");
    for (int i = 0; i < abs(delta); i++) {
        if (!strcmp(v, "phases")) {
            gesture_emit(tap, pair, 1, 0, 0);
            for (int k = 1; k <= 4; k++) { usleep(8000); gesture_emit(tap, pair, 2, sign * k * 0.25, sign * 3000.0); }
            gesture_emit(tap, pair, 4, sign, sign * 9999.0);
        } else {
            gesture_emit(tap, pair, 1, sign, sign * 9999.0); // began
            gesture_emit(tap, pair, 4, sign, sign * 9999.0); // ended
        }
    }
}

// ---------------------------------------------------------------- switching

typedef enum { SW_HOTKEY, SW_ARROW, SW_GESTURE, SW_BRIDGED, SW_BRIDGED3 } SwMethod;
static const char *sw_name[] = {"desktop-N hotkey", "ctrl-arrow hotkey", "dock-swipe gesture", "bridged set-current",
                                "bridged show+hide+set-current"};

static int64_t bridged_perform(id op) { return f_bridged_perform((__bridge void *)op); }

typedef struct {
    SwMethod m;
    bool posted, reached, probe_ok, anim_seen, cursor_moved;
    double t_call_ms, t_current_ms, t_probe_ms;
    uint64_t from, to, final;
    int from_desk, to_desk;
    int64_t rc;
    char err[256];
} SwitchRes;

// Polls until the display's current space is `target` and the probe window's
// on-screen flag matches `expect_onscreen` (stable for 150ms), or timeout.
static void switch_measure(SwitchRes *r, const char *uuid, uint64_t target, uint32_t probe, bool expect_onscreen,
                           uint64_t t0, int timeout_ms) {
    uint64_t deadline = now_ns() + (uint64_t)timeout_ms * 1000000ull;
    double stable_since = -1;
    r->t_current_ms = r->t_probe_ms = -1;
    for (;;) {
        @autoreleasepool {
            uint64_t cur = display_current(uuid);
            if (f_SLSManagedDisplayIsAnimating && f_SLSManagedDisplayIsAnimating(g_cid, (__bridge CFStringRef)@(uuid)))
                r->anim_seen = true;
            bool at = cur == target;
            if (at && r->t_current_ms < 0) r->t_current_ms = ms_since(t0);
            if (!at) r->t_current_ms = -1;
            bool pok = true;
            if (probe) {
                WinRec w = win_info(probe);
                pok = w.ok && w.onscreen == expect_onscreen;
                if (pok && r->t_probe_ms < 0) r->t_probe_ms = ms_since(t0);
                if (!pok) r->t_probe_ms = -1;
            }
            r->final = cur;
            if (at && pok) {
                if (stable_since < 0) stable_since = ms_since(t0);
                if (ms_since(t0) - stable_since >= 150) { r->reached = true; r->probe_ok = true; break; }
            } else {
                stable_since = -1;
            }
            if (now_ns() > deadline) {
                r->reached = at;
                r->probe_ok = pok;
                break;
            }
        }
        usleep(2000);
    }
}

static bool cursor_on_display(const char *uuid) {
    if (!f_SLSCopyBestManagedDisplayForPoint) return true;
    CFStringRef s = f_SLSCopyBestManagedDisplayForPoint(g_cid, cursor_pos());
    if (!s) return true;
    bool eq = [(__bridge NSString *)s isEqualToString:@(uuid)];
    CFRelease(s);
    return eq;
}

// Switches the display hosting `target` to it with method `m`.
static SwitchRes do_switch(SwMethod m, uint64_t target, uint32_t probe, bool probe_expect_onscreen) {
    SwitchRes r = {.m = m, .to = target};
    Topo t;
    topo_load(&t);
    int si, di = topo_find(&t, target, &si);
    if (di < 0) { snprintf(r.err, sizeof r.err, "space %llu not found", target); return r; }
    const char *uuid = t.d[di].uuid;
    r.from = t.d[di].current;
    r.from_desk = topo_desktop_number(&t, r.from);
    r.to_desk = topo_desktop_number(&t, target);
    if (r.from == target) { r.reached = r.probe_ok = true; r.final = target; return r; }
    CGPoint c0 = cursor_pos();
    uint64_t t0 = now_ns();
    switch (m) {
    case SW_HOTKEY:
        if (!r.to_desk || r.to_desk > 16) { snprintf(r.err, sizeof r.err, "no hotkey for desktop %d", r.to_desk); return r; }
        r.posted = hk_post(HK_DESKTOP_BASE + r.to_desk - 1, r.err, sizeof r.err);
        break;
    case SW_ARROW: {
        int ci;
        topo_find(&t, r.from, &ci);
        int delta = si - ci;
        for (int k = 0; k < abs(delta); k++) {
            if (k) sleep_ms(700);
            if (!hk_post(delta > 0 ? HK_SPACE_RIGHT : HK_SPACE_LEFT, r.err, sizeof r.err)) break;
            r.posted = true;
        }
        break;
    }
    case SW_GESTURE: {
        int ci;
        topo_find(&t, r.from, &ci);
        if (!cursor_on_display(uuid)) snprintf(r.err, sizeof r.err, "cursor not on target display; gesture hits cursor display");
        gesture_post(si - ci);
        if (!r.err[0]) snprintf(r.err, sizeof r.err, "variant=%s", gesture_variant());
        r.posted = true;
        break;
    }
    case SW_BRIDGED: {
        if (!f_bridged_perform) { snprintf(r.err, sizeof r.err, "bridged perform symbol unresolved"); return r; }
        Class c = objc_getClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation");
        if (!c) { snprintf(r.err, sizeof r.err, "class missing"); return r; }
        id op = [[c alloc] initWithDisplayIdentifier:@(uuid) spaceID:target];
        r.rc = bridged_perform(op);
        r.posted = true;
        break;
    }
    case SW_BRIDGED3: {
        // yabai's in-Dock focus sequence, sent through the bridge instead.
        if (!f_bridged_perform) { snprintf(r.err, sizeof r.err, "bridged perform symbol unresolved"); return r; }
        Class cs = objc_getClass("SLSBridgedShowSpacesOperation"), ch = objc_getClass("SLSBridgedHideSpacesOperation"),
              cc = objc_getClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation");
        if (!cs || !ch || !cc) { snprintf(r.err, sizeof r.err, "class missing"); return r; }
        bridged_perform([[cs alloc] initWithSpaces:@[@(target)]]);
        bridged_perform([[ch alloc] initWithSpaces:@[@(r.from)]]);
        r.rc = bridged_perform([[cc alloc] initWithDisplayIdentifier:@(uuid) spaceID:target]);
        r.posted = true;
        break;
    }
    }
    r.t_call_ms = ms_since(t0);
    if (!r.posted) return r;
    switch_measure(&r, uuid, target, probe, probe_expect_onscreen, t0, POLL_MS);
    CGPoint c1 = cursor_pos();
    r.cursor_moved = fabs(c1.x - c0.x) > 0.5 || fabs(c1.y - c0.y) > 0.5;
    return r;
}

static void print_switch(const SwitchRes *r) {
    LOG("switch[%s] desk %d->%d sid %llu->%llu posted=%d reached=%d final=%llu t_call=%.1fms t_current=%.1fms "
        "t_probe=%.1fms probe_ok=%d anim_flag_seen=%d cursor_moved=%d rc=%lld err=%s",
        sw_name[r->m], r->from_desk, r->to_desk, r->from, r->to, r->posted, r->reached, r->final, r->t_call_ms,
        r->t_current_ms, r->t_probe_ms, r->probe_ok, r->anim_seen, r->cursor_moved, r->rc, r->err[0] ? r->err : "-");
}

// Switch for restore paths: desktop-N hotkey, ctrl-arrow hotkey, gesture.
static bool switch_auto(uint64_t target, uint32_t probe, bool expect_onscreen) {
    SwMethod ms[] = {SW_HOTKEY, SW_ARROW, SW_GESTURE};
    for (int i = 0; i < 3; i++) {
        SwitchRes r = do_switch(ms[i], target, probe, expect_onscreen);
        if (r.posted || r.reached) print_switch(&r);
        if (r.reached) return true;
    }
    LOG("switch_auto: FAILED to reach %llu", target);
    return false;
}

// ---------------------------------------------------------------- moves

typedef enum { MV_LEGACY, MV_COMPAT, MV_FALLBACK, MV_BRIDGED, MV_DRAG, MV_DRAG_SILICA } MvMethod;
static const char *mv_name[] = {"SLSMoveWindowsToManagedSpace", "compat-id (SLSSpaceSetCompatID+SetWindowListWorkspace)",
                                "bridged-op invokeFallback", "bridged-op (yabai tier 1)", "fake-drag (10px jiggle)",
                                "fake-drag (Silica exact)"};

typedef struct {
    MvMethod m;
    char label[48];
    bool attempted, worked, desk_switched, cursor_moved, frame_ok;
    double latency_ms;
    CGRect f0, f1;
    uint64_t from, to;
    int64_t rc;
    char err[512], note[160], spaces_after[128];
} MoveRes;

static void poll_move(MoveRes *r, uint32_t wid, const char *uuid, uint64_t cur0, uint64_t t0) {
    uint64_t deadline = now_ns() + (uint64_t)POLL_MS * 1000000ull;
    NSArray *s = nil;
    for (;;) {
        @autoreleasepool {
            s = window_spaces(wid);
            if (display_current(uuid) != cur0) r->desk_switched = true;
            if (spaces_is(s, r->to)) { r->worked = true; r->latency_ms = ms_since(t0); }
            if (r->worked || now_ns() > deadline) {
                strlcpy(r->spaces_after, spaces_cstr(s), sizeof r->spaces_after);
                break;
            }
        }
        usleep(2000);
    }
    // A move that triggers a desktop switch may do so after the space change.
    for (int i = 0; i < 125 && !r->desk_switched; i++) {
        if (display_current(uuid) != cur0) r->desk_switched = true;
        usleep(2000);
    }
}

static void append_err(MoveRes *r, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void append_err(MoveRes *r, const char *fmt, ...) {
    size_t n = strlen(r->err);
    if (n && n < sizeof r->err - 2) { strcat(r->err, "; "); n += 2; }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(r->err + n, sizeof r->err - n, fmt, ap);
    va_end(ap);
}

static CGPoint g_mouse_pt;
static volatile bool g_mouse_down;

static void mouse_post(CGEventType type, CGPoint p) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, kCGMouseButtonLeft);
    CGEventSetFlags(e, 0);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void mouse_release_if_down(void) {
    if (!g_mouse_down) return;
    mouse_post(kCGEventLeftMouseUp, g_mouse_pt);
    g_mouse_down = false;
}

// Title bar grab point. Silica uses the minimize button's midX at half the
// button's top inset; on macOS 26+ that lands in the top-edge resize band, so
// this grabs the title bar midline 40pt right of the zoom button instead.
static uint32_t window_at_point(CGPoint p) {
    NSArray *arr = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &b);
        if (CGRectContainsPoint(b, p)) return [d[(id)kCGWindowNumber] unsignedIntValue];
    }
    return 0;
}

static bool drag_point(pid_t pid, uint32_t wid, CGPoint *pt, char *err, size_t len) {
    AXUIElementRef w = ax_find(pid, wid);
    if (!w) { snprintf(err, len, "AX window not found (must be on the active desktop)"); return false; }
    CGRect wf = CGRectZero, mf = CGRectZero, zf = CGRectZero;
    ax_frame(w, &wf);
    AXUIElementRef mb = ax_child(w, kAXMinimizeButtonAttribute);
    AXUIElementRef zb = ax_child(w, kAXZoomButtonAttribute);
    bool have_m = mb && ax_frame(mb, &mf), have_z = zb && ax_frame(zb, &zf);
    if (mb) CFRelease(mb);
    if (zb) CFRelease(zb);
    CFRelease(w);
    if (have_m && have_z) {
        pt->x = fmin(CGRectGetMaxX(zf) + 40, CGRectGetMaxX(wf) - 20);
        pt->y = CGRectGetMidY(mf);
    } else {
        pt->x = wf.origin.x + 100;
        pt->y = wf.origin.y + 14;
    }
    LOG("drag point (%.0f,%.0f) window " RECT_FMT " min " RECT_FMT " zoom " RECT_FMT, pt->x, pt->y, RECT_ARGS(wf),
        RECT_ARGS(mf), RECT_ARGS(zf));
    uint32_t top = window_at_point(*pt);
    if (top != wid) {
        LOG("drag point covered by window %u; raising and activating owner", top);
        AXUIElementRef w2 = ax_find(pid, wid);
        if (w2) { AXUIElementPerformAction(w2, kAXRaiseAction); CFRelease(w2); }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
        sleep_ms(400);
        top = window_at_point(*pt);
        if (top != wid) { snprintf(err, len, "drag point still covered by window %u", top); return false; }
    }
    return true;
}

static MoveRes do_move(MvMethod m, uint32_t wid, uint64_t target) {
    MoveRes r = {.m = m, .to = target, .rc = 0};
    strlcpy(r.label, mv_name[m], sizeof r.label);
    WinRec w0 = win_info(wid);
    if (!w0.ok) { append_err(&r, "window %u not found", wid); return r; }
    r.f0 = w0.bounds;
    NSArray *s0 = window_spaces(wid);
    r.from = s0.count ? [s0[0] unsignedLongLongValue] : 0;
    Topo t;
    topo_load(&t);
    int di = topo_find(&t, target, NULL);
    if (di < 0) { append_err(&r, "target space %llu not found", target); return r; }
    const char *uuid = t.d[di].uuid;
    uint64_t cur0 = t.d[di].current;
    CGPoint c0 = cursor_pos(), c1 = c0;
    CFArrayRef arr = cf_wid_array(wid);
    r.attempted = true;
    uint64_t t0 = now_ns();

    switch (m) {
    case MV_LEGACY:
        f_SLSMoveWindowsToManagedSpace(g_cid, arr, target);
        break;
    case MV_COMPAT: {
        int prev = f_SLSSpaceGetCompatID ? f_SLSSpaceGetCompatID(g_cid, target) : 0;
        CGError e1 = f_SLSSpaceSetCompatID(g_cid, target, 0x79616265);
        CGError e2 = f_SLSSetWindowListWorkspace(g_cid, &wid, 1, 0x79616265);
        CGError e3 = f_SLSSpaceSetCompatID(g_cid, target, prev);
        snprintf(r.note, sizeof r.note, "prev compat id=%d", prev);
        if (e1 || e2 || e3) append_err(&r, "SetCompatID=%d SetWindowListWorkspace=%d RestoreCompatID=%d", e1, e2, e3);
        break;
    }
    case MV_FALLBACK:
    case MV_BRIDGED: {
        Class c = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        if (!c) { append_err(&r, "class missing"); r.attempted = false; break; }
        id op = [[c alloc] initWithWindows:(__bridge NSArray *)arr spaceID:target];
        @try {
            if (m == MV_FALLBACK) {
                [op invokeFallback];
            } else if (!f_bridged_perform) {
                append_err(&r, "SLSPerformAsynchronousBridgedWindowManagementOperation unresolved");
                r.attempted = false;
            } else {
                r.rc = f_bridged_perform((__bridge void *)op);
            }
        } @catch (NSException *ex) {
            append_err(&r, "exception %s: %s", ex.name.UTF8String, ex.reason.UTF8String);
        }
        break;
    }
    case MV_DRAG:
    case MV_DRAG_SILICA: {
        int desk = topo_desktop_number(&t, target);
        int hk = HK_DESKTOP_BASE + desk - 1;
        HotKey h = hk_get(hk);
        CGPoint p;
        char e[256] = "";
        if (!desk || desk > 16 || h.err || !h.enabled) {
            // Silica needs Switch to Desktop N; fall back to Move left/right a space for an adjacent target.
            int ci, ti;
            topo_find(&t, cur0, &ci);
            topo_find(&t, target, &ti);
            int alt = ti - ci == 1 ? HK_SPACE_RIGHT : ti - ci == -1 ? HK_SPACE_LEFT : 0;
            HotKey ha = hk_get(alt);
            if (!alt || ha.err || !ha.enabled) {
                append_err(&r, "hotkey %d disabled and no usable ctrl-arrow hotkey", hk);
                r.attempted = false;
                break;
            }
            snprintf(r.note, sizeof r.note, "hotkey %d (Desktop %d) disabled; used %d (%s a space)", hk, desk, alt,
                     alt == HK_SPACE_RIGHT ? "right" : "left");
            hk = alt;
        }
        if (!drag_point(w0.pid, wid, &p, e, sizeof e)) { append_err(&r, "%s", e); r.attempted = false; break; }
        // The window only rides along with the space switch if the drag really moved it.
        int jiggle = m == MV_DRAG_SILICA ? 0 : getenv("SPIKE_DRAG_JIGGLE") ? atoi(getenv("SPIKE_DRAG_JIGGLE")) : 10;
        int hold = m == MV_DRAG_SILICA ? 400 : getenv("SPIKE_DRAG_HOLD_MS") ? atoi(getenv("SPIKE_DRAG_HOLD_MS")) : 400;
        char *nl = r.note + strlen(r.note);
        snprintf(nl, sizeof r.note - strlen(r.note), "%sjiggle=%d hold=%dms", r.note[0] ? "; " : "", jiggle, hold);
        t0 = now_ns();
        g_mouse_pt = p;
        mouse_post(kCGEventMouseMoved, p);
        g_mouse_down = true;
        mouse_post(kCGEventLeftMouseDown, p);
        if (jiggle) {
            for (int k = 2; k <= jiggle; k += 2) { mouse_post(kCGEventLeftMouseDragged, CGPointMake(p.x + k, p.y)); sleep_ms(10); }
            sleep_ms(60);
            WinRec wg = win_info(wid);
            LOG("drag grab check: window x moved by %.0f (expect %d if grabbed)", wg.bounds.origin.x - w0.bounds.origin.x, jiggle);
            for (int k = jiggle - 2; k >= 0; k -= 2) { mouse_post(kCGEventLeftMouseDragged, CGPointMake(p.x + k, p.y)); sleep_ms(10); }
        } else {
            mouse_post(kCGEventLeftMouseDragged, p);
        }
        sleep_ms(50);
        if (!hk_post(hk, e, sizeof e)) append_err(&r, "%s", e);
        sleep_ms(hold);
        mouse_release_if_down();
        c1 = cursor_pos();
        break;
    }
    }
    CFRelease(arr);
    if (!r.attempted) return r;
    bool drag = m == MV_DRAG || m == MV_DRAG_SILICA;
    if (!drag) c1 = cursor_pos();
    poll_move(&r, wid, uuid, cur0, t0);
    if (drag) cursor_restore(c0);
    WinRec w1 = win_info(wid);
    r.f1 = w1.bounds;
    r.frame_ok = w1.ok && rect_eq(r.f0, r.f1);
    r.cursor_moved = fabs(c1.x - c0.x) > 0.5 || fabs(c1.y - c0.y) > 0.5;
    return r;
}

static void print_move(const MoveRes *r) {
    LOG("move[%s] %llu->%llu attempted=%d worked=%d latency=%.1fms desk_switched=%d cursor_moved=%d frame_ok=%d "
        "f0=" RECT_FMT " f1=" RECT_FMT " spaces_after=[%s] err=%s note=%s",
        r->label, r->from, r->to, r->attempted, r->worked, r->latency_ms, r->desk_switched, r->cursor_moved,
        r->frame_ok, RECT_ARGS(r->f0), RECT_ARGS(r->f1), r->spaces_after, r->err[0] ? r->err : "-",
        r->note[0] ? r->note : "-");
}

// ---------------------------------------------------------------- env / list

static NSString *run_cmd(NSString *cmd) {
    FILE *f = popen(cmd.UTF8String, "r");
    if (!f) return @"(popen failed)";
    NSMutableString *s = [NSMutableString string];
    char buf[512];
    while (fgets(buf, sizeof buf, f)) [s appendString:@(buf)];
    int rc = pclose(f);
    NSString *out = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return rc ? [NSString stringWithFormat:@"%@ (exit %d)", out, WEXITSTATUS(rc)] : out;
}

static void print_parent_chain(void) {
    pid_t p = getpid();
    printf("process chain (the GUI app at the top needs Accessibility):\n");
    for (int i = 0; i < 12 && p > 1; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = "";
        proc_pidpath(p, path, sizeof path);
        struct proc_bsdinfo bi;
        if (proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi) break;
        printf("  %d %s\n", p, path);
        p = (pid_t)bi.pbi_ppid;
    }
}

static void print_topology(void) {
    Topo t;
    topo_load(&t);
    printf("displays (%d):\n", t.n);
    for (int i = 0; i < t.n; i++) {
        DisplayRec *d = &t.d[i];
        uint64_t live = display_current(d->uuid);
        printf("  display %d uuid=%s current=%llu (live %llu) user_desktops=%d\n", i, d->uuid, d->current, live,
               user_desktop_count(d));
        for (int j = 0; j < d->n; j++) {
            int desk = topo_desktop_number(&t, d->sp[j].sid);
            printf("    sid=%-6llu type=%d (%s)%s%s\n", d->sp[j].sid, d->sp[j].type,
                   d->sp[j].type == 0 ? "user" : d->sp[j].type == 4 ? "fullscreen" : "other",
                   desk ? [[NSString stringWithFormat:@" Desktop %d", desk] UTF8String] : "",
                   d->sp[j].sid == live ? "  <- current" : "");
        }
    }
}

static void print_hotkey(int id, const char *label) {
    HotKey h = hk_get(id);
    printf("  %3d %-22s err=%d enabled=%d keycode=%u char=0x%04x mods=0x%06x %s\n", id, label, h.err, h.enabled, h.kc,
           h.ch, h.mods, mods_str(h.mods));
}

static id pref(NSString *key, NSString *domain) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain));
}

static int cmd_env(void) {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    printf("os: %s\n", pi.operatingSystemVersionString.UTF8String);
    printf("sip: %s\n", run_cmd(@"/usr/bin/csrutil status").UTF8String);
    printf("AXIsProcessTrusted=%d CGPreflightPostEventAccess=%d CGPreflightScreenCaptureAccess=%d\n",
           AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess());
    print_parent_chain();
    printf("connection id=%d\n", g_cid);
    print_topology();
    printf("spans-displays (Displays have separate Spaces = !spans): %s\n",
           [[pref(@"spans-displays", @"com.apple.spaces") description] UTF8String] ?: "(unset => separate Spaces)");

    printf("symbolic hotkeys:\n");
    for (int n = 1; n <= 16; n++) {
        char l[32];
        snprintf(l, sizeof l, "Switch to Desktop %d", n);
        print_hotkey(HK_DESKTOP_BASE + n - 1, l);
    }
    print_hotkey(79, "Move left a space");
    print_hotkey(80, "Move left a space (alt)");
    print_hotkey(81, "Move right a space");
    print_hotkey(82, "Move right a space (alt)");
    printf("  scan 0-255 for left/right-arrow bindings (keycode 123/124):\n");
    for (int id = 0; id < 256; id++) {
        HotKey h = hk_get(id);
        if (!h.err && (h.kc == 123 || h.kc == 124)) print_hotkey(id, h.kc == 123 ? "<left arrow>" : "<right arrow>");
    }

    uint32_t nsyms = 0;
    __block int shown = 0;
    printf("mach-o: SkyLight symtab walk:\n");
    int rc = macho_walk(SKYLIGHT_PATH, &nsyms, ^bool(const char *name, uint8_t type, uint64_t addr) {
        if (strstr(name, "BridgedWindowManagementOperation") && !strstr(name, "OBJC") && shown < 12) {
            printf("    %s type=0x%02x addr=0x%llx\n", name, type, addr);
            shown++;
        }
        return false;
    });
    printf("  walk rc=%d nsyms=%u\n", rc, nsyms);
    printf("  SLSPerformAsynchronousBridgedWindowManagementOperation resolved=%s (%p)\n",
           f_bridged_perform ? "yes" : "NO", f_bridged_perform);
    printf("  dlsym(SLSPerformAsynchronousBridgedWindowManagementOperation)=%p\n",
           dlsym(RTLD_DEFAULT, "SLSPerformAsynchronousBridgedWindowManagementOperation"));

    printf("dock mru-spaces (Automatically rearrange Spaces): %s\n",
           [[pref(@"mru-spaces", @"com.apple.dock") description] UTF8String] ?: "(unset => default ON)");
    printf("dock workspaces-swoosh-animation-off: %s\n",
           [[pref(@"workspaces-swoosh-animation-off", @"com.apple.dock") description] UTF8String] ?: "(unset)");
    printf("dock expose-animation-duration: %s\n",
           [[pref(@"expose-animation-duration", @"com.apple.dock") description] UTF8String] ?: "(unset)");
    printf("AppleSpacesSwitchOnActivate: %s\n",
           [[pref(@"AppleSpacesSwitchOnActivate", @"NSGlobalDomain") description] UTF8String] ?: "(unset => default ON)");
    printf("reduce motion: NSWorkspace=%d universalaccess.reduceMotion=%s\n",
           [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion],
           [[pref(@"reduceMotion", @"com.apple.universalaccess") description] UTF8String] ?: "(unset)");
    printf("defaults read com.apple.dock mru-spaces: %s\n", run_cmd(@"/usr/bin/defaults read com.apple.dock mru-spaces 2>&1").UTF8String);
    return 0;
}

static int cmd_list(const char *filter) {
    NSArray *arr = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSString *f = filter ? [@(filter) lowercaseString] : nil;
    NSMutableDictionary<NSNumber *, NSDictionary *> *axTitles = [NSMutableDictionary dictionary];
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowLayer] intValue] != 0) continue;
        NSString *owner = d[(id)kCGWindowOwnerName] ?: @"?";
        if (f && ![[owner lowercaseString] containsString:f]) continue;
        uint32_t wid = [d[(id)kCGWindowNumber] unsignedIntValue];
        pid_t pid = [d[(id)kCGWindowOwnerPID] intValue];
        NSString *title = d[(id)kCGWindowName];
        if (!title.length) {
            NSDictionary *m = axTitles[@(pid)];
            if (!m) {
                NSMutableDictionary *mm = [NSMutableDictionary dictionary];
                for (id el in ax_windows(pid, NULL)) {
                    NSString *tt = ax_str((__bridge AXUIElementRef)el, kAXTitleAttribute);
                    if (tt) mm[@(ax_wid((__bridge AXUIElementRef)el))] = tt;
                }
                axTitles[@(pid)] = m = mm;
            }
            title = m[@(wid)] ? [@"(ax) " stringByAppendingString:m[@(wid)]] : @"";
        }
        CGRect b;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &b);
        printf("wid=%-6u pid=%-6d owner=%-20s spaces=[%s] frame=" RECT_FMT " title=%s\n", wid, pid, owner.UTF8String,
               spaces_cstr(window_spaces(wid)), RECT_ARGS(b), title.UTF8String);
    }
    return 0;
}

// ---------------------------------------------------------------- test

static struct {
    bool active, cleaned, te_was_running;
    uint32_t wid;
    pid_t pid;
    char uuid[64], file[1024];
    uint64_t user_sid, home_sid;
    CGPoint cursor0;
} T;

static bool close_test_window(void) {
    AXUIElementRef w = ax_find(T.pid, T.wid);
    if (!w) { LOG("close: AX window %u not found", T.wid); return false; }
    AXUIElementRef cb = ax_child(w, kAXCloseButtonAttribute);
    CFRelease(w);
    if (!cb) { LOG("close: no close button"); return false; }
    AXError e = AXUIElementPerformAction(cb, kAXPressAction);
    CFRelease(cb);
    for (int i = 0; i < 100; i++) {
        if (!win_info(T.wid).ok) { LOG("close: window %u gone (press err=%d)", T.wid, e); return true; }
        sleep_ms(20);
    }
    LOG("close: window %u still present after press (err=%d)", T.wid, e);
    return false;
}

static int textedit_other_windows(pid_t pid) {
    NSArray *arr = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    int n = 0;
    for (NSDictionary *d in arr) {
        if ([d[(id)kCGWindowOwnerPID] intValue] != pid || [d[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([d[(id)kCGWindowNumber] unsignedIntValue] == T.wid) continue;
        if ([d[(id)kCGWindowName] length]) n++;
    }
    return n + (int)ax_windows(pid, NULL).count;
}

static void test_cleanup(const char *why) {
    if (!T.active || T.cleaned) return;
    T.cleaned = true;
    LOG("cleanup (%s)", why);
    mouse_release_if_down();
    if (T.wid && win_info(T.wid).ok) {
        NSArray *s = window_spaces(T.wid);
        uint64_t cur = display_current(T.uuid);
        if (s.count == 1 && [s[0] unsignedLongLongValue] != cur) {
            LOG("cleanup: test window on space %llu, switching there to close it", [s[0] unsignedLongLongValue]);
            switch_auto([s[0] unsignedLongLongValue], 0, true);
            sleep_ms(300);
        }
        close_test_window();
    }
    if (T.file[0]) unlink(T.file);
    // Quit before the final desktop restore: the app activated after the quit
    // can pull the display to its own Space (AppleSpacesSwitchOnActivate).
    if (!T.te_was_running && T.pid) {
        sleep_ms(300);
        int other = textedit_other_windows(T.pid);
        if (other == 0) {
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:T.pid];
            LOG("cleanup: TextEdit was not running before and has no windows; terminate=%d", [app terminate]);
            sleep_ms(1500);
        } else {
            LOG("cleanup: TextEdit has %d other window(s); leaving it running", other);
        }
    }
    if (display_current(T.uuid) != T.user_sid) switch_auto(T.user_sid, 0, true);
    cursor_restore(T.cursor0);
    CGPoint c = cursor_pos();
    LOG("cleanup done: desktop current=%llu (user's original %llu) cursor=(%.0f,%.0f) saved=(%.0f,%.0f)",
        display_current(T.uuid), T.user_sid, c.x, c.y, T.cursor0.x, T.cursor0.y);
}

static void on_signal(int sig) {
    LOG("signal %d", sig);
    test_cleanup("signal");
    signal(sig, SIG_DFL);
    raise(sig);
}

static void at_exit(void) { test_cleanup("exit"); }

static bool find_test_window(NSString *token, int timeout_ms) {
    uint64_t deadline = now_ns() + (uint64_t)timeout_ms * 1000000ull;
    while (now_ns() < deadline) {
        @autoreleasepool {
            NSMutableSet *pids = [NSMutableSet set];
            for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"])
                [pids addObject:@(a.processIdentifier)];
            NSArray *cg = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
            for (NSDictionary *d in cg)
                if ([d[(id)kCGWindowOwnerName] isEqualToString:@"TextEdit"]) [pids addObject:d[(id)kCGWindowOwnerPID]];
            for (NSNumber *p in pids) {
                for (id el in ax_windows(p.intValue, NULL)) {
                    NSString *title = ax_str((__bridge AXUIElementRef)el, kAXTitleAttribute);
                    if ([title containsString:token]) {
                        T.pid = p.intValue;
                        T.wid = ax_wid((__bridge AXUIElementRef)el);
                        if (T.wid) return true;
                    }
                }
            }
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    }
    return false;
}

static bool ensure_home(uint32_t wid) {
    if (display_current(T.uuid) != T.home_sid && !switch_auto(T.home_sid, wid, true)) return false;
    NSArray *s = window_spaces(wid);
    if (spaces_is(s, T.home_sid)) return true;
    LOG("ensure_home: window on [%s], expected %llu; trying bridged move back", spaces_cstr(s), T.home_sid);
    MoveRes r = do_move(MV_BRIDGED, wid, T.home_sid);
    print_move(&r);
    return r.worked;
}

typedef struct { char what[64]; char ax_inactive[16]; char ax_active[16]; MoveRes there, back; bool has_back; } Row;

// SPIKE_ONLY=comma list of sw-hotkey,sw-arrow,sw-gesture,sw-bridged,sw-bridged3,mv-legacy,mv-compat,mv-fallback,mv-bridged,mv-drag
static bool selected(const char *tok) {
    const char *only = getenv("SPIKE_ONLY");
    if (!only || !*only) return true;
    NSArray *parts = [@(only) componentsSeparatedByString:@","];
    return [parts containsObject:@(tok)];
}

static const char *yesno(bool b) { return b ? "yes" : "no"; }

static int cmd_test(void) {
    if (!AXIsProcessTrusted()) {
        printf("AXIsProcessTrusted() = false. Grant Accessibility to the GUI app hosting this process:\n");
        print_parent_chain();
        return 2;
    }
    memset(&T, 0, sizeof T);
    T.cursor0 = cursor_pos();
    T.te_was_running = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"].count > 0;

    Topo t;
    topo_load(&t);
    int cd = 0;
    if (f_SLSCopyBestManagedDisplayForPoint) {
        CFStringRef s = f_SLSCopyBestManagedDisplayForPoint(g_cid, T.cursor0);
        for (int i = 0; s && i < t.n; i++) if ([(__bridge NSString *)s isEqualToString:@(t.d[i].uuid)]) cd = i;
        if (s) CFRelease(s);
    }
    T.user_sid = t.d[cd].current;
    strlcpy(T.uuid, t.d[cd].uuid, sizeof T.uuid);
    LOG("start: cursor=(%.0f,%.0f) display=%s user desktop sid=%llu (Desktop %d) TextEdit running before=%d", T.cursor0.x,
        T.cursor0.y, T.uuid, T.user_sid, topo_desktop_number(&t, T.user_sid), T.te_was_running);

    NSString *dir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSString *token = [NSString stringWithFormat:@"tilos-spike-%d-%ld", getpid(), (long)time(NULL)];
    NSString *path = [dir stringByAppendingPathComponent:[token stringByAppendingString:@".txt"]];
    if (![@"tilos native-spaces spike test window. Safe to close.\n" writeToFile:path atomically:YES
                                                                         encoding:NSUTF8StringEncoding error:nil]) {
        LOG("cannot write %s", path.UTF8String);
        return 1;
    }
    strlcpy(T.file, path.UTF8String, sizeof T.file);
    T.active = true;
    atexit(at_exit);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGSEGV, on_signal);
    signal(SIGBUS, on_signal);
    signal(SIGABRT, on_signal);

    LOG("open -g -a TextEdit %s -> %s", T.file, run_cmd([NSString stringWithFormat:@"/usr/bin/open -g -a TextEdit '%@' 2>&1", path]).UTF8String);
    if (!find_test_window(token, 10000)) { LOG("test window not found via AX within 10s"); return 1; }
    uint32_t wid = T.wid;
    WinRec w = win_info(wid);
    CFStringRef du = f_SLSCopyManagedDisplayForWindow(g_cid, wid);
    if (du) { strlcpy(T.uuid, [(__bridge NSString *)du UTF8String], sizeof T.uuid); CFRelease(du); }
    NSArray *s0 = window_spaces(wid);
    T.home_sid = s0.count == 1 ? [s0[0] unsignedLongLongValue] : 0;
    LOG("test window wid=%u pid=%d cg_title='%s' frame=" RECT_FMT " display=%s spaces=[%s]", wid, T.pid, w.title,
        RECT_ARGS(w.bounds), T.uuid, spaces_cstr(s0));
    if (!T.home_sid) { LOG("window not on exactly one space"); return 1; }

    topo_load(&t);
    int si, di = topo_find(&t, T.home_sid, &si);
    if (di < 0 || user_desktop_count(&t.d[di]) < 2) {
        LOG("STOP: display has %d user desktop(s); need 2. Not creating Spaces.", di < 0 ? 0 : user_desktop_count(&t.d[di]));
        return 3;
    }
    uint64_t other = 0;
    for (int j = si + 1; j < t.d[di].n && !other; j++) if (t.d[di].sp[j].type == 0) other = t.d[di].sp[j].sid;
    for (int j = si - 1; j >= 0 && !other; j--) if (t.d[di].sp[j].type == 0) other = t.d[di].sp[j].sid;
    LOG("home sid=%llu (Desktop %d) other sid=%llu (Desktop %d)", T.home_sid, topo_desktop_number(&t, T.home_sid), other,
        topo_desktop_number(&t, other));
    char ax[512];
    LOG("AX baseline: listed=%d %s", ax_lists(T.pid, wid, ax, sizeof ax), ax);

    // Switching behaviour, probed by the test window's on-screen flag.
    SwitchRes sw[12];
    int nsw = 0;
    SwMethod sms[] = {SW_HOTKEY, SW_ARROW, SW_GESTURE, SW_BRIDGED, SW_BRIDGED3};
    const char *swtok[] = {"sw-hotkey", "sw-arrow", "sw-gesture", "sw-bridged", "sw-bridged3"};
    for (int i = 0; i < 5; i++) {
        if (!selected(swtok[i])) continue;
        if (!ensure_home(wid)) { LOG("STOP: cannot restore home desktop"); return 1; }
        sleep_ms(300);
        sw[nsw] = do_switch(sms[i], other, wid, false);
        print_switch(&sw[nsw]);
        nsw++;
        sleep_ms(300);
        if (display_current(T.uuid) != T.home_sid) {
            sw[nsw] = do_switch(sms[i], T.home_sid, wid, true);
            print_switch(&sw[nsw]);
            nsw++;
        }
        if (sms[i] == SW_BRIDGED || sms[i] == SW_BRIDGED3) {
            WinRec ww = win_info(wid);
            LOG("post-bridged-switch consistency: current=%llu window onscreen=%d (expect 1 on home)",
                display_current(T.uuid), ww.onscreen);
        }
    }

    // Moves.
    Row rows[10];
    int nrows = 0;
    bool ax_done = false;
    MvMethod mms[] = {MV_LEGACY, MV_COMPAT, MV_FALLBACK, MV_BRIDGED, MV_DRAG_SILICA, MV_DRAG};
    const char *mvtok[] = {"mv-legacy", "mv-compat", "mv-fallback", "mv-bridged", "mv-drag-silica", "mv-drag"};
    for (int i = 0; i < 6; i++) {
        if (!selected(mvtok[i])) continue;
        if (!ensure_home(wid)) { LOG("STOP: cannot restore window/desktop to home"); break; }
        sleep_ms(300);
        Row *row = &rows[nrows++];
        memset(row, 0, sizeof *row);
        strlcpy(row->what, mv_name[mms[i]], sizeof row->what);
        strcpy(row->ax_inactive, "n/a");
        strcpy(row->ax_active, "n/a");
        row->there = do_move(mms[i], wid, other);
        print_move(&row->there);
        if (!row->there.worked) continue;

        bool on_other = display_current(T.uuid) == other;
        if (!on_other) {
            int l = ax_lists(T.pid, wid, ax, sizeof ax);
            snprintf(row->ax_inactive, sizeof row->ax_inactive, "%s", l < 0 ? "err" : l ? "listed" : "absent");
            LOG("AX while window on inactive desktop: %s", ax);
        } else {
            int l = ax_lists(T.pid, wid, ax, sizeof ax);
            snprintf(row->ax_active, sizeof row->ax_active, "%s", l < 0 ? "err" : l ? "listed" : "absent");
            LOG("AX while window on active (switched-to) desktop: %s", ax);
        }
        if (!ax_done) {
            if (!on_other) {
                switch_auto(other, 0, true);
                sleep_ms(300);
                int l = ax_lists(T.pid, wid, ax, sizeof ax);
                snprintf(row->ax_active, sizeof row->ax_active, "%s", l < 0 ? "err" : l ? "listed" : "absent");
                LOG("AX after switching to the window's desktop: %s", ax);
                switch_auto(T.home_sid, 0, true);
            } else {
                switch_auto(T.home_sid, 0, true);
                sleep_ms(300);
                int l = ax_lists(T.pid, wid, ax, sizeof ax);
                snprintf(row->ax_inactive, sizeof row->ax_inactive, "%s", l < 0 ? "err" : l ? "listed" : "absent");
                LOG("AX after leaving the window's desktop: %s", ax);
                switch_auto(other, 0, true);
            }
            sleep_ms(300);
            ax_done = true;
        }
        if ((mms[i] == MV_DRAG || mms[i] == MV_DRAG_SILICA) && display_current(T.uuid) != other) {
            switch_auto(other, 0, true);
            sleep_ms(300);
        }
        row->has_back = true;
        row->back = do_move(mms[i], wid, T.home_sid);
        print_move(&row->back);
        sleep_ms(300);
        int l = ax_lists(T.pid, wid, ax, sizeof ax);
        LOG("AX after move back: listed=%d %s", l, ax);
    }
    ensure_home(wid);

    test_cleanup("end of test");

    printf("\n## switching (Desktop %d <-> %d)\n\n", topo_desktop_number(&t, T.home_sid), topo_desktop_number(&t, other));
    printf("| method | dir | posted | reached | t_call ms | t_current ms | t_window_visibility ms | cursor moved | err |\n");
    printf("|---|---|---|---|---|---|---|---|---|\n");
    for (int i = 0; i < nsw; i++)
        printf("| %s | %d->%d | %s | %s | %.1f | %.1f | %.1f | %s | %s |\n", sw_name[sw[i].m], sw[i].from_desk,
               sw[i].to_desk, yesno(sw[i].posted), yesno(sw[i].reached && sw[i].probe_ok), sw[i].t_call_ms, sw[i].t_current_ms,
               sw[i].t_probe_ms, yesno(sw[i].cursor_moved), sw[i].err[0] ? sw[i].err : "");
    printf("\n## moves (sid %llu <-> %llu)\n\n", T.home_sid, other);
    printf("| method | dir | worked | latency ms | desktop switched | cursor moved | frame preserved | AX inactive | AX active | errors |\n");
    printf("|---|---|---|---|---|---|---|---|---|---|\n");
    for (int i = 0; i < nrows; i++) {
        for (int k = 0; k < (rows[i].has_back ? 2 : 1); k++) {
            MoveRes *r = k ? &rows[i].back : &rows[i].there;
            printf("| %s | %s | %s | %.1f | %s | %s | %s | %s | %s | %s %s |\n", rows[i].what, k ? "back" : "there",
                   r->attempted ? yesno(r->worked) : "not attempted", r->latency_ms, yesno(r->desk_switched),
                   yesno(r->cursor_moved), yesno(r->frame_ok), k ? "" : rows[i].ax_inactive, k ? "" : rows[i].ax_active,
                   r->err, r->note);
        }
    }
    return 0;
}

// ---------------------------------------------------------------- main

static int resolve_target(int desk, uint64_t *sid) {
    Topo t;
    topo_load(&t);
    int di, si;
    if (!topo_desktop(&t, desk, &di, &si)) { printf("no Desktop %d\n", desk); return 1; }
    *sid = t.d[di].sp[si].sid;
    return 0;
}

static int cmd_move(MvMethod m, uint32_t wid, int desk) {
    uint64_t sid;
    if (resolve_target(desk, &sid)) return 1;
    WinRec w = win_info(wid);
    LOG("window %u owner=%s spaces=[%s] -> Desktop %d (sid %llu)", wid, w.owner, spaces_cstr(window_spaces(wid)), desk, sid);
    MoveRes r = do_move(m, wid, sid);
    print_move(&r);
    if (m == MV_LEGACY && !r.worked) {
        r = do_move(MV_COMPAT, wid, sid);
        print_move(&r);
    }
    if (r.worked && !r.desk_switched) {
        char ax[512];
        LOG("AX lists window while its desktop is inactive: %d (%s)", ax_lists(w.pid, wid, ax, sizeof ax), ax);
    }
    return r.worked ? 0 : 1;
}

static int cmd_switch(SwMethod m, int desk) {
    uint64_t sid;
    if (resolve_target(desk, &sid)) return 1;
    SwitchRes r = do_switch(m, sid, 0, true);
    print_switch(&r);
    return r.reached ? 0 : 1;
}

static void usage(void) {
    printf("usage: spike env | list [owner] | where <wid> | switch <n> | switch-arrow <n> | switch-gesture <n> | switch-bridged <n> | switch-bridged3 <n>\n"
           "             | move-bridged <wid> <n> | move-fallback <wid> <n> | move-legacy <wid> <n> | move-drag <wid> <n>\n"
           "             | move-drag-silica <wid> <n> | test\n"
           "  n = Mission Control Desktop number (global across displays)\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        g_t0 = now_ns();
        setvbuf(stdout, NULL, _IOLBF, 0);
        load_symbols();
        AXUIElementRef sys = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(sys, 2.0);
        CFRelease(sys);
        if (argc < 2) { usage(); return 1; }
        const char *c = argv[1];
        if (!strcmp(c, "env")) return cmd_env();
        if (!strcmp(c, "list")) return cmd_list(argc > 2 ? argv[2] : NULL);
        if (!strcmp(c, "where") && argc > 2) {
            uint32_t wid = (uint32_t)atoi(argv[2]);
            WinRec w = win_info(wid);
            printf("wid=%u ok=%d owner=%s onscreen=%d frame=" RECT_FMT " spaces=[%s]\n", wid, w.ok, w.owner, w.onscreen,
                   RECT_ARGS(w.bounds), spaces_cstr(window_spaces(wid)));
            return 0;
        }
        if (!strcmp(c, "switch") && argc > 2) return cmd_switch(SW_HOTKEY, atoi(argv[2]));
        if (!strcmp(c, "switch-arrow") && argc > 2) return cmd_switch(SW_ARROW, atoi(argv[2]));
        if (!strcmp(c, "switch-gesture") && argc > 2) return cmd_switch(SW_GESTURE, atoi(argv[2]));
        if (!strcmp(c, "switch-bridged") && argc > 2) return cmd_switch(SW_BRIDGED, atoi(argv[2]));
        if (!strcmp(c, "switch-bridged3") && argc > 2) return cmd_switch(SW_BRIDGED3, atoi(argv[2]));
        if (argc > 3) {
            uint32_t wid = (uint32_t)atoi(argv[2]);
            int n = atoi(argv[3]);
            if (!strcmp(c, "move-bridged")) return cmd_move(MV_BRIDGED, wid, n);
            if (!strcmp(c, "move-fallback")) return cmd_move(MV_FALLBACK, wid, n);
            if (!strcmp(c, "move-legacy")) return cmd_move(MV_LEGACY, wid, n);
            if (!strcmp(c, "move-drag")) return cmd_move(MV_DRAG, wid, n);
            if (!strcmp(c, "move-drag-silica")) return cmd_move(MV_DRAG_SILICA, wid, n);
        }
        if (!strcmp(c, "test")) return cmd_test();
        usage();
        return 1;
    }
}
