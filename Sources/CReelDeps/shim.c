#include "CReelDeps.h"
#include <CoreText/CoreText.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *reel_err_string(int errnum, char *buf, size_t buflen) {
    if (av_strerror(errnum, buf, buflen) < 0) { snprintf(buf, buflen, "error %d", errnum); }
    return buf;
}

// MARK: libass messages

static _Thread_local void *reel_ass_thread_sink = NULL;

static void reel_ass_message_callback(int level, const char *fmt, va_list args, void *data) {
    reel_ass_message_handler handler = (reel_ass_message_handler)data;
    if (!handler || !fmt) { return; }
    char buffer[1024];
    vsnprintf(buffer, sizeof buffer, fmt, args);
    handler(level, buffer, reel_ass_thread_sink);
}

void reel_ass_install_message_handler(ASS_Library *library, reel_ass_message_handler handler) {
    ass_set_message_cb(library, reel_ass_message_callback, (void *)handler);
}

void reel_ass_set_thread_sink(void *sink) { reel_ass_thread_sink = sink; }

static pthread_mutex_t reel_ass_library_mutex = PTHREAD_MUTEX_INITIALIZER;
static ASS_Library *reel_ass_library = NULL;
static int reel_ass_library_tried = 0;

ASS_Library *reel_ass_shared_library(reel_ass_message_handler handler) {
    pthread_mutex_lock(&reel_ass_library_mutex);
    if (!reel_ass_library_tried) {
        reel_ass_library_tried = 1;
        reel_ass_library = ass_library_init();
        if (reel_ass_library) {
            reel_ass_install_message_handler(reel_ass_library, handler);
            ass_set_extract_fonts(reel_ass_library, 1);
        }
    }
    ASS_Library *library = reel_ass_library;
    pthread_mutex_unlock(&reel_ass_library_mutex);
    return library;
}

void reel_ass_library_lock(void) { pthread_mutex_lock(&reel_ass_library_mutex); }
void reel_ass_library_unlock(void) { pthread_mutex_unlock(&reel_ass_library_mutex); }

// MARK: Subtitle pixels

void reel_blend_ass_image(const ASS_Image *image, uint8_t *dst, ptrdiff_t dst_stride,
                          int origin_x, int origin_y) {
    if (!image || image->w <= 0 || image->h <= 0) { return; }
    const uint32_t color = image->color;
    const unsigned red = (color >> 24) & 0xFF;
    const unsigned green = (color >> 16) & 0xFF;
    const unsigned blue = (color >> 8) & 0xFF;
    const unsigned opacity = 255 - (color & 0xFF);
    if (opacity == 0) { return; }
    for (int row = 0; row < image->h; row++) {
        const uint8_t *mask = image->bitmap + (ptrdiff_t)row * image->stride;
        uint8_t *out = dst + (ptrdiff_t)(image->dst_y - origin_y + row) * dst_stride
            + (ptrdiff_t)(image->dst_x - origin_x) * 4;
        for (int column = 0; column < image->w; column++, out += 4) {
            const unsigned coverage = mask[column];
            if (coverage == 0) { continue; }
            const unsigned alpha = (coverage * opacity + 127) / 255;
            const unsigned keep = 255 - alpha;
            out[0] = (uint8_t)((blue * alpha + out[0] * keep + 127) / 255);
            out[1] = (uint8_t)((green * alpha + out[1] * keep + 127) / 255);
            out[2] = (uint8_t)((red * alpha + out[2] * keep + 127) / 255);
            out[3] = (uint8_t)(alpha + (out[3] * keep + 127) / 255);
        }
    }
}

void reel_expand_pal8(const uint8_t *indices, int index_stride, const uint32_t *palette, int colors,
                      int width, int height, uint8_t *dst, ptrdiff_t dst_stride) {
    uint32_t premultiplied[256];
    for (int entry = 0; entry < 256; entry++) {
        if (!palette || entry >= colors) {
            premultiplied[entry] = 0;
            continue;
        }
        const uint32_t argb = palette[entry];
        const unsigned alpha = (argb >> 24) & 0xFF;
        const unsigned red = ((argb >> 16) & 0xFF) * alpha / 255;
        const unsigned green = ((argb >> 8) & 0xFF) * alpha / 255;
        const unsigned blue = (argb & 0xFF) * alpha / 255;
        // Little-endian BGRA bytes.
        premultiplied[entry] = blue | (green << 8) | (red << 16) | (alpha << 24);
    }
    for (int row = 0; row < height; row++) {
        const uint8_t *in = indices + (ptrdiff_t)row * index_stride;
        uint8_t *out = dst + (ptrdiff_t)row * dst_stride;
        for (int column = 0; column < width; column++) {
            const uint32_t pixel = premultiplied[in[column]];
            memcpy(out + (ptrdiff_t)column * 4, &pixel, 4);
        }
    }
}

