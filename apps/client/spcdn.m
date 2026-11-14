// Blizzard's CDN on the device, for the launcher's check of a newer build (sppatch.m): the build's client's
// arm64 slice, fetched in part. The port of the companion's BlizzardCDN.swift (keep the two in step;
// formats: https://wowdev.wiki/TACT). The build config names the install manifest, which gives the Mac
// client's content key for the region; the encoding file (its header, page index, and the one page that
// can hold that key) gives its encoded key; the client is a BLTE file of independently decodable chunks,
// loose on the CDN or in one of its archives, and the CDN honors ranges, so one ranged request fetches
// just the chunks covering the arm64 slice (about half the universal file).
//
// Everything is checked against the key that names it, so the chain is as trustworthy as the version row
// (HTTPS): a config's MD5 is its key, a chunked BLTE file's header's MD5 is its encoded key and that
// header holds each chunk's MD5, an encoding page's MD5 is in the page index, and the install manifest's
// decoded MD5 is the content key the build config gives it. Unlike the companion's, nothing is cached but
// the slice itself (the caller's `output`): the device fetches one build's once.
#import "spcdn.h"
#include "spguest.h"  // spguest_check_file
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <stdatomic.h>
#include <zlib.h>

NSString *const SPCDNNotFound = @"HTTP 404";

NSDictionary<NSString *, NSString *> *sp_table_row(NSString *text, NSString *column, NSString *value) {
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (!lines.count || !value.length) return nil;
    NSMutableArray<NSString *> *columns = [NSMutableArray array];
    for (NSString *c in [lines[0] componentsSeparatedByString:@"|"])
        [columns addObject:[c componentsSeparatedByString:@"!"][0]];
    NSDictionary *found = nil;
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
        if ([line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *values = [line componentsSeparatedByString:@"|"];
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < MIN(columns.count, values.count); i++) row[columns[i]] = values[i];
        if ([row[column] isEqual:value]) found = row;
    }
    return found;
}

