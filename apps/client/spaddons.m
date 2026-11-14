// Addons on the device: the catalog (https://github.com/paulstraw/slashplayed-addons, whose README has
// addons.json's schema), GitHub links, a zip reader over zlib, each game's record of what Slashplayed
// installed, and the installs, updates, and removals (spaddons.h). Settings' Addons screen
// (spaddonsscreen.swift) and the start screen's check run them on one serial queue (the device's side, at the
// end), never once a game has started: the game reads its AddOns in this process (sp_addons_hold).
//
// Nothing here hosts or builds an addon: each file is its author's, from the URL the catalog (or the GitHub
// release) gives, checked against the catalog's size and SHA-256 before a byte of it is unpacked. Zips come
// from third parties, so the reader refuses any path that could land outside the folder it names, symlinks,
// and anything it can't check (zip64, encryption, other compression methods), and every entry's size and CRC
// are checked as it's inflated. Each folder is unpacked under Library/ and swapped into AddOns in one rename
// (renamex_np's RENAME_SWAP when it's there already), so a game never sees half a folder.
#import "spaddons.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

// A zip that big is no addon (All The Things, among the largest, is 19 MB packed): refused before it's
// read, and its unpacked total too, so a crafted one can't fill the device.
static const NSUInteger max_zip = 300u << 20, max_unpacked = 1u << 30;

// Slashplayed's own addons (sp_addons_place): never listed, installed over, or removed here.
static BOOL ours(NSString *folder) {
    for (NSString *mine in @[@"SPMovie", @"SPHover", @"SPKeyboard"])
        if ([folder caseInsensitiveCompare:mine] == NSOrderedSame) return YES;
    return NO;
}

// A folder name WoW loads and that's safe to make: no separators, no dot names (the catalog's build.py FOLDER).
static BOOL folder_name_ok(NSString *name) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9!][A-Za-z0-9 _.!+-]*$" options:0 error:nil]; });
    return [name isKindOfClass:NSString.class] && name.length <= 128 &&
           [re numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] == 1;
}

static NSString *hex(const uint8_t *b, size_t n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSString *sha256(NSData *d) {
    uint8_t md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, md);
    return hex(md, sizeof md);
}

// ---- the zip reader: the central directory, then each entry's local header and data (stored or raw deflate)

@interface SPZipEntry : NSObject
@property NSString *name;
@property uint32_t crc, csize, usize, local;
@property uint16_t method;
@end
@implementation SPZipEntry
@end

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return le16(p) | (uint32_t)le16(p + 2) << 16; }

// Why `name` can't be unpacked as it stands, or nil (build.py's read_zip refuses the same).
static NSString *unsafe_name(NSString *name) {
    if (!name.length || [name hasPrefix:@"/"] || [name containsString:@"\\"] || [name containsString:@":"] ||
        [name rangeOfString:@"\0"].location != NSNotFound)
        return @"an unsafe path";
    for (NSString *part in [name componentsSeparatedByString:@"/"])
        if ([part isEqual:@"."] || [part isEqual:@".."]) return @"an unsafe path";
    return nil;
}

// Every entry, in the central directory's order; nil and *problem if any one can't be trusted.
static NSArray<SPZipEntry *> *zip_entries(NSData *zip, NSString **problem) {
    const uint8_t *b = zip.bytes;
    NSUInteger n = zip.length;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)n - 22; i >= 0 && i >= (NSInteger)n - 22 - 0xFFFF; i--)
        if (le32(b + i) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0) { *problem = @"it isn't a zip"; return nil; }
    uint16_t count = le16(b + eocd + 10);
    uint32_t cd_size = le32(b + eocd + 12), cd_off = le32(b + eocd + 16);
    if (le16(b + eocd + 4) || le16(b + eocd + 6)) { *problem = @"it's a zip split across files"; return nil; }
    if (count == 0xFFFF || cd_size == 0xFFFFFFFF || cd_off == 0xFFFFFFFF) { *problem = @"it's a zip64, which isn't read here"; return nil; }
    if ((uint64_t)cd_off + cd_size > (uint64_t)eocd) { *problem = @"the zip is damaged"; return nil; }
    NSMutableArray<SPZipEntry *> *entries = [NSMutableArray arrayWithCapacity:count];
    uint64_t unpacked = 0;
    NSUInteger p = cd_off, end = cd_off + cd_size;
    for (uint16_t i = 0; i < count; i++) {
        if (p + 46 > end || le32(b + p) != 0x02014b50) { *problem = @"the zip is damaged"; return nil; }
        uint16_t made = le16(b + p + 4), flags = le16(b + p + 8), method = le16(b + p + 10);
        uint16_t name_len = le16(b + p + 28), extra_len = le16(b + p + 30), comment_len = le16(b + p + 32);
        uint32_t external = le32(b + p + 38);
        if (p + 46 + name_len + extra_len + comment_len > end) { *problem = @"the zip is damaged"; return nil; }
        SPZipEntry *e = [SPZipEntry new];
        e.crc = le32(b + p + 16);
        e.csize = le32(b + p + 20);
        e.usize = le32(b + p + 24);
        e.local = le32(b + p + 42);
        e.method = method;
        e.name = [[NSString alloc] initWithBytes:b + p + 46 length:name_len encoding:NSUTF8StringEncoding];
        p += 46 + name_len + extra_len + comment_len;
        if (!e.name) { *problem = @"a name in the zip isn't UTF-8"; return nil; }
        NSString *why = unsafe_name(e.name);
        if (!why && (made >> 8) == 3 && ((external >> 16) & S_IFMT) == S_IFLNK) why = @"a symlink";
        if (!why && (flags & 1)) why = @"an encrypted file";
        if (!why && (e.csize == 0xFFFFFFFF || e.usize == 0xFFFFFFFF || e.local == 0xFFFFFFFF)) why = @"a zip64 entry";
        if (!why && method != 0 && method != 8) why = [NSString stringWithFormat:@"compression method %u", method];
        if (why) { *problem = [NSString stringWithFormat:@"the zip has %@ (%@)", why, e.name]; return nil; }
        if ((unpacked += e.usize) > max_unpacked) { *problem = @"the zip unpacks to more than 1 GB"; return nil; }
        [entries addObject:e];
    }
    return entries;
}

