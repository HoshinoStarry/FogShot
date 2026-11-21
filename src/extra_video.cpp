#include "extra_video.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <limits>
#include <system_error>
#include <thread>
#include <utility>

#include <dav1d/dav1d.h>
#include <libyuv/convert_argb.h>

namespace rincast {
namespace {

constexpr int kMaxDecoderThreads = 8;

std::string ErrorText(int result) {
    return std::generic_category().message(-result);
}

const libyuv::YuvConstants* ColorMatrix(const Dav1dPicture& picture) {
    const bool full_range = picture.seq_hdr && picture.seq_hdr->color_range != 0;
    const Dav1dMatrixCoefficients matrix =
        picture.seq_hdr ? picture.seq_hdr->mtrx : DAV1D_MC_BT709;

    switch (matrix) {
        case DAV1D_MC_BT601:
        case DAV1D_MC_BT470BG:
            return full_range ? &libyuv::kYuvJPEGConstants : &libyuv::kYuvI601Constants;
        case DAV1D_MC_BT2020_NCL:
        case DAV1D_MC_BT2020_CL:
            return full_range ? &libyuv::kYuvV2020Constants : &libyuv::kYuv2020Constants;
        case DAV1D_MC_BT709:
        case DAV1D_MC_UNKNOWN:
        default:
            return full_range ? &libyuv::kYuvF709Constants : &libyuv::kYuvH709Constants;
    }
}

bool ValidDimensions(const Dav1dPicture& picture) {
    const int width = picture.p.w;
    const int height = picture.p.h;
    if (width <= 0 || height <= 0 || width > INT_MAX / 4) return false;
    const std::size_t pixels = std::size_t(width) * std::size_t(height);
    return pixels <= std::numeric_limits<std::size_t>::max() / 4;
}

bool ConvertPicture(const Dav1dPicture& picture, std::vector<uint8_t>& output) {
    if (!ValidDimensions(picture)) return false;
    if (picture.p.bpc != 8 && picture.p.bpc != 10) return false;
    if (picture.p.layout == DAV1D_PIXEL_LAYOUT_I400) return false;

    const int width = picture.p.w;
    const int height = picture.p.h;
    const int dst_stride = width * 4;
    output.resize(std::size_t(dst_stride) * std::size_t(height));
    const auto* matrix = ColorMatrix(picture);

    if (picture.p.bpc == 8) {
        const auto* y = static_cast<const uint8_t*>(picture.data[0]);
        const auto* u = static_cast<const uint8_t*>(picture.data[1]);
        const auto* v = static_cast<const uint8_t*>(picture.data[2]);
        const int stride_y = int(picture.stride[0]);
        const int stride_uv = int(picture.stride[1]);
        int result = -1;
        switch (picture.p.layout) {
            case DAV1D_PIXEL_LAYOUT_I420:
                result = libyuv::I420ToARGBMatrix(
                    y, stride_y, u, stride_uv, v, stride_uv, output.data(), dst_stride,
                    matrix, width, height);
                break;
            case DAV1D_PIXEL_LAYOUT_I422:
                result = libyuv::I422ToARGBMatrix(
                    y, stride_y, u, stride_uv, v, stride_uv, output.data(), dst_stride,
                    matrix, width, height);
                break;
            case DAV1D_PIXEL_LAYOUT_I444:
                result = libyuv::I444ToARGBMatrix(
                    y, stride_y, u, stride_uv, v, stride_uv, output.data(), dst_stride,
                    matrix, width, height);
                break;
            default:
                return false;
        }
        return result == 0;
    }

    const auto* y = static_cast<const uint16_t*>(picture.data[0]);
    const auto* u = static_cast<const uint16_t*>(picture.data[1]);
    const auto* v = static_cast<const uint16_t*>(picture.data[2]);
    // dav1d reports byte strides. libyuv's high-bit-depth APIs use uint16_t
    // element strides, so these are converted rather than passed through.
    const int stride_y = int(picture.stride[0] / 2);
    const int stride_uv = int(picture.stride[1] / 2);
    int result = -1;
    switch (picture.p.layout) {
        case DAV1D_PIXEL_LAYOUT_I420:
            result = libyuv::I010ToARGBMatrix(
                y, stride_y, u, stride_uv, v, stride_uv, output.data(), dst_stride,
                matrix, width, height);
            break;
        case DAV1D_PIXEL_LAYOUT_I422:
            result = libyuv::I210ToARGBMatrix(
                y, stride_y, u, stride_uv, v, stride_uv, output.data(), dst_stride,
                matrix, width, height);
            break;
        case DAV1D_PIXEL_LAYOUT_I444:
            result = libyuv::I410ToARGBMatrix(
                y, stride_y, u, stride_uv, v, stride_uv, output.data(), dst_stride,
                matrix, width, height);
            break;
        default:
            return false;
    }
    return result == 0;
}

void SetError(std::string* error, std::string message) {
    if (error) *error = std::move(message);
}

}  // namespace

struct ExtraVideoDecoder::Impl {
    explicit Impl(bool wanted_ten_bit) : ten_bit(wanted_ten_bit) {}

    ~Impl() { Close(); }

    bool Open() {
        Dav1dSettings settings{};
        dav1d_default_settings(&settings);
        const unsigned processors = std::max(1u, std::thread::hardware_concurrency());
        settings.n_threads = int(std::min(processors, unsigned(kMaxDecoderThreads)));
        settings.max_frame_delay = 1;
        settings.apply_grain = 0;
        settings.decode_frame_type = DAV1D_DECODEFRAMETYPE_ALL;
        settings.logger.callback = nullptr;
        const int result = dav1d_open(&context, &settings);
        if (result < 0) {
            error = std::string("dav1d_open failed: ") + ErrorText(result);
            return false;
        }
        return true;
    }