NSArray<NSURL *> *sp_cdn_servers(NSDictionary<NSString *, NSString *> *row) {
    NSString *path = row[@"Path"];
    if (!path.length) return @[];
    NSArray<NSString *> *(^words)(NSString *) = ^(NSString *column) {
        return [[row[column] ?: @"" componentsSeparatedByString:@" "]
                filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    };
    NSMutableArray<NSString *> *hosts = [NSMutableArray array];
    for (NSString *s in words(@"Servers")) {
        NSURLComponents *c = [NSURLComponents componentsWithString:s];
        if ([c.scheme isEqual:@"https"] && c.host.length) [hosts addObject:c.host];
    }
    if (!hosts.count) [hosts addObjectsFromArray:words(@"Hosts")];
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    for (NSString *h in [NSOrderedSet orderedSetWithArray:hosts]) {
        NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/%@", h, path]];
        if (u) [out addObject:u];
    }
    return out;
}

// ---- helpers

static NSString *hex(NSData *d) {
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

static BOOL is_key(NSString *s) {
    if (s.length != 32) return NO;
    NSCharacterSet *notHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
    return [s rangeOfCharacterFromSet:notHex].location == NSNotFound;
}

// MD5 is what the CDN's keys are: an integrity check against keys that came over HTTPS, not a signature.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSData *md5(NSData *d) {
    uint8_t out[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d.bytes, (CC_LONG)d.length, out);
    return [NSData dataWithBytes:out length:sizeof out];
}
#pragma clang diagnostic pop

static uint64_t be(NSData *d, NSUInteger off, NSUInteger n) {
    const uint8_t *p = (const uint8_t *)d.bytes + off;
    uint64_t v = 0;
    for (NSUInteger i = 0; i < n; i++) v = v << 8 | p[i];
    return v;
}

// <kind>/ab/cd/abcd…: where the CDN keeps a config or data file.
static NSString *cdn_path(NSString *kind, NSString *key) {
    return [NSString stringWithFormat:@"%@/%@/%@/%@", kind, [key substringToIndex:2], [key substringWithRange:NSMakeRange(2, 2)], key];
}

// zlib (a Z chunk). `expected` when the size is known (a chunk table gives it), else 0.
static NSData *inflate_all(NSData *in, NSUInteger expected) {
    z_stream z = {0};
    if (inflateInit(&z) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:expected ?: MAX(in.length * 4, 4096)];
    z.next_in = (Bytef *)in.bytes;
    z.avail_in = (uInt)in.length;
    int r;
    do {
        if (z.total_out == out.length) out.length *= 2;
        z.next_out = (Bytef *)out.mutableBytes + z.total_out;
        z.avail_out = (uInt)(out.length - z.total_out);
        r = inflate(&z, Z_NO_FLUSH);
    } while (r == Z_OK);
    out.length = z.total_out;
    inflateEnd(&z);
    return r == Z_STREAM_END ? out : nil;
}

typedef struct {
    uint64_t encodedStart, encodedEnd, decodedStart, decodedEnd;
    uint8_t md5[16];
} chunk;

// A BLTE-encoded file on the CDN: loose (data/…/<ekey>) or a stretch of an archive (size from its index).
@interface SPBlob : NSObject
@property (nonatomic, copy) NSString *ekey, *path;
@property (nonatomic) uint64_t offset;
@property (nonatomic) int64_t size;  // -1: not known
@end

@implementation SPBlob
+ (instancetype)loose:(NSString *)ekey {
    SPBlob *b = [SPBlob new];
    b.ekey = ekey;
    b.path = cdn_path(@"data", ekey);
    b.size = -1;
    return b;
}
@end

// The chain's state. Every method returns nil (or NO) on failure with `problem` set.
@interface SPCDN : NSObject
@property (nonatomic, copy) NSArray<NSURL *> *servers;
@property (nonatomic, copy) SPFetch fetch;
@property (nonatomic, copy) NSString *problem;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *headers;
@property (nonatomic, copy) NSArray<NSString *> *tags;  // the install manifest's tag names, once it's read
@end

@implementation SPCDN
- (id)fail:(NSString *)why {
    if (!self.problem) self.problem = why;
    return nil;
}

// Tries each server in turn; not found only if every one says 404.
- (NSData *)get:(NSString *)path range:(NSRange)range {
    if (!self.servers.count) return [self fail:@"no CDN server"];
    NSString *failed = nil;
    for (NSURL *server in self.servers) {
        NSString *why = nil;
        NSData *d = self.fetch([server URLByAppendingPathComponent:path], range, &why);
        if (d) return d;
        if (![why isEqual:SPCDNNotFound]) failed = why ?: @"no answer";
    }
    return [self fail:failed ?: SPCDNNotFound];
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)config:(NSString *)key {
    if (!is_key(key)) return [self fail:@"not a config key"];
    NSData *d = [self get:cdn_path(@"config", key) range:NSMakeRange(0, 0)];
    if (!d) return nil;
    if (![hex(md5(d)) isEqual:key]) return [self fail:[NSString stringWithFormat:@"config %@ doesn't match its key", key]];
    // GameStore.parseConfig: "name = value value…" lines.
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange eq = [line rangeOfString:@" = "];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        out[k] = [[[line substringFromIndex:NSMaxRange(eq)] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    }
    return out;
}

// A blob's BLTE header: all of it for a chunked file (its MD5 is the encoded key), the first 8 bytes
// for an unchunked one. The first request is enough for a header of 680 chunks (the clients have 400–470).
- (NSData *)header:(SPBlob *)blob {
    if (self.headers[blob.ekey]) return self.headers[blob.ekey];
    uint64_t probeSize = 16 * 1024;
    if (blob.size >= 0) probeSize = MIN(probeSize, (uint64_t)blob.size);
    NSData *probe = [self get:blob.path range:NSMakeRange(blob.offset, probeSize)];
    if (!probe) return nil;
    if (probe.length < 8 || memcmp(probe.bytes, "BLTE", 4)) return [self fail:[blob.ekey stringByAppendingString:@" isn't BLTE-encoded"]];
    NSUInteger size = (NSUInteger)be(probe, 4, 4);
    NSData *header;
    if (!size) header = [probe subdataWithRange:NSMakeRange(0, 8)];
    else {
        header = probe.length >= size ? [probe subdataWithRange:NSMakeRange(0, size)]
                                      : [self get:blob.path range:NSMakeRange(blob.offset, size)];
        if (!header) return nil;
        if (header.length != size || ![hex(md5(header)) isEqual:blob.ekey])
            return [self fail:[blob.ekey stringByAppendingString:@" doesn't match its key"]];
    }
    self.headers[blob.ekey] = header;
    return header;
}

// The chunk table of a chunked header; nil with no problem for an unchunked one.
- (NSData *)chunks:(NSData *)h {
    NSUInteger size = (NSUInteger)be(h, 4, 4);
    if (!size) return nil;
    if (h.length < 12) return [self fail:@"a BLTE header is cut short"];
    NSUInteger count = (NSUInteger)be(h, 9, 3);
    if (size < 12 + count * 24 || h.length < size) return [self fail:@"a BLTE chunk table is cut short"];
    NSMutableData *out = [NSMutableData dataWithLength:count * sizeof(chunk)];
    chunk *c = out.mutableBytes;
    uint64_t encoded = size, decoded = 0;
    for (NSUInteger i = 0; i < count; i++) {
        uint64_t e = be(h, 12 + i * 24, 4), d = be(h, 16 + i * 24, 4);
        c[i] = (chunk){encoded, encoded + e, decoded, decoded + d, {0}};
        memcpy(c[i].md5, (const uint8_t *)h.bytes + 20 + i * 24, 16);
        encoded += e;
        decoded += d;
    }
    return out;
}

// A chunk's content: stored (N) or zlib (Z). Encrypted (E) and frame (F) chunks aren't in anything read here.
- (NSData *)decode:(NSData *)c expected:(NSUInteger)expected {
    if (!c.length) return [self fail:@"an empty BLTE chunk"];
    NSData *body = [c subdataWithRange:NSMakeRange(1, c.length - 1)];
    uint8_t mode = *(const uint8_t *)c.bytes;
    NSData *out = mode == 'N' ? body : mode == 'Z' ? inflate_all(body, expected) : nil;
    if (!out) return [self fail:[NSString stringWithFormat:@"a BLTE chunk of mode %c doesn't decode", mode]];
    return out;
}

// An unchunked blob, decoded (its whole encoded file's MD5 is its key).
- (NSData *)whole:(SPBlob *)blob {
    NSData *raw = [self get:blob.path range:NSMakeRange(blob.offset, blob.size >= 0 ? (NSUInteger)blob.size : 0)];
    if (!raw) return nil;
    if (![hex(md5(raw)) isEqual:blob.ekey]) return [self fail:[blob.ekey stringByAppendingString:@" doesn't match its key"]];
    if (raw.length < 9) return [self fail:@"a BLTE file is cut short"];
    return [self decode:[raw subdataWithRange:NSMakeRange(8, raw.length - 8)] expected:0];
}

- (int64_t)decodedSize:(SPBlob *)blob {
    NSData *h = [self header:blob];
    if (!h) return -1;
    NSData *table = [self chunks:h];
    if (table) return table.length ? (int64_t)((const chunk *)table.bytes)[table.length / sizeof(chunk) - 1].decodedEnd : 0;
    if (self.problem) return -1;
    NSData *w = [self whole:blob];
    return w ? (int64_t)w.length : -1;
}

// `range` of a blob's decoded content, fetching only the chunks it covers (as one ranged request), each
// checked against its MD5. A range inside one stored chunk bigger than 1 MB is read alone and isn't
// checked: the caller checks it (an encoding page against the page index; Retail's pages are one 110 MB
// stored chunk).
- (NSData *)read:(SPBlob *)blob range:(NSRange)range {
    NSData *h = [self header:blob];
    if (!h) return nil;
    NSData *table = [self chunks:h];
    if (!table) {
        if (self.problem) return nil;
        NSData *w = [self whole:blob];
        if (!w) return nil;
        if (NSMaxRange(range) > w.length) return [self fail:[blob.ekey stringByAppendingString:@" is shorter than its build says"]];
        return [w subdataWithRange:range];
    }
    const chunk *c = table.bytes;
    NSUInteger n = table.length / sizeof(chunk), first = NSNotFound, last = 0;
    if (!n || NSMaxRange(range) > c[n - 1].decodedEnd) return [self fail:[blob.ekey stringByAppendingString:@" is shorter than its build says"]];
    for (NSUInteger i = 0; i < n; i++)
        if (c[i].decodedStart < NSMaxRange(range) && range.location < c[i].decodedEnd) {
            if (first == NSNotFound) first = i;
            last = i;
        }
    if (first == NSNotFound) return [NSData data];
    const chunk *f = &c[first];
    uint64_t encodedLen = f->encodedEnd - f->encodedStart, decodedLen = f->decodedEnd - f->decodedStart;
    if (first == last && encodedLen == decodedLen + 1 && encodedLen > (1 << 20)) {
        uint64_t at = blob.offset + f->encodedStart;
        NSData *mode = [self get:blob.path range:NSMakeRange(at, 1)];
        if (!mode) return nil;
        if (mode.length == 1 && *(const uint8_t *)mode.bytes == 'N') {
            NSData *part = [self get:blob.path range:NSMakeRange(at + 1 + range.location - f->decodedStart, range.length)];
            if (!part) return nil;
            if (part.length != range.length) return [self fail:[blob.ekey stringByAppendingString:@" is cut short"]];
            return part;
        }
    }
    uint64_t runStart = blob.offset + f->encodedStart, runLen = c[last].encodedEnd - f->encodedStart;
    NSData *run = [self get:blob.path range:NSMakeRange(runStart, runLen)];
    if (!run) return nil;
    if (run.length != runLen) return [self fail:[blob.ekey stringByAppendingString:@" is cut short"]];
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = first; i <= last; i++) {
        NSData *e = [run subdataWithRange:NSMakeRange(c[i].encodedStart - f->encodedStart, c[i].encodedEnd - c[i].encodedStart)];
        if (memcmp(md5(e).bytes, c[i].md5, 16))
            return [self fail:[blob.ekey stringByAppendingString:@" has a chunk that doesn't match its checksum"]];
        NSData *d = [self decode:e expected:(NSUInteger)(c[i].decodedEnd - c[i].decodedStart)];
        if (!d) return nil;
        if (d.length != c[i].decodedEnd - c[i].decodedStart) return [self fail:[blob.ekey stringByAppendingString:@" decoded to the wrong size"]];
        [out appendData:d];
    }
    return [out subdataWithRange:NSMakeRange(range.location - f->decodedStart, range.length)];
}

// The encoded key of content key `ckey`, from the build's encoding file: its header, its content-key page
// index, and the one page whose first key is the last at or before `ckey`.
- (NSData *)encodedKey:(NSData *)ckey encoding:(SPBlob *)encoding {
    NSData *head = [self read:encoding range:NSMakeRange(0, 22)];
    if (!head) return nil;
    NSString *unreadable = @"the build's encoding file isn't one this reads";
    if (memcmp(head.bytes, "EN", 2)) return [self fail:unreadable];
    const uint8_t *hp = head.bytes;
    NSUInteger ckeyLen = hp[3], ekeyLen = hp[4], pageSize = (NSUInteger)be(head, 5, 2) * 1024;
    NSUInteger pages = (NSUInteger)be(head, 9, 4), espec = (NSUInteger)be(head, 18, 4);
    if (ckeyLen != ckey.length || !ekeyLen || !pageSize || !pages) return [self fail:unreadable];
    NSUInteger entry = ckeyLen + 16, indexStart = 22 + espec;
    NSData *index = [self read:encoding range:NSMakeRange(indexStart, pages * entry)];
    if (!index) return nil;
    const uint8_t *ip = index.bytes;
    // The number of pages whose first key is at or before ckey; the last of them holds it, if any does.
    NSUInteger lo = 0, hi = pages;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (memcmp(ckey.bytes, ip + mid * entry, ckeyLen) < 0) hi = mid;
        else lo = mid + 1;
    }
    NSString *notListed = @"the build's encoding file doesn't list its client";
    if (!lo) return [self fail:notListed];
    NSUInteger page = lo - 1, pagesStart = indexStart + pages * entry;
    NSData *body = [self read:encoding range:NSMakeRange(pagesStart + page * pageSize, pageSize)];
    if (!body) return nil;
    if (memcmp(md5(body).bytes, ip + page * entry + ckeyLen, 16))
        return [self fail:@"a page of the build's encoding file doesn't match its checksum"];
    const uint8_t *b = body.bytes;
    for (NSUInteger q = 0; q + 6 + ckeyLen <= body.length;) {
        NSUInteger count = b[q];
        if (!count) break;
        const uint8_t *key = b + q + 6;
        q += 6 + ckeyLen;
        if (q + count * ekeyLen > body.length) break;
        if (!memcmp(key, ckey.bytes, ckeyLen)) return [NSData dataWithBytes:b + q length:ekeyLen];
        q += count * ekeyLen;
    }
    return [self fail:notListed];
}