// An entry's bytes, its size and CRC checked; nil and *problem if they're wrong.
static NSData *zip_data(NSData *zip, SPZipEntry *e, NSString **problem) {
    const uint8_t *b = zip.bytes;
    uint64_t at = e.local;
    if (at + 30 > zip.length || le32(b + at) != 0x04034b50) { *problem = [@"the zip is damaged at " stringByAppendingString:e.name]; return nil; }
    at += 30 + le16(b + at + 26) + le16(b + at + 28);
    if (at + e.csize > zip.length) { *problem = [@"the zip is cut short at " stringByAppendingString:e.name]; return nil; }
    NSData *out = nil;
    if (e.method == 0) {
        if (e.csize == e.usize) out = [zip subdataWithRange:NSMakeRange((NSUInteger)at, e.csize)];
    } else {
        NSMutableData *buf = [NSMutableData dataWithLength:e.usize];
        z_stream z = {0};
        if (inflateInit2(&z, -MAX_WBITS) == Z_OK) {
            z.next_in = (Bytef *)b + at;
            z.avail_in = e.csize;
            z.next_out = buf.mutableBytes;
            z.avail_out = e.usize;
            int r = inflate(&z, Z_FINISH);
            // An empty entry may end its stream with no output room at all (Z_BUF_ERROR on a zero-length buffer).
            if ((r == Z_STREAM_END || (r == Z_BUF_ERROR && !e.usize)) && z.total_out == e.usize) out = buf;
            inflateEnd(&z);
        }
    }
    if (out && (uint32_t)crc32(0, out.bytes, (uInt)out.length) != e.crc) out = nil;
    if (!out) *problem = [@"the zip is damaged at " stringByAppendingString:e.name];
    return out;
}

// ---- TOCs

// A TOC's "## Name: value" fields, by lowercased name.
static NSDictionary<NSString *, NSString *> *toc_fields(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                     ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\uFEFF \t"]];
        if (![line hasPrefix:@"##"]) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[line substringWithRange:NSMakeRange(2, colon.location - 2)]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        NSString *value = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length && !fields[key]) fields[key] = value;
    }
    return fields;
}

// The numbers in a field ("11509, 120105").
static NSArray<NSNumber *> *numbers(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    NSScanner *s = [NSScanner scannerWithString:text ?: @""];
    s.charactersToBeSkipped = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    NSInteger n;
    while ([s scanInteger:&n]) [out addObject:@(n)];
    return out;
}

// WoW reads Dependencies, RequiredDeps, and any field starting with Dep as required.
static NSArray<NSString *> *toc_requires(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in fields)
        if ([key isEqual:@"dependencies"] || [key isEqual:@"requireddeps"] || [key hasPrefix:@"dep"])
            for (NSString *d in [fields[key] componentsSeparatedByString:@","]) {
                NSString *name = [d stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (name.length) [out addObject:name];
            }
    return out;
}

