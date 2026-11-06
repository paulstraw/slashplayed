// The app's main executable when it holds several flavors (apps/client/build.sh). visionOS won't
// exec or spawn another executable, and dyld won't dlopen an MH_EXECUTE, so each flavor's client is
// bundled as wow-<flavor> with its header retyped MH_BUNDLE. This picks one, tells the libSystem shim
// which Documents/ folder is its install root ($SP_SYSTEM_FLAVOR), gets the on-device JIT helper attached
// (spjit.m; on failure the scene says why and the client isn't loaded), dlopens the client (dyld loads its
// shims and runs its initializers, which includes the debugger prepare stop the helper services) and calls
// its LC_MAIN entry point.
// The flavor is $SP_LAUNCH_FLAVOR (the companion's Play and run.sh pass it), else the one picked on the start
// screen (spstart.m, every other launch, even with one game; its gear opens the app's Settings, which show
// each game's build, sp_game_build, and reset its settings, sp_game_reset), else the
// last one run, else the first bundled. flavors.plist, in the app, has their names and order.
// First it deletes the game files the Mac companion listed in Library/spdelete.txt (devicectl can't
// delete): CASC index files a patch replaced, before the client opens the indexes, and archives no
// ticked game uses. Then it writes the space left on the device to Library/spfree.txt, for the companion's
// free space and its check that a copy fits (write_free_space). Before the start screen, a leftover
// login.txt in any game's folder is deleted (splogin.m). Once the flavor is picked, on an iPhone the
// game's render scale gets its first-run default (default_render_scale), a launch with no arguments gets
// the last ones saved for the flavor, else Battle.net's (launch_arguments), the image's build stamp is logged against the game data's
// (image_build), and the patch service is asked whether a newer build is out (sppatch.m: a screen says
// so, and whether this Slashplayed can run it, from the new client's imports; then Play Anyway, or Update,
// which makes and signs the new image on the device). That also picks the image: the bundled one, or one
// an update on the device made in Library/spgames/ (sppatch.m says when). If dlopen refuses an updated one,
// it's deleted and the bundled one loads. An update's .build.info row is written once its image has loaded.
// An app built with no client images (build.sh's SP_NO_IMAGES=1, so it ships no Blizzard bytes) offers every
// game in flavors.plist, those the device hasn't made an image of as "Install <game>" (sp_games); picking one
// installs it with the update's chain before anything else per game (sppatch.m's sp_patch_install: it needs
// the signing identity an update needs, and says so without one), and a game installed that way plays and
// updates from Library/spgames as an updated game does, with no bundled image to fall back on.
// Once the bundled image is the update's build or a later one (the companion installed it), the update is
// deleted (retire_caught_up). Before the helper attaches, splogin.m decides how the game signs in
// (the saved Battle.net sign-in, asked for once, or a token the companion relayed), and writes login.txt
// just before the client loads. From then until the client's first frame, the scene shows a loading screen
// (the AppKit shim's sp_uikit_loading).
// Every start also takes a signing identity the companion pushed into the keychain, or forgets it when the
// companion asks (spsign.m; the start screen's Settings forgets it at the tap), and logs whether there is one and until when it's valid, and
// writes that to Library/spidentity.txt for the companion. An update's image whose signer no profile lists any
// more is signed again with that identity, or left out of the start (library_signed).
// $SP_ASSEMBLE_TEST=<flavor> is a test hook: it assembles a kept newer build's image (spassemble.m) and
// logs it, and the launch ends there (assemble_test). $SP_SIGN_TEST=<path in the app's home> is another:
// it signs a copy of that image with the device's identity and loads it (sign_test), and the launch ends.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
#import "spassemble.h"
#import "spcdn.h"  // sp_table_row, sp_build_info_for_image
#import "spsign.h"

static void say(NSString *s) {
    fprintf(stderr, "[sp:launch] %s\n", s.UTF8String);
}

void sp_launch_say(NSString *s) { say(s); }  // spjit.m, sppair.m, and spvpn.m log through it
NSString *sp_jit_attach(void (^pump)(double));  // spjit.m
NSArray<NSDictionary *> *sp_jit_profiles(NSArray<NSData *> *install, void (^pump)(double), NSString **problem);  // spjit.m
NSString *sp_apple_token_import(void);  // spapple.m
NSString *sp_apple_token_describe(void);  // spapple.m

void sp_profiles_renew(void (^pump)(double));  // spapple.m

// The profiles drill ($SP_PROFILES_DRILL, run.sh): before the helper attaches, installs every
// Documents/spprofiles/*.mobileprovision through the helper's misagent (sp_jit_profiles), or with none there
// only lists this app's profiles. (Renewing from Apple is sp_profiles_renew, every launch: SP_RENEW=now.)
static NSString *profiles_drill(void (^pump)(double)) {
    NSMutableArray<NSData *> *install = [NSMutableArray array];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/spprofiles"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name.pathExtension isEqual:@"mobileprovision"]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
        if (d) [install addObject:d];
    }
    say([NSString stringWithFormat:@"profiles drill: %lu to install", (unsigned long)install.count]);
    NSString *problem = nil;
    NSArray *mine = sp_jit_profiles(install, pump, &problem);
    if (mine) say([NSString stringWithFormat:@"profiles drill: %lu of this app's on the device", (unsigned long)mine.count]);
    return problem;
}
NSString *sp_device_noun(void);  // spjit.m
void sp_login_clear(NSArray<NSString *> *flavors);  // splogin.m
NSMutableData *sp_login_prepare(BOOL token, void (^*pump)(double), NSString **problem);
BOOL sp_login_write(NSString *flavor, NSMutableData *bytes);
UIFont *sp_face(CGFloat size, UIFontTextStyle style, CGFloat maximum, UITraitCollection *traits);  // spstart.m
NSString *sp_pick_flavor(NSArray<NSString *> *flavors, NSSet<NSString *> *installable, void (^*pump)(double));  // spstart.m
NSString *sp_patch_check(NSString *flavor, NSString *bundled, NSDictionary<NSString *, NSString *> *bundledStamp, NSString *library,
                         NSDictionary<NSString *, NSString *> *libraryStamp, NSDictionary<NSString *, NSString *> *choice,
                         void (^*pump)(double));  // sppatch.m
NSString *sp_patch_install(NSString *flavor, NSDictionary<NSString *, NSString *> *choice, BOOL back, void (^*pump)(double),
                           NSString **problem);
void sp_patch_refused(NSString *flavor, NSString *version, NSString *bundledVersion, void (^*pump)(double));

// The app's flavors.plist (apps/client/flavors.plist: also scripts/flavor.sh's and the companion's), in
// its order: each flavor's id, name, and Battle.net's arguments. Empty (logged) if it can't be read.
static NSArray<NSDictionary *> *flavor_entries(void) {
    static NSArray<NSDictionary *> *entries;
    if (entries) return entries;
    entries = [NSArray arrayWithContentsOfFile:
               [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"flavors.plist"]];
    if (!entries) {
        say(@"no flavors.plist in the app");
        entries = @[];
    }
    return entries;
}

static NSDictionary *flavor_entry(NSString *flavor) {
    for (NSDictionary *e in flavor_entries())
        if ([e[@"id"] isEqual:flavor]) return e;
    return nil;
}

NSDictionary *sp_flavor_entry(NSString *flavor) { return flavor_entry(flavor); }  // sppatch.m (the client's path)

