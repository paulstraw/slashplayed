// The gesture-opened text composer on iPhone and iPad. UIKit owns editing, selection, input methods,
// and clipboard access; the shim only receives a committed draft. Included by spevent.m, and kept free
// of AppKit so the same view can be exercised in a UIKit harness without a game or its credentials.
#import <UIKit/UIKit.h>

@interface SPTextComposer : UIViewController <UITextViewDelegate>
@property(nonatomic, copy) void (^insertText)(NSString *);
@property(nonatomic, copy) void (^pressReturn)(void);
@property(nonatomic, copy) void (^closed)(void);
@property(nonatomic, copy) void (^controls)(void);
@end

@implementation SPTextComposer {
    UITextView *_editor;
    UILabel *_placeholder;
    UIButton *_insert;
    BOOL _closing;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return self;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 12, 10, 12);
    button.configuration = config;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    UIButton *backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    backdrop.frame = self.view.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.accessibilityLabel = @"Dismiss text input";
    [backdrop addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:backdrop];

    UIVisualEffectView *card = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    [self.view addSubview:card];

    _editor = [[UITextView alloc] initWithFrame:CGRectZero];
    _editor.delegate = self;
    _editor.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _editor.adjustsFontForContentSizeCategory = YES;
    _editor.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _editor.layer.cornerRadius = 10;
    _editor.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.spellCheckingType = UITextSpellCheckingTypeNo;
    _editor.smartQuotesType = UITextSmartQuotesTypeNo;
    _editor.smartDashesType = UITextSmartDashesTypeNo;
    _editor.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    _editor.pasteConfiguration = [[UIPasteConfiguration alloc]
        initWithAcceptableTypeIdentifiers:@[@"public.plain-text"]];
    _editor.accessibilityLabel = @"Game text";
    _editor.accessibilityHint = @"Type or paste, then use Insert or Return to put it in the game.";
    [_editor.heightAnchor constraintEqualToConstant:72].active = YES;

    _placeholder = [[UILabel alloc] init];
    _placeholder.text = @"Type or paste…";
    _placeholder.font = _editor.font;
    _placeholder.textColor = UIColor.placeholderTextColor;
    _placeholder.userInteractionEnabled = NO;
    _placeholder.isAccessibilityElement = NO;
    _placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [_editor addSubview:_placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [_placeholder.leadingAnchor constraintEqualToAnchor:_editor.leadingAnchor constant:13],
        [_placeholder.topAnchor constraintEqualToAnchor:_editor.topAnchor constant:10],
    ]];

    // The system paste control is a user-initiated paste. Opening the composer never reads the
    // pasteboard, and selection, copy, and cut remain the text view's standard editing menu.
    UIPasteControlConfiguration *pasteConfig = [[UIPasteControlConfiguration alloc] init];
    pasteConfig.displayMode = UIPasteControlDisplayModeIconOnly;
    UIPasteControl *paste = [[UIPasteControl alloc] initWithConfiguration:pasteConfig];
    paste.target = _editor;
    paste.accessibilityLabel = @"Paste into game text";
    UIButton *enter = [self button:@"Return" action:@selector(enter)];
    enter.accessibilityHint = @"Insert the draft, then press Return in the game. With no draft, open or submit chat.";
    _insert = [self button:@"Insert" action:@selector(insert)];
    _insert.accessibilityHint = @"Insert the draft into the game's focused field without pressing Return.";
    UIButton *done = [self button:@"Done" action:@selector(done)];
    UIButton *controls = [self button:@"Controls" action:@selector(openControls)];
    done.accessibilityHint = @"Dismiss the keyboard without sending the remaining draft.";
    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[paste, enter, controls, spacer, _insert, done]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.alignment = UIStackViewAlignmentCenter;
    actions.spacing = 2;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_editor, actions]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    self.view.keyboardLayoutGuide.followsUndockedKeyboard = YES;
    NSLayoutConstraint *bottom = [card.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8];
    bottom.priority = 999;  // a very short landscape window must keep the editor above its top edge
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:560],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        bottom,
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-4],
    ]];
    NSLayoutConstraint *width = [card.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-16];
    width.priority = UILayoutPriorityDefaultHigh;
    width.active = YES;
    [self textViewDidChange:_editor];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_closing) [_editor becomeFirstResponder];
}

- (void)willResignActive:(NSNotification *)notification { [self done]; }

- (void)textViewDidChange:(UITextView *)textView {
    _placeholder.hidden = textView.text.length != 0;
    _insert.enabled = textView.text.length != 0;
}

- (void)insert {
    // Commit any marked input first, so an input method's intermediate spelling is never sent.
    [_editor unmarkText];
    NSString *text = [_editor.text copy];
    if (!text.length) return;
    if (self.insertText) self.insertText(text);
    _editor.text = @"";
    [self textViewDidChange:_editor];
}

- (void)enter {
    [self insert];
    if (self.pressReturn) self.pressReturn();
}

- (void)done {
    if (_closing) return;
    _closing = YES;
    _editor.text = @"";
    [_editor resignFirstResponder];
    void (^closed)(void) = self.closed;
    [self dismissViewControllerAnimated:YES completion:closed];
}

- (void)openControls {
    if (_closing) return;
    _closing = YES;
    _editor.text = @"";
    [_editor resignFirstResponder];
    void (^closed)(void) = self.closed, (^controls)(void) = self.controls;
    [self dismissViewControllerAnimated:YES completion:^{ if (closed) closed(); if (controls) controls(); }];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
