// Input: UIKit key, pointer and touch events become NSEvents, queued for the client's
// nextEventMatchingMask:, and sendEvent: delivers them the way AppKit does (window, then first
// responder or content view, plus tracking area owners). #included at the end of the generated
// libspAppKit.m after spuikit.m and spwindow.m.
//
// Coordinates: the client's window is the game rect (spwindow.m's sp_game_rect: the UIKit window, less
// an iPhone's Dynamic Island side) at the screen origin, so screen, window and view coordinates are all
// the same AppKit points, origin the game rect's bottom left; UIKit's y is flipped, and its x is the
// game rect's offset more.

#import <GameController/GameController.h>
#include <objc/message.h>

__asm__(".linker_option \"-framework\", \"GameController\"");
__asm__(".linker_option \"-framework\", \"CoreGraphics\"");  // the cursor image

// ---- NSEvent

enum {
    SPLeftMouseDown = 1, SPLeftMouseUp, SPRightMouseDown, SPRightMouseUp, SPMouseMoved,
    SPLeftMouseDragged, SPRightMouseDragged, SPMouseEntered, SPMouseExited, SPKeyDown, SPKeyUp,
    SPFlagsChanged, SPScrollWheel = 22, SPOtherMouseDown = 25, SPOtherMouseUp, SPOtherMouseDragged,
};

// Device-independent modifier flags are the same bits in UIKit and AppKit; the device-dependent
// (left/right) bits are IOKit's NX_DEVICE*KEYMASK.
enum {
    SPCapsLock = 1 << 16, SPShift = 1 << 17, SPControl = 1 << 18, SPOption = 1 << 19,
    SPCommand = 1 << 20, SPNumericPad = 1 << 21, SPFunction = 1 << 23,
    SPDevLCtl = 0x1, SPDevLShift = 0x2, SPDevRShift = 0x4, SPDevLCmd = 0x8, SPDevRCmd = 0x10,
    SPDevLAlt = 0x20, SPDevRAlt = 0x40, SPDevRCtl = 0x2000,
};

@interface SPEvent : NSEvent {
@public
    NSUInteger type, modifierFlags;
    NSTimeInterval timestamp;
    CGPoint location;  // in the window
    unsigned short keyCode;
    NSString *characters, *charactersIgnoringModifiers;
    BOOL isARepeat;
    NSInteger buttonNumber, clickCount;
    CGFloat deltaX, deltaY, scrollingDeltaX, scrollingDeltaY;
    BOOL precise;
    NSUInteger phase;
    id trackingArea;
}
@end

