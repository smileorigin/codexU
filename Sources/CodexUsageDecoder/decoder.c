#define ZSTD_STATIC_LINKING_ONLY
#include "../../Vendor/zstd/zstd.h"
#include "decoder.h"
#include <errno.h>
#include <time.h>
#include <unistd.h>

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

int codexu_decode_zstd(int input, int output, uint64_t maximum_bytes, double timeout_seconds) {
    ZSTD_DStream *decoder = ZSTD_createDStream();
    if (!decoder) return 2;
    int result = 1;
    // 限制压缩帧声明的窗口，不能由不可信文件决定解码器内存上限
    if (ZSTD_isError(ZSTD_DCtx_setMaxWindowSize(decoder, 1U << 27))) goto done;
    unsigned char incoming[65536], outgoing[65536];
    uint64_t total = 0;
    size_t remaining = 1;
    int saw_input = 0;
    double deadline = monotonic_seconds() + timeout_seconds;
    for (;;) {
        if (monotonic_seconds() >= deadline) { result = 4; break; }
        ssize_t count = read(input, incoming, sizeof(incoming));
        if (count < 0) { if (errno == EINTR) continue; result = 3; break; }
        if (count == 0) { result = saw_input && remaining == 0 ? 0 : 1; break; }
        saw_input = 1;
        ZSTD_inBuffer source = {incoming, (size_t)count, 0};
        int flush_output;
        do {
            if (monotonic_seconds() >= deadline) { result = 4; goto done; }
            ZSTD_outBuffer target = {outgoing, sizeof(outgoing), 0};
            remaining = ZSTD_decompressStream(decoder, &target, &source);
            if (ZSTD_isError(remaining)) {
                if (ZSTD_getErrorCode(remaining) == ZSTD_error_frameParameter_windowTooLarge) result = 2;
                goto done;
            }
            if (target.pos > maximum_bytes - total) { result = 2; goto done; }
            total += target.pos;
            size_t written = 0;
            while (written < target.pos) {
                ssize_t bytes = write(output, outgoing + written, target.pos - written);
                if (bytes < 0 && errno == EINTR) continue;
                if (bytes <= 0) { result = 3; goto done; }
                written += (size_t)bytes;
            }
            flush_output = target.pos == target.size && remaining != 0;
        } while (source.pos < source.size || flush_output);
    }
done:
    ZSTD_freeDStream(decoder);
    return result;
}
