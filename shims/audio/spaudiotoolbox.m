// AudioToolbox shim (#included into the generated libspAudioToolbox): the client's AudioComponent and
// AudioUnit calls, passed through to visionOS's AudioToolbox and logged. The client asks for the
// macOS HAL output unit ('ahal'); it gets RemoteIO, made to look like AUHAL:
// - CurrentDevice is accepted and ignored (RemoteIO plays to the system's route).
// - Its stream format reads as the device's (44.1 kHz interleaved float), not RemoteIO's
//   pre-initialization rate 0. The client mixes at the rate it reads there; with 0 its mixer spun for
//   ~20 ms of CPU per 10 ms callback, and the overrunning IO thread garbled the whole headset's audio.
// - A playback audio session is set up before the unit is created.
// - After an interruption (the app going to the background, e.g. the headset taken off), the session is
//   reactivated and the units the client had started are started again; nothing in the client does it.
// - The microphone is never opened (see "no microphone" below).
#include "spaudiolog.h"
#include <objc/message.h>
#include <math.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>

static void sp_audio_resume(const char *why);

// ---- no microphone. Voice chat can't work on the device: on the Mac the client runs it in a separate
// helper app it launches, and the device can't launch one. So the app has no
// NSMicrophoneUsageDescription, and without it TCC kills the process (__abort_with_payload) the moment
// anything asks for audio input: no prompt, no error. Every way the client could get there is closed:
// - AVCaptureDevice (AVFoundation, which the client links directly, unshimmed): the client imports
//   authorizationStatusForMediaType: and requestAccessForMediaType:completionHandler: with
//   AVMediaTypeAudio and AVMediaTypeVideo. sp_audio_no_microphone makes both answer "denied" (there's
//   no camera description either), so the system never asks TCC: the answer a Mac user who said no gets.
// - Input on an output unit (EnableIO on the input scope) or the voice-processing unit ('vpio', input
//   always on) is refused below with an error.
// - The HAL calls (spcoreaudio.m) answer from a fake device and touch no hardware, input or not.
// The audio session stays Playback, which has no input route.
enum { SP_AUTH_DENIED = 2 /* AVAuthorizationStatusDenied */ };

static bool sp_is_av_capture_type(id type) {
    // AVMediaTypeAudio and AVMediaTypeVideo are these strings, compared by value as AVFoundation does.
    return [type isKindOfClass:NSString.class] && ([type isEqual:@"soun"] || [type isEqual:@"vide"]);
}

// The launcher calls sp_audio_no_microphone once the client has loaded, before its entry point. Not an
// initializer: this shim doesn't link AVFoundation, so its initializer can run before AVFoundation's;
// AVFoundation then installs its own AVCaptureDevice methods over these (seen on macOS), and messaging
// the class that early crashes. By the time dlopen returns, every image the client links is initialized.
static void sp_refuse_capture(void) {
    Class cls = objc_getClass("AVCaptureDevice");  // the client links AVFoundation, so it's loaded
    if (!cls) {
        sp_stub_log("audio: no AVCaptureDevice, so no capture permission to refuse");
        return;
    }
    ((id (*)(id, SEL))objc_msgSend)(cls, sel_getUid("class"));  // +initialize first, if it swaps methods
    Method status = class_getClassMethod(cls, sel_getUid("authorizationStatusForMediaType:"));
    Method request = class_getClassMethod(cls, sel_getUid("requestAccessForMediaType:completionHandler:"));
    static long (*status_orig)(id, SEL, id);
    static void (*request_orig)(id, SEL, id, void (^)(BOOL));
    if (status) {
        status_orig = (long (*)(id, SEL, id))method_setImplementation(status, imp_implementationWithBlock(
            ^long(id self_, id type) {
                if (!sp_is_av_capture_type(type))
                    return status_orig(self_, sel_getUid("authorizationStatusForMediaType:"), type);
                SP_LOGF(10, "audio: +[AVCaptureDevice authorizationStatusForMediaType:%s] = denied (no capture)",
                        [type UTF8String]);
                return SP_AUTH_DENIED;
            }));
    }
    if (request) {
        request_orig = (void (*)(id, SEL, id, void (^)(BOOL)))method_setImplementation(request,
            imp_implementationWithBlock(^(id self_, id type, void (^done)(BOOL)) {
                if (!sp_is_av_capture_type(type)) {
                    request_orig(self_, sel_getUid("requestAccessForMediaType:completionHandler:"), type, done);
                    return;
                }
                SP_LOGF(10, "audio: +[AVCaptureDevice requestAccessForMediaType:%s] = NO (no capture)",
                        [type UTF8String]);
                // The real call answers later, on a queue of its own; a caller may rely on not being
                // called back inside its own call.
                if (done) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ done(NO); });
            }));
    }
    sp_stub_log(status && request ? "audio: capture permission refused (no microphone)"
                                  : "audio: AVCaptureDevice permission methods missing; not all refused");
}