NSString *sp_flavor_name(NSString *flavor) { return flavor_entry(flavor)[@"name"] ?: flavor; }  // spstart.m

// UIKit before the client is loaded (spuikit.m's sp_uikit_early: the scene, until it's active), and the
// pump that keeps it running while the launcher waits. On iOS always, for the launch watchdog; on visionOS
// only when the launcher needs a screen to wait on a person (sppair.m, spvpn.m). Once: later calls return the same
// pump. nil (logged) when the AppKit shim can't start it.
void (^sp_launch_uikit(void))(double) {
    static void (^pump)(double);
    if (pump) return pump;
    NSString *appkit = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libspAppKit.dylib"];
    void *ak = dlopen(appkit.fileSystemRepresentation, RTLD_NOW);
    void (*early)(double) = ak ? (void (*)(double))dlsym(ak, "sp_uikit_early") : NULL;
    void (*uikit_wait)(double) = ak ? (void (*)(double))dlsym(ak, "sp_uikit_wait") : NULL;
    if (!early || !uikit_wait) {
        say([NSString stringWithFormat:@"no early UIKit: %s", dlerror()]);
        return nil;
    }
    early(10);
    pump = ^(double seconds) { uikit_wait(seconds); };
    return pump;
}

// One container-relative path per line. Only paths in Documents/Data/ are deleted.
static void delete_listed(void) {
    NSString *home = NSHomeDirectory();
    NSString *list = [home stringByAppendingPathComponent:@"Library/spdelete.txt"];
    NSString *text = [NSString stringWithContentsOfFile:list encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    unsigned long deleted = 0, skipped = 0;
    unsigned long long bytes = 0;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length) continue;
        if (![line hasPrefix:@"Documents/Data/"] || [line.pathComponents containsObject:@".."]) {
            skipped++;
            continue;
        }
        NSString *path = [home stringByAppendingPathComponent:line];
        unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize;
        if ([NSFileManager.defaultManager removeItemAtPath:path error:nil]) {
            deleted++;
            bytes += size;
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:list error:nil];
    say([NSString stringWithFormat:@"deleted %lu listed files (%.1f MB), skipped %lu", deleted, bytes / 1e6, skipped]);
}

// Why the game can't load when the companion's last copy of game files stopped before it finished: its
// Library/spcopying.txt (GameFiles.copyMarker) still says "copying". A copy replaces the archives the
// device's client streamed before it sends the indexes that point into them, so a store cut short in
// between has every game quit about 3 s in as "damaged" (the iPhone, 2026-10-29); the next Play finishes
// it. A marker saying the copy finished is deleted. nil: the game data is whole.
static NSString *copy_unfinished(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/spcopying.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return nil;
    if (![text isEqual:@"copying\n"]) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return nil;
    }
    say(@"the last copy of game files stopped before it finished");
    return [NSString stringWithFormat:@"The last copy of game files from your Mac to this %@ stopped before it finished, "
                                      @"so the game data here is incomplete.\n\nOn your Mac, press Play in Slashplayed "
                                      @"Companion with this %@ connected: it finishes the copy.", sp_device_noun(), sp_device_noun()];
}

// The bytes free for the app (what the Settings app shows, which counts space iOS can clear), then the
// bytes free outright (the measure lockdown gives the Mac, without that space), in decimal, as of this
// start, a line each. The companion adds their difference to lockdown's figure to show Settings' figure now
// (Device.freeSpaceNow): lockdown alone read 610 GB on an iPhone whose Settings said 805 GB (rc9 run).
static void write_free_space(void) {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSDictionary *values = [home resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey,
                                                         NSURLVolumeAvailableCapacityKey] error:nil];
    NSNumber *free = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
    NSNumber *outright = values[NSURLVolumeAvailableCapacityKey];
    if (!free) return;
    NSString *text = outright ? [NSString stringWithFormat:@"%@\n%@\n", free, outright] : free.stringValue;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/spfree.txt"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    say([NSString stringWithFormat:@"%.1f GB free (%.1f GB without what iOS can clear)", free.doubleValue / 1e9,
                                   outright.doubleValue / 1e9]);
}

