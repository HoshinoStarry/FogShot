#include "media.h"

#include <atomic>
#include <climits>
#include <cstring>
#include <limits>
#include <utility>

#include <codec_api.h>
#include <libyuv/convert_argb.h>

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio.h>

#include "rc/audio_codec.h"
#include "rc/platform.h"
#include "rc/protocol.h"

namespace rincast {

namespace {

constexpr ma_uint32 kSampleRate = 48000;
constexpr ma_uint32 kPlaybackChannels = 2;
constexpr ma_uint32 kMicrophoneChannels = 1;
constexpr ma_uint32 kAudioCapacityFrames = kSampleRate * 2;
constexpr ma_uint32 kMicrophoneFrameFrames = 480;
constexpr int kOpusMaxPacketMs = 120;

}  // namespace

struct Media::Impl {
    ~Impl() { Close(); }

    static void AudioCallback(ma_device* device, void* output, const void*, ma_uint32 frame_count) {
        auto* self = static_cast<Impl*>(device->pUserData);
        auto* out = static_cast<int16_t*>(output);
        ma_uint32 written = 0;

        while (written < frame_count) {
            ma_uint32 frames = frame_count - written;
            void* input = nullptr;
            if (ma_pcm_rb_acquire_read(&self->audioRing, &frames, &input) != MA_SUCCESS || frames == 0) break;
            std::memcpy(out + std::size_t(written) * kPlaybackChannels, input,
                        std::size_t(frames) * kPlaybackChannels * sizeof(int16_t));
            ma_pcm_rb_commit_read(&self->audioRing, frames);
            written += frames;
        }

        if (written < frame_count) {
            std::memset(out + std::size_t(written) * kPlaybackChannels, 0,
                        std::size_t(frame_count - written) * kPlaybackChannels * sizeof(int16_t));
        }

        const bool silent = !self->playbackActive.load(std::memory_order_relaxed) ||
                            self->muted.load(std::memory_order_relaxed);
        const float volume = silent ? 0.0f : self->volume.load(std::memory_order_relaxed);
        const std::size_t samples = std::size_t(frame_count) * kPlaybackChannels;
        if (volume < 1.0f) {
            for (std::size_t i = 0; i < samples; ++i) out[i] = int16_t(float(out[i]) * volume);
        }
    }

    static void MicrophoneCallback(ma_device* device, void*, const void* input, ma_uint32 frame_count) {
        if (!input || frame_count == 0) return;
        auto* self = static_cast<Impl*>(device->pUserData);
        const auto* in = static_cast<const int16_t*>(input);
        ma_uint32 remaining = frame_count;
        while (remaining > 0) {
            ma_uint32 chunk = remaining;
            void* output = nullptr;
            if (ma_pcm_rb_acquire_write(&self->microphoneRing, &chunk, &output) != MA_SUCCESS ||
                chunk == 0) {
                return;
            }
            std::memcpy(output, in, std::size_t(chunk) * kMicrophoneChannels * sizeof(int16_t));
            ma_pcm_rb_commit_write(&self->microphoneRing, chunk);
            in += std::size_t(chunk) * kMicrophoneChannels;
            remaining -= chunk;
        }
    }

    bool OpenVideoDecoder() {
        if (WelsCreateDecoder(&decoder) != 0 || !decoder) {
            decoder = nullptr;
            return false;
        }

        SDecodingParam params{};
        params.uiTargetDqLayer = UCHAR_MAX;
        params.eEcActiveIdc = ERROR_CON_SLICE_COPY;
        params.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
        if (decoder->Initialize(&params) != 0) {
            WelsDestroyDecoder(decoder);
            decoder = nullptr;
            return false;
        }
        return true;
    }

    void CloseVideoDecoder() {
        if (!decoder) return;
        decoder->Uninitialize();
        WelsDestroyDecoder(decoder);
        decoder = nullptr;
    }

    bool OpenAudioRing() {
        audioRingInitialized =
            ma_pcm_rb_init(ma_format_s16, kPlaybackChannels, kAudioCapacityFrames, nullptr, nullptr, &audioRing) ==
            MA_SUCCESS;
        return audioRingInitialized;
    }