__attribute__((visibility("default"))) void sp_audio_no_microphone(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sp_refuse_capture(); });
}

// Sets up the app's audio session, once.
static void sp_audio_session(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"AVAudioSession");  // AVFAudio, loaded with the client's AVFoundation
        id session = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_getUid("sharedInstance"));
        NSError *err = nil;
        // Playback, mixing with other apps' audio (option 1, MixWithOthers).
        BOOL ok = ((BOOL (*)(id, SEL, NSString *, NSUInteger, NSError **))objc_msgSend)(
            session, sel_getUid("setCategory:withOptions:error:"), @"AVAudioSessionCategoryPlayback", 1, &err);
        SP_LOGF(5, "AVAudioSession setCategory Playback: %d %s", ok, err.description.UTF8String ?: "");
        err = nil;
        ok = ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(session, sel_getUid("setActive:error:"), YES, &err);
        SP_LOGF(5, "AVAudioSession setActive: %d %s", ok, err.description.UTF8String ?: "");
        double rate = ((double (*)(id, SEL))objc_msgSend)(session, sel_getUid("sampleRate"));
        double buffer = ((double (*)(id, SEL))objc_msgSend)(session, sel_getUid("IOBufferDuration"));
        long channels = ((long (*)(id, SEL))objc_msgSend)(session, sel_getUid("outputNumberOfChannels"));
        SP_LOGF(5, "AVAudioSession: %.0f Hz, IO buffer %.4f s, %ld output channels", rate, buffer, channels);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:@"AVAudioSessionInterruptionNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            long type = [note.userInfo[@"AVAudioSessionInterruptionTypeKey"] longValue];  // 1 began, 0 ended
            sp_stub_log(type ? "audio: session interrupted" : "audio: session interruption ended");
            if (!type) sp_audio_resume("interruption ended");
        }];
        [nc addObserverForName:@"AVAudioSessionMediaServicesWereResetNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *note) { sp_stub_log("audio: media services were reset"); }];
        // An interruption doesn't always report its end; becoming active again is the other cue.
        [nc addObserverForName:@"UIApplicationDidBecomeActiveNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *note) { sp_audio_resume("app became active"); }];
    });
}

#define SP_AT "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox"
#define SP_REAL(type, name) static type real; if (!real) real = (type)sp_real(SP_AT, #name)

typedef struct { uint32_t type, subType, manufacturer, flags, flagsMask; } SPComponentDesc;
typedef SPStatus (*SPRenderProc)(void *, uint32_t *, const void *, uint32_t, uint32_t, void *);
typedef struct { SPRenderProc proc; void *refCon; } SPRenderCallback;

typedef void *(*SPFindNext)(void *, const SPComponentDesc *);
typedef SPStatus (*SPInstNew)(void *, void **);
typedef SPStatus (*SPUnitFn)(void *);
typedef SPStatus (*SPUnitGet)(void *, uint32_t, uint32_t, uint32_t, void *, uint32_t *);
typedef SPStatus (*SPUnitSet)(void *, uint32_t, uint32_t, uint32_t, const void *, uint32_t);
typedef SPStatus (*SPUnitRender)(void *, uint32_t *, const void *, uint32_t, uint32_t, void *);

