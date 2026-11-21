#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define RCD_EXPORT __declspec(dllexport)
#else
#define RCD_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RcdClient RcdClient;
typedef struct RcdFrame RcdFrame;

typedef struct {
    uint64_t sequence;
    uint32_t width;
    uint32_t height;
    const uint8_t* pixels;
} RcdFrameView;

RCD_EXPORT RcdClient* rcd_create(const char* profile_dir, const char* platform, int32_t mobile);
RCD_EXPORT void rcd_destroy(RcdClient* client);

// Commands: 0 connect (IPv4[:port]), 1 disconnect, 2 display ID, 3 mute (value 0/1), 4 UTF-8 text.
RCD_EXPORT void rcd_command(RcdClient* client, int32_t kind, const char* text, int32_t value);
// Events: 0 pointer (x/y = normalized coordinates), 1 button, 2 scroll (x/y = steps), 3 VK, 4 release inputs.
RCD_EXPORT void rcd_input(RcdClient* client, int32_t kind, int32_t code, int32_t down, float x, float y);

// Returns UTF-8 byte count. Copies only when capacity is sufficient.
RCD_EXPORT size_t rcd_state(RcdClient* client, uint8_t* output, size_t capacity);
// The pixel view is immutable until rcd_release_frame. A null handle means no newer frame.
RCD_EXPORT RcdFrame* rcd_acquire_frame(RcdClient* client, uint64_t after, uint64_t generation, RcdFrameView* output);
RCD_EXPORT void rcd_release_frame(RcdFrame* frame);

#ifdef __cplusplus
}
#endif
