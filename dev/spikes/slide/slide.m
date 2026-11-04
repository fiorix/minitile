// Throwaway spike: validates page transitions drawn as a snapshot slide.
//
// It captures the visible frame with ScreenCaptureKit, covers it with a
// click-through overlay showing that image, swaps two "pages" of this
// process's own windows between the visible desktop and the stash underneath
// (the bridged SkyLight move minitile uses), captures the new page and slides
// one image out and the other in. At an edge of the grid it bounces the
// snapshot instead. Only windows this process creates are moved.
//
// Spike-only shortcut: the overlay takes key and main status during a
// transition, so macOS does not follow this app's own windows to the stash.
// minitile's overlay must never take focus.
//
// Keys while a spike window is focused: arrows navigate, Q or Escape quits.
// Environment:
//   SLIDE_MODE       demo (default; 12 steps, then quits), interactive or measure
//   SLIDE_MS         slide duration, default 500
//   SLIDE_BOUNCE_MS  edge bounce duration, default 300
//   SLIDE_COVER_MS   delay between showing the overlay and moving windows, default 16
//   SLIDE_WAIT_MS    delay between moving windows and the second capture, default 20
//   SLIDE_SCALE      capture scale relative to the backing scale, default 1
//   SLIDE_CURVE      cubic bezier "x1,y1,x2,y2", default "0.4,0,0.2,1"
//   SLIDE_OVERLAP    1 (default) starts the slide before the new page is captured;
//                    0 waits for the capture first

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>

#define SKYLIGHT_PATH "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
#define BRIDGED_SYMBOL "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

@interface NSObject (SlideBridged)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)space;
@end

static int connection;
static int (*main_connection)(void);
static CFArrayRef (*managed_spaces)(int);
static uint64_t (*current_space)(int, CFStringRef);
static CFArrayRef (*window_spaces)(int, int, CFArrayRef);
static int64_t (*perform)(void *);
static Class move_class;

static double now_ms(void) { return CACurrentMediaTime() * 1000.0; }

static void say(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stdout, "[%10.1f] ", now_ms());
    vfprintf(stdout, format, args);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(args);
}

static double env_double(const char *name, double fallback) {
    const char *value = getenv(name);
    return value && *value ? atof(value) : fallback;
}

static dispatch_time_t after_ms(double ms) { return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)); }

// Walks the in-memory LC_SYMTAB, as yabai does, for the unexported bridged function.
static void *local_symbol(const char *image, const char *symbol) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strcmp(name, image)) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (header->magic != MH_MAGIC_64) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *lc = (const void *)cursor;
            if (lc->cmd == LC_SEGMENT_64 && !strncmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT, 16))
                linkedit = (const void *)lc;
            if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
            cursor += lc->cmdsize;
        }
        if (!linkedit || !symtab) return NULL;
        uintptr_t base = (uintptr_t)(linkedit->vmaddr - linkedit->fileoff + slide);
        const char *strings = (const char *)(base + symtab->stroff);
        const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
        for (uint32_t s = 0; s < symtab->nsyms; s++) {
            uint32_t offset = symbols[s].n_un.n_strx;
            if (offset < symtab->strsize && symbols[s].n_value && !strcmp(strings + offset, symbol))
                return (void *)(symbols[s].n_value + slide);
        }
    }
    return NULL;
}

static BOOL skylight_init(void) {
    if (!dlopen(SKYLIGHT_PATH, RTLD_NOW | RTLD_GLOBAL)) return NO;
    *(void **)&main_connection = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    *(void **)&managed_spaces = dlsym(RTLD_DEFAULT, "SLSCopyManagedDisplaySpaces");
    *(void **)&current_space = dlsym(RTLD_DEFAULT, "SLSManagedDisplayGetCurrentSpace");
    *(void **)&window_spaces = dlsym(RTLD_DEFAULT, "SLSCopySpacesForWindows");
    *(void **)&perform = local_symbol(SKYLIGHT_PATH, BRIDGED_SYMBOL);
    move_class = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!main_connection || !managed_spaces || !current_space || !window_spaces || !perform || !move_class) return NO;
    connection = main_connection();
    return YES;
}

