// A transparent, app-drawn controller. World taps remain mouse clicks; only deliberate drags claim
// a stick. GCVirtualController supplies public gamepad input, exactly as a physical controller does.
#include "sptouchsettings.m"

static NSDictionary<NSString *, NSString *> *sp_touch_gamepad_buttons(void) {
    return @{@"LB": GCInputLeftShoulder, @"RB": GCInputRightShoulder, @"View": GCInputButtonOptions,
        @"Menu": GCInputButtonMenu, @"A": GCInputButtonA, @"B": GCInputButtonB, @"X": GCInputButtonX,
        @"Y": GCInputButtonY, @"LT": GCInputLeftTrigger, @"RT": GCInputRightTrigger,
        @"L3": GCInputLeftThumbstickButton, @"R3": GCInputRightThumbstickButton};
}

static CGPoint sp_touch_axis(CGPoint delta, CGFloat radius, CGFloat deadzone) {
    CGFloat length = hypot(delta.x, delta.y), d = length / radius;
    if (d <= deadzone || !length) return CGPointZero;
    CGFloat value = fmin(1, (d - deadzone) / (1 - deadzone));
    return CGPointMake(delta.x / length * value, -delta.y / length * value);
}

enum { SPTouchPending, SPTouchStick, SPTouchRightDrag, SPTouchLeftDrag, SPTouchIgnored, SPTouchPaired };

@interface SPTouchContact : NSObject
@property(nonatomic) CGPoint origin, point;
@property(nonatomic) NSTimeInterval began;
@property(nonatomic) NSInteger state, side;
@property(nonatomic) BOOL doubleTap;
@property(nonatomic, copy) NSString *owner;
@end
@implementation SPTouchContact
@end

// WoW has one mouse cursor. One same-side pair owns mouse gestures; an opposite-side stick remains
// independent. A pair never takes over a stick that already started moving.
@interface SPTouchPair : NSObject
@property(nonatomic, strong) SPTouchContact *first, *second;
@property(nonatomic) CGPoint startFirst, startSecond;
@property(nonatomic) CGFloat distance, lastDistance;
@property(nonatomic) NSInteger mode;  // undecided, drag, pinch
@property(nonatomic) BOOL waitingForSecond;
@property(nonatomic, copy) NSString *owner;
@end
@implementation SPTouchPair
@end

@interface SPTouchButton : UIButton
@property(nonatomic, strong) NSDictionary *binding;
@property(nonatomic, copy) void (^pressed)(SPTouchButton *, NSInteger);
@property(nonatomic, copy) void (^moved)(SPTouchButton *, UIPanGestureRecognizer *);
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
@property(nonatomic, strong) UIImage *cutoutIcon;
@property(nonatomic) CGFloat pillWidth;
@property(nonatomic) BOOL latched;
@end
@implementation SPTouchButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.exclusiveTouch = NO;
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        [self addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside];
        [self addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        _pan.enabled = NO;
        [self addGestureRecognizer:_pan];
    }
    return self;
}
- (void)down { if (_pressed) _pressed(self, 0); }
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    // Draw the entire pill into one transparent backing store. Destination-out removes the glyph's
    // pixels, so the game is visible through the icon, including when the backdrop is fully opaque.
    CGFloat width = _pillWidth ?: 40, height = width * .55;
    CGRect pill = CGRectMake((self.bounds.size.width - width) / 2,
                             (self.bounds.size.height - height) / 2, width, height);
    UIColor *fill = _latched ? [UIColor colorWithRed:.60 green:.82 blue:1 alpha:1] :
                    [UIColor colorWithWhite:self.highlighted ? .70 : .88 alpha:1];
    [fill setFill];
    [[UIBezierPath bezierPathWithRoundedRect:pill cornerRadius:height / 2] fill];
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeDestinationOut);
    if (_cutoutIcon) {
        CGSize size = _cutoutIcon.size;
        CGFloat scale = fmin((width - 16) / size.width, (height - 9) / size.height);
        size = CGSizeMake(size.width * scale, size.height * scale);
        [_cutoutIcon drawInRect:CGRectMake(CGRectGetMidX(pill) - size.width / 2,
            CGRectGetMidY(pill) - size.height / 2, size.width, size.height)
            blendMode:kCGBlendModeDestinationOut alpha:1];
    } else {
        NSString *label = _binding[@"label"] ?: @"";
        UIFont *font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        CGFloat measured = [label sizeWithAttributes:@{NSFontAttributeName: font}].width;
        font = [font fontWithSize:fmin(10, 10 * (width - 12) / fmax(1, measured))];
        CGSize size = [label sizeWithAttributes:@{NSFontAttributeName: font}];
        [label drawAtPoint:CGPointMake(CGRectGetMidX(pill) - size.width / 2,
            CGRectGetMidY(pill) - size.height / 2)
            withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.blackColor}];
    }
    CGContextRestoreGState(context);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat x = fmax(0, (44 - self.bounds.size.width) / 2), y = fmax(0, (44 - self.bounds.size.height) / 2);
    return CGRectContainsPoint(CGRectInset(self.bounds, -x, -y), point);
}
- (void)up { if (_pressed) _pressed(self, 1); }
- (void)cancel { if (_pressed) _pressed(self, 2); }
- (void)pan:(UIPanGestureRecognizer *)pan { if (_moved) _moved(self, pan); }
@end

