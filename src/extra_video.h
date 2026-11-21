#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace rincast {

// Keep this small boundary independent of the protocol enum so Media can own
// the codec mapping and the adapter can be tested without constructing Session.
enum class ExtraVideoCodec : uint8_t { AV1 };

struct ExtraVideoCapabilities {
    bool av1_8bit = false;
    bool av110bit = false;
};

// Probes codecs that were compiled into this adapter. A capability is true only
// when a decoder context was successfully created at runtime.
ExtraVideoCapabilities ProbeExtraVideo();

// Software AV1 decoder for one OBU stream. Decode() accepts one access unit
// containing one or more AV1 OBUs. Output is BGRA8888, matching Flutter's
// PixelFormat.bgra8888. Calls must be serialized onto one worker thread.
class ExtraVideoDecoder final {
   public:
    static std::unique_ptr<ExtraVideoDecoder> Create(
        ExtraVideoCodec codec,
        bool ten_bit,
        std::string* error = nullptr);

    ~ExtraVideoDecoder();

    ExtraVideoDecoder(const ExtraVideoDecoder&) = delete;
    ExtraVideoDecoder& operator=(const ExtraVideoDecoder&) = delete;
    ExtraVideoDecoder(ExtraVideoDecoder&&) noexcept;
    ExtraVideoDecoder& operator=(ExtraVideoDecoder&&) noexcept;

    // Returns true only when a new decoded picture is ready. The latest picture
    // is retained when one packet produces multiple output pictures.
    bool Decode(const uint8_t* data, std::size_t size);

    // Moves the pending BGRA8888 pixels. Width and height remain queryable until
    // the next decoded picture replaces them.
    std::vector<uint8_t> TakeVideoPixels();
    int VideoWidth() const noexcept;
    int VideoHeight() const noexcept;
    bool HasVideo() const noexcept;
    bool TenBit() const noexcept;

    // Drops delayed pictures and resets AV1 reference state. Reuses the context.
    void Reset();

    const std::string& LastError() const noexcept;

   private:
    struct Impl;
    explicit ExtraVideoDecoder(std::unique_ptr<Impl> impl) noexcept;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace rincast
