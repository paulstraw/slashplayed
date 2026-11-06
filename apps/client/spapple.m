// The Apple token the device keeps, and the one file that touches it. With it the app gets its own renewed
// provisioning profiles from Apple (spapple, the Rust library: spapple/src/lib.rs), which the JIT helper
// installs (spjit.m's sp_jit_profiles), so a free team's 7-day app keeps opening with no computer.
//
// What's kept (owner decisions, 2026-11-02): the xcode.auth app token Apple issues at a sign-in, with the
// adsid it goes with and the anisette server and machine identity it was made on, as one JSON blob in the
// keychain (this device only, never synced). Never the Apple ID's password, and not the GrandSlam token,
// which stops minting app tokens after about an hour. It comes from slashplayed-companion, which pushes it
// at setup as Library/spappletoken.json (0600); the launcher imports it here at its start and wipes the file.
//
// The token is a credential (CLAUDE.md, "The Apple ID is a credential"): nothing here logs it, its size, or
// any of its fields but the stated expiry's date. Requests to spapple carry it in memory only, zeroed after.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#import "spapple/spapple.h"

static NSString *const service = @"Slashplayed Apple token";
static NSString *const account = @"token";
static NSString *const pushed = @"Library/spappletoken.json";

static NSString *home(NSString *relative) { return [NSHomeDirectory() stringByAppendingPathComponent:relative]; }

static NSMutableData *keychain_get(void) {
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    }, &out);
    return st == errSecSuccess ? [(__bridge_transfer NSData *)out mutableCopy] : nil;
}

// After first unlock, not only while unlocked: a refresh may one day run in the background.
static OSStatus keychain_put(NSData *value) {
    SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                (__bridge id)kSecAttrService: service, (__bridge id)kSecAttrAccount: account});
    return SecItemAdd((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecValueData: value,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        (__bridge id)kSecAttrSynchronizable: @NO,
    }, NULL);
}

static void zero(NSMutableData *d) {
    if (d.length) memset(d.mutableBytes, 0, d.length);
}

// Zeros, then unlink, as spsign.m's wipe. YES if there was a file.
static BOOL wipe(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat st;
    if (!fstat(fd, &st)) {
        static const char zeros[4096];
        for (off_t o = 0; o < st.st_size; o += sizeof zeros) pwrite(fd, zeros, sizeof zeros, o);
        fsync(fd);
    }
    close(fd);
    unlink(path.fileSystemRepresentation);
    return YES;
}

// The fields spapple's Token needs, all there and of the right kinds; nil when not. Only shapes are checked:
// whether Apple still takes the token, only Apple says.
static NSDictionary *parse(NSData *blob) {
    NSDictionary *t = blob.length ? [NSJSONSerialization JSONObjectWithData:blob options:0 error:nil] : nil;
    if (![t isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *k in @[@"token", @"adsid", @"anisette_url"])
        if (![t[k] isKindOfClass:NSString.class] || ![t[k] length]) return nil;
    for (NSString *k in @[@"expiry", @"duration"])
        if (![t[k] isKindOfClass:NSNumber.class]) return nil;
    return t;
}

static NSString *day(NSDate *date) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:date];
}

// Apple's stated expiry is in milliseconds since 1970.
static NSDate *stated_expiry(NSDictionary *t) {
    return [NSDate dateWithTimeIntervalSince1970:[t[@"expiry"] doubleValue] / 1000];
}

NSString *sp_apple_token_import(void) {
    NSMutableData *blob = [[NSData dataWithContentsOfFile:home(pushed)] mutableCopy];
    if (!wipe(home(pushed))) return nil;
    NSDictionary *t = parse(blob);
    NSString *line;
    if (!t) {
        line = @"apple: the pushed token wasn't one; deleted, nothing imported";
    } else {
        OSStatus st = keychain_put(blob);
        line = st == errSecSuccess
                   ? [NSString stringWithFormat:@"apple: imported the pushed token into the keychain (this device only); Apple says "
                                                @"it's good until %@; the pushed file is deleted", day(stated_expiry(t))]
                   : [NSString stringWithFormat:@"apple: the keychain refused the pushed token (%d); the pushed file is deleted", (int)st];
    }
    zero(blob);
    return line;
}

NSString *sp_apple_token_describe(void) {
    NSMutableData *blob = keychain_get();
    NSDictionary *t = parse(blob);
    zero(blob);
    if (!blob) return @"apple: no token";
    if (!t) return @"apple: the keychain's token is unreadable";
    return [NSString stringWithFormat:@"apple: a token, Apple says good until %@", day(stated_expiry(t))];
}

BOOL sp_apple_token_present(void) {
    NSMutableData *blob = keychain_get();
    BOOL ok = parse(blob) != nil;
    zero(blob);
    return ok;
}

NSString *sp_apple_token_forget(void) {
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                              (__bridge id)kSecAttrService: service});
    BOOL file = wipe(home(pushed));
    return [NSString stringWithFormat:@"apple: %@%@", st == errSecSuccess ? @"forgot the token" : st == errSecItemNotFound
                                                         ? @"no token to forget" : [NSString stringWithFormat:@"couldn't forget the token: keychain %d", (int)st],
            file ? @"; a pushed one not yet imported is deleted too" : @""];
}