static void move_windows(NSArray<NSNumber *> *ids, uint64_t space) {
    if (!ids.count) return;
    id operation = [[move_class alloc] initWithWindows:ids spaceID:space];
    perform((__bridge void *)operation);
}

static NSArray<NSNumber *> *spaces_of(NSWindow *window) {
    NSArray *ids = @[@(window.windowNumber)];
    return CFBridgingRelease(window_spaces(connection, 0x7, (__bridge CFArrayRef)ids));
}

static NSArray<NSNumber *> *ids_of(NSArray<NSWindow *> *windows) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSWindow *window in windows) [ids addObject:@(window.windowNumber)];
    return ids;
}

// Downsampled pixels for comparing captures.
static NSData *thumbnail(CGImageRef image) {
    size_t w = 64, h = 40;
    NSMutableData *data = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data.mutableBytes, w, h, 8, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return data;
}

static double difference(NSData *a, NSData *b) {
    const uint8_t *x = a.bytes, *y = b.bytes;
    double total = 0;
    for (NSUInteger i = 0; i < a.length; i++) total += abs((int)x[i] - (int)y[i]);
    return total / a.length;
}

static NSValue *point_value(CGPoint p) { return [NSValue valueWithPoint:NSPointFromCGPoint(p)]; }

@interface Overlay : NSPanel
@end

@implementation Overlay
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface Tile : NSView
@property(strong) NSColor *color;
@property(copy) NSString *label;
@end

@implementation Tile
- (void)drawRect:(NSRect)dirty {
    [self.color setFill];
    NSRectFill(self.bounds);
    [[NSColor colorWithWhite:1 alpha:0.15] setFill];
    for (CGFloat x = 0; x < self.bounds.size.width; x += 48) NSRectFill(NSMakeRect(x, 0, 3, self.bounds.size.height));
    NSDictionary *big = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:56], NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize size = [self.label sizeWithAttributes:big];
    [self.label drawAtPoint:NSMakePoint((self.bounds.size.width - size.width) / 2, (self.bounds.size.height - size.height) / 2) withAttributes:big];
    NSDictionary *small = @{NSFontAttributeName: [NSFont systemFontOfSize:14], NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.85]};
    [@"arrows: navigate    q: quit" drawAtPoint:NSMakePoint(12, 10) withAttributes:small];
}
@end

@interface Spike : NSObject <NSApplicationDelegate>
@end

