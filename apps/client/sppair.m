// The headset's pairing, on the launcher's side (spjit.m calls it on visionOS when there's no
// Library/sppairing.plist, or the headset stopped accepting it: the person removed Slashplayed under
// Remote Devices). The JIT helper's tunnel needs a RemotePairing record, and on visionOS the app can make
// its own, the way Xcode pairs a Vision Pro over Wi-Fi (research/jittest's p2): with Settings > General >
// Remote Devices open, visionOS advertises _remotepairing-manual-pairing._tcp, and pair-setup there makes
// the headset show a six-digit code for the person to type in.
//
// The split: the app browses Bonjour (here, so the local network prompt is the app's, and it says why),
// the helper runs pair-setup (helper/Pair.swift: idevice stays out of the launcher) and replies with the
// record. The code is needed while the helper's request is still running, and a request has no channel
// in, so the helper connects back to a listener here on 127.0.0.1 (a port and a random token in the
// request; the code goes only to a connection that sends the token first). This writes the record to
// Library/sppairing.plist (0600; its size is the only thing logged) and the launch goes on.
//
// The screen says where Remote Devices is rather than opening it: no app can. On visionOS 27 an app's
// openURL takes App-prefs: but only for apps' own pages (every root, General included, landed on
// Settings > Apps); prefs:root=General&path=… (what the system itself uses) and settings-navigation://
// are refused (tried on the headset, 2026-10-22).
//
// It all waits on a person, so it needs a scene: the 20 s launch watchdog kills an app without one. The
// screen (SwiftUI, sppairscreen.swift) is a view controller presented over the scene's root (spevent.m's input view, which takes the
// first responder and the keys; it gets them back after).
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <dns_sd.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

void sp_launch_say(NSString *s);  // launcher.m
NSDictionary *sp_jit_request(NSDictionary *req, double timeout, void (^pump)(double));  // spjit.m
UIViewController *sp_scene_root(void);  // spvpn.m

static void say(NSString *s) { sp_launch_say([@"pair: " stringByAppendingString:s]); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

// ---- the screen (sppairscreen.swift: only the screen; the code it sends is checked here)

UIViewController *sp_pair_screen(NSString *_Nullable (^send)(NSString *code), void (^renew)(void));  // sppairscreen.swift
void sp_pair_ask(UIViewController *screen, BOOL ask);
void sp_screen_status(UIViewController *screen, NSString *text);  // spstyle.swift

// ---- the code's listener: one helper connection at a time, on 127.0.0.1

@interface SPPinListener : NSObject
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSString *token;
@end

@implementation SPPinListener {
    int _fd;  // until serve: takes it
    NSCondition *_cond;
    BOOL _wanted, _closed;  // a helper connection is waiting for a code; the listener is shut
    NSString *_pin;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _cond = [NSCondition new];
    uint8_t random[16];
    arc4random_buf(random, sizeof random);
    NSMutableString *token = [NSMutableString string];
    for (size_t i = 0; i < sizeof random; i++) [token appendFormat:@"%02x", random[i]];
    _token = token;
    _fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t len = sizeof a;
    if (_fd < 0 || bind(_fd, (struct sockaddr *)&a, sizeof a) || listen(_fd, 1) ||
        getsockname(_fd, (struct sockaddr *)&a, &len)) {
        say([NSString stringWithFormat:@"code listener: errno %d (%s)", errno, strerror(errno)]);
        if (_fd >= 0) close(_fd);
        _fd = -1;
        return nil;
    }
    _port = ntohs(a.sin_port);
    int fd = _fd;
    _fd = -1;  // serve: owns it now
    [NSThread detachNewThreadWithBlock:^{ [self serve:fd]; }];
    return self;
}

// Polls rather than blocking in accept, which closing the socket from another thread doesn't reliably
// wake; the socket is closed here, once, when -close says so.
- (void)serve:(int)fd {
    for (;;) {
        [_cond lock];
        BOOL closed = _closed;
        [_cond unlock];
        if (closed) break;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, 200) <= 0) continue;
        int c = accept(fd, NULL, NULL);
        if (c < 0) continue;
        // The helper sends the token first; anything else on this port gets nothing.
        struct timeval tv = {.tv_sec = 5};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        char line[64];
        size_t n = 0;
        while (n < sizeof line - 1 && read(c, line + n, 1) == 1 && line[n] != '\n') n++;
        line[n] = 0;
        if (strcmp(line, self.token.UTF8String) != 0) {
            say(@"code listener: a connection without the token");
            close(c);
            continue;
        }
        [_cond lock];
        _pin = nil;
        _wanted = YES;
        while (!_pin && !_closed) [_cond wait];
        NSString *pin = _pin;
        _wanted = NO;
        [_cond unlock];
        if (pin) {
            const char *s = [pin stringByAppendingString:@"\n"].UTF8String;
            write(c, s, strlen(s));
        }
        close(c);
    }
    close(fd);
}