// MARK: In-memory input

typedef struct {
    uint8_t *data;
    size_t size;
    size_t position;
} ReelMemoryInput;

static int reel_memory_read(void *opaque, uint8_t *buf, int buf_size) {
    ReelMemoryInput *input = opaque;
    if (input->position >= input->size) { return AVERROR_EOF; }
    size_t count = input->size - input->position;
    if (count > (size_t)buf_size) { count = (size_t)buf_size; }
    memcpy(buf, input->data + input->position, count);
    input->position += count;
    return (int)count;
}

static int64_t reel_memory_seek(void *opaque, int64_t offset, int whence) {
    ReelMemoryInput *input = opaque;
    int64_t base;
    switch (whence & ~AVSEEK_FORCE) {
    case AVSEEK_SIZE: return (int64_t)input->size;
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = (int64_t)input->position; break;
    case SEEK_END: base = (int64_t)input->size; break;
    default: return AVERROR(EINVAL);
    }
    int64_t target = base + offset;
    if (target < 0 || target > (int64_t)input->size) { return AVERROR(EINVAL); }
    input->position = (size_t)target;
    return target;
}

AVIOContext *reel_avio_open_memory(const uint8_t *data, size_t size) {
    ReelMemoryInput *input = calloc(1, sizeof *input);
    if (!input) { return NULL; }
    input->data = malloc(size > 0 ? size : 1);
    if (!input->data) {
        free(input);
        return NULL;
    }
    if (size > 0) { memcpy(input->data, data, size); }
    input->size = size;
    const int buffer_size = 4096;
    uint8_t *buffer = av_malloc(buffer_size);
    if (!buffer) {
        free(input->data);
        free(input);
        return NULL;
    }
    AVIOContext *context = avio_alloc_context(buffer, buffer_size, 0, input, reel_memory_read, NULL, reel_memory_seek);
    if (!context) {
        av_free(buffer);
        free(input->data);
        free(input);
    }
    return context;
}

void reel_avio_close_memory(AVIOContext **context) {
    if (!context || !*context) { return; }
    ReelMemoryInput *input = (*context)->opaque;
    av_freep(&(*context)->buffer);
    avio_context_free(context);
    if (input) {
        free(input->data);
        free(input);
    }
}

// MARK: TrueType outlines

typedef struct {
    int32_t x, y;
    uint8_t on;
} reel_point;

typedef struct {
    reel_point *items;
    size_t count, capacity;
} reel_points;

typedef struct {
    uint8_t *bytes;
    size_t count, capacity;
} reel_bytes;

static int reel_reserve(void **items, size_t *capacity, size_t needed, size_t size) {
    if (needed <= *capacity) return 0;
    size_t next = *capacity ? *capacity * 2 : 256;
    while (next < needed) next *= 2;
    void *grown = realloc(*items, next * size);
    if (!grown) return -1;
    *items = grown;
    *capacity = next;
    return 0;
}

static int reel_points_add(reel_points *list, CGPoint point, int on) {
    if (reel_reserve((void **)&list->items, &list->capacity, list->count + 1, sizeof(reel_point))) return -1;
    list->items[list->count++] = (reel_point){(int32_t)lround(point.x), (int32_t)lround(point.y), (uint8_t)on};
    return 0;
}

static int reel_bytes_add(reel_bytes *buffer, const void *data, size_t size) {
    if (reel_reserve((void **)&buffer->bytes, &buffer->capacity, buffer->count + size, 1)) return -1;
    memcpy(buffer->bytes + buffer->count, data, size);
    buffer->count += size;
    return 0;
}

