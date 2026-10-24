#ifndef CREELDEPS_H
#define CREELDEPS_H
#include <libavformat/avformat.h>
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

// Swift cannot import function-like macros such as AVERROR(e) or av_err2str(),
// nor the FFERRTAG-based constants. Expose them as functions here.
static inline int reel_averror(int posix_errno) { return AVERROR(posix_errno); }
static inline int reel_averror_eof(void) { return AVERROR_EOF; }
static inline int reel_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int64_t reel_av_nopts(void) { return AV_NOPTS_VALUE; }
static inline int reel_av_time_base(void) { return AV_TIME_BASE; }

// Thread-safe replacement for av_err2str(); copies the message into buf and returns buf.
const char *reel_err_string(int errnum, char *buf, size_t buflen);
#endif