// Units made from a component found as RemoteIO in place of a macOS output unit.
static void *sp_rio_component;
enum { SP_MAX_RIO_UNITS = 8 };
static void *_Atomic sp_rio_units[SP_MAX_RIO_UNITS];
static atomic_bool sp_rio_started[SP_MAX_RIO_UNITS];  // the client started it and hasn't stopped it
static atomic_uint sp_rio_device = 0;  // what the client last set as CurrentDevice

static bool sp_is_rio_unit(void *unit) {
    for (int i = 0; i < SP_MAX_RIO_UNITS; i++)
        if (unit && sp_rio_units[i] == unit) return true;
    return false;
}

void *sp_AudioComponentFindNext(void *after, const SPComponentDesc *d) __asm__("_AudioComponentFindNext");
void *sp_AudioComponentFindNext(void *after, const SPComponentDesc *d) {
    SP_REAL(SPFindNext, AudioComponentFindNext);
    // The voice-processing unit records as soon as it starts (see "no microphone"): not found.
    bool vpio = d && d->type == 'auou' && d->subType == 'vpio';
    void *c = real && !vpio ? real(after, d) : NULL;
    const char *how = vpio ? " (refused: no microphone)" : "";
    // macOS's output units (HAL, default, system) don't exist on visionOS; RemoteIO is the equivalent.
    if (!c && real && d && d->type == 'auou' &&
        (d->subType == 'ahal' || d->subType == 'def ' || d->subType == 'sys ')) {
        SPComponentDesc rio = *d;
        rio.subType = 'rioc';
        c = real(after, &rio);
        if (c) sp_rio_component = c;
        how = " (as 'rioc')";
    }
    char a[12], b[12], m[12];
    SP_LOGF(50, "AudioComponentFindNext(%p, %s %s %s) = %p%s", after, d ? sp_fourcc(d->type, a) : "-",
            d ? sp_fourcc(d->subType, b) : "-", d ? sp_fourcc(d->manufacturer, m) : "-", c, how);
    return c;
}

SPStatus sp_AudioComponentInstanceNew(void *comp, void **out) __asm__("_AudioComponentInstanceNew");
SPStatus sp_AudioComponentInstanceNew(void *comp, void **out) {
    SP_REAL(SPInstNew, AudioComponentInstanceNew);
    SPStatus st = real ? real(comp, out) : -1;
    if (st == 0 && out && comp && comp == sp_rio_component) {
        sp_audio_session();
        for (int i = 0; i < SP_MAX_RIO_UNITS; i++) {
            void *expected = NULL;
            if (atomic_compare_exchange_strong(&sp_rio_units[i], &expected, *out)) break;
        }
    }
    SP_LOGF(50, "AudioComponentInstanceNew(%p) = %d, unit %p", comp, st, out ? *out : NULL);
    return st;
}

#define SP_UNIT_FN(name, limit) \
SPStatus sp_##name(void *unit) __asm__("_" #name); \
SPStatus sp_##name(void *unit) { \
    SP_REAL(SPUnitFn, name); \
    SPStatus st = real ? real(unit) : -1; \
    SP_LOGF(limit, #name "(%p) = %d", unit, st); \
    return st; \
}
SP_UNIT_FN(AudioUnitInitialize, 50)
SP_UNIT_FN(AudioUnitUninitialize, 50)

static void sp_rio_set_started(void *unit, bool started) {
    for (int i = 0; unit && i < SP_MAX_RIO_UNITS; i++)
        if (sp_rio_units[i] == unit) sp_rio_started[i] = started;
}

SPStatus sp_AudioOutputUnitStart(void *unit) __asm__("_AudioOutputUnitStart");
SPStatus sp_AudioOutputUnitStart(void *unit) {
    SP_REAL(SPUnitFn, AudioOutputUnitStart);
    SPStatus st = real ? real(unit) : -1;
    if (st == 0) sp_rio_set_started(unit, true);
    SP_LOGF(50, "AudioOutputUnitStart(%p) = %d", unit, st);
    return st;
}

