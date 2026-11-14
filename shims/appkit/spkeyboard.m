// The on-screen keyboard (iPhone and iPad): the system keyboard, typing into the game as key presses, the
// way a hardware keyboard's do. #included at the end of the generated libspAppKit.m (gen_stubs.py
// EXTRA_INCLUDES), after spevent.m, whose event queue it posts to and whose input view hosts it, and
// sphover.m, which reads the SPKeyboard addon's strip.
//
// When it comes up: in game, when one of the game's text boxes gains focus (the SPKeyboard addon says
// which and where, addon/SPKeyboard; tapping chat's Say, or Return), and it closes when the box loses
// focus (Return sent the line, Escape), so letters never go to the game's key bindings unasked. The touch
// edit menu's Keyboard (spevent.m) brings it up for the focused box, presses Return to open chat when no
// box has focus, and on the login and character screens, where addons don't run, brings it up for the
// spot the menu was opened at; there only the bar's Done closes it. Done closes it anywhere.
//
// The keyboard belongs to a hidden view of its own (SPKeyboardView), not the input view: a view that takes
// text and is first responder brings the keyboard up whenever there's no hardware keyboard, and the input
// view is first responder for the whole game. The hidden view is first responder only while the keyboard
// is up.
//
// It's a full UITextInput over a hidden buffer, not the bare UIKeyInput a key-per-letter keyboard needs:
// the keyboard's dictation key (the mic) is only offered to a full text input. The app never asks for the
// microphone itself (no NSMicrophoneUsageDescription, no SFSpeechRecognizer), so an audio-input request
// from the game still fails closed. The buffer holds what was typed since the keyboard came up, the last
// Return, or the last touch on the game; after each change the game gets Backspaces back to where the
// buffer and what it was sent first differ, then the new text as key presses. So whatever the keyboard
// does to the buffer (a key, autocorrect replacing a word, dictation revising a phrase, the space bar's
// trackpad moving the caret) ends with the game's box holding the same text, as long as its caret was at
// the end, which a touch keyboard can't move. Composing languages (Japanese, Chinese, Korean) keep their
// marked text in the buffer and reach the game when it's committed; drawing it as it's composed would
// need the game view's own setMarkedText:.
//
// On an iPhone the keyboard covers most of the game, so while it's up the game is magnified onto the box
// (or the menu's spot) and placed above the keyboard. The zoom is the input view's own transform, so UIKit
// maps touches through it: a touch lands where the game under it is drawn. An iPad's keyboard can float or
// split, so it gets no zoom.
//
// Nothing here logs what's typed or dictated, or how much: chat, the authenticator code, and a password
// can all go through it. The key presses go to the queue unlogged (sp_post_quiet), and the log says only
// that the keyboard came up or closed, where the focused box is and the zoom went, and that dictation
// started or ended. The buffer is emptied at every Return, at Done, and when the game is touched.

#if !TARGET_OS_VISION
static void sp_keyboard_say(NSString *s) {
    static int logged;
    if (logged++ >= 200) return;
    os_log(OS_LOG_DEFAULT, "[sp:AppKit] keyboard: %{public}s", s.UTF8String);
    fprintf(stderr, "[sp:AppKit] keyboard: %s\n", s.UTF8String);
}

// ---- typing: characters to key presses
//
// A US key for each ASCII character it types, as the game's bindings know them; the character itself
// rides in the event, so the game's text is what was typed whatever key it names. No Shift goes with a
// capital or a symbol: the game's text comes from the characters, and a capital the keyboard made on its
// own (the start of a sentence) shouldn't turn a binding into its Shift one.
static const char sp_kb_plain[] = "`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./ ";
static const char sp_kb_shifted[] = "~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>? ";
static const uint8_t sp_kb_codes[] = {
    0x32, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D, 0x1B, 0x18,  // ` 1-0 - =
    0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23, 0x21, 0x1E, 0x2A,  // q-p [ ] backslash
    0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25, 0x29, 0x27,              // a-l ; '
    0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E, 0x2B, 0x2F, 0x2C, 0x31,              // z-m , . / space
};
_Static_assert(sizeof sp_kb_plain - 1 == sizeof sp_kb_codes && sizeof sp_kb_shifted - 1 == sizeof sp_kb_codes,
               "one key code per character");

