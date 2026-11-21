#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace rincast {

// Windows, macOS, iOS, Android and Linux media backend. Media does not depend on
// SDL, a Flutter view or a window and can be driven from a worker thread.
class Media final {
   public:
    Media();
    ~Media();

    Media(const Media&) = delete;
    Media& operator=(const Media&) = delete;
    Media(Media&&) noexcept;
    Media& operator=(Media&&) noexcept;

    // Initialize OpenH264 and optionally the default playback device. Audio
    // failure does not fail this call; AudioAvailable() reports that state.
    // Video-only decoder instances should pass false. Safe to repeat.
    bool Initialize(bool playback = true);

    // Decode one Annex-B H.264 access unit. True means a new BGRA frame was
    // produced and stored. False includes incomplete pictures and errors.
    bool DecodeVideo(const uint8_t* input, std::size_t input_size);

    // Move the latest BGRA8888 frame. Returns an empty vector when none is
    // pending. The width and height remain available until the next new frame.
    std::vector<uint8_t> TakeVideoPixels();
    int VideoWidth() const noexcept;
    int VideoHeight() const noexcept;
    bool HasVideo() const noexcept;

    // samples is interleaved little-endian signed 16-bit PCM. frames counts
    // sample frames per channel.
    bool DecodeAudio(const int16_t* samples, std::size_t frames);

    // packet is one Opus packet without Ogg/RTP framing. Decode and play it as
    // 48 kHz stereo.
    bool DecodeOpus(const uint8_t* packet, std::size_t packet_size);

    bool AudioAvailable() const noexcept;
    void SetMuted(bool muted) noexcept;

    // Playback gain in the inclusive range [0, 1]. This is independent of mute.
    void SetVolume(float volume) noexcept;

    // Capture mono 48 kHz S16 microphone audio. The real-time callback only
    // writes to a ring buffer; Opus encoding happens in TakeMicPacket().
    bool StartMicrophone();
    void StopMicrophone();

    // Non-blocking. On success packet is one complete upstream AudioPacketHeader
    // followed by a 10 ms (480 sample) mono Opus payload. Failure clears packet.
    bool TakeMicPacket(std::vector<uint8_t>& packet);

    // Discard the pending picture, H.264 reference state and queued audio while
    // keeping the initialized playback device.
    void Reset();

   private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace rincast