@implementation Spike {
    NSScreen *_screen;
    NSString *_displayIdentifier;
    NSRect _visibleFrame;
    uint64_t _visible, _stash;
    NSMutableArray<NSMutableArray<NSMutableArray<NSWindow *> *> *> *_grid;
    NSMutableArray<NSNumber *> *_lastPage;
    int _workspace, _page;
    Overlay *_overlay;
    CALayer *_outgoing, *_incoming;
    SCDisplay *_display;
    SCWindow *_overlayWindow;
    SCContentFilter *_filter;
    SCStreamConfiguration *_config;
    double _slideMs, _bounceMs, _coverMs, _waitMs, _scale;
    BOOL _overlap;
    CAMediaTimingFunction *_curve;
    NSString *_mode;
    BOOL _busy, _pending;
    int _pendingDx, _pendingDy;
    id _monitor;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _mode = @(getenv("SLIDE_MODE") ?: "demo");
    _slideMs = env_double("SLIDE_MS", 500);
    _bounceMs = env_double("SLIDE_BOUNCE_MS", 300);
    _coverMs = env_double("SLIDE_COVER_MS", 16);
    _waitMs = env_double("SLIDE_WAIT_MS", 20);
    _scale = env_double("SLIDE_SCALE", 1);
    _overlap = env_double("SLIDE_OVERLAP", 1) != 0;
    float c[4] = {0.4f, 0.0f, 0.2f, 1.0f};
    if (getenv("SLIDE_CURVE")) sscanf(getenv("SLIDE_CURVE"), "%f,%f,%f,%f", &c[0], &c[1], &c[2], &c[3]);
    _curve = [CAMediaTimingFunction functionWithControlPoints:c[0] :c[1] :c[2] :c[3]];
    say("mode=%s slide=%.0fms bounce=%.0fms cover=%.0fms wait=%.0fms scale=%.2f overlap=%d curve=%.2f,%.2f,%.2f,%.2f",
        _mode.UTF8String, _slideMs, _bounceMs, _coverMs, _waitMs, _scale, _overlap, c[0], c[1], c[2], c[3]);

    if (!CGPreflightScreenCaptureAccess()) {
        say("Screen Recording is not granted. Requesting it; enable SlideSpike in System Settings > Privacy & Security > Screen & System Audio Recording, then run again.");
        CGRequestScreenCaptureAccess();
        dispatch_after(after_ms(30000), dispatch_get_main_queue(), ^{ [self quit:3]; });
        return;
    }
    if (!skylight_init()) { say("SkyLight symbols unavailable"); [self quit:1]; return; }

    _screen = NSScreen.screens.firstObject;
    _visibleFrame = _screen.visibleFrame;
    if (![self findSpaces]) { [self quit:1]; return; }
    say("display frame=%s visible=%s scale=%.1f max_fps=%ld reduce_motion=%d",
        NSStringFromRect(_screen.frame).UTF8String, NSStringFromRect(_visibleFrame).UTF8String,
        _screen.backingScaleFactor, (long)_screen.maximumFramesPerSecond,
        NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);

    [NSApp activateIgnoringOtherApps:YES];
    [self buildGrid];
    [self buildOverlay];
    double start = now_ms();
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self shareableContent:content error:error started:start]; });
    }];
}

- (BOOL)findSpaces {
    NSArray *displays = CFBridgingRelease(managed_spaces(connection));
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
    NSString *mainUUID = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    for (NSDictionary *display in displays) {
        NSString *identifier = display[@"Display Identifier"];
        if (![identifier isEqual:@"Main"] && ![identifier isEqual:mainUUID]) continue;
        NSMutableArray<NSNumber *> *users = [NSMutableArray array];
        for (NSDictionary *space in display[@"Spaces"]) if ([space[@"type"] intValue] == 0) [users addObject:space[@"id64"]];
        if (users.count < 2) { say("The main display needs two desktops"); return NO; }
        // The current desktop stands in for minitile's visible desktop; the last one is the stash.
        uint64_t current = current_space(connection, (__bridge CFStringRef)identifier);
        _displayIdentifier = identifier;
        _visible = current;
        _stash = users.lastObject.unsignedLongLongValue;
        say("spaces users=%s visible=%llu stash=%llu", [users componentsJoinedByString:@","].UTF8String, _visible, _stash);
        if (![users containsObject:@(current)] || current == _stash) { say("Switch to a desktop other than the last one and run again"); return NO; }
        return YES;
    }
    say("Main display not found in managed spaces");
    return NO;
}

// Same layout family as minitile: 1 full, 2 halves, 3 large plus two, 4 quarters.
- (NSArray<NSValue *> *)frames:(int)count {
    NSRect area = NSInsetRect(_visibleFrame, 8, 8);
    CGFloat g = 4, x = area.origin.x, y = area.origin.y, w = area.size.width, h = area.size.height;
    NSRect left = NSMakeRect(x, y, w / 2 - g, h), right = NSMakeRect(x + w / 2 + g, y, w / 2 - g, h);
    NSRect rightTop = NSMakeRect(right.origin.x, y + h / 2 + g, right.size.width, h / 2 - g);
    NSRect rightBottom = NSMakeRect(right.origin.x, y, right.size.width, h / 2 - g);
    NSRect leftTop = NSMakeRect(x, y + h / 2 + g, left.size.width, h / 2 - g), leftBottom = NSMakeRect(x, y, left.size.width, h / 2 - g);
    switch (count) {
        case 1: return @[[NSValue valueWithRect:area]];
        case 2: return @[[NSValue valueWithRect:left], [NSValue valueWithRect:right]];
        case 3: return @[[NSValue valueWithRect:left], [NSValue valueWithRect:rightTop], [NSValue valueWithRect:rightBottom]];
        default: return @[[NSValue valueWithRect:leftTop], [NSValue valueWithRect:rightTop], [NSValue valueWithRect:leftBottom], [NSValue valueWithRect:rightBottom]];
    }
}