// The content key of the Mac client at `path` for `region`, from the install manifest. It has a copy per
// region group (China's differs), so an entry tagged with the region wins.
- (NSData *)executableKey:(NSData *)d path:(NSString *)path region:(NSString *)region {
    NSString *unreadable = @"the build's install manifest isn't one this reads";
    if (d.length < 10 || memcmp(d.bytes, "IN", 2)) return [self fail:unreadable];
    const uint8_t *p = d.bytes;
    NSUInteger keyLen = p[3], tagCount = (NSUInteger)be(d, 4, 2), count = (NSUInteger)be(d, 6, 4);
    NSUInteger maskLen = (count + 7) / 8;
    __block NSUInteger at = 10;
    NSString * (^string)(void) = ^NSString * {
        const uint8_t *nul = at < d.length ? memchr(p + at, 0, d.length - at) : NULL;
        if (!nul) return nil;
        NSString *s = [[NSString alloc] initWithBytes:p + at length:(NSUInteger)(nul - (p + at)) encoding:NSUTF8StringEncoding];
        at = (NSUInteger)(nul - p) + 1;
        return s ?: @"";
    };
    NSUInteger osx = NSNotFound, regional = NSNotFound;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger t = 0; t < tagCount; t++) {
        NSString *name = string();
        if (!name) return [self fail:unreadable];
        [names addObject:name];
        at += 2;  // the tag's type
        if (at + maskLen > d.length) return [self fail:unreadable];
        if ([name isEqual:@"OSX"]) osx = at;
        if ([name isEqual:region.uppercaseString]) regional = at;
        at += maskLen;
    }
    NSString *wanted = [path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    NSMutableSet<NSData *> *mac = [NSMutableSet set], *inRegion = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *name = string();
        if (!name || at + keyLen + 4 > d.length) return [self fail:unreadable];
        BOOL (^tagged)(NSUInteger) = ^BOOL(NSUInteger mask) { return mask != NSNotFound && (p[mask + i / 8] & (0x80 >> (i % 8))); };
        if ([name isEqual:wanted] && tagged(osx)) {
            NSData *key = [d subdataWithRange:NSMakeRange(at, keyLen)];
            [mac addObject:key];
            if (tagged(regional)) [inRegion addObject:key];
        }
        at += keyLen + 4;
    }
    self.tags = names;
    NSSet<NSData *> *keys = inRegion.count ? inRegion : mac;
    if (keys.count != 1)
        return [self fail:keys.count ? @"the build's install manifest has more than one Mac client for the region"
                                     : @"the build's install manifest has no Mac client"];
    return keys.anyObject;
}

