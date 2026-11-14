// Look highlights in game: the SPHover addon (addon/SPHover) draws the rects of the clickable
// UI as a pixel strip along the bottom of the screen. Each time the client presents, a blit copies
// the bottom rows of the drawable into a shared buffer; the strip is decoded (sphoverstrip.h) and
// the rects go to the hover overlay (sp_hover_set_rects in spevent.m). While a strip is showing, the
// layer's contentsRect leaves it out. #included after spevent.m.
//
// On an iPhone or iPad the strip is the SPKeyboard addon's instead (addon/SPKeyboard), the same format
// with frames of another kind: the text box with the keyboard's focus, which goes to the on-screen
// keyboard (spkeyboard.m's sp_keyboard_focus).
//
// The blit goes into the client's own command buffer, in presentDrawable:, so it sees the finished
// frame. The drawable has to be readable for that: framebufferOnly is turned off.

#import <Metal/Metal.h>
#include "sphoverstrip.h"

__asm__(".linker_option \"-framework\", \"Metal\"");

#define SPH_ROWS 3       // the strip is about this many pixels tall; any row of it will do
#define SPH_BUFFERS 3    // frames in flight

static CALayer *sp_hover_metal_layer;
static sph_assembler sp_hover_asm, sp_hover_focus_asm;
static int sp_hover_misses = 1000;  // frames since a valid strip
static BOOL sp_hover_cropped, sp_hover_testing;

// 0..7 (r << 2 | g << 1 | b) for one pixel, by thresholding each channel at half.
static uint8_t sp_hover_pixel_bits(const uint8_t *p, MTLPixelFormat format) {
    unsigned r, g, b;
    switch (format) {
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB:
        b = p[0] >= 128, g = p[1] >= 128, r = p[2] >= 128;
        break;
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
        r = p[0] >= 128, g = p[1] >= 128, b = p[2] >= 128;
        break;
    case MTLPixelFormatRGB10A2Unorm:
    case MTLPixelFormatBGR10A2Unorm: {
        uint32_t v;
        memcpy(&v, p, 4);
        unsigned lo = (v & 0x3ff) >= 512, mid = (v >> 10 & 0x3ff) >= 512, hi = (v >> 20 & 0x3ff) >= 512;
        if (format == MTLPixelFormatRGB10A2Unorm) r = lo, g = mid, b = hi;
        else b = lo, g = mid, r = hi;
        break;
    }
    case MTLPixelFormatRGBA16Float: {
        __fp16 c[3];
        memcpy(c, p, sizeof c);
        r = c[0] >= 0.5f, g = c[1] >= 0.5f, b = c[2] >= 0.5f;
        break;
    }
    default:
        return 0;
    }
    return r << 2 | g << 1 | b;
}

static BOOL sp_hover_format_ok(MTLPixelFormat format) {
    switch (format) {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm:
    case MTLPixelFormatRGBA16Float:
        return YES;
    default:
        return NO;
    }
}

static size_t sp_hover_pixel_size(MTLPixelFormat format) {
    return format == MTLPixelFormatRGBA16Float ? 8 : 4;
}

static void sp_hover_crop(BOOL crop, CGFloat height) {
    if (crop == sp_hover_cropped || !sp_hover_metal_layer) return;
    sp_hover_cropped = crop;
    Class tx = NSClassFromString(@"CATransaction");
    [tx begin];
    [tx setDisableActions:YES];
    // Unit coordinates of the drawable, origin top left (checked on device: the strip disappears).
    sp_hover_metal_layer.contentsRect = crop ? CGRectMake(0, 0, 1, 1 - (SPH_ROWS + 1) / height)
                                             : CGRectMake(0, 0, 1, 1);
    [tx commit];
}

// Main thread: one presented frame's strip rows, SPH_ROWS x SPH_BLOCKS, bottom row first.
static void sp_hover_frame(const uint8_t *rows, CGFloat height) {
    uint8_t frame[SPH_FRAME_BYTES];
    int kind = 0;
    for (int i = 0; i < SPH_ROWS && !kind; i++) kind = sph_frame_from_blocks(rows + i * SPH_BLOCKS, frame);
    if (!kind) {
        // Hidden UI, a loading screen, glue screens (no addons there): no highlights, and no box has focus.
        if (++sp_hover_misses == 30) {
            sph_reset(&sp_hover_asm);
            sph_reset(&sp_hover_focus_asm);
            if (!sp_hover_testing) sp_hover_set_rects(NULL, 0);
#if !TARGET_OS_VISION
            sp_keyboard_focus(NO, CGRectNull);
#endif
            sp_hover_crop(NO, height);
            sp_stub_log("hover: strip gone");
        }
        return;
    }
    if (sp_hover_misses >= 30) sp_stub_log("hover: strip found");
    sp_hover_misses = 0;
    sp_hover_crop(YES, height);
    static sph_rect rects[SPH_MAX_RECTS];
    int n;
#if !TARGET_OS_VISION
    if (kind == 'K') {
        if (sph_feed(&sp_hover_focus_asm, frame, rects, &n) == SPH_MESSAGE)
            sp_keyboard_focus(YES, n ? CGRectMake(rects[0].x, rects[0].y, rects[0].w, rects[0].h) : CGRectNull);
        return;
    }
#endif
    if (kind != 'W') return;
    if (sph_feed(&sp_hover_asm, frame, rects, &n) != SPH_MESSAGE || sp_hover_testing) return;
    static CGRect fractions[SPH_MAX_RECTS];
    for (int i = 0; i < n; i++) fractions[i] = CGRectMake(rects[i].x, rects[i].y, rects[i].w, rects[i].h);
    sp_hover_set_rects(fractions, n);
    static int logged;
    if (logged++ < 20) sp_stub_log([NSString stringWithFormat:@"hover: %d rects (seq %d, %d chunks)", n,
                                    sp_hover_asm.seq, sp_hover_asm.count].UTF8String);
}

