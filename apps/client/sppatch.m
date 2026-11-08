// The patch check. Once the game is picked and before anything else per launch (the sign-in, the helper),
// the launcher asks Blizzard's patch service which build of the game is current and compares it with the
// client's stamp (Library/spgames/spbuild-<flavor>, launcher.m's image_build). Up to date shows nothing, and
// so does a check that couldn't be made (offline, a timeout, an answer without the row): it costs a few
// seconds at most and never stops a launch.
//
// A newer build out shows a screen that says so, and whether this Slashplayed can run the new build: it
// fetches the new client's arm64 slice from Blizzard's CDN (spcdn.m, about 50 MB; on cellular or in Low
// Data Mode only if the person says so) and checks its imports against the shims' exports.json the app
// carries (spbind.m), as the companion's bind check would. It binds: Update, which puts that slice in place
// as the game's client (update, below: nothing is assembled or signed, as spguest loads it unchanged), or
// Play Anyway. It doesn't: "This patch needs a Slashplayed update". Couldn't tell: Play Anyway only. The slice
// is kept in Library/spslice/ with its own stamp until it's taken, so a later launch doesn't fetch it again,
// and the client in Library/spgames stays untouched for Play Anyway.
//
// The service is https://<region>.version.battle.net/v2/products/<product>/versions: a table shaped like
// .build.info, one row per region. The region is the game's (sp_game_region in spcdn.m): the stamp's Branch for
// the Mac's game, Library/spregion-<flavor> for one the device installed. Its row's
// BuildConfig is the build's identity, the stamp's Build Key; VersionsName is the version to show. Its
// sibling /cdns names the region's CDN servers. $SP_PATCH_SERVICE replaces the base (everything before
// /<product>/versions) for tests: a URL, or a path relative to the app's home directory, read as files
// (Library/sppatchtest, with Library/sppatchtest/<product>/versions copied in by devicectl; a cdns file
// there is optional, the real service's is used without one). $SP_PATCH_CELLULAR=1 treats the network as
// cellular, for testing the question, and $SP_PATCH_CHOOSE presses a button (wait_for_choice).
//
// $SP_PATCH_DRILL is the patch drill (drill_symbol): it shows the screen with no newer build on the CDN.
// Only a pre-release companion's Play (BindCheck.deviceDrill) and run.sh pass it.
//
// The install (sp_patch_install) is the same chain from nothing, for a game with no client on the device:
// the service's current build (or, for a game with game data, the data's own build: "Getting <game> ready"),
// its slice, the bind check, and the update, on the same screen, with Back instead of Play Anyway.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#import "spbind.h"
#import "spcdn.h"

void sp_launch_say(NSString *s);  // launcher.m
void (^sp_launch_uikit(void))(double);  // launcher.m
NSString *sp_flavor_name(NSString *flavor);  // launcher.m
NSDictionary *sp_flavor_entry(NSString *flavor);  // launcher.m
UIViewController *sp_scene_root(void);  // spvpn.m
NSString *sp_device_noun(void);  // spjit.m
NSString *sp_game_region_write(NSString *flavor, NSDictionary<NSString *, NSString *> *choice);  // launcher.m
NSArray<NSString *> *sp_device_languages(void);  // launcher.m: NSLocale.preferredLanguages, or the test's

static void say(NSString *s) { sp_launch_say([@"patch: " stringByAppendingString:s]); }
// The update's own lines, and the image chosen: "update: ", as the launcher's after the load.
static void say_update(NSString *s) { sp_launch_say([@"update: " stringByAppendingString:s]); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

// The service check's budget, connect to answer: a bad network costs this much at most.
static const double timeout = 3;

// The service's `table` (versions, cdns) for `product`, or nil and *problem. Waits with `pump`, so on iOS
// the scene keeps running (the launch watchdog). `optionalFile`: with a test path in $SP_PATCH_SERVICE and
// no such file there, the real service's.
static NSString *fetch(NSString *product, NSString *region, NSString *table, BOOL optionalFile, void (^pump)(double),
                       NSString **problem) {
    NSString *base = NSProcessInfo.processInfo.environment[@"SP_PATCH_SERVICE"];
    NSString *tail = [NSString stringWithFormat:@"/%@/%@", product, table];
    if (base.length && [base rangeOfString:@"://"].location == NSNotFound) {
        NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:base] stringByAppendingString:tail];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (text || !optionalFile) {
            if (!text) *problem = [NSString stringWithFormat:@"no test file %@%@", base, tail];
            return text;
        }
        base = nil;
    }
    if (!base.length) base = [NSString stringWithFormat:@"https://%@.version.battle.net/v2/products", region];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:tail]];
    if (!url) {
        *problem = @"not a URL";
        return nil;
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = timeout;
    config.waitsForConnectivity = NO;  // offline fails now, rather than at the timeout
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    // Set on the session's queue, read here: done last.
    __block NSString *text = nil, *why = nil;
    static atomic_bool done;
    atomic_store(&done, false);
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSInteger status = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (e) why = [NSString stringWithFormat:@"%@ %ld", e.domain, (long)e.code];
        else if (status != 200) why = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        else if (!(text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding])) why = @"not text";
        atomic_store(&done, true);
    }];
    [task resume];
    // A little past the session's own timeout, in case it doesn't fire.
    for (double end = now() + timeout + 0.5; !atomic_load(&done) && now() < end;) pump(0.05);
    [session invalidateAndCancel];
    if (!atomic_load(&done)) {
        *problem = @"timed out";
        return nil;
    }
    *problem = why;
    return text;
}

