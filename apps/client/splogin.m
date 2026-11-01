// Signing the game in with no Battle.net. The unmodified client signs in by itself when its folder holds
// a login.txt (the approach of an Android launcher for another WoW client; docs/research.md): it fills its
// own logon form from it, and an authenticator's code is asked for in the game. So the launcher asks for
// the Battle.net email and password once, on a screen of its own, keeps them in the keychain (this device
// only, never synced), and writes the file just before the client loads. The libSystem shim deletes it
// as soon as the client closes it, or when the client exits if it never got that far
// (shims/system/spsystem.c), and anything left over (a launch killed before either) goes at the next start.
//
// The file overrides the Battle.net launcher token the companion relays: while it exists, even empty,
// the client takes that path. A token arrives only when the person chose Play with My Mac's Battle.net on
// the Mac (the way in when this sign-in stops working), so a launch with a fresh one writes no file and
// shows no screen; the saved sign-in stays for the next launch.
//
// Never logged: the email, the password, the file's contents or its size. The screen itself is SwiftUI
// (spsignin.swift), which hands what's typed straight to the blocks here. The start screen's Settings sheet
// (spsettings.swift) asks here whether one is saved, shows its email when asked to (Show Email: the only place it's
// ever shown), forgets it at the tap, and opens this screen to save one before any game starts.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void sp_launch_say(NSString *s);  // launcher.m
void (^sp_launch_uikit(void))(double);  // launcher.m
UIViewController *sp_scene_root(void);  // spvpn.m
NSString *sp_device_noun(void);  // spjit.m

static void say(NSString *s) { sp_launch_say([@"login: " stringByAppendingString:s]); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

static NSString *login_path(NSString *flavor) {
    return [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/_%@_/login.txt", flavor]];
}

// Zeroed before it's unlinked, as the Android launcher does: best effort, since flash storage may keep
// the old blocks. The shim's copy of this is what normally runs.
static BOOL scrub(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > 0 && st.st_size < (1 << 16)) {
            char zeros[1024] = {0};
            for (off_t left = st.st_size; left > 0; left -= sizeof zeros)
                write(fd, zeros, left < (off_t)sizeof zeros ? (size_t)left : sizeof zeros);
            fsync(fd);
        }
        close(fd);
    }
    return unlink(path.fileSystemRepresentation) == 0 || errno == ENOENT;
}

// A login.txt still there from an earlier launch: the shim deletes it at the client's close of it or at
// its exit, so one left means that launch was killed (a signal, or the system ending it) before either, or
// it was put there by hand. Every game's, not only the one starting: a launch of another game leaves its
// own, which would otherwise sit there, the sign-in in it, until that game ran again. And the one starting
// would override this launch's choice.
void sp_login_clear(NSArray<NSString *> *flavors) {
    for (NSString *flavor in flavors) {
        NSString *path = login_path(flavor);
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        say(scrub(path) ? [NSString stringWithFormat:@"deleted a leftover login.txt (%@)", flavor]
                        : [NSString stringWithFormat:@"couldn't delete a leftover login.txt (%@): errno %d", flavor, errno]);
    }
}

// ---- the keychain: one generic password, the email as its account

static NSString *const service = @"Slashplayed Battle.net sign-in";

// The saved email and password, or nil (and the OSStatus, errSecItemNotFound when there's none).
static NSArray<NSString *> *load(OSStatus *status) {
    CFTypeRef out = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecReturnAttributes: @YES, (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    }, &out);
    NSDictionary *item = CFBridgingRelease(out);
    if (*status != errSecSuccess) return nil;
    NSString *email = item[(__bridge id)kSecAttrAccount];
    NSData *data = item[(__bridge id)kSecValueData];
    NSString *password = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!email.length || !password.length) return nil;
    return @[email, password];
}

static OSStatus forget(void) {
    return SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                      (__bridge id)kSecAttrService: service});
}

