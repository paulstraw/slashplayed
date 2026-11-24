// LocalDevVPN, on the launcher's side. The JIT helper reaches the device's own developer services
// (RemotePairing at 10.7.0.1, port 49152 by default) through LocalDevVPN, a loopback VPN, and it has to be on at every
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
//
// A refused connect means something else: LocalDevVPN is on, and the device's own services refuse through it.
// That's cellular data: LocalDevVPN works only on Wi-Fi (LocalDevVPN's issue 31, "Apple-enforced"; on the iPhone
// with Wi-Fi off, errno 61, where LocalDevVPN off times out, errno 60). Opening LocalDevVPN again doesn't help
// there, so the screen says to join Wi-Fi or turn on Airplane Mode for now (sp_net_wait, below, says when to turn it off), and the same connects
// end the wait (the iPhone, 2026-11-14: Airplane Mode on from this screen, through within a second).
//
// A refused connect on Wi-Fi can also be the port: RemotePairing's network listener isn't always on 49152. An
// iPhone 16 on iOS 27.3 beta (24C5037i), on Wi-Fi, advertised _remotepairing._tcp at port 50022 and refused
// 49152, from the Mac too (2026-11-22). So before saying "Connect to Wi-Fi", a refused connect browses Bonjour
// for _remotepairing._tcp and tries each advertised port at 10.7.0.1 (sp_bonjour_loopbacks, sppair.m): only
// this device's own answers there. The port that connects is the one sp_vpn_endpoint gives the helper.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <unistd.h>

void sp_launch_say(NSString *s);  // launcher.m
void (^sp_launch_uikit(void))(double);  // launcher.m

