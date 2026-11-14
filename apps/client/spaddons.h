// Addons on the device (spaddons.m): installing, updating, and removing the addons in each game's
// Interface/AddOns, from Slashplayed's catalog (https://github.com/paulstraw/slashplayed-addons, published
// as addons.json) or a GitHub link, with no key and no companion. Foundation only, so the companion's tests
// build it for the Mac too and run it against zips and catalogs they make themselves.
#import <Foundation/Foundation.h>
#import "spcdn.h"  // SPFetch

NS_ASSUME_NONNULL_BEGIN

// ---- zips

// The addon folders a zip holds, as the catalog's build finds them: each top-level folder with a TOC named
// after it ({"name", "path": its prefix in the zip}), with every TOC's Interface numbers (*interfaces) and the
// dependencies the zip doesn't hold (*requires). nil and *problem when the zip is damaged or unsafe (an
// absolute path, a "..", a backslash, a symlink, a zip64 or encrypted entry) or holds no addon folder.
NSArray<NSDictionary *> *_Nullable sp_zip_addon_folders(NSData *zip, NSArray<NSNumber *> *_Nullable *_Nullable interfaces,
                                                        NSArray<NSString *> *_Nullable *_Nullable requires,
                                                        NSString *_Nullable *_Nonnull problem);

// Unpacks the entries under each of `folders`' prefixes ({"name", "path"}) into <into>/<name>/, refusing the
// whole zip as sp_zip_addon_folders does, and a folder name that isn't one WoW loads or is Slashplayed's own
// (SPMovie, SPHover, SPKeyboard). Entries outside the prefixes are skipped. Each entry's size and CRC are checked.
BOOL sp_zip_unpack(NSData *zip, NSArray<NSDictionary *> *folders, NSString *into, NSString *_Nullable *_Nonnull problem);

// ---- the catalog

// addons.json, checked: nil and *problem when it isn't schema 1.
NSDictionary *_Nullable sp_addons_catalog(NSData *_Nullable json, NSString *_Nullable *_Nonnull problem);

// The catalog's addons offered for `flavor`, by name: each its catalog entry with "file", its one file for
// that game (the catalog puts each game in at most one).
NSArray<NSDictionary *> *sp_addons_offered(NSDictionary *_Nullable catalog, NSString *flavor);

// ---- one game's addons
//
// `game` is the game's folder (Documents/_<flavor>_), `record` its record of what Slashplayed installed
// (Library/spaddons-<flavor>.json: each addon's id, name, version, source, file and SHA-256, folders, and
// requirements), `staging` a folder in Library/ for downloads and the swaps (the same volume as Documents/,
// so each folder moves in one rename). SPMovie, SPHover, and SPKeyboard, Slashplayed’s own, are never listed or touched,
// and neither is a folder no record owns, unless the person installs a catalog addon of that folder's name.

// What's in the game's Interface/AddOns, for Settings' Installed list: one row per recorded addon, then per
// catalog addon whose folders were added by hand, then per other folder (with folders named after another's
// prefix, Details_Compare under Details). Each row: "id", "name", "version" (maybe empty), "source"
// ("catalog", "github", or "hand"), "folders", and when known "latest" and "update" (@YES: a newer file),
// "catalog" (the catalog id a hand-added folder matches), "repo", "updated" (when an update last changed it) and
// "previous" (the version before), and "needs" (required folders that aren't there).
NSArray<NSDictionary *> *sp_addons_list(NSString *game, NSString *record, NSDictionary *_Nullable catalog, NSString *flavor);

// A GitHub repository link ("https://github.com/owner/repo", "owner/repo") resolved to something to install
// for `flavor`: the catalog's entry when the catalog has the repo, else its latest release's file, chosen by
// the BigWigs packager's release.json, else its one zip, else a zip named for the game. nil and *problem when
// there's none.
NSDictionary *_Nullable sp_addons_github(NSString *link, NSString *flavor, NSDictionary *_Nullable catalog, SPFetch fetch,
                                         NSString *_Nullable *_Nonnull problem);

// Installs or updates `entry` (an sp_addons_offered or sp_addons_github one): downloads its file, checks its
// size and SHA-256 (a GitHub file without one is checked against the game's Interface range instead), unpacks
// it into `staging`, swaps each folder into place, deletes the folders its last version had and this one
// doesn't (unless another addon has them), and records it. A line for the log, or nil and *problem.
NSString *_Nullable sp_addons_install(NSDictionary *entry, NSString *flavor, NSDictionary *_Nullable catalog, NSString *game,
                                      NSString *record, NSString *staging, SPFetch fetch, NSString *_Nullable *_Nonnull problem);

// Deletes the recorded addon `ident`'s folders (but those another recorded addon has) and its record. A line
// for the log, or nil and *problem.
NSString *_Nullable sp_addons_remove(NSString *ident, NSString *game, NSString *record, NSString *staging,
                                     NSString *_Nullable *_Nonnull problem);

// Stores the latest release of each GitHub-linked addon in `record` as its "latest" (fetching each repo's latest
// release), for sp_addons_list's update. A line for the log.
NSString *sp_addons_check_github(NSString *record, NSString *flavor, SPFetch fetch);

// ---- the device's: each game's paths in the app's container, the catalog kept in Library/, and one serial
// queue for everything below (a download and its swap never interleave with another's), each `done` on the
// main queue with nil or what went wrong, for the person.

// The catalog as last downloaded (Library/spaddons-catalog.json), nil before the first.
NSDictionary *_Nullable sp_addons_cached_catalog(void);
// sp_addons_list and sp_addons_offered for the game, with that catalog; and the game's Interface/AddOns.
NSArray<NSDictionary *> *sp_addons_rows(NSString *flavor);
NSArray<NSDictionary *> *sp_addons_browse(NSString *flavor);
NSString *sp_addons_folder(NSString *flavor);
// Downloads the catalog and checks the game's GitHub links (sp_addons_check_github).
void sp_addons_refresh(NSString *flavor, void (^done)(NSString *_Nullable problem));
// `action` on `argument`: "install" a catalog id, "update" a row's id, "remove" a recorded id, "link" a GitHub
// link, or "update-all".
void sp_addons_run(NSString *flavor, NSString *action, NSString *argument, void (^done)(NSString *_Nullable problem));
// "Update addons automatically", for every game.
BOOL sp_addons_auto(void);
void sp_addons_set_auto(BOOL on);
// The start screen's check (launcher.m, before the start screen): at most every 3 hours, the catalog, each
// game's GitHub links, and with sp_addons_auto the updates of what Slashplayed installed. In the background,
// logged, never on the screen.
void sp_addons_background(NSArray<NSString *> *flavors);

// After this, nothing is swapped into any game's AddOns (an install's files are left in staging, and it fails):
// the launcher calls it once a game is picked, since the game reads its AddOns from then on, in this process.
// Waits for a swap already under way.
void sp_addons_hold(void);

NS_ASSUME_NONNULL_END