// Settings in the game's Config.wtf (`SET name "value"` lines): each of `cvars` ({name, value}) the file
// doesn't have is added. A value the game or a person set stays. Makes the file (and WTF/) if there's none.
// The names it set, empty for none; nil if it couldn't write the file. (The region's three are
// sp_config_with_region's: game_region.)
static NSArray<NSString *> *config_seed(NSString *flavor, NSArray<NSArray<NSString *> *> *cvars) {
    NSString *wtf = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_/WTF", flavor]];
    NSString *config = [wtf stringByAppendingPathComponent:@"Config.wtf"];
    NSString *text = [NSString stringWithContentsOfFile:config encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *added = [NSMutableArray array];
    for (NSArray<NSString *> *cvar in cvars) {
        NSString *line = [NSString stringWithFormat:@"SET %@ \"%@\"", cvar[0], cvar[1]];
        if ([text rangeOfString:[NSString stringWithFormat:@"SET %@ ", cvar[0]] options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
        if (text.length && ![text hasSuffix:@"\n"]) text = [text stringByAppendingString:@"\n"];
        text = [text stringByAppendingFormat:@"%@\n", line];
        [added addObject:cvar[0]];
    }
    if (!added.count) return added;
    [NSFileManager.defaultManager createDirectoryAtPath:wtf withIntermediateDirectories:YES attributes:nil error:nil];
    return [text writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:nil] ? added : nil;
}

// An iPhone renders at 2x by default (spwindow.m), for a readable UI; the game's own render scale at 50%
// keeps the 3D world near 1x's GPU cost. Set once per flavor, only if Config.wtf doesn't have it, so a
// change in the game's settings sticks (the game drops the line again when it's set back to 100%, which
// is why it's once: Library/sprenderscale-<flavor> records it). Not when the backing scale is below 2
// (Settings > Display, or SP_SCALE): the AppKit shim's sp_backing_scale says which, so the precedence is
// in one place. On iOS that library is already loaded (sp_launch_uikit).
static void default_render_scale(NSString *flavor) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return;
    NSString *appkit = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libspAppKit.dylib"];
    void *ak = dlopen(appkit.fileSystemRepresentation, RTLD_NOW);
    double (*backing)(void) = ak ? (double (*)(void))dlsym(ak, "sp_backing_scale") : NULL;
    if (!backing) {
        say([NSString stringWithFormat:@"no backing scale to seed the render scale by: %s", dlerror()]);
        return;
    }
    if (backing() < 2) return;  // the shim logs which (its first read)
    NSString *home = NSHomeDirectory();
    NSString *mark = [home stringByAppendingPathComponent:[@"Library/sprenderscale-" stringByAppendingString:flavor]];
    if ([NSFileManager.defaultManager fileExistsAtPath:mark]) return;
    NSString *wtf = [home stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_/WTF", flavor]];
    NSString *config = [wtf stringByAppendingPathComponent:@"Config.wtf"];
    NSString *text = [NSString stringWithContentsOfFile:config encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if ([text rangeOfString:@"SET renderScale " options:NSCaseInsensitiveSearch].location == NSNotFound) {
        if (text.length && ![text hasSuffix:@"\n"]) text = [text stringByAppendingString:@"\n"];
        text = [text stringByAppendingString:@"SET renderScale \"0.5\"\n"];
        [NSFileManager.defaultManager createDirectoryAtPath:wtf withIntermediateDirectories:YES attributes:nil error:nil];
        if (![text writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            say(@"couldn't set the game's render scale to 50%");
            return;
        }
        say(@"set the game's render scale to 50% (first run on this iPhone)");
    }
    [@"" writeToFile:mark atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// The intro movie is marked as seen on a game's first launch on the device (no playIntroMovie in its
// Config.wtf yet), always. A game's first session on an empty store does the client's own setup of its
// data first, and the intro it starts then never plays: the client never asks the CDN for the movie's
// data (every other request goes out and succeeds), so it waits on a black screen with its download bar
// for as long as it's left (15 and 53 minutes on the iPhone, Retail). The next session, with the same
// store, plays it at once. So no first launch plays the intro; it's still in the game's Cinematics menu.
// playIntroMovie is the last expansion whose intro played (99 is past every one, and the game keeps it).
// SP_SKIP_INTRO=1 (agent and dev runs: run.sh, the companion's -skip-intro) also answers Retail's Screen
// Narrator question, which waits for Enable or Disable: the narrator settings are what Disable writes.
// Never without the switch: people answer the narrator question themselves. Only lines the file doesn't
// have, so a value the game or a person set stays. The photosensitivity warning is left alone: it
// dismisses itself.
static void skip_intro(NSString *flavor) {
    BOOL agent = [NSProcessInfo.processInfo.environment[@"SP_SKIP_INTRO"] isEqual:@"1"];
    NSMutableArray<NSArray<NSString *> *> *cvars = [NSMutableArray arrayWithObject:@[@"playIntroMovie", @"99"]];
    if (agent) [cvars addObjectsFromArray:@[@[@"showScreenNarrationDialog", @"0"], @[@"accessibilityScreenNarrationEnabled", @"0"]]];
    NSArray<NSString *> *added = config_seed(flavor, cvars);
    if (!added) say(@"skip intro: couldn't write Config.wtf");
    else if (added.count)
        say([NSString stringWithFormat:@"skip intro: set %@ in Config.wtf%@", [added componentsJoinedByString:@", "],
                                       agent ? @"" : @" (the game's first launch here)"]);
    else if (agent) say(@"skip intro: Config.wtf already has the intro and narrator settings");
}

// .build.info's (or a stamp's) row for a product. nil if there's no file or row.
static NSDictionary<NSString *, NSString *> *build_info_row(NSString *path, NSString *product) {
    return sp_table_row([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil], @"Product", product);
}

// ---- the region a game plays in (issue #34; spcdn.h says how it's decided)

static NSString *home_path(NSString *relative) { return [NSHomeDirectory() stringByAppendingPathComponent:relative]; }

static NSString *read_text(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static NSString *region_path(NSString *flavor) { return home_path([@"Library/spregion-" stringByAppendingString:flavor]); }

static NSString *bundled_image(NSString *flavor);

// The game's region and languages now (sp_game_region), and "Device" "1" when the device decides them (the app
// has no image of the game, so the device made or makes its own), "0" when the Mac does. Reads the region file,
// the update's kept row and stamp, the game data's .build.info, and the device's region and languages; logs
// nothing. $SP_REGION_COUNTRY (an ISO country code) and $SP_REGION_LANGUAGES (BCP 47, comma-separated) stand in
// for the device's, for tests (run.sh passes them): a test device's own region is the owner's.
NSArray<NSString *> *sp_device_languages(void) {  // sppatch.m too
    NSString *test = NSProcessInfo.processInfo.environment[@"SP_REGION_LANGUAGES"];
    return test.length ? [test componentsSeparatedByString:@","] : NSLocale.preferredLanguages;
}

NSDictionary<NSString *, NSString *> *sp_game_region_now(NSString *flavor) {
    NSString *test = NSProcessInfo.processInfo.environment[@"SP_REGION_COUNTRY"];
    NSString *country = test.length ? test : [NSLocale.currentLocale objectForKey:NSLocaleCountryCode];
    BOOL device = ![NSFileManager.defaultManager fileExistsAtPath:bundled_image(flavor)];
    NSString *spgames = home_path(@"Library/spgames");
    NSMutableDictionary *choice = [sp_game_region(
        flavor_entry(flavor)[@"product"] ?: @"", device, read_text(region_path(flavor)),
        read_text([spgames stringByAppendingPathComponent:[@"spbuildinfo-" stringByAppendingString:flavor]]),
        read_text([(device ? spgames : NSBundle.mainBundle.bundlePath) stringByAppendingPathComponent:
                   [@"spbuild-" stringByAppendingString:flavor]]),
        read_text(home_path(@"Documents/.build.info")), country, sp_device_languages()) mutableCopy];
    choice[@"Device"] = device ? @"1" : @"0";
    return choice;
}

// Library/spregion-<flavor> from `choice` (sppatch.m's install and Update, and Settings). nil, or why not.
NSString *sp_game_region_write(NSString *flavor, NSDictionary<NSString *, NSString *> *choice) {
    NSString *product = flavor_entry(flavor)[@"product"];
    if (!product.length) return @"the app doesn't know the game's product";
    NSError *e = nil;
    if (![sp_region_file(product, choice) writeToFile:region_path(flavor) atomically:YES encoding:NSUTF8StringEncoding error:&e])
        return [NSString stringWithFormat:@"couldn't write Library/spregion-%@ (%@ %ld)", flavor, e.domain, (long)e.code];
    return nil;
}

// Settings' Region for a game the device decides it for: the region file now has `region`, with the
// device's languages for it that the build ships (as far as the last install or Update read them). The next
// start does the rest (region_sync, game_region, build_info_for_image), and so does every start after, so
// nothing written before puts the old region back. A line for the log.
NSString *sp_game_set_region(NSString *flavor, NSString *region) {
    NSDictionary<NSString *, NSString *> *now = sp_game_region_now(flavor);
    if (![now[@"Device"] isEqual:@"1"]) return [NSString stringWithFormat:@"region %@: the Mac decides it (Battle.net)", flavor];
    if (![sp_regions() containsObject:region]) return [NSString stringWithFormat:@"region %@: %@ isn't a region", flavor, region];
    NSArray<NSString *> *shipped = now[@"Shipped"].length ? [now[@"Shipped"] componentsSeparatedByString:@" "] : nil;
    NSString *text = [region isEqual:now[@"Region"]] ? now[@"Text"] : sp_region_locale(region, sp_device_languages(), shipped);
    NSMutableDictionary *choice = [@{@"Region": region, @"Text": text, @"Speech": text} mutableCopy];
    if (shipped) choice[@"Shipped"] = now[@"Shipped"];
    NSString *problem = sp_game_region_write(flavor, choice);
    return problem ? [NSString stringWithFormat:@"region %@: %@", flavor, problem]
                   : [NSString stringWithFormat:@"region %@ (Settings): %@ (%@), text %@, speech %@; was %@ from %@", flavor, region,
                                                sp_region_name(region), text, text, now[@"Region"], now[@"Source"]];
}

// For a game whose region the device decides, from its region file: the row kept beside its Library/spgames
// image (its Branch and Tags) and the image's stamp (its Branch) in that region, if a Settings change since the
// last start left them in another. Nothing decides the region from them any more, but they say it, and the
// companion pulls the stamps. Before the image is chosen, so the patch check, the load, and the start-time
// .build.info rewrite (build_info_for_image) all see one region. region: lines.
static void region_sync(NSString *flavor, NSDictionary<NSString *, NSString *> *choice) {
    if (![choice[@"Device"] isEqual:@"1"] || ![choice[@"Source"] isEqual:@"chosen"]) return;
    NSString *product = flavor_entry(flavor)[@"product"], *spgames = home_path(@"Library/spgames");
    NSString *tags = sp_region_tags(choice[@"Region"], choice[@"Text"], choice[@"Speech"]);
    for (NSArray *file in @[@[@"spbuildinfo-", @{@"Branch": choice[@"Region"], @"Tags": tags}],
                            @[@"spbuild-", @{@"Branch": choice[@"Region"]}]]) {
        NSString *path = [spgames stringByAppendingPathComponent:[file[0] stringByAppendingString:flavor]];
        NSString *text = sp_table_with(read_text(path), product, file[1]);
        if (!text) continue;
        say([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]
                ? [NSString stringWithFormat:@"region: Library/spgames/%@%@ is in %@ now", file[0], flavor, choice[@"Region"]]
                : [NSString stringWithFormat:@"region: couldn't write Library/spgames/%@%@", file[0], flavor]);
    }
}

// The region and languages the game plays in, in its Config.wtf, before every launch (sp_config_with_region).
// Started by Battle.net, the client takes them from Battle.net's launch options in its prefs (net.battle),
// which nothing writes on the device; without those it falls back on Config.wtf's portal, textLocale, and
// audioLocale. With neither it opens its region picker, a Mac nib the device doesn't have, so the client exits
// by itself (code 255), and saves all three as "" on its way out, so every later launch of that game exits the
// same way. A Config.wtf without them is easy to come by: the one the launcher makes itself for a game's first
// launch (the render scale and the intro, below), one Reset Game Settings deleted, or those blanks. So every
// launch adds any that are missing and replaces any that are "", from the game's region (`choice`). A value
// already set stays (a person's own choice in the game, or the game's), except that a game whose region the
// device decides and that Settings moved to another region gets all three replaced.
static void game_region(NSString *flavor, NSDictionary<NSString *, NSString *> *choice) {
    NSString *wtf = home_path([NSString stringWithFormat:@"Documents/_%@_/WTF", flavor]);
    NSString *config = [wtf stringByAppendingPathComponent:@"Config.wtf"];
    NSArray<NSString *> *set = nil;
    NSString *text = sp_config_with_region(read_text(config), choice, [choice[@"Device"] isEqual:@"1"], &set);
    if (!set.count) return;
    [NSFileManager.defaultManager createDirectoryAtPath:wtf withIntermediateDirectories:YES attributes:nil error:nil];
    if (![text writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:nil])
        say(@"region: couldn't write Config.wtf; the game may ask for a region it can't show, and exit");
    else
        say([NSString stringWithFormat:@"region: set %@ in Config.wtf (%@, text %@, speech %@, from %@)",
                                       [set componentsJoinedByString:@", "], choice[@"Region"], choice[@"Text"], choice[@"Speech"],
                                       choice[@"Source"]]);
}

// The stamp beside a client image (spbuild-<flavor>), its product's row; nil without one or without its Build Key.
static NSDictionary<NSString *, NSString *> *stamp_beside(NSString *image, NSString *flavor) {
    NSDictionary<NSString *, NSString *> *stamp = build_info_row(
        [image.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]],
        flavor_entry(flavor)[@"product"]);
    return stamp[@"Build Key"].length ? stamp : nil;
}

// The two images a game can start: the bundled one, and the one an update on the device made (sppatch.m).
static NSString *bundled_image(NSString *flavor) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:[@"wow-" stringByAppendingString:flavor]];
}

static NSString *library_image(NSString *flavor) {
    return [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/spgames/wow-" stringByAppendingString:flavor]];
}

// The build the client image is: its stamp, spbuild-<flavor> beside wow-<flavor> (apps/client/build.sh and
// the companion's ClientAssembly.Stamp write it: a one-row table shaped like .build.info). It travels with
// the image, so one an on-device update puts in Library/ has its own. Logged against the game data's
// (Documents/.build.info), since the two can disagree today: a new image with the old data, or the
// reverse, after a patch reached one but not the other. Versions only. nil without a stamp.
static NSDictionary<NSString *, NSString *> *image_build(NSString *image, NSString *flavor) {
    NSString *product = flavor_entry(flavor)[@"product"];
    NSDictionary<NSString *, NSString *> *stamp = stamp_beside(image, flavor);
    if (!stamp) {
        say([NSString stringWithFormat:@"build: no stamp for %@ beside its image (built before stamps?)", product ?: flavor]);
        return nil;
    }
    NSDictionary<NSString *, NSString *> *data = build_info_row(
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/.build.info"], product);
    if (!data)
        say([NSString stringWithFormat:@"build: image %@ %@; the game data's .build.info has no %@ row",
                                       product, stamp[@"Version"], product]);
    else if ([data[@"Build Key"] isEqual:stamp[@"Build Key"]])
        say([NSString stringWithFormat:@"build: image and game data are both %@ %@", product, stamp[@"Version"]]);
    else
        say([NSString stringWithFormat:@"build: MISMATCH: image %@ %@, game data %@%@", product, stamp[@"Version"], data[@"Version"],
                                       [data[@"Version"] isEqual:stamp[@"Version"]] ? @" (same version, another build)" : @""]);
    return stamp;
}

// The platform and minimum OS a client image assembled here gets (spassemble.m): the launcher's own
// LC_BUILD_VERSION's. build-launcher.sh compiles it for scripts/platform.sh's target, the one vtool is given
// on the Mac.
void sp_launch_build_version(uint32_t *platform, uint32_t *minOS) {
    *platform = *minOS = 0;
    const struct load_command *lc = (const void *)(&_mh_execute_header + 1);
    for (uint32_t i = 0; i < _mh_execute_header.ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_BUILD_VERSION) {
            *platform = ((const struct build_version_command *)lc)->platform;
            *minOS = ((const struct build_version_command *)lc)->minos;
        }
}

// The image an update on the device made (sppatch.m: Library/spgames/wow-<flavor>, its stamp
// spgames/spbuild-<flavor> beside it, written last) and its build; nil unless both are there.
static NSDictionary<NSString *, NSString *> *updated_build(NSString *image, NSString *flavor) {
    if (![NSFileManager.defaultManager fileExistsAtPath:image]) return nil;
    return stamp_beside(image, flavor);
}

// The game data's .build.info row for an image made on the device (Library/spgames/wow-<flavor>), once it
// has loaded and before the client reads it: the row update kept beside it (spgames/spbuildinfo-<flavor>,
// sppatch.m) when Documents/.build.info's isn't that build's. On the launch that made it, and on any later
// one: one that made it may have stopped before the client loaded, and the game data may have been emptied
// under it. Without the row, an install in an empty container streams with nothing naming its build, and the
// client stops with #134, "Invalid schema … for Table StartupFiles" (issue #36). The bundled image's row is
// the companion's, as it copied the game data. For a game whose region the device decides (`choice` from its
// region file), the row is in that region too, and is written again when a Settings change left it in another,
// so the old row's region doesn't come back. Versions only.
static void build_info_for_image(NSString *flavor, NSString *image, NSDictionary<NSString *, NSString *> *stamp,
                                 NSDictionary<NSString *, NSString *> *choice) {
    NSString *product = flavor_entry(flavor)[@"product"], *dir = image.stringByDeletingLastPathComponent;
    NSString *info = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/.build.info"], *why = nil;
    NSDictionary<NSString *, NSString *> *region = nil;
    if ([choice[@"Device"] isEqual:@"1"] && [choice[@"Source"] isEqual:@"chosen"])
        region = @{@"Branch": choice[@"Region"], @"Tags": sp_region_tags(choice[@"Region"], choice[@"Text"], choice[@"Speech"])};
    NSString *text = sp_build_info_for_image(
        [NSString stringWithContentsOfFile:info encoding:NSUTF8StringEncoding error:nil], product,
        [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:[@"spbuildinfo-" stringByAppendingString:flavor]]
                                  encoding:NSUTF8StringEncoding error:nil],
        [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]]
                                  encoding:NSUTF8StringEncoding error:nil], region, &why);
    if (why) say([NSString stringWithFormat:@"update: .build.info's %@ row isn't the image's %@, and %@: the game may not start",
                                            product, stamp[@"Version"], why]);
    if (!text) return;
    say([text writeToFile:info atomically:YES encoding:NSUTF8StringEncoding error:nil]
            ? [NSString stringWithFormat:@"update: .build.info's %@ row is %@ now%@", product, stamp[@"Version"],
                                         region ? [@" in " stringByAppendingString:region[@"Branch"]] : @""]
            : @"update: couldn't write .build.info");
}

// The bundled image catching up: the companion installs Blizzard's current build, so once the bundled image's
// build equals or passes an update the device made (sp_update_caught_up), that update is deleted, and with it
// a kept newer build's slice (Library/spslice/, sppatch.m) that the bundled image has caught up with too.
// The launcher's own rule, not the companion's spdelete.txt (which only ever names game data): it holds
// whatever put the newer bundled image there, and the companion's Play only follows it in the log. The
// .build.info row stays: an update wrote its build's, which the bundled image's equals, or the companion
// has since written the bundled image's. The patch drill ($SP_PATCH_DRILL, sppatch.m) keeps the slice: its
// "newer" build is the bundled one, so its slice always counts as caught up, and every drill launch fetched
// the same 45 MB again (the rc9 run). The next start without the drill retires it.
static void retire_caught_up(NSString *flavor, NSDictionary<NSString *, NSString *> *bundledStamp) {
    NSString *product = flavor_entry(flavor)[@"product"];
    BOOL drill = NSProcessInfo.processInfo.environment[@"SP_PATCH_DRILL"].length > 0;
    for (NSString *dir in drill ? @[@"Library/spgames"] : @[@"Library/spgames", @"Library/spslice"]) {
        NSString *home = [NSHomeDirectory() stringByAppendingPathComponent:dir];
        NSString *stamp = [home stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]];
        NSDictionary<NSString *, NSString *> *kept = build_info_row(stamp, product);
        if (!sp_update_caught_up(bundledStamp, kept)) continue;
        NSString *file = [home stringByAppendingPathComponent:[dir hasSuffix:@"spgames"] ? [@"wow-" stringByAppendingString:flavor]
                                                                                       : [flavor stringByAppendingString:@".arm64"]];
        unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil].fileSize;
        // The stamp first, so a file left behind is never taken for its build; then the image's kept
        // .build.info row (spgames only), which nothing reads without the stamp.
        [NSFileManager.defaultManager removeItemAtPath:stamp error:nil];
        [NSFileManager.defaultManager removeItemAtPath:file error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[home stringByAppendingPathComponent:[@"spbuildinfo-" stringByAppendingString:flavor]]
                                                 error:nil];
        say([NSString stringWithFormat:@"update: retired %@ %@ %@ (%.1f MB): the bundled image is %@", dir, product, kept[@"Version"],
                                       size / 1e6, bundledStamp[@"Version"]]);
    }
}

// An update's image is signed with the identity the device held when it was made, and dlopen refuses an image
// whose signer no installed profile lists, as it does an ad hoc one (research/dlopentest, 5.3). That signer can
// drop out of the profiles while the image stays: Xcode replaces a free team's certificate (A) and the app is
// installed again with a profile that lists only the new one, or a regenerated profile no longer lists the
// Slashplayed certificate (B). So before the image is chosen, its signer is looked for in the profiles the app
// can see (sp_listed_certificates). Not there: it's signed again, in place, with the device's identity when a
// profile lists that one (the companion sends the new identity at the same Play that installs the new
// profile, and it's imported before this); otherwise this start loads the bundled image, and the update is
// kept for a later start, when an identity that's listed can sign it again. Returns the stamp, or nil to leave
// the update out. update: lines, never the certificate.
static BOOL library_listed(NSString *library) {
    return sp_certificates_listed(sp_image_certificates(library), sp_listed_certificates());
}

static NSDictionary<NSString *, NSString *> *library_signed(NSString *library, NSString *flavor,
                                                             NSDictionary<NSString *, NSString *> *stamp) {
    if (!stamp) return nil;
    NSString *what = [NSString stringWithFormat:@"the Library/spgames image (%@ %@)", stamp[@"Product"], stamp[@"Version"]];
    if (library_listed(library)) {
        say([NSString stringWithFormat:@"update: %@ is signed with a certificate the app's profiles list", what]);
        return stamp;
    }
    if (!sp_identity_usable()) {
        say([NSString stringWithFormat:@"update: %@ is signed with a certificate no profile the app can see lists, and this device "
                                       @"has no identity that one lists to sign it again: loading the bundled image, keeping the update",
                                       what]);
        return nil;
    }
    double t = CFAbsoluteTimeGetCurrent();
    NSString *problem = nil;
    if (!sp_sign_with_identity(library, library, &problem)) {
        say([NSString stringWithFormat:@"update: %@ is signed with a certificate no profile lists, and signing it again failed (%@): "
                                       @"loading the bundled image", what, problem]);
        return nil;
    }
    say([NSString stringWithFormat:@"update: %@ was signed with a certificate no profile lists: signed again with this device's "
                                   @"identity in %.3f s", what, CFAbsoluteTimeGetCurrent() - t]);
    return stamp;
}

// The build a game starts with, for the Settings sheet's Games section (spstart.m): the update the device
// made (*updated YES) when the next start would load it by main's rules (retire_caught_up hasn't a bundled
// image that caught up with it to retire it, and library_signed finds its signer listed, or an identity to
// sign it again), else the bundled image's. nil without a stamp. Only reads: the start does the logging,
// signing, and deleting. A newer build the patch check would offer isn't counted until it's made.
NSDictionary<NSString *, NSString *> *sp_game_build(NSString *flavor, BOOL *updated) {
    NSDictionary<NSString *, NSString *> *bundled = stamp_beside(bundled_image(flavor), flavor);
    NSString *library = library_image(flavor);
    NSDictionary<NSString *, NSString *> *update = updated_build(library, flavor);
    *updated = update && !sp_update_caught_up(bundled, update) && (library_listed(library) || sp_identity_usable());
    return *updated ? update : bundled;
}

// For the Settings sheet too: whether the game has an image the next start would load, by the same rules,
// so a game the app has no image of (built without them) reads as not installed until the device makes one.
BOOL sp_game_has_image(NSString *flavor) {
    if ([NSFileManager.defaultManager fileExistsAtPath:bundled_image(flavor)]) return YES;
    NSString *library = library_image(flavor);
    return updated_build(library, flavor) && (library_listed(library) || sp_identity_usable());
}

// The Settings sheet's Reset Game Settings (spstart.m): deletes the game's WTF/Config.wtf (its graphics, sound,
// and other settings) and its render scale's first-run marker, so the next start seeds both as on a first
// launch (default_render_scale, skip_intro). WTF/Account/ (keybindings, macros, addons' SavedVariables) is
// kept. A line for the log.
NSString *sp_game_reset(NSString *flavor) {
    NSString *home = NSHomeDirectory();
    NSArray<NSString *> *paths = @[
        [home stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_/WTF/Config.wtf", flavor]],
        [home stringByAppendingPathComponent:[@"Library/sprenderscale-" stringByAppendingString:flavor]],
    ];
    NSMutableArray<NSString *> *deleted = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSString *path in paths) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        NSError *error = nil;
        if ([NSFileManager.defaultManager removeItemAtPath:path error:&error]) [deleted addObject:path.lastPathComponent];
        else [failed addObject:[NSString stringWithFormat:@"%@ (%@)", path.lastPathComponent, error.localizedDescription]];
    }
    if (failed.count) return [NSString stringWithFormat:@"reset %@: couldn't delete %@", flavor, [failed componentsJoinedByString:@", "]];
    return [NSString stringWithFormat:@"reset %@ (Settings): deleted %@; WTF/Account kept", flavor,
                                      deleted.count ? [deleted componentsJoinedByString:@" and "] : @"nothing (already the defaults)"];
}

// The test hook $SP_ASSEMBLE_TEST=<flavor>: assembles the client image (spassemble.m) from the newer
// build's slice the patch check kept (Library/spslice/<flavor>.arm64, sppatch.m) into tmp/wow-<flavor>,
// logs it (assemble: lines: build, time, size, the image's SHA-256 to compare with the companion's for the
// same slice, the retype's changes), and loads nothing: the launch ends there.
static void assemble_test(NSString *flavor) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/spslice"];
    NSString *slicePath = [dir stringByAppendingPathComponent:[flavor stringByAppendingString:@".arm64"]];
    NSDictionary<NSString *, NSString *> *stamp =
        build_info_row([dir stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]], flavor_entry(flavor)[@"product"]);
    NSData *slice = [NSData dataWithContentsOfFile:slicePath options:NSDataReadingMappedIfSafe error:nil];
    NSString *map = [NSString stringWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"rewrite-map.txt"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!slice || !stamp) { say([NSString stringWithFormat:@"assemble: no kept slice for %@ (Library/spslice/)", flavor]); return; }
    if (!map) { say(@"assemble: the app has no rewrite-map.txt"); return; }
    uint32_t platform, minOS;
    sp_launch_build_version(&platform, &minOS);
    double t = CFAbsoluteTimeGetCurrent();
    NSArray<NSString *> *changes = nil;
    NSString *problem = nil;
    NSData *image = sp_assemble(slice, map, platform, minOS, &changes, &problem);
    double seconds = CFAbsoluteTimeGetCurrent() - t;
    if (!image) { say([NSString stringWithFormat:@"assemble: %@ %@ refused: %@", stamp[@"Product"], stamp[@"Version"], problem]); return; }
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"wow-" stringByAppendingString:flavor]];
    if (![image writeToFile:out atomically:YES]) { say([@"assemble: couldn't write " stringByAppendingString:out]); return; }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(image.bytes, (CC_LONG)image.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    say([NSString stringWithFormat:@"assemble: %@ %@ from Library/spslice/%@.arm64 into tmp/wow-%@: %.1f MB in %.3f s, platform %u, "
                                   @"minimum OS %u.%u, sha256 %@", stamp[@"Product"], stamp[@"Version"], flavor, flavor,
                                   image.length / 1e6, seconds, platform, minOS >> 16, (minOS >> 8) & 0xFF, hex]);
    for (NSString *c in changes) say([@"assemble: retype: " stringByAppendingString:c]);
}