// The app's and its helper's renewed profiles from Apple, with the keychain's token, for team `team` and
// the App IDs `app` and `app`.helper: @{@"app": NSData, @"helper": NSData}. Blocks on the network (up to a
// minute or so): never on the main thread. Nil when it can't: *problem says why (no secret in it), and
// *code is Apple's error number when Apple sent one. A re-provisioned anisette identity goes back into the
// keychain with the token.
NSDictionary *sp_apple_profiles(NSString *team, NSString *app, NSString **problem, NSNumber **code) {
    NSMutableData *blob = keychain_get();
    NSMutableDictionary *token = [parse(blob) mutableCopy];
    zero(blob);
    if (!token) {
        *problem = blob ? @"the keychain's Apple token is unreadable" : @"there's no Apple token on this device";
        return nil;
    }
    NSMutableData *request = [[NSJSONSerialization dataWithJSONObject:@{
        @"op": @"profiles", @"token": token, @"team": team, @"app": app,
        @"helper": [app stringByAppendingString:@".helper"],
    } options:0 error:nil] mutableCopy];
    [request appendBytes:"" length:1];
    char *raw = spapple_call(request.bytes);
    zero(request);
    NSDictionary *reply = raw ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:strlen(raw)] options:0 error:nil] : nil;
    if (raw) spapple_free(raw);
    if (![reply isKindOfClass:NSDictionary.class]) {
        *problem = @"spapple's reply didn't parse";
        return nil;
    }
    if (![reply[@"ok"] boolValue]) {
        *problem = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"no reason given";
        if ([reply[@"code"] isKindOfClass:NSNumber.class]) *code = reply[@"code"];
        return nil;
    }
    NSString *state = reply[@"anisette_state"];
    if ([state isKindOfClass:NSString.class] && state.length) {
        token[@"anisette_state"] = state;
        NSMutableData *updated = [[NSJSONSerialization dataWithJSONObject:token options:0 error:nil] mutableCopy];
        OSStatus st = keychain_put(updated);
        zero(updated);
        if (st != errSecSuccess) {
            *problem = [NSString stringWithFormat:@"the keychain refused the token's new anisette identity (%d)", (int)st];
            return nil;
        }
    }
    NSData *a = [[NSData alloc] initWithBase64EncodedString:reply[@"app"] ?: @"" options:0];
    NSData *h = [[NSData alloc] initWithBase64EncodedString:reply[@"helper"] ?: @"" options:0];
    if (!a.length || !h.length) {
        *problem = @"Apple's reply had no profile";
        return nil;
    }
    return @{@"app": a, @"helper": h};
}

// ---- Renewing the app's profiles at launch

NSArray<NSDictionary *> *sp_jit_profiles(NSArray<NSData *> *install, void (^pump)(double), NSString **problem);  // spjit.m
NSDictionary *sp_profile_plist(NSData *profile);  // spsign.m
NSString *sp_profile_app_id(NSData *profile);  // spsign.m
NSString *sp_app_id(void);  // spsign.m
void sp_launch_say(NSString *s);  // launcher.m

static void say(NSString *s) { sp_launch_say([@"renew: " stringByAppendingString:s]); }

// Renew when the app's latest profile has less than this left (owner, 2026-11-03: about 3 days, so a week's
// free profile renews on any launch in its last 3 days).
static const double renew_within = 3 * 86400;

// Copies of the profiles a renewal installed (spsign.m's sp_profile_copies lists them).
static NSString *copies_dir(void) { return home(@"Library/spprofiles"); }
NSArray<NSString *> *sp_profile_copies(void);  // spsign.m

static NSString *app_dir(void) { return NSBundle.mainBundle.bundlePath; }

// The latest expiry of a profile for this app (not its helper) the launcher knows: its embedded one and the
// renewals' copies. Nil when it can't tell.
NSDate *sp_profile_expiry(void) {
    NSString *appid = sp_app_id();
    NSDate *latest = nil;
    NSMutableArray *paths = [NSMutableArray arrayWithObject:[app_dir() stringByAppendingPathComponent:@"embedded.mobileprovision"]];
    [paths addObjectsFromArray:sp_profile_copies()];
    for (NSString *path in paths) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (!appid || ![sp_profile_app_id(d) isEqual:appid]) continue;
        NSDate *e = sp_profile_plist(d)[@"ExpirationDate"];
        if ([e isKindOfClass:NSDate.class] && (!latest || [e compare:latest] == NSOrderedDescending)) latest = e;
    }
    return latest;
}

