// Decoder for the SPHover and SPKeyboard addons' pixel strip (addon/SPHover/SPHover.lua has the format;
// SPKeyboard's frames are 'V' 'K', and its message holds at most one rect, then a byte the decoder skips).
// Plain C, so addon/test can run it on the Mac against the addon's own output.

#include <stdint.h>
#include <string.h>

#define SPH_BLOCKS 320
#define SPH_FRAME_BYTES 120  // SPH_BLOCKS * 3 / 8
#define SPH_PAYLOAD_BYTES (SPH_FRAME_BYTES - 7)
#define SPH_MAX_RECTS 400
#define SPH_MAX_MESSAGE (2 + SPH_MAX_RECTS * 6)
#define SPH_MAX_CHUNKS ((SPH_MAX_MESSAGE + SPH_PAYLOAD_BYTES - 1) / SPH_PAYLOAD_BYTES)

typedef struct { float x, y, w, h; } sph_rect;  // fractions of the screen, origin bottom left

typedef struct {
    int seq, count, received;  // the message being assembled; seq -1 for none
    uint8_t have[SPH_MAX_CHUNKS];
    uint8_t data[SPH_MAX_CHUNKS * SPH_PAYLOAD_BYTES];
} sph_assembler;

enum { SPH_NONE, SPH_CHUNK, SPH_MESSAGE };

static void sph_reset(sph_assembler *a) {
    a->seq = -1;
}

// One frame from the sampled blocks: rgb[i] is block i's color bits (r << 2 | g << 1 | b).
// Returns its kind, 'W' (SPHover's) or 'K' (SPKeyboard's), or 0 unless it's a valid strip frame.
static int sph_frame_from_blocks(const uint8_t rgb[SPH_BLOCKS], uint8_t frame[SPH_FRAME_BYTES]) {
    memset(frame, 0, SPH_FRAME_BYTES);
    for (int i = 0; i < SPH_BLOCKS * 3; i++)
        if (rgb[i / 3] >> (2 - i % 3) & 1) frame[i / 8] |= 0x80 >> (i % 8);
    if (frame[0] != 'V' || (frame[1] != 'W' && frame[1] != 'K')) return 0;
    unsigned s1 = 0, s2 = 0;
    for (int i = 0; i < SPH_FRAME_BYTES - 2; i++) {
        s1 = (s1 + frame[i]) % 255;
        s2 = (s2 + s1) % 255;
    }
    return frame[SPH_FRAME_BYTES - 2] == s2 && frame[SPH_FRAME_BYTES - 1] == s1 ? frame[1] : 0;
}

// Feeds one valid frame. On SPH_MESSAGE, rects/n hold the complete message's rects (each message is
// reported once, however often it repeats).
static int sph_feed(sph_assembler *a, const uint8_t frame[SPH_FRAME_BYTES], sph_rect *rects, int *n) {
    int seq = frame[2], chunk = frame[3], count = frame[4];
    if (count == 0 || count > SPH_MAX_CHUNKS || chunk >= count) return SPH_NONE;
    if (seq != a->seq || count != a->count) {
        a->seq = seq;
        a->count = count;
        a->received = 0;
        memset(a->have, 0, sizeof a->have);
    }
    if (a->have[chunk]) return SPH_CHUNK;
    a->have[chunk] = 1;
    memcpy(a->data + chunk * SPH_PAYLOAD_BYTES, frame + 5, SPH_PAYLOAD_BYTES);
    if (++a->received < count) return SPH_CHUNK;
    const uint8_t *d = a->data;
    int total = d[0] << 8 | d[1];
    if (total > SPH_MAX_RECTS || 2 + total * 6 > count * SPH_PAYLOAD_BYTES) return SPH_CHUNK;
    for (int i = 0; i < total; i++) {
        const uint8_t *r = d + 2 + i * 6;
        rects[i].x = (r[0] << 4 | r[1] >> 4) / 4095.0f;
        rects[i].y = ((r[1] & 15) << 8 | r[2]) / 4095.0f;
        rects[i].w = (r[3] << 4 | r[4] >> 4) / 4095.0f;
        rects[i].h = ((r[4] & 15) << 8 | r[5]) / 4095.0f;
    }
    *n = total;
    return SPH_MESSAGE;
}