    void CloseAudioRing() {
        if (!audioRingInitialized) return;
        ma_pcm_rb_uninit(&audioRing);
        audioRingInitialized = false;
    }

    bool OpenMicrophoneRing() {
        microphoneRingInitialized = ma_pcm_rb_init(ma_format_s16, kMicrophoneChannels,
                                                   kAudioCapacityFrames, nullptr, nullptr,
                                                   &microphoneRing) == MA_SUCCESS;
        return microphoneRingInitialized;
    }

    void CloseMicrophoneRing() {
        if (!microphoneRingInitialized) return;
        ma_pcm_rb_uninit(&microphoneRing);
        microphoneRingInitialized = false;
    }

    bool OpenAudio() {
        if (!opus.Init(int(kSampleRate), int(kPlaybackChannels))) return false;
        opusPcm.resize(std::size_t(kSampleRate) * kOpusMaxPacketMs / 1000 * kPlaybackChannels);
        if (!OpenAudioRing()) return false;

        ma_device_config config = ma_device_config_init(ma_device_type_playback);
        config.playback.format = ma_format_s16;
        config.playback.channels = kPlaybackChannels;
        config.sampleRate = kSampleRate;
        config.periodSizeInMilliseconds = 20;
        config.dataCallback = &Impl::AudioCallback;
        config.pUserData = this;

        if (ma_device_init(nullptr, &config, &audioDevice) != MA_SUCCESS) {
            CloseAudioRing();
            return false;
        }
        audioDeviceInitialized = true;
        if (ma_device_start(&audioDevice) != MA_SUCCESS) {
            ma_device_uninit(&audioDevice);
            audioDeviceInitialized = false;
            CloseAudioRing();
            return false;
        }
        audioReady = true;
        return true;
    }

    void CloseAudio() {
        audioReady = false;
        if (audioDeviceInitialized) {
            ma_device_stop(&audioDevice);
            ma_device_uninit(&audioDevice);
            audioDeviceInitialized = false;
        }
        CloseAudioRing();
    }

    bool ResetAudio() {
        if (!audioDeviceInitialized) return false;
        audioReady = false;
        if (ma_device_stop(&audioDevice) != MA_SUCCESS) return false;
        CloseAudioRing();
        if (!OpenAudioRing()) return false;
        if (!opus.Init(int(kSampleRate), int(kPlaybackChannels))) {
            CloseAudioRing();
            return false;
        }
        if (ma_device_start(&audioDevice) != MA_SUCCESS) return false;
        audioReady = true;
        return audioReady;
    }

    bool OpenMicrophone() {
        if (microphoneReady) return true;
        if (!OpenMicrophoneRing()) return false;

        microphoneEncoder = std::make_unique<rc::AudioEncoder>();
        if (!microphoneEncoder->Init(int(kSampleRate), int(kMicrophoneChannels), 48000, true)) {
            microphoneEncoder.reset();
            CloseMicrophoneRing();
            return false;
        }

        ma_device_config config = ma_device_config_init(ma_device_type_capture);
        config.capture.format = ma_format_s16;
        config.capture.channels = kMicrophoneChannels;
        config.sampleRate = kSampleRate;
        config.periodSizeInMilliseconds = 10;
        config.performanceProfile = ma_performance_profile_low_latency;
        config.dataCallback = &Impl::MicrophoneCallback;
        config.pUserData = this;

        if (ma_device_init(nullptr, &config, &microphoneDevice) != MA_SUCCESS) {
            microphoneEncoder.reset();
            CloseMicrophoneRing();
            return false;
        }
        microphoneDeviceInitialized = true;
        if (ma_device_start(&microphoneDevice) != MA_SUCCESS) {
            ma_device_uninit(&microphoneDevice);
            microphoneDeviceInitialized = false;
            microphoneEncoder.reset();
            CloseMicrophoneRing();
            return false;
        }

        microphoneFrame.resize(kMicrophoneFrameFrames);
        microphoneSequence = 0;
        microphoneReady = true;
        return true;
    }

