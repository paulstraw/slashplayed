// Replays the actual touch router, AppKit event queue, and Apple's hidden virtual controller.
static SPTouchControls *sp_harness_controls(UIView *root) {
    for (UIView *view in root.subviews) if ([view isKindOfClass:SPTouchControls.class]) return (SPTouchControls *)view;
    return nil;
}

static NSSet *sp_harness_touch(CGPoint point) {
    SPHarnessTouch *touch = [[SPHarnessTouch alloc] init];
    touch.point = point; touch.timestamp = NSProcessInfo.processInfo.systemUptime;
    return [NSSet setWithObject:touch];
}

static NSArray<SPEvent *> *sp_harness_type(NSArray<SPEvent *> *events, NSUInteger type) {
    return [events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPEvent *e, NSDictionary *b) {
        return e->type == type;
    }]];
}
static void sp_harness_gesture_events(SPTouchControls *controls, void (^done)(void)) {
    NSSet *first = sp_harness_touch(CGPointMake(600, 180));
    NSSet *second = sp_harness_touch(CGPointMake(720, 180));
    NSSet *pair = [first setByAddingObjectsFromSet:second];
    [sp_harness_input touchesBegan:first withEvent:nil];
    [sp_harness_input touchesBegan:second withEvent:nil];
    sp_harness_check(!sp_harness_drain().count, @"forming a gesture emits no premature click");
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(580, 180);
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(740, 180);
    [sp_harness_input touchesMoved:pair withEvent:nil];
    NSArray<SPEvent *> *events = sp_harness_drain();
    NSArray<SPEvent *> *wheel = sp_harness_type(events, SPScrollWheel);
    sp_harness_check(wheel.count == 2 && wheel[0]->phase == 1 && wheel[1]->deltaY > 0,
                     @"spreading two fingers emits zoom-in scroll with a began phase");
    sp_harness_check(!sp_harness_type(events, SPLeftMouseDown).count && !sp_harness_type(events, SPRightMouseDown).count && !sp_mouse_buttons,
                     @"pinching emits no mouse press");
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(600, 180);
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(720, 180);
    [sp_harness_input touchesMoved:pair withEvent:nil];
    events = sp_harness_drain(); wheel = sp_harness_type(events, SPScrollWheel);
    sp_harness_check(wheel.count == 1 && wheel[0]->deltaY < 0, @"closing the pinch emits zoom-out scroll");
    [sp_harness_input touchesEnded:first withEvent:nil];
    wheel = sp_harness_type(sp_harness_drain(), SPScrollWheel);
    sp_harness_check(wheel.count == 1 && wheel[0]->phase == 8, @"lifting either pinch finger ends its scroll phase");
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(760, 190);
    [sp_harness_input touchesMoved:second withEvent:nil];
    [sp_harness_input touchesEnded:second withEvent:nil];
    sp_harness_check(!sp_harness_drain().count, @"remaining pinch finger cannot click or become a stick");

    first = sp_harness_touch(CGPointMake(600, 180)); second = sp_harness_touch(CGPointMake(720, 180));
    pair = [first setByAddingObjectsFromSet:second];
    [sp_harness_input touchesBegan:first withEvent:nil]; [sp_harness_input touchesBegan:second withEvent:nil];
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(625, 192);
    // Deliberately deliver adjacent motion reports separately, like UIKit can at pan onset.
    [sp_harness_input touchesMoved:first withEvent:nil];
    sp_harness_check(!sp_harness_drain().count, @"a single early pan report waits for the second finger");
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(745, 192);
    [sp_harness_input touchesMoved:second withEvent:nil];
    events = sp_harness_drain();
    NSArray<SPEvent *> *downs = sp_harness_type(events, SPLeftMouseDown);
    sp_harness_check(downs.count == 1 && CGPointEqualToPoint(downs[0]->location, sp_from_uikit(CGPointMake(600, 180))),
                     @"two-finger item drag presses at the first finger's original position");
    sp_harness_check(sp_harness_type(events, SPLeftMouseDragged).count > 0 && !sp_harness_type(events, SPScrollWheel).count,
                     @"parallel pan becomes mouse drag instead of zoom");
    [sp_harness_input touchesCancelled:second withEvent:nil];
    sp_harness_check(sp_harness_type(sp_harness_drain(), SPLeftMouseUp).count == 1 && !sp_mouse_buttons,
                     @"cancelled pan releases its primary mouse button");
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(650, 200);
    [sp_harness_input touchesMoved:first withEvent:nil]; [sp_harness_input touchesEnded:first withEvent:nil];
    sp_harness_check(!sp_harness_drain().count, @"remaining pan finger stays suppressed after cancellation");

    NSMutableDictionary *config = sp_touch_load(); config[@"twoFingerDrag"] = @"Turn Character"; sp_touch_save(config);
    first = sp_harness_touch(CGPointMake(600, 180)); second = sp_harness_touch(CGPointMake(720, 180));
    pair = [first setByAddingObjectsFromSet:second];
    [sp_harness_input touchesBegan:pair withEvent:nil];
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(625, 192);
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(745, 192);
    [sp_harness_input touchesMoved:pair withEvent:nil];
    events = sp_harness_drain();
    sp_harness_check(sp_harness_type(events, SPRightMouseDown).count == 1 && !sp_harness_type(events, SPLeftMouseDown).count,
                     @"Turn Character option uses right-button camera dragging");
    sp_set_mouse_frozen(YES); CGPoint frozen = sp_mouse;
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(645, 192);
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(765, 192);
    [sp_harness_input touchesMoved:pair withEvent:nil];
    NSArray<SPEvent *> *drag = sp_harness_type(sp_harness_drain(), SPRightMouseDragged);
    sp_harness_check(drag.count == 1 && fabs(drag[0]->deltaX - 20) < .001 && CGPointEqualToPoint(sp_mouse, frozen),
                     @"camera pan supplies relative movement while the game freezes its cursor");
    [controls inactive]; events = sp_harness_drain();
    sp_harness_check(sp_harness_type(events, SPRightMouseUp).count == 1 && !sp_mouse_buttons,
                     @"backgrounding releases an active camera gesture");
    [sp_harness_input touchesEnded:pair withEvent:nil]; sp_harness_drain(); sp_set_mouse_frozen(NO);
    config[@"twoFingerDrag"] = @"Orbit / Drag Items"; sp_touch_save(config);

    NSSet *tap = sp_harness_touch(CGPointMake(610, 230));
    [sp_harness_input touchesBegan:tap withEvent:nil]; [sp_harness_input touchesEnded:tap withEvent:nil]; sp_harness_drain();
    tap = sp_harness_touch(CGPointMake(610, 230));
    [sp_harness_input touchesBegan:tap withEvent:nil];
    ((SPHarnessTouch *)tap.anyObject).point = CGPointMake(640, 240);
    [sp_harness_input touchesMoved:tap withEvent:nil];
    events = sp_harness_drain();
    sp_harness_check(sp_harness_type(events, SPLeftMouseDown).count == 1 && sp_harness_type(events, SPLeftMouseDragged).count > 0,
                     @"double-tap and drag moves UI items without becoming a stick");
    [sp_harness_input touchesEnded:tap withEvent:nil];
    sp_harness_check(sp_harness_type(sp_harness_drain(), SPLeftMouseUp).count == 1 && !sp_mouse_buttons,
                     @"double-tap drag releases cleanly");
    [controls releaseAll]; sp_harness_drain();

    first = sp_harness_touch(CGPointMake(600, 180)); second = sp_harness_touch(CGPointMake(720, 180));
    pair = [first setByAddingObjectsFromSet:second];
    [sp_harness_input touchesBegan:first withEvent:nil]; [sp_harness_input touchesBegan:second withEvent:nil];
    [sp_harness_input touchesEnded:pair withEvent:nil];
    events = sp_harness_drain();
    sp_harness_check(sp_harness_type(events, SPRightMouseDown).count == 1 && sp_harness_type(events, SPRightMouseUp).count == 1 &&
                     !sp_harness_type(events, SPLeftMouseDown).count, @"short two-finger tap right-clicks once");
    [controls releaseAll]; sp_harness_drain();

    // A left thumb remains a controller input while a same-side pair on the right pinches.
    NSSet *left = sp_harness_touch(CGPointMake(130, 250));
    [sp_harness_input touchesBegan:left withEvent:nil];
    ((SPHarnessTouch *)left.anyObject).point = CGPointMake(180, 250);
    [sp_harness_input touchesMoved:left withEvent:nil];
    first = sp_harness_touch(CGPointMake(600, 180)); second = sp_harness_touch(CGPointMake(720, 180));
    pair = [first setByAddingObjectsFromSet:second];
    [sp_harness_input touchesBegan:pair withEvent:nil];
    ((SPHarnessTouch *)first.anyObject).point = CGPointMake(580, 180);
    ((SPHarnessTouch *)second.anyObject).point = CGPointMake(740, 180);
    [sp_harness_input touchesMoved:pair withEvent:nil];
    sp_harness_check(sp_harness_type(sp_harness_drain(), SPScrollWheel).count == 2 && !sp_mouse_buttons,
                     @"pinch zoom works with an independent opposite-side movement stick");
    sp_harness_wait(^BOOL { return controls.virtualController.controller.extendedGamepad.leftThumbstick.xAxis.value > .8; }, ^{
        sp_harness_check(controls.virtualController.controller.extendedGamepad.leftThumbstick.xAxis.value > .8,
                         @"pinching does not neutralize the active opposite-side stick");
        [sp_harness_input touchesEnded:pair withEvent:nil]; [sp_harness_input touchesEnded:left withEvent:nil];
        [controls releaseAll]; sp_harness_drain();
        NSSet *a = sp_harness_touch(CGPointMake(600, 180)), *b = sp_harness_touch(CGPointMake(720, 180));
        NSSet *stationary = [a setByAddingObjectsFromSet:b];
        [sp_harness_input touchesBegan:stationary withEvent:nil];
        ((SPHarnessTouch *)b.anyObject).point = CGPointMake(760, 180);
        [sp_harness_input touchesMoved:b withEvent:nil];
        sp_harness_check(!sp_harness_drain().count, @"stationary-finger pinch waits through the pan arbitration interval");
        sp_harness_wait(^BOOL { return sp_harness_type(sp_events, SPScrollWheel).count > 0; }, ^{
            NSArray<SPEvent *> *wheel = sp_harness_type(sp_harness_drain(), SPScrollWheel);
            sp_harness_check(wheel.count == 2 && wheel[1]->deltaY > 0,
                             @"one stationary finger still permits pinch zoom after arbitration");
            [sp_harness_input touchesCancelled:stationary withEvent:nil]; sp_harness_drain();
            NSSet *c = sp_harness_touch(CGPointMake(600, 180)), *d = sp_harness_touch(CGPointMake(720, 180));
            NSSet *cancelled = [c setByAddingObjectsFromSet:d];
            [sp_harness_input touchesBegan:cancelled withEvent:nil];
            ((SPHarnessTouch *)d.anyObject).point = CGPointMake(760, 180);
            [sp_harness_input touchesMoved:d withEvent:nil];
            [sp_harness_input touchesCancelled:cancelled withEvent:nil]; sp_harness_drain();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                sp_harness_check(!sp_harness_drain().count && !sp_mouse_buttons,
                                 @"cancelled gesture cannot emit a delayed pinch or click");
                NSMutableDictionary *off = sp_touch_load(); off[@"pinch"] = @NO;
                sp_touch_save(off);
                NSSet *e = sp_harness_touch(CGPointMake(600, 180)), *f = sp_harness_touch(CGPointMake(720, 180));
                NSSet *disabled = [e setByAddingObjectsFromSet:f];
                [sp_harness_input touchesBegan:disabled withEvent:nil];
                ((SPHarnessTouch *)e.anyObject).point = CGPointMake(580, 180);
                ((SPHarnessTouch *)f.anyObject).point = CGPointMake(740, 180);
                [sp_harness_input touchesMoved:disabled withEvent:nil];
                [sp_harness_input touchesEnded:disabled withEvent:nil];
                sp_harness_check(!sp_harness_drain().count, @"pinch can be disabled without turning it into a stray mouse click");
                off[@"pinch"] = @YES; sp_touch_save(off);
                done();
            });
        }, 100);
    }, 100);
}