@implementation SPEvent
- (NSUInteger)type { return type; }
- (NSUInteger)modifierFlags { return modifierFlags; }
- (NSTimeInterval)timestamp { return timestamp; }
- (id)window { return sp_client_window; }
- (NSInteger)windowNumber { return 1; }
- (CGPoint)locationInWindow { return location; }
- (unsigned short)keyCode { return keyCode; }
- (NSString *)characters { return characters; }
- (NSString *)charactersIgnoringModifiers { return charactersIgnoringModifiers; }
- (BOOL)isARepeat { return isARepeat; }
- (NSInteger)buttonNumber { return buttonNumber; }
- (NSInteger)clickCount { return clickCount; }
- (float)pressure { return clickCount ? 1 : 0; }
- (CGFloat)deltaX { return deltaX; }
- (CGFloat)deltaY { return deltaY; }
- (CGFloat)deltaZ { return 0; }
- (CGFloat)scrollingDeltaX { return scrollingDeltaX; }
- (CGFloat)scrollingDeltaY { return scrollingDeltaY; }
- (BOOL)hasPreciseScrollingDeltas { return precise; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (NSUInteger)phase { return phase; }
- (NSUInteger)momentumPhase { return 0; }
- (short)subtype { return 0; }
- (NSInteger)eventNumber { return 0; }
- (id)trackingArea { return trackingArea; }
- (void *)userData { return NULL; }
- (void *)CGEvent { return NULL; }
- (NSString *)description {
    return [NSString stringWithFormat:@"<SPEvent type %lu at %.1f,%.1f flags 0x%lx key %u '%@' button %ld>",
            (unsigned long)type, location.x, location.y, (unsigned long)modifierFlags, keyCode, characters,
            (long)buttonNumber];
}
@end

// ---- input state and queue

static NSMutableArray<SPEvent *> *sp_events;
static CGPoint sp_mouse;               // AppKit window coordinates
static NSUInteger sp_mod_flags;        // device-independent and device-dependent bits
static NSUInteger sp_mouse_buttons;    // bit per button number, like +pressedMouseButtons
static SPEvent *sp_current_event;
static NSMutableArray *sp_local_monitors;  // [mask, handler] pairs
static int sp_logged_events;

// UIKit points in the scene window <-> AppKit points in the client's window. A point in the strip beside
// the game converts to one outside the window (x < 0 or past its width), as on a Mac.
static CGPoint sp_from_uikit(CGPoint p) {
    CGRect g = sp_game_rect();
    return CGPointMake(p.x - g.origin.x, g.origin.y + g.size.height - p.y);
}

static CGPoint sp_to_uikit(CGPoint p) {
    CGRect g = sp_game_rect();
    return CGPointMake(g.origin.x + p.x, g.origin.y + g.size.height - p.y);
}

static SPEvent *sp_event(NSUInteger type) {
    SPEvent *e = [[SPEvent alloc] init];
    e->type = type;
    e->modifierFlags = sp_mod_flags;
    e->timestamp = NSProcessInfo.processInfo.systemUptime;
    e->location = sp_mouse;
    return e;
}

static void sp_post(SPEvent *e) {
    if (!sp_events) sp_events = [NSMutableArray array];
    [sp_events addObject:e];
    // Only the first events are logged, so a session's log stays small; a diagnosis that happens later
    // in a session (a key that stops working after login) needs more: SP_INPUT_LOG_MAX raises the cap,
    // 0 for none. The lines carry typed characters, chat included, so keep it to diagnosis runs.
    static int max = -1;
    if (max < 0) max = getenv("SP_INPUT_LOG_MAX") ? atoi(getenv("SP_INPUT_LOG_MAX")) : 60;
    if (max < 0) max = 60;
    if ((max == 0 || sp_logged_events < max) && e->type != SPMouseMoved && e->type != SPLeftMouseDragged &&
        e->type != SPRightMouseDragged && e->type != SPScrollWheel) {
        sp_logged_events++;
        sp_stub_log([NSString stringWithFormat:@"input: %@", e].UTF8String);
    }
}

// ---- keyboard: HID usage (UIKeyboardHIDUsage) to Mac virtual key code (kVK_*)

static const uint8_t sp_hid_to_mac[256] = {
    [0x04] = 0x00, [0x05] = 0x0B, [0x06] = 0x08, [0x07] = 0x02, [0x08] = 0x0E, [0x09] = 0x03,  // a b c d e f
    [0x0A] = 0x05, [0x0B] = 0x04, [0x0C] = 0x22, [0x0D] = 0x26, [0x0E] = 0x28, [0x0F] = 0x25,  // g h i j k l
    [0x10] = 0x2E, [0x11] = 0x2D, [0x12] = 0x1F, [0x13] = 0x23, [0x14] = 0x0C, [0x15] = 0x0F,  // m n o p q r
    [0x16] = 0x01, [0x17] = 0x11, [0x18] = 0x20, [0x19] = 0x09, [0x1A] = 0x0D, [0x1B] = 0x07,  // s t u v w x
    [0x1C] = 0x10, [0x1D] = 0x06,                                                              // y z
    [0x1E] = 0x12, [0x1F] = 0x13, [0x20] = 0x14, [0x21] = 0x15, [0x22] = 0x17, [0x23] = 0x16,  // 1-6
    [0x24] = 0x1A, [0x25] = 0x1C, [0x26] = 0x19, [0x27] = 0x1D,                                // 7 8 9 0
    [0x28] = 0x24, [0x29] = 0x35, [0x2A] = 0x33, [0x2B] = 0x30, [0x2C] = 0x31,  // return esc bksp tab space
    [0x2D] = 0x1B, [0x2E] = 0x18, [0x2F] = 0x21, [0x30] = 0x1E, [0x31] = 0x2A,  // - = [ ] backslash
    [0x32] = 0x2A, [0x33] = 0x29, [0x34] = 0x27, [0x35] = 0x32, [0x36] = 0x2B,  // non-US # ; ' ` ,
    [0x37] = 0x2F, [0x38] = 0x2C, [0x39] = 0x39,                                // . / capslock
    [0x3A] = 0x7A, [0x3B] = 0x78, [0x3C] = 0x63, [0x3D] = 0x76, [0x3E] = 0x60, [0x3F] = 0x61,  // F1-F6
    [0x40] = 0x62, [0x41] = 0x64, [0x42] = 0x65, [0x43] = 0x6D, [0x44] = 0x67, [0x45] = 0x6F,  // F7-F12
    [0x46] = 0x69, [0x47] = 0x6B, [0x48] = 0x71,  // print screen, scroll lock, pause (F13-F15 on a Mac)
    [0x49] = 0x72, [0x4A] = 0x73, [0x4B] = 0x74, [0x4C] = 0x75, [0x4D] = 0x77, [0x4E] = 0x79,  // ins home pgup del end pgdn
    [0x4F] = 0x7C, [0x50] = 0x7B, [0x51] = 0x7D, [0x52] = 0x7E,                                // right left down up
    [0x53] = 0x47, [0x54] = 0x4B, [0x55] = 0x43, [0x56] = 0x4E, [0x57] = 0x45, [0x58] = 0x4C,  // clear / * - + enter
    [0x59] = 0x53, [0x5A] = 0x54, [0x5B] = 0x55, [0x5C] = 0x56, [0x5D] = 0x57, [0x5E] = 0x58,  // keypad 1-6
    [0x5F] = 0x59, [0x60] = 0x5B, [0x61] = 0x5C, [0x62] = 0x52, [0x63] = 0x41,                 // keypad 7 8 9 0 .
    [0x64] = 0x0A, [0x67] = 0x51,                                                              // ISO §, keypad =
    [0x68] = 0x69, [0x69] = 0x6B, [0x6A] = 0x71, [0x6B] = 0x6A, [0x6C] = 0x40, [0x6D] = 0x4F,  // F13-F18
    [0x6E] = 0x50, [0x6F] = 0x5A,                                                              // F19 F20
    [0x75] = 0x72, [0x7F] = 0x4A, [0x80] = 0x48, [0x81] = 0x49,  // help, mute, volume up, volume down
    [0x85] = 0x5F, [0x87] = 0x5E, [0x89] = 0x5D, [0x90] = 0x68, [0x91] = 0x66,  // JIS , _ ¥ kana eisu
    [0xE0] = 0x3B, [0xE1] = 0x38, [0xE2] = 0x3A, [0xE3] = 0x37,  // left ctrl shift option command
    [0xE4] = 0x3E, [0xE5] = 0x3C, [0xE6] = 0x3D, [0xE7] = 0x36,  // right ctrl shift option command
};

// AppKit's characters for keys that don't type text (NSUpArrowFunctionKey etc.), by Mac key code.
static unichar sp_function_char(unsigned short mac) {
    switch (mac) {
    case 0x24: return '\r';
    case 0x4C: return 0x03;  // keypad enter
    case 0x30: return '\t';
    case 0x33: return 0x7F;
    case 0x35: return 0x1B;
    case 0x75: return 0xF728;  // forward delete
    case 0x7E: return 0xF700;
    case 0x7D: return 0xF701;
    case 0x7B: return 0xF702;
    case 0x7C: return 0xF703;
    case 0x7A: return 0xF704;  // F1
    case 0x78: return 0xF705;
    case 0x63: return 0xF706;
    case 0x76: return 0xF707;
    case 0x60: return 0xF708;
    case 0x61: return 0xF709;
    case 0x62: return 0xF70A;
    case 0x64: return 0xF70B;
    case 0x65: return 0xF70C;
    case 0x6D: return 0xF70D;
    case 0x67: return 0xF70E;
    case 0x6F: return 0xF70F;  // F12
    case 0x69: return 0xF710;  // F13
    case 0x6B: return 0xF711;
    case 0x71: return 0xF712;
    case 0x6A: return 0xF713;
    case 0x40: return 0xF714;
    case 0x4F: return 0xF715;
    case 0x50: return 0xF716;
    case 0x5A: return 0xF717;  // F20
    case 0x72: return 0xF746;  // help
    case 0x73: return 0xF729;  // home
    case 0x77: return 0xF72B;  // end
    case 0x74: return 0xF72C;  // page up
    case 0x79: return 0xF72D;  // page down
    case 0x47: return 0xF739;  // clear
    }
    return 0;
}

static BOOL sp_is_keypad(unsigned short mac) {
    return (mac >= 0x52 && mac <= 0x5C && mac != 0x5A) || mac == 0x41 || mac == 0x43 || mac == 0x45 ||
           mac == 0x47 || mac == 0x4B || mac == 0x4C || mac == 0x4E || mac == 0x51;
}

// Modifier keys: Mac key code -> device-independent flag, device-dependent bit.
static BOOL sp_modifier_bits(unsigned short mac, NSUInteger *flag, NSUInteger *dev) {
    switch (mac) {
    case 0x38: *flag = SPShift; *dev = SPDevLShift; return YES;
    case 0x3C: *flag = SPShift; *dev = SPDevRShift; return YES;
    case 0x3B: *flag = SPControl; *dev = SPDevLCtl; return YES;
    case 0x3E: *flag = SPControl; *dev = SPDevRCtl; return YES;
    case 0x3A: *flag = SPOption; *dev = SPDevLAlt; return YES;
    case 0x3D: *flag = SPOption; *dev = SPDevRAlt; return YES;
    case 0x37: *flag = SPCommand; *dev = SPDevLCmd; return YES;
    case 0x36: *flag = SPCommand; *dev = SPDevRCmd; return YES;
    case 0x39: *flag = SPCapsLock; *dev = 0; return YES;
    }
    return NO;
}

// Recompute a device-independent flag from the device bits still held.
static void sp_set_modifier(NSUInteger flag, NSUInteger dev, BOOL down) {
    if (down) sp_mod_flags |= dev; else sp_mod_flags &= ~dev;
    NSUInteger all = flag == SPShift ? SPDevLShift | SPDevRShift
                   : flag == SPControl ? SPDevLCtl | SPDevRCtl
                   : flag == SPOption ? SPDevLAlt | SPDevRAlt
                   : SPDevLCmd | SPDevRCmd;
    if (sp_mod_flags & all) sp_mod_flags |= flag; else sp_mod_flags &= ~flag;
}

// Key repeat, as macOS does it (UIKit sends one press per key, no repeats).
static SPEvent *sp_repeat_key;
static NSTimeInterval sp_repeat_at;
static const NSTimeInterval sp_repeat_delay = 0.42, sp_repeat_interval = 0.083;

static void sp_key(UIKey *key, BOOL down) {
    unsigned usage = (unsigned)key.keyCode;
    unsigned short mac = usage < 256 ? sp_hid_to_mac[usage] : 0;
    if (!mac && usage != 0x04) {  // 0x04 (a) is the one key whose code is 0
        sp_stub_log([NSString stringWithFormat:@"input: unmapped HID usage 0x%x '%@'", usage, key.characters].UTF8String);
        return;
    }
    NSUInteger flag, dev;
    if (sp_modifier_bits(mac, &flag, &dev)) {
        if (flag == SPCapsLock) {
            // Caps lock is a toggle on the Mac: one flagsChanged per press, the flag follows the light.
            if (!down) return;
            sp_mod_flags ^= SPCapsLock;
        } else {
            sp_set_modifier(flag, dev, down);
        }
        SPEvent *e = sp_event(SPFlagsChanged);
        e->keyCode = mac;
        sp_post(e);
        return;
    }
    SPEvent *e = sp_event(down ? SPKeyDown : SPKeyUp);
    e->keyCode = mac;
    unichar fc = sp_function_char(mac);
    if (fc) {
        e->characters = e->charactersIgnoringModifiers = [NSString stringWithCharacters:&fc length:1];
        if (fc >= 0xF700) e->modifierFlags |= SPFunction;
    } else {
        e->characters = key.characters ?: @"";
        e->charactersIgnoringModifiers = key.charactersIgnoringModifiers ?: e->characters;
    }
    if (sp_is_keypad(mac) || (mac >= 0x7B && mac <= 0x7E)) e->modifierFlags |= SPNumericPad;
    sp_post(e);
    if (down) {
        sp_repeat_key = e;
        sp_repeat_at = e->timestamp + sp_repeat_delay;
    } else if (sp_repeat_key && sp_repeat_key->keyCode == mac) {
        sp_repeat_key = nil;
    }
}

static void sp_key_repeats(void) {
    if (!sp_repeat_key) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < sp_repeat_at) return;
    SPEvent *e = sp_event(SPKeyDown);
    e->keyCode = sp_repeat_key->keyCode;
    e->characters = sp_repeat_key->characters;
    e->charactersIgnoringModifiers = sp_repeat_key->charactersIgnoringModifiers;
    e->modifierFlags |= sp_repeat_key->modifierFlags & (SPFunction | SPNumericPad);
    e->isARepeat = YES;
    sp_post(e);
    sp_repeat_at = now + sp_repeat_interval;
}

