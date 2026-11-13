// Touchpad swipes: a one-finger swipe on a DualSense's (or DualShock 4's) touchpad presses F16 (up), F17
// (down), F18 (left), or F19 (right), for addon key bindings, as a Mac helper beside the game can do. The
// game's own touchpad cursor (GamePadTouchCursorEnable) keeps working: this only reads the touchpad.
// #included at the end of the generated libspAppKit.m (gen_stubs.py EXTRA_INCLUDES), after spevent.m,
// whose event queue it posts to and whose pump calls sp_touchpad_poll.
//
// Controllers are polled from the client's event pump, never given handlers: the client sets its own
// GameController handlers, a GCControllerElement has one slot for each, and setting ours would silently
// take the client's away. Polling reads the same state without touching them.
//
// The touchpad's primary finger is a dpad, -1..1 on each axis, and reads 0,0 with no finger on it. A
// contact runs from the first sample off 0,0 to the first back on it. It's a swipe when the larger axis
// travelled at least 0.8 (two-fifths of the pad) and the finger lifted within 0.6 s, with no touchpad
// click and no second finger at any point: a tap or a click never moves that far, and a slow drag (the
// touchpad cursor) takes longer. +y is up, as for GameController's dpads. A jump of most of the pad
// between two samples is a new finger, not a swipe (in case a lift ever goes unseen between samples).
// 0.8, not 1.0 (half the pad): on the PR author's first device test, swipes of 0.95 read as nothing.

enum { SP_F16 = 0x6A, SP_F17 = 0x40, SP_F18 = 0x4F, SP_F19 = 0x50 };
static const float sp_swipe_travel = 0.8f, sp_swipe_jump = 0.9f;
static const NSTimeInterval sp_swipe_time = 0.6;

// Its own lines, "[sp:AppKit] touchpad: …", like sploading.m's: these aren't the client's calls into stubs.
static void sp_touchpad_say(NSString *s) {
    os_log(OS_LOG_DEFAULT, "[sp:AppKit] touchpad: %{public}s", s.UTF8String);
    fprintf(stderr, "[sp:AppKit] touchpad: %s\n", s.UTF8String);
}

// A function key's down now and its up 50 ms later. Together they'd reach the client in one pump, and a
// game that reads key state once a frame could see neither; a real key is never that short.
static void sp_touchpad_key(unsigned short mac) {
    unichar fc = sp_function_char(mac);
    NSString *chars = [NSString stringWithCharacters:&fc length:1];
    SPEvent *down = sp_event(SPKeyDown);
    down->keyCode = mac;
    down->characters = down->charactersIgnoringModifiers = chars;
    down->modifierFlags |= SPFunction;
    sp_post(down);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SPEvent *up = sp_event(SPKeyUp);
        up->keyCode = mac;
        up->characters = up->charactersIgnoringModifiers = chars;
        up->modifierFlags |= SPFunction;
        sp_post(up);
    });
}

@interface SPTouchpad : NSObject {
@public
    BOOL touching, spoiled;
    float x0, y0, x, y;
    NSTimeInterval t0;
}
@end
@implementation SPTouchpad
@end

static void sp_swipe_sample(SPTouchpad *p, GCControllerDirectionPad *primary, GCControllerDirectionPad *secondary,
                            GCControllerButtonInput *click, NSTimeInterval now) {
    float x = primary.xAxis.value, y = primary.yAxis.value;
    BOOL contact = x != 0 || y != 0;
    BOOL spoil = click.isPressed || secondary.xAxis.value != 0 || secondary.yAxis.value != 0;
    if (p->touching && contact && (fabsf(x - p->x) > sp_swipe_jump || fabsf(y - p->y) > sp_swipe_jump))
        p->touching = NO;
    if (!p->touching) {
        if (!contact) return;
        p->touching = YES;
        p->spoiled = spoil;
        p->x0 = p->x = x;
        p->y0 = p->y = y;
        p->t0 = now;
        return;
    }
    if (contact) {
        p->x = x;
        p->y = y;
        p->spoiled |= spoil;
        return;
    }
    p->touching = NO;
    float dx = p->x - p->x0, dy = p->y - p->y0, ax = fabsf(dx), ay = fabsf(dy);
    NSTimeInterval held = now - p->t0;
    unsigned short key = 0;
    if (!p->spoiled && held <= sp_swipe_time && MAX(ax, ay) >= sp_swipe_travel)
        key = ay > ax ? (dy > 0 ? SP_F16 : SP_F17) : (dx < 0 ? SP_F18 : SP_F19);
    static int logged;
    if (key || logged < 30) {
        logged++;
        sp_touchpad_say([NSString stringWithFormat:@"contact %.2f s, travel %+.2f,%+.2f%s -> %s", held, dx, dy,
                         p->spoiled ? " (click or 2 fingers)" : "",
                         key == SP_F16 ? "F16" : key == SP_F17 ? "F17" : key == SP_F18 ? "F18" : key == SP_F19 ? "F19" : "none"]);
    }
    if (key) sp_touchpad_key(key);
}

// The PlayStation controllers connected: each one's touchpad state. Weak keys, so a controller that
// goes away takes its entry with it.
static NSMapTable<GCController *, SPTouchpad *> *sp_touchpads;

static void sp_touchpad_connect(GCController *c) {
    GCExtendedGamepad *gp = c.extendedGamepad;
    if (![gp isKindOfClass:GCDualSenseGamepad.class] && ![gp isKindOfClass:GCDualShockGamepad.class]) return;
    if ([sp_touchpads objectForKey:c]) return;
    [sp_touchpads setObject:[[SPTouchpad alloc] init] forKey:c];
    sp_touchpad_say([NSString stringWithFormat:@"swipes on for %@ (%s)", c.vendorName, object_getClassName(gp)]);
}

static void sp_touchpad_setup(void) {
    sp_touchpads = [NSMapTable weakToStrongObjectsMapTable];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { sp_touchpad_connect(n.object); }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { [sp_touchpads removeObjectForKey:n.object]; }];
    for (GCController *c in GCController.controllers) sp_touchpad_connect(c);
}

// From -nextEventMatchingMask:… (spevent.m), which the client calls many times a frame: sampled at most
// every 8 ms.
static void sp_touchpad_poll(void) {
    static uint64_t last;
    uint64_t now_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now_ns - last < 8000000) return;
    last = now_ns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sp_touchpad_setup(); });
    NSTimeInterval now = now_ns / 1e9;
    for (GCController *c in sp_touchpads) {
        SPTouchpad *p = [sp_touchpads objectForKey:c];
        GCExtendedGamepad *gp = c.extendedGamepad;
        if ([gp isKindOfClass:GCDualSenseGamepad.class]) {
            GCDualSenseGamepad *ds = (GCDualSenseGamepad *)gp;
            sp_swipe_sample(p, ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton, now);
        } else {
            GCDualShockGamepad *ds = (GCDualShockGamepad *)gp;
            sp_swipe_sample(p, ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton, now);
        }
    }
}