// A character no US key types (é, an emoji, a CJK one) goes on a key code no Mac keyboard has, so it can't
// press a binding: the game takes its text from the characters, as it does a French keyboard's é.
static const unsigned short sp_kb_no_key = 0x6C;

static unsigned short sp_kb_code(NSString *ch) {
    if (ch.length != 1) return sp_kb_no_key;
    unichar c = [ch characterAtIndex:0];
    if (c == 0 || c > 0x7E) return sp_kb_no_key;
    const char *p = strchr(sp_kb_plain, c), *q = strchr(sp_kb_shifted, c);
    return p ? sp_kb_codes[p - sp_kb_plain] : q ? sp_kb_codes[q - sp_kb_shifted] : sp_kb_no_key;
}

// The presses go out one at a time, each key up 30 ms after its down and the next key's down with it, as
// a fast typist's would: a down and its up in the same pump could reach a game that reads key state once
// a frame as nothing (sptouchpad.m), and keys that overlap could read as a key held. A dictated phrase is
// typed at about 33 characters a second.
static NSMutableArray<SPEvent *> *sp_kb_pending;  // key downs waiting
static SPEvent *sp_kb_down;                       // the key down now; its up is the next tick's

static void sp_kb_tick(void) {
    if (sp_kb_down) {
        SPEvent *up = sp_event(SPKeyUp);
        up->keyCode = sp_kb_down->keyCode;
        up->characters = sp_kb_down->characters;
        up->charactersIgnoringModifiers = sp_kb_down->charactersIgnoringModifiers;
        up->modifierFlags |= sp_kb_down->modifierFlags & SPFunction;
        sp_post_quiet(up);
        sp_kb_down = nil;
    }
    if (!sp_kb_pending.count) return;
    SPEvent *down = sp_kb_pending.firstObject;
    [sp_kb_pending removeObjectAtIndex:0];
    down->timestamp = NSProcessInfo.processInfo.systemUptime;
    down->location = sp_mouse;
    sp_post_quiet(down);
    sp_kb_down = down;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ sp_kb_tick(); });
}

static void sp_kb_press(unsigned short mac, NSString *chars) {
    SPEvent *e = sp_event(SPKeyDown);
    e->modifierFlags &= ~(NSUInteger)(SPShift | SPControl | SPOption | SPCommand);
    e->keyCode = mac;
    e->characters = e->charactersIgnoringModifiers = chars;
    if (sp_function_char(mac) >= 0xF700) e->modifierFlags |= SPFunction;
    if (!sp_kb_pending) sp_kb_pending = [NSMutableArray array];
    [sp_kb_pending addObject:e];
    if (!sp_kb_down) sp_kb_tick();
}

static void sp_kb_backspace(void) {
    unichar c = 0x7F;
    sp_kb_press(0x33, [NSString stringWithCharacters:&c length:1]);
}

static void sp_kb_return(void) {
    sp_kb_press(0x24, @"\r");
}

// One press per character as the reader sees it (an emoji with its skin tone is one).
static void sp_kb_type(NSString *s) {
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        sp_kb_press(sp_kb_code(ch), ch);
    }];
}