// ---- pointer

static NSTimeInterval sp_last_click_time;
static NSInteger sp_last_click_button, sp_click_count;
static CGPoint sp_last_click_at;

// ---- mouselook
//
// To turn, the client hides the cursor, calls CGAssociateMouseAndMouseCursorPosition(false) and reads
// deltaX/deltaY from the drag events. On a Mac the cursor then stays put and the deltas keep coming.
// Here the visionOS pointer stops at the window's edge, so while the cursor is frozen the deltas come
// from GCMouse's raw movement and sp_mouse stays where it was. With no raw movement seen (no GCMouse)
// the pointer's own movement still turns, up to the edge, and so does a pinch's or a finger's: no
// GCMouse reports those, however many mice have moved (an iPhone's AssistiveTouch click, though a
// finger-type touch, isn't a finger: sp_raw:).

static BOOL sp_mouse_frozen;
static BOOL sp_raw_moves;           // GCMouse has reported movement
static CGPoint sp_pointer;          // where UIKit last put the pointer; sp_mouse stays put while frozen
static void sp_cursor_update(void);
static void sp_cursor_from_rects(void);
static void sp_pointer_lock_update(void);

static NSUInteger sp_motion_type(void) {
    return sp_mouse_buttons & 1 ? SPLeftMouseDragged : sp_mouse_buttons & 2 ? SPRightMouseDragged
         : sp_mouse_buttons ? SPOtherMouseDragged : SPMouseMoved;
}

// dy grows downward, as AppKit's deltaY.
static void sp_post_motion(NSUInteger type, CGFloat dx, CGFloat dy) {
    SPEvent *e = sp_event(type);
    e->deltaX = dx;
    e->deltaY = dy;
    if (type == SPRightMouseDragged) e->buttonNumber = 1;
    if (type == SPOtherMouseDragged) e->buttonNumber = 2;
    sp_post(e);
}

// Raw and pointer movement side by side, while not frozen, to check the raw deltas' sign and scale.
static CGFloat sp_cmp_raw_x, sp_cmp_raw_y, sp_cmp_ptr_x, sp_cmp_ptr_y;

// raw: GCMouse's raw movement reports this movement too, once it has reported any.
static void sp_mouse_moved_to(CGPoint p, NSUInteger type, BOOL raw) {
    CGFloat dx = p.x - sp_pointer.x, dy = sp_pointer.y - p.y;
    sp_pointer = p;
    if (sp_mouse_frozen) {
        if (!raw || !sp_raw_moves) sp_post_motion(type, dx, dy);
        return;
    }
    sp_cmp_ptr_x += dx;
    sp_cmp_ptr_y += dy;
    sp_mouse = p;
    sp_post_motion(type, dx, dy);
    sp_cursor_from_rects();
    sp_cursor_update();
}

static void sp_raw_moved(float dx, float dy) {
    static float scale;
    if (!scale) scale = getenv("SP_MOUSELOOK_SCALE") ? atof(getenv("SP_MOUSELOOK_SCALE")) : 1;
    sp_raw_moves = YES;
    // GameController's y is up.
    if (sp_mouse_frozen) {
        sp_post_motion(sp_motion_type(), dx * scale, -dy * scale);
        return;
    }
    sp_cmp_raw_x += dx;
    sp_cmp_raw_y -= dy;
    static int logged;
    if (fabs(sp_cmp_raw_x) + fabs(sp_cmp_raw_y) > 300 && logged < 10) {
        logged++;
        sp_stub_log([NSString stringWithFormat:@"input: raw mouse %.0f,%.0f vs pointer %.0f,%.0f (y down)",
                     sp_cmp_raw_x, sp_cmp_raw_y, sp_cmp_ptr_x, sp_cmp_ptr_y].UTF8String);
        sp_cmp_raw_x = sp_cmp_raw_y = sp_cmp_ptr_x = sp_cmp_ptr_y = 0;
    }
}

static void sp_set_mouse_frozen(BOOL frozen) {
    if (frozen == sp_mouse_frozen) return;
    static int logged;
    if (logged++ < 20)
        sp_stub_log([NSString stringWithFormat:@"input: cursor %s at %.0f,%.0f (raw moves %s)", frozen ? "frozen" : "freed",
                     sp_mouse.x, sp_mouse.y, sp_raw_moves ? "seen" : "not seen"].UTF8String);
    sp_mouse_frozen = frozen;
    sp_pointer_lock_update();
}

// Ignores a down for a button already down and an up for one already up: buttons can be reported
// by both the touch's button mask and GCMouse.
static void sp_mouse_button(NSInteger button, BOOL down, CGPoint p) {
    if (!!(sp_mouse_buttons & (1u << button)) == down) return;
    if (p.x != sp_pointer.x || p.y != sp_pointer.y) sp_mouse_moved_to(p, sp_motion_type(), YES);
    p = sp_mouse;  // differs while frozen
    NSUInteger type = button == 0 ? (down ? SPLeftMouseDown : SPLeftMouseUp)
                    : button == 1 ? (down ? SPRightMouseDown : SPRightMouseUp)
                    : (down ? SPOtherMouseDown : SPOtherMouseUp);
    if (down) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        BOOL again = button == sp_last_click_button && now - sp_last_click_time < 0.5 &&
                     fabs(p.x - sp_last_click_at.x) < 4 && fabs(p.y - sp_last_click_at.y) < 4;
        sp_click_count = again ? sp_click_count + 1 : 1;
        sp_last_click_time = now;
        sp_last_click_button = button;
        sp_last_click_at = p;
        sp_mouse_buttons |= 1u << button;
    } else {
        sp_mouse_buttons &= ~(1u << button);
    }
    SPEvent *e = sp_event(type);
    e->buttonNumber = button;
    e->clickCount = sp_click_count;
    sp_post(e);
}

// ---- look highlights
//
// visionOS never tells an app where the user looks, so the client gets no mouseMoved from gaze and
// draws no hover state. Instead, clear views with a hoverStyle sit over the client's interactive
// rects, and the system draws its own gaze highlight on them (out of process). They take no input of
// their own: a UIView passes unhandled touches up the responder chain, so pinches still reach
// SPInputView, and the container itself is never the hit view.

@interface SPHoverLayer : UIView
@end

#define SP_HOVER_MAX 400
static CGRect sp_hover_rects[SP_HOVER_MAX];  // fractions of the window, origin bottom left
static size_t sp_hover_count;

@implementation SPHoverLayer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return v == self ? nil : v;
}

// One view per rect, reused; the rest hidden. Again on every resize.
- (void)layoutSubviews {
    [super layoutSubviews];
    NSArray<UIView *> *views = self.subviews;
    CGSize size = self.bounds.size;
    for (size_t i = 0; i < sp_hover_count; i++) {
        UIView *v;
        if (i < views.count) {
            v = views[i];
        } else {
            v = [[UIView alloc] init];
            v.hoverStyle = [UIHoverStyle styleWithShape:[UIShape rectShapeWithCornerRadius:4]];
            [self addSubview:v];
        }
        CGRect r = sp_hover_rects[i];
        v.frame = CGRectMake(r.origin.x * size.width, (1 - r.origin.y - r.size.height) * size.height,
                             r.size.width * size.width, r.size.height * size.height);
        v.hidden = NO;
    }
    for (size_t i = sp_hover_count; i < views.count; i++) views[i].hidden = YES;
}
@end