static int reel_bytes_be16(reel_bytes *buffer, uint16_t value) {
    uint8_t bytes[2] = {(uint8_t)(value >> 8), (uint8_t)value};
    return reel_bytes_add(buffer, bytes, 2);
}

// One glyph being collected: the open contour, then the finished points and contour ends.
typedef struct {
    reel_points current;
    reel_points points;
    uint16_t *ends;
    size_t end_count, end_capacity;
    CGPoint last, start;
    int failed;
} reel_glyph;

// Merges coincident points (a control point on its end point makes a straight segment), drops
// the closing duplicate and on-curve points TrueType implies between two control points, then
// keeps the contour when it still has area.
static void reel_finish_contour(reel_glyph *glyph) {
    reel_point *in = glyph->current.items;
    size_t n = 0;
    for (size_t i = 0; i < glyph->current.count; i++) {
        if (n > 0 && in[n - 1].x == in[i].x && in[n - 1].y == in[i].y) {
            in[n - 1].on = in[n - 1].on || in[i].on;
            continue;
        }
        in[n++] = in[i];
    }
    while (n > 1 && in[0].x == in[n - 1].x && in[0].y == in[n - 1].y) {
        in[0].on = in[0].on || in[n - 1].on;
        n--;
    }
    glyph->current.count = 0;
    if (n < 3) return;
    size_t kept = 0;
    for (size_t i = 0; i < n; i++) {
        reel_point point = in[i], before = in[(i + n - 1) % n], after = in[(i + 1) % n];
        if (point.on && !before.on && !after.on && 2 * point.x == before.x + after.x && 2 * point.y == before.y + after.y) continue;
        kept++;
    }
    int elide = kept >= 3;
    for (size_t i = 0; i < n; i++) {
        reel_point point = in[i], before = in[(i + n - 1) % n], after = in[(i + 1) % n];
        if (elide && point.on && !before.on && !after.on && 2 * point.x == before.x + after.x && 2 * point.y == before.y + after.y) continue;
        if (reel_reserve((void **)&glyph->points.items, &glyph->points.capacity, glyph->points.count + 1, sizeof(reel_point))) {
            glyph->failed = 1;
            return;
        }
        glyph->points.items[glyph->points.count++] = point;
    }
    if (reel_reserve((void **)&glyph->ends, &glyph->end_capacity, glyph->end_count + 1, sizeof(uint16_t))) {
        glyph->failed = 1;
        return;
    }
    glyph->ends[glyph->end_count++] = (uint16_t)(glyph->points.count - 1);
}

static CGPoint reel_mid(CGPoint a, CGPoint b) { return CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2); }

static void reel_path_element(void *info, const CGPathElement *element) {
    reel_glyph *glyph = info;
    const CGPoint *p = element->points;
    switch (element->type) {
    case kCGPathElementMoveToPoint:
        reel_finish_contour(glyph);
        glyph->start = glyph->last = p[0];
        if (reel_points_add(&glyph->current, p[0], 1)) glyph->failed = 1;
        break;
    case kCGPathElementAddLineToPoint:
        if (reel_points_add(&glyph->current, p[0], 1)) glyph->failed = 1;
        glyph->last = p[0];
        break;
    case kCGPathElementAddQuadCurveToPoint:
        if (reel_points_add(&glyph->current, p[0], 0) || reel_points_add(&glyph->current, p[1], 1)) glyph->failed = 1;
        glyph->last = p[1];
        break;
    case kCGPathElementAddCurveToPoint: {
        // Split at t = 0.5; each half becomes the quadratic through its tangent intersection.
        CGPoint p0 = glyph->last, ab = reel_mid(p0, p[0]), bc = reel_mid(p[0], p[1]), cd = reel_mid(p[1], p[2]);
        CGPoint abc = reel_mid(ab, bc), bcd = reel_mid(bc, cd), middle = reel_mid(abc, bcd);
        CGPoint halves[2][4] = {{p0, ab, abc, middle}, {middle, bcd, cd, p[2]}};
        for (int h = 0; h < 2; h++) {
            CGPoint control = CGPointMake((3 * (halves[h][1].x + halves[h][2].x) - halves[h][0].x - halves[h][3].x) / 4,
                                          (3 * (halves[h][1].y + halves[h][2].y) - halves[h][0].y - halves[h][3].y) / 4);
            if (reel_points_add(&glyph->current, control, 0) || reel_points_add(&glyph->current, halves[h][3], 1)) glyph->failed = 1;
        }
        glyph->last = p[2];
        break;
    }
    case kCGPathElementCloseSubpath:
        reel_finish_contour(glyph);
        glyph->last = glyph->start;
        break;
    }
}