- (void)buildGrid {
    NSArray *spec = @[@[@4, @2, @3], @[@1, @4]];
    _grid = [NSMutableArray array];
    _lastPage = [NSMutableArray array];
    NSMutableArray<NSNumber *> *hidden = [NSMutableArray array];
    int hue = 0;
    for (NSUInteger w = 0; w < spec.count; w++) {
        NSMutableArray *pages = [NSMutableArray array];
        for (NSUInteger p = 0; p < [spec[w] count]; p++) {
            int count = [spec[w][p] intValue];
            NSArray *frames = [self frames:count];
            NSMutableArray *windows = [NSMutableArray array];
            for (int i = 0; i < count; i++) {
                NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                                 backing:NSBackingStoreBuffered defer:NO];
                window.releasedWhenClosed = NO;
                window.animationBehavior = NSWindowAnimationBehaviorNone;
                Tile *tile = [[Tile alloc] initWithFrame:NSZeroRect];
                tile.color = [NSColor colorWithHue:fmod(hue++ * 0.13, 1.0) saturation:0.55 brightness:0.7 alpha:1];
                tile.label = [NSString stringWithFormat:@"W%lu P%lu #%d", w + 1, p + 1, i + 1];
                window.title = tile.label;
                window.contentView = tile;
                [window setFrame:[frames[i] rectValue] display:YES];
                [window orderFrontRegardless];
                [windows addObject:window];
                if (w != 0 || p != 0) [hidden addObject:@(window.windowNumber)];
            }
            [pages addObject:windows];
        }
        [_grid addObject:pages];
        [_lastPage addObject:@0];
    }
    move_windows(hidden, _stash);
    [_grid[0][0].firstObject makeKeyAndOrderFront:nil];
    dispatch_after(after_ms(300), dispatch_get_main_queue(), ^{
        say("setup: W1P1 window on %s, W1P2 window on %s",
            spaces_of(self->_grid[0][0].firstObject).description.UTF8String, spaces_of(self->_grid[0][1].firstObject).description.UTF8String);
    });
}

- (void)buildOverlay {
    _overlay = [[Overlay alloc] initWithContentRect:_visibleFrame styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                            backing:NSBackingStoreBuffered defer:NO];
    _overlay.level = NSPopUpMenuWindowLevel;
    _overlay.ignoresMouseEvents = YES;
    _overlay.opaque = YES;
    _overlay.hasShadow = NO;
    _overlay.releasedWhenClosed = NO;
    _overlay.animationBehavior = NSWindowAnimationBehaviorNone;
    _overlay.backgroundColor = [NSColor colorWithWhite:0.08 alpha:1];
    _overlay.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
        | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *view = _overlay.contentView;
    view.wantsLayer = YES;
    view.layer.masksToBounds = YES;
    view.layer.backgroundColor = [NSColor colorWithWhite:0.08 alpha:1].CGColor;
    _outgoing = [CALayer layer];
    _incoming = [CALayer layer];
    for (CALayer *layer in @[_outgoing, _incoming]) {
        layer.frame = view.bounds;
        layer.contentsGravity = kCAGravityResize;
        layer.contentsScale = _screen.backingScaleFactor;
        [view.layer addSublayer:layer];
    }
    _overlay.alphaValue = 0;
    [_overlay orderFrontRegardless];
    [_overlay orderOut:nil];
    _overlay.alphaValue = 1;
}