// Whether the network costs the person: cellular (or a hotspot), or Low Data Mode. Not known in a second
// counts as not.
static BOOL costly_network(void (^pump)(double)) {
    if ([NSProcessInfo.processInfo.environment[@"SP_PATCH_CELLULAR"] isEqual:@"1"]) return YES;
    nw_path_monitor_t monitor = nw_path_monitor_create();
    static atomic_int state;  // -1 until the first path, then 0 or 1
    atomic_store(&state, -1);
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        atomic_store(&state, nw_path_is_expensive(path) || nw_path_is_constrained(path));
    });
    nw_path_monitor_start(monitor);
    for (double end = now() + 1; atomic_load(&state) < 0 && now() < end;) pump(0.05);
    nw_path_monitor_cancel(monitor);
    return atomic_load(&state) == 1;
}

// ---- the screen

UIViewController *sp_patch_screen(void (^choose)(NSInteger index));  // sppatchscreen.swift
void sp_patch_show(UIViewController *screen, NSString *heading, NSString *message, NSString *_Nullable note,
                   NSArray<NSString *> *buttons);
void sp_screen_status(UIViewController *screen, NSString *text);  // spstyle.swift

// The SwiftUI screen (sppatchscreen.swift, in the start screen's look) and what the wait reads: the button
// tapped and the titles shown, kept here so $SP_PATCH_CHOOSE finds a button by its title.
@interface SPPatchController : NSObject
@property (nonatomic, readonly) UIViewController *view;
@property (nonatomic) NSInteger choice;  // the button tapped (-1 until one is); read by the wait
@property (nonatomic, copy) NSArray<NSString *> *titles;  // the buttons shown now
@end

@implementation SPPatchController

- (instancetype)init {
    if (!(self = [super init])) return nil;
    __weak SPPatchController *me = self;  // else the screen's block would keep this alive
    _view = sp_patch_screen(^(NSInteger i) { me.choice = i; });
    _choice = -1;
    return self;
}

// What the screen says now: the heading, what to do, and a quieter `note` under it (nil for none). With
// `buttons`, it waits for one (the first is the screen's action, the others gold text); without, a spinner
// turns. A new state clears the progress line.
- (void)setHeading:(NSString *)heading body:(NSString *)body note:(NSString *)note buttons:(NSArray<NSString *> *)titles {
    self.choice = -1;
    self.titles = titles;
    sp_patch_show(_view, heading, body, note, titles);
}

// The progress line, under the same heading, words, and buttons: the download's MB count.
- (void)setStatus:(NSString *)status {
    sp_screen_status(_view, status);
}
@end

// The screen, presented on the scene's root (nil when there's no screen to show it on). Sets *pump to UIKit's.
// `what` names it in the log: "newer-build" (the companion follows that line), or "install".
static SPPatchController *present(void (^*pump)(double), NSString *what) {
    // It waits on the person: UIKit has to be up for the launch watchdog (on iOS it already is).
    void (^ui)(double) = sp_launch_uikit();
    UIViewController *root = ui ? sp_scene_root() : nil;
    if (!root) {
        say(@"no screen to say so on: going on");
        return nil;
    }
    *pump = ui;
    SPPatchController *screen = [SPPatchController new];  // full screen, pinned Dark (LauncherHost)
    // Checked, as splogin.m's: UIKit refuses a presentation while the root still presents another.
    __block BOOL shown = NO;
    [root presentViewController:screen.view animated:NO completion:^{ shown = YES; }];
    for (double end = now() + 5; !shown && now() < end;) ui(0.05);
    if (!shown || !screen.view.presentingViewController) {
        say([NSString stringWithFormat:@"the %@ screen didn't show (the root presents %@)", what, root.presentedViewController]);
        return nil;
    }
    // The companion follows this line and Play Anyway's (ClientLauncher.Marker.newerBuild, playAnyway).
    say([NSString stringWithFormat:@"showing the %@ screen", what]);
    return screen;
}

// $SP_PATCH_CHOOSE=<a button's title> (Update, Play Anyway, Download, Not Now) presses it a second after it
// shows, for headless tests.
static NSInteger wait_for_choice(SPPatchController *screen, void (^pump)(double)) {
    NSUInteger hook = [screen.titles indexOfObject:NSProcessInfo.processInfo.environment[@"SP_PATCH_CHOOSE"] ?: @""];
    if (hook != NSNotFound) {
        for (double end = now() + 1; now() < end;) pump(0.05);
        say([NSString stringWithFormat:@"%@ pressed by the test hook", screen.titles[hook]]);
        return (NSInteger)hook;
    }
    while (screen.choice < 0) pump(0.1);
    return screen.choice;
}

static void dismiss(SPPatchController *screen, void (^pump)(double)) {
    // Until it's gone: the sign-in, LocalDevVPN, and pairing screens may be presented next.
    UIViewController *root = screen.view.presentingViewController;
    __block BOOL gone = NO;
    [screen.view dismissViewControllerAnimated:NO completion:^{ gone = YES; }];
    for (double end = now() + 5; !gone && now() < end;) pump(0.05);
    // The input view (spevent.m) takes the keys back.
    [root.view becomeFirstResponder];
}

// ---- the patch drill