static int reel_encode_glyph(const reel_glyph *glyph, reel_bytes *out, int16_t *bounds) {
    const reel_point *points = glyph->points.items;
    size_t count = glyph->points.count;
    int32_t xmin = points[0].x, xmax = points[0].x, ymin = points[0].y, ymax = points[0].y;
    for (size_t i = 1; i < count; i++) {
        if (points[i].x < xmin) xmin = points[i].x;
        if (points[i].x > xmax) xmax = points[i].x;
        if (points[i].y < ymin) ymin = points[i].y;
        if (points[i].y > ymax) ymax = points[i].y;
    }
    bounds[0] = (int16_t)xmin;
    bounds[1] = (int16_t)ymin;
    bounds[2] = (int16_t)xmax;
    bounds[3] = (int16_t)ymax;
    int failed = reel_bytes_be16(out, (uint16_t)glyph->end_count);
    for (int i = 0; i < 4; i++) failed |= reel_bytes_be16(out, (uint16_t)bounds[i]);
    for (size_t i = 0; i < glyph->end_count; i++) failed |= reel_bytes_be16(out, glyph->ends[i]);
    failed |= reel_bytes_be16(out, 0);
    uint8_t *flags = malloc(count), *xs = malloc(count * 2), *ys = malloc(count * 2);
    if (!flags || !xs || !ys) {
        free(flags);
        free(xs);
        free(ys);
        return -1;
    }
    size_t x_count = 0, y_count = 0;
    int32_t px = 0, py = 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t flag = points[i].on ? 0x01 : 0;
        int32_t dx = points[i].x - px, dy = points[i].y - py;
        px = points[i].x;
        py = points[i].y;
        if (dx == 0) {
            flag |= 0x10;
        } else if (dx > -256 && dx < 256) {
            flag |= 0x02 | (dx > 0 ? 0x10 : 0);
            xs[x_count++] = (uint8_t)(dx > 0 ? dx : -dx);
        } else {
            uint16_t v = (uint16_t)(int16_t)dx;
            xs[x_count++] = (uint8_t)(v >> 8);
            xs[x_count++] = (uint8_t)v;
        }
        if (dy == 0) {
            flag |= 0x20;
        } else if (dy > -256 && dy < 256) {
            flag |= 0x04 | (dy > 0 ? 0x20 : 0);
            ys[y_count++] = (uint8_t)(dy > 0 ? dy : -dy);
        } else {
            uint16_t v = (uint16_t)(int16_t)dy;
            ys[y_count++] = (uint8_t)(v >> 8);
            ys[y_count++] = (uint8_t)v;
        }
        flags[i] = flag;
    }
    for (size_t i = 0; i < count;) {
        size_t repeats = 0;
        while (i + repeats + 1 < count && flags[i + repeats + 1] == flags[i] && repeats < 255) repeats++;
        if (repeats > 0) {
            uint8_t pair[2] = {(uint8_t)(flags[i] | 0x08), (uint8_t)repeats};
            failed |= reel_bytes_add(out, pair, 2);
        } else {
            failed |= reel_bytes_add(out, &flags[i], 1);
        }
        i += repeats + 1;
    }
    failed |= reel_bytes_add(out, xs, x_count);
    failed |= reel_bytes_add(out, ys, y_count);
    static const uint8_t zeros[4] = {0, 0, 0, 0};
    if (out->count % 4) failed |= reel_bytes_add(out, zeros, 4 - out->count % 4);
    free(flags);
    free(xs);
    free(ys);
    return failed ? -1 : 0;
}

