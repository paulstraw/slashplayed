// The device app's main executable. Each game's client is its unchanged arm64 slice in the app's data
// container, Library/spgames/wow-<flavor> (an MH_EXECUTE, unsigned: the Mac companion copies it there, with
// its build's stamp spbuild-<flavor>, its .build.info row spbuildinfo-<flavor>, and spsource-<flavor>, the
// one word for where it came from; or the device fetches it, sppatch.m). The launcher picks a game, tells the
// libSystem shim which Documents/ folder is its install root ($SP_SYSTEM_FLAVOR), gets the on-device JIT
// helper attached (spjit.m; on failure the scene says why and the client isn't loaded), and loads the client
// with spguest, its own loader (spguestlaunch.m, spguest.c): visionOS won't exec or spawn another
// executable, and dyld won't dlopen an MH_EXECUTE. Nothing signs the client, so updating or installing a game
// on the device needs no signing identity, and a game patch never means a new app.
// The flavor is $SP_LAUNCH_FLAVOR (the companion's Play and run.sh pass it), else the one picked on the start
// screen (spstart.m, every other launch, even with one game; its gear opens the app's Settings, which show
// each game's build and where it came from, sp_game_build, and reset its settings, sp_game_reset), else the
// last one run, else the first. flavors.plist, in the app, has their names and order: the start screen offers
// every game it lists, the ones the device has nothing of as "Install <game>" (sp_games).
// First it deletes the game files the Mac companion listed in Library/spdelete.txt (devicectl can't
// delete): CASC index files a patch replaced, before the client opens the indexes, and archives no
// ticked game uses. Then it writes the space left on the device to Library/spfree.txt, for the companion's
// free space and its check that a copy fits (write_free_space). It retires a Library/spgames file that isn't
// a client spguest can load (an image an older Slashplayed assembled and signed there, an MH_BUNDLE, or a cut
// short copy: sp_slice_retire, which also deletes what an older one's signing left beside it), and deletes the
// signing identity an older one kept (forget_identity). Before the
// start screen, a leftover login.txt in any game's folder is deleted (splogin.m). Once the flavor is picked: a
// game with game data but no client (an upgrade, whose images were retired) gets its data's own build of the
// client from Blizzard's CDN ("Getting <game> ready", sppatch.m), and one with neither is installed. On an
// iPhone the game's render scale gets its first-run default (default_render_scale), a launch with no
// arguments gets the last ones saved for the flavor, else Battle.net's (launch_arguments), the client's
// build stamp is logged against the game data's (image_build), and the patch service is asked whether a
// newer build is out (sppatch.m: a screen says so, and whether this Slashplayed can run it, from the new
// client's imports; then Play Anyway, or Update, which puts the new build's slice in place). A kept newer
// build's slice that the client has since caught up with is deleted (retire_caught_up). The private hooks
// spguest needs are checked before the start screen (sp_guest_hooks_problem), so nothing is downloaded for a
// load that can't work, and the file before the sign-in (sp_guest_preflight), so a launch that can't load
// says why first. Before the helper attaches, splogin.m decides how the game signs in (the saved
// Battle.net sign-in, asked for once, or a token the companion relayed), and writes login.txt just before the
// client loads. From then until the client's first frame, the scene shows a loading screen (the AppKit
// shim's sp_uikit_loading).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#import <Security/Security.h>
#import "spcdn.h"  // sp_table_row, sp_build_info_for_image, sp_flavor_info, sp_slice_retire

static void say(NSString *s) {
    fprintf(stderr, "[sp:launch] %s\n", s.UTF8String);
}

void sp_launch_say(NSString *s) { say(s); }  // spjit.m, sppair.m, and spvpn.m log through it
NSString *sp_jit_attach(void (^pump)(double));  // spjit.m
NSString *sp_device_noun(void);  // spjit.m
NSString *sp_guest_hooks_problem(void);  // spguestlaunch.m
NSString *sp_guest_preflight(NSString *path);  // spguestlaunch.m
int sp_guest_main(NSString *path, int argc, char **argv, NSString **problem);
void sp_login_clear(NSArray<NSString *> *flavors);  // splogin.m
NSMutableData *sp_login_prepare(BOOL token, void (^*pump)(double), NSString **problem);
BOOL sp_login_write(NSString *flavor, NSMutableData *bytes);
UIFont *sp_face(CGFloat size, UIFontTextStyle style, CGFloat maximum, UITraitCollection *traits);  // spstart.m
NSString *sp_pick_flavor(NSArray<NSString *> *flavors, NSSet<NSString *> *installable, void (^*pump)(double));  // spstart.m
NSDictionary<NSString *, NSString *> *sp_patch_check(NSString *flavor, NSString *image, NSDictionary<NSString *, NSString *> *stamp,
                                                    NSDictionary<NSString *, NSString *> *choice, void (^*pump)(double));  // sppatch.m
