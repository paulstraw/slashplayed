// A UIKit-only input harness, with the actual AppKit shim and a tiny NSTextInputClient of our own.
// No game install, Apple account, pairing record, network, or game code. --test replays touch chords
// through SPInputView, then edits the real composer and drains the real AppKit event queue.
#include "../../shims/generated/libspAppKit.m"

@interface SPHarnessResponder : NSView
@property(nonatomic, strong) NSMutableString *text;
@property(nonatomic) NSUInteger returns;
@property(nonatomic, copy) NSString *submitted;
@end
@implementation SPHarnessResponder
- (instancetype)init {
    if ((self = [super init])) _text = [NSMutableString string];
    return self;
}
- (void)insertText:(id)text replacementRange:(NSRange)range { [_text appendString:text]; }
- (void)keyDown:(SPEvent *)event {
    if (event->keyCode == 0x24) {
        _returns++;
        _submitted = [_text copy];
        [_text setString:@""];
    }
}
- (void)keyUp:(id)event {}
@end

// The shim only asks a finger for these public properties. These are test doubles, not synthesized
// system touches, so tests can replay cancellation, movement, and late releases deterministically.
@interface SPHarnessTouch : NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic) NSTimeInterval timestamp;
@end
@implementation SPHarnessTouch
- (UITouchType)type { return UITouchTypeDirect; }
- (CGFloat)majorRadiusTolerance { return 2; }
- (CGPoint)locationInView:(UIView *)view { return _point; }
@end

static SPInputView *sp_harness_input;
static SPHarnessResponder *sp_harness_responder;
static NSUInteger sp_harness_checks;

static void sp_harness_check(BOOL ok, NSString *message) {
    NSCAssert(ok, @"%@", message);
    sp_harness_checks++;
}

static NSSet *sp_harness_fingers(NSUInteger count, NSTimeInterval age) {
    NSMutableSet *touches = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; i++) {
        SPHarnessTouch *touch = [[SPHarnessTouch alloc] init];
        touch.point = CGPointMake(150 + i * 30, 100);
        touch.timestamp = NSProcessInfo.processInfo.systemUptime - age;
        [touches addObject:touch];
    }
    return touches;
}

static NSArray<SPEvent *> *sp_harness_drain(void) {
    NSMutableArray *events = [NSMutableArray array];
    SPEvent *event;
    while ((event = [sp_NSApp nextEventMatchingMask:UINT64_MAX untilDate:nil inMode:nil dequeue:YES])) {
        [events addObject:event];
        [sp_NSApp sendEvent:event];
    }
    return events;
}

static UITextView *sp_harness_editor(UIView *view) {
    if ([view isKindOfClass:UITextView.class]) return (UITextView *)view;
    for (UIView *child in view.subviews) {
        UITextView *found = sp_harness_editor(child);
        if (found) return found;
    }
    return nil;
}

// Keyboard and presentation animations settle later on a freshly booted simulator. Wait for the
// actual state, with a hard limit, rather than passing or failing based on an animation's duration.
static void sp_harness_wait(BOOL (^ready)(void), void (^run)(void), NSUInteger remaining) {
    if (ready() || !remaining) { run(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        sp_harness_wait(ready, run, remaining - 1);
    });
}