static SPHoverLayer *sp_hover_layer;

// spwindow.m's sp_window_track_scene, when it fits or moves the game rect: the highlights' rects are
// fractions of the client's window, so their container covers the game rect, not the scene window;
// the cursor is placed from it too.
static void sp_game_moved(CGRect game) {
    sp_hover_layer.frame = game;
    sp_cursor_update();
}

// rects: fractions of the window, origin bottom left.
static void sp_hover_set_rects(const CGRect *rects, size_t n) {
    if (n > SP_HOVER_MAX) n = SP_HOVER_MAX;
    memcpy(sp_hover_rects, rects, n * sizeof *rects);
    sp_hover_count = n;
    [sp_hover_layer setNeedsLayout];
}

// SP_HOVER_TEST=<cols>x<rows>: a grid of hover cells over the whole window, to see the highlight over
// the client's Metal layer and check that clicks still go through.
static void sp_hover_test_grid(void) {
    const char *s = getenv("SP_HOVER_TEST");
    int cols, rows;
    if (!s || sscanf(s, "%dx%d", &cols, &rows) != 2 || cols <= 0 || rows <= 0 || cols * rows > SP_HOVER_MAX) return;
    CGRect cells[SP_HOVER_MAX];
    for (int y = 0; y < rows; y++)
        for (int x = 0; x < cols; x++)
            cells[y * cols + x] = CGRectMake((x + 0.05) / cols, (y + 0.05) / rows, 0.9 / cols, 0.9 / rows);
    sp_hover_set_rects(cells, cols * rows);
    sp_stub_log([NSString stringWithFormat:@"hover: test grid %dx%d", cols, rows].UTF8String);
}

// ---- the client's cursor
//
// The client makes its own cursor images (arrow, loot bag, gear, sword...) and picks one through cursor
// rects: when its cursor changes it calls -invalidateCursorRectsForView:, AppKit calls the view's
// -resetCursorRects, and that adds a rect with the new cursor (-addCursorRect:cursor:). The cursor of
// the rect under the mouse is the one shown; -[NSCursor set] works too. visionOS doesn't let an app change its pointer, so
// the system pointer is hidden over the window (UIPointerInteraction, hidden style) and the client's
// cursor is drawn as a view at sp_mouse, above everything. It shows only while a mouse or trackpad
// pointer is over the window (gaze has no position), and not while the client has it hidden (+hide).
// While the pointer is over the window the look highlights are off: the client draws its own hover.
// SP_CURSOR_SYSTEM=1 keeps the system pointer.

static UIView *sp_cursor_view;
static id sp_cursor_current;      // the NSCursor last set
static NSData *sp_cursor_pixels;  // its pixels, as last drawn
static CGPoint sp_cursor_hot;     // points from the image's top left
static int sp_cursor_hide_count;  // +hide minus +unhide; an +unhide while shown does nothing
static BOOL sp_pointer_inside;    // a mouse or trackpad pointer is over the window
static NSMutableArray *sp_cursor_rects;  // [view, rect, cursor], in the order added

static void sp_cursor_update(void) {
    sp_hover_layer.hidden = sp_pointer_inside;
    if (!sp_cursor_view) return;
    BOOL show = sp_cursor_current && !sp_cursor_hide_count && sp_pointer_inside;
    sp_cursor_view.hidden = !show;
    if (!show) return;
    CGPoint at = sp_to_uikit(sp_mouse);
    CGPoint origin = CGPointMake(at.x - sp_cursor_hot.x, at.y - sp_cursor_hot.y);
    if (!CGPointEqualToPoint(origin, sp_cursor_view.frame.origin))
        sp_cursor_view.frame = (CGRect){origin, sp_cursor_view.frame.size};
}

static void sp_cursor_set(id cursor) {
    id image = [cursor image];
    id rep = [[image representations] firstObject];
    if (!sp_cursor_view) return;
    if (!rep || [rep bitsPerPixel] != 32) {
        SP_LOG_ONCE("-[NSCursor set]: no 32 bpp image, not drawn");
        return;
    }
    NSInteger w = [rep pixelsWide], h = [rep pixelsHigh], row = [rep bytesPerRow];
    NSData *pixels = [NSData dataWithBytes:[rep bitmapData] length:row * h];
    if (cursor == sp_cursor_current && [pixels isEqualToData:sp_cursor_pixels]) return;
    sp_cursor_current = cursor;
    sp_cursor_pixels = pixels;
    // NSBitmapFormatAlphaFirst = 1, NSBitmapFormatAlphaNonpremultiplied = 2.
    NSUInteger format = [rep bitmapFormat];
    CGImageAlphaInfo alpha = format & 1 ? (format & 2 ? kCGImageAlphaFirst : kCGImageAlphaPremultipliedFirst)
                                        : (format & 2 ? kCGImageAlphaLast : kCGImageAlphaPremultipliedLast);
    CGDataProviderRef data = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef cg = CGImageCreate(w, h, 8, 32, row, space, (CGBitmapInfo)alpha, data, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(data);
    // The client sizes its images by the backing scale: 64x64 px "64x64 pt" at 2x, 32x32 at 1x. 64 pt
    // looks too big next to the window's UI, so they're drawn at the 2x size times SP_CURSOR_SCALE
    // (default 0.5: 32 pt) whatever the backing scale.
    static CGFloat user_scale;
    if (!user_scale) user_scale = getenv("SP_CURSOR_SCALE") ? atof(getenv("SP_CURSOR_SCALE")) : 0.5;
    CGFloat scale = user_scale * 2 / sp_scale;
    CGSize size = [image size];
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(w / sp_scale, h / sp_scale);
    size = CGSizeMake(size.width * scale, size.height * scale);
    static int logged;
    if (logged++ < 3)
        sp_stub_log([NSString stringWithFormat:@"cursor: %ldx%ld px, format 0x%lx, drawn at %gx%g pt", (long)w, (long)h,
                     (unsigned long)format, size.width, size.height].UTF8String);
    sp_cursor_view.layer.contents = (__bridge id)cg;
    CGImageRelease(cg);
    sp_cursor_view.frame = (CGRect){sp_cursor_view.frame.origin, size};
    CGPoint hot = [cursor hotSpot];
    sp_cursor_hot = CGPointMake(hot.x * scale, hot.y * scale);
    sp_cursor_update();
}

static void sp_cursor_hide(BOOL hide) {
    if (hide) sp_cursor_hide_count++;
    else if (sp_cursor_hide_count > 0) sp_cursor_hide_count--;  // the client unhides once at startup
    sp_cursor_update();
}

// While frozen, ask UIKit to lock the pointer to the window (prefersPointerLocked). iPadOS does this
// for a full-screen app; visionOS ignored it in a test, so there it's opt-in (SP_POINTER_LOCK=1).
static BOOL sp_pointer_lock_wanted(void) {
    static int on = -1;
    if (on < 0) on = getenv("SP_POINTER_LOCK") ? atoi(getenv("SP_POINTER_LOCK")) != 0 : !TARGET_OS_VISION;
    return on;
}

static void sp_pointer_lock_update(void) {
    if (sp_pointer_lock_wanted()) [sp_window.rootViewController setNeedsUpdateOfPrefersPointerLocked];
}

@interface SPRootViewController : UIViewController
@end
@implementation SPRootViewController
- (BOOL)prefersPointerLocked {
    return sp_pointer_lock_wanted() && sp_mouse_frozen;
}
#if !TARGET_OS_VISION
// iPad: the game gets the whole screen; the home indicator fades, and a swipe from an edge needs a
// second swipe (the first goes to the game).
- (BOOL)prefersStatusBarHidden {
    return YES;
}
- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}
#endif
@end

// ---- the UIKit side: the scene's root view collects input

@interface SPInputView : UIView <UIPointerInteractionDelegate>
@end

