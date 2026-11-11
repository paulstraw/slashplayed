// The Apple token the device keeps, and the one file that touches it. With it the app gets its own renewed
// provisioning profiles from Apple (spapple, the Rust library: spapple/src/lib.rs), which the JIT helper
// installs (spjit.m's sp_jit_profiles), so a free team's 7-day app keeps opening with no computer.
//
// What's kept (owner decisions, 2026-11-02): the xcode.auth app token Apple issues at a sign-in, with the
// adsid it goes with and the anisette server and machine identity it was made on, as one JSON blob in the
// keychain (this device only, never synced). Never the Apple ID's password, and not the GrandSlam token,
// which stops minting app tokens after about an hour. It comes one of two ways: slashplayed-companion pushes
// it at setup as Library/spappletoken.json (0600), which the launcher imports here at its start and wipes; or
// the person signs in to Apple on the device, from the start screen or Settings (the launcher's own sign-in,
// below, with spapplescreen.swift its screen): an opt-in for a device whose companion gives no token (the Mac
// companion's, every Vision Pro), or whose token Apple stopped taking.
//
// The token is a credential (CLAUDE.md, "The Apple token is a credential"): nothing here logs it, its size, or
// any of its fields but the stated expiry's date. Requests to spapple carry it in memory only, zeroed after.
// So is the Apple ID's password the sign-in takes (CLAUDE.md, "The Apple ID is a credential"): it goes from
// the screen to spapple in one request, written into a buffer zeroed after, and nothing logs it, its size, or
// the Apple ID; spapple drops it once Apple has it. Only the token the sign-in makes is kept.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
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

// Updated in place, and added only when there's none: deleting first would lose the token whenever the add
// then failed. After first unlock, not only while unlocked: a refresh may one day run in the background.
static OSStatus keychain_put(NSData *value) {
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                             (__bridge id)kSecAttrService: service, (__bridge id)kSecAttrAccount: account},
                                (__bridge CFDictionaryRef) @{
                                    (__bridge id)kSecValueData: value,
                                    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                });
    if (st != errSecItemNotFound) return st;
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

// Zeros, then unlink, as launcher.m's wipe. YES if there was a file.
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

