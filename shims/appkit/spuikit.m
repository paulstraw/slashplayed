// UIKit under the AppKit shim. #included at the end of the generated libspAppKit.m (gen_stubs.py
// EXTRA_INCLUDES), after the stub NSApplication class and sp_NSApp.
//
// The client runs its own main loop on the main thread, and UIKit needs the main thread too: visionOS
// SIGKILLs an app that hasn't brought up a scene about 20 s after launch. So the two share it as
// coroutines. +[NSApplication sharedApplication] starts UIApplicationMain on a stack of its own. A
// run loop observer switches back to the client each time the main run loop is about to wait, and
// the client's event pumping (nextEventMatchingMask:... in spevent.m, run) switches to UIKit for one
// run loop iteration. Each side keeps its own autorelease pool stack (objc's per-thread TSD slot is swapped).
#import <UIKit/UIKit.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <pthread.h>
#include <sys/mman.h>

// libspSystem's dladdr, which also names the frames of a client dyld didn't load (sp_set_client); the
// plain one without it.
static int sp_frame_dladdr(const void *pc, Dl_info *info) {
    static int (*f)(const void *, Dl_info *);
    if (!f) f = (int (*)(const void *, Dl_info *))dlsym(RTLD_DEFAULT, "sp_dladdr") ?: dladdr;
    return f(pc, info);
}

// ---- coroutines: callee-saved registers, sp, and the autorelease pool TSD slot

typedef struct {
    uint64_t x19_x28[10], fp, lr, sp, d8_d15[8];
    void *pool;  // objc's AUTORELEASE_POOL_KEY slot (__PTK_FRAMEWORK_OBJC_KEY3)
} sp_ctx;

// void sp_ctx_switch(sp_ctx *save, const sp_ctx *load)
__asm__(".text\n.p2align 2\n"
        "_sp_ctx_switch:\n"
        "stp x19, x20, [x0, #0]\n stp x21, x22, [x0, #16]\n stp x23, x24, [x0, #32]\n"
        "stp x25, x26, [x0, #48]\n stp x27, x28, [x0, #64]\n stp x29, x30, [x0, #80]\n"
        "mov x9, sp\n str x9, [x0, #96]\n"
        "stp d8, d9, [x0, #104]\n stp d10, d11, [x0, #120]\n stp d12, d13, [x0, #136]\n"
        "stp d14, d15, [x0, #152]\n"
        "ldp x19, x20, [x1, #0]\n ldp x21, x22, [x1, #16]\n ldp x23, x24, [x1, #32]\n"
        "ldp x25, x26, [x1, #48]\n ldp x27, x28, [x1, #64]\n ldp x29, x30, [x1, #80]\n"
        "ldr x9, [x1, #96]\n mov sp, x9\n"
        "ldp d8, d9, [x1, #104]\n ldp d10, d11, [x1, #120]\n ldp d12, d13, [x1, #136]\n"
        "ldp d14, d15, [x1, #152]\n"
        "ret\n");
void sp_ctx_switch(sp_ctx *save, const sp_ctx *load) __asm__("_sp_ctx_switch");

#define SP_POOL_TSD_SLOT 43

static void **sp_tsd(void) {
    uintptr_t p;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(p));
    return (void **)(p & ~(uintptr_t)7);
}

static sp_ctx sp_client_ctx, sp_uikit_ctx;
static BOOL sp_in_uikit;

static void sp_switch_to(BOOL uikit) {
    sp_ctx *from = uikit ? &sp_client_ctx : &sp_uikit_ctx, *to = uikit ? &sp_uikit_ctx : &sp_client_ctx;
    void **tsd = sp_tsd();
    from->pool = tsd[SP_POOL_TSD_SLOT];
    tsd[SP_POOL_TSD_SLOT] = to->pool;
    sp_in_uikit = uikit;
    sp_ctx_switch(from, to);
}

// ---- UIKit side