// An iPhone's mouse goes through AssistiveTouch, and there neither UIKit nor GCMouse has every button
// right. A left click is a touch of its own, a finger's type, and those are right; GCMouse learns of
// a left press only when another button changes, and late. The other buttons come as a pointer touch
// whose mask can carry a left that isn't down and which can outlive its button by seconds; GCMouse
// has them right. So on an iPhone the left button comes from touches and the others from GCMouse,
// except for buttons GCMouse has no input for (an MX Master's gesture button), which only the pointer
// touch reports.
static BOOL sp_assistive_mouse(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
}

static UIEventButtonMask sp_gcmouse_mask;  // the buttons some GCMouse has an input for, as UIKit's bits

static void sp_watch_mouse(GCMouse *m) {
    sp_stub_log([NSString stringWithFormat:@"input: GCMouse %@: middle %d, %lu auxiliary", m.vendorName,
                 m.mouseInput.middleButton != nil, (unsigned long)m.mouseInput.auxiliaryButtons.count].UTF8String);
    // Left and right too: UIKit's button mask doesn't drop a button released while another is held.
    m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
        if (!sp_assistive_mouse()) sp_mouse_button(0, pressed, sp_pointer);
    };
    m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
        sp_mouse_button(1, pressed, sp_pointer);
    };
    m.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
        sp_mouse_button(2, pressed, sp_pointer);
    };
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
        sp_raw_moved(dx, dy);
    };
    NSArray *aux = m.mouseInput.auxiliaryButtons;
    sp_gcmouse_mask |= 1 << 0 | 1 << 1 | (m.mouseInput.middleButton ? 1 << 2 : 0) | (((1 << aux.count) - 1) << 3);
    for (NSUInteger i = 0; i < aux.count; i++)
        ((GCControllerButtonInput *)aux[i]).pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
            sp_mouse_button(3 + i, pressed, sp_pointer);
        };
}

@implementation SPInputView {
    NSMutableArray<UITouch *> *_touches;  // the touches down, acting as the mouse
    UIEventButtonMask _pointer_mask;      // the buttons the pointer touch last reported
    UIEventButtonMask _mask;              // the buttons reported down
    CGPoint _scroll_last;
    BOOL _hover_in_game;                  // the hover is over the game, and entered it
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // More than one touch: an iPhone's AssistiveTouch pointer makes a left click a touch of its own,
    // separate from the pointer touch that holds the other buttons.
    self.multipleTouchEnabled = YES;
    _touches = [NSMutableArray array];
    UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)];
    [self addGestureRecognizer:hover];
    // Scroll wheel and two-finger trackpad scrolls, without touches.
    UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
    scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
    scroll.allowedTouchTypes = @[];
    [self addGestureRecognizer:scroll];
    // Buttons from GameController too (sp_mouse_button drops whichever report is second).
    for (GCMouse *m in GCMouse.mice) sp_watch_mouse(m);
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { sp_watch_mouse(n.object); }];
    // Above the client's CAMetalLayer, which is added to this view's layer later.
    sp_hover_layer = [[SPHoverLayer alloc] initWithFrame:self.bounds];
    sp_hover_layer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sp_hover_layer.layer.zPosition = 1000;
    [self addSubview:sp_hover_layer];
    sp_hover_test_grid();
    sp_cursor_view = [[UIView alloc] init];
    sp_cursor_view.userInteractionEnabled = NO;
    sp_cursor_view.hidden = YES;
    sp_cursor_view.layer.zPosition = 2000;
    [self addSubview:sp_cursor_view];
    if (!getenv("SP_CURSOR_SYSTEM")) [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
    [NSNotificationCenter.defaultCenter addObserverForName:UIPointerLockStateDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) {
        UIScene *scene = n.userInfo[UIPointerLockStateSceneUserInfoKey];
        sp_stub_log([NSString stringWithFormat:@"input: pointer lock %s",
                     scene.pointerLockState.locked ? "on" : "off"].UTF8String);
    }];
    return self;
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region {
    static int logged;
    if (logged++ < 3) sp_stub_log("input: system pointer hidden over the window");
    return [UIPointerStyle hiddenPointerStyle];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

#if !TARGET_OS_VISION
// The black strip beside the game (an iPhone's Dynamic Island side) is outside the client's window, as
// the desktop is beside a Mac window, so it isn't part of this view once the client has a window: a
// touch, click or scroll that starts there reaches no one (rather than being clamped to the game's edge,
// where it would press whatever button is there), and the hover gesture ends at its edge (hover: checks
// too). A touch that starts in the game still reports all the way into the strip, as a drag out of a
// Mac window does. The launcher's screens are presented over the root, not in it, so they keep the strip.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (![super pointInside:point withEvent:event]) return NO;
    return !sp_told_rect.size.width || CGRectContainsPoint(sp_game_rect(), point);
}
#endif

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self becomeFirstResponder];
}

- (void)sp_pointer_entered:(CGPoint)p {
    sp_pointer = p;
    if (!sp_mouse_frozen) sp_mouse = p;
    sp_pointer_inside = YES;
    _hover_in_game = YES;
    sp_post(sp_event(SPMouseEntered));
    sp_cursor_update();
}

- (void)sp_pointer_exited {
    sp_pointer_inside = NO;
    _hover_in_game = NO;
    sp_post(sp_event(SPMouseExited));
    sp_cursor_update();
}

// A hover over the strip beside the game (an iPhone's island side) is outside the client's window: the
// pointer leaves the game at its edge (the cursor hides) and enters again on the way back, as a Mac
// pointer leaving a window does. pointInside: may already end the gesture there; this covers it either
// way.
- (void)hover:(UIHoverGestureRecognizer *)g {
    CGPoint u = [g locationInView:self];
    CGPoint p = sp_from_uikit(u);
    BOOL in_game = CGRectContainsPoint(sp_game_rect(), u);
    switch (g.state) {
    case UIGestureRecognizerStateBegan:
        if (in_game) {
            [self sp_pointer_entered:p];
        } else if (sp_pointer_inside) {
            sp_pointer_inside = NO;
            sp_cursor_update();
        }
        break;
    case UIGestureRecognizerStateChanged:
        if (in_game && !_hover_in_game) [self sp_pointer_entered:p];
        else if (!in_game && _hover_in_game) [self sp_pointer_exited];
        else if (in_game) sp_mouse_moved_to(p, SPMouseMoved, YES);
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
        // No move to the end location: the last change already put the mouse there, and an iPhone's
        // AssistiveTouch pointer ends its hover at 0,0 whenever it clicks, which would jump the
        // mouse to the top left corner on every click. Out over the strip, the exit was already sent.
        if (_hover_in_game) {
            [self sp_pointer_exited];
        } else if (sp_pointer_inside) {
            sp_pointer_inside = NO;
            sp_cursor_update();
        }
        break;
    default:
        break;
    }
}

- (void)scroll:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) _scroll_last = CGPointMake(0, 0);
    SPEvent *e = sp_event(SPScrollWheel);
    // Content follows the fingers, as with natural scrolling on a Mac: AppKit's deltas then have the
    // finger's sign, with y up.
    e->scrollingDeltaX = t.x - _scroll_last.x;
    e->scrollingDeltaY = t.y - _scroll_last.y;
    e->deltaX = e->scrollingDeltaX / 10;
    e->deltaY = e->scrollingDeltaY / 10;
    e->precise = YES;
    e->phase = g.state == UIGestureRecognizerStateBegan ? 1 : g.state == UIGestureRecognizerStateChanged ? 4 : 8;
    _scroll_last = t;
    if (e->scrollingDeltaX || e->scrollingDeltaY || e->phase != 4) sp_post(e);
}

// A pointer is one touch for as long as any button is down; its event's button mask says which.
// Each change in the mask becomes downs and ups (UIKit's button n is AppKit's n - 1), so pressing a
// second button while one is held is a chord, as on a Mac. Any other touch (a finger, a pinch, an
// iPhone's AssistiveTouch left click) is the primary button, so the buttons down are the union over
// all the touches.
- (void)sp_buttons:(UIEventButtonMask)mask at:(CGPoint)p {
    static int logged;
    if (mask != _mask && logged++ < 20)
        sp_stub_log([NSString stringWithFormat:@"input: button mask 0x%lx -> 0x%lx", (long)_mask, (long)mask].UTF8String);
    UIEventButtonMask changed = mask ^ _mask;
    _mask = mask;
    for (NSInteger b = 0; b < 8; b++)
        if (changed & (1 << b)) sp_mouse_button(b, !!(mask & (1 << b)), p);
}