// A number spapple's u64 takes: digits only as written back out (not a boolean, a fraction, an exponent, or
// negative), and few enough of them to fit.
static BOOL whole(id n) {
    if (![n isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) return NO;
    NSString *s = [n stringValue];
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    return s.length && s.length <= 19 && [s rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound;
}

// The fields spapple's Token needs, all there and of the right kinds (anisette_state may be missing, but is a
// string when it's there); nil when not. Only shapes are checked: whether Apple still takes the token, only
// Apple says.
static NSDictionary *parse(NSData *blob) {
    NSDictionary *t = blob.length ? [NSJSONSerialization JSONObjectWithData:blob options:0 error:nil] : nil;
    if (![t isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *k in @[@"token", @"adsid", @"anisette_url"])
        if (![t[k] isKindOfClass:NSString.class] || ![t[k] length]) return nil;
    for (NSString *k in @[@"expiry", @"duration"])
        if (!whole(t[k])) return nil;
    if (t[@"anisette_state"] && ![t[@"anisette_state"] isKindOfClass:NSString.class]) return nil;
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

static void signed_out(void);

NSString *sp_apple_token_forget(void) {
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                              (__bridge id)kSecAttrService: service});
    BOOL file = wipe(home(pushed));
    signed_out();
    return [NSString stringWithFormat:@"apple: %@%@", st == errSecSuccess ? @"forgot the token" : st == errSecItemNotFound
                                                         ? @"no token to forget" : [NSString stringWithFormat:@"couldn't forget the token: keychain %d", (int)st],
            file ? @"; a pushed one not yet imported is deleted too" : @""];
}

// The app's and its helper's renewed profiles from Apple, with the keychain's token, for team `team` and
// the App IDs `app` and `app`.helper: @{@"app": NSData, @"helper": NSData, @"remade": the App IDs made again
// because they'd lapsed, and @"unsaved" when the keychain refused a re-provisioned anisette identity, saying
// so}. Blocks on the network (up to a minute or so): never on the main thread. Nil when it can't: *problem
// says why (no secret in it), *code is Apple's error number when Apple sent one, and *http the HTTP status
// when Apple's own servers refused the request. A re-provisioned anisette identity goes back into the
// keychain with the token, even when a later step failed.
NSDictionary *sp_apple_profiles(NSString *team, NSString *app, NSString **problem, NSNumber **code, NSNumber **http) {
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
    // A re-provisioned identity is kept whether or not the rest of the request worked: the server provisioned
    // it before a later step failed. A refused save is only noted: the profiles are as good either way.
    NSString *unsaved = nil;
    NSString *state = reply[@"anisette_state"];
    if ([state isKindOfClass:NSString.class] && state.length) {
        token[@"anisette_state"] = state;
        NSMutableData *updated = [[NSJSONSerialization dataWithJSONObject:token options:0 error:nil] mutableCopy];
        OSStatus st = keychain_put(updated);
        zero(updated);
        if (st != errSecSuccess)
            unsaved = [NSString stringWithFormat:@"the keychain refused the token's new anisette identity (%d), so it keeps the old one", (int)st];
    }
    if (![reply[@"ok"] boolValue]) {
        NSString *error = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"no reason given";
        *problem = unsaved ? [NSString stringWithFormat:@"%@; and %@", error, unsaved] : error;
        if ([reply[@"code"] isKindOfClass:NSNumber.class]) *code = reply[@"code"];
        if ([reply[@"http_status"] isKindOfClass:NSNumber.class]) *http = reply[@"http_status"];
        return nil;
    }
    NSData *a = [[NSData alloc] initWithBase64EncodedString:reply[@"app"] ?: @"" options:0];
    NSData *h = [[NSData alloc] initWithBase64EncodedString:reply[@"helper"] ?: @"" options:0];
    if (!a.length || !h.length) {
        *problem = @"Apple's reply had no profile";
        return nil;
    }
    NSArray *remade = [reply[@"remade"] isKindOfClass:NSArray.class] ? reply[@"remade"] : @[];
    NSMutableDictionary *got = [@{@"app": a, @"helper": h, @"remade": remade} mutableCopy];
    if (unsaved) got[@"unsaved"] = unsaved;
    return got;
}

// ---- Renewing the app's profiles at launch

NSArray<NSDictionary *> *sp_jit_profiles(NSArray<NSData *> *install, void (^pump)(double), NSString **problem);  // spjit.m
NSDictionary *sp_profile_plist(NSData *profile);  // spjit.m
NSString *sp_profile_app_id(NSData *profile);  // spjit.m
NSString *sp_app_id(void);  // spjit.m
void sp_launch_say(NSString *s);  // launcher.m

static void say(NSString *s) { sp_launch_say([@"renew: " stringByAppendingString:s]); }

// Renew when the app's latest profile has less than this left (owner, 2026-11-03: about 3 days, so a week's
// free profile renews on any launch in its last 3 days).
static const double renew_within = 3 * 86400;

// Copies of the profiles a renewal installed: iOS checks the app against every installed profile, but the
// app can't read the device's list without the helper's tunnel, so these are what it knows it has.
static NSString *copies_dir(void) { return home(@"Library/spprofiles"); }

static NSArray<NSString *> *sp_profile_copies(void) {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:copies_dir() error:nil])
        if ([name.pathExtension isEqual:@"mobileprovision"]) [paths addObject:[copies_dir() stringByAppendingPathComponent:name]];
    return paths;
}

static NSString *app_dir(void) { return NSBundle.mainBundle.bundlePath; }