// Where `key` is in a CDN archive, from its index: blocks of (key, size, offset) entries, then a table
// of contents, then a 28-byte footer giving the sizes. NO with no problem when it isn't there.
- (BOOL)archiveIndex:(NSData *)d find:(NSData *)key offset:(uint64_t *)offset size:(uint64_t *)size {
    if (d.length < 28) return [self fail:@"an archive index isn't one this reads"] != nil;
    const uint8_t *p = d.bytes;
    NSUInteger f = d.length - 28, blockSize = p[f + 11] * 1024, offsetLen = p[f + 12], sizeLen = p[f + 13];
    NSUInteger keyLen = p[f + 14], hashLen = p[f + 15];
    if (!blockSize || keyLen != key.length || offsetLen < 1 || offsetLen > 8 || sizeLen < 1 || sizeLen > 8 ||
        f % (blockSize + keyLen + hashLen))
        return [self fail:@"an archive index isn't one this reads"] != nil;
    NSUInteger entry = keyLen + sizeLen + offsetLen;
    for (NSUInteger block = 0; block < f / (blockSize + keyLen + hashLen); block++)
        for (NSUInteger q = block * blockSize; q + entry <= (block + 1) * blockSize; q += entry)
            if (!memcmp(p + q, key.bytes, keyLen)) {
                *size = be(d, q + keyLen, sizeLen);
                *offset = be(d, q + keyLen + sizeLen, offsetLen);
                return YES;
            }
    return NO;
}

// The arm64 slice of a Mach-O file, from its first bytes: the arm64 (not arm64e) entry of a fat header,
// or the whole of a thin arm64 image. What `lipo -thin arm64` writes.
- (BOOL)arm64Slice:(NSData *)d fileSize:(uint64_t)fileSize range:(NSRange *)out {
    if (d.length < 8) return [self fail:@"the client is too short to be a Mach-O file"] != nil;
    const uint8_t *p = d.bytes;
    uint64_t magic = be(d, 0, 4);
    if (magic == 0xCFFAEDFE) {  // MH_MAGIC_64, little-endian
        if (p[4] != 0x0C || p[5] || p[6] || p[7] != 0x01) return [self fail:@"the client isn't arm64"] != nil;
        *out = NSMakeRange(0, fileSize);
        return YES;
    }
    if (magic != 0xCAFEBABE && magic != 0xCAFEBABF) return [self fail:@"the client isn't a Mach-O file"] != nil;
    BOOL wide = magic == 0xCAFEBABF;
    NSUInteger entry = wide ? 32 : 20;
    for (NSUInteger i = 0; i < be(d, 4, 4); i++) {
        NSUInteger e = 8 + i * entry;
        if (e + entry > d.length) break;
        if (be(d, e, 4) != 0x0100000C || (be(d, e + 4, 4) & 0x00FFFFFF)) continue;
        uint64_t offset = wide ? be(d, e + 8, 8) : be(d, e + 8, 4), size = wide ? be(d, e + 16, 8) : be(d, e + 12, 4);
        if (offset + size > fileSize) break;
        *out = NSMakeRange(offset, size);
        return YES;
    }
    return [self fail:@"the client has no arm64 slice"] != nil;
}

- (NSData *)sliceOf:(NSString *)executable region:(NSString *)region build:(NSString *)buildConfig cdn:(NSString *)cdnConfig {
    NSDictionary<NSString *, NSArray<NSString *> *> *config = [self config:buildConfig];
    if (!config) return nil;
    NSArray<NSString *> *install = config[@"install"], *encoding = config[@"encoding"];
    NSInteger installSize = [config[@"install-size"].firstObject integerValue];
    if (install.count < 2 || installSize <= 0 || encoding.count < 2 || !is_key(install[1]) || !is_key(encoding[1]))
        return [self fail:@"the build has no install manifest or encoding file"];
    NSData *manifest = [self read:[SPBlob loose:install[1]] range:NSMakeRange(0, (NSUInteger)installSize)];
    if (!manifest) return nil;
    if (![hex(md5(manifest)) isEqual:install[0]]) return [self fail:@"the build's install manifest doesn't match its key"];
    NSData *ckey = [self executableKey:manifest path:executable region:region];
    if (!ckey) return nil;
    NSData *ekeyBytes = [self encodedKey:ckey encoding:[SPBlob loose:encoding[1]]];
    if (!ekeyBytes) return nil;
    NSString *ekey = hex(ekeyBytes);
    SPBlob *blob = [SPBlob loose:ekey];
    if (![self header:blob]) {
        if (![self.problem isEqual:SPCDNNotFound]) return nil;
        // Not loose: in one of the CDN's archives.
        self.problem = nil;
        NSArray<NSString *> *archives = [self config:cdnConfig][@"archives"];
        if (!archives) return nil;
        blob = nil;
        for (NSString *archive in archives) {
            if (!is_key(archive)) continue;
            NSData *index = [self get:cdn_path(@"data", [archive stringByAppendingString:@".index"]) range:NSMakeRange(0, 0)];
            if (!index) return nil;
            uint64_t offset, size;
            if ([self archiveIndex:index find:ekeyBytes offset:&offset size:&size]) {
                blob = [SPBlob new];
                blob.ekey = ekey;
                blob.path = cdn_path(@"data", archive);
                blob.offset = offset;
                blob.size = (int64_t)size;
                break;
            }
            if (self.problem) return nil;
        }
        if (!blob) return [self fail:@"Blizzard's CDN doesn't have the client any more"];
    }
    int64_t size = [self decodedSize:blob];
    if (size < 0) return nil;
    NSData *head = [self read:blob range:NSMakeRange(0, (NSUInteger)MIN(4096, size))];
    if (!head) return nil;
    NSRange slice;
    if (![self arm64Slice:head fileSize:(uint64_t)size range:&slice]) return nil;
    return [self read:blob range:slice];
}
@end

BOOL sp_cdn_slice(NSArray<NSURL *> *servers, NSString *buildConfig, NSString *cdnConfig, NSString *executable,
                  NSString *region, SPFetch fetch, NSString *output, NSArray<NSString *> **tags, NSString **problem) {
    if (tags) *tags = nil;
    SPCDN *cdn = [SPCDN new];
    cdn.servers = servers;
    cdn.fetch = fetch;
    cdn.headers = [NSMutableDictionary dictionary];
    if (!is_key(buildConfig) || !is_key(cdnConfig)) {
        *problem = @"the version row's keys aren't keys";
        return NO;
    }
    NSData *slice = [cdn sliceOf:executable region:region build:buildConfig cdn:cdnConfig];
    if (tags) *tags = cdn.tags;
    if (!slice) {
        *problem = cdn.problem ?: @"no slice";
        return NO;
    }
    NSError *e = nil;
    if (![slice writeToFile:output options:NSDataWritingAtomic error:&e]) {
        *problem = [NSString stringWithFormat:@"couldn't write it (%@ %ld)", e.domain, (long)e.code];
        return NO;
    }
    return YES;
}