// Backspaces for the end of what was sent: one per Unicode scalar, as the game's box deletes.
static NSUInteger sp_kb_scalars(NSString *s) {
    return [s lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4;
}

// ---- the iPhone's zoom

static SPInputView *sp_kb_host;
static CGRect sp_kb_target;        // what's typed in: the focused box, or (no size) the menu's point;
                                   // UIKit, in the host (untransformed)
static CGRect sp_kb_frame;         // the keyboard's last frame, in the host's window; empty when hidden
static BOOL sp_kb_rotating;

static CGFloat sp_kb_zoom_scale(void) {
    static CGFloat s;
    if (!s) s = getenv("SP_KEYBOARD_ZOOM") ? atof(getenv("SP_KEYBOARD_ZOOM")) : 2;
    return s < 1 ? 1 : s;
}

static BOOL sp_kb_zooms(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone && sp_kb_zoom_scale() > 1;
}

// Scale s about the target's center P, as much as SP_KEYBOARD_ZOOM (2) but no more than fits the box's
// width across. P lands across where it was if it can; down, a box's bottom lands just above the
// keyboard, so the chat lines over the box stay in view, and the menu's point 60% down the space above
// it. Each is clamped so the magnified game still fills the window from the left edge to the right and
// from the top to the keyboard: no edge of it shows (a box at the very bottom sits on the keyboard).
static CGAffineTransform sp_kb_zoom_transform(void) {
    UIView *v = sp_kb_host;
    CGSize b = v.bounds.size;
    CGFloat above = CGRectIsEmpty(sp_kb_frame) ? b.height : MIN(b.height, CGRectGetMinY(sp_kb_frame));
    if (!sp_kb_zooms() || above >= b.height || above <= 0 || b.width <= 0) return CGAffineTransformIdentity;
    CGRect r = sp_kb_target;
    CGFloat s = MAX(1, MIN(sp_kb_zoom_scale(), b.width * 0.95 / MAX(r.size.width, 1)));
    CGFloat px = CGRectGetMidX(r), py = CGRectGetMidY(r);
    CGFloat want_y = r.size.height ? above - 6 - s * r.size.height / 2 : above * 0.6;
    CGFloat to_x = MAX(b.width - s * (b.width - px), MIN(s * px, b.width / 2));
    CGFloat to_y = MAX(above - s * (b.height - py), MIN(s * py, want_y));
    // A view's transform is about its center.
    CGFloat cx = b.width / 2, cy = b.height / 2;
    return CGAffineTransformMake(s, 0, 0, s, to_x - cx - s * (px - cx), to_y - cy - s * (py - cy));
}

static void sp_kb_apply_zoom(NSDictionary *info) {
    if (!sp_kb_host || sp_kb_rotating) return;
    CGAffineTransform t = sp_kb_zoom_transform();
    if (CGAffineTransformEqualToTransform(t, sp_kb_host.transform)) return;
    if (!CGAffineTransformIsIdentity(t))
        sp_keyboard_say([NSString stringWithFormat:@"zoomed %.2gx onto %.0f,%.0f %.0fx%.0f, the keyboard's top at %.0f", t.a,
                         sp_kb_target.origin.x, sp_kb_target.origin.y, sp_kb_target.size.width,
                         sp_kb_target.size.height, CGRectGetMinY(sp_kb_frame)]);
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions curve = [info[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:duration delay:0
                        options:curve | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ sp_kb_host.transform = t; } completion:nil];
}

// The window sets its root view's frame as it turns, which a transform would throw off: the zoom comes off
// for the turn and goes back on after (SPRootViewController).
static void sp_keyboard_rotation(BOOL starting) {
    if (!sp_kb_host) return;
    sp_kb_rotating = starting;
    if (starting) sp_kb_host.transform = CGAffineTransformIdentity;
    else sp_kb_apply_zoom(nil);
}

// ---- the hidden text input

@interface SPTextPosition : UITextPosition
@property (nonatomic) NSUInteger offset;
@end
@implementation SPTextPosition
@end

@interface SPTextRange : UITextRange
@property (nonatomic) NSRange range;
@end
@implementation SPTextRange
- (UITextPosition *)start {
    SPTextPosition *p = [[SPTextPosition alloc] init];
    p.offset = self.range.location;
    return p;
}
- (UITextPosition *)end {
    SPTextPosition *p = [[SPTextPosition alloc] init];
    p.offset = NSMaxRange(self.range);
    return p;
}
- (BOOL)isEmpty {
    return self.range.length == 0;
}
@end

static SPTextRange *sp_kb_range(NSRange r) {
    SPTextRange *t = [[SPTextRange alloc] init];
    t.range = r;
    return t;
}

@interface SPKeyboardView : UIView <UITextInput>
@end

static SPKeyboardView *sp_kb_view;

@implementation SPKeyboardView {
    NSMutableString *_text;  // the buffer
    NSRange _sel;
    NSRange _marked;         // location NSNotFound when there's none
    NSString *_sent;         // what the game was sent since the buffer was last emptied
    UIView *_bar;
    UITextInputStringTokenizer *_tokenizer;
}
@synthesize inputDelegate, markedTextStyle;

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _text = [NSMutableString string];
    _marked = NSMakeRange(NSNotFound, 0);
    _sent = @"";
    [self sp_make_bar];
    [NSNotificationCenter.defaultCenter addObserverForName:UITextInputCurrentInputModeDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!self.isFirstResponder) return;
        static BOOL dictating;
        BOOL now = [self.textInputMode.primaryLanguage isEqualToString:@"dictation"];
        if (now != dictating) sp_keyboard_say(now ? @"dictation started" : @"dictation ended");
        dictating = now;
    }];
    return self;
}