    void CloseMicrophone() {
        microphoneReady = false;
        if (microphoneDeviceInitialized) {
            ma_device_stop(&microphoneDevice);
            ma_device_uninit(&microphoneDevice);
            microphoneDeviceInitialized = false;
        }
        CloseMicrophoneRing();
        microphoneEncoder.reset();
    }

    bool TakeMicrophonePacket(std::vector<uint8_t>& packet) {
        packet.clear();
        if (!microphoneReady || !microphoneEncoder ||
            ma_pcm_rb_available_read(&microphoneRing) < kMicrophoneFrameFrames) {
            return false;
        }

        std::size_t offset = 0;
        while (offset < microphoneFrame.size()) {
            ma_uint32 frames = ma_uint32(microphoneFrame.size() - offset);
            void* input = nullptr;
            if (ma_pcm_rb_acquire_read(&microphoneRing, &frames, &input) != MA_SUCCESS || frames == 0) {
                return false;
            }
            std::memcpy(microphoneFrame.data() + offset, input,
                        std::size_t(frames) * kMicrophoneChannels * sizeof(int16_t));
            ma_pcm_rb_commit_read(&microphoneRing, frames);
            offset += frames;
        }

        constexpr std::size_t kOpusCapacity = 1000;
        const std::size_t headerSize = sizeof(rc::AudioPacketHeader);
        packet.resize(headerSize + kOpusCapacity);
        const int encoded = microphoneEncoder->Encode(microphoneFrame.data(), int(kMicrophoneFrameFrames),
                                                      packet.data() + headerSize, int(kOpusCapacity));
        if (encoded <= 0) {
            packet.clear();
            return false;
        }

        rc::AudioPacketHeader header{};
        header.stream = uint8_t(rc::AudioStream::MicToPc);
        header.channels = uint8_t(kMicrophoneChannels);
        header.frameSamples = uint16_t(kMicrophoneFrameFrames);
        header.sequence = ++microphoneSequence;
        header.timestampNs = uint64_t(rc::NowNs());
        std::memcpy(packet.data(), &header, headerSize);
        packet.resize(headerSize + std::size_t(encoded));
        return true;
    }

    bool PushPcm(const int16_t* samples, std::size_t frames) {
        if (!audioReady || !samples || frames == 0 || frames > std::numeric_limits<ma_uint32>::max()) {
            return false;
        }

        ma_uint32 remaining = ma_uint32(frames);
        const int16_t* cursor = samples;
        while (remaining > 0) {
            ma_uint32 chunk = remaining;
            void* output = nullptr;
            if (ma_pcm_rb_acquire_write(&audioRing, &chunk, &output) != MA_SUCCESS || chunk == 0) return false;
            std::memcpy(output, cursor, std::size_t(chunk) * kPlaybackChannels * sizeof(int16_t));
            ma_pcm_rb_commit_write(&audioRing, chunk);
            cursor += std::size_t(chunk) * kPlaybackChannels;
            remaining -= chunk;
        }
        return true;
    }

    void Close() {
        CloseMicrophone();
        CloseAudio();
        CloseVideoDecoder();
        pixels.clear();
        width = 0;
        height = 0;
    }