NSString *sp_patch_install(NSString *flavor, NSDictionary<NSString *, NSString *> *choice,
                           NSDictionary<NSString *, NSString *> *_Nullable data, BOOL back, void (^*pump)(double), NSString **problem);

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

// The game folder's .flavor.info, which names its product (sp_flavor_info), as Battle.net and the companion
// write it, every start before the client loads. Classic Era, TBC Anniversary, and MoP Classic are one client
// (as are Retail and Forever), and it reads the file to know which game it is: without it, it read another
// game's static data, and TBC Anniversary stopped on the loading screen with #134, "Invalid schema
// WOWSTATIC_5_5_4_… for Table StartupFiles" (MoP Classic's; the iPhone, 2026-10-31 and 11-07). The companion
// sends it only for the games ticked for the device, so a game whose image came another way (a dev build has
// them all) had none, and nothing put it back. Written only when it isn't already this.
static void flavor_info(NSString *flavor) {
    NSString *product = flavor_entry(flavor)[@"product"], *text = sp_flavor_info(product);
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_", flavor]];
    NSString *info = [folder stringByAppendingPathComponent:@".flavor.info"];
    if ([[NSString stringWithContentsOfFile:info encoding:NSUTF8StringEncoding error:nil] isEqual:text]) return;
    BOOL had = [NSFileManager.defaultManager fileExistsAtPath:info];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    say([text writeToFile:info atomically:YES encoding:NSUTF8StringEncoding error:nil]
            ? [NSString stringWithFormat:@"flavor: wrote _%@_/.flavor.info (%@), which %@", flavor, product,
                                         had ? @"named another product" : @"was missing"]
            : [NSString stringWithFormat:@"flavor: couldn't write _%@_/.flavor.info: the game may not start", flavor]);
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

static NSString *games_path(NSString *name, NSString *flavor) {
    return home_path([NSString stringWithFormat:@"Library/spgames/%@%@", name, flavor]);
}

// Where the game's client came from (Library/spgames/spsource-<flavor>, one word): "mac" (the companion
// copied it), "updated" or "installed" (the device fetched it: sppatch.m), or nil without one.
static NSString *client_source(NSString *flavor) {
    NSString *word = [read_text(games_path(@"spsource-", flavor)) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return word.length ? word : nil;
}

static NSDictionary<NSString *, NSString *> *data_build(NSString *flavor);

// The game's region and languages now (sp_game_region), and "Device" "1" when the device decides them, "0"
// when the Mac does. The device decides for a game it installs itself: one with a region file (an install
// writes it, and so do Settings' changes, which need the device deciding), or with no game data yet (its
// install is the device's), unless the Mac has copied its client (spsource-<flavor> "mac"), which makes it the
// Mac's game, as a bundled image did. Game data with no region file is the Mac's copy (or an older
// Slashplayed's update of the Mac's game), whose .build.info row says its region. Reads the
// region file, the client's kept row and stamp, the game data's .build.info, and the device's region and
// languages; logs nothing. $SP_REGION_COUNTRY (an ISO country code) and $SP_REGION_LANGUAGES (BCP 47,
// comma-separated) stand in for the device's, for tests (run.sh passes them): a test device's own region is
// the owner's.
NSArray<NSString *> *sp_device_languages(void) {  // sppatch.m too
    NSString *test = NSProcessInfo.processInfo.environment[@"SP_REGION_LANGUAGES"];
    return test.length ? [test componentsSeparatedByString:@","] : NSLocale.preferredLanguages;
}

NSDictionary<NSString *, NSString *> *sp_game_region_now(NSString *flavor) {
    NSString *test = NSProcessInfo.processInfo.environment[@"SP_REGION_COUNTRY"];
    NSString *country = test.length ? test : [NSLocale.currentLocale objectForKey:NSLocaleCountryCode];
    BOOL device = ![client_source(flavor) isEqual:@"mac"] &&
                  ([NSFileManager.defaultManager fileExistsAtPath:region_path(flavor)] || !data_build(flavor));
    NSMutableDictionary *choice = [sp_game_region(
        flavor_entry(flavor)[@"product"] ?: @"", device, read_text(region_path(flavor)), read_text(games_path(@"spbuildinfo-", flavor)),
        read_text(games_path(@"spbuild-", flavor)), read_text(home_path(@"Documents/.build.info")), country,
        sp_device_languages()) mutableCopy];
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

// The game's client: its unchanged slice, which spguest loads (spguestlaunch.m).
static NSString *library_image(NSString *flavor) { return games_path(@"wow-", flavor); }

// The client and its stamp, when both are there: the stamp is written last (the companion's copy and
// sppatch.m's update), so a client with one is whole. nil otherwise.
static NSDictionary<NSString *, NSString *> *client_build(NSString *flavor) {
    NSString *image = library_image(flavor);
    return [NSFileManager.defaultManager fileExistsAtPath:image] ? stamp_beside(image, flavor) : nil;
}

// The game data's .build.info row for the game (the Mac's copy of it, or an earlier install's), when it names
// a build: what a game with data and no client gets its client for (sppatch.m's sp_patch_install).
static NSDictionary<NSString *, NSString *> *data_build(NSString *flavor) {
    NSDictionary<NSString *, NSString *> *row = build_info_row(home_path(@"Documents/.build.info"), flavor_entry(flavor)[@"product"]);
    return row[@"Build Key"].length && row[@"CDN Key"].length ? row : nil;
}

// The build the client is: its stamp, spbuild-<flavor> beside wow-<flavor> (the companion's
// ClientAssembly.Stamp, seed-client.sh, and sppatch.m write it: a one-row table shaped like .build.info). Logged against the game data's
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

// The game data's .build.info row for the client (Library/spgames/wow-<flavor>), just before spguest loads it:
// the row kept beside it (spgames/spbuildinfo-<flavor>: sppatch.m's, or the companion's copy's) when
// Documents/.build.info's isn't that build's. On every launch: one that put the client there may have stopped
// before the client loaded, and the game data may have been emptied under it. Without the row, an install in
// an empty container streams with nothing naming its build, and the client stops with #134, "Invalid schema …
// for Table StartupFiles" (issue #36). For a game whose region the device decides (`choice` from its region
// file), the row is in that region too, and is written again when a Settings change left it in another, so
// the old row's region doesn't come back. Versions only.
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

// A newer build's slice the patch check kept (Library/spslice/, sppatch.m) once the client has caught up
// with it (sp_update_caught_up: the same Build Key or version, or a later one), as after the companion
// copied that build's client or a later one: it would only be fetched for nothing. The stamp first, so a
// slice left behind is never taken for its build. The patch drill ($SP_PATCH_DRILL, sppatch.m) keeps it:
// its "newer" build is the client's own, so it always counts as caught up, and every drill launch fetched
// the same 45 MB again (the rc9 run). The next start without the drill retires it.
static void retire_caught_up(NSString *flavor, NSDictionary<NSString *, NSString *> *stamp) {
    if (NSProcessInfo.processInfo.environment[@"SP_PATCH_DRILL"].length) return;
    NSString *product = flavor_entry(flavor)[@"product"], *home = home_path(@"Library/spslice");
    NSString *keptStamp = [home stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]];
    NSDictionary<NSString *, NSString *> *kept = build_info_row(keptStamp, product);
    if (!sp_update_caught_up(stamp, kept)) return;
    NSString *file = [home stringByAppendingPathComponent:[flavor stringByAppendingString:@".arm64"]];
    unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil].fileSize;
    [NSFileManager.defaultManager removeItemAtPath:keptStamp error:nil];
    [NSFileManager.defaultManager removeItemAtPath:file error:nil];
    say([NSString stringWithFormat:@"update: retired Library/spslice %@ %@ (%.1f MB): the client is %@", product, kept[@"Version"],
                                   size / 1e6, stamp[@"Version"]]);
}

// The signing identity Slashplayed 1.4 and earlier kept for Update Games on This Device (its keychain items,
// under their own service, and what the companion pushed or the launcher wrote beside them), deleted at
// every start where there is any: updates and installs on the device sign nothing now. Not Library/spidentity,
// the small identity file login needs from the Mac. Names only in the log, never what they held. Kept for two
// releases after 1.5, then removed with the files' names.
// A credential's file overwritten with zeros, then deleted (CLAUDE.md: "zeroed and deleted"), as spsign.m did for
// the pushed .p12 and its password. Whether there was one.
static BOOL wipe(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY);
    if (fd < 0) return NO;
    struct stat st;
    if (!fstat(fd, &st)) {
        static const char zero[4096];
        for (off_t o = 0; o < st.st_size; o += sizeof zero) pwrite(fd, zero, (size_t)MIN((off_t)sizeof zero, st.st_size - o), o);
        fsync(fd);
    }
    close(fd);
    unlink(path.fileSystemRepresentation);
    return YES;
}

