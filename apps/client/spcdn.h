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
// the key that names it. *tags (when given) gets the build's install manifest's tag names once it's read
// (the platforms, regions, and locales it ships: sp_locale_shipped), nil if it wasn't. NO and *problem on
// failure.
BOOL sp_cdn_slice(NSArray<NSURL *> *servers, NSString *buildConfig, NSString *cdnConfig, NSString *executable,
                  NSString *region, SPFetch fetch, NSString *output, NSArray<NSString *> *_Nullable *_Nullable tags,
                  NSString *_Nullable *_Nonnull problem);

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
// later one; ClientBuild.clientCopy is the companion's side of the same rule (a client it copies over is one
// this calls caught up with the Mac's). NO when either is missing.
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
// the companion writes for that build (BlizzardCDN.buildInfoLine). Its Tags are `tags` when given (the game's
// region's: sp_game_region), else kept from the product's row in
// `existing`, else a US English Mac install's. The other products' rows of `existing` are kept, in their
// order, laid out by name in the same columns; a product with no row gets one at the end.
NSString *sp_build_info_with(NSString *_Nullable existing, NSString *product, NSString *region, NSString *_Nullable tags,
                             NSDictionary<NSString *, NSString *> *version, NSDictionary<NSString *, NSString *> *cdns);

// The device's .build.info once `product`'s row is the one for the build an image made on the device is
// (Library/spgames/wow-<flavor>), so the client streams that build's data: `kept` is the .build.info
// text update wrote beside the image when it made it (spgames/spbuildinfo-<flavor>, sp_build_info_with's
// for its build with no existing rows), `stamp` the image's stamp. Laid out as sp_build_info_with lays it,
// the Tags kept from `existing`'s row. With `region` (Branch and Tags: the game's region,
// sp_game_region), the row is in that region instead, with those Tags, and is written again when `existing`'s
// has another Branch or Tags too, so a region picked in Settings isn't put back by the Mac's row. nil when `existing`'s row is
// already that build's (and in `region`) (*why nil), or when it isn't and `kept` has no row for that build to
// write (*why says so, for the log: an image made before the row was kept beside it).
NSString *_Nullable sp_build_info_for_image(NSString *_Nullable existing, NSString *product, NSString *_Nullable kept,
                                            NSString *_Nullable stamp, NSDictionary<NSString *, NSString *> *_Nullable region,
                                            NSString *_Nullable *_Nonnull why);

// ---- The region a game plays in (issues #34 and #132)
//
// Each game has its own, as Battle.net does it, and a person can pick it on the device for every game
// (Settings' Region). Only a pick is saved, in Library/sppickedregion-<flavor> (one word), and it always wins:
// nothing but Settings writes it, so a Mac's Play, an Update on either side, and an install again all leave it.
// Without one, the game follows the Mac when the Mac has said a region for it (Library/spmacregion-<flavor>, its
// install's .build.info row, which the companion sends at every Play and nothing on the device rewrites), else the
// device's region, worked out at every start and never saved. Everything else follows the result at each start:
// the patch check's region, an Update's kept row and stamp, the start-time .build.info rewrite, and Config.wtf.
// A region differs in more than the portal: its languages (Config.wtf's textLocale and audioLocale, and the
// row's Tags, which say what the client streams), and at times its build (the patch check then offers that
// region's build as an Update).

// The regions a person can pick, in Settings' order: us, eu, kr, tw.
NSArray<NSString *> *sp_regions(void);

// Blizzard's region for a country (ISO 3166-1 alpha-2: the device's region in Settings): kr for South Korea;
// tw for Taiwan, Hong Kong, and Macao; eu for Europe, Russia, the Middle East, and Africa; else us (the
// Americas, Oceania, and every country not mapped). Never cn, sg, or xx.
NSString *sp_region_for_country(NSString *_Nullable country);

// What a person reads for a region: Americas, Europe, Korea, Taiwan (the code in capitals for another).
NSString *sp_region_name(NSString *region);

// The game's locales in a region, its default first: us enUS esMX ptBR; eu enUS deDE esES frFR itIT ruRU;
// kr koKR; tw zhTW. Empty for another region. Europe's English is enUS: the clients have no enGB.
NSArray<NSString *> *sp_region_locales(NSString *region);

// Whether a build ships `locale`, by its install manifest's tag names (`shipped`; nil when not known: YES).
BOOL sp_locale_shipped(NSString *locale, NSArray<NSString *> *_Nullable shipped);

// The text language a game in `region` gets: the first of `preferred` (BCP 47: the device's preferred
// languages, in order) whose language is one of the region's locales' and that the build ships (`shipped`,
// sp_locale_shipped), else the region's default (us enUS, eu enUS, kr koKR, tw zhTW). Speech follows it.
NSString *sp_region_locale(NSString *region, NSArray<NSString *> *preferred, NSArray<NSString *> *_Nullable shipped);

// .build.info's Tags for a game in `region` with those languages, in Flavor.tags' layout (the speech group,
// then the text group): "OSX x86_64 EU? deDE speech?:OSX x86_64 EU? deDE text?".
NSString *sp_region_tags(NSString *region, NSString *text, NSString *speech);

