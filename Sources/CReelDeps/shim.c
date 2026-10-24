#include "CReelDeps.h"
#include <stdio.h>

const char *reel_err_string(int errnum, char *buf, size_t buflen) {
    if (av_strerror(errnum, buf, buflen) < 0) { snprintf(buf, buflen, "error %d", errnum); }
    return buf;
}