// $SP_PATCH_DRILL rehearses a newer build without one on the CDN (or any file of Blizzard's in the test):
// the service's current build counts as newer than the image even when it's the same, so the screen shows,
// its slice is fetched (or kept), and it's checked. `binds` leaves the check alone (it binds: "Update on
// your Mac" or Update); any other value is a symbol withheld from the app's shims for the check, as the
// companion's SPPatchDrillImport (BindCheck.Manifest.withheld): "This patch needs a Slashplayed update".
// Returns whether the drill is on, and *symbol the withheld one (nil for binds).
static BOOL drill(NSString **symbol) {
    NSString *value = NSProcessInfo.processInfo.environment[@"SP_PATCH_DRILL"];
    *symbol = [value isEqual:@"binds"] ? nil : value;
    return value.length > 0;
}

// ---- the check of the new build

// What the check of a newer build found.
typedef enum { binds, needs_update, unknown } verdict;

static NSString *stamp_text(NSString *product, NSString *region, NSDictionary<NSString *, NSString *> *row) {
    // ClientAssembly.Stamp's layout, for the build the slice is.
    return [NSString stringWithFormat:@"Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\n%@|%@|%@|%@\n",
                                      product, region, row[@"BuildConfig"], row[@"VersionsName"]];
}

// The newer build's arm64 slice in Library/spslice/ (<flavor>.arm64 and its stamp, spbuild-<flavor>):
// kept from an earlier launch if it's this build, else fetched, asking first on a costly network. nil and
// *why if there's none.
// *shipped: the build's install manifest's tag names when this fetched the slice (nil for a kept one).
static NSString *new_slice(NSString *flavor, NSString *product, NSString *region, NSDictionary<NSString *, NSString *> *row,
                           double megabytes, SPPatchController *screen, NSString *heading, NSString *note, void (^pump)(double),
                           NSArray<NSString *> **shipped, NSString **why) {
    *shipped = nil;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/spslice"];
    NSString *slice = [dir stringByAppendingPathComponent:[flavor stringByAppendingString:@".arm64"]];
    NSString *stamp = [dir stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]];
    NSDictionary *kept = sp_table_row([NSString stringWithContentsOfFile:stamp encoding:NSUTF8StringEncoding error:nil], @"Product", product);
    if ([kept[@"Build Key"] isEqual:row[@"BuildConfig"]] && [NSFileManager.defaultManager fileExistsAtPath:slice]) {
        say([NSString stringWithFormat:@"slice: %@ %@ kept from an earlier launch", product, row[@"VersionsName"]]);
        return slice;
    }
    if (costly_network(pump)) {
        say(@"on cellular or Low Data Mode: asking before the download");
        [screen setHeading:heading
                      body:[NSString stringWithFormat:@"To check whether Slashplayed can run it, this %@ downloads about "
                                                      @"%.0f MB from Blizzard. You're on cellular data or Low Data Mode.",
                                                      sp_device_noun(), megabytes]
                      note:note
                   buttons:@[@"Download", @"Not Now"]];
        if (wait_for_choice(screen, pump) != 0) {
            say(@"Not Now: no download");
            *why = @"not downloaded on a costly network";
            return nil;
        }
        say(@"Download");
    }
    // The words stay put while the download counts in the status line.
    [screen setHeading:heading body:@"Checking whether Slashplayed can run it…" note:note buttons:@[]];
    [screen setStatus:[NSString stringWithFormat:@"Downloading about %.0f MB from Blizzard", megabytes]];
    double t = now();
    NSString *problem = nil;
    NSString *cdns = fetch(product, region, @"cdns", YES, pump, &problem);
    NSArray<NSURL *> *servers = cdns ? sp_cdn_servers(sp_table_row(cdns, @"Name", region) ?: @{}) : @[];
    if (!servers.count) {
        *why = [NSString stringWithFormat:@"no CDN servers (%@)", problem ?: [NSString stringWithFormat:@"no %@ row", region]];
        return nil;
    }
    NSString *client = sp_flavor_entry(flavor)[@"client"];
    if (!client.length) {
        *why = @"flavors.plist has no client path";
        return nil;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    // The stamp goes first and comes back last, so one is only ever beside a whole slice of its build.
    [NSFileManager.defaultManager removeItemAtPath:stamp error:nil];
    // The download, on the screen as it goes: one took 41.7 s (2–7 s otherwise) behind a bare spinner. The
    // slice is a part of the client's file, so its size is known only roughly (`megabytes`, the image's).
    __block double shown = -1;
    SPFetch session = sp_cdn_session(pump, 20, ^(unsigned long long received) {
        double mb = floor(received / 1e6);
        if (mb == shown) return;
        shown = mb;
        [screen setStatus:[NSString stringWithFormat:@"Downloading from Blizzard: %.0f of about %.0f MB",
                                                     MIN(mb, megabytes), megabytes]];
    });
    __block unsigned long long bytes = 0;
    __block unsigned requests = 0;
    SPFetch counted = ^NSData *(NSURL *url, NSRange range, NSString **p) {
        NSData *d = session(url, range, p);
        bytes += d.length;
        requests++;
        return d;
    };
    if (!sp_cdn_slice(servers, row[@"BuildConfig"], row[@"CDNConfig"], client, region, counted, slice, shipped, &problem)) {
        *why = [@"the download failed: " stringByAppendingString:problem];
        say([NSString stringWithFormat:@"slice: %@ %@ failed after %.1f MB in %u requests, %.1f s", product,
                                       row[@"VersionsName"], bytes / 1e6, requests, now() - t]);
        return nil;
    }
    [stamp_text(product, region, row) writeToFile:stamp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:slice error:nil].fileSize;
    say([NSString stringWithFormat:@"slice: %@ %@, %.1f MB, fetched %.1f MB in %u requests, %.1f s (Library/spslice/%@.arm64)",
                                   product, row[@"VersionsName"], size / 1e6, bytes / 1e6, requests, now() - t, flavor]);
    return slice;
}