- (BOOL)wanted {
    [_cond lock];
    BOOL wanted = _wanted && !_pin;
    [_cond unlock];
    return wanted;
}

- (void)give:(NSString *)pin {
    [_cond lock];
    if (_wanted) _pin = pin;
    [_cond broadcast];
    [_cond unlock];
}

// Ends a waiting connection too: the helper's read then sees no code.
- (void)close {
    [_cond lock];
    _closed = YES;
    [_cond broadcast];
    [_cond unlock];
}
@end

// ---- the Bonjour browse for the manual pairing service, and its endpoints

@interface SPPairBrowse : NSObject
@property (atomic) BOOL denied;  // local network access was refused
@end

@implementation SPPairBrowse {
    nw_browser_t _browser;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, nw_endpoint_t> *_found;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("sp.pair.bonjour", DISPATCH_QUEUE_SERIAL);
    _found = [NSMutableDictionary dictionary];
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    _browser = nw_browser_create(
        nw_browse_descriptor_create_bonjour_service("_remotepairing-manual-pairing._tcp", NULL), params);
    nw_browser_set_queue(_browser, _queue);
    __weak SPPairBrowse *weak = self;
    nw_browser_set_browse_results_changed_handler(_browser, ^(nw_browse_result_t old, nw_browse_result_t new, bool done) {
        SPPairBrowse *me = weak;
        if (!me) return;
        nw_browse_result_change_t change = nw_browse_result_get_changes(old, new);
        @synchronized (me) {
            if (change & nw_browse_result_change_result_removed) {
                nw_endpoint_t e = nw_browse_result_copy_endpoint(old);
                [me->_found removeObjectForKey:@(nw_endpoint_get_bonjour_service_name(e) ?: "")];
            }
            if (change & nw_browse_result_change_result_added) {
                nw_endpoint_t e = nw_browse_result_copy_endpoint(new);
                me->_found[@(nw_endpoint_get_bonjour_service_name(e) ?: "")] = e;
            }
        }
    });
    nw_browser_set_state_changed_handler(_browser, ^(nw_browser_state_t state, nw_error_t error) {
        SPPairBrowse *me = weak;
        if (!me) return;
        if (error && nw_error_get_error_domain(error) == nw_error_domain_dns &&
            nw_error_get_error_code(error) == kDNSServiceErr_PolicyDenied) {
            if (!me.denied) say(@"bonjour: local network access refused");
            me.denied = YES;
        } else if (state == nw_browser_state_ready) {
            me.denied = NO;
        } else if (state == nw_browser_state_failed) {
            say([NSString stringWithFormat:@"bonjour browse failed: %d", error ? nw_error_get_error_code(error) : 0]);
        }
    });
    nw_browser_start(_browser);
    return self;
}

- (void)dealloc {
    nw_browser_cancel(_browser);
}

- (BOOL)anything {
    @synchronized (self) {
        return _found.count > 0;
    }
}