- (void)shareableContent:(SCShareableContent *)content error:(NSError *)error started:(double)start {
    if (!content) { say("shareable content failed: %s", error.description.UTF8String); [self quit:1]; return; }
    for (SCDisplay *display in content.displays) if (display.displayID == CGMainDisplayID()) _display = display;
    for (SCWindow *window in content.windows) if (window.windowID == (CGWindowID)_overlay.windowNumber) _overlayWindow = window;
    say("shareable content %.1f ms, display=%d overlay_window=%d", now_ms() - start, _display != nil, _overlayWindow != nil);
    if (!_display) { [self quit:1]; return; }
    _filter = [[SCContentFilter alloc] initWithDisplay:_display excludingWindows:_overlayWindow ? @[_overlayWindow] : @[]];
    [self configure:_scale];
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        return [self key:event] ? nil : event;
    }];
    if ([_mode isEqual:@"measure"]) [self measure];
    else if ([_mode isEqual:@"demo"]) [self demo];
    else say("interactive: arrows navigate, q quits");
}

- (void)configure:(double)scale {
    NSRect screen = _screen.frame, visible = _visibleFrame;
    CGFloat pixels = _screen.backingScaleFactor * scale;
    _config = [SCStreamConfiguration new];
    _config.sourceRect = CGRectMake(visible.origin.x - screen.origin.x,
                                    screen.size.height - (visible.origin.y - screen.origin.y) - visible.size.height,
                                    visible.size.width, visible.size.height);
    _config.width = (size_t)(visible.size.width * pixels);
    _config.height = (size_t)(visible.size.height * pixels);
    _config.showsCursor = NO;
    _config.pixelFormat = kCVPixelFormatType_32BGRA;
    _config.captureResolution = SCCaptureResolutionBest;
}

- (BOOL)key:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
    if ([characters isEqual:@"q"] || event.keyCode == 53) { [self quit:0]; return YES; }
    int dx = 0, dy = 0;
    switch (event.keyCode) {
        case 123: dx = -1; break;
        case 124: dx = 1; break;
        case 125: dy = 1; break;
        case 126: dy = -1; break;
        default: return NO;
    }
    if (!event.isARepeat) [self navigate:dx dy:dy];
    return YES;
}

- (void)capture:(void (^)(CGImageRef image, double ms))done {
    double start = now_ms();
    [SCScreenshotManager captureImageWithFilter:_filter configuration:_config completionHandler:^(CGImageRef image, NSError *error) {
        if (error) say("capture error: %s", error.description.UTF8String);
        CGImageRef kept = image ? CGImageRetain(image) : NULL;
        double ms = now_ms() - start;
        dispatch_async(dispatch_get_main_queue(), ^{
            done(kept, ms);
            if (kept) CGImageRelease(kept);
        });
    }];
}

- (NSString *)currentSpace {
    uint64_t space = current_space(connection, (__bridge CFStringRef)_displayIdentifier);
    return space == _visible ? @"visible" : space == _stash ? @"stash" : [NSString stringWithFormat:@"%llu", space];
}

- (CGPoint)rest {
    CGSize size = _overlay.contentView.bounds.size;
    return CGPointMake(size.width / 2, size.height / 2);
}

- (void)cover:(CGImageRef)image {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_outgoing removeAllAnimations];
    [_incoming removeAllAnimations];
    _outgoing.contents = (__bridge id)image;
    _outgoing.position = [self rest];
    _outgoing.hidden = NO;
    _incoming.hidden = YES;
    [CATransaction commit];
    [_overlay orderFrontRegardless];
    [_overlay makeKeyWindow];
    [_overlay makeMainWindow];
    [CATransaction flush];
}

- (void)animate:(CALayer *)layer from:(CGPoint)from to:(CGPoint)to {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position"];
    animation.fromValue = point_value(from);
    animation.toValue = point_value(to);
    animation.duration = _slideMs / 1000;
    animation.timingFunction = _curve;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.position = to;
    [CATransaction commit];
    [layer addAnimation:animation forKey:@"slide"];
}