// A TOC's text without WoW's color and texture escapes (|cffrrggbb, |r, |T...|t).
static NSString *plain(NSString *s) {
    if (!s) return nil;
    NSString *out = [s stringByReplacingOccurrencesOfString:@"\\|c[0-9A-Fa-f]{8}|\\|r|\\|T[^|]*\\|t" withString:@""
                                                    options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
    out = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return out.length ? out : nil;
}

static NSArray<NSString *> *case_sorted(NSSet<NSString *> *set) {
    return [set.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}

NSArray<NSDictionary *> *sp_zip_addon_folders(NSData *zip, NSArray<NSNumber *> **interfaces_out, NSArray<NSString *> **requires_out,
                                              NSString **problem) {
    NSArray<SPZipEntry *> *entries = zip_entries(zip, problem);
    if (!entries) return nil;
    NSMutableSet<NSString *> *tops = [NSMutableSet set];
    for (SPZipEntry *e in entries) {
        NSRange slash = [e.name rangeOfString:@"/"];
        if (slash.location != NSNotFound) [tops addObject:[e.name substringToIndex:slash.location]];
    }
    NSMutableArray<NSDictionary *> *folders = [NSMutableArray array];
    NSMutableArray<SPZipEntry *> *tocs = [NSMutableArray array];
    for (NSString *top in case_sorted(tops)) {
        NSString *prefix = [top stringByAppendingString:@"/"];
        BOOL addon = NO;
        for (SPZipEntry *e in entries) {
            NSString *rest = [e.name hasPrefix:prefix] ? [e.name substringFromIndex:prefix.length] : nil;
            if (![rest hasSuffix:@".toc"] || [rest containsString:@"/"]) continue;
            [tocs addObject:e];
            if ([rest.stringByDeletingPathExtension hasPrefix:top]) addon = YES;
        }
        if (!addon) continue;
        if (!folder_name_ok(top)) { *problem = [NSString stringWithFormat:@"the zip has a folder WoW can't load (%@)", top]; return nil; }
        [folders addObject:@{@"name": top, @"path": prefix}];
    }
    if (!folders.count) { *problem = @"the zip has no addon folder (one with a TOC named after it)"; return nil; }
    NSMutableSet<NSNumber *> *interfaces = [NSMutableSet set];
    NSMutableSet<NSString *> *deps = [NSMutableSet set], *inside = [NSMutableSet set];
    for (NSDictionary *f in folders) [inside addObject:[f[@"name"] lowercaseString]];
    for (SPZipEntry *e in tocs) {
        if (![inside containsObject:[e.name componentsSeparatedByString:@"/"][0].lowercaseString]) continue;
        NSData *data = zip_data(zip, e, problem);
        if (!data) return nil;
        NSDictionary *fields = toc_fields(data);
        [interfaces addObjectsFromArray:numbers(fields[@"interface"])];
        for (NSString *d in toc_requires(fields))
            if (![inside containsObject:d.lowercaseString]) [deps addObject:d];
    }
    if (interfaces_out) *interfaces_out = [interfaces.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (requires_out) *requires_out = case_sorted(deps);
    return folders;
}

BOOL sp_zip_unpack(NSData *zip, NSArray<NSDictionary *> *folders, NSString *into, NSString **problem) {
    for (NSDictionary *f in folders) {
        if (![f isKindOfClass:NSDictionary.class]) { *problem = @"its folders can't be read"; return NO; }
        NSString *name = f[@"name"], *path = f[@"path"];
        if (!folder_name_ok(name) || ours(name)) {
            *problem = [NSString stringWithFormat:@"it names a folder that can't be installed (%@)", name];
            return NO;
        }
        if (![path isKindOfClass:NSString.class] || ![path hasSuffix:@"/"] || unsafe_name(path)) {
            *problem = [NSString stringWithFormat:@"it names an unsafe path for %@", name];
            return NO;
        }
    }
    NSArray<SPZipEntry *> *entries = zip_entries(zip, problem);
    if (!entries) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSDictionary *f in folders) {
        NSString *path = f[@"path"], *dir = [into stringByAppendingPathComponent:f[@"name"]];
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) {
            *problem = [@"couldn't make a folder for " stringByAppendingString:f[@"name"]];
            return NO;
        }
        NSUInteger files = 0;
        for (SPZipEntry *e in entries) {
            if (![e.name hasPrefix:path] || e.name.length == path.length) continue;
            NSString *dest = [dir stringByAppendingPathComponent:[e.name substringFromIndex:path.length]];
            if ([e.name hasSuffix:@"/"]) {
                [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
                continue;
            }
            NSData *data = zip_data(zip, e, problem);
            if (!data) return NO;
            [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![data writeToFile:dest options:0 error:nil]) {
                *problem = [@"couldn't write " stringByAppendingString:e.name];
                return NO;
            }
            files++;
        }
        if (!files) {
            *problem = [NSString stringWithFormat:@"it has nothing for %@", f[@"name"]];
            return NO;
        }
    }
    return YES;
}

// ---- the catalog

NSDictionary *sp_addons_catalog(NSData *json, NSString **problem) {
    id d = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![d isKindOfClass:NSDictionary.class] || ![d[@"addons"] isKindOfClass:NSArray.class]) {
        *problem = @"The addon catalog couldn't be read.";
        return nil;
    }
    if (![d[@"schema"] isEqual:@1]) {
        *problem = @"The addon catalog needs a newer Slashplayed.";
        return nil;
    }
    return d;
}

NSArray<NSDictionary *> *sp_addons_offered(NSDictionary *catalog, NSString *flavor) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *a in catalog[@"addons"]) {
        if (![a isKindOfClass:NSDictionary.class] || ![a[@"id"] isKindOfClass:NSString.class]) continue;
        for (NSDictionary *f in a[@"files"])
            if ([f isKindOfClass:NSDictionary.class] && [f[@"flavors"] isKindOfClass:NSArray.class] && [f[@"flavors"] containsObject:flavor]) {
                NSMutableDictionary *e = [a mutableCopy];
                e[@"file"] = f;
                e[@"source"] = @"catalog";
                if (![e[@"name"] isKindOfClass:NSString.class]) e[@"name"] = a[@"id"];
                [out addObject:e];
                break;
            }
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return out;
}

// The catalog's addon whose GitHub repo is `repo` ("owner/name"), in any game.
static NSDictionary *catalog_repo(NSDictionary *catalog, NSString *repo) {
    for (NSDictionary *a in catalog[@"addons"]) {
        NSString *r = [a isKindOfClass:NSDictionary.class] && [a[@"recipe"] isKindOfClass:NSDictionary.class] ? a[@"recipe"][@"repo"] : nil;
        if ([r isKindOfClass:NSString.class] && [r caseInsensitiveCompare:repo] == NSOrderedSame) return a;
    }
    return nil;
}

// Whether any of `interfaces` is in the catalog's range for `flavor` ("flavors": {flavor: [low, high]}). YES
// when the catalog doesn't say.
static BOOL interfaces_fit(NSArray<NSNumber *> *interfaces, NSDictionary *catalog, NSString *flavor) {
    NSArray *range = [catalog[@"flavors"] isKindOfClass:NSDictionary.class] ? catalog[@"flavors"][flavor] : nil;
    if (![range isKindOfClass:NSArray.class] || range.count != 2) return YES;
    for (NSNumber *i in interfaces)
        if (i.integerValue >= [range[0] integerValue] && i.integerValue <= [range[1] integerValue]) return YES;
    return NO;
}

// ---- the record

static NSMutableArray<NSMutableDictionary *> *record_read(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id d = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableArray *out = [NSMutableArray array];
    if ([d isKindOfClass:NSDictionary.class] && [d[@"addons"] isKindOfClass:NSArray.class])
        for (id a in d[@"addons"])
            if ([a isKindOfClass:NSMutableDictionary.class] && [a[@"id"] isKindOfClass:NSString.class] &&
                [a[@"folders"] isKindOfClass:NSArray.class])
                [out addObject:a];
    return out;
}

static BOOL record_write(NSString *path, NSArray *addons) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"addons": addons}
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    return [data writeToFile:path atomically:YES];
}

static NSMutableDictionary *record_find(NSArray<NSMutableDictionary *> *addons, NSString *ident) {
    for (NSMutableDictionary *a in addons)
        if ([a[@"id"] isEqual:ident]) return a;
    return nil;
}

// ---- what's in AddOns

static NSString *addons_dir(NSString *game) { return [game stringByAppendingPathComponent:@"Interface/AddOns"]; }

// The folders in AddOns, Slashplayed's own and hidden ones left out.
static NSArray<NSString *> *folders_in(NSString *dir) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        BOOL isDir = NO;
        if ([name hasPrefix:@"."] || ours(name) ||
            ![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:name] isDirectory:&isDir] || !isDir)
            continue;
        [out addObject:name];
    }
    return [out sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}

// The suffixes a TOC for `flavor` may carry (Folder_Mainline.toc and the like), the game's own first.
static NSArray<NSString *> *toc_suffixes(NSString *flavor) {
    NSDictionary *by = @{@"retail": @[@"Mainline"], @"classic_era": @[@"Vanilla", @"Classic"], @"anniversary": @[@"TBC", @"BCC"],
                         @"classic": @[@"Mists"], @"forever": @[@"Forever"]};
    return by[flavor] ?: @[];
}