// Whether the newer build binds against the app's shims, with the screen up meanwhile. *why for unknown.
static verdict check_new_build(NSString *flavor, NSString *image, NSString *product, NSString *region,
                               NSDictionary<NSString *, NSString *> *row, SPPatchController *screen, NSString *heading,
                               NSString *note, void (^pump)(double), NSArray<NSString *> **shipped, NSString **why) {
    *shipped = nil;
    NSString *exports = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"exports.json"];
    NSData *manifest = [NSData dataWithContentsOfFile:exports options:NSDataReadingMappedIfSafe error:nil];
    if (!manifest) {
        *why = @"the app has no exports.json";
        return unknown;
    }
    // The new slice is about the size of this one.
    // No client yet (an install, sp_patch_install): new_slice's 50.
    double megabytes = image ? [NSFileManager.defaultManager attributesOfItemAtPath:image error:nil].fileSize / 1e6 : 0;
    NSString *slice = new_slice(flavor, product, region, row, megabytes ?: 50, screen, heading, note, pump, shipped, why);
    if (!slice) return unknown;
    double t = now();
    NSUInteger total = 0;
    NSString *problem = nil, *withheld = nil;
    drill(&withheld);
    if (withheld.length) say([@"drill: withholding " stringByAppendingString:withheld]);
    NSArray<NSString *> *unresolved = sp_bind_unresolved(
        [NSData dataWithContentsOfFile:slice options:NSDataReadingMappedIfSafe error:nil] ?: [NSData data], manifest,
        withheld.length ? [NSSet setWithObject:withheld] : nil, &total, &problem);
    if (!unresolved) {
        *why = [@"its imports couldn't be read: " stringByAppendingString:problem];
        return unknown;
    }
    say([NSString stringWithFormat:@"imports: %lu of %lu resolve against the app's shims (%.1f s)",
                                   (unsigned long)(total - unresolved.count), (unsigned long)total, now() - t]);
    for (NSString *u in [unresolved subarrayWithRange:NSMakeRange(0, MIN(unresolved.count, 10))])
        say([@"imports: UNRESOLVED " stringByAppendingString:u]);
    if (unresolved.count > 10) say([NSString stringWithFormat:@"imports: … and %lu more", (unsigned long)unresolved.count - 10]);
    return unresolved.count ? needs_update : binds;
}

// ---- the update on the device