// The text and speech locales a Tags value names (nil for one it doesn't).
void sp_tags_locales(NSString *_Nullable tags, NSString *_Nullable *_Nonnull text, NSString *_Nullable *_Nonnull speech);

// What a person reads for where the region came from (sp_game_region's Source): "picked on device",
// "following the Mac", "from the device's region".
NSString *sp_region_source_name(NSString *source);

// The region a game plays in: Region, its Text and Speech locales, Tags (its .build.info row's), Source ("picked",
// "mac", or "device"), Default (the region without a pick: what Settings' first choice names), and Mac (the
// Mac's region, when it has said one). `picked`: Library/sppickedregion-<flavor>'s word; `macFile`:
// Library/spmacregion-<flavor>, a table (Product, Branch, Tags) of the Mac install's row; `shipped`: the locales
// the client's build ships (nil when not known); `country` and `preferred`: the device's region (ISO 3166-1) and
// preferred languages (BCP 47). A pick or a Mac region that isn't one of sp_regions() is passed over. In the
// Mac's region the languages and Tags are the Mac row's; in any other, the device's for that region
// (sp_region_locale) and sp_region_tags.
NSDictionary<NSString *, NSString *> *sp_game_region(NSString *product, NSString *_Nullable picked, NSString *_Nullable macFile,
                                                     NSArray<NSString *> *_Nullable shipped, NSString *_Nullable country,
                                                     NSArray<NSString *> *preferred);

// A |-separated table (a stamp, a kept .build.info) with `values` (by column name) set in `product`'s rows, its
// own header and column order kept. nil when nothing changes (or there's no such row or column).
NSString *_Nullable sp_table_with(NSString *_Nullable text, NSString *product, NSDictionary<NSString *, NSString *> *values);

// Config.wtf with the game's region and languages (`choice`: sp_game_region) as portal, textLocale, and
// audioLocale. Started by Battle.net the client takes them from its launch options, which nothing writes on
// the device, and with neither it opens a region picker the device can't show and exits. A missing or empty
// one is always set. With a portal that isn't the region, the region moved (Settings, or Battle.net on the
// Mac), or the portal was never the region (the first Config.wtf an older companion sent said "us" whatever the
// Mac's region, issue #94): all three are replaced. Otherwise a value set stays (a language picked in the game's
// options).
// *set: the names set (empty for none).
NSString *sp_config_with_region(NSString *_Nullable config, NSDictionary<NSString *, NSString *> *choice,
                                NSArray<NSString *> *_Nullable *_Nonnull set);

// ---- The game's client in Library/spgames (launcher.m, sppatch.m)

// Why the file at `path` isn't a client spguest can load, or nil when it is: spguest's own parse of the
// header and load commands (spguest_check_file), so nothing passes here that the load refuses, a build with
// chained fixups included. An image an older Slashplayed made on the device (an MH_BUNDLE, assembled and
// signed there), an arm64e file, or one a copy left short each has a reason, in a few words for the log
// and the screen.
NSString *_Nullable sp_slice_problem(NSString *path);

// The game's client in `games` (Library/spgames: wow-<flavor>) retired when it isn't a slice spguest can
// load (sp_slice_problem): its stamp first (spbuild-<flavor>, so a file left behind is never taken for its
// build), then the file, its kept .build.info row (spbuildinfo-<flavor>), and spsource-<flavor>. The game
// data stays. Whatever the client, the copies 1.4 and earlier left beside it when their signing stopped part
// way (wow-<flavor>.signing, .signed) go too. A line for the log (versions, sizes, and the reason), or nil when
// there was nothing to retire.
NSString *_Nullable sp_slice_retire(NSString *games, NSString *flavor, NSString *product);

// The games the start screen offers: every game flavors.plist lists (`order`, its ids; any other last, by
// name), in its order. *installable is the ones the device has nothing of (`made`: those with a client in
// Library/spgames, or game data to get one for), which it installs itself (sp_patch_install).
NSArray<NSString *> *sp_games(NSArray<NSString *> *order, NSArray<NSString *> *made, NSSet<NSString *> *_Nullable *_Nonnull installable);

// The game's .flavor.info, as Battle.net writes it in the game's folder and the companion sends it
// (GameFiles.flavorInfo): its product, as a one-column table.
NSString *sp_flavor_info(NSString *product);

// The addons the app carries (`addons`: the app's addons/, each <name>/<name>.toc and .lua as addon/ has
// them; apps/client/build.sh and the companion's ClientAssembly put them there) into a game's folder
// (`game`: Documents/_<flavor>_), at Interface/AddOns/<name>/, as the companion used to copy them: SPMovie
// on every device, SPHover with `hover` (the headset: the iPad and iPhone have a real pointer), and
// SPKeyboard without it (the iPad and iPhone: the focused text box, for the on-screen keyboard). Each file is
// written when the game's copy is missing or its bytes differ, and left alone otherwise. Each TOC lists every
// flavor's Interface number, so one copy suits each game. A line for the log; NO when one couldn't be
// read or written (*line says which).
BOOL sp_addons_place(NSString *addons, NSString *game, BOOL hover, NSString *_Nullable *_Nonnull line);

NS_ASSUME_NONNULL_END