// The fields of the TOC the game reads in `folder`: the game's own (Folder_Mainline.toc), else Folder.toc,
// else the first one named after the folder.
static NSDictionary<NSString *, NSString *> *folder_toc(NSString *dir, NSString *folder, NSString *flavor) {
    NSString *path = [dir stringByAppendingPathComponent:folder];
    NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *s in toc_suffixes(flavor)) {
        [names addObject:[NSString stringWithFormat:@"%@_%@.toc", folder, s]];
        [names addObject:[NSString stringWithFormat:@"%@-%@.toc", folder, s]];
    }
    [names addObject:[folder stringByAppendingString:@".toc"]];
    for (NSString *f in files)
        if ([f.pathExtension isEqual:@"toc"] && [f hasPrefix:folder]) [names addObject:f];
    for (NSString *name in names)
        for (NSString *f in files)
            if ([f caseInsensitiveCompare:name] == NSOrderedSame) {
                NSData *d = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:f]];
                if (d) return toc_fields(d);
            }
    return @{};
}

static NSString *toc_version(NSDictionary *fields) {
    NSString *v = plain(fields[@"version"]);
    return [v containsString:@"@"] ? nil : v;  // an unpackaged "@project-version@"
}

NSArray<NSDictionary *> *sp_addons_list(NSString *game, NSString *record, NSDictionary *catalog, NSString *flavor) {
    NSString *dir = addons_dir(game);
    NSArray<NSString *> *present = folders_in(dir);
    NSMutableSet<NSString *> *left = [NSMutableSet setWithArray:present];
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *offered = [NSMutableDictionary dictionary];
    for (NSDictionary *e in sp_addons_offered(catalog, flavor)) offered[e[@"id"]] = e;
    NSSet *lower = [NSSet setWithArray:[present valueForKey:@"lowercaseString"]];
    NSArray *(^needs)(NSArray *) = ^NSArray *(NSArray *requires) {
        NSMutableArray *out = [NSMutableArray array];
        if (![requires isKindOfClass:NSArray.class]) return out;
        for (NSString *r in requires)
            if ([r isKindOfClass:NSString.class] && ![lower containsObject:r.lowercaseString]) [out addObject:r];
        return out;
    };
    // What Slashplayed installed: a record whose folders are all gone (deleted in Files) isn't listed.
    for (NSDictionary *a in record_read(record)) {
        NSMutableArray *mine = [NSMutableArray array];
        for (NSString *f in a[@"folders"])
            if ([present containsObject:f]) [mine addObject:f];
        if (!mine.count) continue;
        [left minusSet:[NSSet setWithArray:mine]];
        NSMutableDictionary *row = [@{@"id": a[@"id"], @"name": a[@"name"] ?: a[@"id"], @"version": a[@"version"] ?: @"",
                                      @"source": a[@"source"] ?: @"catalog", @"folders": mine,
                                      @"needs": needs(a[@"requires"])} mutableCopy];
        for (NSString *k in @[@"repo", @"updated", @"previous"])
            if (a[k]) row[k] = a[k];
        if ([a[@"source"] isEqual:@"github"]) {
            if ([a[@"latest"] isKindOfClass:NSString.class]) {
                row[@"latest"] = a[@"latest"];
                if (![a[@"latest"] isEqual:a[@"version"]]) row[@"update"] = @YES;
            }
        } else {
            NSDictionary *e = offered[a[@"id"]];
            if (e) {
                row[@"latest"] = e[@"version"] ?: @"";
                if (![e[@"file"][@"sha256"] isEqual:a[@"sha256"]]) row[@"update"] = @YES;
            }
        }
        [rows addObject:row];
    }
    // Folders added by hand that a catalog addon installs: updatable from it.
    for (NSDictionary *e in offered.allValues) {
        NSMutableArray *mine = [NSMutableArray array];
        for (NSDictionary *f in e[@"file"][@"folders"])
            if ([f isKindOfClass:NSDictionary.class] && [left containsObject:f[@"name"]]) [mine addObject:f[@"name"]];
        if (!mine.count) continue;
        [left minusSet:[NSSet setWithArray:mine]];
        NSString *version = toc_version(folder_toc(dir, mine[0], flavor)) ?: @"";
        [rows addObject:@{@"id": [@"hand:" stringByAppendingString:e[@"id"]], @"name": e[@"name"], @"version": version,
                          @"source": @"hand", @"catalog": e[@"id"], @"folders": mine, @"latest": e[@"version"] ?: @"",
                          @"update": @(![version isEqual:e[@"version"]]), @"needs": needs(e[@"file"][@"requires"])}];
    }
    // The rest, updated by hand: one row per folder, with the folders named after another's prefix under it.
    NSArray<NSString *> *rest = case_sorted(left);
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
    for (NSString *f in rest) {
        NSString *owner = f;
        for (NSString *g in rest)
            if (g.length < owner.length && ([f hasPrefix:[g stringByAppendingString:@"_"]] || [f hasPrefix:[g stringByAppendingString:@"-"]]))
                owner = g;
        groups[owner] = groups[owner] ?: [NSMutableArray array];
        [groups[owner] addObject:f];
    }
    for (NSString *owner in case_sorted([NSSet setWithArray:groups.allKeys])) {
        NSDictionary *toc = folder_toc(dir, owner, flavor);
        [rows addObject:@{@"id": [@"folder:" stringByAppendingString:owner], @"name": plain(toc[@"title"]) ?: owner,
                          @"version": toc_version(toc) ?: @"", @"source": @"hand", @"folders": groups[owner],
                          @"needs": needs(toc_requires(toc))}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return rows;
}

// ---- GitHub

// "owner/name" from a link, or nil.
static NSString *github_repo(NSString *link) {
    NSString *s = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *p in @[@"https://", @"http://", @"www.", @"github.com/"])
        if ([s.lowercaseString hasPrefix:p]) s = [s substringFromIndex:p.length];
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"/"];
    if (parts.count < 2) return nil;
    NSString *owner = parts[0], *name = parts[1];
    if ([name.lowercaseString hasSuffix:@".git"]) name = [name substringToIndex:name.length - 4];
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."] invertedSet];
    if (!owner.length || !name.length || [owner rangeOfCharacterFromSet:bad].location != NSNotFound ||
        [name rangeOfCharacterFromSet:bad].location != NSNotFound || [name hasPrefix:@"."])
        return nil;
    return [NSString stringWithFormat:@"%@/%@", owner, name];
}