SPFetch sp_cdn_session(void (^pump)(double), double timeout, void (^progress)(unsigned long long bytes)) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = timeout;  // without data
    config.timeoutIntervalForResource = 600;  // the slice itself is ~50 MB
    config.waitsForConnectivity = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block unsigned long long before = 0;  // the bytes of the requests already done
    return ^NSData *(NSURL *url, NSRange range, NSString **problem) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        if (range.length)
            [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)range.location,
                                                         (unsigned long)NSMaxRange(range) - 1] forHTTPHeaderField:@"Range"];
        // Set on the session's queue, read here once `done` is.
        __block NSData *body = nil;
        __block NSString *why = nil;
        __block atomic_bool done = false;
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            NSInteger status = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
            if (e) why = [NSString stringWithFormat:@"%@ %ld", e.domain, (long)e.code];
            else if (status == 404) why = SPCDNNotFound;
            else if (status != (range.length ? 206 : 200)) why = [NSString stringWithFormat:@"HTTP %ld", (long)status];
            else body = data;
            atomic_store(&done, true);
        }];
        [task resume];
        while (!atomic_load(&done)) {
            pump(0.05);
            if (progress) progress(before + (unsigned long long)MAX(task.countOfBytesReceived, 0));
        }
        before += body.length;
        if (!body) *problem = why;
        return body;
    };
}

// ---- what an on-device update writes besides the image (sppatch.m)

BOOL sp_cdn_store_config(NSArray<NSURL *> *servers, NSString *key, SPFetch fetch, NSString *data,
                         unsigned long long *fetched, NSString **problem) {
    *fetched = 0;
    if (!is_key(key)) {
        *problem = @"not a config key";
        return NO;
    }
    NSString *path = [data stringByAppendingPathComponent:cdn_path(@"config", key)];
    NSData *have = [NSData dataWithContentsOfFile:path];
    if (have && [hex(md5(have)) isEqual:key]) return YES;
    SPCDN *cdn = [SPCDN new];
    cdn.servers = servers;
    cdn.fetch = fetch;
    NSData *d = [cdn get:cdn_path(@"config", key) range:NSMakeRange(0, 0)];
    if (!d) {
        *problem = cdn.problem ?: @"no answer";
        return NO;
    }
    if (![hex(md5(d)) isEqual:key]) {
        *problem = [NSString stringWithFormat:@"config %@ doesn't match its key", key];
        return NO;
    }
    NSError *e = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    if (![d writeToFile:path options:NSDataWritingAtomic error:&e]) {
        *problem = [NSString stringWithFormat:@"couldn't write config %@ (%@ %ld)", key, e.domain, (long)e.code];
        return NO;
    }
    *fetched = d.length;
    return YES;
}

BOOL sp_version_newer(NSString *a, NSString *b) {
    NSArray<NSNumber *> * (^parse)(NSString *) = ^NSArray<NSNumber *> *(NSString *v) {
        if (!v.length) return nil;
        NSMutableArray *out = [NSMutableArray array];
        NSCharacterSet *notDigit = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
        for (NSString *p in [v componentsSeparatedByString:@"."]) {
            if (!p.length || [p rangeOfCharacterFromSet:notDigit].location != NSNotFound) return nil;
            [out addObject:@(p.longLongValue)];
        }
        return out;
    };
    NSArray<NSNumber *> *x = parse(a), *y = parse(b);
    if (!x || !y) return NO;
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        long long p = i < x.count ? x[i].longLongValue : 0, q = i < y.count ? y[i].longLongValue : 0;
        if (p != q) return p > q;
    }
    return NO;
}

BOOL sp_update_caught_up(NSDictionary<NSString *, NSString *> *bundled, NSDictionary<NSString *, NSString *> *update) {
    if (!bundled[@"Build Key"].length || !update[@"Build Key"].length) return NO;
    return [bundled[@"Build Key"] isEqual:update[@"Build Key"]] || [bundled[@"Version"] isEqual:update[@"Version"]] ||
           sp_version_newer(bundled[@"Version"], update[@"Version"]);
}

NSString *sp_patch_news(NSString *game, NSString *version) {
    return version.length ? [NSString stringWithFormat:@"%@ %@ is out", game, version]
                          : [NSString stringWithFormat:@"A new build of %@ is out", game];
}

NSString *sp_patch_needs_update_body(NSString *news) {
    return [NSString stringWithFormat:@"%@, and this version of Slashplayed can't run it yet. In Slashplayed Companion on "
                                      @"your Mac, check for updates; once there's one for it, press Play there.", news];
}

// GameStore.buildInfoColumns: .build.info's columns and types, in Battle.net's order on the Mac.
static NSArray<NSString *> *build_info_columns(void) {
    return @[@"Branch!STRING:0", @"Active!DEC:1", @"Build Key!HEX:16", @"CDN Key!HEX:16", @"Install Key!HEX:16",
             @"IM Size!DEC:4", @"CDN Path!STRING:0", @"CDN Hosts!STRING:0", @"CDN Servers!STRING:0", @"Tags!STRING:0",
             @"Armadillo!STRING:0", @"Last Activated!STRING:0", @"Version!STRING:0", @"KeyRing!HEX:16", @"Product!STRING:0"];
}

// `existing` with `mine` as the product's row (by .build.info's column names), its Tags kept from the
// product's row in `existing` when that has some, else mine's, else Flavor.tags' default (a US English Mac
// install's). With `mineWins`, mine's Tags (a game the device decides the region of: sp_game_region), so a
// region changed in Settings isn't put back by the old row's. sp_build_info_with's and
// sp_build_info_for_image's layout.
static NSString *build_info_merged(NSString *existing, NSString *product, NSDictionary<NSString *, NSString *> *given,
                                   BOOL mineWins) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *c in build_info_columns()) [names addObject:[c componentsSeparatedByString:@"!"][0]];
    NSString * (^line)(NSDictionary *) = ^NSString *(NSDictionary *row) {
        NSMutableArray *values = [NSMutableArray array];
        for (NSString *n in names) [values addObject:row[n] ?: @""];
        return [values componentsJoinedByString:@"|"];
    };
    // The existing rows, by their own header's column names.
    NSArray<NSString *> *lines = [existing ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *columns = [NSMutableArray array];
    for (NSString *c in [lines.firstObject ?: @"" componentsSeparatedByString:@"|"])
        [columns addObject:[c componentsSeparatedByString:@"!"][0]];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *l in lines.count > 1 ? [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)] : @[]) {
        if (!l.length || [l hasPrefix:@"#"]) continue;
        NSArray<NSString *> *values = [l componentsSeparatedByString:@"|"];
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < MIN(columns.count, values.count); i++) row[columns[i]] = values[i];
        [rows addObject:row];
    }
    // The product's last row is its row (sp_table_row, GameStore.BuildInfo.byProduct).
    NSString *tags = nil;
    for (NSDictionary *row in rows)
        if (!(mineWins && given[@"Tags"].length) && [row[@"Product"] isEqual:product] && [row[@"Tags"] length]) tags = row[@"Tags"];
    NSMutableDictionary *withTags = [given mutableCopy];
    withTags[@"Tags"] = tags ?: (given[@"Tags"].length ? given[@"Tags"]
                                                     : @"OSX x86_64 US? acct-USA? geoip-US? enUS speech?:OSX x86_64 US? acct-USA? geoip-US? enUS text?");
    withTags[@"Product"] = product;
    NSString *mine = line(withTags);
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@\n", [build_info_columns() componentsJoinedByString:@"|"]];
    BOOL placed = NO;
    for (NSDictionary *row in rows) {
        if (![row[@"Product"] isEqual:product]) [out appendFormat:@"%@\n", line(row)];
        else if (!placed) {
            [out appendFormat:@"%@\n", mine];
            placed = YES;
        }
    }
    if (!placed) [out appendFormat:@"%@\n", mine];
    return out;
}