// Readable only while the device is unlocked, and never leaves it (no iCloud Keychain, no backup restore
// to another device).
static OSStatus save(NSString *email, NSString *password) {
    forget();
    return SecItemAdd((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: email, (__bridge id)kSecValueData: [password dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        (__bridge id)kSecAttrSynchronizable: @NO,
    }, NULL);
}

// ---- the screen (spsignin.swift: only the screen, which hands what's typed to `entered` here)

UIViewController *sp_signin_screen(NSString *noun, NSString *_Nullable (^entered)(NSString *email, NSString *password),
                                   void (^_Nullable cancel)(void));  // spsignin.swift

// What's wrong with what was typed, or nil, with the email trimmed. The file is one line each, so neither
// may hold a line break.
static NSString *check(NSString **email, NSString *password) {
    *email = [*email stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!(*email).length || !password.length) return @"Type your Battle.net email and password.";
    if ([password rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        return @"The password can't contain a line break.";
    return nil;
}

// Shows the screen until the person signs in. NO when there's no screen to show it on.
static BOOL ask(NSArray<NSString *> **entered, void (^*pump)(double)) {
    // It waits on the person: UIKit has to be up for the launch watchdog (on iOS it already is).
    void (^ui)(double) = sp_launch_uikit();
    UIViewController *root = ui ? sp_scene_root() : nil;
    if (!root) return NO;
    *pump = ui;
    __block NSArray<NSString *> *sent = nil;
    UIViewController *screen = sp_signin_screen(sp_device_noun(), ^NSString *(NSString *email, NSString *password) {
        NSString *problem = check(&email, password);
        if (!problem) sent = @[email, password];
        return problem;
    }, nil);
    screen.modalPresentationStyle = UIModalPresentationFullScreen;
    // Checked, as sppair.m's: UIKit refuses a presentation while the root still presents another.
    __block BOOL shown = NO;
    [root presentViewController:screen animated:NO completion:^{ shown = YES; }];
    for (double end = now() + 5; !shown && now() < end;) (*pump)(0.05);
    if (!shown || !screen.presentingViewController) {
        say([NSString stringWithFormat:@"the sign-in screen didn't show (the root presents %@)", root.presentedViewController]);
        return NO;
    }
    say(@"showing the sign-in screen");
    while (!sent) (*pump)(0.1);
    *entered = sent;
    // Until it's gone: the LocalDevVPN and pairing screens may be presented next (spjit.m).
    __block BOOL gone = NO;
    [screen dismissViewControllerAnimated:NO completion:^{ gone = YES; }];
    for (double end = now() + 5; !gone && now() < end;) (*pump)(0.05);
    // The input view (spevent.m) takes the keys back.
    [root.view becomeFirstResponder];
    return YES;
}

// Before the helper attaches: decides how this launch signs in. Returns login.txt's bytes, for
// sp_login_write once the client is about to load, or nil for the token (`token`: the companion relayed
// one for this launch) or the game's own login screen. *problem is set only when the launch can't go on.
NSMutableData *sp_login_prepare(BOOL token, void (^*pump)(double), NSString **problem) {
    if (token) {
        say(@"using the Mac's Battle.net (a relayed token), not the saved sign-in");
        return nil;
    }
    OSStatus status;
    NSArray<NSString *> *login = load(&status);
    if (login) {
        say(@"using the saved sign-in");
    } else if (status == errSecInteractionNotAllowed) {
        // Locked (a launch from the Mac with the device asleep): the saved sign-in is there but unreadable,
        // and asking for it again would make the person retype it.
        say(@"the saved sign-in can't be read while the device is locked");
        *problem = [NSString stringWithFormat:@"Unlock this %@, then open Slashplayed again.", sp_device_noun()];
        return nil;
    } else {
        if (status != errSecItemNotFound) say([NSString stringWithFormat:@"no saved sign-in: keychain %d", (int)status]);
        if (!ask(&login, pump)) {
            say(@"no screen to ask on: the game's own login screen");
            return nil;
        }
        status = save(login[0], login[1]);
        say(status == errSecSuccess ? @"saved the sign-in" : [NSString stringWithFormat:@"couldn't save the sign-in: keychain %d", (int)status]);
    }
    return [[[NSString stringWithFormat:@"%@\n%@\n", login[0], login[1]] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
}

// Writes login.txt (0600, a new file), then zeroes `bytes`. Just before the client loads, so a launch that
// stops earlier (no helper) leaves nothing behind.
BOOL sp_login_write(NSString *flavor, NSMutableData *bytes) {
    NSString *path = login_path(flavor);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    BOOL ok = fd >= 0 && write(fd, bytes.bytes, bytes.length) == (ssize_t)bytes.length;
    int err = errno;
    if (fd >= 0) ok = close(fd) == 0 && ok;
    memset_s(bytes.mutableBytes, bytes.length, 0, bytes.length);
    if (!ok) {
        say([NSString stringWithFormat:@"couldn't write login.txt: errno %d (%s)", err, strerror(err)]);
        if (fd >= 0) scrub(path);
        return NO;
    }
    say(@"wrote login.txt");
    return YES;
}

// ---- the Settings sheet's (spstart.m)

// Whether a sign-in is saved. Asks for neither value: only whether the item is there.
BOOL sp_login_saved(void) {
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    }, NULL);
    // Locked, it's there but can't be read; the sheet shows only while the device is in use anyway.
    return status == errSecSuccess || status == errSecInteractionNotAllowed;
}

// The saved email, for Show Email, or nil. Only the account attribute is asked for (never the password), and
// nothing here logs it: the sheet shows it and drops it when it hides.
NSString *sp_login_email(void) {
    CFTypeRef out = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecReturnAttributes: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    }, &out);
    NSDictionary *item = CFBridgingRelease(out);
    if (status != errSecSuccess) return nil;
    NSString *email = item[(__bridge id)kSecAttrAccount];
    return email.length ? email : nil;
}

// Forget My Sign-In, at the tap: the next game start asks again. NO if the keychain refused.
BOOL sp_login_forget(void) {
    OSStatus s = forget();
    BOOL ok = s == errSecSuccess || s == errSecItemNotFound;
    say(ok ? @"forgot the saved sign-in (Settings)" : [NSString stringWithFormat:@"couldn't forget the saved sign-in: keychain %d", (int)s]);
    return ok;
}

// Sign In…: the screen with Cancel, to present over the sheet. It saves what's sent, as a launch's does,
// then goes; `done` gets whether one was saved (NO for Cancel).
UIViewController *sp_login_screen(void (^done)(BOOL saved)) {
    __block __weak UIViewController *weakScreen = nil;
    UIViewController *screen = sp_signin_screen(sp_device_noun(), ^NSString *(NSString *email, NSString *password) {
        NSString *problem = check(&email, password);
        if (problem) return problem;
        OSStatus status = save(email, password);
        say(status == errSecSuccess ? @"saved the sign-in (Settings)" : [NSString stringWithFormat:@"couldn't save the sign-in: keychain %d", (int)status]);
        if (status != errSecSuccess) return @"The sign-in couldn't be saved. Try again.";
        [weakScreen dismissViewControllerAnimated:YES completion:^{ done(YES); }];
        return nil;
    }, ^{ [weakScreen dismissViewControllerAnimated:YES completion:^{ done(NO); }]; });
    weakScreen = screen;
    return screen;
}