// Right moves content left; Down moves content up (layer y grows upwards).
- (void)slide:(CGImageRef)image dx:(int)dx dy:(int)dy done:(void (^)(void))done {
    CGSize size = _overlay.contentView.bounds.size;
    CGPoint rest = [self rest];
    CGPoint shift = CGPointMake(-dx * size.width, dy * size.height);
    CGPoint start = CGPointMake(rest.x - shift.x, rest.y - shift.y);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _incoming.contents = (__bridge id)image;
    _incoming.position = start;
    _incoming.hidden = NO;
    [CATransaction commit];
    [CATransaction begin];
    [CATransaction setCompletionBlock:done];
    [self animate:_outgoing from:rest to:CGPointMake(rest.x + shift.x, rest.y + shift.y)];
    [self animate:_incoming from:start to:rest];
    [CATransaction commit];
}

- (void)navigate:(int)dx dy:(int)dy {
    if (_busy) { _pending = YES; _pendingDx = dx; _pendingDy = dy; return; }
    int toWorkspace = _workspace + dy, toPage = _page + dx;
    if (dy) {
        if (toWorkspace < 0 || toWorkspace >= (int)_grid.count) { [self bounce:dx dy:dy]; return; }
        toPage = _lastPage[toWorkspace].intValue;
    } else if (toPage < 0 || toPage >= (int)_grid[_workspace].count) { [self bounce:dx dy:dy]; return; }
    _busy = YES;
    double t0 = now_ms();
    int fromWorkspace = _workspace, fromPage = _page;
    NSArray *outgoing = ids_of(_grid[fromWorkspace][fromPage]), *incoming = ids_of(_grid[toWorkspace][toPage]);
    NSWindow *focus = _grid[toWorkspace][toPage].firstObject;
    BOOL overlap = _overlap;
    [self capture:^(CGImageRef first, double firstMs) {
        if (!first) { [self finish]; return; }
        [self cover:first];
        double covered = now_ms();
        id firstImage = (__bridge id)first;
        __block id secondImage = nil;
        __block double motion = 0, ready = 0, secondTook = 0;
        __block NSString *spaceAtCapture = @"?";
        void (^finished)(void) = ^{
            double total = now_ms() - t0;
            NSString *onScreen = [self onScreenPages], *spaceAtEnd = [self currentSpace];
            // Compare both snapshots with the screen under the overlay, before the focus change repaints it.
            // Thumbnails cost about 45 ms each, so they are made here, after the slide.
            [self capture:^(CGImageRef settled, double settledMs) {
                NSData *check = settled ? thumbnail(settled) : nil;
                double vsIncoming = check && secondImage ? difference(thumbnail((__bridge CGImageRef)secondImage), check) : -1;
                double vsOutgoing = check ? difference(thumbnail((__bridge CGImageRef)firstImage), check) : -1;
                [self->_overlay orderOut:nil];
                [focus makeKeyAndOrderFront:nil];
                say("slide %s W%dP%d->W%dP%d overlap=%d capture1=%.1f cover=%.1f capture2=%.1f key_to_motion=%.1f incoming_after_motion=%.1f total=%.1f incoming_vs_settled=%.1f outgoing_vs_settled=%.1f on_screen=%s desktop_at_capture2=%s desktop_at_end=%s",
                    dx > 0 ? "right" : dx < 0 ? "left" : dy > 0 ? "down" : "up",
                    fromWorkspace + 1, fromPage + 1, toWorkspace + 1, toPage + 1, overlap,
                    firstMs, covered - t0 - firstMs, secondTook, motion - t0, ready ? ready - motion : -1, total, vsIncoming, vsOutgoing,
                    onScreen.UTF8String, spaceAtCapture.UTF8String, spaceAtEnd.UTF8String);
                [self finish];
            }];
        };
        // With overlap the incoming half starts dark and gets the new page's image when it arrives.
        if (overlap) { motion = now_ms(); [self slide:NULL dx:dx dy:dy done:finished]; }
        dispatch_after(after_ms(self->_coverMs), dispatch_get_main_queue(), ^{
            move_windows(incoming, self->_visible);
            move_windows(outgoing, self->_stash);
            self->_workspace = toWorkspace;
            self->_page = toPage;
            self->_lastPage[toWorkspace] = @(toPage);
            dispatch_after(after_ms(self->_waitMs), dispatch_get_main_queue(), ^{
                [self capture:^(CGImageRef second, double secondMs) {
                    ready = now_ms();
                    secondTook = secondMs;
                    spaceAtCapture = [self currentSpace];
                    if (second) secondImage = (__bridge id)second;
                    if (overlap) {
                        if (second) {
                            [CATransaction begin];
                            [CATransaction setDisableActions:YES];
                            self->_incoming.contents = (__bridge id)second;
                            [CATransaction commit];
                        }
                        return;
                    }
                    motion = now_ms();
                    if (!second) { finished(); return; }
                    [self slide:second dx:dx dy:dy done:finished];
                }];
            });
        });
    }];
}