static UIWindow *sp_window;
static BOOL sp_scene_active;  // the scene has been active at least once (sp_uikit_early waits for it)
static UIViewController *sp_make_root_view_controller(void);  // spevent.m: its view collects input
static void sp_loading_attach(void);  // sploading.m
static void sp_window_scene_connected(void);  // spwindow.m
static void sp_scene_connect_late(void);

@interface SPSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end
@implementation SPSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    UISceneSizeRestrictions *r = ((UIWindowScene *)scene).sizeRestrictions;
    sp_stub_log([NSString stringWithFormat:@"scene connected, size limits %@ to %@",
                 NSStringFromCGSize(r.minimumSize), NSStringFromCGSize(r.maximumSize)].UTF8String);
    sp_scene_connect_late();
    sp_window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = sp_make_root_view_controller();
    vc.view.backgroundColor = UIColor.blackColor;
    sp_window.rootViewController = vc;
    [sp_window makeKeyAndVisible];
    sp_window_scene_connected();  // the client's layer, if it set one first (visionOS)
    sp_loading_attach();  // if the launcher already asked for the loading screen (visionOS)
}
// A closed window suspends the app, and the server connection often drops while suspended. The client
// then reconnects without uploading its changed settings, and the re-login downloads the server's
// older copy over them. A background task keeps the client running (and answering the server) for
// the time the system grants (~26 s), so a short close doesn't drop the connection.
static UIBackgroundTaskIdentifier sp_bg_task;
static BOOL sp_bg_task_running;
static void sp_bg_task_end(UIApplication *app, const char *why) {
    if (!sp_bg_task_running) return;
    sp_stub_log([NSString stringWithFormat:@"background task ended (%s)", why].UTF8String);
    [app endBackgroundTask:sp_bg_task];
    sp_bg_task_running = NO;
}
// The scene delegate gets these: a scene-based app's delegate isn't sent applicationDidEnterBackground:.
- (void)sceneDidEnterBackground:(UIScene *)scene {
    UIApplication *app = UIApplication.sharedApplication;
    if (sp_bg_task_running) return;
    sp_bg_task = [app beginBackgroundTaskWithName:@"sp keep connection" expirationHandler:^{
        sp_bg_task_end(app, "time's up");
    }];
    sp_bg_task_running = sp_bg_task != UIBackgroundTaskInvalid;
    // The time left isn't set yet here (DBL_MAX); the expiry is logged when it comes (~26 s seen).
    sp_stub_log(sp_bg_task_running ? "background task started" : "background task refused");
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    sp_scene_active = YES;
}
- (void)sceneWillEnterForeground:(UIScene *)scene {
    sp_bg_task_end(UIApplication.sharedApplication, "back in the foreground");
}
@end

@interface SPAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation SPAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    sp_stub_log("UIKit launched");
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:nil sessionRole:session.role];
    config.delegateClass = SPSceneDelegate.class;
    return config;
}
@end

// Back to the client whenever the main run loop is about to sleep: it has handled what was pending.
static void sp_before_waiting(CFRunLoopObserverRef obs, CFRunLoopActivity activity, void *info) {
    if (sp_in_uikit) sp_switch_to(NO);
}

// The Battle.net launcher's account timestamp in net.battle (a timestamp, never a credential), or "(none)".
static void sp_log_account_ts(void) {
    CFPropertyListRef ts = CFPreferencesCopyAppValue(CFSTR("Launch Options/WoW/ACCOUNT_TS"), CFSTR("net.battle"));
    char buf[32] = "(none)";
    if (ts && CFGetTypeID(ts) == CFStringGetTypeID()) CFStringGetCString(ts, buf, sizeof buf, kCFStringEncodingUTF8);
    fprintf(stderr, "[sp:AppKit] net.battle ACCOUNT_TS = %s\n", buf);
    if (ts) CFRelease(ts);
}

