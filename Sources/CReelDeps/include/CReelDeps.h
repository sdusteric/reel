#ifndef CREELDEPS_H
#define CREELDEPS_H
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/display.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <ass/ass.h>
#include <stddef.h>
#include <stdint.h>

// Swift cannot import function-like macros such as AVERROR(e) or av_err2str(),
// nor the FFERRTAG-based constants. Expose them as functions here.
static inline int reel_averror(int posix_errno) { return AVERROR(posix_errno); }
static inline int reel_averror_eof(void) { return AVERROR_EOF; }
static inline int reel_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int reel_averror_invaliddata(void) { return AVERROR_INVALIDDATA; }
static inline int64_t reel_av_nopts(void) { return AV_NOPTS_VALUE; }
static inline int reel_av_time_base(void) { return AV_TIME_BASE; }

// Thread-safe replacement for av_err2str(); copies the message into buf and returns buf.
const char *reel_err_string(int errnum, char *buf, size_t buflen);

// MARK: libass messages

// Receives each libass message, already formatted, with the sink the calling thread set through
// reel_ass_set_thread_sink (NULL when none). libass calls back on the thread that called it.
typedef void (*reel_ass_message_handler)(int level, const char *message, void *sink);

// Installs the formatting callback on `library`; `handler` gets every message.
void reel_ass_install_message_handler(ASS_Library *library, reel_ass_message_handler handler);

// Sets the sink passed to the handler for messages raised on the calling thread.
void reel_ass_set_thread_sink(void *sink);

// The process-wide ASS_Library (one per app, design section 8.1), created on first use with
// `handler` installed. NULL if libass failed to initialise.
ASS_Library *reel_ass_shared_library(reel_ass_message_handler handler);

// Serialises calls that touch the shared library (track and renderer creation, headers).
void reel_ass_library_lock(void);
void reel_ass_library_unlock(void);

// MARK: Subtitle pixels

// Blends one ASS_Image (an alpha mask in one RGBA colour, A = transparency) source-over onto
// premultiplied BGRA. `dst` is the pixel at (origin_x, origin_y) of the frame.
void reel_blend_ass_image(const ASS_Image *image, uint8_t *dst, ptrdiff_t dst_stride,
                          int origin_x, int origin_y);

// Expands a PAL8 bitmap with a palette of 32-bit ARGB entries (FFmpeg's AVSubtitleRect layout)
// to premultiplied BGRA. Indices at or past `colors` become transparent.
void reel_expand_pal8(const uint8_t *indices, int index_stride, const uint32_t *palette, int colors,
                      int width, int height, uint8_t *dst, ptrdiff_t dst_stride);

// MARK: In-memory input

// An AVIOContext reading a private copy of `size` bytes. Free with reel_avio_close_memory.
AVIOContext *reel_avio_open_memory(const uint8_t *data, size_t size);
void reel_avio_close_memory(AVIOContext **context);
// MARK: TrueType outlines

// One font's glyphs as TrueType `glyf` data (design 8.4: PingFang rebuilt for FreeType). Every
// array is malloc'd; free the result with reel_glyf_free.
typedef struct {
    uint8_t *glyf;        // glyph records, each padded to 4 bytes
    size_t glyf_size;
    uint32_t *offsets;    // count + 1 offsets into glyf (the loca table, host order)
    int16_t *bounds;      // 4 per glyph: xMin, yMin, xMax, yMax (zeros for an empty glyph)
    uint16_t max_points;
    uint16_t max_contours;
} reel_glyf_result;

// Converts glyphs 0 to count - 1 of `font` (a CTFontRef sized at its units per em) with
// CTFontCreatePathForGlyph: quadratic and line segments map one to one, cubics are split into
// two quadratics, coordinates are rounded. Returns 0, or -1 when memory runs out.
int reel_build_glyf(const void *font, uint32_t count, reel_glyf_result *result);
void reel_glyf_free(reel_glyf_result *result);

// Every Unicode scalar `font` (a CTFontRef) maps to a glyph, in code point order. Fills malloc'd
// arrays the caller frees with free(); returns the count, or -1 when memory runs out.
long reel_font_character_map(const void *font, uint32_t **codes, uint16_t **glyphs);

// The OpenType table checksum: the big-endian 32-bit words of `bytes`, zero padded, summed.
uint32_t reel_table_checksum(const uint8_t *bytes, size_t size);

#endif