static void forget_identity(void) {
    NSMutableArray<NSString *> *gone = [NSMutableArray array];
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                             (__bridge id)kSecAttrService: @"Slashplayed signing identity"});
    if (st == errSecSuccess) [gone addObject:@"its keychain items"];
    else if (st != errSecItemNotFound) say([NSString stringWithFormat:@"identity: the old signing identity's keychain items weren't deleted (OSStatus %d)", (int)st]);
    // The .p12 and its password are zeroed first; the rest (the identity's description, the forget request, its
    // profile) are no secret.
    for (NSString *name in @[@"spidentity.p12", @"spidentity.pass"])
        if (wipe(home_path([@"Library" stringByAppendingPathComponent:name]))) [gone addObject:[@"Library/" stringByAppendingString:name]];
    for (NSString *name in @[@"spidentity.txt", @"spidentity.forget", @"spprofile.mobileprovision"])
        if ([NSFileManager.defaultManager removeItemAtPath:home_path([@"Library" stringByAppendingPathComponent:name]) error:nil])
            [gone addObject:[@"Library/" stringByAppendingString:name]];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"sp_identity_forgotten"];
    if (gone.count)
        say([NSString stringWithFormat:@"identity: deleted the signing identity an older Slashplayed kept for game updates (%@)",
                                       [gone componentsJoinedByString:@", "]]);
}