static id fetch_json(SPFetch fetch, NSString *url, NSString **problem) {
    NSString *why = nil;
    NSData *d = fetch([NSURL URLWithString:url], NSMakeRange(0, 0), &why);
    if (!d) { *problem = why; return nil; }
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (!j) *problem = @"not JSON";
    return j;
}

// The BigWigs packager's flavor names, as Slashplayed's games.
static NSString *packager_flavor(NSString *name) {
    return @{@"mainline": @"retail", @"classic": @"classic_era", @"bcc": @"anniversary", @"mists": @"classic",
             @"forever": @"forever"}[name];
}

// Words a zip's name may carry for a game, when a release has a zip per game but no release.json (TipTac).
static NSArray<NSString *> *name_hints(NSString *flavor) {
    return @{@"retail": @[@"mainline", @"retail"], @"classic_era": @[@"vanilla", @"classic-era", @"era"],
             @"anniversary": @[@"tbc", @"bcc", @"anniversary"], @"classic": @[@"mists", @"mop"],
             @"forever": @[@"forever"]}[flavor] ?: @[];
}

NSDictionary *sp_addons_github(NSString *link, NSString *flavor, NSDictionary *catalog, SPFetch fetch, NSString **problem) {
    NSString *repo = github_repo(link);
    if (!repo) { *problem = @"That isn’t a GitHub repository. Enter it as owner/repo, or paste its link."; return nil; }
    NSDictionary *known = catalog_repo(catalog, repo);
    if (known) {
        for (NSDictionary *e in sp_addons_offered(catalog, flavor))
            if ([e[@"id"] isEqual:known[@"id"]]) return e;
        *problem = [NSString stringWithFormat:@"%@ is in Slashplayed’s catalog, but has no file for this game.", known[@"name"] ?: repo];
        return nil;
    }
    NSString *why = nil;
    NSDictionary *release = fetch_json(fetch, [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repo], &why);
    if (![release isKindOfClass:NSDictionary.class] || ![release[@"assets"] isKindOfClass:NSArray.class]) {
        *problem = [why isEqual:SPCDNNotFound] ? [NSString stringWithFormat:@"%@ has no release on GitHub.", repo]
                                               : [NSString stringWithFormat:@"GitHub didn’t answer for %@ (%@).", repo, why ?: @"no release"];
        return nil;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *assets = [NSMutableDictionary dictionary];
    for (NSDictionary *a in release[@"assets"])
        if ([a isKindOfClass:NSDictionary.class] && [a[@"name"] isKindOfClass:NSString.class]) assets[a[@"name"]] = a;
    NSDictionary *chosen = nil;
    NSDictionary *manifest = assets[@"release.json"] ? fetch_json(fetch, assets[@"release.json"][@"browser_download_url"], &why) : nil;
    if ([manifest isKindOfClass:NSDictionary.class]) {
        for (NSDictionary *r in manifest[@"releases"]) {
            if (![r isKindOfClass:NSDictionary.class] || [r[@"nolib"] boolValue]) continue;
            for (NSDictionary *m in r[@"metadata"])
                if ([m isKindOfClass:NSDictionary.class] && [packager_flavor(m[@"flavor"]) isEqual:flavor] && assets[r[@"filename"]])
                    chosen = chosen ?: assets[r[@"filename"]];
        }
        if (!chosen) {
            *problem = [NSString stringWithFormat:@"%@’s latest release (%@) has no file for this game.", repo, release[@"tag_name"]];
            return nil;
        }
    } else {
        NSMutableArray<NSDictionary *> *zips = [NSMutableArray array], *hinted = [NSMutableArray array];
        for (NSDictionary *a in assets.allValues) {
            NSString *n = [a[@"name"] lowercaseString];
            if (![n hasSuffix:@".zip"] || [n containsString:@"nolib"]) continue;
            [zips addObject:a];
            for (NSString *h in name_hints(flavor))
                if ([n containsString:h]) { [hinted addObject:a]; break; }
        }
        chosen = zips.count == 1 ? zips[0] : hinted.count == 1 ? hinted[0] : nil;
        if (!chosen) {
            *problem = zips.count ? [NSString stringWithFormat:@"%@’s latest release has %lu zips, and none says it’s for this game.",
                                                               repo, (unsigned long)zips.count]
                                  : [NSString stringWithFormat:@"%@’s latest release has no zip to install.", repo];
            return nil;
        }
    }
    NSMutableDictionary *file = [@{@"name": chosen[@"name"], @"url": chosen[@"browser_download_url"] ?: @""} mutableCopy];
    if ([chosen[@"size"] isKindOfClass:NSNumber.class]) file[@"size"] = chosen[@"size"];
    NSString *digest = chosen[@"digest"];
    if ([digest isKindOfClass:NSString.class] && [digest hasPrefix:@"sha256:"]) file[@"sha256"] = [digest substringFromIndex:7].lowercaseString;
    NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
    return @{@"id": [@"github:" stringByAppendingString:repo.lowercaseString], @"name": [repo componentsSeparatedByString:@"/"][1],
             @"version": tag, @"source": @"github", @"repo": repo, @"home": [@"https://github.com/" stringByAppendingString:repo],
             @"file": file};
}

NSString *sp_addons_check_github(NSString *record, NSString *flavor, SPFetch fetch) {
    NSMutableArray<NSMutableDictionary *> *addons = record_read(record);
    NSMutableArray *lines = [NSMutableArray array];
    BOOL changed = NO;
    for (NSMutableDictionary *a in addons) {
        if (![a[@"source"] isEqual:@"github"] || ![a[@"repo"] isKindOfClass:NSString.class]) continue;
        NSString *why = nil;
        NSDictionary *e = sp_addons_github(a[@"repo"], flavor, nil, fetch, &why);
        if (!e) { [lines addObject:[NSString stringWithFormat:@"%@: %@", a[@"repo"], why]]; continue; }
        [lines addObject:[NSString stringWithFormat:@"%@ %@", a[@"repo"], e[@"version"]]];
        if (![a[@"latest"] isEqual:e[@"version"]]) { a[@"latest"] = e[@"version"]; changed = YES; }
    }
    if (changed) record_write(record, addons);
    return lines.count ? [lines componentsJoinedByString:@", "] : @"no GitHub links";
}

// ---- installs and removals

static NSLock *swap_lock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}
static BOOL held;