    ISVCDecoder* decoder = nullptr;
    rc::AudioDecoder opus;
    std::vector<int16_t> opusPcm;
    ma_device audioDevice{};
    ma_pcm_rb audioRing{};
    bool audioDeviceInitialized = false;
    bool audioRingInitialized = false;
    bool audioReady = false;
    ma_device microphoneDevice{};
    ma_pcm_rb microphoneRing{};
    std::unique_ptr<rc::AudioEncoder> microphoneEncoder;
    std::vector<int16_t> microphoneFrame;
    uint32_t microphoneSequence = 0;
    bool microphoneDeviceInitialized = false;
    bool microphoneRingInitialized = false;
    bool microphoneReady = false;
    std::atomic<bool> muted{false};
    std::atomic<bool> playbackActive{true};
    std::atomic<float> volume{1.0f};
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
};

Media::Media() : m_impl(std::make_unique<Impl>()) {}

Media::~Media() = default;

Media::Media(Media&&) noexcept = default;

Media& Media::operator=(Media&&) noexcept = default;

bool Media::Initialize(bool playback) {
    m_impl->Close();
    if (!m_impl->OpenVideoDecoder()) return false;
    if (playback) m_impl->OpenAudio();  // An unavailable playback device must not disable video.
    return true;
}

bool Media::DecodeVideo(const uint8_t* input, std::size_t input_size) {
    if (!m_impl->decoder || !input || input_size == 0 || input_size > std::size_t(INT_MAX)) return false;

    unsigned char* planes[3]{};
    SBufferInfo info{};
    const DECODING_STATE state =
        m_impl->decoder->DecodeFrameNoDelay(input, int(input_size), planes, &info);
    if (state != dsErrorFree || info.iBufferStatus != 1) return false;

    const int width = info.UsrData.sSystemBuffer.iWidth;
    const int height = info.UsrData.sSystemBuffer.iHeight;
    if (!planes[0] || !planes[1] || !planes[2] || width <= 0 || height <= 0 || width > INT_MAX / 4) {
        return false;
    }

    std::vector<uint8_t> bgra(std::size_t(width) * std::size_t(height) * 4);
    // libyuv ARGB is B,G,R,A in little-endian memory, matching Flutter BGRA8888.
    const int converted = libyuv::I420ToARGBMatrix(
        planes[0], info.UsrData.sSystemBuffer.iStride[0], planes[1],
        info.UsrData.sSystemBuffer.iStride[1], planes[2], info.UsrData.sSystemBuffer.iStride[1],
        bgra.data(), width * 4, &libyuv::kYuvH709Constants, width, height);
    if (converted != 0) return false;

    m_impl->pixels = std::move(bgra);
    m_impl->width = width;
    m_impl->height = height;
    return true;
}

std::vector<uint8_t> Media::TakeVideoPixels() { return std::exchange(m_impl->pixels, {}); }

int Media::VideoWidth() const noexcept { return m_impl->width; }

int Media::VideoHeight() const noexcept { return m_impl->height; }

bool Media::HasVideo() const noexcept { return !m_impl->pixels.empty(); }

bool Media::DecodeAudio(const int16_t* samples, std::size_t frames) {
    return m_impl->PushPcm(samples, frames);
}

bool Media::DecodeOpus(const uint8_t* packet, std::size_t packet_size) {
    if (!m_impl->audioReady || !packet || packet_size == 0 || packet_size > std::size_t(INT_MAX)) return false;
    const int maxFrames = int(m_impl->opusPcm.size() / kPlaybackChannels);
    const int decoded = m_impl->opus.Decode(packet, int(packet_size), m_impl->opusPcm.data(), maxFrames);
    if (decoded <= 0) return false;
    return m_impl->PushPcm(m_impl->opusPcm.data(), std::size_t(decoded));
}

bool Media::AudioAvailable() const noexcept { return m_impl->audioReady; }

void Media::SetMuted(bool muted) noexcept { m_impl->muted.store(muted, std::memory_order_relaxed); }

void Media::SetPlaybackActive(bool active) noexcept {
    m_impl->playbackActive.store(active, std::memory_order_relaxed);
}

void Media::SetVolume(float volume) noexcept {
    if (!(volume >= 0.0f)) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    m_impl->volume.store(volume, std::memory_order_relaxed);
}

bool Media::StartMicrophone() { return m_impl->OpenMicrophone(); }

void Media::StopMicrophone() { m_impl->CloseMicrophone(); }

bool Media::TakeMicPacket(std::vector<uint8_t>& packet) {
    return m_impl->TakeMicrophonePacket(packet);
}

void Media::Reset() {
    m_impl->pixels.clear();
    m_impl->width = 0;
    m_impl->height = 0;

    m_impl->CloseVideoDecoder();
    m_impl->OpenVideoDecoder();
    m_impl->ResetAudio();
}

}  // namespace rincast