// Each service found, resolved by connecting (TCP, nothing sent): the path names its address and port.
// 10.7.0.1 at that port first (the loopback VPN, which is what worked in p2), then the address itself.
- (NSArray<NSString *> *)endpoints:(void (^)(double))pump {
    NSArray<nw_endpoint_t> *services;
    @synchronized (self) {
        services = _found.allValues;
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (nw_endpoint_t service in services) {
        nw_connection_t c = nw_connection_create(service,
            nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION));
        nw_connection_set_queue(c, _queue);
        __block _Atomic int state = 0;  // 1 ready, 2 failed
        nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t s, nw_error_t e) {
            if (s == nw_connection_state_ready) state = 1;
            else if (s == nw_connection_state_failed || s == nw_connection_state_cancelled) state = state ?: 2;
        });
        nw_connection_start(c);
        for (double end = now() + 2; !state && now() < end;) pump(0.05);
        nw_path_t path = state == 1 ? nw_connection_copy_current_path(c) : nil;
        nw_endpoint_t remote = path ? nw_path_copy_effective_remote_endpoint(path) : nil;
        nw_connection_cancel(c);
        if (!remote || nw_endpoint_get_type(remote) != nw_endpoint_type_address) {
            say([NSString stringWithFormat:@"bonjour: %s didn't resolve", nw_endpoint_get_bonjour_service_name(service)]);
            continue;
        }
        uint16_t port = nw_endpoint_get_port(remote);
        char *address = nw_endpoint_copy_address_string(remote);
        NSString *a = address ? @(address) : nil;
        free(address);
        say([NSString stringWithFormat:@"bonjour: %s at %@ port %u", nw_endpoint_get_bonjour_service_name(service), a, port]);
        NSString *loopback = [NSString stringWithFormat:@"10.7.0.1:%u", port];
        if (![out containsObject:loopback]) [out addObject:loopback];
        if (a) {
            NSString *direct = [a containsString:@":"] ? [NSString stringWithFormat:@"[%@]:%u", a, port]
                                                       : [NSString stringWithFormat:@"%@:%u", a, port];
            if (![out containsObject:direct]) [out addObject:direct];
        }
    }
    return out;
}
@end

// ---- the flow

// Written to a new 0600 file and renamed over the old, so a half-written record is never read.
static BOOL write_record(NSData *record, NSString *path) {
    NSString *tmp = [path stringByAppendingString:@".new"];
    int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return NO;
    BOOL ok = write(fd, record.bytes, record.length) == (ssize_t)record.length;
    ok = close(fd) == 0 && ok;
    if (ok) ok = rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(tmp.fileSystemRepresentation);
    return ok;
}