void sp_addons_hold(void) {
    [swap_lock() lock];
    held = YES;
    [swap_lock() unlock];
}

// Moves `folder` out of AddOns into `trash` (deleted with it).
static void retire_folder(NSString *dir, NSString *folder, NSString *trash) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:trash withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *from = [dir stringByAppendingPathComponent:folder];
    if (![fm moveItemAtPath:from toPath:[trash stringByAppendingPathComponent:[@"old-" stringByAppendingString:folder]] error:nil])
        [fm removeItemAtPath:from error:nil];
}

// Folders another recorded addon (not `ident`) has.
static NSSet<NSString *> *others_folders(NSArray<NSDictionary *> *addons, NSString *ident) {
    NSMutableSet *out = [NSMutableSet set];
    for (NSDictionary *a in addons)
        if (![a[@"id"] isEqual:ident]) [out addObjectsFromArray:a[@"folders"]];
    return out;
}

NSString *sp_addons_install(NSDictionary *entry, NSString *flavor, NSDictionary *catalog, NSString *game, NSString *record,
                            NSString *staging, SPFetch fetch, NSString **problem) {
    NSString *name = entry[@"name"] ?: entry[@"id"];
    NSDictionary *file = entry[@"file"];
    NSURL *url = [file[@"url"] isKindOfClass:NSString.class] ? [NSURL URLWithString:file[@"url"]] : nil;
    if (![entry[@"id"] isKindOfClass:NSString.class] || ![url.scheme isEqual:@"https"]) {
        *problem = [NSString stringWithFormat:@"%@ has no file to download.", name];
        return nil;
    }
    NSNumber *size = [file[@"size"] isKindOfClass:NSNumber.class] ? file[@"size"] : nil;
    if (size.unsignedLongLongValue > max_zip) { *problem = [NSString stringWithFormat:@"%@’s file is too big to be an addon.", name]; return nil; }
    NSString *why = nil;
    NSData *zip = fetch(url, NSMakeRange(0, 0), &why);
    if (!zip) { *problem = [NSString stringWithFormat:@"%@ couldn’t be downloaded (%@).", name, why]; return nil; }
    NSString *digest = sha256(zip);
    if ((size && zip.length != size.unsignedLongLongValue) || zip.length > max_zip ||
        ([file[@"sha256"] isKindOfClass:NSString.class] && ![[file[@"sha256"] lowercaseString] isEqual:digest])) {
        *problem = [NSString stringWithFormat:@"%@’s download isn’t the file the %@ lists, so it wasn’t installed.", name,
                                              [entry[@"source"] isEqual:@"github"] ? @"release" : @"catalog"];
        return nil;
    }
    NSArray *folders = file[@"folders"], *requires = file[@"requires"];
    if (![folders isKindOfClass:NSArray.class]) {
        NSArray<NSNumber *> *interfaces = nil;
        folders = sp_zip_addon_folders(zip, &interfaces, &requires, &why);
        if (!folders) { *problem = [NSString stringWithFormat:@"%@ can’t be installed: %@.", name, why]; return nil; }
        if (!interfaces_fit(interfaces, catalog, flavor)) {
            *problem = [NSString stringWithFormat:@"%@ %@ isn’t for this game’s version (its TOCs name %@).", name, entry[@"version"] ?: @"",
                                                  [interfaces componentsJoinedByString:@", "]];
            return nil;
        }
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *op = [staging stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    // Gives up with `text`, deleting what's left in staging.
    NSString *(^fail)(NSString *) = ^NSString *(NSString *text) {
        [fm removeItemAtPath:op error:nil];
        return text;
    };
    if (!sp_zip_unpack(zip, folders, op, &why)) {
        *problem = fail([NSString stringWithFormat:@"%@ can’t be installed: %@.", name, why]);
        return nil;
    }
    NSString *dir = addons_dir(game);
    [swap_lock() lock];
    if (held) {
        [swap_lock() unlock];
        *problem = fail([NSString stringWithFormat:@"%@ wasn’t installed: a game started.", name]);
        return nil;
    }
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSMutableDictionary *> *addons = record_read(record);
    NSMutableDictionary *was = record_find(addons, entry[@"id"]);
    NSMutableArray<NSString *> *names = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSDictionary *f in folders) {
        NSString *folder = f[@"name"], *fresh = [op stringByAppendingPathComponent:folder], *dest = [dir stringByAppendingPathComponent:folder];
        [names addObject:folder];
        // One rename each: the new folder and the one in place swap (the old one then goes with `op`), or the new one moves in.
        BOOL done = renamex_np(fresh.fileSystemRepresentation, dest.fileSystemRepresentation, RENAME_SWAP) == 0 ||
                    (errno == ENOENT && rename(fresh.fileSystemRepresentation, dest.fileSystemRepresentation) == 0);
        if (!done) [failed addObject:[NSString stringWithFormat:@"%@ (%s)", folder, strerror(errno)]];
    }
    NSSet *keep = others_folders(addons, entry[@"id"]);
    NSMutableArray *dropped = [NSMutableArray array];
    for (NSString *old in was[@"folders"])
        if (![names containsObject:old] && ![keep containsObject:old]) {
            retire_folder(dir, old, op);
            [dropped addObject:old];
        }
    NSString *previous = was[@"version"];
    NSMutableDictionary *now = [@{@"id": entry[@"id"], @"name": name, @"version": entry[@"version"] ?: @"",
                                  @"source": entry[@"source"] ?: @"catalog", @"file": file[@"name"] ?: url.lastPathComponent,
                                  @"sha256": failed.count ? @"" : digest, @"folders": names, @"requires": requires ?: @[]} mutableCopy];
    if (entry[@"repo"]) now[@"repo"] = entry[@"repo"];
    if (was && ![previous isEqual:now[@"version"]]) {
        now[@"previous"] = previous ?: @"";
        now[@"updated"] = [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.systemTimeZone
                                                   formatOptions:NSISO8601DateFormatWithInternetDateTime];
    } else if (was) {
        for (NSString *k in @[@"previous", @"updated"])
            if (was[k]) now[k] = was[k];
    }
    if (was) [addons replaceObjectAtIndex:[addons indexOfObject:was] withObject:now];
    else [addons addObject:now];
    BOOL wrote = record_write(record, addons);
    [swap_lock() unlock];
    [fm removeItemAtPath:op error:nil];
    if (failed.count) {
        *problem = [NSString stringWithFormat:@"%@ was only partly installed: %@ couldn’t be moved into place.", name,
                                              [failed componentsJoinedByString:@", "]];
        return nil;
    }
    if (!wrote) {
        *problem = [NSString stringWithFormat:@"%@ was installed, but Slashplayed couldn’t record it.", name];
        return nil;
    }
    NSString *line = was ? [NSString stringWithFormat:@"updated %@ %@ to %@", entry[@"id"], previous ?: @"?", now[@"version"]]
                         : [NSString stringWithFormat:@"installed %@ %@", entry[@"id"], now[@"version"]];
    line = [line stringByAppendingFormat:@" (%@, %lu bytes)", [names componentsJoinedByString:@" "], (unsigned long)zip.length];
    if (dropped.count) line = [line stringByAppendingFormat:@"; deleted %@", [dropped componentsJoinedByString:@" "]];
    return line;
}

NSString *sp_addons_remove(NSString *ident, NSString *game, NSString *record, NSString *staging, NSString **problem) {
    [swap_lock() lock];
    NSMutableArray<NSMutableDictionary *> *addons = record_read(record);
    NSMutableDictionary *was = record_find(addons, ident);
    if (held || !was) {
        [swap_lock() unlock];
        *problem = held ? @"A game started." : @"Slashplayed didn’t install that addon.";
        return nil;
    }
    NSString *trash = [staging stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSSet *keep = others_folders(addons, ident);
    NSMutableArray *gone = [NSMutableArray array];
    for (NSString *f in was[@"folders"])
        if (![keep containsObject:f] && !ours(f) && folder_name_ok(f) &&
            [NSFileManager.defaultManager fileExistsAtPath:[addons_dir(game) stringByAppendingPathComponent:f]]) {
            retire_folder(addons_dir(game), f, trash);
            [gone addObject:f];
        }
    [addons removeObject:was];
    BOOL wrote = record_write(record, addons);
    [swap_lock() unlock];
    [NSFileManager.defaultManager removeItemAtPath:trash error:nil];
    if (!wrote) { *problem = @"Slashplayed couldn’t update its record of this game’s addons."; return nil; }
    return [NSString stringWithFormat:@"removed %@ (%@)", ident, gone.count ? [gone componentsJoinedByString:@" "] : @"no folders left"];
}

// ---- the device's: paths, the queue, and the start screen's check

static NSString *const catalog_url = @"https://paulstraw.github.io/slashplayed-addons/addons.json";

static NSString *home(NSString *relative) { return [NSHomeDirectory() stringByAppendingPathComponent:relative]; }
static NSString *game_path(NSString *flavor) { return home([NSString stringWithFormat:@"Documents/_%@_", flavor]); }
static NSString *record_path(NSString *flavor) { return home([NSString stringWithFormat:@"Library/spaddons-%@.json", flavor]); }
static NSString *staging_path(void) { return home(@"Library/spaddons-staging"); }
static NSString *catalog_path(void) { return home(@"Library/spaddons-catalog.json"); }

// The launcher's log line (launcher.m's say: stderr, which the libSystem shim tees to Documents/spconsole.log).
static void say(NSString *s) { fprintf(stderr, "[sp:launch] addons: %s\n", s.UTF8String); }

// Every addon operation, in order: a download and the swap after it never interleave with another's.
static dispatch_queue_t addons_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("slashplayed.addons", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// A fetch for the queue: URLSession, waiting by sleeping (it runs off the main thread).
static SPFetch session(void) {
    return sp_cdn_session(^(double s) { usleep((useconds_t)(s * 1e6)); }, 30, nil);
}

NSDictionary *sp_addons_cached_catalog(void) {
    NSString *problem = nil;
    return sp_addons_catalog([NSData dataWithContentsOfFile:catalog_path()], &problem);
}

// The catalog, fetched and kept in Library/ for the next screen. nil and *problem when it couldn't be.
static NSDictionary *refresh_catalog(SPFetch fetch, NSString **problem) {
    NSString *why = nil;
    NSData *data = fetch([NSURL URLWithString:catalog_url], NSMakeRange(0, 0), &why);
    if (!data) { *problem = [NSString stringWithFormat:@"The addon catalog couldn’t be downloaded (%@).", why]; return nil; }
    NSDictionary *catalog = sp_addons_catalog(data, problem);
    if (catalog) [data writeToFile:catalog_path() atomically:YES];
    return catalog;
}

NSArray<NSDictionary *> *sp_addons_rows(NSString *flavor) {
    return sp_addons_list(game_path(flavor), record_path(flavor), sp_addons_cached_catalog(), flavor);
}

NSArray<NSDictionary *> *sp_addons_browse(NSString *flavor) {
    return sp_addons_offered(sp_addons_cached_catalog(), flavor);
}

NSString *sp_addons_folder(NSString *flavor) { return addons_dir(game_path(flavor)); }

// "Update addons automatically": on by default (sp_addons_auto_default), for every game.
static NSString *const auto_key = @"sp_addons_auto";
static const BOOL sp_addons_auto_default = YES;
BOOL sp_addons_auto(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:auto_key];
    return v ? [v boolValue] : sp_addons_auto_default;
}
void sp_addons_set_auto(BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:auto_key];
    say([@"update automatically: " stringByAppendingString:on ? @"on" : @"off"]);
}

void sp_addons_refresh(NSString *flavor, void (^done)(NSString *problem)) {
    dispatch_async(addons_queue(), ^{
        SPFetch fetch = session();
        NSString *problem = nil;
        refresh_catalog(fetch, &problem);
        say([NSString stringWithFormat:@"%@ github: %@", flavor, sp_addons_check_github(record_path(flavor), flavor, fetch)]);
        dispatch_async(dispatch_get_main_queue(), ^{ done(problem); });
    });
}

// Each row that has an update, as what to install: the catalog's entry, or the GitHub link's latest release.
static NSArray<NSDictionary *> *updates(NSString *flavor, NSDictionary *catalog, SPFetch fetch, NSArray<NSString *> *only,
                                        BOOL recorded, NSMutableArray<NSString *> *problems) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *offered = sp_addons_offered(catalog, flavor);
    for (NSDictionary *row in sp_addons_list(game_path(flavor), record_path(flavor), catalog, flavor)) {
        if (![row[@"update"] boolValue] || (only && ![only containsObject:row[@"id"]])) continue;
        if (recorded && row[@"catalog"]) continue;  // hand-added folders update only on a tap
        NSString *why = nil;
        NSDictionary *e = nil;
        if ([row[@"source"] isEqual:@"github"]) e = sp_addons_github(row[@"repo"], flavor, catalog, fetch, &why);
        else
            for (NSDictionary *o in offered)
                if ([o[@"id"] isEqual:row[@"catalog"] ?: row[@"id"]]) e = o;
        if (e) [out addObject:e];
        else [problems addObject:why ?: [NSString stringWithFormat:@"%@ isn’t in the catalog any more.", row[@"name"]]];
    }
    return out;
}