- (void)bounce:(int)dx dy:(int)dy {
    _busy = YES;
    double t0 = now_ms();
    NSWindow *focus = _grid[_workspace][_page].firstObject;
    [self capture:^(CGImageRef image, double ms) {
        if (!image) { [self finish]; return; }
        [self cover:image];
        double motion = now_ms();
        CGSize size = self->_overlay.contentView.bounds.size;
        CGPoint rest = [self rest];
        CGPoint offset = CGPointMake(rest.x - dx * size.width * 0.05, rest.y + dy * size.height * 0.05);
        CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        animation.values = @[point_value(rest), point_value(offset), point_value(rest)];
        animation.keyTimes = @[@0, @0.35, @1];
        animation.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                                      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        animation.duration = self->_bounceMs / 1000;
        [CATransaction begin];
        [CATransaction setCompletionBlock:^{
            [self->_overlay orderOut:nil];
            [focus makeKeyAndOrderFront:nil];
            say("bounce %s capture=%.1f key_to_motion=%.1f total=%.1f",
                dx > 0 ? "right" : dx < 0 ? "left" : dy > 0 ? "down" : "up", ms, motion - t0, now_ms() - t0);
            [self finish];
        }];
        [self->_outgoing addAnimation:animation forKey:@"bounce"];
        [CATransaction commit];
    }];
}

- (void)finish {
    _busy = NO;
    if (_pending) {
        _pending = NO;
        [self navigate:_pendingDx dy:_pendingDy];
    }
}

- (void)demo {
    NSArray *steps = @[@"R", @"R", @"R", @"L", @"L", @"L", @"D", @"D", @"R", @"R", @"U", @"U"];
    say("demo: %lu steps, then quits", (unsigned long)steps.count);
    for (NSUInteger i = 0; i < steps.count; i++) {
        NSString *step = steps[i];
        dispatch_after(after_ms(1200 + i * 1300.0), dispatch_get_main_queue(), ^{
            int dx = [step isEqual:@"R"] ? 1 : [step isEqual:@"L"] ? -1 : 0;
            int dy = [step isEqual:@"D"] ? 1 : [step isEqual:@"U"] ? -1 : 0;
            [self navigate:dx dy:dy];
        });
    }
    dispatch_after(after_ms(1200 + steps.count * 1300.0 + 500), dispatch_get_main_queue(), ^{ [self quitWhenIdle]; });
}

- (void)quitWhenIdle {
    if (_busy || _pending) { dispatch_after(after_ms(100), dispatch_get_main_queue(), ^{ [self quitWhenIdle]; }); return; }
    say("on_screen=%s", [self onScreenPages].UTF8String);
    [self quit:0];
}