static void sp_harness_tests(UIViewController *root) {
    // The first scene fit can queue a mouse move; it is startup work, before the test's touches.
    sp_window_track_scene();
    sp_harness_drain();
    for (NSUInteger n = 1; n <= 3; n++) {
        NSSet *touches = sp_harness_fingers(n, 0);
        [sp_harness_input touchesBegan:touches withEvent:nil];
        [sp_harness_input touchesEnded:touches withEvent:nil];
        NSArray<SPEvent *> *events = sp_harness_drain();
        NSUInteger down = n == 1 ? SPLeftMouseDown : n == 2 ? SPRightMouseDown : SPOtherMouseDown;
        NSArray<SPEvent *> *buttons = [events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(SPEvent *event, NSDictionary *bindings) {
                return event->type == down || event->type == down + 1;
            }]];
        sp_harness_check(buttons.count == 2 && buttons[0]->type == down && buttons[1]->type == down + 1,
                         @"one-, two-, and three-finger taps keep their mouse buttons");
        sp_harness_check(root.presentedViewController == nil, @"mouse chords must not open the composer");
    }
    for (NSUInteger invalid = 0; invalid < 4; invalid++) {
        NSSet *touches = sp_harness_fingers(invalid == 3 ? 5 : 4, invalid == 2 ? 0.5 : 0);
        [sp_harness_input touchesBegan:touches withEvent:nil];
        if (invalid == 0) {
            ((SPHarnessTouch *)touches.anyObject).point = CGPointMake(500, 200);
            [sp_harness_input touchesMoved:touches withEvent:nil];
        }
        if (invalid == 1) [sp_harness_input touchesCancelled:touches withEvent:nil];
        else [sp_harness_input touchesEnded:touches withEvent:nil];
        sp_harness_check(sp_harness_drain().count == 0, @"an invalid keyboard gesture emits no mouse click");
        sp_harness_check(root.presentedViewController == nil, @"drag, cancellation, hold, and fifth finger do not open it");
    }

    // A held movement key must be released before the editor takes UIKit focus.
    SPEvent *held = sp_event(SPKeyDown);
    held->keyCode = 0x0D;
    sp_held_keys = [@{@(held->keyCode): held} mutableCopy];
    sp_repeat_key = held;
    NSSet *four = sp_harness_fingers(4, 0);
    [sp_harness_input touchesBegan:four withEvent:nil];
    [sp_harness_input touchesEnded:four withEvent:nil];
    NSArray<SPEvent *> *released = sp_harness_drain();
    sp_harness_check(released.count == 1 && released[0]->type == SPKeyUp, @"opening releases a movement key");
    sp_harness_check(!sp_repeat_key && sp_held_keys.count == 0, @"opening stops key repeat");
    sp_harness_check([root.presentedViewController isKindOfClass:SPTextComposer.class], @"four-finger tap opens composer");
    CGRect game = sp_game_rect();

    sp_harness_wait(^BOOL {
        return sp_harness_editor(root.presentedViewController.view).isFirstResponder;
    }, ^{
        SPTextComposer *composer = (SPTextComposer *)root.presentedViewController;
        UITextView *editor = sp_harness_editor(composer.view);
        sp_harness_check(editor.isFirstResponder, @"the native editor receives keyboard focus");
        NSString *sample = @"Café 👩🏽‍💻 中文\n/say native paste";
        [editor insertText:sample];
        sp_harness_check(sp_harness_responder.text.length == 0, @"editing alone never types into the game");
        [composer insert];
        sp_harness_check([sp_NSApp nextEventMatchingMask:UINT64_MAX untilDate:nil inMode:nil dequeue:NO] == nil,
                         @"peeking delivers a text commit without exposing a fabricated key");
        sp_harness_check(sp_harness_drain().count == 0, @"text commits do not escape as physical key events");
        sp_harness_check([sp_harness_responder.text isEqual:sample], @"Unicode and multiline text arrive intact");
        sp_harness_check(sp_harness_responder.returns == 0, @"Insert never submits chat");
        sp_harness_check(editor.text.length == 0, @"Insert clears the transient draft");
        [editor insertText:@" more"];
        [composer enter];
        [sp_NSApp nextEventMatchingMask:UINT64_MAX untilDate:nil inMode:nil dequeue:NO];
        [sp_NSApp nextEventMatchingMask:UINT64_MAX untilDate:nil inMode:nil dequeue:NO];
        sp_harness_check([sp_harness_responder.text isEqual:[sample stringByAppendingString:@" more"]],
                         @"repeated peeks never duplicate a text commit");
        sp_harness_drain();
        sp_harness_check(sp_harness_responder.returns == 1, @"Return is delivered once");
        sp_harness_check([sp_harness_responder.submitted isEqual:[sample stringByAppendingString:@" more"]],
                         @"the text commit is delivered before Return");
        sp_harness_check(CGRectEqualToRect(game, sp_game_rect()), @"keyboard presentation does not resize the game");
        [editor insertText:@"discard this draft"];
        [composer done];
        sp_harness_wait(^BOOL { return !root.presentedViewController && sp_harness_input.isFirstResponder; }, ^{
            sp_harness_drain();
            sp_harness_check(!root.presentedViewController && sp_harness_input.isFirstResponder,
                             @"Done restores the game's keyboard focus");
            sp_harness_check(sp_harness_responder.text.length == 0 && sp_harness_responder.returns == 1,
                             @"Done discards the draft without inserting or submitting it");
            NSDictionary *result = @{@"passed": @(sp_harness_checks), @"result": @"passed"};
            NSURL *url = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
                writeToURL:[url URLByAppendingPathComponent:@"textinput-tests.json"] atomically:YES];
            fprintf(stderr, "Text input harness: %lu checks passed\n", (unsigned long)sp_harness_checks);
            // Leave the actual composer open for a visual review after the replay has passed.
            [sp_harness_input sp_show_text_composer];
        }, 100);
    }, 100);
}