void sp_addons_run(NSString *flavor, NSString *action, NSString *argument, void (^done)(NSString *problem)) {
    dispatch_async(addons_queue(), ^{
        SPFetch fetch = session();
        NSString *problem = nil;
        NSDictionary *catalog = sp_addons_cached_catalog();
        NSMutableArray<NSString *> *problems = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *install = [NSMutableArray array];
        if ([action isEqual:@"remove"]) {
            NSString *line = sp_addons_remove(argument, game_path(flavor), record_path(flavor), staging_path(), &problem);
            say([NSString stringWithFormat:@"%@: %@", flavor, line ?: problem]);
        } else if ([action isEqual:@"link"]) {
            NSDictionary *e = sp_addons_github(argument, flavor, catalog, fetch, &problem);
            if (e) [install addObject:e];
            else say([NSString stringWithFormat:@"%@: link: %@", flavor, problem]);
        } else if ([action isEqual:@"install"]) {
            for (NSDictionary *o in sp_addons_offered(catalog, flavor))
                if ([o[@"id"] isEqual:argument]) [install addObject:o];
            if (!install.count) problem = @"That addon isn’t in the catalog for this game.";
        } else if ([action isEqual:@"update"] || [action isEqual:@"update-all"]) {
            [install addObjectsFromArray:updates(flavor, catalog, fetch, [action isEqual:@"update"] ? @[argument] : nil, NO, problems)];
        }
        for (NSDictionary *e in install) {
            NSString *why = nil;
            NSString *line = sp_addons_install(e, flavor, catalog, game_path(flavor), record_path(flavor), staging_path(), fetch, &why);
            say([NSString stringWithFormat:@"%@: %@", flavor, line ?: why]);
            if (!line) [problems addObject:why];
        }
        if (problems.count) problem = [problems componentsJoinedByString:@"\n\n"];
        dispatch_async(dispatch_get_main_queue(), ^{ done(problem); });
    });
}