// The event's mask belongs to the pointer touch only when that touch is one of the event's. An
// iPhone's pointer touch has a say only in buttons no GCMouse has (sp_assistive_mouse).
- (UIEventButtonMask)sp_mask:(UIEvent *)event touches:(NSSet<UITouch *> *)touches {
    UIEventButtonMask mask = 0;
    for (UITouch *t in _touches) {
        if (t.type != UITouchTypeIndirectPointer) {
            mask |= UIEventButtonMaskPrimary;
            continue;
        }
        if ([touches containsObject:t]) _pointer_mask = event.buttonMask ?: UIEventButtonMaskPrimary;
        mask |= sp_assistive_mouse() ? _pointer_mask & ~sp_gcmouse_mask : _pointer_mask;
    }
    return mask;
}

- (CGPoint)sp_location:(UITouch *)t {
    return sp_from_uikit([t locationInView:self]);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        // A pinch has no pointer to draw a cursor at.
        if (!_touches.count) {
            sp_pointer_inside = t.type == UITouchTypeIndirectPointer;
            sp_cursor_update();
        }
        [_touches addObject:t];
    }
    [self sp_buttons:[self sp_mask:event touches:touches] at:[self sp_location:[self sp_mover:touches]]];
}

// The touch that moves the mouse. On an iPhone, whichever moved: its pointer touch can stay on after
// its button is up. Elsewhere the first one down: a second pinch starts wherever the eyes are and a
// second finger wherever it lands, and moving the mouse there would jump the cursor, or the camera.
- (UITouch *)sp_mover:(NSSet<UITouch *> *)touches {
    return sp_assistive_mouse() ? touches.anyObject : _touches.firstObject;
}

// Only a pointer touch's movement is in GCMouse's raw movement too; on an iPhone, an AssistiveTouch
// left click's finger-type touch also moves with the mouse. That click is synthesized and reports its
// radius with no tolerance; a finger's always has some (iPhone 16 Pro: a click 43.7±0, a finger 12.1±6.1).
- (BOOL)sp_raw:(UITouch *)t {
    return t.type == UITouchTypeIndirectPointer || (sp_assistive_mouse() && t.majorRadiusTolerance == 0);
}

// The first touch ending hands the mouse to the next one where it is, without moving it there.
- (void)sp_remove:(NSSet<UITouch *> *)touches {
    UITouch *first = _touches.firstObject;
    [_touches removeObjectsInArray:touches.allObjects];
    if (!sp_assistive_mouse() && _touches.count && _touches.firstObject != first)
        sp_pointer = [self sp_location:_touches.firstObject];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touches.count || ![touches intersectsSet:[NSSet setWithArray:_touches]]) return;
    UITouch *mover = [self sp_mover:touches];
    CGPoint p = [touches containsObject:mover] ? [self sp_location:mover] : sp_pointer;
    [self sp_buttons:[self sp_mask:event touches:touches] at:p];
    if (p.x != sp_pointer.x || p.y != sp_pointer.y) sp_mouse_moved_to(p, sp_motion_type(), [self sp_raw:mover]);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = _touches.count > touches.count ? sp_pointer : [self sp_location:touches.anyObject];
    [self sp_remove:touches];
    [self sp_buttons:[self sp_mask:event touches:touches] at:p];
}

// When the last touch is cancelled, buttons it had down stay down while GCMouse says they're held (it
// reports their ups): locking the pointer may cancel the touch mid-mouselook.
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [self sp_location:touches.anyObject];
    [self sp_remove:touches];
    if (_touches.count) {
        [self sp_buttons:[self sp_mask:event touches:touches] at:sp_pointer];
        return;
    }
    UIEventButtonMask held = 0;
    if (!sp_assistive_mouse()) {
        for (GCMouse *m in GCMouse.mice) {
            GCMouseInput *in = m.mouseInput;
            if (in.leftButton.pressed) held |= 1 << 0;
            if (in.rightButton.pressed) held |= 1 << 1;
            if (in.middleButton.pressed) held |= 1 << 2;
        }
    }
    static int logged;
    if (logged++ < 10)
        sp_stub_log([NSString stringWithFormat:@"input: touch cancelled, GCMouse holds 0x%lx", (long)held].UTF8String);
    [self sp_buttons:held at:p];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses)
        if (p.key) sp_key(p.key, YES);
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses)
        if (p.key) sp_key(p.key, NO);
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self pressesEnded:presses withEvent:event];
}
@end