int reel_build_glyf(const void *font, uint32_t count, reel_glyf_result *result) {
    memset(result, 0, sizeof(*result));
    result->offsets = calloc((size_t)count + 1, sizeof(uint32_t));
    result->bounds = calloc((size_t)count * 4 + 4, sizeof(int16_t));
    if (!result->offsets || !result->bounds) {
        reel_glyf_free(result);
        return -1;
    }
    reel_bytes out = {0};
    reel_glyph glyph = {0};
    int failed = 0;
    for (uint32_t g = 0; g < count && !failed; g++) {
        result->offsets[g] = (uint32_t)out.count;
        CGPathRef path = CTFontCreatePathForGlyph((CTFontRef)font, (CGGlyph)g, NULL);
        if (!path) continue;
        glyph.current.count = 0;
        glyph.points.count = 0;
        glyph.end_count = 0;
        glyph.failed = 0;
        CGPathApply(path, &glyph, reel_path_element);
        reel_finish_contour(&glyph);
        CGPathRelease(path);
        if (glyph.failed) {
            failed = 1;
            break;
        }
        if (glyph.end_count == 0) continue;
        if (glyph.points.count > result->max_points) result->max_points = (uint16_t)glyph.points.count;
        if (glyph.end_count > result->max_contours) result->max_contours = (uint16_t)glyph.end_count;
        if (reel_encode_glyph(&glyph, &out, result->bounds + (size_t)g * 4)) failed = 1;
    }
    result->offsets[count] = (uint32_t)out.count;
    free(glyph.current.items);
    free(glyph.points.items);
    free(glyph.ends);
    result->glyf = out.bytes;
    result->glyf_size = out.count;
    if (failed) {
        reel_glyf_free(result);
        return -1;
    }
    return 0;
}

void reel_glyf_free(reel_glyf_result *result) {
    free(result->glyf);
    free(result->offsets);
    free(result->bounds);
    memset(result, 0, sizeof(*result));
}

long reel_font_character_map(const void *font, uint32_t **codes, uint16_t **glyphs) {
    *codes = NULL;
    *glyphs = NULL;
    size_t capacity = 0, count = 0;
    enum { chunk = 4096 };
    UniChar units[chunk * 2];
    CGGlyph found[chunk * 2];
    uint32_t scalars[chunk];
    uint32_t code = 0;
    while (code <= 0x10FFFF) {
        size_t n = 0, unit_count = 0;
        for (; code <= 0x10FFFF && n < chunk; code++) {
            if (code >= 0xD800 && code <= 0xDFFF) continue;
            scalars[n++] = code;
            if (code > 0xFFFF) {
                uint32_t v = code - 0x10000;
                units[unit_count++] = (UniChar)(0xD800 + (v >> 10));
                units[unit_count++] = (UniChar)(0xDC00 + (v & 0x3FF));
            } else {
                units[unit_count++] = (UniChar)code;
            }
        }
        memset(found, 0, sizeof(found));
        // Missing characters return false but the others are still filled in.
        CTFontGetGlyphsForCharacters((CTFontRef)font, units, found, (CFIndex)unit_count);
        size_t unit = 0;
        for (size_t i = 0; i < n; i++) {
            CGGlyph glyph = found[unit];
            unit += scalars[i] > 0xFFFF ? 2 : 1;
            if (!glyph) continue;
            if (count == capacity) {
                size_t next = capacity ? capacity * 2 : 4096;
                uint32_t *grown_codes = realloc(*codes, next * sizeof(uint32_t));
                if (grown_codes) *codes = grown_codes;
                uint16_t *grown_glyphs = realloc(*glyphs, next * sizeof(uint16_t));
                if (grown_glyphs) *glyphs = grown_glyphs;
                if (!grown_codes || !grown_glyphs) {
                    free(*codes);
                    free(*glyphs);
                    *codes = NULL;
                    *glyphs = NULL;
                    return -1;
                }
                capacity = next;
            }
            (*codes)[count] = scalars[i];
            (*glyphs)[count] = glyph;
            count++;
        }
    }
    return (long)count;
}

uint32_t reel_table_checksum(const uint8_t *bytes, size_t size) {
    uint32_t sum = 0;
    size_t i = 0;
    for (; i + 4 <= size; i += 4) {
        sum += ((uint32_t)bytes[i] << 24) | ((uint32_t)bytes[i + 1] << 16) | ((uint32_t)bytes[i + 2] << 8) | bytes[i + 3];
    }
    if (i < size) {
        uint32_t word = 0;
        for (size_t k = 0; k < 4; k++) word = (word << 8) | (i + k < size ? bytes[i + k] : 0);
        sum += word;
    }
    return sum;
}