@interface SPTouchControls : UIView
@property(nonatomic, copy) void (^keyEvent)(NSUInteger, BOOL);
@property(nonatomic, copy) void (^mouseEvent)(NSInteger, BOOL, CGPoint);
@property(nonatomic, copy) void (^mouseMove)(CGPoint);
@property(nonatomic, copy) void (^scrollEvent)(CGFloat, CGPoint, NSUInteger);
@property(nonatomic, copy) void (^keyboard)(void);
@property(nonatomic, copy) void (^settings)(void);
@property(nonatomic, copy) void (^arranged)(void);
@property(nonatomic, readonly) NSDictionary *config;
@property(nonatomic, readonly) GCVirtualController *virtualController;
@property(nonatomic) BOOL arranging;
- (NSSet<UITouch *> *)route:(NSSet<UITouch *> *)touches phase:(NSInteger)phase inView:(UIView *)view;
- (void)releaseAll;
- (void)reload;
- (void)start;
@end

@implementation SPTouchControls {
    NSMutableDictionary *_config;
    GCVirtualController *_virtualController;
    BOOL _connecting;
    NSMapTable<UITouch *, SPTouchContact *> *_contacts;
    NSMutableDictionary<NSString *, NSDictionary *> *_held;
    NSSet<NSNumber *> *_keys;
    NSSet<NSString *> *_padButtons;
    NSSet<NSNumber *> *_mouseButtons;
    NSMutableArray<SPTouchButton *> *_buttons;
    UIButton *_finish;
    UILabel *_layoutHint, *_status;
    BOOL _four, _fourInvalid;
    NSTimeInterval _fourBegan;
    SPTouchPair *_pair;
    CGPoint _lastTapPoint[2];
    NSTimeInterval _lastTapTime[2];
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    _contacts = [NSMapTable strongToStrongObjectsMapTable];
    _held = [NSMutableDictionary dictionary];
    _keys = [NSSet set]; _padButtons = [NSSet set]; _mouseButtons = [NSSet set];
    _buttons = [NSMutableArray array];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SPTouchChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(start) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerDisconnected:) name:GCControllerDidDisconnectNotification object:nil];
    [self reload];
    return self;
}
- (NSDictionary *)config { return _config; }
- (GCVirtualController *)virtualController { return _virtualController; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_virtualController disconnect]; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    return view == self ? nil : view;
}
- (void)didMoveToWindow { [super didMoveToWindow]; if (self.window) [self start]; else [self releaseAll]; }
- (void)inactive { [self releaseAll]; }
- (void)controllerDisconnected:(NSNotification *)notification {
    __weak SPTouchControls *weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weak start]; });
}
- (void)start {
    if (!self.window || ![_config[@"enabled"] boolValue] || _virtualController.controller || _connecting) return;
    if (!_virtualController) {
        GCVirtualControllerConfiguration *c = [[GCVirtualControllerConfiguration alloc] init];
        c.hidden = YES;
        NSMutableSet *elements = [NSMutableSet setWithArray:sp_touch_gamepad_buttons().allValues];
        [elements addObjectsFromArray:@[GCInputLeftThumbstick, GCInputRightThumbstick]];
        c.elements = elements;
        _virtualController = [[GCVirtualController alloc] initWithConfiguration:c];
    }
    _connecting = YES;
    __weak SPTouchControls *weak = self;
    [_virtualController connectWithReplyHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPTouchControls *me = weak;
            if (!me) return;
            me->_connecting = NO;
            if (![me->_config[@"enabled"] boolValue]) { [me->_virtualController disconnect]; return; }
            me->_status.hidden = !error;
            me->_status.text = error ? @"Touch controller unavailable. Open Controls to retry." : nil;
            // A finger held during the asynchronous connection must start neutral, never stuck.
            [me releaseAll];
        });
    }];
}
- (void)reload {
    [self releaseAll];
    _config = sp_touch_load();
    for (UIView *b in _buttons) [b removeFromSuperview];
    [_buttons removeAllObjects];
    BOOL enabled = [_config[@"enabled"] boolValue];
    __weak SPTouchControls *weak = self;
    for (NSDictionary *binding in _config[@"buttons"]) {
        SPTouchButton *button = [[SPTouchButton alloc] initWithFrame:CGRectZero];
        button.binding = binding;
        NSString *symbol = [binding[@"label"] isEqual:@"▧"] ? @"rectangle.on.rectangle" :
                           [binding[@"label"] isEqual:@"☰"] ? @"line.3.horizontal" : nil;
        if ([binding[@"action"] isEqual:@"Keyboard"] && [binding[@"label"] isEqual:@"Keyboard"]) symbol = @"keyboard";
        if ([binding[@"action"] isEqual:@"Controls"] && [binding[@"label"] isEqual:@"Controls"]) symbol = @"slider.horizontal.3";
        if (symbol) {
            button.cutoutIcon = [UIImage systemImageNamed:symbol withConfiguration:
                [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
        }
        button.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@", binding[@"label"], binding[@"action"], binding[@"mode"]];
        button.pressed = ^(SPTouchButton *b, NSInteger phase) { [weak button:b phase:phase]; };
        button.moved = ^(SPTouchButton *b, UIPanGestureRecognizer *pan) { [weak moveButton:b pan:pan]; };
        button.hidden = !enabled && !_arranging;
        button.pan.enabled = _arranging;
        [self addSubview:button]; [_buttons addObject:button];
    }
    if (!_finish) {
        _finish = [UIButton buttonWithType:UIButtonTypeSystem];
        [_finish setTitle:@"Done Arranging" forState:UIControlStateNormal];
        _finish.backgroundColor = UIColor.secondarySystemBackgroundColor;
        _finish.layer.cornerRadius = 12;
        [_finish addTarget:self action:@selector(finishArranging) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_finish];
        _layoutHint = [[UILabel alloc] init];
        _layoutHint.text = @"Drag buttons to place them";
        _layoutHint.textColor = UIColor.whiteColor; _layoutHint.textAlignment = NSTextAlignmentCenter;
        _layoutHint.font = [UIFont systemFontOfSize:13]; [self addSubview:_layoutHint];
        _status = [[UILabel alloc] init];
        _status.textColor = UIColor.whiteColor; _status.backgroundColor = [UIColor colorWithWhite:0 alpha:.7];
        _status.textAlignment = NSTextAlignmentCenter; _status.font = [UIFont systemFontOfSize:12];
        _status.hidden = YES; [self addSubview:_status];
    }
    _finish.hidden = _layoutHint.hidden = !_arranging;
    [self bringSubviewToFront:_finish]; [self bringSubviewToFront:_layoutHint];
    if (!enabled) { [_virtualController disconnect]; _status.hidden = YES; }
    else [self start];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat size = [_config[@"size"] doubleValue];
    for (SPTouchButton *b in _buttons) {
        CGSize target = CGSizeMake(fmax(44, size), fmax(44, size * .55));
        b.frame = (CGRect){CGPointZero, target};
        b.center = CGPointMake(target.width / 2 + [b.binding[@"x"] doubleValue] * fmax(0, self.bounds.size.width - target.width),
                               target.height / 2 + [b.binding[@"y"] doubleValue] * fmax(0, self.bounds.size.height - target.height));
        BOOL active = NO;
        for (NSDictionary *held in _held.allValues) if ([held[@"id"] isEqual:b.binding[@"id"]]) { active = YES; break; }
        b.pillWidth = size;
        b.latched = active;
        b.alpha = [_config[@"buttonOpacity"] doubleValue];
        b.accessibilityValue = active ? @"Held" : @"Released";
        [b setNeedsDisplay];
    }
    _finish.frame = CGRectMake(self.bounds.size.width / 2 - 85, self.bounds.size.height / 2 - 24, 170, 48);
    _layoutHint.frame = CGRectMake(self.bounds.size.width / 2 - 140, CGRectGetMaxY(_finish.frame) + 8, 280, 24);
    _status.frame = CGRectMake(30, self.bounds.size.height - 28, fmax(0, self.bounds.size.width - 60), 24);
}
- (void)setArranging:(BOOL)value {
    [self releaseAll]; _arranging = value;
    for (SPTouchButton *b in _buttons) { b.pan.enabled = value; b.hidden = !value && ![_config[@"enabled"] boolValue]; }
    _finish.hidden = _layoutHint.hidden = !value;
    [self setNeedsDisplay]; [self setNeedsLayout];
}
- (void)finishArranging { self.arranging = NO; if (_arranged) _arranged(); }
- (void)moveButton:(SPTouchButton *)button pan:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self];
    CGSize size = button.bounds.size;
    CGPoint p = CGPointMake(button.center.x + delta.x, button.center.y + delta.y);
    p.x = fmax(size.width / 2, fmin(self.bounds.size.width - size.width / 2, p.x));
    p.y = fmax(size.height / 2, fmin(self.bounds.size.height - size.height / 2, p.y));
    button.center = p; [pan setTranslation:CGPointZero inView:self];
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        NSMutableDictionary *c = sp_touch_load();
        for (NSMutableDictionary *b in c[@"buttons"]) if ([b[@"id"] isEqual:button.binding[@"id"]]) {
            b[@"x"] = @((p.x - size.width / 2) / fmax(1, self.bounds.size.width - size.width));
            b[@"y"] = @((p.y - size.height / 2) / fmax(1, self.bounds.size.height - size.height));
        }
        sp_touch_save(c);
    }
}