SPStatus sp_AudioOutputUnitStop(void *unit) __asm__("_AudioOutputUnitStop");
SPStatus sp_AudioOutputUnitStop(void *unit) {
    SP_REAL(SPUnitFn, AudioOutputUnitStop);
    SPStatus st = real ? real(unit) : -1;
    sp_rio_set_started(unit, false);
    SP_LOGF(50, "AudioOutputUnitStop(%p) = %d", unit, st);
    return st;
}

// Reactivates the session and starts again the units the client had running (starting a running
// unit does nothing).
static void sp_audio_resume(const char *why) {
    SP_REAL(SPUnitFn, AudioOutputUnitStart);
    id session = ((id (*)(Class, SEL))objc_msgSend)(NSClassFromString(@"AVAudioSession"), sel_getUid("sharedInstance"));
    NSError *err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(session, sel_getUid("setActive:error:"), YES, &err);
    NSMutableString *msg = [NSMutableString stringWithFormat:@"audio: resume (%s): setActive %d%s%@", why, ok,
                            err ? " " : "", err ? err.localizedDescription : @""];
    for (int i = 0; i < SP_MAX_RIO_UNITS; i++) {
        void *unit = sp_rio_units[i];
        if (unit && sp_rio_started[i] && real) [msg appendFormat:@", start %p = %d", unit, real(unit)];
    }
    sp_stub_log(msg.UTF8String);
}

SPStatus sp_AudioComponentInstanceDispose(void *unit) __asm__("_AudioComponentInstanceDispose");
SPStatus sp_AudioComponentInstanceDispose(void *unit) {
    SP_REAL(SPUnitFn, AudioComponentInstanceDispose);
    for (int i = 0; unit && i < SP_MAX_RIO_UNITS; i++) {
        void *expected = unit;
        if (atomic_compare_exchange_strong(&sp_rio_units[i], &expected, NULL)) sp_rio_started[i] = false;
    }
    SPStatus st = real ? real(unit) : -1;
    SP_LOGF(50, "AudioComponentInstanceDispose(%p) = %d", unit, st);
    return st;
}

SPStatus sp_AudioUnitGetProperty(void *unit, uint32_t prop, uint32_t scope, uint32_t elem, void *out, uint32_t *size) __asm__("_AudioUnitGetProperty");
SPStatus sp_AudioUnitGetProperty(void *unit, uint32_t prop, uint32_t scope, uint32_t elem, void *out, uint32_t *size) {
    SP_REAL(SPUnitGet, AudioUnitGetProperty);
    SPStatus st;
    const char *how = "";
    if (prop == 2000 /* kAudioOutputUnitProperty_CurrentDevice */ && sp_is_rio_unit(unit) && out && size &&
        *size >= 4) {
        *(uint32_t *)out = sp_rio_device;
        *size = 4;
        st = 0;
        how = " (RemoteIO: last set)";
    } else if (prop == 8 /* kAudioUnitProperty_StreamFormat */ && sp_is_rio_unit(unit) && out && size && *size >= 40) {
        // RemoteIO reports rate 0 and non-interleaved float before initialization; AUHAL reports the
        // device's format, and the client mixes at that rate (see the top of the file).
        st = real ? real(unit, prop, scope, elem, out, size) : -1;
        if (st == 0 && *(double *)out == 0) {
            double rate = SP_CLIENT_RATE;
            uint32_t asbd[10] = {0, 0, 'lpcm', 1 | 8 /* float, packed */, 8, 1, 8, 2, 32, 0};
            memcpy(asbd, &rate, sizeof rate);
            memcpy(out, asbd, sizeof asbd);
            *size = sizeof asbd;
            how = " (RemoteIO: AUHAL-style format)";
        }
    } else {
        st = real ? real(unit, prop, scope, elem, out, size) : -1;
    }
    char hex[64];
    SP_LOGF(200, "AudioUnitGetProperty(%p, prop %u, scope %u, elem %u) = %d%s, size %u: %s", unit, prop, scope,
            elem, st, how, size ? *size : 0, st ? "" : sp_hex(out, size ? *size : 0, hex));
    return st;
}