// The build a game starts with, for the Settings sheet's Games section (spsettings.swift): its client's stamp,
// and *source where the client came from (client_source: "mac", "updated", "installed", or nil); nil
// without a client. Only reads: the start does the retiring and fetching.
NSDictionary<NSString *, NSString *> *sp_game_build(NSString *flavor, NSString **source) {
    *source = client_source(flavor);
    return client_build(flavor);
}

// For the start screen and the Settings sheet too: whether the device has the game, so it plays without an
// install: its client, or game data whose client the next start gets for it (sp_patch_install).
BOOL sp_game_has_image(NSString *flavor) { return client_build(flavor) || data_build(flavor); }

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
    forget_identity();
    NSString *dir = NSBundle.mainBundle.bundlePath;
    // The games: every one flavors.plist lists, in its order (the start screen's, and its first is the
    // default); the ones the device has nothing of read as installable (sp_games). A client in Library/spgames
    // that spguest can't load (an image an older Slashplayed made there, or a copy cut short) is retired first,
    // so the game reads as one to get ready, or to install.
    NSMutableArray<NSString *> *madeGames = [NSMutableArray array], *order = [NSMutableArray array];
    for (NSDictionary *e in flavor_entries())
        if ([e[@"id"] isKindOfClass:NSString.class]) [order addObject:e[@"id"]];
    for (NSString *f in order) {
        NSString *retired = sp_slice_retire(home_path(@"Library/spgames"), f, flavor_entry(f)[@"product"] ?: f);
        if (retired) say([@"update: " stringByAppendingString:retired]);
        if (sp_game_has_image(f)) [madeGames addObject:f];
    }
    NSSet<NSString *> *installable = nil;
    NSArray<NSString *> *flavors = sp_games(order, madeGames, &installable);
    if (!flavors.count) { say(@"no games: none in flavors.plist"); return 1; }
    say([NSString stringWithFormat:@"games: %lu on this device, %lu to install here", (unsigned long)madeGames.count,
                                   (unsigned long)installable.count]);
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
    // The private hooks spguest needs (sp_guest_hooks_problem) before anything below can download a game for a
    // load that would fail anyway: a new OS that took one away says so now.
    NSString *hooks = sp_guest_hooks_problem();
    if (hooks) fail_launch(hooks);
    NSString *saved = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/splaunch-flavor"];
    NSString *flavor, *library;
    NSDictionary<NSString *, NSString *> *stamp;
    BOOL installed = NO;
    // Until a game with a client to load is picked: a pick of one with no client gets it first (its data's own
    // build when it has game data, else the current build), and one that can't go back to the start screen
    // (after its screen says why), or, when the start screen didn't pick it, stops the launch with why.
    for (;;) {
        flavor = NSProcessInfo.processInfo.environment[@"SP_LAUNCH_FLAVOR"];
        BOOL picked = NO;
        if (!flavor.length) picked = (flavor = sp_pick_flavor(flavors, installable, &pump)).length > 0;
        if (!flavor.length) flavor = [NSString stringWithContentsOfFile:saved encoding:NSUTF8StringEncoding error:nil];
        flavor = [flavor stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![flavors containsObject:flavor]) flavor = flavors[0];
        say([NSString stringWithFormat:@"flavors %@, running %@", [flavors componentsJoinedByString:@" "], flavor]);
        library = library_image(flavor);
        stamp = client_build(flavor) ? image_build(library, flavor) : nil;
        if (stamp) break;
        // No client: the device gets it itself, from Blizzard's CDN. With game data (the Mac copied it, or an
        // upgrade retired the image an older Slashplayed made), the data's own build, in its region; with none,
        // the current build in the game's region (its region file, chosen in Settings or by an earlier install,
        // else the device's region: sp_game_region).
        NSString *problem = nil;
        NSDictionary<NSString *, NSString *> *data = data_build(flavor);
        NSString *path = sp_patch_install(flavor, sp_game_region_now(flavor), data, picked, &pump, &problem);
        if (path) {
            stamp = image_build(path, flavor);
            installed = !data;  // the data's build may be an older one: the patch check still looks
            break;
        }
        if (!picked) fail_launch(problem);
        say(@"install: back to the start screen");
    }
    [flavor writeToFile:saved atomically:YES encoding:NSUTF8StringEncoding error:nil];
    retire_caught_up(flavor, stamp);
    // The game's region, once, for the rest of the start (an install just now wrote its region file).
    NSDictionary<NSString *, NSString *> *choice = sp_game_region_now(flavor);
    say([NSString stringWithFormat:@"region: %@ plays in %@ (%@), text %@, speech %@, from %@", flavor, choice[@"Region"],
                                   sp_region_name(choice[@"Region"]), choice[@"Text"], choice[@"Speech"], choice[@"Source"]]);
    region_sync(flavor, choice);
    game_region(flavor, choice);
    default_render_scale(flavor);
    skip_intro(flavor);
    flavor_info(flavor);
    // The addons the app carries, into the game's folder before the client loads (sp_addons_place): SPMovie
    // everywhere, SPHover on the headset. The device's own copy, so a game it installed has them too.
    NSString *addons = nil;
    sp_addons_place([dir stringByAppendingPathComponent:@"addons"],
                    [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_", flavor]],
                    TARGET_OS_VISION, &addons);
    say(addons);
    launch_arguments(flavor, &argc, &argv);
    // Whether a newer build is out than the client's (sppatch.m), and Update if the person wants it, which puts
    // the new build's slice in place. Before the sign-in, so nobody signs in to then be told, and before the
    // helper attaches. It never stops the launch. Not after an install just now: that's the build it wanted.
    if (!installed) {
        NSDictionary<NSString *, NSString *> *now = sp_patch_check(flavor, library, stamp, choice, &pump);
        if (now != stamp && !now)
            fail_launch([NSString stringWithFormat:@"%@ couldn't be updated on this %@, and the version it had went with it.\n\n"
                                                   @"Open Slashplayed again to get it again.", sp_flavor_name(flavor), sp_device_noun()]);
        if (now != stamp) stamp = image_build(library, flavor);
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
    // What spguest needs of the file (sp_guest_preflight; the hooks were checked at the start) first: a client
    // the device can't load says so here, before anyone signs in, rather than after the helper's attach. Then game data a copy left incomplete, for the same reason. Then the
    // sign-in, so the person isn't asked while the helper holds the debugger. Then the on-device JIT helper
    // attaches before the client loads (spjit.m). If any can't, the scene says why (starting UIKit for it on
    // visionOS) and the client isn't loaded: its prepare would fail.
    NSString *problem = sp_guest_preflight(library);
    if (!problem) problem = copy_unfinished();
    NSMutableData *login = problem ? nil : sp_login_prepare(token, &pump, &problem);
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
    // The game data's row for the build about to load, before the client reads it. An Update just now may
    // have settled the region file's languages against its build (sppatch.m): read again.
    build_info_for_image(flavor, library, stamp, sp_game_region_now(flavor));
    // Returns only if the client couldn't be loaded (or once its main returns): the reason is spguest's (an
    // unresolved import, a bad opcode, a refused hook), and a file that turned out bad is deleted with its
    // stamp, so the next Play or start gets it again.
    int status = sp_guest_main(library, argc, argv, &problem);
    if (problem)
        fail_launch([NSString stringWithFormat:@"%@ %@ couldn't be loaded on this %@: %@.", sp_flavor_name(flavor), stamp[@"Version"],
                                               sp_device_noun(), problem]);
    return status;
}