// Each source owns its binding. Shared modifiers/buttons stay held until their last owner releases.
- (void)action:(NSDictionary *)binding owner:(NSString *)owner down:(BOOL)down at:(CGPoint)point {
    if (down) _held[owner] = binding; else [_held removeObjectForKey:owner];
    NSMutableSet *keys = [NSMutableSet set], *pad = [NSMutableSet set], *mouse = [NSMutableSet set];
    for (NSDictionary *b in _held.allValues) {
        NSString *action = b[@"action"];
        if ([action isEqual:@"Key combo"]) [keys addObjectsFromArray:sp_touch_combo(b[@"combo"])];
        NSString *element = sp_touch_gamepad_buttons()[action]; if (element) [pad addObject:element];
        if ([action isEqual:@"Left click"]) [mouse addObject:@0];
        if ([action isEqual:@"Right click"]) [mouse addObject:@1];
    }
    // Ordinary keys release before modifiers; modifiers press before ordinary keys.
    NSArray *released = [[_keys allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *pressed = [[[keys allObjects] sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator].allObjects;
    for (NSNumber *key in released) if (![keys containsObject:key] && _keyEvent) _keyEvent(key.unsignedIntegerValue, NO);
    for (NSNumber *key in pressed) if (![_keys containsObject:key] && _keyEvent) _keyEvent(key.unsignedIntegerValue, YES);
    for (NSString *b in _padButtons) if (![pad containsObject:b]) [_virtualController setValue:0 forButtonElement:b];
    for (NSString *b in pad) if (![_padButtons containsObject:b]) [_virtualController setValue:1 forButtonElement:b];
    for (NSNumber *b in _mouseButtons) if (![mouse containsObject:b] && _mouseEvent) _mouseEvent(b.integerValue, NO, point);
    for (NSNumber *b in mouse) if (![_mouseButtons containsObject:b] && _mouseEvent) _mouseEvent(b.integerValue, YES, point);
    _keys = keys; _padButtons = pad; _mouseButtons = mouse;
    [self setNeedsLayout];
}
- (void)button:(SPTouchButton *)button phase:(NSInteger)phase {
    if (_arranging) return;
    NSDictionary *b = button.binding; NSString *owner = b[@"id"], *mode = b[@"mode"], *action = b[@"action"];
    if ([action isEqual:@"Keyboard"] || [action isEqual:@"Controls"]) {
        if (phase == 1) {
            [self releaseAll];
            if ([action isEqual:@"Keyboard"]) { if (_keyboard) _keyboard(); }
            else if (_settings) _settings();
        }
        return;
    }
    CGPoint pointer = CGPointMake(NAN, NAN);
    if ([mode isEqual:@"Hold"]) [self action:b owner:owner down:phase == 0 at:pointer];
    else if (phase == 1 && [mode isEqual:@"Toggle"]) [self action:b owner:owner down:!_held[owner] at:pointer];
    else if (phase == 1) {
        NSString *pulse = NSUUID.UUID.UUIDString;
        [self action:b owner:pulse down:YES at:pointer];
        __weak SPTouchControls *weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (weak) [weak action:b owner:pulse down:NO at:CGPointMake(NAN, NAN)];
        });
    }
}
- (void)axis:(SPTouchContact *)contact value:(CGPoint)value {
    [_virtualController setPosition:value forDirectionPadElement:contact.side ? GCInputRightThumbstick : GCInputLeftThumbstick];
}
- (BOOL)mouseOwned {
    if (_pair.mode) return YES;
    for (SPTouchContact *c in _contacts.objectEnumerator)
        if (c.state == SPTouchRightDrag || c.state == SPTouchLeftDrag) return YES;
    return NO;
}
- (void)finishPairCancelled:(BOOL)cancelled {
    SPTouchPair *pair = _pair;
    if (!pair) return;
    if (pair.mode == 1) [self action:@{} owner:pair.owner down:NO at:CGPointMake(NAN, NAN)];
    else if (pair.mode == 2) { if (_scrollEvent) _scrollEvent(0, pair.first.origin, 8); }
    else if (!cancelled && [_config[@"twoFingerTap"] boolValue] &&
             NSProcessInfo.processInfo.systemUptime - pair.first.began <= .4) {
        [self action:@{@"action": @"Right click"} owner:pair.owner down:YES at:pair.first.origin];
        [self action:@{} owner:pair.owner down:NO at:pair.first.origin];
    }
    pair.first.state = pair.second.state = SPTouchIgnored;
    _lastTapTime[0] = _lastTapTime[1] = 0;
    _pair = nil;
}
- (void)releaseAll {
    [self finishPairCancelled:YES];
    [_contacts removeAllObjects]; _four = NO;
    _lastTapTime[0] = _lastTapTime[1] = 0;
    [_held removeAllObjects];
    [self action:@{} owner:@"release" down:NO at:CGPointMake(NAN, NAN)];
    [_virtualController setPosition:CGPointZero forDirectionPadElement:GCInputLeftThumbstick];
    [_virtualController setPosition:CGPointZero forDirectionPadElement:GCInputRightThumbstick];
    [self setNeedsDisplay];
}
- (void)beginPair {
    if (_pair || _four || _arranging || [self mouseOwned]) return;
    if (![_config[@"pinch"] boolValue] && ![_config[@"twoFingerTap"] boolValue] &&
        [_config[@"twoFingerDrag"] isEqual:@"Off"]) return;
    NSArray<SPTouchContact *> *pending = [[_contacts.objectEnumerator.allObjects
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPTouchContact *c, NSDictionary *b) {
            return c.state == SPTouchPending;
        }]] sortedArrayUsingComparator:^NSComparisonResult(SPTouchContact *a, SPTouchContact *b) {
            return a.began < b.began ? NSOrderedAscending : a.began > b.began ? NSOrderedDescending : NSOrderedSame;
        }];
    for (SPTouchContact *first in pending) {
        BOOL occupied = NO;
        for (SPTouchContact *c in _contacts.objectEnumerator)
            if (c.side == first.side && c.state == SPTouchStick) occupied = YES;
        if (occupied) continue;
        for (SPTouchContact *second in pending) {
            if (second == first || second.side != first.side) continue;
            CGFloat distance = hypot(second.point.x - first.point.x, second.point.y - first.point.y);
            if (distance < 18) continue;
            _pair = [[SPTouchPair alloc] init];
            _pair.first = first; _pair.second = second;
            _pair.startFirst = first.point; _pair.startSecond = second.point;
            _pair.distance = _pair.lastDistance = distance;
            _pair.owner = NSUUID.UUID.UUIDString;
            first.state = second.state = SPTouchPaired;
            first.doubleTap = second.doubleTap = NO;
            return;
        }
    }
}
- (void)movePairAllowStationary:(BOOL)allowStationary {
    SPTouchPair *p = _pair;
    CGPoint a = CGPointMake(p.first.point.x - p.startFirst.x, p.first.point.y - p.startFirst.y);
    CGPoint b = CGPointMake(p.second.point.x - p.startSecond.x, p.second.point.y - p.startSecond.y);
    CGFloat pan = hypot((a.x + b.x) / 2, (a.y + b.y) / 2);
    CGFloat distance = hypot(p.second.point.x - p.first.point.x, p.second.point.y - p.first.point.y);
    if (!p.mode) {
        // Fingers in a parallel pan can report their first movement on adjacent frames. Give the
        // second one 50 ms before interpreting a moving finger + stationary finger as a pinch.
        if (!allowStationary && (hypot(a.x, a.y) <= 3 || hypot(b.x, b.y) <= 3)) {
            if (!p.waitingForSecond) {
                p.waitingForSecond = YES;
                __weak SPTouchControls *weak = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    SPTouchControls *me = weak;
                    if (me && me->_pair == p && !p.mode) [me movePairAllowStationary:YES];
                });
            }
            return;
        }
        CGFloat pinch = fabs(distance - p.distance);
        if ([_config[@"pinch"] boolValue] && pinch > 10 && pinch > pan * 1.5) {
            p.mode = 2;
            if (_scrollEvent) _scrollEvent(0, p.first.origin, 1);
        } else if (![_config[@"twoFingerDrag"] isEqual:@"Off"] && pan > 8 &&
                   hypot(a.x, a.y) > 3 && hypot(b.x, b.y) > 3 && a.x * b.x + a.y * b.y > 0) {
            p.mode = 1;
            NSString *action = [_config[@"twoFingerDrag"] isEqual:@"Turn Character"] ? @"Right click" : @"Left click";
            [self action:@{@"action": action} owner:p.owner down:YES at:p.first.origin];
        }
    }
    if (p.mode == 1 && _mouseMove) _mouseMove(p.first.point);
    if (p.mode == 2 && distance > 1 && _scrollEvent) {
        CGFloat delta = log(distance / p.lastDistance) * [_config[@"zoomSpeed"] doubleValue];
        if (fabs(delta) > .0001) _scrollEvent(delta, p.first.origin, 4);
        p.lastDistance = distance;
    }
}