static UIViewController *sp_make_root_view_controller(void) {
    UIViewController *vc = [[SPRootViewController alloc] init];
    // The game and the loading screen (sploading.m) are black in either appearance, so UIKit's controls
    // on them are drawn for Dark (the launcher's screens pin it too: apps/client/spstartscreen.swift).
    vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    vc.view = [[SPInputView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    return vc;
}

// ---- NSEvent class methods

@implementation NSEvent (SPEvent)
+ (CGPoint)mouseLocation {
    return sp_mouse;
}
+ (NSUInteger)modifierFlags {
    return sp_mod_flags;
}
+ (NSUInteger)pressedMouseButtons {
    return sp_mouse_buttons;
}
+ (NSTimeInterval)doubleClickInterval {
    return 0.5;
}
+ (NSTimeInterval)keyRepeatDelay {
    return sp_repeat_delay;
}
+ (NSTimeInterval)keyRepeatInterval {
    return sp_repeat_interval;
}
+ (instancetype)keyEventWithType:(NSUInteger)type location:(CGPoint)location modifierFlags:(NSUInteger)flags
                       timestamp:(NSTimeInterval)time windowNumber:(NSInteger)wn context:(id)context
                      characters:(NSString *)chars charactersIgnoringModifiers:(NSString *)unmodChars
                       isARepeat:(BOOL)repeat keyCode:(unsigned short)code {
    SPEvent *e = sp_event(type);
    e->location = location;
    e->modifierFlags = flags;
    e->timestamp = time;
    e->characters = chars;
    e->charactersIgnoringModifiers = unmodChars;
    e->isARepeat = repeat;
    e->keyCode = code;
    return (id)e;
}
+ (instancetype)mouseEventWithType:(NSUInteger)type location:(CGPoint)location modifierFlags:(NSUInteger)flags
                         timestamp:(NSTimeInterval)time windowNumber:(NSInteger)wn context:(id)context
                       eventNumber:(NSInteger)n clickCount:(NSInteger)clicks pressure:(float)pressure {
    SPEvent *e = sp_event(type);
    e->location = location;
    e->modifierFlags = flags;
    e->timestamp = time;
    e->clickCount = clicks;
    e->buttonNumber = type == SPRightMouseDown || type == SPRightMouseUp || type == SPRightMouseDragged ? 1
                    : type >= SPOtherMouseDown ? 2 : 0;
    return (id)e;
}
+ (id)addLocalMonitorForEventsMatchingMask:(uint64_t)mask handler:(NSEvent * (^)(NSEvent *))handler {
    sp_stub_log([NSString stringWithFormat:@"+[NSEvent addLocalMonitorForEventsMatchingMask:0x%llx]", mask].UTF8String);
    if (!sp_local_monitors) sp_local_monitors = [NSMutableArray array];
    NSArray *monitor = @[ @(mask), [handler copy] ];
    [sp_local_monitors addObject:monitor];
    return monitor;
}
+ (void)removeMonitor:(id)monitor {
    [sp_local_monitors removeObjectIdenticalTo:monitor];
}
// For the CoreGraphics shim's cursor calls (spdisplay.m), which can't link against this library.
+ (void)sp_setMouseFrozen:(BOOL)frozen {
    sp_set_mouse_frozen(frozen);
}
// p: AppKit screen coordinates. The visionOS pointer can't be moved, so only the client's cursor moves;
// the next pointer move brings it back to the pointer (unless frozen).
+ (void)sp_warpMouseTo:(CGPoint)p {
    static int logged;
    if (logged++ < 20)
        sp_stub_log([NSString stringWithFormat:@"input: cursor warped to %.0f,%.0f", p.x, p.y].UTF8String);
    sp_mouse = p;
    sp_cursor_update();
}
+ (BOOL)sp_cursorVisible {
    return !sp_cursor_hide_count;
}
@end

// ---- NSTrackingArea: kept so mouse events can go to their owners

@interface SPTrackingArea : NSTrackingArea {
@public
    CGRect rect;
    NSUInteger options;
    id __weak owner;
    NSDictionary *userInfo;
}
@end
@implementation SPTrackingArea
- (CGRect)rect { return rect; }
- (NSUInteger)options { return options; }
- (id)owner { return owner; }
- (NSDictionary *)userInfo { return userInfo; }
@end

@implementation NSTrackingArea (SPEvent)
+ (instancetype)alloc {
    return self == NSTrackingArea.class ? (id)[SPTrackingArea allocWithZone:nil] : [super alloc];
}
- (instancetype)initWithRect:(CGRect)rect options:(NSUInteger)options owner:(id)owner userInfo:(NSDictionary *)info {
    if (!(self = [self init])) return nil;
    if ([self isKindOfClass:SPTrackingArea.class]) {
        SPTrackingArea *t = (SPTrackingArea *)self;
        t->rect = rect;
        t->options = options;
        t->owner = owner;
        t->userInfo = info;
    }
    sp_stub_log([NSString stringWithFormat:@"-[NSTrackingArea initWithRect:{%g,%g,%g,%g} options:0x%lx owner:<%s>]",
                 rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, (unsigned long)options,
                 object_getClassName(owner)].UTF8String);
    return self;
}
@end

static char sp_tracking_areas_key;

static NSMutableArray *sp_tracking_areas(id view) {
    NSMutableArray *a = objc_getAssociatedObject(view, &sp_tracking_areas_key);
    if (!a) {
        a = [NSMutableArray array];
        objc_setAssociatedObject(view, &sp_tracking_areas_key, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return a;
}

// ---- NSView: tracking areas, point conversion (every view is at the window's origin), hit testing

@implementation NSView (SPEvent)
- (void)addTrackingArea:(NSTrackingArea *)area {
    if (area) [sp_tracking_areas(self) addObject:area];
}
- (void)removeTrackingArea:(NSTrackingArea *)area {
    if (area) [sp_tracking_areas(self) removeObjectIdenticalTo:area];
}
- (NSArray *)trackingAreas {
    return [sp_tracking_areas(self) copy];
}
- (CGPoint)convertPoint:(CGPoint)p fromView:(id)view {
    return p;
}
- (CGPoint)convertPoint:(CGPoint)p toView:(id)view {
    return p;
}
- (CGRect)convertRect:(CGRect)r fromView:(id)view {
    return r;
}
- (CGRect)convertRect:(CGRect)r toView:(id)view {
    return r;
}
- (CGPoint)convertPointToBacking:(CGPoint)p {
    return CGPointMake(p.x * sp_scale, p.y * sp_scale);
}
- (CGPoint)convertPointFromBacking:(CGPoint)p {
    return CGPointMake(p.x / sp_scale, p.y / sp_scale);
}
- (id)hitTest:(CGPoint)p {
    return self;
}
- (BOOL)mouse:(CGPoint)p inRect:(CGRect)r {
    return p.x >= r.origin.x && p.y >= r.origin.y && p.x < r.origin.x + r.size.width &&
           p.y < r.origin.y + r.size.height;
}
- (void)resetCursorRects {  // AppKit's adds none; the client's view overrides it
}
- (void)addCursorRect:(CGRect)rect cursor:(id)cursor {
    if (!sp_cursor_rects) sp_cursor_rects = [NSMutableArray array];
    [sp_cursor_rects addObject:@[ self, [NSValue valueWithCGRect:rect], cursor ]];
}
- (void)removeCursorRect:(CGRect)rect cursor:(id)cursor {
    NSValue *r = [NSValue valueWithCGRect:rect];
    [sp_cursor_rects filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *e, id b) {
        return !(e[0] == self && [e[1] isEqual:r] && e[2] == cursor);
    }]];
}
- (void)discardCursorRects {
    [sp_cursor_rects filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *e, id b) {
        return e[0] != self;
    }]];
}
@end

// The cursor of the cursor rect under the mouse. Views, the window and the screen share coordinates.
static void sp_cursor_from_rects(void) {
    for (NSArray *e in sp_cursor_rects.reverseObjectEnumerator)
        if (CGRectContainsPoint([e[1] CGRectValue], sp_mouse)) {
            sp_cursor_set(e[2]);
            return;
        }
}

// ---- NSWindow: first responder, delegate, event delivery

static char sp_first_responder_key, sp_delegate_key, sp_accepts_moved_key;

