#ifndef CODEXU_USAGE_DECODER_H
#define CODEXU_USAGE_DECODER_H
#include <stdint.h>

// 0 成功，1 损坏或截断，2 超出资源预算，3 I/O 失败，4 超时
int codexu_decode_zstd(int input, int output, uint64_t maximum_bytes, double timeout_seconds);
#endif