// The start screen's check, at most every 3 hours: the catalog, then each game's GitHub links, and with
// "Update addons automatically" on, every addon Slashplayed installed that has a newer file. In the
// background; it never holds up the start screen, and says nothing on the screen (offline included).
void sp_addons_background(NSArray<NSString *> *flavors) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *last = [defaults objectForKey:@"sp_addons_checked"];
    NSTimeInterval age = [last isKindOfClass:NSDate.class] ? -last.timeIntervalSinceNow : -1;
    if (age >= 0 && age < 3 * 3600) return;
    NSMutableArray *games = [NSMutableArray array];
    for (NSString *f in flavors)
        if (record_read(record_path(f)).count) [games addObject:f];
    BOOL automatic = sp_addons_auto();
    dispatch_async(addons_queue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:staging_path() error:nil];  // what a killed install left
        SPFetch fetch = session();
        NSString *problem = nil;
        NSDictionary *catalog = refresh_catalog(fetch, &problem);
        if (!catalog) { say([@"check: " stringByAppendingString:problem]); return; }
        [defaults setObject:NSDate.date forKey:@"sp_addons_checked"];
        say([NSString stringWithFormat:@"check: catalog of %@, %lu addons; %lu games with addons Slashplayed installed",
                                       catalog[@"generated"], (unsigned long)[catalog[@"addons"] count], (unsigned long)games.count]);
        for (NSString *flavor in games) {
            say([NSString stringWithFormat:@"%@ github: %@", flavor, sp_addons_check_github(record_path(flavor), flavor, fetch)]);
            NSMutableArray *problems = [NSMutableArray array];
            NSArray *pending = updates(flavor, catalog, fetch, nil, YES, problems);
            say([NSString stringWithFormat:@"%@: %lu with updates%@", flavor, (unsigned long)pending.count,
                                           pending.count && !automatic ? @" (updating automatically is off)" : @""]);
            if (!automatic) continue;
            for (NSDictionary *e in pending) {
                NSString *why = nil;
                NSString *line = sp_addons_install(e, flavor, catalog, game_path(flavor), record_path(flavor), staging_path(), fetch, &why);
                say([NSString stringWithFormat:@"%@: %@", flavor, line ?: why]);
            }
        }
    });
}