// In the client's command buffer, before its present: copy the bottom rows of the drawable out, and
// when the GPU is done, sample the block centers and pass them to the main thread.
static void sp_hover_capture(id<MTLCommandBuffer> cb, id drawable) {
    if (![drawable respondsToSelector:@selector(texture)]) return;
    id<MTLTexture> tex = [drawable texture];
    if (tex.framebufferOnly) {
        // Only drawables made after this are readable.
        [sp_hover_metal_layer setValue:@NO forKey:@"framebufferOnly"];
        return;
    }
    MTLPixelFormat format = tex.pixelFormat;
    size_t bpp = sp_hover_pixel_size(format), width = tex.width, height = tex.height;
    static BOOL said;
    if (!said) {
        said = YES;
        sp_stub_log([NSString stringWithFormat:@"hover: first present, %zux%zu pixel format %lu%s", width, height,
                     (unsigned long)format, sp_hover_format_ok(format) ? "" : " (not handled)"].UTF8String);
    }
    if (!sp_hover_format_ok(format) || height < SPH_ROWS || width < SPH_BLOCKS) return;
    static id<MTLBuffer> buffers[SPH_BUFFERS];
    static size_t buffer_size;
    static unsigned next;
    size_t row = width * bpp, size = row * SPH_ROWS;
    if (size > buffer_size) {
        for (int i = 0; i < SPH_BUFFERS; i++)
            buffers[i] = [cb.device newBufferWithLength:size options:MTLResourceStorageModeShared];
        buffer_size = size;
    }
    id<MTLBuffer> buf = buffers[next++ % SPH_BUFFERS];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, height - SPH_ROWS, 0)
               sourceSize:MTLSizeMake(width, SPH_ROWS, 1) toBuffer:buf destinationOffset:0
      destinationBytesPerRow:row destinationBytesPerImage:size];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) return;
        uint8_t *rows = malloc(SPH_ROWS * SPH_BLOCKS);
        const uint8_t *px = buf.contents;
        for (int r = 0; r < SPH_ROWS; r++)  // the buffer's last row is the drawable's bottom one
            for (int i = 0; i < SPH_BLOCKS; i++)
                rows[r * SPH_BLOCKS + i] = sp_hover_pixel_bits(
                    px + (SPH_ROWS - 1 - r) * row + (size_t)((i + 0.5) * width / SPH_BLOCKS) * bpp, format);
        dispatch_async(dispatch_get_main_queue(), ^{
            sp_hover_frame(rows, height);
            free(rows);
        });
    }];
}

static void (*sp_present_orig)(id, SEL, id);
static void sp_present(id self, SEL _cmd, id drawable) {
    sp_loading_frame();
    sp_stats_frame();
    sp_hover_capture(self, drawable);
    sp_present_orig(self, _cmd, drawable);
}
static void (*sp_present_at_orig)(id, SEL, id, CFTimeInterval);
static void sp_present_at(id self, SEL _cmd, id drawable, CFTimeInterval t) {
    sp_loading_frame();
    sp_stats_frame();
    sp_hover_capture(self, drawable);
    sp_present_at_orig(self, _cmd, drawable, t);
}
static void (*sp_present_after_orig)(id, SEL, id, CFTimeInterval);
static void sp_present_after(id self, SEL _cmd, id drawable, CFTimeInterval t) {
    sp_loading_frame();
    sp_stats_frame();
    sp_hover_capture(self, drawable);
    sp_present_after_orig(self, _cmd, drawable, t);
}

// Called with the client's CAMetalLayer when it goes on screen (-[NSView setLayer:]). The client makes
// a new one when it comes back from the background; the presents stay hooked, the strip moves to it.
// SP_HOVER_OFF=1 leaves the client's presents alone (so there's no loading screen: sploading.m).
static void sp_hover_attach(CALayer *layer) {
    if (![layer respondsToSelector:@selector(nextDrawable)] || getenv("SP_HOVER_OFF")) return;
    if (sp_hover_metal_layer) {
        sp_hover_metal_layer = layer;
        sp_hover_cropped = NO;  // the new layer shows the whole drawable until a strip is seen
        sph_reset(&sp_hover_asm);
        sph_reset(&sp_hover_focus_asm);
        [layer setValue:@NO forKey:@"framebufferOnly"];
        sp_stub_log("hover: reading the strip from the client's new layer");
        return;
    }
    sp_hover_metal_layer = layer;
    sp_hover_testing = getenv("SP_HOVER_TEST") != NULL;
    sph_reset(&sp_hover_asm);
    sph_reset(&sp_hover_focus_asm);
    [layer setValue:@NO forKey:@"framebufferOnly"];
    // The device's command buffer class: one made here is the same kind as the client's.
    id<MTLDevice> dev = [layer valueForKey:@"device"] ?: MTLCreateSystemDefaultDevice();
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    Class c = object_getClass(cb);
    sp_stats_hook_gpu(c);
    Method m;
    if ((m = class_getInstanceMethod(c, @selector(presentDrawable:))))
        sp_present_orig = (void *)method_setImplementation(m, (IMP)sp_present);
    if ((m = class_getInstanceMethod(c, @selector(presentDrawable:atTime:))))
        sp_present_at_orig = (void *)method_setImplementation(m, (IMP)sp_present_at);
    if ((m = class_getInstanceMethod(c, @selector(presentDrawable:afterMinimumDuration:))))
        sp_present_after_orig = (void *)method_setImplementation(m, (IMP)sp_present_after);
    sp_stub_log([NSString stringWithFormat:@"hover: reading the strip from presents on %s",
                 class_getName(c)].UTF8String);
}
