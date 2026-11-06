// Device-local touch layout and its native editor. No game settings or account data are involved.
#import <UIKit/UIKit.h>

static NSString *const SPTouchDefaultsKey = @"sp_touch_controls_v1";
static NSString *const SPTouchChanged = @"SPTouchControlsChanged";

// Bindings use public HID usages; spevent.m owns their AppKit translation.
static NSArray<NSNumber *> *sp_touch_combo(NSString *text) {
    NSMutableArray *keys = [NSMutableArray array];
    NSDictionary *named = @{@"CTRL": @224, @"CONTROL": @224, @"SHIFT": @225, @"ALT": @226,
        @"OPTION": @226, @"CMD": @227, @"COMMAND": @227, @"SPACE": @44, @"RETURN": @40,
        @"ENTER": @40, @"ESC": @41, @"ESCAPE": @41, @"TAB": @43, @"BACKSPACE": @42,
        @"DELETE": @76, @"UP": @82, @"DOWN": @81, @"LEFT": @80, @"RIGHT": @79,
        @"HOME": @74, @"END": @77, @"PAGEUP": @75, @"PAGEDOWN": @78,
        @"-": @45, @"=": @46, @"[": @47, @"]": @48, @";": @51, @"'": @52,
        @"`": @53, @",": @54, @".": @55, @"/": @56, @"\\": @49};
    for (NSString *part in [text.uppercaseString componentsSeparatedByString:@"+"]) {
        NSString *s = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSNumber *key = named[s];
        if (s.length == 1) {
            unichar c = [s characterAtIndex:0];
            if (c >= 'A' && c <= 'Z') key = @(4 + c - 'A');
            if (c >= '1' && c <= '9') key = @(30 + c - '1');
            if (c == '0') key = @39;
        }
        if ([s hasPrefix:@"F"] && s.length > 1) {
            NSInteger n = [[s substringFromIndex:1] integerValue];
            if ([[NSString stringWithFormat:@"F%ld", (long)n] isEqual:s] && n >= 1 && n <= 20)
                key = @(n <= 12 ? 57 + n : 104 + n - 13);
        }
        if (!key) return nil;
        if (![keys containsObject:key]) [keys addObject:key];
    }
    if (!keys.count || keys.count > 8) return nil;
    // Modifier downs precede all ordinary keys, irrespective of the order typed in the editor.
    return [keys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        BOOL am = a.integerValue >= 224, bm = b.integerValue >= 224;
        return am == bm ? NSOrderedSame : am ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static NSArray<NSString *> *sp_touch_actions(void) {
    return @[@"LB", @"RB", @"View", @"Menu", @"A", @"B", @"X", @"Y", @"LT", @"RT", @"L3", @"R3",
             @"Key combo", @"Left click", @"Right click", @"Keyboard", @"Controls"];
}

static NSArray<NSString *> *sp_touch_drag_modes(void) { return @[@"Orbit / Drag Items", @"Turn Character", @"Off"]; }

static NSMutableDictionary *sp_touch_button(NSString *label, NSString *action, NSString *mode, double x, double y) {
    return [@{@"id": NSUUID.UUID.UUIDString, @"label": label, @"action": action, @"mode": mode,
              @"combo": @"Shift+1", @"x": @(x), @"y": @(y)} mutableCopy];
}

static NSDictionary *sp_touch_defaults(void) {
    NSArray *buttons = @[sp_touch_button(@"LB", @"LB", @"Toggle", .09, .30),
                         sp_touch_button(@"RB", @"RB", @"Toggle", .91, .30),
                         sp_touch_button(@"▧", @"View", @"Tap", .44, .10),
                         sp_touch_button(@"☰", @"Menu", @"Tap", .56, .10)];
    for (NSUInteger i = 0; i < buttons.count; i++) buttons[i][@"id"] = @[@"default-lb", @"default-rb", @"default-view", @"default-menu"][i];
    return @{@"enabled": @YES, @"left": @YES, @"right": @YES, @"longPress": @YES,
             @"pinch": @YES, @"zoomSpeed": @8, @"twoFingerDrag": @"Orbit / Drag Items",
             @"doubleTapDrag": @YES, @"twoFingerTap": @YES,
             @"radius": @56, @"deadzone": @0.16, @"opacity": @0.42, @"buttonOpacity": @1,
             @"size": @40, @"holdTime": @0.45,
             @"buttons": buttons};
}

static double sp_touch_number(id value, double fallback, double lo, double hi) {
    if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return fallback;
    return fmax(lo, fmin(hi, [value doubleValue]));
}

static NSMutableDictionary *sp_touch_load(void) {
    NSDictionary *defaults = sp_touch_defaults();
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SPTouchDefaultsKey];
    NSMutableDictionary *c = [defaults mutableCopy];
    for (NSString *key in @[@"enabled", @"left", @"right", @"longPress", @"pinch", @"doubleTapDrag", @"twoFingerTap"])
        if ([saved[key] isKindOfClass:NSNumber.class]) c[key] = @([saved[key] boolValue]);
    if ([sp_touch_drag_modes() containsObject:saved[@"twoFingerDrag"]]) c[@"twoFingerDrag"] = saved[@"twoFingerDrag"];
    NSDictionary *ranges = @{@"radius": @[@30, @100], @"deadzone": @[@.05, @.4],
        @"opacity": @[@.15, @.85], @"buttonOpacity": @[@.2, @1], @"size": @[@28, @72],
        @"holdTime": @[@.3, @.9], @"zoomSpeed": @[@2, @20]};
    for (NSString *key in ranges) c[key] = @(sp_touch_number(saved[key], [defaults[key] doubleValue],
        [ranges[key][0] doubleValue], [ranges[key][1] doubleValue]));
    NSMutableArray *buttons = [NSMutableArray array];
    NSArray *source = [saved[@"buttons"] isKindOfClass:NSArray.class] ? saved[@"buttons"] : defaults[@"buttons"];
    NSMutableSet *ids = [NSMutableSet set];
    for (id value in source) {
        if (![value isKindOfClass:NSDictionary.class] || buttons.count == 24) continue;
        NSDictionary *b = value;
        if (![sp_touch_actions() containsObject:b[@"action"]] ||
            ![@[@"Hold", @"Tap", @"Toggle"] containsObject:b[@"mode"]]) continue;
        NSMutableDictionary *valid = sp_touch_button(@"•", b[@"action"], b[@"mode"],
            sp_touch_number(b[@"x"], .5, 0, 1), sp_touch_number(b[@"y"], .5, 0, 1));
        if ([b[@"id"] isKindOfClass:NSString.class] && [b[@"id"] length] && ![ids containsObject:b[@"id"]])
            valid[@"id"] = b[@"id"];
        [ids addObject:valid[@"id"]];
        if ([b[@"label"] isKindOfClass:NSString.class] && [b[@"label"] length] <= 12) valid[@"label"] = b[@"label"];
        if ([b[@"combo"] isKindOfClass:NSString.class] && sp_touch_combo(b[@"combo"])) valid[@"combo"] = b[@"combo"];
        [buttons addObject:valid];
    }
    c[@"buttons"] = buttons;
    return c;
}

static void sp_touch_save(NSDictionary *c) {
    [NSUserDefaults.standardUserDefaults setObject:c forKey:SPTouchDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:SPTouchChanged object:nil];
}

@interface SPTouchChoice : UITableViewController
@property(nonatomic, copy) NSArray<NSString *> *choices;
@property(nonatomic, copy) NSString *selected;
@property(nonatomic, copy) void (^choose)(NSString *);
@end
@implementation SPTouchChoice
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _choices.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = _choices[path.row];
    cell.accessoryType = [cell.textLabel.text isEqual:_selected] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    _choose(_choices[path.row]);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface SPTouchSettings : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSString *buttonID;
@property(nonatomic, copy) void (^arrange)(void);
@property(nonatomic, copy) void (^closed)(void);
@end

@implementation SPTouchSettings {
    NSMutableDictionary *_config;
    NSMutableDictionary *_button;
}
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _buttonID ? @"Edit Button" : @"Touch Controls";
    if (!_buttonID) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _config = sp_touch_load();
    _button = nil;
    for (NSMutableDictionary *b in _config[@"buttons"]) if ([b[@"id"] isEqual:_buttonID]) _button = b;
    [self.tableView reloadData];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_buttonID) self.navigationController.presentationController.delegate = self;
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller { if (_closed) _closed(); }
- (void)done { [self.view endEditing:YES]; [self dismissViewControllerAnimated:YES completion:_closed]; }
- (void)save { sp_touch_save(_config); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _buttonID ? 3 : 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_buttonID) return section == 0 ? 4 : section == 1 ? 2 : 1;
    return section == 0 ? 10 : section == 1 ? 5 : section == 2 ? [_config[@"buttons"] count] + 1 : (_arrange ? 2 : 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (_buttonID ? @[@"Binding", @"Position", @""] : @[@"Gestures", @"Appearance & Feel", @"Buttons", @"Layout"])[section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (_buttonID && section == 0) return @"Hold follows your finger. Tap sends a short press. Toggle stays held until tapped again. Keyboard and Controls always open on a tap. Combos: Shift+1, Ctrl+Alt+R, Space, or Escape.";
    if (_buttonID && section == 1) return @"Positions are relative to the game area. You can also drag buttons in Arrange Buttons.";
    if (!_buttonID && section == 0) return @"One finger on each half controls the sticks. Two fingers on the same half pinch to zoom or drag together to orbit the camera or drag UI items; the first finger sets the click position. Tap, then touch again and drag to move an item with one finger. Hold still to right-click. Four-finger tap opens the keyboard. The game's action-bar locks still apply.";
    if (!_buttonID && section == 2) return @"Add keys, key combinations, gamepad buttons, mouse buttons, or buttons that open Keyboard and Controls. All held inputs clear when opening an editor or leaving the app.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSInteger s = path.section, r = path.row;
    if (_buttonID) {
        if (s == 0) {
            NSString *key = @[@"label", @"action", @"mode", @"combo"][r];
            cell.textLabel.text = @[@"Label", @"Action", @"Behavior", @"Keys"][r];
            cell.detailTextLabel.text = _button[key];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (s == 1) {
            [self slider:cell title:r ? @"Vertical" : @"Horizontal" key:r ? @"y" : @"x" lo:0 hi:1 button:YES];
        } else { cell.textLabel.text = @"Delete Button"; cell.textLabel.textColor = UIColor.systemRedColor; }
    } else if (s == 0) {
        NSString *key = @[@"enabled", @"left", @"right", @"longPress", @"holdTime", @"pinch", @"zoomSpeed",
                           @"twoFingerDrag", @"doubleTapDrag", @"twoFingerTap"][r];
        NSString *title = @[@"Touch Controls", @"Left Floating Stick", @"Right Floating Stick", @"Long-Press Right Click",
                             @"Long-Press Delay", @"Pinch to Zoom", @"Zoom Sensitivity", @"Two-Finger Drag",
                             @"Double-Tap and Drag", @"Two-Finger Tap: Right Click"][r];
        if (r == 4) [self slider:cell title:title key:key lo:.3 hi:.9 button:NO];
        else if (r == 6) [self slider:cell title:title key:key lo:2 hi:20 button:NO];
        else if (r == 7) {
            cell.textLabel.text = title; cell.detailTextLabel.text = _config[key];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        else {
            cell.textLabel.text = title;
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = [_config[key] boolValue]; toggle.accessibilityIdentifier = key;
            [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
    } else if (s == 1) {
        NSString *key = @[@"radius", @"deadzone", @"opacity", @"size", @"buttonOpacity"][r];
        NSArray *lo = @[@30, @.05, @.15, @28, @.2], *hi = @[@100, @.4, @.85, @72, @1];
        [self slider:cell title:@[@"Stick Radius", @"Dead Zone", @"Stick Opacity", @"Button Size", @"Button Opacity"][r]
            key:key lo:[lo[r] doubleValue] hi:[hi[r] doubleValue] button:NO];
    } else if (s == 2) {
        NSArray *buttons = _config[@"buttons"];
        if (r == buttons.count) cell.textLabel.text = @"Add Button";
        else {
            NSDictionary *b = buttons[r]; cell.textLabel.text = b[@"label"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [b[@"action"] isEqual:@"Key combo"] ? b[@"combo"] : b[@"action"], b[@"mode"]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        cell.textLabel.text = _arrange && r == 0 ? @"Arrange Buttons" : @"Restore Defaults";
    }
    return cell;
}
- (void)slider:(UITableViewCell *)cell title:(NSString *)title key:(NSString *)key lo:(float)lo hi:(float)hi button:(BOOL)button {
    cell.textLabel.text = title;
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 160, 32)];
    slider.minimumValue = lo; slider.maximumValue = hi;
    slider.value = [(button ? _button : _config)[key] floatValue];
    slider.accessibilityIdentifier = key; slider.accessibilityLabel = title;
    [slider addTarget:self action:@selector(slider:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = slider;
}
- (void)toggle:(UISwitch *)toggle { _config[toggle.accessibilityIdentifier] = @(toggle.on); [self save]; }
- (void)slider:(UISlider *)slider {
    (_buttonID ? _button : _config)[slider.accessibilityIdentifier] = @(slider.value);
    [self save];
}
- (void)editText:(NSString *)key title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:[key isEqual:@"combo"] ? @"Use + between keys. Examples: Shift+1, Ctrl+Alt+R, Space." : @"Up to 12 characters."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = self->_button[key]; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        BOOL valid = [key isEqual:@"combo"] ? sp_touch_combo(text) != nil : text.length > 0 && text.length <= 12;
        if (valid) { self->_button[key] = text; [self save]; [self.tableView reloadData]; }
        else {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"Check the Binding"
                message:@"Use a label with 1–12 characters, or a combination of letter, number, modifier, arrow, or function keys."
                preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:error animated:YES completion:nil];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSInteger s = path.section, r = path.row;
    if (!_buttonID && s == 0 && r == 7) {
        SPTouchChoice *choice = [[SPTouchChoice alloc] initWithStyle:UITableViewStyleInsetGrouped];
        choice.title = @"Two-Finger Drag"; choice.choices = sp_touch_drag_modes(); choice.selected = _config[@"twoFingerDrag"];
        __weak SPTouchSettings *weak = self;
        choice.choose = ^(NSString *value) {
            SPTouchSettings *editor = weak;
            if (editor) { editor->_config[@"twoFingerDrag"] = value; [editor save]; }
        };
        [self.navigationController pushViewController:choice animated:YES];
        return;
    }
    if (_buttonID) {
        if (s == 0 && (r == 0 || r == 3)) { [self editText:r ? @"combo" : @"label" title:r ? @"Keys" : @"Label"]; return; }
        if (s == 0) {
            NSString *key = r == 1 ? @"action" : @"mode";
            SPTouchChoice *choice = [[SPTouchChoice alloc] initWithStyle:UITableViewStyleInsetGrouped];
            choice.title = r == 1 ? @"Action" : @"Behavior";
            choice.choices = r == 1 ? sp_touch_actions() : @[@"Hold", @"Tap", @"Toggle"];
            choice.selected = _button[key];
            __weak SPTouchSettings *weak = self;
            choice.choose = ^(NSString *value) {
                SPTouchSettings *editor = weak;
                if (editor) { editor->_button[key] = value; [editor save]; }
            };
            [self.navigationController pushViewController:choice animated:YES];
        } else if (s == 2) {
            [_config[@"buttons"] removeObject:_button]; [self save];
            [self.navigationController popViewControllerAnimated:YES];
        }
    } else if (s == 2) {
        NSMutableArray *buttons = _config[@"buttons"];
        if (r == buttons.count) {
            if (buttons.count >= 24) return;
            [buttons addObject:sp_touch_button(@"Key", @"Key combo", @"Tap", .5, .5)]; [self save];
        }
        SPTouchSettings *editor = [[SPTouchSettings alloc] init];
        editor.buttonID = buttons[r][@"id"];
        [self.navigationController pushViewController:editor animated:YES];
    } else if (s == 3) {
        if (_arrange && r == 0) { [self dismissViewControllerAnimated:YES completion:_arrange]; return; }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore Touch Defaults?"
            message:@"This replaces your buttons and touch preferences." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            sp_touch_save(sp_touch_defaults()); [self viewWillAppear:NO];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
@end

__attribute__((visibility("default")))
UIViewController *sp_uikit_touch_settings(void) {
    return [[UINavigationController alloc] initWithRootViewController:[[SPTouchSettings alloc] init]];
}