static void sp_harness_button_events(SPTouchControls *controls) {
    __block NSUInteger opened = 0;
    void (^keyboard)(void) = controls.keyboard;
    controls.keyboard = ^{ opened++; };
    for (NSUInteger i = 0; i < 4; i++) {
        NSSet *four = sp_harness_fingers(i == 3 ? 5 : 4, 0);
        [sp_harness_input touchesBegan:four withEvent:nil];
        if (i == 1) {
            ((SPHarnessTouch *)four.anyObject).point = CGPointMake(500, 300);
            [sp_harness_input touchesMoved:four withEvent:nil];
        }
        if (i == 2) [sp_harness_input touchesCancelled:four withEvent:nil];
        else [sp_harness_input touchesEnded:four withEvent:nil];
    }
    sp_harness_check(opened == 1 && sp_harness_drain().count == 0, @"floating mode reserves the four-finger keyboard gesture and rejects drags, cancels, and fifth fingers");
    NSSet *four = sp_harness_fingers(4, 0);
    [sp_harness_input touchesBegan:four withEvent:nil];
    NSSet *early = [NSSet setWithObject:four.anyObject];
    [sp_harness_input touchesEnded:early withEvent:nil];
    NSSet *fifth = sp_harness_fingers(1, 0);
    [sp_harness_input touchesBegan:fifth withEvent:nil];
    NSMutableSet *rest = [four mutableCopy]; [rest minusSet:early]; [rest unionSet:fifth];
    [sp_harness_input touchesEnded:rest withEvent:nil];
    sp_harness_check(opened == 1 && !sp_harness_drain().count, @"a fifth finger after an early lift still cancels the keyboard gesture");
    SPTouchButton *keyboardButton = [[SPTouchButton alloc] init];
    keyboardButton.binding = sp_touch_button(@"Type", @"Keyboard", @"Toggle", .5, .5);
    [controls button:keyboardButton phase:1];
    sp_harness_check(opened == 2, @"custom Keyboard action opens once even with Toggle behavior selected");
    NSSet *seqOne = sp_harness_touch(CGPointMake(600, 120)), *seqTwo = sp_harness_touch(CGPointMake(700, 120));
    NSSet *three = sp_harness_touch(CGPointMake(200, 120)), *fourth = sp_harness_touch(CGPointMake(300, 120));
    NSMutableSet *sequential = [NSMutableSet set];
    for (NSSet *finger in @[seqOne, seqTwo, three, fourth]) {
        [sp_harness_input touchesBegan:finger withEvent:nil]; [sequential unionSet:finger];
    }
    [sp_harness_input touchesEnded:sequential withEvent:nil];
    sp_harness_check(opened == 3 && !sp_harness_drain().count, @"four-finger keyboard tap supersedes an undecided two-finger pair");
    controls.keyboard = keyboard;
    NSMutableDictionary *persisted = sp_touch_load();
    NSMutableDictionary *custom = sp_touch_button(@"Map", @"Key combo", @"Toggle", .75, .8);
    custom[@"combo"] = @"Ctrl+M";
    [persisted[@"buttons"] addObject:custom]; sp_touch_save(persisted);
    NSDictionary *loaded = [sp_touch_load()[@"buttons"] lastObject];
    sp_harness_check([loaded[@"id"] isEqual:custom[@"id"]] && [loaded[@"combo"] isEqual:@"Ctrl+M"] &&
        [loaded[@"mode"] isEqual:@"Toggle"] && [loaded[@"x"] doubleValue] == .75, @"custom button binding, behavior, and placement persist");
    SPTouchSettings *editor = [[SPTouchSettings alloc] init];
    editor.buttonID = @"default-lb"; [editor loadViewIfNeeded]; [editor viewWillAppear:NO];
    UITableViewCell *label = [editor tableView:editor.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    sp_harness_check([label.detailTextLabel.text isEqual:@"LB"], @"native editor resolves an untouched default button by stable ID");
    NSArray *combo = sp_touch_combo(@"1+Shift+Ctrl");
    sp_harness_check([combo isEqual:@[@225, @224, @30]], @"combos normalize modifiers before ordinary keys");
    sp_harness_check(!sp_touch_combo(@"Shift++1") && !sp_touch_combo(@"F21") && !sp_touch_combo(@"banana"), @"invalid key bindings are rejected");
    sp_harness_check([sp_touch_combo(@"F13+F20") isEqual:@[@104, @111]], @"extended function keys use correct HID usages");
    sp_harness_check(CGPointEqualToPoint(sp_touch_axis(CGPointMake(2, 2), 56, .16), CGPointZero), @"stick dead zone is neutral");
    CGPoint full = sp_touch_axis(CGPointMake(500, -500), 56, .16);
    sp_harness_check(fabs(hypot(full.x, full.y) - 1) < .0001 && full.y > 0, @"radial stick output clamps and flips UIKit y");

    NSDictionary *one = sp_touch_button(@"1", @"Key combo", @"Hold", .5, .5);
    NSMutableDictionary *two = sp_touch_button(@"2", @"Key combo", @"Hold", .5, .5); two[@"combo"] = @"Shift+2";
    [controls action:one owner:@"one" down:YES at:CGPointMake(NAN, NAN)];
    [controls action:two owner:@"two" down:YES at:CGPointMake(NAN, NAN)];
    NSArray<SPEvent *> *events = sp_harness_drain();
    sp_harness_check(events.count == 3 && events[0]->type == SPFlagsChanged && events[1]->keyCode == 0x12 &&
        events[2]->keyCode == 0x13 && (events[2]->modifierFlags & SPShift), @"modifier down precedes shared key combo downs");
    [controls action:one owner:@"one" down:NO at:CGPointMake(NAN, NAN)];
    events = sp_harness_drain();
    sp_harness_check(events.count == 1 && events[0]->type == SPKeyUp && (NSEvent.modifierFlags & SPShift), @"releasing one combo preserves the shared modifier");
    [controls releaseAll]; events = sp_harness_drain();
    sp_harness_check(events.count == 2 && events[0]->type == SPKeyUp && events[1]->type == SPFlagsChanged && !NSEvent.modifierFlags,
                     @"clearing controls releases keys before their modifiers");

    // A physical key's ownership survives release of the same key on a touch button.
    SPEvent *physical = sp_event(SPKeyDown); physical->keyCode = 0x12;
    sp_held_keys = [@{@0x12: physical} mutableCopy];
    [controls action:one owner:@"one" down:YES at:CGPointMake(NAN, NAN)];
    [controls releaseAll]; events = sp_harness_drain();
    sp_harness_check(events.count == 2 && events[0]->type == SPFlagsChanged && events[1]->type == SPFlagsChanged,
                     @"touch combo does not release a physically held key");
    [sp_held_keys removeAllObjects];
    sp_mouse_button(1, YES, sp_pointer); sp_harness_drain();
    [controls action:@{@"action": @"Right click"} owner:@"right" down:YES at:CGPointMake(NAN, NAN)];
    [controls releaseAll];
    sp_harness_check(sp_harness_drain().count == 0 && (sp_mouse_buttons & 2), @"touch mouse release preserves a physical mouse hold");
    sp_mouse_button(1, NO, sp_pointer); sp_harness_drain();

    [controls action:one owner:@"background" down:YES at:CGPointMake(NAN, NAN)]; sp_harness_drain();
    [controls inactive];
    sp_harness_check(sp_harness_drain().count == 2 && !NSEvent.modifierFlags, @"leaving the app releases latched keys and modifiers");

    SPTouchButton *button = [[SPTouchButton alloc] init];
    button.binding = sp_touch_button(@"LB", @"LB", @"Toggle", .1, .3);
    [controls button:button phase:0]; [controls button:button phase:2];
    sp_harness_check(controls.virtualController.controller.extendedGamepad.leftShoulder.value == 0, @"cancelled toggle press stays released");
    [controls button:button phase:1];
    sp_harness_wait(^BOOL { return controls.virtualController.controller.extendedGamepad.leftShoulder.isPressed; }, ^{
        sp_harness_check(controls.virtualController.controller.extendedGamepad.leftShoulder.isPressed, @"toggle latches native LB");
        [controls button:button phase:1];
        sp_harness_wait(^BOOL { return !controls.virtualController.controller.extendedGamepad.leftShoulder.isPressed; }, ^{
            sp_harness_check(!controls.virtualController.controller.extendedGamepad.leftShoulder.isPressed, @"second toggle releases native LB");
            button.binding = sp_touch_button(@"View", @"View", @"Hold", .1, .3);
            [controls button:button phase:0];
            sp_harness_wait(^BOOL { return controls.virtualController.controller.extendedGamepad.buttonOptions.isPressed; }, ^{
                sp_harness_check(controls.virtualController.controller.extendedGamepad.buttonOptions.isPressed, @"hold presses native View");
                [controls button:button phase:2];
                button.binding = sp_touch_button(@"Menu", @"Menu", @"Tap", .1, .3);
                [controls button:button phase:1];
                sp_harness_wait(^BOOL { return controls.virtualController.controller.extendedGamepad.buttonMenu.isPressed; }, ^{
                    sp_harness_check(controls.virtualController.controller.extendedGamepad.buttonMenu.isPressed, @"tap presses native Menu");
                    sp_harness_wait(^BOOL { return !controls.virtualController.controller.extendedGamepad.buttonMenu.isPressed; }, ^{
                        sp_harness_check(!controls.virtualController.controller.extendedGamepad.buttonMenu.isPressed &&
                            !controls.virtualController.controller.extendedGamepad.buttonOptions.isPressed, @"tap pulse and cancelled hold release");
                        NSMutableDictionary *config = sp_touch_load(); config[@"enabled"] = @NO; sp_touch_save(config);
                        // The original chord + native keyboard suite also exercises the disabled fallback.
                        sp_harness_tests(sp_harness_input.window.rootViewController);
                    }, 100);
                }, 100);
            }, 100);
        }, 100);
    }, 100);
}

static void sp_harness_touch_tests(UIViewController *root) {
    sp_window_track_scene(); [root.view layoutIfNeeded]; sp_harness_drain();
    SPTouchControls *controls = sp_harness_controls(root.view);
    sp_harness_check(controls != nil, @"the root owns its touch overlay");
    sp_harness_wait(^BOOL { return controls.virtualController.controller != nil; }, ^{
        sp_harness_check(controls.virtualController.controller != nil, @"hidden native gamepad connects");
        // Its connection reply clears inputs asynchronously; run after that has settled.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSSet *tap = sp_harness_touch(CGPointMake(180, 220));
            [sp_harness_input touchesBegan:tap withEvent:nil];
            sp_harness_check(sp_harness_drain().count == 0, @"touch down does not emit a premature click");
            [sp_harness_input touchesEnded:tap withEvent:nil];
            NSArray<SPEvent *> *events = sp_harness_drain();
            NSArray *clicks = [events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPEvent *e, NSDictionary *b) {
                return e->type == SPLeftMouseDown || e->type == SPLeftMouseUp;
            }]];
            sp_harness_check(clicks.count == 2, @"short world tap still clicks the action bar");

            NSSet *left = sp_harness_touch(CGPointMake(120, 260)), *right = sp_harness_touch(CGPointMake(650, 260));
            [sp_harness_input touchesBegan:left withEvent:nil]; [sp_harness_input touchesBegan:right withEvent:nil];
            ((SPHarnessTouch *)left.anyObject).point = CGPointMake(170, 260);
            ((SPHarnessTouch *)right.anyObject).point = CGPointMake(650, 210);
            [sp_harness_input touchesMoved:left withEvent:nil]; [sp_harness_input touchesMoved:right withEvent:nil];
            sp_harness_wait(^BOOL {
                return controls.virtualController.controller.extendedGamepad.leftThumbstick.xAxis.value > .8 &&
                       controls.virtualController.controller.extendedGamepad.rightThumbstick.yAxis.value > .8;
            }, ^{
                sp_harness_check(controls.virtualController.controller.extendedGamepad.leftThumbstick.xAxis.value > .8 &&
                    controls.virtualController.controller.extendedGamepad.rightThumbstick.yAxis.value > .8, @"both floating sticks work simultaneously from arbitrary origins");
                sp_harness_check(sp_harness_drain().count == 0, @"stick movement never emits mouse clicks");
                [sp_harness_input touchesCancelled:left withEvent:nil]; [sp_harness_input touchesEnded:right withEvent:nil];
                sp_harness_wait(^BOOL { return controls.virtualController.controller.extendedGamepad.leftThumbstick.xAxis.value == 0 &&
                    controls.virtualController.controller.extendedGamepad.rightThumbstick.yAxis.value == 0; }, ^{
                    sp_harness_check(controls.virtualController.controller.extendedGamepad.leftThumbstick.xAxis.value == 0 &&
                        controls.virtualController.controller.extendedGamepad.rightThumbstick.yAxis.value == 0, @"lift and cancellation neutralize both sticks");
                    NSSet *hold = sp_harness_touch(CGPointMake(240, 170));
                    [sp_harness_input touchesBegan:hold withEvent:nil];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 550 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                        NSArray<SPEvent *> *held = sp_harness_drain();
                        sp_harness_check(sp_mouse_buttons == 2 && [[held filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                            ^BOOL(SPEvent *e, NSDictionary *b) { return e->type == SPLeftMouseDown; }]] count] == 0,
                            @"long press holds only right click without a preceding left click");
                        ((SPHarnessTouch *)hold.anyObject).point = CGPointMake(265, 175);
                        [sp_harness_input touchesMoved:hold withEvent:nil]; [sp_harness_input touchesEnded:hold withEvent:nil];
                        NSArray<SPEvent *> *drag = sp_harness_drain();
                        sp_harness_check([[drag filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                            ^BOOL(SPEvent *e, NSDictionary *b) { return e->type == SPRightMouseDragged; }]] count] > 0 && !sp_mouse_buttons,
                            @"long press can right-drag and releases cleanly");
                        sp_harness_gesture_events(controls, ^{ sp_harness_button_events(controls); });
                    });
                }, 100);
            }, 100);
        });
    }, 100);
}