// The companion moves the Battle.net launch credentials to the device as
// <container>/Library/spnetbattle.plist (the Mac's net.battle prefs; values are never read). Copying
// it over Library/Preferences/net.battle.plist isn't reliable: cfprefsd may keep serving the domain it
// cached, i.e. stale ones. So its keys go into the domain through CFPreferences, and the file is deleted.
// The launcher calls this just before it loads the client (apps/client/launcher.m), once it has decided
// on the token, not UIKit's start: on iOS UIKit starts before that decision (and on visionOS for the
// pairing and LocalDevVPN screens), and an import there deleted the file the launcher then looked for,
// so the launch signed in with the saved sign-in instead.
__attribute__((visibility("default"))) void sp_net_battle_import(void) {
    const char *home = getenv("HOME");
    if (!home) return;
    NSString *path = [NSString stringWithFormat:@"%s/Library/spnetbattle.plist", home];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!d) {
        fprintf(stderr, "[sp:AppKit] no Library/spnetbattle.plist to import\n");
        return;
    }
    for (NSString *key in d)
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)d[key], CFSTR("net.battle"));
    Boolean ok = CFPreferencesAppSynchronize(CFSTR("net.battle"));
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    fprintf(stderr, "[sp:AppKit] imported %lu keys from Library/spnetbattle.plist into net.battle (sync %d)\n",
            (unsigned long)d.count, ok);
    sp_log_account_ts();
}

// The command line's option names, and whether the Battle.net launcher's prefs domain (net.battle in the
// app container's Library/Preferences) is visible. Battle.net's arguments can carry credential values, so
// only the "-x"/"--x" part of each option (before any "=") and the count are logged, and a timestamp:
// never a credential.
static void sp_log_launch(void) {
    char **argv = *_NSGetArgv();
    fprintf(stderr, "[sp:AppKit] %d arguments\n", *_NSGetArgc());
    for (int i = 1; i < *_NSGetArgc(); i++)
        if (argv[i][0] == '-') fprintf(stderr, "[sp:AppKit] option %.*s\n", (int)strcspn(argv[i], "="), argv[i]);
    sp_log_account_ts();
}

static void sp_uikit_main(void) {
    sp_log_launch();
    CFRunLoopObserverRef obs = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, true, 0,
                                                       sp_before_waiting, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, NSStringFromClass(SPAppDelegate.class));
    abort();  // doesn't return
}

// ---- stall reports: if the client hasn't pumped for 3 s, log the main thread's stack (frame
// pointer walk, image + offset per frame), every 3 s until it does. No debugger involved.

static _Atomic uint64_t sp_pumps;

static void *sp_stall_watch(void *arg) {
    thread_act_t main_thread = (thread_act_t)(uintptr_t)arg;
    uint64_t last = 0;
    for (;;) {
        sleep(3);
        // Before the client has an NSApp (UIKit started early, sp_uikit_early) it isn't pumping yet,
        // and may be stopped in the debugger's prepare: leave it alone.
        if (!sp_NSApp) continue;
        uint64_t now = sp_pumps;
        if (now != last) {
            last = now;
            continue;
        }
        arm_thread_state64_t st;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        uintptr_t pcs[64];
        int n = 0;
        if (thread_suspend(main_thread) != KERN_SUCCESS) continue;
        if (thread_get_state(main_thread, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
            pcs[n++] = (uintptr_t)arm_thread_state64_get_pc(st);
            pcs[n++] = (uintptr_t)arm_thread_state64_get_lr(st);
            uintptr_t *fp = (uintptr_t *)arm_thread_state64_get_fp(st);
            for (; fp && n < 64 && !((uintptr_t)fp & 7); fp = (uintptr_t *)fp[0]) {
                vm_size_t got;
                uintptr_t frame[2];
                if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof frame, (vm_address_t)frame, &got))
                    break;
                if (!frame[1]) break;
                pcs[n++] = frame[1];
                if (frame[0] <= (uintptr_t)fp) break;
            }
        }
        thread_resume(main_thread);
        NSMutableString *msg = [NSMutableString stringWithFormat:@"main thread hasn't pumped events for 3 s:"];
        for (int i = 0; i < n; i++) {
            Dl_info info;
            if (sp_frame_dladdr((void *)pcs[i], &info) && info.dli_fname)
                [msg appendFormat:@"\n    %2d %s+0x%lx (%s)", i, strrchr(info.dli_fname, '/') + 1,
                                  pcs[i] - (uintptr_t)info.dli_fbase, info.dli_sname ?: "?"];
            else
                [msg appendFormat:@"\n    %2d 0x%lx", i, pcs[i]];
        }
        sp_stub_log(msg.UTF8String);
    }
    return NULL;
}

