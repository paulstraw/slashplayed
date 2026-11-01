// Blizzard's CDN on the device (spcdn.m): a build's client's arm64 slice, as the companion's
// BlizzardCDN.swift fetches it. Foundation only, so the companion's tests build it for the Mac too and run
// it against their in-memory CDN.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One HTTP GET of `url`: the body, or with a nonzero range.length those bytes of it (fewer past the end).
// nil and *problem on failure, *problem being SPCDNNotFound for a 404.
typedef NSData *_Nullable (^SPFetch)(NSURL *url, NSRange range, NSString *_Nullable *_Nonnull problem);

extern NSString *const SPCDNNotFound;

// A row of a |-separated table whose header names carry a !type suffix (.build.info, the image's stamp,
// the patch service's versions and cdns): the last one whose `column` is `value`, as the companion's
// GameStore.buildInfo takes it. Lines starting with # (the service's "## seqn") aren't rows. nil if none.
NSDictionary<NSString *, NSString *> *_Nullable sp_table_row(NSString *_Nullable text, NSString *column,
                                                             NSString *_Nullable value);

// The CDN servers a region's row in the patch service's cdns table names: its HTTPS servers in the
// table's order, or its hosts over HTTPS if it lists none, each with the row's Path. Empty if none.
NSArray<NSURL *> *sp_cdn_servers(NSDictionary<NSString *, NSString *> *cdnsRow);

// Writes the arm64 slice of `executable` (the client's path in its game's folder, flavors.plist's) in the
// build `buildConfig` / `cdnConfig` (the version row's) for `region` to `output`, byte-identical to
// `lipo -thin arm64` of the installed executable. Fetches only what it needs, each piece checked against
// the key that names it. NO and *problem on failure.
BOOL sp_cdn_slice(NSArray<NSURL *> *servers, NSString *buildConfig, NSString *cdnConfig, NSString *executable,
                  NSString *region, SPFetch fetch, NSString *output, NSString *_Nullable *_Nonnull problem);

// The device's fetch: URLSession, waiting with `pump` (so the scene keeps running), `timeout` seconds
// without data at most per request. `progress`, if given, is called while it waits with the bytes this
// fetch has received so far, the current request's included (one request can be most of a slice).
SPFetch sp_cdn_session(void (^pump)(double), double timeout, void (^_Nullable progress)(unsigned long long bytes));

// The config `key` (a build or CDN config, or Retail's KeyRing) in a game's Data/ folder `data`, at
// config/ab/cd/<key> as the companion writes it there: the CDN's bytes, checked against the key. Left alone
// when the file there already is that config (*fetched 0), else fetched (*fetched its size). NO and *problem
// on failure, with nothing written.
BOOL sp_cdn_store_config(NSArray<NSURL *> *servers, NSString *key, SPFetch fetch, NSString *data,
                         unsigned long long *fetched, NSString *_Nullable *_Nonnull problem);

// Whether version `a` is a later one than `b` (.build.info's Version: 1.15.9.70003, part by part as
// numbers), as the companion's GameStore.isVersion: NO when either isn't all numbers.
BOOL sp_version_newer(NSString *_Nullable a, NSString *_Nullable b);

// Whether the bundled image's build (its stamp's row, `bundled`) equals or passes an update the device made
// (`update`, its Library/spgames stamp's row): the same Build Key or Version, or a later Version. The launcher
// then deletes the update (launcher.m's retire_caught_up), since the companion has installed that build or a
// later one; ClientBuild.deviceUpdate is the companion's side of the same rule. NO when either is missing.
BOOL sp_update_caught_up(NSDictionary<NSString *, NSString *> *_Nullable bundled,
                         NSDictionary<NSString *, NSString *> *_Nullable update);

// The patch screen's news of a newer build (sppatch.m): "Classic Era 1.15.9.70003 is out", or "A new build of
// Classic Era is out" when the patch service's row has no version. No period, so the heading and the body's
// sentences both start from it.
NSString *sp_patch_news(NSString *game, NSString *_Nullable version);

// The body of the screen headed "This patch needs a Slashplayed update.": the news (sp_patch_news) and what to
// do. The device's own version goes in the screen's note, under it (sppatch.m).
NSString *sp_patch_needs_update_body(NSString *news);

// The device's .build.info once `product` is on the build the patch service's `version` row names in
// `region` (`cdns` is the region's row of its cdns table): Battle.net's header, and for the product the row
// the companion writes for that build (BlizzardCDN.buildInfoLine), its Tags kept from the product's row in
// `existing`. The other products' rows of `existing` are kept, in their order, laid out by name in the same
// columns; a product with no row gets one at the end.
NSString *sp_build_info_with(NSString *_Nullable existing, NSString *product, NSString *region,
                             NSDictionary<NSString *, NSString *> *version, NSDictionary<NSString *, NSString *> *cdns);

// ---- Installing a game on the device, with no image in the app (launcher.m, sppatch.m)

// The games the start screen offers, in flavors.plist's order (`order`, its ids; any other last, by name).
// An app with client images offers the games it bundles one of (`bundled`), as it always has, and
// *installable is empty: an update the device made of a game the app no longer bundles doesn't bring it back.
// An app with none (built without them, so it ships no Blizzard bytes: build.sh's SP_NO_IMAGES=1) offers
// every game in `order`, and *installable is the ones the device hasn't made an image of yet (`made`,
// Library/spgames), which it installs itself (sp_patch_install).
NSArray<NSString *> *sp_games(NSArray<NSString *> *order, NSArray<NSString *> *bundled, NSArray<NSString *> *made,
                              NSSet<NSString *> *_Nullable *_Nonnull installable);

// The region a game is installed in on the device: the Branch of its product's row in the device's
// .build.info (`buildInfo`'s text: a game installed before, or game data a Mac copied), else "us", the region
// the companion's first Config.wtf and sp_build_info_with's Tags already assume.
NSString *sp_install_region(NSString *_Nullable buildInfo, NSString *product);

// The game's .flavor.info, as Battle.net writes it in the game's folder and the companion sends it
// (GameFiles.flavorInfo): its product, as a one-column table.
NSString *sp_flavor_info(NSString *product);

NS_ASSUME_NONNULL_END