static void say(NSString *s) { sp_launch_say([@"vpn: " stringByAppendingString:s]); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

NSArray<NSString *> *sp_bonjour_loopbacks(const char *type, double seconds, void (^pump)(double));  // sppair.m

// The device's RemotePairing port: 49152 until a Bonjour browse found it elsewhere (discover).
static atomic_int rp_port = 49152;

// Where the helper reaches the device's RemotePairing service through LocalDevVPN.
NSString *sp_vpn_endpoint(void) { return [NSString stringWithFormat:@"10.7.0.1:%d", atomic_load(&rp_port)]; }

// 0 when a TCP connect to `a` goes through within 3 s, else the errno.
static int connect_addr(const struct sockaddr *a, socklen_t size) {
    int fd = socket(a->sa_family, SOCK_STREAM, 0);
    if (fd < 0) return errno;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    int r = connect(fd, a, size);
    int err = r == 0 ? 0 : errno;
    if (err == EINPROGRESS) {
        struct pollfd p = {.fd = fd, .events = POLLOUT};
        socklen_t len = sizeof err;
        err = poll(&p, 1, 3000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 ? err : ETIMEDOUT;
    }
    close(fd);
    return err;
}

static int connect_errno(int port) {
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, "10.7.0.1", &a.sin_addr);
    return connect_addr((struct sockaddr *)&a, sizeof a);
}

// 0 when a TCP connect to the device's RemotePairing port goes through the VPN, else the errno. Not
// logged: the wait tries it every second.
int sp_vpn_errno(void) { return connect_errno(atomic_load(&rp_port)); }

// After a refused connect: the RemotePairing port Bonjour advertises, when it isn't the one tried. YES once
// one connects through the VPN (it's then sp_vpn_endpoint's). `wait` waits on the browse.
static BOOL discover(void (^wait)(double)) {
    NSArray<NSString *> *found = sp_bonjour_loopbacks("_remotepairing._tcp", 2, wait);
    if (!found) {
        say(@"_remotepairing._tcp: local network access refused, so only the default port is tried");
        return NO;
    }
    for (NSString *e in found) {
        int port = [e substringFromIndex:@"10.7.0.1:".length].intValue;
        if (port <= 0 || port > 65535 || port == atomic_load(&rp_port)) continue;
        int err = connect_errno(port);
        if (err) {
            say([NSString stringWithFormat:@"%@ (Bonjour): errno %d (%s)", e, err, strerror(err)]);
            continue;
        }
        say([NSString stringWithFormat:@"RemotePairing is at %@ (Bonjour), not %d", e, atomic_load(&rp_port)]);
        atomic_store(&rp_port, port);
        return YES;
    }
    say([NSString stringWithFormat:@"_remotepairing._tcp: %lu advertised, none other than %d answers through LocalDevVPN",
         (unsigned long)found.count, atomic_load(&rp_port)]);
    return NO;
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
void sp_vpn_refused(UIViewController *screen, BOOL refused);  // spvpnscreen.swift
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
    say([NSString stringWithFormat:@"%@: errno %d (%s)", sp_vpn_endpoint(), err, strerror(err)]);
    // On, but refused: maybe RemotePairing listens on another port.
    if (err == ECONNREFUSED && discover(*pump)) return nil;
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
    BOOL refused = err == ECONNREFUSED;
    sp_vpn_refused(screen, refused);
    [root presentViewController:screen animated:NO completion:nil];
    // One line: the companion follows it (ClientLauncher.Marker.vpnOff).
    say(@"waiting for LocalDevVPN");
    if (refused) say(@"refused: LocalDevVPN is on, and this needs Wi-Fi (cellular data?)");
    // The latest connect's errno, 0 once one went through.
    static atomic_int last;
    atomic_store(&last, err);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Refused again: the port is looked for again every 10 s (local network access granted since, Wi-Fi
        // joined, the service moved).
        double looked = now();
        for (int e; (e = sp_vpn_errno()); sleep(1)) {
            if (e == ECONNREFUSED && now() - looked > 10) {
                looked = now();
                if (discover(^(double s) { usleep((useconds_t)(s * 1e6)); })) break;
            }
            atomic_store(&last, e);
        }
        atomic_store(&last, 0);
    });
    double t = now();
    BOOL opened = NO;
    for (int e; (e = atomic_load(&last));) {
        // The screen follows the connects: LocalDevVPN turned off or on while it waits.
        if ((e == ECONNREFUSED) != refused) {
            refused = !refused;
            say([NSString stringWithFormat:@"%@: errno %d (%s)%@", sp_vpn_endpoint(), e, strerror(e),
                 refused ? @": LocalDevVPN is on, and this needs Wi-Fi (cellular data?)" : @""]);
            sp_vpn_refused(screen, refused);
        }
        // Once, by itself, and only when it's off: an openURL from an app that isn't active yet goes nowhere.
        if (!opened && !refused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
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

// ---- the internet, once the helper has detached (issue #129)
//
// On cellular data, getting past "Connect to Wi-Fi" takes Airplane Mode (or cellular data off) until the
// helper has prepared the client's code, and the game signs in to Battle.net seconds after: turned back on
// once the game was loading, the cellular connection wasn't always back in time, and the sign-in failed
// (BLZ51901016). So once the helper has detached (spguestlaunch.m calls this then, before any of the client's
// code runs), a TCP connect to the game's region's Battle.net host (the patch service sppatch.m asks) has to go
// through. Not at the attach: the helper still needs its tunnel then, and nothing says a tunnel survives
// Airplane Mode going off under it. Online, that's one connect and no screen. Otherwise a screen (over the
// loading screen) says to turn the network back on and waits, as long as it takes; its Start Anyway is for a
// network that reaches the game but not that host.

UIViewController *sp_net_screen(NSString *noun, void (^startAnyway)(void));  // spvpnscreen.swift
NSString *sp_device_noun(void);  // spjit.m

static void net_say(NSString *s) { sp_launch_say([@"net: " stringByAppendingString:s]); }

// nil when a TCP connect to host:443 goes through, else why not (the name's resolve, or the last address's errno).
static NSString *internet_problem(NSString *host) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *info = NULL;
    int gai = getaddrinfo(host.UTF8String, "443", &hints, &info);
    if (gai) return [NSString stringWithFormat:@"resolve: %s", gai_strerror(gai)];
    int err = EHOSTUNREACH;
    for (struct addrinfo *a = info; a && err; a = a->ai_next) err = connect_addr(a->ai_addr, a->ai_addrlen);
    freeaddrinfo(info);
    return err ? [NSString stringWithFormat:@"errno %d (%s)", err, strerror(err)] : nil;
}

void sp_net_wait(void (^pump)(double), NSString *region) {
    NSString *host = [NSString stringWithFormat:@"%@.version.battle.net", region];
    double t = now();
    // The latest try's problem: @"" until the first ends, nil once one went through. The tries stop then, or
    // once the wait is over (Start Anyway, or no screen to wait on).
    NSObject *lock = [NSObject new];
    __block NSString *problem = @"";
    __block BOOL over = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            @synchronized (lock) {
                if (over) return;
            }
            NSString *p = internet_problem(host);
            @synchronized (lock) {
                problem = p;
                if (!p) return;
            }
            sleep(1);
        }
    });
    NSString *(^latest)(void) = ^NSString * {
        @synchronized (lock) {
            return problem;
        }
    };
    void (^end)(void) = ^{
        @synchronized (lock) {
            over = YES;
        }
    };
    // The first try, without a screen: online, it's well under a second.
    // Each read of the latest is one read: the tries change it meanwhile.
    NSString *p;
    for (double until = now() + 4; (p = latest()) && !p.length && now() < until;) pump(0.05);
    if (!p) {
        net_say([NSString stringWithFormat:@"%@ answers, after %.2f s", host, now() - t]);
        return;
    }
    net_say([NSString stringWithFormat:@"%@: %@", host, p.length ? p : @"no answer within 4 s"]);
    void (^ui)(double) = sp_launch_uikit();
    UIViewController *root = ui ? sp_scene_root() : nil;
    if (!root) {
        end();
        net_say(@"offline, and no screen to wait on: the game starts anyway");
        return;
    }
    pump = ui;
    __block BOOL anyway = NO;
    UIViewController *screen = sp_net_screen(sp_device_noun(), ^{ anyway = YES; });
    [root presentViewController:screen animated:NO completion:nil];
    net_say(@"waiting for the internet");
    NSString *logged = p;
    while ((p = latest()) && !anyway) {
        // A new reason only, not every second's.
        if (p.length && ![p isEqual:logged]) net_say([NSString stringWithFormat:@"%@: %@", host, logged = p]);
        pump(0.25);
    }
    end();
    net_say(anyway ? [NSString stringWithFormat:@"Start Anyway, after %.1f s offline", now() - t]
                   : [NSString stringWithFormat:@"online again, after %.1f s", now() - t]);
    // As the LocalDevVPN screen's: gone before the next screen (the loading screen) goes up.
    __block BOOL gone = NO;
    [screen dismissViewControllerAnimated:NO completion:^{ gone = YES; }];
    for (double until = now() + 5; !gone && now() < until;) pump(0.05);
    if (!gone) net_say(@"the internet screen didn't go away");
    [root.view becomeFirstResponder];
}