// Touches pass through to the game: this view is only a first responder.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

// No three-finger editing gestures here either: a three-finger press is the middle button.
- (UIEditingInteractionConfiguration)editingInteractionConfiguration {
    return UIEditingInteractionConfigurationNone;
}

- (UIView *)inputAccessoryView {
    return _bar;
}

// The bar over the keyboard: Done, the one way to close it. A plain button on a plain view, not a
// toolbar's Done: pressing a Liquid Glass bar button (its flex interaction) switches UIKit's touch
// delivery to the frame-paced update cycle (UpdateCycle's driver, the scheduler's "waiting main inputs"
// step), and under the shared main thread (spuikit.m) that step waits out a backup timer, ~20 s on iOS
// 27.2.1, before it dispatches anything: the press's lift and every touch after it, app-wide. A plain
// UIButton's touches take the ordinary path (iPhone 16 Pro: each Done in under 30 ms).
- (void)sp_make_bar {
    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    _bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _bar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    UIButtonConfiguration *c = [UIButtonConfiguration plainButtonConfiguration];
    c.title = @"Done";
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = [a mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        return m;
    };
    UIButton *done = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [done addTarget:self action:@selector(sp_done) forControlEvents:UIControlEventPrimaryActionTriggered];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [_bar addSubview:done];
    [NSLayoutConstraint activateConstraints:@[
        [done.trailingAnchor constraintEqualToAnchor:_bar.layoutMarginsGuide.trailingAnchor],
        [done.centerYAnchor constraintEqualToAnchor:_bar.centerYAnchor],
    ]];
}

- (void)sp_done {
    sp_keyboard_say(@"Done");
    [self resignFirstResponder];
}

- (BOOL)resignFirstResponder {
    if (![super resignFirstResponder]) return NO;
    sp_keyboard_say(@"closed");
    [self sp_forget];
    // Hardware keys need the input view to be first responder again, unless a launcher screen took over
    // (it hands the input view back itself when it's done).
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sp_window.rootViewController.presentedViewController && !self.isFirstResponder)
            [sp_kb_host becomeFirstResponder];
    });
    return YES;
}

// Empties the buffer, telling the keyboard (its autocorrect and capitals read the text before the caret):
// the game's box has changed under it, or what was typed is done with.
- (void)sp_forget {
    if (!_text.length && _marked.location == NSNotFound) {
        _sent = @"";
        return;
    }
    [self.inputDelegate selectionWillChange:self];
    [self.inputDelegate textWillChange:self];
    [_text setString:@""];
    _sel = NSMakeRange(0, 0);
    _marked = NSMakeRange(NSNotFound, 0);
    _sent = @"";
    [self.inputDelegate textDidChange:self];
    [self.inputDelegate selectionDidChange:self];
}

// The buffer less the text still being composed.
- (NSString *)sp_committed {
    if (_marked.location == NSNotFound) return [_text copy];
    NSMutableString *s = [_text mutableCopy];
    [s deleteCharactersInRange:_marked];
    return s;
}