static void sp_send(id target, SEL sel, NSEvent *e) {
    if (target && [target respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(target, sel, e);
}

static void sp_send_to_tracking_areas(id view, NSEvent *e, NSUInteger option, SEL sel) {
    for (SPTrackingArea *t in [sp_tracking_areas(view) copy]) {
        if (![t isKindOfClass:SPTrackingArea.class] || !(t->options & option)) continue;
        ((SPEvent *)e)->trackingArea = t;
        sp_send(t->owner, sel, e);
    }
    ((SPEvent *)e)->trackingArea = nil;
}

@implementation NSWindow (SPEvent)
// AppKit rebuilds the rects later, not during the call; so does this, on the main queue.
- (void)invalidateCursorRectsForView:(id)view {
    static int logged;
    if (logged++ < 5) sp_stub_log("-[NSWindow invalidateCursorRectsForView:]");
    dispatch_async(dispatch_get_main_queue(), ^{
        [view discardCursorRects];
        [view resetCursorRects];
        sp_cursor_from_rects();
    });
}
- (id)firstResponder {
    return objc_getAssociatedObject(self, &sp_first_responder_key);
}
- (BOOL)makeFirstResponder:(id)responder {
    sp_stub_log([NSString stringWithFormat:@"-[%s makeFirstResponder:<%s>]", object_getClassName(self),
                 object_getClassName(responder)].UTF8String);
    objc_setAssociatedObject(self, &sp_first_responder_key, responder, OBJC_ASSOCIATION_ASSIGN);
    return YES;
}
- (id)delegate {
    return objc_getAssociatedObject(self, &sp_delegate_key);
}
- (void)setDelegate:(id)delegate {
    objc_setAssociatedObject(self, &sp_delegate_key, delegate, OBJC_ASSOCIATION_ASSIGN);
}
- (BOOL)acceptsMouseMovedEvents {
    return [objc_getAssociatedObject(self, &sp_accepts_moved_key) boolValue];
}
- (void)setAcceptsMouseMovedEvents:(BOOL)accepts {
    objc_setAssociatedObject(self, &sp_accepts_moved_key, @(accepts), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// AppKit tells the delegate (and observers) when the window becomes key and main.
- (void)makeKeyAndOrderFront:(id)sender {
    sp_stub_log([NSString stringWithFormat:@"-[%s makeKeyAndOrderFront:]", object_getClassName(self)].UTF8String);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[ @"NSWindowDidBecomeKeyNotification", @"NSWindowDidBecomeMainNotification" ]) {
        NSNotification *n = [NSNotification notificationWithName:name object:self];
        SEL sel = [name isEqual:@"NSWindowDidBecomeKeyNotification"] ? @selector(windowDidBecomeKey:)
                                                                    : @selector(windowDidBecomeMain:);
        id delegate = [self delegate];
        if ([delegate respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, n);
        [nc postNotification:n];
    }
}
- (void)makeKeyWindow {
}
- (void)orderFront:(id)sender {
}
- (NSInteger)windowNumber {
    return 1;
}
+ (NSInteger)windowNumberAtPoint:(CGPoint)p belowWindowWithWindowNumber:(NSInteger)n {
    return n == 1 ? 0 : 1;
}
- (CGPoint)mouseLocationOutsideOfEventStream {
    return sp_mouse;
}
- (CGPoint)convertPointFromScreen:(CGPoint)p {
    return p;
}
- (CGPoint)convertPointToScreen:(CGPoint)p {
    return p;
}
- (CGRect)convertRectFromScreen:(CGRect)r {
    return r;
}
- (CGRect)convertRectToScreen:(CGRect)r {
    return r;
}
- (CGPoint)convertPointToBacking:(CGPoint)p {
    return CGPointMake(p.x * sp_scale, p.y * sp_scale);
}
- (CGPoint)convertPointFromBacking:(CGPoint)p {
    return CGPointMake(p.x / sp_scale, p.y / sp_scale);
}
- (void)sendEvent:(NSEvent *)e {
    SPEvent *ev = (SPEvent *)e;
    id view = [self contentView];
    id responder = [self firstResponder] ?: view;
    switch (ev->type) {
    case SPKeyDown: sp_send(responder, @selector(keyDown:), e); break;
    case SPKeyUp: sp_send(responder, @selector(keyUp:), e); break;
    case SPFlagsChanged: sp_send(responder, @selector(flagsChanged:), e); break;
    case SPLeftMouseDown: sp_send(view, @selector(mouseDown:), e); break;
    case SPLeftMouseUp: sp_send(view, @selector(mouseUp:), e); break;
    case SPRightMouseDown: sp_send(view, @selector(rightMouseDown:), e); break;
    case SPRightMouseUp: sp_send(view, @selector(rightMouseUp:), e); break;
    case SPOtherMouseDown: sp_send(view, @selector(otherMouseDown:), e); break;
    case SPOtherMouseUp: sp_send(view, @selector(otherMouseUp:), e); break;
    case SPLeftMouseDragged: sp_send(view, @selector(mouseDragged:), e); break;
    case SPRightMouseDragged: sp_send(view, @selector(rightMouseDragged:), e); break;
    case SPOtherMouseDragged: sp_send(view, @selector(otherMouseDragged:), e); break;
    case SPScrollWheel: sp_send(view, @selector(scrollWheel:), e); break;
    case SPMouseMoved:
        // NSTrackingMouseMoved (0x2) areas get it, and the first responder if the window asks for it.
        sp_send_to_tracking_areas(view, e, 0x2, @selector(mouseMoved:));
        if ([self acceptsMouseMovedEvents]) sp_send(responder, @selector(mouseMoved:), e);
        break;
    case SPMouseEntered: sp_send_to_tracking_areas(view, e, 0x1, @selector(mouseEntered:)); break;
    case SPMouseExited: sp_send_to_tracking_areas(view, e, 0x1, @selector(mouseExited:)); break;
    }
}
@end

// ---- NSApplication: the event queue

static char sp_app_delegate_key;

@implementation NSApplication (SPEvent)
- (id)nextEventMatchingMask:(uint64_t)mask untilDate:(id)date inMode:(id)mode dequeue:(BOOL)dequeue {
    SP_LOG_ONCE("-[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:] (pumps UIKit)");
    // Pump UIKit only when nothing is queued, so a burst of input drains before more is collected.
    if (!sp_events.count) sp_uikit_pump(NO);
    sp_window_track_scene();
    sp_key_repeats();
    for (NSUInteger i = 0; i < sp_events.count; i++) {
        SPEvent *e = sp_events[i];
        if (!(mask & (1ull << e->type))) continue;
        if (dequeue) [sp_events removeObjectAtIndex:i];
        return e;
    }
    return nil;
}
- (void)postEvent:(NSEvent *)e atStart:(BOOL)atStart {
    if (![e isKindOfClass:SPEvent.class]) return;
    if (!sp_events) sp_events = [NSMutableArray array];
    if (atStart) [sp_events insertObject:(SPEvent *)e atIndex:0]; else [sp_events addObject:(SPEvent *)e];
}
- (void)discardEventsMatchingMask:(uint64_t)mask beforeEvent:(NSEvent *)last {
    NSUInteger end = last ? [sp_events indexOfObjectIdenticalTo:(SPEvent *)last] : NSNotFound;
    if (end == NSNotFound) end = sp_events.count;
    NSIndexSet *drop = [sp_events indexesOfObjectsPassingTest:^BOOL(SPEvent *e, NSUInteger i, BOOL *stop) {
        return i < end && (mask & (1ull << e->type));
    }];
    [sp_events removeObjectsAtIndexes:drop];
}
- (void)sendEvent:(NSEvent *)e {
    if (![e isKindOfClass:SPEvent.class]) return;
    for (NSArray *monitor in [sp_local_monitors copy]) {
        if (!([monitor[0] unsignedLongLongValue] & (1ull << ((SPEvent *)e)->type))) continue;
        e = ((NSEvent * (^)(NSEvent *))monitor[1])(e);
        if (!e) return;
    }
    SPEvent *previous = sp_current_event;
    sp_current_event = (SPEvent *)e;
    [sp_client_window sendEvent:e];
    sp_current_event = previous;
}
- (id)currentEvent {
    return sp_current_event;
}
- (BOOL)isActive {
    return YES;
}
- (id)keyWindow {
    return sp_client_window;
}
- (id)mainWindow {
    return sp_client_window;
}
- (NSArray *)windows {
    return sp_client_window ? @[ sp_client_window ] : @[];
}
- (id)delegate {
    return objc_getAssociatedObject(self, &sp_app_delegate_key);
}
- (void)setDelegate:(id)delegate {
    sp_stub_log([NSString stringWithFormat:@"-[%s setDelegate:<%s>]", object_getClassName(self),
                 object_getClassName(delegate)].UTF8String);
    objc_setAssociatedObject(self, &sp_app_delegate_key, delegate, OBJC_ASSOCIATION_ASSIGN);
}
- (void)activateIgnoringOtherApps:(BOOL)flag {
}
@end

// ---- NSResponder: interpretKeyEvents: the way AppKit's key bindings would for the keys a game sees.
// Text goes to insertText:replacementRange:, editing keys to doCommandBySelector:, and keys with no
// binding (function keys, command or control combinations) to doCommandBySelector:@selector(noop:).

static SEL sp_command_for_key(SPEvent *e) {
    BOOL shift = e->modifierFlags & SPShift;
    switch (e->keyCode) {
    case 0x24: case 0x4C: return @selector(insertNewline:);
    case 0x30: return shift ? @selector(insertBacktab:) : @selector(insertTab:);
    case 0x33: return @selector(deleteBackward:);
    case 0x75: return @selector(deleteForward:);
    case 0x35: return @selector(cancelOperation:);
    case 0x7B: return shift ? @selector(moveLeftAndModifySelection:) : @selector(moveLeft:);
    case 0x7C: return shift ? @selector(moveRightAndModifySelection:) : @selector(moveRight:);
    case 0x7E: return shift ? @selector(moveUpAndModifySelection:) : @selector(moveUp:);
    case 0x7D: return shift ? @selector(moveDownAndModifySelection:) : @selector(moveDown:);
    case 0x73: return @selector(scrollToBeginningOfDocument:);
    case 0x77: return @selector(scrollToEndOfDocument:);
    case 0x74: return @selector(scrollPageUp:);
    case 0x79: return @selector(scrollPageDown:);
    }
    if (e->modifierFlags & (SPCommand | SPControl)) return @selector(noop:);
    if (e->characters.length && [e->characters characterAtIndex:0] >= 0xF700) return @selector(noop:);
    return NULL;
}

@implementation NSResponder (SPEvent)
- (void)interpretKeyEvents:(NSArray *)events {
    for (SPEvent *e in events) {
        if (![e isKindOfClass:SPEvent.class] || e->type != SPKeyDown) continue;
        SEL command = sp_command_for_key(e);
        if (command) {
            if ([self respondsToSelector:@selector(doCommandBySelector:)])
                ((void (*)(id, SEL, SEL))objc_msgSend)(self, @selector(doCommandBySelector:), command);
        } else if (e->characters.length &&
                   [self respondsToSelector:@selector(insertText:replacementRange:)]) {
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(self, @selector(insertText:replacementRange:),
                                                           e->characters, NSMakeRange(NSNotFound, 0));
        }
    }
}
@end
