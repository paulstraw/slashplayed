// The launcher's Objective-C and Swift, each to the other. build-launcher.sh gives it to swiftc as the
// bridging header (-import-objc-header), so the Swift screens (spstartscreen.swift, spsettings.swift, spsignin.swift, ...) call the launcher's
// logic through these C functions; the Objective-C imports it for the Swift side's own C entry points
// (@_cdecl). The logic stays in Objective-C: the companion's tests compile some of it for the Mac
// (spsign.m), and the credential rules (CLAUDE.md) are kept where they're already kept (splogin.m,
// spsign.m). Swift only shows what these return.
#import <UIKit/UIKit.h>
#import "spsign.h"
#import "splogo.h"  // the start screen's logo (spstartscreen.swift)

NS_ASSUME_NONNULL_BEGIN

// launcher.m
void sp_launch_say(NSString *s);
NSString *sp_flavor_name(NSString *flavor);
// The build a game starts with (Version, Build Key, ...), and whether the device made it. nil without a stamp.
NSDictionary<NSString *, NSString *> *_Nullable sp_game_build(NSString *flavor, BOOL *updated);
// Whether the game has an image to start: the app's, or one the device made that the next start would load.
// NO for a game an app built without images offers to install.
BOOL sp_game_has_image(NSString *flavor);
NSString *sp_game_reset(NSString *flavor);
// The game's region and languages (spcdn.h's sp_game_region: Region, Text, Speech, Source), and Device "1"
// when the device decides them (Settings can change it), "0" when the Mac does (Battle.net there).
NSDictionary<NSString *, NSString *> *sp_game_region_now(NSString *flavor);
// Settings' Region: the region file in `region`, applied from the game's next start. A line for the log.
NSString *sp_game_set_region(NSString *flavor, NSString *region);
// spcdn.m: the regions offered (us, eu, kr, tw) and what a person reads for one (Americas, Europe, ...).
NSArray<NSString *> *sp_regions(void);
NSString *sp_region_name(NSString *region);

// spjit.m: "iPad", "iPhone", or "Vision Pro".
NSString *sp_device_noun(void);

// splogin.m. The email is the one sign-in value that leaves it, for Show Email: never logged.
BOOL sp_login_saved(void);
NSString *_Nullable sp_login_email(void);
BOOL sp_login_forget(void);
UIViewController *sp_login_screen(void (^done)(BOOL saved));

// spstart.m: Goodmountain at `size` points for the default text size, scaled like `style` up to `maximum`
// (the system font when it's missing).
UIFont *sp_face(CGFloat size, UIFontTextStyle style, CGFloat maximum, UITraitCollection *traits);
// spstart.m: the logo's S (splogo.h's path), in the icon's 1024-unit space.
UIBezierPath *sp_logo_s(void);
// spstart.m: an HTML license's text (the Rust standard library's notices), for the license page.
NSString *sp_html_text(NSString *html);

// spsettings.swift. The Settings sheet over the start screen, opening in `drill`'s state ($SP_START_DRILL)
// when one is given; and hiding the email it shows, when a game starts.
// spsignin.swift. The sign-in screen; splogin.m's `entered` checks and keeps what's typed (nil when it took
// them, else what to say), and `cancel` gives it Cancel (Settings' Sign In…).
UIViewController *sp_signin_screen(NSString *noun, NSString *_Nullable (^entered)(NSString *email, NSString *password),
                                   void (^_Nullable cancel)(void));
// sppairscreen.swift, spvpnscreen.swift, spstyle.swift: the waiting screens (sppair.m's, spvpn.m's) and
// their status line.
UIViewController *sp_pair_screen(NSString *_Nullable (^send)(NSString *code), void (^renew)(void));
void sp_pair_ask(UIViewController *screen, BOOL ask);
UIViewController *sp_vpn_screen(NSString *noun, void (^turnOn)(void));
void sp_screen_status(UIViewController *screen, NSString *text);
// sppatchscreen.swift: the newer-build screen (sppatch.m's). `choose` gets the index of the button tapped;
// sp_patch_show sets what it says (no buttons: a spinner) and clears the status line.
UIViewController *sp_patch_screen(void (^choose)(NSInteger index));
void sp_patch_show(UIViewController *screen, NSString *heading, NSString *message, NSString *_Nullable note,
                   NSArray<NSString *> *buttons);

// spstartscreen.swift. The start screen for `flavors` (flavors.plist's order), the `installable` ones
// reading "Install <game>", calling `pick` with the one tapped; and the Settings sheet over it in `drill`'s
// state ($SP_START_DRILL).
UIViewController *sp_start_screen(NSArray<NSString *> *flavors, NSArray<NSString *> *installable, void (^pick)(NSString *flavor));
void sp_start_settings(UIViewController *screen, NSString *drill);

UIViewController *sp_settings_sheet(NSArray<NSString *> *flavors, NSString *_Nullable drill);
void sp_settings_hide_email(void);

NS_ASSUME_NONNULL_END
