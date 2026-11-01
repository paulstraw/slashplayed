// The start screen's logic; the screen itself is SwiftUI (spstartscreen.swift, through sp_start_screen).
// Every launch that doesn't name a game ($SP_LAUNCH_FLAVOR: the companion's Play and run.sh pass it) starts
// there, even with one game installed: one tap on a game starts it, and the gear opens the app's Settings, a
// sheet (spsettings.swift). Before anything per game (the leftover login.txt, the render scale, the
// arguments, the sign-in) and before the helper attaches. The games are the app's, in flavors.plist's
// order, with its names (launcher.m). Here: the wait for that tap, the lines the companion and scripts
// follow, the dev overrides, and what the Swift screens and the launcher share: Goodmountain (sp_face),
// the logo's S (sp_logo_s), and the license pages' text (sp_html_text).
//
// Goodmountain is a display face the app ships unmodified with its license (scripts/fetch-font.sh; the
// system font stands in if it's missing), scaled with Dynamic Type.
//
// Dev only, through run.sh (which alone passes them, as the patch drill's SP_PATCH_DRILL; a launch from the
// home screen has no environment): $SP_START_DRILL=<state> opens the screen with the Settings sheet already
// showing that state, so each state can be screenshotted without taps (spsettings.swift's runDrill lists
// them), and $SP_START_TEXT_SIZE=<XS…XXXL, AX1…AX5> sets the screen's Dynamic Type size.
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "splogo.h"
#import "spswift.h"  // the start screen and the Settings sheet (Swift), and the launcher's functions they call

void (^sp_launch_uikit(void))(double);  // launcher.m
UIViewController *sp_scene_root(void);  // spvpn.m

static void say(NSString *s) { sp_launch_say([@"start: " stringByAppendingString:s]); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

// ---- the look's pieces the Swift screens and the launcher share

// Goodmountain at `size` points for the default text size, scaled for `traits`' Dynamic Type size like
// `style`, up to `maximum`. The app's copy is registered for this process on first use (no Info.plist key:
// one template serves every build). The system font stands in when the file is missing or refused.
static UIFont *face(CGFloat size, UIFontTextStyle style, CGFloat maximum, UITraitCollection *traits) {
    static BOOL registered;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"Goodmountain-Regular" withExtension:@"otf"];
        CFErrorRef error = NULL;
        if (!url) say(@"no Goodmountain-Regular.otf in the app: the system font stands in");
        else if (!(registered = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error))) {
            say([NSString stringWithFormat:@"Goodmountain wasn't registered (%@): the system font stands in", (__bridge NSError *)error]);
            if (error) CFRelease(error);
        }
    });
    UIFont *font = (registered ? [UIFont fontWithName:@"Goodmountain-Regular" size:size] : nil)
                       ?: [UIFont systemFontOfSize:size weight:UIFontWeightBold];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:font maximumPointSize:maximum compatibleWithTraitCollection:traits];
}

// Goodmountain for the Swift screens (spstyle.swift's spFace) and the launcher (launcher.m, before the
// loading screen), registered and scaled as here.
UIFont *sp_face(CGFloat size, UIFontTextStyle style, CGFloat maximum, UITraitCollection *traits) {
    return face(size, style, maximum, traits);
}

// An SVG path's `d` with absolute M, L, H, V, C, and Z only (splogo.h's S), as a path in its own units.
static UIBezierPath *svg_path(const char *d) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint at = CGPointZero;
    char command = 0;
    for (const char *s = d; *s;) {
        if (*s == ' ' || *s == ',') { s++; continue; }
        if (strchr("MLHVCZ", *s)) {
            command = *s++;
            if (command == 'Z') [path closePath];
            continue;
        }
        int count = command == 'C' ? 6 : command == 'H' || command == 'V' ? 1 : 2;
        double v[6];
        for (int i = 0; i < count; i++) {
            while (*s == ' ' || *s == ',') s++;
            char *end;
            v[i] = strtod(s, &end);
            if (end == s) return path;  // not a number: the rest isn't a path this reads
            s = end;
        }
        switch (command) {
            case 'M': [path moveToPoint:(at = CGPointMake(v[0], v[1]))]; command = 'L'; break;  // then implicit L's
            case 'L': [path addLineToPoint:(at = CGPointMake(v[0], v[1]))]; break;
            case 'H': [path addLineToPoint:(at = CGPointMake(v[0], at.y))]; break;
            case 'V': [path addLineToPoint:(at = CGPointMake(at.x, v[0]))]; break;
            case 'C': [path addCurveToPoint:(at = CGPointMake(v[4], v[5])) controlPoint1:CGPointMake(v[0], v[1])
                              controlPoint2:CGPointMake(v[2], v[3])]; break;
            default: return path;
        }
    }
    return path;
}

