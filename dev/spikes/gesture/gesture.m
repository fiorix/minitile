// Throwaway spike: can a session event tap see, and swallow, the trackpad swipe
// that the Dock uses to switch desktops and open Mission Control?
//
// It never moves windows. It quits by itself after GESTURE_SECONDS, so a
// blocking tap cannot outlive the test.
//
// Environment:
//   GESTURE_MODE     observe (default; listen only) or block (swallow matching events)
//   GESTURE_SECONDS  run time, default 30
//   GESTURE_TYPES    event types to swallow in block mode, comma-separated, default "30"
//   GESTURE_TAP      session (default) or hid
//
// Each event line shows the private gesture fields that other tools use for Dock
// swipes: 110 HID event type, 132 phase, 123 swipe motion, 124 progress,
// 129/130 velocity. The first event of each (type, HID type, phase) also dumps
// every nonzero field, so unknown layouts still show up.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static BOOL blocking;
static NSSet<NSNumber *> *blockTypes;
static NSMutableSet<NSString *> *dumped;
static NSMutableDictionary<NSString *, NSNumber *> *counts;
static CFMachPortRef tap;
static uint64_t started;

static double now_s(void) { return (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9; }

static void say(const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *text = NULL;
    vasprintf(&text, format, args);
    va_end(args);
    printf("[%8.3f] %s\n", now_s(), text);
    free(text);
}

// Keyboard, mouse buttons, movement and scrolling are noise here.
static BOOL ordinary(CGEventType type) {
    return (type >= 1 && type <= 12) || (type >= 22 && type <= 27);
}

static void dump(CGEventRef event, CGEventType type, int64_t hid, int64_t phase) {
    NSString *key = [NSString stringWithFormat:@"%u/%lld/%lld", type, hid, phase];
    if ([dumped containsObject:key]) return;
    [dumped addObject:key];
    NSMutableString *fields = [NSMutableString string];
    for (int field = 0; field < 256; field++) {
        int64_t integer = CGEventGetIntegerValueField(event, (CGEventField)field);
        double real = CGEventGetDoubleValueField(event, (CGEventField)field);
        if (integer != 0 || real != 0) [fields appendFormat:@" %d=%lld/%.4g", field, integer, real];
    }
    say("  first type=%u hid=%lld phase=%lld fields:%s", type, hid, phase, fields.UTF8String);
}

static CGEventRef callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        say("tap disabled (%u); re-enabling", type);
        CGEventTapEnable(tap, true);
        return event;
    }
    if (ordinary(type)) return event;
    int64_t hid = CGEventGetIntegerValueField(event, (CGEventField)110);
    int64_t phase = CGEventGetIntegerValueField(event, (CGEventField)132);
    int64_t motion = CGEventGetIntegerValueField(event, (CGEventField)123);
    double progress = CGEventGetDoubleValueField(event, (CGEventField)124);
    double vx = CGEventGetDoubleValueField(event, (CGEventField)129);
    double vy = CGEventGetDoubleValueField(event, (CGEventField)130);
    BOOL swallow = blocking && [blockTypes containsObject:@(type)];
    NSString *key = [NSString stringWithFormat:@"type=%u hid=%lld%@", type, hid, swallow ? @" swallowed" : @""];
    counts[key] = @(counts[key].integerValue + 1);
    // Raw touch frames (type 29) arrive continuously; they are counted and dumped once, not printed.
    if (type != 29) say("type=%u hid=%lld phase=%lld motion=%lld progress=%.3f vx=%.1f vy=%.1f%s",
                        type, hid, phase, motion, progress, vx, vy, swallow ? " SWALLOWED" : "");
    dump(event, type, hid, phase);
    return swallow ? NULL : event;
}

static void finish(int code) {
    say("summary:");
    for (NSString *key in [counts.allKeys sortedArrayUsingSelector:@selector(compare:)]) say("  %s: %ld events", key.UTF8String, counts[key].longValue);
    say("exit %d", code);
    exit(code);
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
        NSString *mode = env[@"GESTURE_MODE"] ?: @"observe";
        double seconds = env[@"GESTURE_SECONDS"] ? env[@"GESTURE_SECONDS"].doubleValue : 30;
        blocking = [mode isEqual:@"block"];
        NSMutableSet *types = [NSMutableSet set];
        for (NSString *part in [env[@"GESTURE_TYPES"] ?: @"30" componentsSeparatedByString:@","]) [types addObject:@(part.intValue)];
        blockTypes = types;
        dumped = [NSMutableSet set];
        counts = [NSMutableDictionary dictionary];
        BOOL hid = [env[@"GESTURE_TAP"] isEqual:@"hid"];

        NSDictionary *prompt = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)prompt)) {
            say("Accessibility is not granted to GestureSpike. Grant it in System Settings > Privacy & Security > Accessibility, then run again.");
            finish(2);
        }
        tap = CGEventTapCreate(hid ? kCGHIDEventTap : kCGSessionEventTap, kCGHeadInsertEventTap,
                               blocking ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly,
                               kCGEventMaskForAllEvents, callback, NULL);
        if (!tap) { say("could not create the event tap"); finish(1); }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(NULL, tap, 0), kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);
        NSMutableArray *names = [NSMutableArray array];
        for (NSNumber *type in types) [names addObject:type.stringValue];
        say("mode=%s tap=%s seconds=%.0f%s", mode.UTF8String, hid ? "hid" : "session", seconds,
            blocking ? [NSString stringWithFormat:@" swallowing types %@", [names componentsJoinedByString:@","]].UTF8String : "");
        say("swipe now: left, right, up, down, a couple of times each");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(0); });
        CFRunLoopRun();
    }
    return 0;
}