NSString *sp_build_info_with(NSString *existing, NSString *product, NSString *region, NSString *tags,
                             NSDictionary<NSString *, NSString *> *version, NSDictionary<NSString *, NSString *> *cdns) {
    // BlizzardCDN.buildInfoLine.
    NSMutableDictionary *row = [@{
        @"Branch": region, @"Active": @"1", @"Build Key": version[@"BuildConfig"] ?: @"", @"CDN Key": version[@"CDNConfig"] ?: @"",
        @"CDN Path": cdns[@"Path"] ?: @"", @"CDN Hosts": cdns[@"Hosts"] ?: @"", @"CDN Servers": cdns[@"Servers"] ?: @"",
        @"Version": version[@"VersionsName"] ?: @"", @"KeyRing": version[@"KeyRing"] ?: @"",
    } mutableCopy];
    if (tags.length) row[@"Tags"] = tags;
    return build_info_merged(existing, product, row, tags.length > 0);
}

NSString *sp_build_info_for_image(NSString *existing, NSString *product, NSString *kept, NSString *stamp,
                                  NSDictionary<NSString *, NSString *> *region, NSString **why) {
    *why = nil;
    NSString *build = sp_table_row(stamp, @"Product", product)[@"Build Key"];
    if (!build.length) return nil;
    NSDictionary<NSString *, NSString *> *have = sp_table_row(existing, @"Product", product);
    // With the device's region: its row also has to be in it (a Settings change since the last start).
    BOOL inRegion = !region || ([have[@"Branch"] isEqual:region[@"Branch"]] && [have[@"Tags"] isEqual:region[@"Tags"]]);
    if ([have[@"Build Key"] isEqual:build] && inRegion) return nil;
    NSDictionary<NSString *, NSString *> *row = sp_table_row(kept, @"Product", product);
    if (![row[@"Build Key"] isEqual:build] || !row[@"CDN Key"].length) {
        *why = row ? @"the row kept beside the image is another build's" : @"no row is kept beside the image";
        return nil;
    }
    if (region) {
        NSMutableDictionary *mine = [row mutableCopy];
        mine[@"Branch"] = region[@"Branch"];
        mine[@"Tags"] = region[@"Tags"];
        row = mine;
    }
    return build_info_merged(existing, product, row, region != nil);
}

// ---- the region a game plays in (issue #34)

NSArray<NSString *> *sp_regions(void) { return @[@"us", @"eu", @"kr", @"tw"]; }

NSString *sp_region_for_country(NSString *country) {
    NSString *c = country.uppercaseString;
    if (!c.length) return @"us";
    if ([c isEqual:@"KR"]) return @"kr";
    if ([@[@"TW", @"HK", @"MO"] containsObject:c]) return @"tw";
    // Europe (Russia, the Caucasus, and Cyprus included), the Middle East, and Africa: Battle.net's Europe.
    // Everything else, the Americas and Oceania and every country not listed (China, Japan, Southeast
    // Asia, Central Asia), is the Americas: Slashplayed never offers China (cn), Southeast Asia (sg), or
    // the test region (xx).
    static NSSet<NSString *> *europe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        europe = [NSSet setWithArray:[@"AD AL AT AX BA BE BG BY CH CY CZ DE DK EE ES FI FO FR GB GG GI GR HR HU IE IM IS IT JE "
                                      @"LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM UA VA XK "
                                      @"AM AZ GE "
                                      @"AE BH IL IQ IR JO KW LB OM PS QA SA SY TR YE "
                                      @"AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ GW KE KM LR LS LY "
                                      @"MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA "
                                      @"ZM ZW" componentsSeparatedByString:@" "]];
    });
    return [europe containsObject:c] ? @"eu" : @"us";
}

NSString *sp_region_name(NSString *region) {
    NSDictionary<NSString *, NSString *> *names = @{@"us": @"Americas", @"eu": @"Europe", @"kr": @"Korea", @"tw": @"Taiwan"};
    return names[region.lowercaseString] ?: region.uppercaseString;
}

NSArray<NSString *> *sp_region_locales(NSString *region) {
    NSDictionary<NSString *, NSArray<NSString *> *> *locales = @{
        @"us": @[@"enUS", @"esMX", @"ptBR"],
        // Europe's English is enUS: the clients have no enGB (no install manifest lists it), and one with
        // textLocale enGB opens its region picker, which the device can't show, and exits (issue #88).
        @"eu": @[@"enUS", @"deDE", @"esES", @"frFR", @"itIT", @"ruRU"],
        @"kr": @[@"koKR"],
        @"tw": @[@"zhTW"],
    };
    return locales[region.lowercaseString] ?: @[];
}

BOOL sp_locale_shipped(NSString *locale, NSArray<NSString *> *shipped) {
    return !shipped || [shipped containsObject:locale];
}

// Slashplayed 1.4 and 1.5 gave Europe's English as enGB, in region files and the kept rows' Tags: read as enUS,
// so a game installed then plays without installing it again (the start then writes enUS everywhere else).
static NSString *game_locale(NSString *locale) { return [locale isEqual:@"enGB"] ? @"enUS" : locale; }

NSString *sp_region_locale(NSString *region, NSArray<NSString *> *preferred, NSArray<NSString *> *shipped) {
    NSArray<NSString *> *locales = sp_region_locales(region);
    if (!locales.count) return @"enUS";
    for (NSString *tag in preferred) {
        // BCP 47 (en-GB, es-419, zh-Hant-TW): the language decides, since each region has one locale per language.
        NSString *language = [tag componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]]
                                 .firstObject.lowercaseString;
        for (NSString *locale in locales)
            if ([[locale substringToIndex:2] isEqual:language] && sp_locale_shipped(locale, shipped)) return locale;
    }
    return locales.firstObject;
}

NSString *sp_region_tags(NSString *region, NSString *text, NSString *speech) {
    // Flavor.tags' layout: the speech group, then the text group. Battle.net's acct- and geoip- tags are left
    // out: no install manifest lists them (the client fetches by platform, region, and locale), and the
    // device has no account country to give.
    NSString *r = region.uppercaseString;
    return [NSString stringWithFormat:@"OSX x86_64 %@? %@ speech?:OSX x86_64 %@? %@ text?", r, speech, r, text];
}