// ---- client side

static void sp_stats_start(void);  // spstats.m

static void sp_uikit_start(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    size_t size = 8 << 20, guard = 16 << 10;
    char *stack = mmap(NULL, size + guard, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    mprotect(stack, guard, PROT_NONE);
    sp_uikit_ctx.sp = (uint64_t)(stack + size + guard);
    sp_uikit_ctx.lr = (uint64_t)sp_uikit_main;
    sp_uikit_ctx.fp = 0;  // end of the frame chain, for unwinders
    pthread_t watcher;
    pthread_create(&watcher, NULL, sp_stall_watch, (void *)(uintptr_t)mach_thread_self());
    sp_stats_start();
    sp_switch_to(YES);
}

// One run loop iteration, until the loop would sleep. With wait, it may sleep first until something
// arrives; without, it's woken so it doesn't.
static void sp_uikit_pump(BOOL wait) {
    if (sp_in_uikit) return;
    sp_pumps++;
    if (!wait) CFRunLoopWakeUp(CFRunLoopGetMain());
    sp_switch_to(YES);
}

// iOS SIGKILLs an app that hasn't shown a scene 20 s after launch (0x8badf00d, "process-launch
// watchdog"), counting the time stopped in the debugger, and the client only reaches
// +sharedApplication ~20 s in (the prepare stop alone is ~12 s). So on iOS the launcher
// (apps/client/launcher.m) calls this before it loads the client: UIKit starts and runs until
// the scene is active (or timeout seconds pass), and the client takes the main thread over later as usual.
__attribute__((visibility("default"))) void sp_uikit_early(double timeout) {
    sp_uikit_start();
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + timeout;
    while (!sp_scene_active && CFAbsoluteTimeGetCurrent() < end) {
        sp_uikit_pump(NO);
        usleep(5000);
    }
    sp_stub_log(sp_scene_active ? "early UIKit: scene active" : "early UIKit: no active scene yet");
}

// The launcher's waits on the JIT helper before the client is loaded (apps/client/spjit.m), once
// sp_uikit_early has run: UIKit keeps running meanwhile, so the scene stays responsive.
__attribute__((visibility("default"))) void sp_uikit_wait(double seconds) {
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + seconds;
    do {
        sp_uikit_pump(NO);
        usleep(5000);
    } while (CFAbsoluteTimeGetCurrent() < end);
}

// The launcher's error screen, when the JIT helper can't prepare the client (apps/client/launcher.m): the
// message, centered on the scene, until the person leaves the app. UIKit starts here if it isn't up yet
// (on visionOS the launcher doesn't start it early). Never returns: the client isn't loaded.
__attribute__((visibility("default"), noreturn)) void sp_uikit_fail(const char *message) {
    sp_uikit_early(10);
    UIView *view = sp_window.rootViewController.view;
    if (view) {
        UILabel *label = [[UILabel alloc] init];
        label.text = @(message);
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:label];
        UILayoutGuide *guide = view.readableContentGuide;
        [NSLayoutConstraint activateConstraints:@[
            [label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
            [label.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [label.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        ]];
    } else {
        sp_stub_log("no scene to show the launcher's error on");
    }
    // With wait, each pump sleeps in UIKit until something arrives.
    for (;;) sp_uikit_pump(YES);
}

@implementation NSApplication (SPUIKit)
+ (instancetype)sharedApplication {
    if (!sp_NSApp) {
        sp_NSApp = [[self alloc] init];
        sp_stub_log([NSString stringWithFormat:@"+[%s sharedApplication]: starting UIKit (unless early)",
                     class_getName(self)].UTF8String);
        sp_uikit_start();
    }
    return sp_NSApp;
}
// As AppKit: ask the delegate (applicationShouldTerminate:: NSTerminateCancel 0, Now 1, Later 2,
// then pump until replyToApplicationShouldTerminate:), then post NSApplicationWillTerminateNotification,
// which AppKit delivers to the delegate as applicationWillTerminate:, then exit(0). The client
// implements both; its shutdown work happens there, before exit runs static destructors.
static int sp_terminate_reply = -1;  // -1 while no Later reply is pending
static void sp_terminate_now(NSApplication *app, id delegate) {
    NSNotification *n = [NSNotification notificationWithName:@"NSApplicationWillTerminateNotification" object:app];
    SEL will = sel_registerName("applicationWillTerminate:");
    if ([delegate respondsToSelector:will]) {
        sp_stub_log("-[NSApplication terminate:]: applicationWillTerminate:");
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, will, n);
    }
    [NSNotificationCenter.defaultCenter postNotification:n];
    sp_stub_log("-[NSApplication terminate:] -> exit(0)");
    exit(0);
}
- (void)terminate:(id)sender {
    id d = ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate));  // spevent.m
    SEL should = sel_registerName("applicationShouldTerminate:");
    if ([d respondsToSelector:should]) {
        NSUInteger reply = ((NSUInteger (*)(id, SEL, id))objc_msgSend)(d, should, self);
        sp_stub_log([NSString stringWithFormat:@"-[NSApplication terminate:]: applicationShouldTerminate: = %lu",
                     (unsigned long)reply].UTF8String);
        if (reply == 2) {
            for (sp_terminate_reply = -1; sp_terminate_reply < 0;) @autoreleasepool { sp_uikit_pump(YES); }
            reply = sp_terminate_reply;
        }
        if (!reply) return;
    }
    sp_terminate_now(self, d);
}
- (void)replyToApplicationShouldTerminate:(BOOL)terminate {
    sp_stub_log(terminate ? "-[NSApplication replyToApplicationShouldTerminate:YES]"
                          : "-[NSApplication replyToApplicationShouldTerminate:NO]");
    if (sp_terminate_reply < 0 && terminate) {
        // Not inside a Later wait (the client cancels, shuts down on its own, then replies): finish here.
        sp_terminate_now(self, ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate)));
    }
    sp_terminate_reply = terminate ? 1 : 0;
}
- (void)run {
    sp_stub_log("-[NSApplication run] (pumps UIKit forever)");
    for (;;) {
        @autoreleasepool {
            sp_uikit_pump(YES);
        }
    }
}
@end

// ---- NSAlert: no UI yet. runModal logs the alert and answers with the first button.

static char sp_alert_message_key, sp_alert_info_key, sp_alert_buttons_key;

@implementation NSAlert (SPUIKit)
- (void)setMessageText:(NSString *)text {
    objc_setAssociatedObject(self, &sp_alert_message_key, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void)setInformativeText:(NSString *)text {
    objc_setAssociatedObject(self, &sp_alert_info_key, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (id)addButtonWithTitle:(NSString *)title {
    NSMutableArray *buttons = objc_getAssociatedObject(self, &sp_alert_buttons_key);
    if (!buttons) {
        buttons = [NSMutableArray array];
        objc_setAssociatedObject(self, &sp_alert_buttons_key, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [buttons addObject:title ?: @""];
    return nil;
}
- (NSInteger)runModal {
    sp_stub_log([NSString stringWithFormat:@"NSAlert: \"%@\" / \"%@\" buttons %@ -> first",
                 objc_getAssociatedObject(self, &sp_alert_message_key),
                 objc_getAssociatedObject(self, &sp_alert_info_key),
                 objc_getAssociatedObject(self, &sp_alert_buttons_key)].UTF8String);
    return 1000;  // NSAlertFirstButtonReturn
}
@end