#include "touchtests.m"

@interface SPTextHarnessSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SPTextHarnessSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    sp_in_uikit = YES;  // the harness has a normal UIKit loop; no client coroutine or debugger
    sp_NSApp = [[NSApplication alloc] init];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    sp_window = self.window;
    UIViewController *root = sp_make_root_view_controller();
    root.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.09 blue:0.07 alpha:1];
    sp_harness_input = (SPInputView *)root.view;
    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"Input harness · four-finger tap to type\nNo game code or account needed";
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [root.view addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:root.view.centerYAnchor constant:-20],
    ]];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    sp_client_window = [[NSWindow alloc] initWithContentRect:self.window.bounds styleMask:0 backing:0 defer:NO];
    sp_harness_responder = [[SPHarnessResponder alloc] init];
    [sp_client_window setContentView:sp_harness_responder];
    [sp_client_window makeFirstResponder:sp_harness_responder];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--test"])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [NSUserDefaults.standardUserDefaults removeObjectForKey:SPTouchDefaultsKey];
            [sp_harness_controls(root.view) reload];
            sp_harness_touch_tests(root);
        });
    else if ([NSProcessInfo.processInfo.arguments containsObject:@"--controls"])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [sp_harness_input sp_show_touch_settings]; });
    else if ([NSProcessInfo.processInfo.arguments containsObject:@"--touch-preview"]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SPTouchDefaultsKey];
        [sp_harness_controls(root.view) reload];
        hint.text = @"Touch controls · floating sticks\nDrag anywhere on either side · hold still to right-click";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSSet *left = sp_harness_touch(CGPointMake(175, 280)), *right = sp_harness_touch(CGPointMake(700, 280));
            [sp_harness_input touchesBegan:left withEvent:nil]; [sp_harness_input touchesBegan:right withEvent:nil];
            ((SPHarnessTouch *)left.anyObject).point = CGPointMake(205, 265);
            ((SPHarnessTouch *)right.anyObject).point = CGPointMake(720, 250);
            [sp_harness_input touchesMoved:left withEvent:nil]; [sp_harness_input touchesMoved:right withEvent:nil];
        });
    }
    else if ([NSProcessInfo.processInfo.arguments containsObject:@"--composer"])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [sp_harness_input sp_show_text_composer]; });
}
@end

@interface SPTextHarnessDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation SPTextHarnessDelegate
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SPTextHarnessDelegate.class)); }
}