// Puts the newer build's kept slice (Library/spslice/<flavor>.arm64, new_slice) in place as the game's client:
// the build's configs into Documents/Data/config/ (spcdn.m, the bytes the companion's BlizzardCDN.configData
// gives), then in Library/spgames/ the slice itself renamed to wow-<flavor> (one volume, so nothing is
// copied), its .build.info row (spbuildinfo-<flavor>), spsource-<flavor> (`source`: "updated", or
// "installed" for an install), and its stamp last (spbuild-<flavor>, the slice's stamp's layout), so a stamp is only ever
// beside a whole client of its build. Configs first: they're named by their content, so they're harmless to
// the old build, and a failure leaves the old client. The game data's .build.info row for the new build isn't
// written here: the launcher writes it into Documents/.build.info from the kept row just before the client
// loads, on that launch and every later one whose row isn't the client's build (sp_build_info_for_image). So a
// launch that stops before the client loads (at the sign-in, say, or the JIT helper), or game data emptied
// under the client, doesn't leave the client streaming with no row for its build (#134, "Invalid schema …
// StartupFiles", issue #36). `tags`: the kept row's Tags for a game whose region the device decides
// (sp_region_tags), nil for the Mac's (its own row's are kept). The new client's path, or nil and *why.
static NSString *update(NSString *flavor, NSString *product, NSString *region, NSString *tags, NSDictionary<NSString *, NSString *> *row,
                        NSString *source, void (^pump)(double), NSString **why) {
    NSString *home = NSHomeDirectory(), *name = [@"wow-" stringByAppendingString:flavor];
    NSString *kept = [home stringByAppendingPathComponent:@"Library/spslice"];
    NSString *slice = [kept stringByAppendingPathComponent:[flavor stringByAppendingString:@".arm64"]];
    NSString *sliceStamp = [kept stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]];
    if (![NSFileManager.defaultManager fileExistsAtPath:slice]) {
        *why = @"the new version's download isn't on this device any more";
        return nil;
    }
    // What spguest would refuse (a download that came out short, say) never replaces the client: it's dropped,
    // so the next check fetches it again.
    NSString *bad = sp_slice_problem(slice);
    if (bad) {
        [NSFileManager.defaultManager removeItemAtPath:sliceStamp error:nil];
        [NSFileManager.defaultManager removeItemAtPath:slice error:nil];
        *why = [@"the new version's download can't be loaded: " stringByAppendingString:bad];
        return nil;
    }
    double t = now();
    NSString *problem = nil;
    NSString *cdns = fetch(product, region, @"cdns", YES, pump, &problem);
    NSDictionary<NSString *, NSString *> *cdnsRow = cdns ? sp_table_row(cdns, @"Name", region) : nil;
    NSArray<NSURL *> *servers = cdnsRow ? sp_cdn_servers(cdnsRow) : @[];
    if (!servers.count) {
        *why = [NSString stringWithFormat:@"Blizzard's patch service named no CDN (%@)", problem ?: [NSString stringWithFormat:@"no %@ row", region]];
        return nil;
    }
    SPFetch session = sp_cdn_session(pump, 20, nil);
    NSString *data = [home stringByAppendingPathComponent:@"Documents/Data"];
    unsigned long long bytes = 0;
    unsigned fetched = 0, there = 0;
    for (NSString *key in @[row[@"BuildConfig"] ?: @"", row[@"CDNConfig"] ?: @"", row[@"KeyRing"] ?: @""]) {
        if (!key.length) continue;
        unsigned long long n = 0;
        if (!sp_cdn_store_config(servers, key, session, data, &n, &problem)) {
            *why = [@"its game data's configs couldn't be fetched: " stringByAppendingString:problem];
            return nil;
        }
        if (n) fetched++, bytes += n;
        else there++;
    }
    say_update([NSString stringWithFormat:@"configs: %u fetched (%.1f KB), %u already there, %.1f s", fetched, bytes / 1e3, there, now() - t]);

    NSString *dir = [home stringByAppendingPathComponent:@"Library/spgames"];
    NSString *dest = [dir stringByAppendingPathComponent:name];
    NSString *stamp = [dir stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    // Into place. The old client's stamp goes first, so a start cut short from here never takes the new file for
    // the old build, and it comes back if the rename fails, which leaves the old client and its row as they
    // were (Play Anyway plays it, and the slice stays kept for a later Update). The slice's own stamp in
    // spslice goes once the slice has moved. Then the new build's row, the word, and the stamp last. If one of
    // those can't be written, the new client stays with no stamp, which nothing loads, and the old one is gone:
    // sp_patch_check sees the stamp missing and offers no Play Anyway, and the next start gets the game ready.
    NSString *oldStamp = [NSString stringWithContentsOfFile:stamp encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:stamp error:nil];
    if (rename(slice.fileSystemRepresentation, dest.fileSystemRepresentation)) {
        int e = errno;
        [oldStamp writeToFile:stamp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        *why = [NSString stringWithFormat:@"its client couldn't be put in place (errno %d)", e];
        return nil;
    }
    [NSFileManager.defaultManager removeItemAtPath:sliceStamp error:nil];
    NSString *keptRow = [dir stringByAppendingPathComponent:[@"spbuildinfo-" stringByAppendingString:flavor]];
    if (![sp_build_info_with(nil, product, region, tags, row, cdnsRow) writeToFile:keptRow atomically:YES encoding:NSUTF8StringEncoding
                                                                       error:nil] ||
        ![[source stringByAppendingString:@"\n"] writeToFile:[dir stringByAppendingPathComponent:[@"spsource-" stringByAppendingString:flavor]]
                                                  atomically:YES encoding:NSUTF8StringEncoding error:nil] ||
        ![stamp_text(product, region, row) writeToFile:stamp atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        *why = @"its .build.info row, spsource, or stamp couldn't be written";
        return nil;
    }
    return dest;
}

// ---- the install on the device

// A reason for the screen's note: capitalized, with a period. "" for none.
static NSString *sentence(NSString *why) {
    if (!why.length) return @"";
    return [NSString stringWithFormat:@"%@%@.", [why substringToIndex:1].uppercaseString, [why substringFromIndex:1]];
}

// A device-decided region (sp_game_region) once the build's install manifest has been read (`shipped`, its tag
// names; nil when this start didn't read one): its languages checked against what the build ships, the
// device's next one for the region (sp_region_locale) if it doesn't ship the chosen one, and what it ships kept
// in the region file for a later change in Settings. Written to Library/spregion-<flavor>.
static NSDictionary<NSString *, NSString *> *settle_region(NSString *flavor, NSDictionary<NSString *, NSString *> *choice,
                                                           NSArray<NSString *> *shipped) {
    NSMutableDictionary<NSString *, NSString *> *out = [choice mutableCopy];
    if (shipped) {
        NSMutableArray<NSString *> *locales = [NSMutableArray array];
        for (NSString *t in shipped)
            if ([t rangeOfString:@"^[a-z]{2}[A-Z]{2}$" options:NSRegularExpressionSearch].location != NSNotFound) [locales addObject:t];
        out[@"Shipped"] = [locales componentsJoinedByString:@" "];
        if (!sp_locale_shipped(choice[@"Text"], locales)) {
            NSString *text = sp_region_locale(choice[@"Region"], sp_device_languages(), locales);
            say([NSString stringWithFormat:@"region: this build doesn't ship %@: %@ instead", choice[@"Text"], text]);
            out[@"Text"] = out[@"Speech"] = text;
        }
    }
    NSString *problem = sp_game_region_write(flavor, out);
    if (problem) say([@"region: " stringByAppendingString:problem]);
    return out;
}

// The patch service's versions row for `product` in `region`, or nil and *why.
static NSDictionary<NSString *, NSString *> *current_row(NSString *product, NSString *region, void (^pump)(double), NSString **why) {
    double t = now();
    NSString *problem = nil;
    NSString *text = fetch(product, region, @"versions", NO, pump, &problem);
    NSDictionary<NSString *, NSString *> *row = text ? sp_table_row(text, @"Region", region) : nil;
    if (text && !row[@"BuildConfig"].length) problem = [NSString stringWithFormat:@"no %@ row", region];
    if (problem) {
        *why = [NSString stringWithFormat:@"%@, %.1f s", problem, now() - t];
        return nil;
    }
    say([NSString stringWithFormat:@"install: %@ %@ is current in %@ (%.1f s)", product, row[@"VersionsName"], region, now() - t]);
    return row;
}

// Installs a game the device has no client of: with the update's chain from nothing, the patch service's
// current build in the game's region (`choice`, sp_game_region: the region file, else the device's region and
// languages), its slice fetched (asking first on a costly network) and its imports checked (check_new_build),
// then its configs, row, and stamp put in place here (update, as "installed"); the launcher writes the game's
// .flavor.info (flavor_info). Its screen says each step; there's no Play Anyway, as there's nothing else to
// play. The screen names the region ("Installing Classic Era for Europe"), and once the build is checked the
// region and its languages, checked against the locales the build ships, go into Library/spregion-<flavor>
// (settle_region), which the game follows from then on until Settings changes it.
//
// With `data` (the game data's .build.info row: the Mac copied the game's data, or an upgrade retired the image
// an older Slashplayed made), the client of that build, not the current one: "Getting Classic Era ready". Its
// region stays the data's (the Mac's, or an earlier install's region file), and the patch check after it
// offers any newer build as usual. If that build can't be downloaded, the current one is. A Mac's next Play
// copies the same client, if it gets there first.
//
// Returns the new client (Library/spgames/wow-<flavor>), its .build.info row kept beside it for the launcher
// to write just before it loads, as after Update. nil and *problem when it can't: with `back`, the screen has
// said why and waited for Back (the launcher shows the start screen again); without (a launch that named the
// game), it's dismissed and the launcher shows *problem. install: lines, versions only.
NSString *sp_patch_install(NSString *flavor, NSDictionary<NSString *, NSString *> *choice, NSDictionary<NSString *, NSString *> *data,
                           BOOL back, void (^*pump)(double), NSString **problem) {
    *problem = nil;
    NSString *product = sp_flavor_entry(flavor)[@"product"], *game = sp_flavor_name(flavor), *noun = sp_device_noun();
    NSString *region = choice[@"Region"], *where = sp_region_name(region ?: @"");
    BOOL device = [choice[@"Device"] isEqual:@"1"];
    if (data)
        say([NSString stringWithFormat:@"install: %@ has game data for %@ and no client on this %@: getting that build's in %@ (%@, from %@)",
                                       product ?: flavor, data[@"Version"], noun, region, where, choice[@"Source"]]);
    else
        say([NSString stringWithFormat:@"install: %@ has no client on this %@: installing it in %@ (%@, text %@, speech %@, from %@)",
                                       product ?: flavor, noun, region, where, choice[@"Text"], choice[@"Speech"], choice[@"Source"]]);
    NSCharacterSet *notRegion = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"].invertedSet;
    if (!product.length || !region.length || [region rangeOfCharacterFromSet:notRegion].location != NSNotFound) {
        *problem = [NSString stringWithFormat:@"%@ can't be installed: the app doesn't know its product or region.", game];
        say(@"install: no product or region");
        return nil;
    }
    SPPatchController *screen = present(pump, @"install");
    if (!screen) {
        *problem = [NSString stringWithFormat:@"%@ isn't ready on this %@, and there's no screen to get it ready on.", game, noun];
        return nil;
    }
    void (^ui)(double) = *pump;  // UIKit's, now (present)
    NSString *heading = data ? [NSString stringWithFormat:@"Getting %@ ready…", game]
                             : [NSString stringWithFormat:@"Installing %@ for %@…", game, where];
    // A failure: on the screen with Back, or handed to the launcher to show. What the launcher shows.
    NSString * (^failed)(NSString *, NSString *, NSString *) = ^NSString *(NSString *title, NSString *body, NSString *note) {
        if (back) {
            [screen setHeading:title body:body note:note buttons:@[@"Back"]];
            wait_for_choice(screen, ui);
            say(@"install: Back");
        }
        dismiss(screen, ui);
        return note.length ? [NSString stringWithFormat:@"%@ %@\n\n%@", title, body, note]
                           : [NSString stringWithFormat:@"%@ %@", title, body];
    };
    NSString *cant = data ? [NSString stringWithFormat:@"%@ couldn't be made ready on this %@.", game, noun]
                          : [NSString stringWithFormat:@"%@ can't be installed on this %@.", game, noun];
    NSString *why = nil;
    NSDictionary<NSString *, NSString *> *row;
    if (data) {
        // The data's row, in the patch service's names (sp_build_info_with's, the other way round).
        row = @{@"BuildConfig": data[@"Build Key"], @"CDNConfig": data[@"CDN Key"], @"KeyRing": data[@"KeyRing"] ?: @"",
                @"VersionsName": data[@"Version"] ?: @""};
    } else {
        [screen setHeading:heading body:@"Asking Blizzard for the current version…" note:nil buttons:@[]];
        row = current_row(product, region, ui, &why);
        if (!row) {
            say([NSString stringWithFormat:@"install: couldn't ask the patch service for %@ (%@)", product, why]);
            *problem = failed(cant, @"Blizzard's patch service couldn't be reached. Check the network, then try again.", sentence(why));
            return nil;
        }
    }
    NSString *version = row[@"VersionsName"].length ? row[@"VersionsName"] : @"(no version)";
    if (!data) heading = [NSString stringWithFormat:@"Installing %@ %@ for %@…", game, version, where];
    NSArray<NSString *> *shipped = nil;
    verdict v = check_new_build(flavor, nil, product, region, row, screen, heading, nil, ui, &shipped, &why);
    // The data's own build that couldn't be fetched (Blizzard's CDN no longer serves it, say, or it came out
    // short): the current build in the data's region instead, as an install gets, so a device with no Mac still
    // plays. The client streams that build's content over the data's, as after Update. Not after Not Now on a
    // costly network: that was the person's answer.
    if (data && v == unknown && [why hasPrefix:@"the download failed"]) {
        say([NSString stringWithFormat:@"install: %@ %@ couldn't be fetched (%@): getting the current build instead", product, version, why]);
        [screen setHeading:heading body:@"Asking Blizzard for the current version…" note:nil buttons:@[]];
        NSDictionary<NSString *, NSString *> *current = current_row(product, region, ui, &why);
        if (current) {
            row = current;
            version = row[@"VersionsName"].length ? row[@"VersionsName"] : @"(no version)";
            v = check_new_build(flavor, nil, product, region, row, screen, heading, nil, ui, &shipped, &why);
        }
    }
    if (v == needs_update) {
        say([NSString stringWithFormat:@"install: message: needs a Slashplayed update: %@ %@ doesn't bind", product, version]);
        *problem = failed(cant, [NSString stringWithFormat:@"This version of Slashplayed can't run %@ %@ yet. Once there's a "
                                                           @"Slashplayed update for it, install that, then try again.", game, version], nil);
        return nil;
    }
    if (v == unknown) {
        say([NSString stringWithFormat:@"install: message: couldn't check %@ %@: %@", product, version, why]);
        // A download that failed isn't a check that couldn't run: say which.
        BOOL fetch = [why hasPrefix:@"the download failed"] || [why hasPrefix:@"no CDN servers"];
        *problem = failed(cant, fetch ? @"It couldn't be downloaded from Blizzard. Check the network, then try again."
                                      : @"Whether Slashplayed can run it couldn't be checked. Try again on Wi-Fi.", sentence(why));
        return nil;
    }
    [screen setHeading:heading body:[NSString stringWithFormat:@"Setting it up on this %@.", noun] note:nil buttons:@[]];
    double t = now();
    // The languages checked against the build's before its row is kept with them, for a game whose region the
    // device decides (every install); the Mac's game data keeps its own row's (`tags` nil).
    NSDictionary<NSString *, NSString *> *settled = !data || device ? settle_region(flavor, choice, shipped) : choice;
    NSString *tags = !data || device ? sp_region_tags(region, settled[@"Text"], settled[@"Speech"]) : nil;
    NSString *image = update(flavor, product, region, tags, row, @"installed", ui, &why);
    if (!image) {
        say([NSString stringWithFormat:@"install: failed after %.1f s: %@", now() - t, why]);
        *problem = failed(cant, @"Try again later.", sentence(why));
        return nil;
    }
    say([NSString stringWithFormat:@"install: %@ %@ is Library/spgames/%@, %.1f s in all; %@ (%@), text %@, speech %@",
                                   product, version, image.lastPathComponent, now() - t, region, where, settled[@"Text"],
                                   settled[@"Speech"]]);
    dismiss(screen, ui);
    say_update([NSString stringWithFormat:@"image: Library/spgames %@ %@ (just %@)", product, version, data ? @"made ready" : @"installed"]);
    return image;
}

// ---- the check

// Whether a newer build is out than the game's client (`image`, Library/spgames/wow-<flavor>, and `stamp`, its
// build), with the screen if so, once the launch may go on: right away unless a newer build is out, then after
// Play Anyway or Update. The region is the device's for a game it decides it for (`choice`, sp_game_region),
// else the stamp's Branch (the Mac's), and an Update keeps its row in that region.
//
// A newer build out shows the screen. When the new build binds, it offers Update: the new build's slice is
// put in place here (update) and its stamp returned, its .build.info row kept beside it for the launcher to
// write just before it loads. Otherwise Play Anyway only, with why.
//
// One line of log for the outcome, one for the message shown, and one for the client chosen (update: image:),
// versions only. Returns the stamp of the build that loads (`stamp` itself unless an Update replaced it), or nil
// when an Update failed after it had replaced the client, which leaves nothing to load. Sets *pump to UIKit's
// when it shows its screen.
NSDictionary<NSString *, NSString *> *sp_patch_check(NSString *flavor, NSString *image, NSDictionary<NSString *, NSString *> *stamp,
                                                    NSDictionary<NSString *, NSString *> *choice, void (^*pump)(double)) {
    BOOL device = [choice[@"Device"] isEqual:@"1"] && choice[@"Region"].length;
    NSString *product = stamp[@"Product"], *region = device ? choice[@"Region"] : stamp[@"Branch"].lowercaseString;
    NSDictionary<NSString *, NSString *> * (^use)(NSString *) = ^NSDictionary<NSString *, NSString *> *(NSString *why) {
        say_update([NSString stringWithFormat:@"image: Library/spgames %@ %@ (%@)", product, stamp[@"Version"], why]);
        return stamp;
    };
    if (!stamp) {
        say(@"couldn't check: the client has no stamp");
        return stamp;
    }
    // The region goes into a host name.
    NSCharacterSet *notRegion = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"].invertedSet;
    if (!product.length || !region.length || [region rangeOfCharacterFromSet:notRegion].location != NSNotFound) {
        say(@"couldn't check: the stamp has no product or region");
        return use(@"couldn't check");
    }
    double t = now();
    NSString *problem = nil;
    NSString *text = fetch(product, region, @"versions", NO, *pump, &problem);
    NSDictionary<NSString *, NSString *> *row = text ? sp_table_row(text, @"Region", region) : nil;
    if (text && !row[@"BuildConfig"].length) problem = [NSString stringWithFormat:@"no %@ row", region];
    if (problem) {
        say([NSString stringWithFormat:@"couldn't check %@ (%@, %.1f s): going on", product, problem, now() - t]);
        return use(@"couldn't check");
    }
    NSString *withheld = nil;
    BOOL drilled = drill(&withheld);
    if (drilled) {
        say([NSString stringWithFormat:@"drill: SP_PATCH_DRILL=%@: %@ %@ counts as newer than the client", withheld ?: @"binds",
                                       product, row[@"VersionsName"]]);
    } else if ([row[@"BuildConfig"] isEqual:stamp[@"Build Key"]]) {
        say([NSString stringWithFormat:@"up to date: %@ %@ (%@, %.1f s)", product, stamp[@"Version"], region, now() - t]);
        return use(@"the current build");
    }
    NSString *version = row[@"VersionsName"].length ? row[@"VersionsName"] : @"(no version)";
    say([NSString stringWithFormat:@"newer build out: %@ %@, the client is %@ (%@, %.1f s)", product, version,
                                   stamp[@"Version"], region, now() - t]);
    NSString *game = sp_flavor_name(flavor), *noun = sp_device_noun();
    NSString *news = sp_patch_news(game, row[@"VersionsName"]), *heading = [news stringByAppendingString:@"."];
    SPPatchController *screen = present(pump, @"newer-build");
    if (!screen) return use(@"a newer build is out");
    // Under every state's words: the build this device has, against the news in the heading.
    NSString *has = [NSString stringWithFormat:@"This %@ has %@ %@.", noun, game, stamp[@"Version"]];
    NSString *why = nil;
    NSArray<NSString *> *shipped = nil;
    verdict v = check_new_build(flavor, image, product, region, row, screen, heading, has, *pump, &shipped, &why);
    if (v == needs_update) {
        say([NSString stringWithFormat:@"message: needs a Slashplayed update: %@ %@ doesn't bind, the client is %@", product,
                                       version, stamp[@"Version"]]);
        [screen setHeading:@"This patch needs a Slashplayed update."
                      body:sp_patch_needs_update_body(news)
                      note:has
                   buttons:@[@"Play Anyway"]];
    } else if (v == binds) {
        say([NSString stringWithFormat:@"message: update here: %@ %@ binds, the client is %@", product, version, stamp[@"Version"]]);
        [screen setHeading:heading
                      body:[NSString stringWithFormat:@"This %@ can update itself in a few seconds.", noun]
                      note:has
                   buttons:@[@"Update", @"Play Anyway"]];
    } else {
        say([NSString stringWithFormat:@"message: couldn't tell whether %@ %@ binds (%@), the client is %@", product, version, why,
                                       stamp[@"Version"]]);
        [screen setHeading:heading
                      body:@"Whether Slashplayed can run it couldn't be checked. Try again on Wi-Fi."
                      note:[NSString stringWithFormat:@"%@\n%@", sentence(why), has]
                   buttons:@[@"Play Anyway"]];
    }
    if (v == binds && wait_for_choice(screen, *pump) == 0) {
        // The companion follows this line as it does Play Anyway's (ClientLauncher.Marker.update).
        say(@"Update");
        [screen setHeading:[NSString stringWithFormat:@"Updating %@ to %@…", game, version]
                      body:[NSString stringWithFormat:@"Setting the new version up on this %@.", noun]
                      note:nil
                   buttons:@[]];
        t = now();
        NSDictionary<NSString *, NSString *> *settled = device ? settle_region(flavor, choice, shipped) : nil;
        NSString *updated = update(flavor, product, region, device ? sp_region_tags(region, settled[@"Text"], settled[@"Speech"]) : nil,
                                   row, @"updated", *pump, &why);
        if (updated) {
            say_update([NSString stringWithFormat:@"%@ %@ is Library/spgames/%@, %.1f s in all", product, version,
                                           updated.lastPathComponent, now() - t]);
            dismiss(screen, *pump);
            say_update([NSString stringWithFormat:@"image: Library/spgames %@ %@ (just updated)", product, version]);
            return sp_table_row([NSString stringWithContentsOfFile:[updated.stringByDeletingLastPathComponent stringByAppendingPathComponent:
                                                                    [@"spbuild-" stringByAppendingString:flavor]]
                                                          encoding:NSUTF8StringEncoding error:nil], @"Product", product);
        }
        say_update([NSString stringWithFormat:@"failed after %.1f s: %@", now() - t, why]);
        // Past the rename (update), the old client is gone too: nothing to play anyway. The launcher says so,
        // and the next start gets the game ready.
        if (![NSFileManager.defaultManager fileExistsAtPath:[image.stringByDeletingLastPathComponent stringByAppendingPathComponent:
                                                             [@"spbuild-" stringByAppendingString:flavor]]]) {
            dismiss(screen, *pump);
            return nil;
        }
        [screen setHeading:[NSString stringWithFormat:@"%@ couldn't be updated on this %@.", game, noun]
                      body:@"Try again later."
                      // The reason, for a report, under the plain words, then the build it has.
                      note:[NSString stringWithFormat:@"%@\n%@", sentence(why), has]
                   buttons:@[@"Play Anyway"]];
    }
    wait_for_choice(screen, *pump);
    say(@"Play Anyway");
    dismiss(screen, *pump);
    return use(@"Play Anyway");
}