// The test hook $SP_SIGN_TEST=<path in the app's home>: signs a copy of that image (a fixture of our own;
// apps/client/push-identity.sh's comment says how it gets there) with the device's identity (spsign.m) into
// tmp/, then dlopens it, and logs sign: lines (time, size, and dlopen's verdict). Nothing in it is called:
// a fixture signed with a certificate the device doesn't trust is refused with an error, which is the point.
static void sign_test(NSString *relative) {
    NSString *source = [NSHomeDirectory() stringByAppendingPathComponent:relative];
    NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"spsigned-" stringByAppendingString:relative.lastPathComponent]];
    double t = CFAbsoluteTimeGetCurrent();
    NSString *problem = nil;
    BOOL ok = sp_sign_with_identity(source, dest, &problem);
    double seconds = CFAbsoluteTimeGetCurrent() - t;
    if (!ok) { say([NSString stringWithFormat:@"sign: %@ not signed: %@", relative, problem]); return; }
    unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:dest error:nil].fileSize;
    say([NSString stringWithFormat:@"sign: %@ signed into tmp/%@ in %.3f s, %.1f MB", relative, dest.lastPathComponent,
                                   seconds, size / 1e6]);
    t = CFAbsoluteTimeGetCurrent();
    void *h = dlopen(dest.fileSystemRepresentation, RTLD_NOW);
    say(h ? [NSString stringWithFormat:@"sign: dlopen loaded it in %.3f s", CFAbsoluteTimeGetCurrent() - t]
          : [NSString stringWithFormat:@"sign: dlopen refused it: %s", dlerror()]);
}

