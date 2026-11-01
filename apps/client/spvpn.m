// LocalDevVPN, on the launcher's side. The JIT helper reaches the device's own developer services
// (RemotePairing at 10.7.0.1:49152) through LocalDevVPN, a loopback VPN, and it has to be on at every
// start: it doesn't turn itself back on after a restart. When it's off, the launch waits for it here
// rather than failing with "turn it on, then open Slashplayed again": opening an app that's still running
// only brings it back to the front, so that took a force quit.
//
// The screen opens localdevvpn://enable?scheme=slashplayed, once by itself and again from its button.
// LocalDevVPN (com.jkcoxson.LocalDevVPN, its LocalDevVPNApp.swift) turns its VPN on and, a second later,
// opens slashplayed:// (Info.plist's CFBundleURLTypes), which brings Slashplayed back. The URL itself
// needs no handling here: a connect through the VPN, tried every second off the main thread, is what
// ends the wait, so turning it on by hand and coming back works too. On iOS the app is suspended while
// it's in the background, and the tries pick up again when it's back.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>

void sp_launch_say(NSString *s);  // launcher.m
void (^sp_launch_uikit(void))(double);  // launcher.m

static void say(NSString *s) { sp_launch_say([@"vpn: " stringByAppendingString:s]); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

// 0 when a TCP connect to the device's RemotePairing port goes through the VPN, else the errno. Not
// logged: the wait tries it every second.
int sp_vpn_errno(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return errno;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(49152)};
    inet_pton(AF_INET, "10.7.0.1", &a.sin_addr);
    int r = connect(fd, (struct sockaddr *)&a, sizeof a);
    int err = r == 0 ? 0 : errno;
    if (err == EINPROGRESS) {
        struct pollfd p = {.fd = fd, .events = POLLOUT};
        socklen_t len = sizeof err;
        err = poll(&p, 1, 3000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 ? err : ETIMEDOUT;
    }
    close(fd);
    return err;
}

// The scene's root view controller, which the launcher's screens (this one, sppair.m's, splogin.m's) are
// presented over.
UIViewController *sp_scene_root(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        UIWindow *w = ws.keyWindow ?: ws.windows.firstObject;
        if (w.rootViewController) return w.rootViewController;
    }
    return nil;
}

// ---- the screen (spvpnscreen.swift: only the screen; its button comes back here)

UIViewController *sp_vpn_screen(NSString *noun, void (^turnOn)(void));  // spvpnscreen.swift
void sp_screen_status(UIViewController *screen, NSString *text);  // spstyle.swift

// Opens LocalDevVPN to turn it on. open's completion says whether any app took the URL, so no
// LSApplicationQueriesSchemes is needed to tell that LocalDevVPN isn't installed.
static void turn_on(UIViewController *screen) {
    sp_screen_status(screen, @"Opening LocalDevVPN…");
    NSURL *url = [NSURL URLWithString:@"localdevvpn://enable?scheme=slashplayed"];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL ok) {
        say(ok ? @"opened LocalDevVPN to turn it on" : @"couldn't open LocalDevVPN");
        sp_screen_status(screen, ok ? @"Waiting for LocalDevVPN…"
                                    : @"LocalDevVPN isn't installed. Get it (free) from the App Store, open it, and turn it on.");
    }];
}

// ---- the wait

// Returns nil once a connect through LocalDevVPN works, right away when it's on. Else it shows the screen
// and waits, as long as it takes (the person can always leave the app), with *pump then UIKit's. A
// problem, for the person, only when there's no screen to wait on.
NSString *sp_vpn_wait(void (^*pump)(double), NSString *noun) {
    int err = sp_vpn_errno();
    if (!err) return nil;
    say([NSString stringWithFormat:@"10.7.0.1:49152: errno %d (%s)", err, strerror(err)]);
    // It waits on the person: UIKit has to be up for the launch watchdog (on iOS it already is).
    void (^ui)(double) = sp_launch_uikit();
    UIViewController *root = ui ? sp_scene_root() : nil;
    if (!root) {
        return [NSString stringWithFormat:@"Slashplayed couldn't reach this %@'s developer services.\n\nOpen LocalDevVPN "
                @"and turn it on, then close Slashplayed and open it again.", noun];
    }
    *pump = ui;
    __block __weak UIViewController *weakScreen = nil;
    UIViewController *screen = sp_vpn_screen(noun, ^{ turn_on(weakScreen); });
    weakScreen = screen;
    [root presentViewController:screen animated:NO completion:nil];
    // One line: the companion follows it (ClientLauncher.Marker.vpnOff).
    say(@"waiting for LocalDevVPN");
    static atomic_bool up;
    atomic_store(&up, false);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (sp_vpn_errno()) sleep(1);
        atomic_store(&up, true);
    });
    double t = now();
    BOOL opened = NO;
    while (!atomic_load(&up)) {
        // Once, by itself: an openURL from an app that isn't active yet goes nowhere.
        if (!opened && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            opened = YES;
            turn_on(screen);
        }
        (*pump)(0.25);
    }
    say([NSString stringWithFormat:@"LocalDevVPN is on, after %.1f s", now() - t]);
    // Until it's gone, even unanimated: the root refuses a new presentation while this one is still on it,
    // and the headset's pairing screen comes right after (on the headset that left a black scene with the
    // pairing waiting behind it, 2026-10-22).
    __block BOOL gone = NO;
    [screen dismissViewControllerAnimated:NO completion:^{ gone = YES; }];
    for (double end = now() + 5; !gone && now() < end;) (*pump)(0.05);
    if (!gone) say(@"the LocalDevVPN screen didn't go away");
    // The input view (spevent.m) takes the keys back.
    [root.view becomeFirstResponder];
    return nil;
}