void sp_tags_locales(NSString *tags, NSString **text, NSString **speech) {
    *text = *speech = nil;
    for (NSString *group in [tags ?: @"" componentsSeparatedByString:@":"]) {
        NSString *locale = nil;
        BOOL isText = NO, isSpeech = NO;
        for (NSString *tag in [group componentsSeparatedByString:@" "]) {
            if ([tag isEqual:@"text?"]) isText = YES;
            else if ([tag isEqual:@"speech?"]) isSpeech = YES;
            else if ([tag rangeOfString:@"^[a-z]{2}[A-Z]{2}$" options:NSRegularExpressionSearch].location != NSNotFound) locale = tag;
        }
        if (isText && locale) *text = locale;
        if (isSpeech && locale) *speech = locale;
    }
}

static BOOL is_region(NSString *r) {
    NSCharacterSet *notRegion = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"].invertedSet;
    return r.length && [r rangeOfCharacterFromSet:notRegion].location == NSNotFound;
}

static NSString *const region_header = @"Product!STRING:0|Region!STRING:0|Text!STRING:0|Speech!STRING:0|Shipped!STRING:0";

NSString *sp_region_file(NSString *product, NSDictionary<NSString *, NSString *> *choice) {
    return [NSString stringWithFormat:@"%@\n%@|%@|%@|%@|%@\n", region_header, product, choice[@"Region"], choice[@"Text"],
                                      choice[@"Speech"], choice[@"Shipped"] ?: @""];
}

NSDictionary<NSString *, NSString *> *sp_game_region(NSString *product, BOOL device, NSString *regionFile, NSString *kept,
                                                     NSString *stamp, NSString *buildInfo, NSString *country,
                                                     NSArray<NSString *> *preferred) {
    NSDictionary<NSString *, NSString *> *info = sp_table_row(buildInfo, @"Product", product);
    NSDictionary<NSString *, NSString *> *stamped = sp_table_row(stamp, @"Product", product);
    // A region from a row, its languages from the row's Tags (or `tagsFrom`'s), else the device's for that region.
    NSDictionary * (^from)(NSString *, NSString *, NSString *) = ^NSDictionary *(NSString *region, NSString *tags, NSString *source) {
        NSString *text = nil, *speech = nil;
        sp_tags_locales(tags, &text, &speech);
        text = game_locale(text);
        speech = game_locale(speech);
        text = text ?: speech ?: (device ? sp_region_locale(region, preferred, nil) : sp_region_locales(region).firstObject ?: @"enUS");
        return @{@"Region": region, @"Text": text, @"Speech": speech ?: text, @"Source": source};
    };
    NSString *infoBranch = info[@"Branch"].lowercaseString, *stampBranch = stamped[@"Branch"].lowercaseString;
    if (!device) {
        // The Mac's: its .build.info row (the companion sends it again at every sync), else the image's stamp.
        // With neither, nothing says the region: "default", which Config.wtf doesn't follow (sp_config_with_region).
        if (is_region(infoBranch)) return from(infoBranch, info[@"Tags"], @"mac");
        if (is_region(stampBranch)) return from(stampBranch, nil, @"mac");
        return from(@"us", nil, @"default");
    }
    NSDictionary<NSString *, NSString *> *chosen = sp_table_row(regionFile, @"Product", product);
    if ([sp_regions() containsObject:chosen[@"Region"]] && chosen[@"Text"].length) {
        NSMutableDictionary *out = [@{@"Region": chosen[@"Region"], @"Text": game_locale(chosen[@"Text"]),
                                      @"Speech": game_locale(chosen[@"Speech"].length ? chosen[@"Speech"] : chosen[@"Text"]),
                                      @"Source": @"chosen"}
                                    mutableCopy];
        if (chosen[@"Shipped"].length) out[@"Shipped"] = chosen[@"Shipped"];
        return out;
    }
    // A game the device made before the region file: its kept row, else its stamp, as before.
    NSDictionary<NSString *, NSString *> *keptRow = sp_table_row(kept, @"Product", product);
    if (is_region(keptRow[@"Branch"].lowercaseString)) return from(keptRow[@"Branch"].lowercaseString, keptRow[@"Tags"], @"kept row");
    if (is_region(stampBranch))
        return from(stampBranch, [infoBranch isEqual:stampBranch] ? info[@"Tags"] : nil, @"stamp");
    // Game data with a row and no image (an image the device made was refused and deleted): its region.
    if (is_region(infoBranch)) return from(infoBranch, info[@"Tags"], @"build.info");
    NSString *region = sp_region_for_country(country);
    NSString *text = sp_region_locale(region, preferred, nil);
    return @{@"Region": region, @"Text": text, @"Speech": text, @"Source": @"device"};
}