// The latest expiry of the profiles the launcher knows for one App ID: the embedded ones (the app's and its
// helper's) and the renewals' copies. Nil when there's none.
static NSDate *latest_for(NSString *appid, NSArray<NSString *> *paths) {
    NSDate *latest = nil;
    for (NSString *path in paths) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (!appid || ![sp_profile_app_id(d) isEqual:appid]) continue;
        NSDate *e = sp_profile_plist(d)[@"ExpirationDate"];
        if ([e isKindOfClass:NSDate.class] && (!latest || [e compare:latest] == NSOrderedDescending)) latest = e;
    }
    return latest;
}

// When the app stops opening: the earlier of its own profiles' last day and its helper's, since without the
// helper's (PlugIns/SPJitHelper.appex, App ID <app>.helper) no game loads either. Both come from one renewal,
// so they match in practice. Nil when the app's can't be told; the app's alone when the helper's can't.
NSDate *sp_profile_expiry(void) {
    NSString *appid = sp_app_id();
    NSMutableArray *paths = [NSMutableArray arrayWithObjects:[app_dir() stringByAppendingPathComponent:@"embedded.mobileprovision"],
                             [app_dir() stringByAppendingPathComponent:@"PlugIns/SPJitHelper.appex/embedded.mobileprovision"], nil];
    [paths addObjectsFromArray:sp_profile_copies()];
    NSDate *app = latest_for(appid, paths), *helper = latest_for([appid stringByAppendingString:@".helper"], paths);
    return app && helper && [helper compare:app] == NSOrderedAscending ? helper : app;
}