// ---- the client's render callbacks, wrapped to log the output's health every ~30 s (callback rate,
// CPU time, peak level), and, from a watcher thread, the audio thread's stack (frame-pointer walk,
// image + offset per frame) whenever a callback runs past 12 ms. A 10 ms callback normally takes ~0.06 ms.

static _Atomic thread_act_t sp_audio_thread;
static _Atomic uint64_t sp_callback_entered;  // mach time, 0 when not in a callback

static void sp_log_audio_stack(double ms) {
    thread_act_t thread = sp_audio_thread;
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    uintptr_t pcs[48];
    int n = 0;
    if (thread_suspend(thread) != KERN_SUCCESS) return;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        pcs[n++] = (uintptr_t)arm_thread_state64_get_pc(st);
        pcs[n++] = (uintptr_t)arm_thread_state64_get_lr(st);
        uintptr_t *fp = (uintptr_t *)arm_thread_state64_get_fp(st);
        for (; fp && n < 48 && !((uintptr_t)fp & 7); fp = (uintptr_t *)fp[0]) {
            vm_size_t got;
            uintptr_t frame[2];
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof frame, (vm_address_t)frame, &got))
                break;
            if (!frame[1]) break;
            pcs[n++] = frame[1];
            if (frame[0] <= (uintptr_t)fp) break;
        }
    }
    thread_resume(thread);
    NSMutableString *msg = [NSMutableString stringWithFormat:@"render callback running %.1f ms:", ms];
    for (int i = 0; i < n; i++) {
        Dl_info info;
        if (dladdr((void *)pcs[i], &info) && info.dli_fname)
            [msg appendFormat:@"\n    %2d %s+0x%lx (%s)", i, strrchr(info.dli_fname, '/') + 1,
                              pcs[i] - (uintptr_t)info.dli_fbase, info.dli_sname ?: "?"];
        else
            [msg appendFormat:@"\n    %2d 0x%lx", i, pcs[i]];
    }
    sp_stub_log(msg.UTF8String);
}

static void *sp_callback_watch(void *arg) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t sampled = 0;
    for (int samples = 0; samples < 6;) {
        usleep(2000);
        uint64_t entered = sp_callback_entered;
        if (!entered || entered == sampled) continue;
        double ms = (mach_absolute_time() - entered) * tb.numer / tb.denom / 1e6;
        if (ms < 12) continue;
        sampled = entered;
        samples++;
        sp_log_audio_stack(ms);
    }
    return NULL;
}

enum { SP_MAX_CALLBACKS = 8 };
static SPRenderCallback sp_callbacks[SP_MAX_CALLBACKS];
static atomic_int sp_ncallbacks;

static SPStatus sp_watched_render(void *refCon, uint32_t *flags, const void *ts, uint32_t bus, uint32_t frames,
                                  void *buffers) {
    SPRenderCallback *cb = refCon;
    static long k;  // callbacks so far (one IO thread calls this)
    static uint64_t last_log, worst, cpu_ns;
    static float peak;
    static mach_timebase_info_data_t tb;
    if (k == 0) {
        mach_timebase_info(&tb);
        sp_audio_thread = mach_thread_self();
        pthread_t watcher;
        pthread_create(&watcher, NULL, sp_callback_watch, NULL);
    }
    uint64_t t0 = mach_absolute_time(), c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    sp_callback_entered = t0;
    SPStatus st = cb->proc(cb->refCon, flags, ts, bus, frames, buffers);
    sp_callback_entered = 0;
    uint64_t t1 = mach_absolute_time();
    cpu_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0;
    if (t1 - t0 > worst) worst = t1 - t0;
    const struct { uint32_t n, pad, channels, bytes; const float *data; } *list = buffers;  // float32, as set
    if (st == 0 && list && list->n && list->data)
        for (uint32_t i = 0; i < list->bytes / sizeof(float); i++) peak = fmaxf(peak, fabsf(list->data[i]));
    if (k == 0 || k % 3000 == 0) {
        SP_LOGF(100, "render callback #%ld: %u frames = %d; since last: %.1f s, %.1f ms cpu, slowest %.2f ms, peak %.3f",
                k, frames, st, last_log ? (t1 - last_log) * tb.numer / tb.denom / 1e9 : 0, cpu_ns / 1e6,
                worst * tb.numer / tb.denom / 1e6, peak);
        last_log = t1;
        worst = cpu_ns = 0;
        peak = 0;
    }
    k++;
    return st;
}