// Brings the game's box to the buffer: Backspaces back to where they first differ (at a character's start
// in both), then the rest typed. A line break is a Return: what's before it is sent, then Return, and the
// buffer starts again with what's after it.
- (void)sp_sync {
    NSString *now = [self sp_committed];
    NSRange nl = [now rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    NSString *line = nl.location == NSNotFound ? now : [now substringToIndex:nl.location];
    NSUInteger p = 0, n = MIN(line.length, _sent.length);
    while (p < n && [line characterAtIndex:p] == [_sent characterAtIndex:p]) p++;
    if (p < _sent.length) p = MIN(p, [_sent rangeOfComposedCharacterSequenceAtIndex:p].location);
    if (p < line.length) p = MIN(p, [line rangeOfComposedCharacterSequenceAtIndex:p].location);
    for (NSUInteger i = sp_kb_scalars([_sent substringFromIndex:p]); i > 0; i--) sp_kb_backspace();
    sp_kb_type([line substringFromIndex:p]);
    _sent = line;
    if (nl.location == NSNotFound) return;
    sp_kb_return();
    NSString *rest = [now substringFromIndex:NSMaxRange(nl)];
    [self sp_forget];
    if (!rest.length) return;
    [self.inputDelegate textWillChange:self];
    [_text setString:rest];
    _sel = NSMakeRange(rest.length, 0);
    [self.inputDelegate textDidChange:self];
    [self sp_sync];
}

static NSRange sp_kb_clamp(NSRange r, NSUInteger len) {
    NSUInteger loc = MIN(r.location, len);
    return NSMakeRange(loc, MIN(r.length, len - loc));
}

// Every edit is this: r replaced by s, the caret after it, the composition dropped if it's touched or
// moved along if it's after.
- (void)sp_replace:(NSRange)r with:(NSString *)s {
    r = sp_kb_clamp(r, _text.length);
    [_text replaceCharactersInRange:r withString:s];
    if (_marked.location != NSNotFound) {
        if (NSMaxRange(r) < _marked.location) _marked.location = _marked.location + s.length - r.length;
        else if (r.location <= NSMaxRange(_marked)) _marked = NSMakeRange(NSNotFound, 0);
    }
    _sel = NSMakeRange(r.location + s.length, 0);
}

// ---- UIKeyInput

// Yes even when the buffer is empty: the game's box may hold text from before it (a paste, the box's
// last line), and Backspace should reach it.
- (BOOL)hasText {
    return YES;
}

- (void)insertText:(NSString *)text {
    NSRange r = _marked.location != NSNotFound ? _marked : _sel;
    _marked = NSMakeRange(NSNotFound, 0);
    [self sp_replace:r with:text];
    [self sp_sync];
}

- (void)deleteBackward {
    NSRange r = _sel;
    if (!r.length) {
        if (!r.location) {
            sp_kb_backspace();  // past the buffer's start: the game's own text
            return;
        }
        r = [_text rangeOfComposedCharacterSequenceAtIndex:r.location - 1];
    }
    if (_marked.location != NSNotFound && NSLocationInRange(r.location, _marked)) {
        // Inside the composition: only it shrinks, and nothing goes to the game.
        [_text deleteCharactersInRange:r];
        _marked.length -= MIN(_marked.length, r.length);
        if (!_marked.length) _marked = NSMakeRange(NSNotFound, 0);
        _sel = NSMakeRange(r.location, 0);
        return;
    }
    [self sp_replace:r with:@""];
    [self sp_sync];
}

// ---- UITextInput

- (NSString *)textInRange:(UITextRange *)range {
    if (![range isKindOfClass:SPTextRange.class]) return nil;
    return [_text substringWithRange:sp_kb_clamp(((SPTextRange *)range).range, _text.length)];
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    if (![range isKindOfClass:SPTextRange.class]) return;
    [self sp_replace:((SPTextRange *)range).range with:text];
    [self sp_sync];
}

- (UITextRange *)selectedTextRange {
    return sp_kb_range(_sel);
}

- (void)setSelectedTextRange:(UITextRange *)range {
    if ([range isKindOfClass:SPTextRange.class]) _sel = sp_kb_clamp(((SPTextRange *)range).range, _text.length);
}

- (UITextRange *)markedTextRange {
    return _marked.location == NSNotFound ? nil : sp_kb_range(_marked);
}

- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)selected {
    NSRange r = _marked.location != NSNotFound ? _marked : _sel;
    r = sp_kb_clamp(r, _text.length);
    text = text ?: @"";
    [_text replaceCharactersInRange:r withString:text];
    _marked = text.length ? NSMakeRange(r.location, text.length) : NSMakeRange(NSNotFound, 0);
    selected = sp_kb_clamp(selected, text.length);
    _sel = NSMakeRange(r.location + selected.location, selected.length);
    [self sp_sync];  // the committed text didn't change unless the composition replaced some of it
}

- (void)unmarkText {
    if (_marked.location == NSNotFound) return;
    _sel = NSMakeRange(NSMaxRange(_marked), 0);
    _marked = NSMakeRange(NSNotFound, 0);
    [self sp_sync];
}

- (UITextPosition *)beginningOfDocument {
    SPTextPosition *p = [[SPTextPosition alloc] init];
    p.offset = 0;
    return p;
}