// Returned touches are the ones the overlay owns; pointer and pencil events stay in spevent.m.
- (NSSet<UITouch *> *)route:(NSSet<UITouch *> *)touches phase:(NSInteger)phase inView:(UIView *)view {
    NSMutableSet *handled = [NSMutableSet set], *changed = [NSMutableSet set];
    // Read the whole frame before classifying motion: updating one finger and recognizing it before
    // reading the other would mistake a parallel two-finger drag for a pinch.
    for (UITouch *touch in touches) {
        if (!sp_finger(touch)) continue;
        SPTouchContact *c = [_contacts objectForKey:touch];
        if (!c && (phase != 0 || (![_config[@"enabled"] boolValue] && !_arranging))) continue;
        [handled addObject:touch];
        CGPoint point = [view convertPoint:[touch locationInView:view] toView:self];
        if (phase == 0) {
            if (_four) _fourInvalid = YES;
            c = [[SPTouchContact alloc] init]; c.origin = c.point = point;
            c.began = touch.timestamp; c.owner = NSUUID.UUID.UUIDString;
            c.side = point.x >= self.bounds.size.width / 2;
            c.state = _arranging || _four ? SPTouchIgnored : SPTouchPending;
            c.doubleTap = [_config[@"doubleTapDrag"] boolValue] && _lastTapTime[c.side] > 0 &&
                c.began - _lastTapTime[c.side] >= 0 && c.began - _lastTapTime[c.side] < .3 &&
                hypot(point.x - _lastTapPoint[c.side].x, point.y - _lastTapPoint[c.side].y) < 24;
            [_contacts setObject:c forKey:touch];
            SPTouchContact *contact = c;
            __weak SPTouchControls *weak = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([_config[@"holdTime"] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPTouchControls *me = weak;
                if (!me || [me->_contacts objectForKey:touch] != contact || contact.state != SPTouchPending ||
                    me->_four || me->_arranging || [me mouseOwned] ||
                    (!contact.doubleTap && ![me->_config[@"longPress"] boolValue])) return;
                contact.state = contact.doubleTap ? SPTouchLeftDrag : SPTouchRightDrag;
                [me action:@{@"action": contact.doubleTap ? @"Left click" : @"Right click"}
                    owner:contact.owner down:YES at:contact.origin];
                me->_lastTapTime[contact.side] = 0;
                [me setNeedsDisplay];
            });
        } else c.point = point;
        [changed addObject:c];
    }
    if (phase == 0 && _contacts.count >= 4) {
        NSTimeInterval first = DBL_MAX, last = 0; BOOL candidates = YES;
        for (SPTouchContact *c in _contacts.objectEnumerator) {
            first = fmin(first, c.began); last = fmax(last, c.began);
            candidates &= c.state == SPTouchPending || c.state == SPTouchIgnored ||
                          (c.state == SPTouchPaired && !_pair.mode);
        }
        if (candidates && last - first <= .12) {
            if (!_four) { _four = YES; _fourBegan = first; _fourInvalid = NO; }
            if (_contacts.count != 4) _fourInvalid = YES;
            [self finishPairCancelled:YES];
            for (SPTouchContact *c in _contacts.objectEnumerator) c.state = SPTouchIgnored;
        } else if (_four) _fourInvalid = YES;
    }
    if (phase == 0) [self beginPair];
    BOOL pairChanged = _pair && ([changed containsObject:_pair.first] || [changed containsObject:_pair.second]);
    if (pairChanged && (phase == 1 || phase == 2)) [self movePairAllowStationary:phase == 2];
    if (pairChanged && phase >= 2) {
        CGFloat a = hypot(_pair.first.point.x - _pair.startFirst.x, _pair.first.point.y - _pair.startFirst.y);
        CGFloat b = hypot(_pair.second.point.x - _pair.startSecond.x, _pair.second.point.y - _pair.startSecond.y);
        [self finishPairCancelled:phase == 3 || (!_pair.mode && (a > 10 || b > 10))];
    }
    for (SPTouchContact *c in changed) {
        CGFloat distance = hypot(c.point.x - c.origin.x, c.point.y - c.origin.y);
        if (_four) { if (distance > 20 || phase == 3) _fourInvalid = YES; }
        else if (phase == 1 && c.state != SPTouchPaired) {
            if (c.state == SPTouchPending && distance > 10) {
                BOOL stick = [_config[c.side ? @"right" : @"left"] boolValue], occupied = NO;
                for (SPTouchContact *other in _contacts.objectEnumerator)
                    if (other != c && other.side == c.side && other.state == SPTouchStick) occupied = YES;
                BOOL mouse = c.doubleTap || !stick;
                c.state = occupied || (mouse && [self mouseOwned]) ? SPTouchIgnored :
                          mouse ? SPTouchLeftDrag : SPTouchStick;
                if (c.state == SPTouchLeftDrag) [self action:@{@"action": @"Left click"} owner:c.owner down:YES at:c.origin];
                _lastTapTime[c.side] = 0;
            }
            if (c.state == SPTouchStick) [self axis:c value:sp_touch_axis(CGPointMake(c.point.x - c.origin.x,
                c.point.y - c.origin.y), [_config[@"radius"] doubleValue], [_config[@"deadzone"] doubleValue])];
            if ((c.state == SPTouchRightDrag || c.state == SPTouchLeftDrag) && _mouseMove) _mouseMove(c.point);
        } else if (phase >= 2) {
            if (c.state == SPTouchStick) [self axis:c value:CGPointZero];
            if (c.state == SPTouchRightDrag || c.state == SPTouchLeftDrag) {
                if (_mouseMove) _mouseMove(c.point);
                [self action:@{} owner:c.owner down:NO at:c.point];
            }
            if (c.state == SPTouchPending && phase == 2 && !_arranging && !pairChanged && ![self mouseOwned]) {
                [self action:@{@"action": @"Left click"} owner:c.owner down:YES at:c.point];
                [self action:@{} owner:c.owner down:NO at:c.point];
                _lastTapTime[c.side] = NSProcessInfo.processInfo.systemUptime;
                _lastTapPoint[c.side] = c.point;
            }
        }
        if (phase == 3) _lastTapTime[c.side] = 0;
    }
    if (phase >= 2) for (UITouch *touch in handled) [_contacts removeObjectForKey:touch];
    if (_four && !_contacts.count) {
        BOOL tap = !_fourInvalid && NSProcessInfo.processInfo.systemUptime - _fourBegan <= .4;
        _four = NO; if (tap && _keyboard) _keyboard();
    }
    [self setNeedsDisplay];
    return handled;
}
- (void)drawRect:(CGRect)rect {
    if (_arranging) {
        [[UIColor colorWithWhite:0 alpha:.25] setFill]; UIRectFill(self.bounds);
        return;
    }
    CGFloat radius = [_config[@"radius"] doubleValue], alpha = [_config[@"opacity"] doubleValue];
    for (SPTouchContact *c in _contacts.objectEnumerator) {
        if (c.state != 1) continue;
        CGPoint delta = CGPointMake(c.point.x - c.origin.x, c.point.y - c.origin.y);
        CGFloat length = hypot(delta.x, delta.y), limit = fmin(1, radius / fmax(1, length));
        CGPoint thumb = CGPointMake(c.origin.x + delta.x * limit, c.origin.y + delta.y * limit);
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.origin.x - radius, c.origin.y - radius, radius * 2, radius * 2)];
        [[UIColor colorWithWhite:0 alpha:alpha * .18] setFill]; [ring fill];
        [[UIColor colorWithWhite:1 alpha:alpha * .65] setStroke]; ring.lineWidth = 1; [ring stroke];
        UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(thumb.x - 17, thumb.y - 17, 34, 34)];
        [[UIColor colorWithWhite:1 alpha:alpha * .45] setFill]; [dot fill];
        [[UIColor colorWithWhite:1 alpha:alpha] setStroke]; dot.lineWidth = 1; [dot stroke];
    }
}
@end