SPStatus sp_AudioUnitSetProperty(void *unit, uint32_t prop, uint32_t scope, uint32_t elem, const void *data, uint32_t size) __asm__("_AudioUnitSetProperty");
SPStatus sp_AudioUnitSetProperty(void *unit, uint32_t prop, uint32_t scope, uint32_t elem, const void *data, uint32_t size) {
    SP_REAL(SPUnitSet, AudioUnitSetProperty);
    SPRenderCallback wrapped;
    if (prop == 23 /* kAudioUnitProperty_SetRenderCallback */ && data && size >= sizeof wrapped &&
        ((const SPRenderCallback *)data)->proc) {
        int i = atomic_fetch_add(&sp_ncallbacks, 1);
        if (i < SP_MAX_CALLBACKS) {
            sp_callbacks[i] = *(const SPRenderCallback *)data;
            wrapped = (SPRenderCallback){sp_watched_render, &sp_callbacks[i]};
            data = &wrapped;
        }
    }
    SPStatus st;
    const char *how = "";
    if (prop == 2003 /* kAudioOutputUnitProperty_EnableIO */ && scope == 1 /* input */ && data && size >= 4 &&
        *(const uint32_t *)data) {
        // Turning input on is what opens the microphone (see "no microphone"); turning it off is fine.
        st = -10851;  // kAudioUnitErr_InvalidPropertyValue
        how = " (refused: no microphone)";
    } else if (prop == 2000 /* kAudioOutputUnitProperty_CurrentDevice */ && sp_is_rio_unit(unit)) {
        // RemoteIO always plays to the system's current route; there's no device to pick.
        if (data && size >= 4) sp_rio_device = *(const uint32_t *)data;
        st = 0;
        how = " (RemoteIO: ignored)";
    } else if (prop == 8 /* kAudioUnitProperty_StreamFormat */ && sp_is_rio_unit(unit) && data && size >= 40 &&
               *(const double *)data == 0) {
        // The client sets the format it read back, so this only matters if RemoteIO's rate-0 one gets through.
        uint32_t asbd[10];
        memcpy(asbd, data, sizeof asbd);
        sp_audio_session();
        double rate = SP_CLIENT_RATE;
        memcpy(asbd, &rate, sizeof rate);
        st = real ? real(unit, prop, scope, elem, asbd, sizeof asbd) : -1;
        how = " (RemoteIO: client rate)";
    } else {
        st = real ? real(unit, prop, scope, elem, data, size) : -1;
    }
    char hex[64];
    SP_LOGF(200, "AudioUnitSetProperty(%p, prop %u, scope %u, elem %u, %s) = %d%s", unit, prop, scope, elem,
            sp_hex(data, size, hex), st, how);
    return st;
}

SPStatus sp_AudioUnitRender(void *unit, uint32_t *flags, const void *ts, uint32_t bus, uint32_t frames, void *buffers) __asm__("_AudioUnitRender");
SPStatus sp_AudioUnitRender(void *unit, uint32_t *flags, const void *ts, uint32_t bus, uint32_t frames, void *buffers) {
    SP_REAL(SPUnitRender, AudioUnitRender);
    SPStatus st = real ? real(unit, flags, ts, bus, frames, buffers) : -1;
    SP_LOGF(20, "AudioUnitRender(%p, bus %u, %u frames) = %d", unit, bus, frames, st);
    return st;
}