// The logo's S (splogo.h), in the icon's 1024-unit space, for the start screen's Emblem (spstartscreen.swift).
UIBezierPath *sp_logo_s(void) {
    static UIBezierPath *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = svg_path(SP_LOGO_S_PATH); });
    return s;
}

// ---- Settings (spsettings.swift)

// An HTML file's text, for the Settings sheet's license page (spsettings.swift; the Rust standard library's
// notices, 1.5 MB: WebKit's import took seconds and set it black on the dark sheet): <pre> blocks as they
// are, other runs of white space as one space, a line break after each block, no tags, and the character references decoded.
NSString *sp_html_text(NSString *html) {
    NSRegularExpressionOptions i = NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators;
    NSString *(^replace)(NSString *, NSString *, NSString *) = ^(NSString *text, NSString *pattern, NSString *with) {
        return [[NSRegularExpression regularExpressionWithPattern:pattern options:i error:nil]
            stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:with];
    };
    html = replace(html, @"<head>.*?</head>", @"");
    NSMutableString *out = [NSMutableString string];
    NSScanner *scan = [NSScanner scannerWithString:html];
    scan.charactersToBeSkipped = nil;
    scan.caseSensitive = NO;
    while (!scan.isAtEnd) {
        NSString *flow = @"", *pre = @"";
        [scan scanUpToString:@"<pre" intoString:&flow];
        [out appendString:replace(flow, @"\\s+", @" ")];
        if (scan.isAtEnd) break;
        [scan scanUpToString:@"</pre>" intoString:&pre];
        [out appendFormat:@"\n%@\n", replace(pre, @"^<pre[^>]*>", @"")];
        if (!scan.isAtEnd) scan.scanLocation += 6;
    }
    NSString *text = replace(out, @"<br\\s*/?>", @"\n");
    text = replace(text, @"</(p|h[1-6]|li|div|summary|details|ul)>|<(p|h[1-6]|li|ul|details)( [^>]*)?>", @"\n");
    text = replace(text, @"<[^>]+>", @"");
    text = replace(text, @"[ \t]*\n[ \t]*", @"\n");
    text = replace(text, @"\n{3,}", @"\n\n");
    NSMutableString *decoded = [NSMutableString string];
    scan = [NSScanner scannerWithString:text];
    scan.charactersToBeSkipped = nil;
    NSDictionary<NSString *, NSString *> *named = @{@"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'", @"nbsp": @"\u00a0"};
    while (!scan.isAtEnd) {
        NSString *part = @"";
        [scan scanUpToString:@"&" intoString:&part];
        [decoded appendString:part];
        if (scan.isAtEnd) break;
        NSUInteger at = scan.scanLocation, end = [text rangeOfString:@";" options:0 range:NSMakeRange(at, MIN(12, text.length - at))].location;
        NSString *entity = end == NSNotFound ? nil : [text substringWithRange:NSMakeRange(at + 1, end - at - 1)];
        NSString *character = named[entity];
        if (!character && [entity hasPrefix:@"#"]) {
            unsigned long code = [entity hasPrefix:@"#x"] || [entity hasPrefix:@"#X"] ? strtoul(entity.UTF8String + 2, NULL, 16)
                                                                                        : strtoul(entity.UTF8String + 1, NULL, 10);
            UTF32Char c = (UTF32Char)code;
            if (code) character = [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
        }
        [decoded appendString:character ?: @"&"];
        scan.scanLocation = character ? end + 1 : at + 1;
    }
    return [decoded stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// ---- the screen

// $SP_START_TEXT_SIZE's short names for the Dynamic Type sizes.
static UIContentSizeCategory text_size(NSString *name) {
    NSDictionary<NSString *, UIContentSizeCategory> *sizes = @{
        @"XS": UIContentSizeCategoryExtraSmall, @"S": UIContentSizeCategorySmall, @"M": UIContentSizeCategoryMedium,
        @"L": UIContentSizeCategoryLarge, @"XL": UIContentSizeCategoryExtraLarge, @"XXL": UIContentSizeCategoryExtraExtraLarge,
        @"XXXL": UIContentSizeCategoryExtraExtraExtraLarge, @"AX1": UIContentSizeCategoryAccessibilityMedium,
        @"AX2": UIContentSizeCategoryAccessibilityLarge, @"AX3": UIContentSizeCategoryAccessibilityExtraLarge,
        @"AX4": UIContentSizeCategoryAccessibilityExtraExtraLarge, @"AX5": UIContentSizeCategoryAccessibilityExtraExtraExtraLarge,
    };
    return sizes[name];
}

// Which of `flavors` (in the screen's order) to start, or nil when there's no screen to ask on (the
// launcher then starts the last one run). The `installable` ones (an app built without client images, whose
// device hasn't made one of them yet: sp_games) read "Install <game>", and the launcher installs the one
// tapped before it starts (sp_patch_install). Sets *pump to UIKit's, which it starts on visionOS.
NSString *sp_pick_flavor(NSArray<NSString *> *flavors, NSSet<NSString *> *installable, void (^*pump)(double)) {
    void (^ui)(double) = sp_launch_uikit();
    UIViewController *root = ui ? sp_scene_root() : nil;
    if (!root) {
        say(@"no screen to show the start screen on");
        return nil;
    }
    *pump = ui;
    NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
    __block NSString *picked = nil;  // set by a tap; read by the wait
    UIViewController *screen = sp_start_screen(flavors, installable.allObjects, ^(NSString *flavor) {
        if (!picked) picked = flavor;
    });
    NSString *textSize = env[@"SP_START_TEXT_SIZE"];
    if (textSize.length) {
        UIContentSizeCategory category = text_size(textSize);
        if (category) screen.traitOverrides.preferredContentSizeCategory = category;
        say(category ? [@"text size " stringByAppendingString:category]
                     : [NSString stringWithFormat:@"SP_START_TEXT_SIZE=%@ isn't a size (XS…XXXL, AX1…AX5)", textSize]);
    }
    // Checked, as splogin.m's: UIKit refuses a presentation while the root still presents another.
    __block BOOL shown = NO;
    [root presentViewController:screen animated:NO completion:^{ shown = YES; }];
    for (double end = now() + 5; !shown && now() < end;) ui(0.05);
    if (!shown || !screen.presentingViewController) {
        say([NSString stringWithFormat:@"the start screen didn't show (the root presents %@)", root.presentedViewController]);
        return nil;
    }
    say(@"showing the start screen");
    NSString *drill = env[@"SP_START_DRILL"];
    if (drill.length) {
        say([@"drill: SP_START_DRILL=" stringByAppendingString:drill]);
        sp_start_settings(screen, drill);
    }
    while (!picked) ui(0.1);
    say([NSString stringWithFormat:@"picked %@%@", picked, [installable containsObject:picked] ? @" (to install)" : @""]);
    // A game starts: the email hides (the sheet, if a tap got past it, goes with the screen below anyway).
    sp_settings_hide_email();
    // Until it's gone (and the sheet, if a tap got past it): the sign-in, LocalDevVPN, and pairing screens
    // may be presented next.
    __block BOOL gone = NO;
    [screen dismissViewControllerAnimated:NO completion:^{ gone = YES; }];
    for (double end = now() + 5; !gone && now() < end;) ui(0.05);
    // The input view (spevent.m) takes the keys back.
    [root.view becomeFirstResponder];
    return picked;
}