// Pages with windows on the current desktop, to check that each move took effect.
- (NSString *)onScreenPages {
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSMutableSet *shown = [NSMutableSet set];
    for (NSDictionary *window in info) [shown addObject:window[(__bridge NSString *)kCGWindowNumber]];
    NSMutableArray *pages = [NSMutableArray array];
    for (NSUInteger w = 0; w < _grid.count; w++) {
        for (NSUInteger p = 0; p < _grid[w].count; p++) {
            NSUInteger count = 0;
            for (NSNumber *number in ids_of(_grid[w][p])) if ([shown containsObject:number]) count++;
            if (count) [pages addObject:[NSString stringWithFormat:@"W%luP%lu:%lu/%lu", w + 1, p + 1, count, (unsigned long)_grid[w][p].count]];
        }
    }
    return pages.count ? [pages componentsJoinedByString:@","] : @"none";
}

// Capture latency at full and half scale, then how soon a capture shows the
// new page after the move (no overlay, no animation).
- (void)measure {
    [self latency:15 scale:1 samples:[NSMutableArray array] done:^{
        [self latency:15 scale:0.5 samples:[NSMutableArray array] done:^{
            [self configure:self->_scale];
            [self settleRound:0 rounds:8];
        }];
    }];
}

- (void)latency:(int)remaining scale:(double)scale samples:(NSMutableArray<NSNumber *> *)samples done:(void (^)(void))done {
    if (!samples.count) [self configure:scale];
    if (!remaining) {
        NSArray *sorted = [samples sortedArrayUsingSelector:@selector(compare:)];
        say("capture latency scale=%.2f size=%zux%zu min=%.1f median=%.1f max=%.1f ms (n=%lu)", scale, _config.width, _config.height,
            [sorted.firstObject doubleValue], [sorted[sorted.count / 2] doubleValue], [sorted.lastObject doubleValue], (unsigned long)sorted.count);
        done();
        return;
    }
    [self capture:^(CGImageRef image, double ms) {
        [samples addObject:@(ms)];
        [self latency:remaining - 1 scale:scale samples:samples done:done];
    }];
}

- (void)settleRound:(int)round rounds:(int)rounds {
    if (round == rounds) { say("measure done"); [self quit:0]; return; }
    int from = round % 2, to = 1 - from;
    [self capture:^(CGImageRef before, double ms) {
        NSData *baseline = before ? thumbnail(before) : nil;
        move_windows(ids_of(self->_grid[0][to]), self->_visible);
        move_windows(ids_of(self->_grid[0][from]), self->_stash);
        self->_page = to;
        [self settleStep:now_ms() baseline:baseline samples:[NSMutableArray array] round:round rounds:rounds];
    }];
}

// Each round logs how far the pre-move screen is from the final one, so a
// zero difference after the move cannot come from a move that never showed.
- (void)settleStep:(double)moved baseline:(NSData *)baseline samples:(NSMutableArray *)samples round:(int)round rounds:(int)rounds {
    double started = now_ms() - moved;
    [self capture:^(CGImageRef image, double ms) {
        if (image) [samples addObject:@[@(started), thumbnail(image)]];
        if (now_ms() - moved < 300) { [self settleStep:moved baseline:baseline samples:samples round:round rounds:rounds]; return; }
        NSData *final = [samples.lastObject lastObject];
        double settled = -1;
        NSMutableString *trace = [NSMutableString string];
        for (NSArray *sample in samples) {
            double d = difference(sample[1], final);
            [trace appendFormat:@" %.0f:%.1f", [sample[0] doubleValue], d];
            if (settled < 0 && d < 2) settled = [sample[0] doubleValue];
        }
        double before = baseline ? difference(baseline, final) : -1;
        say("settle round %d: before_vs_final=%.1f; first matching capture started %.1f ms after the move; start:diff%s",
            round + 1, before, settled, trace.UTF8String);
        dispatch_after(after_ms(400), dispatch_get_main_queue(), ^{ [self settleRound:round + 1 rounds:rounds]; });
    }];
}

- (void)quit:(int)code {
    say("exit %d", code);
    exit(code);
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        Spike *spike = [Spike new];
        app.delegate = spike;
        [app run];
    }
    return 0;
}