// Pairs, showing the screen until it has (the person can always leave the app), and returns the record,
// already at `path`. nil only when the pairing can't happen at all; `*problem` then says why.
NSData *sp_pair_headset(NSString *path, void (^pump)(double), NSString **problem) {
    UIViewController *root = sp_scene_root();
    if (!root) {
        *problem = @"Slashplayed needs to pair with this Vision Pro, but has no window to ask in.";
        return nil;
    }
    // What the screen sends: the code once it's six digits (else what to say), and a request for a new one.
    __block NSString *entered = nil;
    __block BOOL renew = NO;
    UIViewController *ui = sp_pair_screen(^NSString *(NSString *code) {
        code = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (code.length != 6 || [code rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location
                                    != NSNotFound) {
            return @"The code is the six digits Remote Devices shows.";
        }
        entered = code;
        return nil;
    }, ^{ renew = YES; });
    // UIKit refuses a presentation while the root still presents another (the LocalDevVPN screen,
    // dismissing), and says so only in the system log: the screen is checked, so it can't be missing silently.
    __block BOOL shown = NO;
    [root presentViewController:ui animated:NO completion:^{ shown = YES; }];
    for (double end = now() + 5; !shown && now() < end;) pump(0.05);
    if (!shown || !ui.presentingViewController) {
        say([NSString stringWithFormat:@"the pairing screen didn't show (the root presents %@)", root.presentedViewController]);
        *problem = @"Slashplayed couldn't show its pairing screen.\n\nClose Slashplayed and open it again.";
        [ui dismissViewControllerAnimated:NO completion:nil];
        return nil;
    }
    say(@"showing the pairing screen");
    SPPairBrowse *browse = [SPPairBrowse new];
    NSString *last = nil;  // why the last try failed, for the person
    NSData *record = nil;
    while (!record) {
        // Settings > General > Remote Devices open is what makes the service appear.
        double t = now();
        sp_screen_status(ui, last ?: @"Looking for Remote Devices…");
        while (![browse anything]) {
            if (browse.denied) {
                sp_screen_status(ui, @"Slashplayed needs local network access to find Remote Devices. Turn it on in "
                                     @"Settings > Apps > Slashplayed, then open Slashplayed again.");
            }
            pump(0.1);
        }
        say([NSString stringWithFormat:@"the manual pairing service appeared after %.1f s", now() - t]);
        NSArray<NSString *> *endpoints = [browse endpoints:pump];
        if (!endpoints.count) {
            pump(1);
            continue;
        }
        sp_screen_status(ui, last ? [last stringByAppendingString:@"\n\nWaiting for a new code…"]
                                 : @"Found Remote Devices. Waiting for its code…");
        SPPinListener *listener = [SPPinListener new];
        if (!listener) {
            *problem = @"Slashplayed couldn't start pairing (no code listener).";
            break;
        }
        entered = nil;
        renew = NO;
        __block BOOL asking = NO, renewed = NO;
        void (^watch)(double) = ^(double seconds) {
            pump(seconds);
            BOOL wanted = [listener wanted];
            if (wanted && !asking) {
                sp_screen_status(ui, @"Type the code Remote Devices shows.");
                sp_pair_ask(ui, YES);
            }
            asking = wanted;
            if (wanted && entered) {
                [listener give:entered];
                entered = nil;
            }
            // Closing the listener ends the helper's wait with no code, so this pair-setup fails.
            if (renew && !renewed) {
                say(@"the person asked for a new code");
                renewed = YES;
                [listener close];
            }
        };
        // The helper waits up to 10 minutes for the code; this waits a little longer for its reply.
        NSDictionary *reply = sp_jit_request(@{@"op": @"pair", @"endpoints": endpoints, @"pinPort": @(listener.port),
                                               @"pinToken": listener.token}, 660, watch);
        [listener close];
        sp_pair_ask(ui, NO);
        if (!reply) {
            *problem = @"Slashplayed's helper didn't start.\n\nInstall Slashplayed again from Slashplayed Companion on your Mac.";
            break;
        }
        say([NSString stringWithFormat:@"reply: %@%@", [reply[@"ok"] boolValue] ? @"" : @"FAIL: ", reply[@"summary"]]);
        NSData *data = reply[@"pairing"];
        if (![reply[@"ok"] boolValue] || ![data isKindOfClass:NSData.class]) {
            last = renewed ? nil : [NSString stringWithFormat:@"That didn't work (%@). Check the code and try again: Remote Devices "
                    @"shows a new one.", reply[@"summary"] ?: @"no reason given"];
            pump(1);
            continue;
        }
        if (!write_record(data, path)) {
            *problem = [NSString stringWithFormat:@"Slashplayed paired, but couldn't save the pairing: errno %d (%s).",
                        errno, strerror(errno)];
            break;
        }
        say([NSString stringWithFormat:@"wrote Library/sppairing.plist (%lu bytes)", (unsigned long)data.length]);
        record = data;
    }
    if (record) {
        sp_screen_status(ui, @"Paired. You can close Remote Devices.");
        pump(1.5);
    }
    // Also on failure: the launcher's error screen is drawn on the root view, under this one.
    [ui dismissViewControllerAnimated:NO completion:nil];
    // The input view takes the keys back from the code field.
    [root.view becomeFirstResponder];
    return record;
}