NSString *sp_table_with(NSString *text, NSString *product, NSDictionary<NSString *, NSString *> *values) {
    NSMutableArray<NSString *> *lines = [[text ?: @"" componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count < 2) return nil;
    NSMutableArray<NSString *> *columns = [NSMutableArray array];
    for (NSString *c in [lines[0] componentsSeparatedByString:@"|"]) [columns addObject:[c componentsSeparatedByString:@"!"][0]];
    NSUInteger productAt = [columns indexOfObject:@"Product"];
    if (productAt == NSNotFound) return nil;
    BOOL changed = NO;
    for (NSUInteger i = 1; i < lines.count; i++) {
        if ([lines[i] hasPrefix:@"#"]) continue;
        NSMutableArray<NSString *> *v = [[lines[i] componentsSeparatedByString:@"|"] mutableCopy];
        if (v.count <= productAt || ![v[productAt] isEqual:product]) continue;
        for (NSString *name in values) {
            NSUInteger at = [columns indexOfObject:name];
            if (at == NSNotFound || at >= v.count || [v[at] isEqual:values[name]]) continue;
            v[at] = values[name];
            changed = YES;
        }
        lines[i] = [v componentsJoinedByString:@"|"];
    }
    return changed ? [lines componentsJoinedByString:@"\n"] : nil;
}

NSString *sp_config_with_region(NSString *config, NSDictionary<NSString *, NSString *> *choice, NSArray<NSString *> **set) {
    NSString *text = config ?: @"";
    NSArray<NSArray<NSString *> *> *cvars = @[@[@"portal", choice[@"Region"]], @[@"textLocale", choice[@"Text"]],
                                              @[@"audioLocale", choice[@"Speech"]]];
    // Each cvar's value now (the last line of it, as the game reads it), nil without one.
    NSString * (^value)(NSString *) = ^NSString *(NSString *name) {
        NSString *pattern = [NSString stringWithFormat:@"^SET %@ \"([^\"]*)\"[ \\t\\r]*$", [NSRegularExpression escapedPatternForString:name]];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
            options:NSRegularExpressionCaseInsensitive | NSRegularExpressionAnchorsMatchLines error:nil];
        NSTextCheckingResult *last = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)].lastObject;
        return last ? [text substringWithRange:[last rangeAtIndex:1]] : nil;
    };
    // The region moved since the game last ran (Settings, or Battle.net on the Mac), or the portal never was the
    // region (an older companion's first Config.wtf said "us" whatever the Mac's region, issue #94): the portal
    // and both languages go with it, since the old languages are the old portal's. Otherwise a value set stays
    // (a language picked in the game's own options), and only a missing or empty one is filled.
    NSString *portal = value(@"portal");
    BOOL follow = ![choice[@"Source"] isEqual:@"default"];
    BOOL moved = follow && portal.length && ![portal.lowercaseString isEqual:choice[@"Region"]];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSArray<NSString *> *cvar in cvars) {
        NSString *now = value(cvar[0]), *line = [NSString stringWithFormat:@"SET %@ \"%@\"", cvar[0], cvar[1]];
        if (now.length && !moved) continue;
        if ([now isEqual:cvar[1]]) continue;
        if (now) {
            NSString *pattern = [NSString stringWithFormat:@"^SET %@ \"[^\"]*\"[ \\t\\r]*$", [NSRegularExpression escapedPatternForString:cvar[0]]];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                options:NSRegularExpressionCaseInsensitive | NSRegularExpressionAnchorsMatchLines error:nil];
            text = [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                           withTemplate:[NSRegularExpression escapedTemplateForString:line]];
        } else {
            if (text.length && ![text hasSuffix:@"\n"]) text = [text stringByAppendingString:@"\n"];
            text = [text stringByAppendingFormat:@"%@\n", line];
        }
        [names addObject:cvar[0]];
    }
    *set = names;
    return text;
}

// ---- the game's client in Library/spgames (launcher.m, sppatch.m)

NSString *sp_slice_problem(NSString *path) {
    char why[256];
    return spguest_check_file(path.fileSystemRepresentation, why, sizeof why) ? nil : @(why);
}

NSString *sp_slice_retire(NSString *games, NSString *flavor, NSString *product) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *file = [games stringByAppendingPathComponent:[@"wow-" stringByAppendingString:flavor]];
    // What 1.4 and earlier left when a crash or a full disk stopped its signing part way (spsign.m's sp_sign
    // wrote <dest>.signing, then <dest>.signed, beside the image; an Update signed into wow-<flavor>.signing
    // first, so its own were .signing.signing and .signing.signed): nothing reads them, and each is a client's size.
    NSMutableArray<NSString *> *leftovers = [NSMutableArray array];
    for (NSString *suffix in @[@".signing", @".signed", @".signing.signing", @".signing.signed"]) {
        NSString *path = [file stringByAppendingString:suffix];
        unsigned long long size = [fm attributesOfItemAtPath:path error:nil].fileSize;
        if ([fm removeItemAtPath:path error:nil])
            [leftovers addObject:[NSString stringWithFormat:@"%@ (%.1f MB)", path.lastPathComponent, size / 1e6]];
    }
    NSString *left = leftovers.count ? [NSString stringWithFormat:@"deleted what an older Slashplayed's signing left in Library/spgames: %@",
                                                                  [leftovers componentsJoinedByString:@", "]] : nil;
    if (![fm fileExistsAtPath:file]) return left;
    NSString *why = sp_slice_problem(file);
    if (!why) return left;
    NSString *stamp = [games stringByAppendingPathComponent:[@"spbuild-" stringByAppendingString:flavor]];
    NSString *version = sp_table_row([NSString stringWithContentsOfFile:stamp encoding:NSUTF8StringEncoding error:nil], @"Product",
                                     product)[@"Version"];
    unsigned long long size = [fm attributesOfItemAtPath:file error:nil].fileSize;
    [fm removeItemAtPath:stamp error:nil];
    [fm removeItemAtPath:file error:nil];
    for (NSString *name in @[@"spbuildinfo-", @"spsource-"])
        [fm removeItemAtPath:[games stringByAppendingPathComponent:[name stringByAppendingString:flavor]] error:nil];
    return [NSString stringWithFormat:@"retired Library/spgames/wow-%@ (%@ %@, %.1f MB): %@; the game data stays%@", flavor, product,
                                      version ?: @"with no stamp", size / 1e6, why, left ? [@"; " stringByAppendingString:left] : @""];
}

NSArray<NSString *> *sp_games(NSArray<NSString *> *order, NSArray<NSString *> *made, NSSet<NSString *> **installable) {
    NSMutableSet<NSString *> *none = [NSMutableSet set];
    for (NSString *f in order)
        if (![made containsObject:f]) [none addObject:f];
    *installable = none;
    return [order sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger ia = [order indexOfObject:a], ib = [order indexOfObject:b];
        return ia < ib ? NSOrderedAscending : ia > ib ? NSOrderedDescending : [a compare:b];
    }];
}

NSString *sp_flavor_info(NSString *product) {
    return [NSString stringWithFormat:@"Product Flavor!STRING:0\n%@\n", product];
}

BOOL sp_addons_place(NSString *addons, NSString *game, BOOL hover, NSString **line) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *written = [NSMutableArray array], *failed = [NSMutableArray array];
    NSUInteger same = 0;
    for (NSString *name in hover ? @[@"SPMovie", @"SPHover"] : @[@"SPMovie", @"SPKeyboard"])
        for (NSString *ext in @[@"toc", @"lua"]) {
            NSString *file = [NSString stringWithFormat:@"%@/%@.%@", name, name, ext];
            NSData *bytes = [NSData dataWithContentsOfFile:[addons stringByAppendingPathComponent:file]];
            if (!bytes) {
                [failed addObject:[file stringByAppendingString:@" (not in the app)"]];
                continue;
            }
            NSString *dest = [game stringByAppendingPathComponent:[@"Interface/AddOns" stringByAppendingPathComponent:file]];
            if ([[NSData dataWithContentsOfFile:dest] isEqualToData:bytes]) {
                same++;
                continue;
            }
            [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if ([bytes writeToFile:dest atomically:YES]) [written addObject:file];
            else [failed addObject:[file stringByAppendingString:@" (couldn't be written)"]];
        }
    NSMutableString *text = [NSMutableString stringWithFormat:@"addons: %lu up to date", (unsigned long)same];
    if (written.count) [text appendFormat:@", wrote %@", [written componentsJoinedByString:@" "]];
    if (failed.count) [text appendFormat:@"; FAILED %@", [failed componentsJoinedByString:@", "]];
    *line = text;
    return !failed.count;
}
