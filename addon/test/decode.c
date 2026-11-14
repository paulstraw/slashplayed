// Reads mockwow.lua's output on stdin, decodes the strip frames with the shim's decoder and checks
// the last message's rects against the expected ones. Exit 0 if it decodes and matches. argv[1]: the
// frames' kind, W (SPHover's, the default) or K (SPKeyboard's); a frame of another kind fails. argv[2]:
// how many messages there must be, if given.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../shims/appkit/sphoverstrip.h"

int main(int argc, char **argv) {
    int kind = argc > 1 ? argv[1][0] : 'W';
    int want_n;
    if (scanf("expect %d\n", &want_n) != 1) return 2;
    sph_rect *want = calloc(want_n, sizeof *want);
    for (int i = 0; i < want_n; i++)
        if (scanf("%f %f %f %f\n", &want[i].x, &want[i].y, &want[i].w, &want[i].h) != 4) return 2;
    static sph_assembler a;
    sph_reset(&a);
    static sph_rect got[SPH_MAX_RECTS];
    int got_n = -1, frames = 0, valid = 0, messages = 0;
    char line[SPH_BLOCKS + 8];
    while (fgets(line, sizeof line, stdin)) {
        uint8_t rgb[SPH_BLOCKS], frame[SPH_FRAME_BYTES];
        for (int i = 0; i < SPH_BLOCKS; i++) rgb[i] = line[i] - '0';
        frames++;
        int k = sph_frame_from_blocks(rgb, frame);
        if (!k) continue;
        if (k != kind) {
            printf("FAIL: a frame of kind %c, expected %c\n", k, kind);
            return 1;
        }
        valid++;
        int n;
        if (sph_feed(&a, frame, got, &n) == SPH_MESSAGE) {
            got_n = n;
            messages++;
            printf("message after %d frames: %d rects in %d chunks\n", frames, n, a.count);
        }
    }
    printf("%d frames, %d valid\n", frames, valid);
    if (got_n != want_n) {
        printf("FAIL: %d rects, expected %d\n", got_n, want_n);
        return 1;
    }
    int bad = 0;
    for (int i = 0; i < want_n; i++) {
        // 12-bit fractions: within 1/4095 of the screen, plus rounding of both corners.
        float tol = 1.5f / 4095;
        if (fabsf(got[i].x - want[i].x) > tol || fabsf(got[i].y - want[i].y) > tol ||
            fabsf(got[i].w - want[i].w) > 2 * tol || fabsf(got[i].h - want[i].h) > 2 * tol) {
            printf("FAIL rect %d: got %f %f %f %f, expected %f %f %f %f\n", i, got[i].x, got[i].y, got[i].w,
                   got[i].h, want[i].x, want[i].y, want[i].w, want[i].h);
            bad++;
        }
    }
    if (bad) return 1;
    if (argc > 2 && messages != atoi(argv[2])) {
        printf("FAIL: %d messages, expected %s\n", messages, argv[2]);
        return 1;
    }
    printf("ok: %d rects match\n", want_n);
    return 0;
}