- (UITextPosition *)endOfDocument {
    SPTextPosition *p = [[SPTextPosition alloc] init];
    p.offset = _text.length;
    return p;
}

- (UITextRange *)textRangeFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)to {
    if (![from isKindOfClass:SPTextPosition.class] || ![to isKindOfClass:SPTextPosition.class]) return nil;
    NSUInteger a = ((SPTextPosition *)from).offset, b = ((SPTextPosition *)to).offset;
    return sp_kb_range(NSMakeRange(MIN(a, b), (a > b ? a - b : b - a)));
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    if (![position isKindOfClass:SPTextPosition.class]) return nil;
    NSInteger o = (NSInteger)((SPTextPosition *)position).offset + offset;
    if (o < 0 || o > (NSInteger)_text.length) return nil;
    SPTextPosition *p = [[SPTextPosition alloc] init];
    p.offset = o;
    return p;
}

// One line: up and down go nowhere.
- (UITextPosition *)positionFromPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction
                                  offset:(NSInteger)offset {
    if (direction == UITextLayoutDirectionLeft) return [self positionFromPosition:position offset:-offset];
    if (direction == UITextLayoutDirectionRight) return [self positionFromPosition:position offset:offset];
    return position;
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    NSUInteger a = ((SPTextPosition *)position).offset, b = ((SPTextPosition *)other).offset;
    return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)to {
    return (NSInteger)((SPTextPosition *)to).offset - (NSInteger)((SPTextPosition *)from).offset;
}

- (id<UITextInputTokenizer>)tokenizer {
    if (!_tokenizer) _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];
    return _tokenizer;
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction {
    return direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp ? range.start : range.end;
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position
                                       inDirection:(UITextLayoutDirection)direction {
    NSUInteger o = MIN(((SPTextPosition *)position).offset, _text.length);
    return direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp
               ? sp_kb_range(NSMakeRange(0, o)) : sp_kb_range(NSMakeRange(o, _text.length - o));
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position
                                          inDirection:(UITextStorageDirection)direction {
    return NSWritingDirectionNatural;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(UITextRange *)range {
}

// The text isn't drawn here: every rect is this view's, at the menu's point, so what the system draws by
// the caret (dictation's indicator, a composing candidate list) shows by the box being typed in.
- (CGRect)firstRectForRange:(UITextRange *)range {
    return self.bounds;
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    return self.bounds;
}

- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    return @[];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    return self.endOfDocument;
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    return range.end;
}

- (UITextRange *)characterRangeAtPoint:(CGPoint)point {
    return sp_kb_range(NSMakeRange(_text.length, 0));
}

- (UIView *)textInputView {
    return self;
}

- (void)dictationRecordingDidEnd {
    sp_keyboard_say(@"dictation recording ended");
}

- (void)dictationRecognitionFailed {
    sp_keyboard_say(@"dictation recognition failed");
}

// ---- UITextInputTraits
//
// The game's dark, with the keyboard's own help (autocorrect, capitals, predictions) as in any text field,
// but no curly quotes or long dashes, which game chat doesn't use and which no US key types. No inline
// predictions or Writing Tools: they draw over text this view doesn't draw.
- (UIKeyboardAppearance)keyboardAppearance {
    return UIKeyboardAppearanceDark;
}
- (UITextSmartQuotesType)smartQuotesType {
    return UITextSmartQuotesTypeNo;
}
- (UITextSmartDashesType)smartDashesType {
    return UITextSmartDashesTypeNo;
}
- (UITextInlinePredictionType)inlinePredictionType {
    return UITextInlinePredictionTypeNo;
}
- (UIWritingToolsBehavior)writingToolsBehavior {
    return UIWritingToolsBehaviorNone;
}
@end

// ---- for spevent.m

static BOOL sp_keyboard_up(void) {
    return sp_kb_view.isFirstResponder;
}

// A touch on the game, or the edit menu's Paste: the box being typed in may have changed, or another one
// have focus, so autocorrect mustn't reach back into it.
static void sp_keyboard_forget(void) {
    if (sp_keyboard_up()) [sp_kb_view sp_forget];
}

// target: the focused box, or (no size) the menu's point; UIKit, in the game's view. Again while it's up,
// for another box: the zoom moves to it, and the buffer starts over.
static void sp_keyboard_open(CGRect target) {
    SPInputView *host = (SPInputView *)sp_window.rootViewController.view;
    if (![host isKindOfClass:SPInputView.class]) return;
    if (!sp_kb_view) {
        sp_kb_view = [[SPKeyboardView alloc] initWithFrame:CGRectZero];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            if (!sp_keyboard_up() || !sp_kb_host.window) return;
            UIWindow *w = sp_kb_host.window;
            CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
            sp_kb_frame = [w convertRect:kb fromCoordinateSpace:w.windowScene.screen.coordinateSpace];
            sp_kb_apply_zoom(n.userInfo);
        }];
        [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            sp_kb_frame = CGRectZero;
            sp_kb_apply_zoom(n.userInfo);
        }];
        // A hardware keyboard types for itself, through the input view, so it closes this one.
        [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            if (sp_keyboard_up()) [sp_kb_view resignFirstResponder];
        }];
    }
    sp_kb_host = host;
    sp_kb_target = target;
    // Where the system draws by the caret (dictation's indicator, a composing candidate list).
    sp_kb_view.frame = target.size.width ? target : CGRectInset(target, -1, -10);
    if (sp_kb_view.superview != host) [host addSubview:sp_kb_view];
    if (sp_keyboard_up()) {
        [sp_kb_view sp_forget];
        sp_kb_apply_zoom(nil);
        return;
    }
    sp_keyboard_say(target.size.width ? @"shown for the focused box" : @"shown at the edit menu's point");
    [sp_kb_view becomeFirstResponder];
}