    void Close() {
        if (context) dav1d_close(&context);
    }

    bool DecodePicture(Dav1dPicture& picture) {
        if (picture.p.bpc == 8 && ten_bit) {
            error = "AV1 decoder produced 8-bit instead of negotiated 10-bit output";
            dav1d_picture_unref(&picture);
            return false;
        }
        if (picture.p.bpc > 8 && !ten_bit) {
            error = "AV1 decoder produced high-bit-depth output for an 8-bit stream";
            dav1d_picture_unref(&picture);
            return false;
        }

        std::vector<uint8_t> converted;
        if (!ConvertPicture(picture, converted)) {
            error = "Unsupported AV1 output layout or bit depth";
            dav1d_picture_unref(&picture);
            return false;
        }
        pixels = std::move(converted);
        width = picture.p.w;
        height = picture.p.h;
        dav1d_picture_unref(&picture);
        return true;
    }

    bool DrainPictures(bool& got_picture, bool* produced = nullptr) {
        bool produced_picture = false;
        for (;;) {
            Dav1dPicture picture{};
            const int result = dav1d_get_picture(context, &picture);
            if (result == DAV1D_ERR(EAGAIN)) {
                if (produced) *produced = produced_picture;
                return true;
            }
            if (result < 0) {
                error = std::string("dav1d_get_picture failed: ") + ErrorText(result);
                return false;
            }
            if (!DecodePicture(picture)) return false;
            got_picture = true;
            produced_picture = true;
        }
    }

    bool Decode(const uint8_t* data, std::size_t size) {
        if (!context || !data || size == 0 || size > std::numeric_limits<std::size_t>::max() - 1) {
            error = "Invalid AV1 access unit";
            return false;
        }
        pixels.clear();
        error.clear();

        Dav1dData input{};
        uint8_t* destination = dav1d_data_create(&input, size);
        if (!destination) {
            error = "dav1d_data_create failed";
            return false;
        }
        std::memcpy(destination, data, size);

        bool got_picture = false;
        bool ok = true;
        while (input.sz != 0 && ok) {
            const std::size_t size_before_send = input.sz;
            bool produced = false;
            const int sent = dav1d_send_data(context, &input);
            ok = DrainPictures(got_picture, &produced);
            if (!ok) break;
            if (sent < 0 && sent != DAV1D_ERR(EAGAIN)) {
                error = std::string("dav1d_send_data failed: ") + ErrorText(sent);
                ok = false;
                break;
            }
            if (sent == DAV1D_ERR(EAGAIN) && input.sz == size_before_send && !produced) {
                error = "dav1d made no progress while consuming an AV1 access unit";
                ok = false;
                break;
            }
        }

        if (ok) ok = DrainPictures(got_picture);
        dav1d_data_unref(&input);
        if (!ok) return false;
        if (!got_picture) return false;
        return true;
    }

    void Reset() {
        if (context) {
            dav1d_flush(context);
            for (;;) {
                Dav1dPicture delayed{};
                if (dav1d_get_picture(context, &delayed) != 0) break;
                dav1d_picture_unref(&delayed);
            }
        }
        pixels.clear();
        width = 0;
        height = 0;
        error.clear();
    }

    bool ten_bit = false;
    Dav1dContext* context = nullptr;
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    std::string error;
};

ExtraVideoCapabilities ProbeExtraVideo() {
    ExtraVideoCapabilities capabilities;
    for (const bool ten_bit : {false, true}) {
        Dav1dSettings settings{};
        dav1d_default_settings(&settings);
        settings.n_threads = 1;
        Dav1dContext* context = nullptr;
        if (dav1d_open(&context, &settings) == 0) {
            dav1d_close(&context);
            (ten_bit ? capabilities.av110bit : capabilities.av1_8bit) = true;
        }
    }
    return capabilities;
}

ExtraVideoDecoder::ExtraVideoDecoder(std::unique_ptr<Impl> impl) noexcept
    : m_impl(std::move(impl)) {}

ExtraVideoDecoder::~ExtraVideoDecoder() = default;
ExtraVideoDecoder::ExtraVideoDecoder(ExtraVideoDecoder&&) noexcept = default;
ExtraVideoDecoder& ExtraVideoDecoder::operator=(ExtraVideoDecoder&&) noexcept = default;

std::unique_ptr<ExtraVideoDecoder> ExtraVideoDecoder::Create(
    ExtraVideoCodec codec,
    bool ten_bit,
    std::string* error) {
    if (codec != ExtraVideoCodec::AV1) {
        SetError(error, "Unsupported extra video codec");
        return nullptr;
    }
    auto impl = std::make_unique<Impl>(ten_bit);
    if (!impl->Open()) {
        SetError(error, impl->error);
        return nullptr;
    }
    return std::unique_ptr<ExtraVideoDecoder>(new ExtraVideoDecoder(std::move(impl)));
}

bool ExtraVideoDecoder::Decode(const uint8_t* data, std::size_t size) {
    return m_impl->Decode(data, size);
}

std::vector<uint8_t> ExtraVideoDecoder::TakeVideoPixels() {
    return std::exchange(m_impl->pixels, {});
}

int ExtraVideoDecoder::VideoWidth() const noexcept { return m_impl->width; }

int ExtraVideoDecoder::VideoHeight() const noexcept { return m_impl->height; }

bool ExtraVideoDecoder::HasVideo() const noexcept { return !m_impl->pixels.empty(); }

bool ExtraVideoDecoder::TenBit() const noexcept { return m_impl->ten_bit; }

void ExtraVideoDecoder::Reset() { m_impl->Reset(); }

const std::string& ExtraVideoDecoder::LastError() const noexcept { return m_impl->error; }

}  // namespace rincast