// As Battle.net launches each flavor, less the launch credentials it adds (flavors.plist).
static NSArray<NSString *> *battle_net_arguments(NSString *flavor) {
    return flavor_entry(flavor)[@"arguments"] ?: @[@"-launcherlogin"];
}

// A launch from the home screen (or an on-device debugger) has no arguments, but the client needs the ones
// Battle.net gives the Mac client (-launcherlogin, -uid, game mode), which the companion passes on. So a
// launch with arguments saves them per flavor (Library/splaunch-args-<flavor>, one per line), and a launch
// with none replays the last saved, else Battle.net's. Only their count is logged. -launcherlogin is the
// one that matters: without it the client reads login.txt but doesn't sign in from it, and stops at its
// login screen (docs/research.md). A relayed token isn't among them (it's Library/spnetbattle.plist), so
// a replay carries no stale credential.
static void launch_arguments(NSString *flavor, int *argc, char ***argv) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
                      [@"Library/splaunch-args-" stringByAppendingString:flavor]];
    if (*argc > 1) {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < *argc; i++) [args addObject:@((*argv)[i])];
        [[args componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    NSString *saved = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSArray<NSString *> *args = saved.length ? [saved componentsSeparatedByString:@"\n"] : battle_net_arguments(flavor);
    char **v = calloc(args.count + 2, sizeof *v);  // the client keeps argv for the process's life
    v[0] = (*argv)[0];
    for (NSUInteger i = 0; i < args.count; i++) v[i + 1] = strdup(args[i].UTF8String);
    *argc = (int)args.count + 1;
    *argv = v;
    say([NSString stringWithFormat:saved.length ? @"no arguments: replaying the %lu saved for this flavor"
                                                : @"no arguments, and none saved: using Battle.net's %lu for this flavor",
                                   (unsigned long)args.count]);
}

// Why the client can't be loaded, on the scene (the AppKit shim's sp_uikit_fail, which starts UIKit for it
// on visionOS and doesn't return), and the launch ends there.
__attribute__((noreturn)) static void fail_launch(NSString *problem) {
    // One line: the companion reads it off the console (ClientLauncher.Marker.problem).
    say([@"can't prepare the client: " stringByAppendingString:[problem stringByReplacingOccurrencesOfString:@"\n\n" withString:@" "]]);
    NSString *appkit = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libspAppKit.dylib"];
    void *h = dlopen(appkit.fileSystemRepresentation, RTLD_NOW);
    void (*fail)(const char *) = h ? (void (*)(const char *))dlsym(h, "sp_uikit_fail") : NULL;
    if (fail) fail(problem.UTF8String);
    say([NSString stringWithFormat:@"no UIKit to show it: %s", dlerror()]);
    exit(1);
}

int main(int argc, char **argv) {
    // The libSystem shim first: its initializer starts the Documents/spconsole.log tee of stderr, which
    // otherwise starts only when the client loads (no other shim links it). A launch from the home
    // screen has no devicectl console, so without this everything before the client (the helper's
    // status, a disk image mount, the headset's pairing screen, a "can't prepare" problem) was lost.
    // Safe this early: its path redirect is set up on first use, by the client, after SP_SYSTEM_FLAVOR,
    // and only the client is bound to it.
    NSString *sys = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libspSystem.dylib"];
    if (!dlopen(sys.fileSystemRepresentation, RTLD_NOW)) say([NSString stringWithFormat:@"no console log: %s", dlerror()]);
    delete_listed();
    write_free_space();
    NSString *forgot = sp_identity_forget_if_asked();
    if (forgot) say(forgot);
    NSString *imported = sp_identity_import();
    if (imported) say(imported);
    say(sp_identity_describe());
    NSString *appleToken = sp_apple_token_import();
    if (appleToken) say(appleToken);
    say(sp_apple_token_describe());
    NSString *signTest = NSProcessInfo.processInfo.environment[@"SP_SIGN_TEST"];
    if (signTest.length) {
        sign_test(signTest);
        return 0;
    }
    NSString *assemble = NSProcessInfo.processInfo.environment[@"SP_ASSEMBLE_TEST"];
    if (assemble.length) {
        assemble_test(assemble);
        return 0;
    }
    NSString *dir = NSBundle.mainBundle.bundlePath;
    // The games: the app's images (wow-<flavor>), or in an app built with none every game flavors.plist
    // lists, the ones the device hasn't made an image of (Library/spgames) installable here (sp_games). In
    // flavors.plist's order (the start screen's, and its first is the default).
    NSMutableArray<NSString *> *bundledGames = [NSMutableArray array], *madeGames = [NSMutableArray array], *order = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([f hasPrefix:@"wow-"]) [bundledGames addObject:[f substringFromIndex:4]];
    for (NSDictionary *e in flavor_entries())
        if ([e[@"id"] isKindOfClass:NSString.class]) [order addObject:e[@"id"]];
    // Made here, and loadable by the rules the start below applies (sp_game_has_image): one whose signer no
    // profile lists, with no identity to sign it again, reads as installable, and its install says why not.
    if (!bundledGames.count)
        for (NSString *f in order)
            if (sp_game_has_image(f)) [madeGames addObject:f];
    NSSet<NSString *> *installable = nil;
    NSArray<NSString *> *flavors = sp_games(order, bundledGames, madeGames, &installable);
    if (!flavors.count) { say(@"no games: no wow-<flavor> in the bundle, and none in flavors.plist"); return 1; }
    if (!bundledGames.count)
        say([NSString stringWithFormat:@"no client images in the app: %lu games made on this device, %lu to install here",
                                       (unsigned long)madeGames.count, (unsigned long)installable.count]);
    // Before the start screen, which can wait a long time: a sign-in left in any game's folder shouldn't.
    sp_login_clear(flavors);
    void (^pump)(double) = ^(double seconds) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true); };
