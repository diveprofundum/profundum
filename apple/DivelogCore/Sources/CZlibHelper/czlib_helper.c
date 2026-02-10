#include "czlib_helper.h"
#include <zlib.h>
#include <string.h>

int czlib_gunzip(const uint8_t *src, int srcLen, uint8_t *dst, int dstLen) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in  = (Bytef *)src;
    strm.avail_in = (uInt)srcLen;
    strm.next_out  = dst;
    strm.avail_out = (uInt)dstLen;

    /* windowBits = 15 + 16 = 31: enable gzip decoding */
    if (inflateInit2(&strm, 15 + 16) != Z_OK)
        return -1;

    int ret = inflate(&strm, Z_FINISH);
    int total = (int)strm.total_out;
    inflateEnd(&strm);

    if (ret == Z_STREAM_END)
        return total;

    /* If the output buffer was too small, try streaming */
    if (ret == Z_BUF_ERROR || ret == Z_OK)
        return -2;  /* buffer too small */

    return -1;
}