// ---- the focused box (the SPKeyboard addon's strip, sphover.m)

static BOOL sp_kb_focus_known;            // the strip is showing: in game, with the UI on
static CGRect sp_kb_focus = {{INFINITY, INFINITY}, {0, 0}};  // the focused box, UIKit; CGRectNull for none

// The edit menu's Keyboard: the focused box's keyboard; with none focused in game, Return, which opens
// the chat box, and the keyboard follows its focus; outside the game (the login and character screens,
// where addons don't run), the keyboard at the menu's point. at: UIKit, in the game's view.
static void sp_keyboard_menu(CGPoint at) {
    if (!CGRectIsNull(sp_kb_focus)) {
        sp_keyboard_open(sp_kb_focus);
    } else if (sp_kb_focus_known) {
        sp_keyboard_say(@"Keyboard with no box focused: Return");
        sp_kb_return();
    } else {
        sp_keyboard_open(CGRectMake(at.x, at.y, 0, 0));
    }
}

// From the strip, when it changes: known, whether the strip is showing; box, the focused box in fractions
// of the client's window (origin bottom left), or CGRectNull. A box gaining focus brings the keyboard up
// (not with a hardware keyboard, which types for itself, or under a launcher screen), another box moves
// it there, and the box losing focus (Return sent a chat line, Escape) closes it, so letters don't go to
// the game's key bindings. A keyboard closed with Done stays closed while the box keeps focus, until the
// UI focuses it again (Say chosen with chat open: the addon's message changes, the rect the same).
static void sp_keyboard_focus(BOOL known, CGRect box) {
    CGRect r = CGRectNull;
    if (!CGRectIsNull(box)) {
        CGRect g = sp_game_rect();
        r = CGRectMake(g.origin.x + box.origin.x * g.size.width, g.origin.y + (1 - box.origin.y - box.size.height) * g.size.height,
                       box.size.width * g.size.width, box.size.height * g.size.height);
    }
    BOOL had = !CGRectIsNull(sp_kb_focus);
    if (known != sp_kb_focus_known) sp_keyboard_say(known ? @"the SPKeyboard addon's strip is showing" : @"no SPKeyboard strip");
    sp_kb_focus_known = known;
    sp_kb_focus = r;
    if (CGRectIsNull(r)) {
        if (!had) return;
        sp_keyboard_say(@"no box has focus");
        if (sp_keyboard_up()) [sp_kb_view resignFirstResponder];
        return;
    }
    // A box's rect, never anything of its text.
    sp_keyboard_say([NSString stringWithFormat:@"a box has focus at %.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y,
                     r.size.width, r.size.height]);
    if (GCKeyboard.coalescedKeyboard || sp_window.rootViewController.presentedViewController) return;
    sp_keyboard_open(r);
}
#endif