// The start screen's word on the renewal (Library/sprenew.txt, one line): "ok <time>" (the app's profiles
// last until then), "signin <time>" (renewing needs a new Apple token on this device, and the app stops
// opening at that time), "signedin <time>" (the person has since signed in to Apple here: the next launch
// renews), or "failed <time>" (it couldn't renew this time; it tries again next launch). The time is ISO 8601
// in UTC, so the note can give the person's own day; "unknown" when it can't be told.
static void write_state(NSString *word, NSDate *until) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", word, until ? [[NSISO8601DateFormatter new] stringFromDate:until] : @"unknown"];
    [line writeToFile:home(@"Library/sprenew.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Library/sprenew.txt's word, and its time in *until (nil when it's "unknown"). Nil when there's none, or
// it's stale: its time has passed (past it the app doesn't open), or the profiles the app has now last past
// it (or, with no time, past the renewal window), as after the companion signed the app again. The file is
// only written at a game's launch, so a re-sign since then leaves it behind.
static NSString *read_state(NSDate **until) {
    NSString *line = [NSString stringWithContentsOfFile:home(@"Library/sprenew.txt") encoding:NSUTF8StringEncoding error:nil];
    NSArray *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@" "];
    if (parts.count != 2) return nil;
    *until = [[NSISO8601DateFormatter new] dateFromString:parts[1]];
    if (*until && (*until).timeIntervalSinceNow < 0) return nil;
    NSDate *now = sp_profile_expiry();
    if (now && (*until ? [now compare:*until] == NSOrderedDescending : now.timeIntervalSinceNow > renew_within)) return nil;
    return parts[0];
}

// Whether the start screen offers the Apple sign-in with its note: the last renewal found no token it could use.
BOOL sp_profiles_need_signin(void) {
    NSDate *until = nil;
    return [read_state(&until) isEqual:@"signin"];
}

// A sign-in here answers a "signin" word, and forgetting the token takes that back.
static void signed_in(void) {
    NSDate *until = nil;
    if ([read_state(&until) isEqual:@"signin"]) write_state(@"signedin", until);
}

static void signed_out(void) {
    NSDate *until = nil;
    if ([read_state(&until) isEqual:@"signedin"]) write_state(@"signin", until);
}

// What the start screen says under the games about the renewal, from Library/sprenew.txt: nothing when it's
// fine (or nothing's been tried yet), else why the app may stop opening, with the day, in the person's words.
NSString *sp_profiles_note(void) {
    NSDate *until = nil;
    NSString *word = read_state(&until);
    if (!word || [word isEqual:@"ok"]) return nil;
    if ([word isEqual:@"signedin"])
        return @"You’re signed in to Apple. Slashplayed renews its signing the next time a game starts.";
    NSString *when = @"soon";
    if (until && [NSCalendar.currentCalendar isDateInToday:until]) when = @"later today";
    else if (until && [NSCalendar.currentCalendar isDateInTomorrow:until]) when = @"tomorrow";
    else if (until) when = [@"on " stringByAppendingString:[NSDateFormatter localizedStringFromDate:until dateStyle:NSDateFormatterMediumStyle
                                                                                            timeStyle:NSDateFormatterNoStyle]];
    if ([word isEqual:@"signin"])
        return [NSString stringWithFormat:@"Slashplayed can’t renew its signing on its own, so it stops opening %@. Before then, "
                                          @"run Slashplayed Companion again on the computer you set it up with, or sign in to Apple here.", when];
    return [NSString stringWithFormat:@"Slashplayed couldn’t renew its signing. It tries again the next time a game starts "
                                      @"online, and stops opening %@ if it can’t.", when];
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
// services' "not signed in" family, and a 401 from Apple's own servers (spapple's http_status, never another
// server's). Never the problem's text: it names team and bundle IDs, URLs, and the anisette server's errors,
// where a "401" says nothing about the token. Anything unknown counts as a retry, never as a reason to ask.
static BOOL token_refused(NSNumber *code, NSNumber *http) {
    if (http.integerValue == 401) return YES;
    if (!code) return NO;
    long c = code.longValue;
    return c == 1100 || c == 1101 || c == 401 || (c <= -22000 && c > -23000);
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
    __block NSNumber *code = nil, *http = nil;
    __block BOOL done = NO;
    NSObject *lock = [NSObject new];
    double t = CFAbsoluteTimeGetCurrent();
    NSString *team = [appid substringToIndex:dot.location], *bundle = [appid substringFromIndex:dot.location + 1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *w = nil;
        NSNumber *c = nil, *h = nil;
        NSDictionary *g = sp_apple_profiles(team, bundle, &w, &c, &h);
        @synchronized (lock) {
            got = g, why = w, code = c, http = h, done = YES;
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
        BOOL refused = token_refused(code, http);
        say([NSString stringWithFormat:@"Apple's profiles didn't come after %.2f s (%@%@%@)%@", CFAbsoluteTimeGetCurrent() - t, why,
             code ? [NSString stringWithFormat:@", code %@", code] : @"", http ? [NSString stringWithFormat:@", HTTP %@", http] : @"",
             refused ? @": the token no longer works" : @"; the next launch tries again"]);
        write_state(refused ? @"signin" : @"failed", until);
        return;
    }
    say([NSString stringWithFormat:@"Apple's profiles in %.2f s%@", CFAbsoluteTimeGetCurrent() - t,
         [got[@"remade"] count] ? [NSString stringWithFormat:@", after making %lu lapsed App ID(s) again", (unsigned long)[got[@"remade"] count]] : @""]);
    if (got[@"unsaved"]) say([got[@"unsaved"] stringByAppendingString:@"; installing the profiles anyway"]);
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

// ---- The launcher's own Apple sign-in (opt-in: the start screen's note and Settings' Signing offer it)
//
// A second sign-in to the person's Apple ID, as slashplayed-companion's (spapple's "login" op, isideload's
// GSA sign-in with 2FA), through a third-party anisette server, which the screen says plainly. What's typed
// goes from the screen (spapplescreen.swift, which keeps none of it) to spapple here, off the main thread; the
// screen hears back each step (sp_apple_screen_show). Its end is a token, kept as a pushed one is, once
// spapple has checked the Apple ID is on the team that signed the app. Logged: the steps, the server's host,
// and Apple's error number. Never the Apple ID, the password, a code, or the masked numbers Apple sends.

UIViewController *sp_apple_screen(NSString *noun, NSString *server,
                                  NSString *_Nullable (^begin)(NSString *email, NSString *password, NSString *server),
                                  void (^answer)(NSString *kind, NSInteger number, NSString *code), void (^cancel)(void),
                                  void (^finish)(void));  // spapplescreen.swift
void sp_apple_screen_show(UIViewController *screen, NSDictionary *step);  // spapplescreen.swift
NSString *sp_device_noun(void);  // spjit.m

static void signin_say(NSString *s) { sp_launch_say([@"apple sign-in: " stringByAppendingString:s]); }

// The anisette server the sign-in offers: the last one a sign-in here used, else slashplayed-companion's
// default (account.rs's DEFAULT_ANISETTE: a server backed by Apple's Mac ADI, research/isideload's "Anisette").
static NSString *const anisette_key = @"sp_anisette_url";
static NSString *const default_anisette = @"https://mac-ani.jkcoxson.com";

static NSString *anisette_server(void) {
    NSString *s = [NSUserDefaults.standardUserDefaults stringForKey:anisette_key];
    return s.length ? s : default_anisette;
}

// One spapple request whose JSON may hold the password: written into a buffer of our own, zeroed and freed
// after (NSJSONSerialization's NSData can't be zeroed), and the reply read in place, which spapple_free
// zeroes (it may hold the token). Nil when it didn't parse.
static NSDictionary *call_zeroed(NSDictionary *request) {
    const NSUInteger cap = 16 * 1024;
    uint8_t *buf = calloc(cap, 1);
    NSOutputStream *stream = [NSOutputStream outputStreamToBuffer:buf capacity:cap - 1];
    [stream open];
    NSInteger n = [NSJSONSerialization writeJSONObject:request toStream:stream options:0 error:nil];
    [stream close];
    NSDictionary *reply = nil;
    if (n > 0 && (NSUInteger)n < cap) {
        char *raw = spapple_call((const char *)buf);
        if (raw) {
            id v = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:raw length:strlen(raw) freeWhenDone:NO]
                                                   options:0 error:nil];
            reply = [v isKindOfClass:NSDictionary.class] ? v : nil;
            spapple_free(raw);
        }
    }
    memset_s(buf, cap, 0, cap);
    free(buf);
    return reply;
}

// A failed step in the person's words, from spapple's reply: Apple's refusal when it gave one.
static NSString *signin_problem(NSDictionary *reply) {
    if ([reply[@"problem"] isEqual:@"team"])
        return @"This Apple ID isn’t on the team Slashplayed was signed with, so it can’t renew it. Sign in with that "
               @"Apple ID, or another on its team.";
    long code = [reply[@"code"] isKindOfClass:NSNumber.class] ? [reply[@"code"] longValue] : 0;
    NSString *message = [reply[@"message"] isKindOfClass:NSString.class] ? reply[@"message"] : nil;
    if (code == -20101 || code == -22406) return @"Apple didn’t accept that Apple ID and password.";
    if (code == -80045) return @"Apple refused the anisette server. Try again later, or another server.";
    if (message.length) return [NSString stringWithFormat:@"Apple said: %@", message];
    return @"The sign-in didn’t work. Check the network and the anisette server, then try again.";
}

// Keeps the sign-in's token as a pushed one is kept, and says on the start screen that the next launch
// renews. Nil when it's kept, else what to say.
static NSString *keep(NSDictionary *token) {
    NSMutableData *blob = [token isKindOfClass:NSDictionary.class]
                              ? [[NSJSONSerialization dataWithJSONObject:token options:0 error:nil] mutableCopy] : nil;
    NSDictionary *t = parse(blob);
    OSStatus st = t ? keychain_put(blob) : errSecParam;
    zero(blob);
    if (!t) {
        signin_say(@"Apple's reply had no token");
        return @"Apple’s reply had no token. Try again.";
    }
    if (st != errSecSuccess) {
        signin_say([NSString stringWithFormat:@"the keychain refused the token (%d)", (int)st]);
        return @"The token couldn’t be saved on this device. Try again.";
    }
    [NSUserDefaults.standardUserDefaults setObject:t[@"anisette_url"] forKey:anisette_key];
    signed_in();
    signin_say([NSString stringWithFormat:@"signed in: the token is in the keychain (this device only); Apple says it's good "
                                          @"until %@", day(stated_expiry(t))]);
    return nil;
}

// The sign-in screen, to present (full screen) over the start screen or Settings; `done` gets whether a token
// was kept once it's gone (NO for Cancel).
UIViewController *sp_apple_signin(void (^done)(BOOL signedIn)) {
    NSString *appid = sp_app_id();
    NSRange dot = [appid rangeOfString:@"."];
    NSString *team = dot.location == NSNotFound ? nil : [appid substringToIndex:dot.location];
    __block __weak UIViewController *weak = nil;
    __block BOOL kept = NO;
    // Every step's reply, on the main thread: the screen's next step.
    void (^handle)(NSDictionary *) = ^(NSDictionary *reply) {
        UIViewController *screen = weak;
        if (!reply) {
            signin_say(@"spapple's reply didn't parse");
            if (screen) sp_apple_screen_show(screen, @{@"step": @"form", @"status": @"The sign-in didn’t work. Try again."});
            return;
        }
        if (![reply[@"ok"] boolValue]) {
            id code = reply[@"code"];
            signin_say([NSString stringWithFormat:@"failed: %@%@", reply[@"error"] ?: @"no reason given",
                        [code isKindOfClass:NSNumber.class] ? [NSString stringWithFormat:@" (code %@)", code] : @""]);
            if (screen) sp_apple_screen_show(screen, @{@"step": @"form", @"status": signin_problem(reply)});
            return;
        }
        if ([reply[@"step"] isEqual:@"code"]) {
            signin_say([NSString stringWithFormat:@"Apple asks for a code%@%@", [reply[@"sms"] boolValue] ? @" (by text)" : @" (on the Apple devices)",
                        [reply[@"retry"] boolValue] ? @", after a wrong one" : [reply[@"unknown"] boolValue] ? @", by another way" : @""]);
            if (screen) sp_apple_screen_show(screen, reply);
            return;
        }
        NSString *problem = keep(reply[@"token"]);
        kept = kept || !problem;
        if (screen) sp_apple_screen_show(screen, problem ? @{@"step": @"form", @"status": problem} : @{@"step": @"done"});
    };
    // Off the main thread (spapple blocks on the network, a step up to two minutes), then back to it.
    void (^run)(NSDictionary *) = ^(NSDictionary *request) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = call_zeroed(request);
            dispatch_async(dispatch_get_main_queue(), ^{ handle(reply); });
        });
    };
    void (^close)(void) = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ call_zeroed(@{@"op": @"login_cancel"}); });
        UIViewController *screen = weak;
        BOOL signedIn = kept;
        if (screen.presentingViewController) [screen dismissViewControllerAnimated:YES completion:^{ done(signedIn); }];
        else done(signedIn);
    };
    UIViewController *screen = sp_apple_screen(sp_device_noun(), anisette_server(),
        ^NSString *(NSString *email, NSString *password, NSString *server) {
            email = [email stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            server = [server stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            while ([server hasSuffix:@"/"]) server = [server substringToIndex:server.length - 1];
            if (!email.length || !password.length) return @"Type your Apple ID and its password.";
            NSURLComponents *url = [NSURLComponents componentsWithString:server];
            if (![url.scheme isEqual:@"https"] || !url.host.length) return @"The anisette server has to be an https:// address.";
            if (!team) {
                signin_say(@"no App ID in the embedded profile; not signing in");
                return @"Slashplayed can’t tell which team signed it, so a sign-in can’t renew it.";
            }
            signin_say([NSString stringWithFormat:@"signing in, with anisette from %@", url.host]);
            run(@{@"op": @"login", @"email": email, @"password": password, @"anisette_url": server, @"team": team});
            return nil;
        },
        ^(NSString *kind, NSInteger number, NSString *code) {
            signin_say([@"answering: " stringByAppendingString:kind]);  // the kind only: never the code
            run(@{@"op": @"login_answer", @"answer": kind, @"id": @(number), @"code": code ?: @""});
        },
        close, close);
    weak = screen;
    return screen;
}