// The start screen's word on the renewal (Library/sprenew.txt, one line): "ok <day>" (the app's profiles
// last until then), "signin <day>" (renewing needs an Apple sign-in on this device, and the app stops
// opening after that day), or "failed <day>" (it couldn't renew this time; it tries again next launch).
static void write_state(NSString *word, NSDate *until) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", word, until ? day(until) : @"unknown"];
    [line writeToFile:home(@"Library/sprenew.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Deletes the copies that have expired: they list nothing and keep the app open no longer.
static void prune_copies(void) {
    for (NSString *path in sp_profile_copies()) {
        NSDate *e = sp_profile_plist([NSData dataWithContentsOfFile:path])[@"ExpirationDate"];
        if (![e isKindOfClass:NSDate.class] || e.timeIntervalSinceNow < 0) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
}

// Apple's refusals that mean the token itself no longer works, so only a new sign-in helps (as opposed to the
// network or Apple being down, which the next launch retries). GrandSlam's auth errors, and the developer
// services' "not signed in" family; anything unknown counts as a retry, never as a reason to ask.
static BOOL token_refused(NSNumber *code, NSString *problem) {
    if (code) {
        long c = code.longValue;
        if (c == 1100 || c == 1101 || c == 401 || (c <= -22000 && c > -23000)) return YES;
    }
    return [problem rangeOfString:@"401"].location != NSNotFound;
}

// Every launch of a game, before the helper attaches: when the app's profiles have less than 3 days left
// (SP_RENEW=now: whatever's left; SP_RENEW=off: never), new ones from Apple with the keychain's token, installed
// by the helper, with copies kept in Library/spprofiles. It never stops the launch: the profiles still have
// days left, and the start screen says when the next launch can't fix it alone (Library/sprenew.txt).
void sp_profiles_renew(void (^pump)(double)) {
    NSString *mode = NSProcessInfo.processInfo.environment[@"SP_RENEW"];
    if ([mode isEqual:@"off"]) return;
    prune_copies();
    NSDate *until = sp_profile_expiry();
    double left = until ? until.timeIntervalSinceNow : 0;
    if (![mode isEqual:@"now"] && until && left > renew_within) {
        write_state(@"ok", until);
        return;
    }
    NSString *appid = sp_app_id();
    NSRange dot = [appid rangeOfString:@"."];
    if (dot.location == NSNotFound) {
        say(@"no App ID in the embedded profile; not renewing");
        return;
    }
    say([NSString stringWithFormat:@"the app's profiles last until %@ (%.1f days)%@", until ? day(until) : @"an unknown day",
         left / 86400, [mode isEqual:@"now"] ? @"; renewing now (SP_RENEW=now)" : @"; renewing"]);
    if (!sp_apple_token_present()) {
        say(@"no Apple token: renewing needs an Apple sign-in on this device");
        write_state(@"signin", until);
        return;
    }
    // Off the main thread (it blocks on the network), with the launch's pump turning meanwhile. Waited for up to
    // 60 s: past that the launch goes on, since the profiles still have days left, and the next launch retries.
    __block NSDictionary *got = nil;
    __block NSString *why = nil;
    __block NSNumber *code = nil;
    __block BOOL done = NO;
    NSObject *lock = [NSObject new];
    double t = CFAbsoluteTimeGetCurrent();
    NSString *team = [appid substringToIndex:dot.location], *bundle = [appid substringFromIndex:dot.location + 1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *w = nil;
        NSNumber *c = nil;
        NSDictionary *g = sp_apple_profiles(team, bundle, &w, &c);
        @synchronized (lock) {
            got = g, why = w, code = c, done = YES;
        }
    });
    for (double end = CFAbsoluteTimeGetCurrent() + 60;;) {
        @synchronized (lock) {
            if (done) break;
        }
        if (CFAbsoluteTimeGetCurrent() > end) {
            say(@"Apple didn't answer within 60 s; the next launch tries again");
            write_state(@"failed", until);
            return;
        }
        pump(0.05);
    }
    if (!got) {
        BOOL refused = token_refused(code, why);
        say([NSString stringWithFormat:@"Apple's profiles didn't come after %.2f s (%@%@)%@", CFAbsoluteTimeGetCurrent() - t, why,
             code ? [NSString stringWithFormat:@", code %@", code] : @"", refused ? @": the token no longer works" : @"; the next launch tries again"]);
        write_state(refused ? @"signin" : @"failed", until);
        return;
    }
    say([NSString stringWithFormat:@"Apple's profiles in %.2f s", CFAbsoluteTimeGetCurrent() - t]);
    NSString *problem = nil;
    NSArray *mine = sp_jit_profiles(@[got[@"app"], got[@"helper"]], pump, &problem);
    if (!mine) {
        // Not the launch's problem: the attach right after says what's wrong with the helper, if anything is.
        say([@"the helper didn't install them: " stringByAppendingString:problem ?: @"no reason"]);
        write_state(@"failed", until);
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:copies_dir() withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *which in @[@"app", @"helper"]) {
        NSData *d = got[which];
        NSString *uuid = sp_profile_plist(d)[@"UUID"];
        if ([uuid isKindOfClass:NSString.class]) [d writeToFile:[copies_dir() stringByAppendingPathComponent:[uuid stringByAppendingPathExtension:@"mobileprovision"]] atomically:YES];
    }
    NSDate *now = sp_profile_expiry();
    say([NSString stringWithFormat:@"renewed: the app's profiles last until %@", now ? day(now) : @"an unknown day"]);
    write_state(@"ok", now);
    return;
}