#if !TARGET_OS_VISION
    // iOS's 20 s launch watchdog counts the wait on the start screen, the helper's work (a disk image mount
    // takes seconds) and the prepare stop: show the scene first (spuikit.m), and keep it running while
    // waiting. Safe before SP_SYSTEM_FLAVOR: only the client's own calls read it.
    void (^ui)(double) = sp_launch_uikit();
    if (ui) pump = ui;
#endif
    NSString *saved = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/splaunch-flavor"];
    NSString *flavor, *bundled, *library, *path = nil;
    NSDictionary<NSString *, NSString *> *bundledStamp, *libraryStamp;
    // Until a game with an image to load is picked: a pick of one the device has to install (an app built
    // without images) installs it first, and one that can't be installed goes back to the start screen
    // (after its screen says why), or, when the start screen didn't pick it, stops the launch with why.
    for (;;) {
        flavor = NSProcessInfo.processInfo.environment[@"SP_LAUNCH_FLAVOR"];
        BOOL picked = NO;
        if (!flavor.length) picked = (flavor = sp_pick_flavor(flavors, installable, &pump)).length > 0;
        if (!flavor.length) flavor = [NSString stringWithContentsOfFile:saved encoding:NSUTF8StringEncoding error:nil];
        flavor = [flavor stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![flavors containsObject:flavor]) flavor = flavors[0];
        say([NSString stringWithFormat:@"flavors %@, running %@", [flavors componentsJoinedByString:@" "], flavor]);
        // An app without this game's image (built without images) has only what the device made.
        bundled = [NSFileManager.defaultManager fileExistsAtPath:bundled_image(flavor)] ? bundled_image(flavor) : nil;
        library = library_image(flavor);
        bundledStamp = bundled ? image_build(bundled, flavor) : nil;
        retire_caught_up(flavor, bundledStamp);
        libraryStamp = library_signed(library, flavor, updated_build(library, flavor));
        if (bundled || libraryStamp) break;
        // Nothing to load: the device installs the game itself, from Blizzard's CDN, in the game's region (its
        // region file, chosen in Settings or by an earlier install, else the device's region: sp_game_region).
        NSString *problem = nil;
        path = sp_patch_install(flavor, sp_game_region_now(flavor), picked, &pump, &problem);
        if (path) {
            libraryStamp = image_build(path, flavor);
            break;
        }
        if (!picked) fail_launch(problem);
        say(@"install: back to the start screen");
    }
    [flavor writeToFile:saved atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // The game's region, once, for the rest of the start (an install just now wrote its region file).
    NSDictionary<NSString *, NSString *> *choice = sp_game_region_now(flavor);
    say([NSString stringWithFormat:@"region: %@ plays in %@ (%@), text %@, speech %@, from %@", flavor, choice[@"Region"],
                                   sp_region_name(choice[@"Region"]), choice[@"Text"], choice[@"Speech"], choice[@"Source"]]);
    region_sync(flavor, choice);
    game_region(flavor, choice);
    default_render_scale(flavor);
    skip_intro(flavor);
    // The addons the app carries, into the game's folder before the client loads (sp_addons_place): SPMovie
    // everywhere, SPHover on the headset. The device's own copy, so a game it installed has them too.
    NSString *addons = nil;
    sp_addons_place([dir stringByAppendingPathComponent:@"addons"],
                    [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_", flavor]],
                    TARGET_OS_VISION, &addons);
    say(addons);
    launch_arguments(flavor, &argc, &argv);
    // Whether a newer build is out than the image's (sppatch.m), which also picks the image: the bundled one
    // or the one an update on the device made, maybe just now (its .build.info row is written once it has
    // loaded: build_info_for_image). Before the sign-in, so nobody signs in to then
    // be told, and before the helper attaches. It never stops the launch. Not after an install just now:
    // that image is the current build.
    if (!path) {
        path = sp_patch_check(flavor, bundled, bundledStamp, library, libraryStamp, choice, &pump);
        if ([path isEqual:library]) libraryStamp = image_build(library, flavor);
    }
    // A Battle.net launcher token the companion relayed (Play with My Mac's Battle.net) and the client
    // hasn't imported yet: just before the client loads, the AppKit shim imports it into net.battle and
    // deletes the file (sp_net_battle_import, below). Only here, not when UIKit starts (on iOS that's
    // before this check), so the file is still there to see. Not -launcherlogin, which every launch carries
    // now (launch_arguments). One left by a launch that stopped before the client loaded is the next
    // launch's too (Retry Launch counts on that), and then it's gone, so it outlives at most one launch.
    BOOL token = [NSFileManager.defaultManager fileExistsAtPath:
                  [NSHomeDirectory() stringByAppendingPathComponent:@"Library/spnetbattle.plist"]];

    setenv("SP_SYSTEM_FLAVOR", [NSString stringWithFormat:@"_%@_", flavor].UTF8String, 1);
    NSString *appkit = [dir stringByAppendingPathComponent:@"Frameworks/libspAppKit.dylib"];
    // Game data a copy left incomplete first, so nobody signs in to then be told. Then the sign-in, so the
    // person isn't asked while the helper holds the debugger. Then the on-device JIT helper attaches before
    // the client loads (spjit.m). If any can't, the scene says why (starting UIKit for it on visionOS) and
    // the client isn't loaded: its prepare would fail.
    NSString *problem = copy_unfinished();
    NSMutableData *login = problem ? nil : sp_login_prepare(token, &pump, &problem);
    if (!problem && NSProcessInfo.processInfo.environment[@"SP_PROFILES_DRILL"].length) problem = profiles_drill(pump);
    // The app's own profiles, renewed from Apple when they're near their end (spapple.m): after the sign-in and
    // before the attach, since the helper installs them through the same tunnel. It never stops the launch.
    if (!problem) sp_profiles_renew(pump);
    if (!problem) problem = sp_jit_attach(pump);
    if (problem) fail_launch(problem);
    if (login) sp_login_write(flavor, login);  // on failure it says so; the token or the game's login screen is left
    // The loading screen (the AppKit shim's sploading.m), from here until the client's first frame, instead
    // of black: the game's name, then the data setup's progress or "Loading…". On visionOS it goes up when
    // the client brings UIKit up.
    // Its title is in Goodmountain, which the shim finds by name: registered here, for the process, as the
    // start screen does (spstart.m), since a launch that names a game never shows the start screen.
    sp_face(1, UIFontTextStyleBody, 1, UITraitCollection.currentTraitCollection);
    void *ak = dlopen(appkit.fileSystemRepresentation, RTLD_NOW);
    void (*loading)(const char *) = ak ? (void (*)(const char *))dlsym(ak, "sp_uikit_loading") : NULL;
    if (loading) loading(sp_flavor_name(flavor).UTF8String);
    else say([NSString stringWithFormat:@"no loading screen: %s", dlerror()]);
    if (token) {
        void (*import)(void) = ak ? (void (*)(void))dlsym(ak, "sp_net_battle_import") : NULL;
        if (import) import();
        else say([NSString stringWithFormat:@"login: can't import the relayed token: %s", dlerror()]);
    }
    double t = CFAbsoluteTimeGetCurrent();
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW);
    if (!h && [path isEqual:library]) {
        // An updated image the system won't load (its signature, say): it's deleted, so the next start offers
        // the update again, and the bundled image loads, with its own .build.info row left as it is. With no
        // bundled image (a game installed on the device), the next start offers to install it again.
        NSString *refused = @(dlerror() ?: "no reason");
        say([NSString stringWithFormat:@"update: the updated image didn't load (%@): deleted, %@", refused,
                                       bundled ? [NSString stringWithFormat:@"loading the bundled %@ instead", bundledStamp[@"Version"]]
                                               : @"and the app has no image of the game to load instead"]);
        [NSFileManager.defaultManager removeItemAtPath:[library.stringByDeletingLastPathComponent stringByAppendingPathComponent:
                                                        [@"spbuild-" stringByAppendingString:flavor]] error:nil];
        [NSFileManager.defaultManager removeItemAtPath:library error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[library.stringByDeletingLastPathComponent stringByAppendingPathComponent:
                                                        [@"spbuildinfo-" stringByAppendingString:flavor]] error:nil];
        if (!bundled)
            fail_launch([NSString stringWithFormat:@"%@ %@, made on this %@, couldn't be loaded, so it's deleted.\n\nOpen "
                                                   @"Slashplayed again to install it again.", sp_flavor_name(flavor),
                                                   libraryStamp[@"Version"], sp_device_noun()]);
        sp_patch_refused(flavor, libraryStamp[@"Version"], bundledStamp[@"Version"], &pump);
        path = bundled;
        t = CFAbsoluteTimeGetCurrent();
        h = dlopen(path.fileSystemRepresentation, RTLD_NOW);
    }
    if (!h) { say([NSString stringWithFormat:@"dlopen: %s", dlerror()]); return 1; }
    // No microphone: the app has no NSMicrophoneUsageDescription (voice chat can't work on the device), so a
    // capture permission request would get the process killed. The AudioToolbox shim makes AVCaptureDevice
    // answer "denied"; only now, with every image the client links initialized (spaudiotoolbox.m says why).
    void (*no_mic)(void) = (void (*)(void))dlsym(h, "sp_audio_no_microphone");
    if (no_mic) no_mic();
    else say([NSString stringWithFormat:@"audio: can't refuse the microphone (%s): voice chat settings may stop the app", dlerror()]);
    say([NSString stringWithFormat:@"update: loaded the %@ image (%.1f s, the prepare included)",
                                   [path isEqual:library] ? @"updated (Library/spgames)" : @"bundled", CFAbsoluteTimeGetCurrent() - t]);
    // The game data's row for the build that just loaded, before the client reads it.
    // An Update just now may have settled the region file's languages against its build (sppatch.m): read again.
    if ([path isEqual:library]) build_info_for_image(flavor, library, libraryStamp, sp_game_region_now(flavor));
    // The client's header (an executable exports it), and from it the entry point.
    const struct mach_header_64 *mh = dlsym(h, "_mh_execute_header");
    if (!mh) { say(@"the client exports no __mh_execute_header"); return 1; }
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_MAIN) {
            int (*client_main)(int, char **) = (void *)((const char *)mh + ((const struct entry_point_command *)lc)->entryoff);
            return client_main(argc, argv);
        }
    say(@"the client has no LC_MAIN");
    return 1;
}
