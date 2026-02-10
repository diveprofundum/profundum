#ifndef CZLIB_HELPER_H
#define CZLIB_HELPER_H

#include <stdint.h>

/// Decompress gzip data using zlib.
/// Returns the number of decompressed bytes written to `dst`, or -1 on error.
/// `src` points to raw gzip data (starting with 1f 8b).
int czlib_gunzip(const uint8_t *src, int srcLen, uint8_t *dst, int dstLen);

#endif
