#include <avif/avif.h>
#include <napi/native_api.h>

#include <climits>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <utility>

namespace {

constexpr uint32_t MAX_IMAGE_SIDE = 8192;
constexpr uint32_t MAX_IMAGE_PIXELS = 16 * 1024 * 1024;
// Match the attachment size limit and bound libavif's file-reader buffer.
constexpr uint64_t MAX_FILE_BYTES = 64 * 1024 * 1024;
constexpr uint32_t RGBA_BYTES_PER_PIXEL = 4;

struct DecodeWork {
    char path[PATH_MAX]{};
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    std::unique_ptr<uint8_t[]> pixels;
};

bool ApplyTransforms(avifRGBImage& rgb, std::unique_ptr<uint8_t[]>& pixels, const avifCropRect& crop,
                     uint8_t rotation, int mirrorAxis)
{
    if (crop.width == rgb.width && crop.height == rgb.height && rotation == 0 && mirrorAxis == -1) {
        return true;
    }

    const bool swapAxes = (rotation & 1) != 0;
    const uint32_t width = swapAxes ? crop.height : crop.width;
    const uint32_t height = swapAxes ? crop.width : crop.height;
    const uint32_t rowBytes = width * RGBA_BYTES_PER_PIXEL;
    std::unique_ptr<uint8_t[]> transformed(new (std::nothrow) uint8_t[static_cast<size_t>(rowBytes) * height]);
    if (!transformed) {
        return false;
    }

    // Map output pixels back through the mirror, counterclockwise rotation, and clean aperture.
    const bool reverseCropX = rotation == 1 || rotation == 2;
    const bool reverseCropY = rotation == 2 || rotation == 3;
    for (uint32_t y = 0; y < height; ++y) {
        const uint32_t rotatedY = mirrorAxis == 0 ? height - 1 - y : y;
        uint8_t* destination = transformed.get() + static_cast<size_t>(y) * rowBytes;
        for (uint32_t x = 0; x < width; ++x) {
            const uint32_t rotatedX = mirrorAxis == 1 ? width - 1 - x : x;
            const uint32_t cropX = swapAxes ? rotatedY : rotatedX;
            const uint32_t cropY = swapAxes ? rotatedX : rotatedY;
            const uint32_t sourceX = crop.x + (reverseCropX ? crop.width - 1 - cropX : cropX);
            const uint32_t sourceY = crop.y + (reverseCropY ? crop.height - 1 - cropY : cropY);
            const uint8_t* source = rgb.pixels + static_cast<size_t>(sourceY) * rgb.rowBytes +
                                    sourceX * RGBA_BYTES_PER_PIXEL;
            std::memcpy(destination, source, RGBA_BYTES_PER_PIXEL);
            destination += RGBA_BYTES_PER_PIXEL;
        }
    }

    pixels = std::move(transformed);
    rgb.pixels = pixels.get();
    rgb.width = width;
    rgb.height = height;
    rgb.rowBytes = rowBytes;
    return true;
}

void Decode(napi_env, void* data)
{
    auto& work = *static_cast<DecodeWork*>(data);
    std::unique_ptr<avifDecoder, decltype(&avifDecoderDestroy)> decoder(avifDecoderCreate(), avifDecoderDestroy);
    if (!decoder) {
        return;
    }

    decoder->maxThreads = 2;
    decoder->imageDimensionLimit = MAX_IMAGE_SIDE;
    decoder->imageSizeLimit = MAX_IMAGE_PIXELS;
    decoder->ignoreExif = AVIF_TRUE;
    decoder->ignoreXMP = AVIF_TRUE;
    if (avifDecoderSetIOFile(decoder.get(), work.path) != AVIF_RESULT_OK ||
        decoder->io->sizeHint == 0 || decoder->io->sizeHint > MAX_FILE_BYTES ||
        avifDecoderParse(decoder.get()) != AVIF_RESULT_OK || avifDecoderNextImage(decoder.get()) != AVIF_RESULT_OK) {
        return;
    }

    const avifImage* image = decoder->image;
    if (!image || image->width == 0 || image->height == 0 ||
        image->width > MAX_IMAGE_SIDE || image->height > MAX_IMAGE_SIDE ||
        static_cast<uint64_t>(image->width) * image->height > MAX_IMAGE_PIXELS) {
        return;
    }

    avifCropRect crop{0, 0, image->width, image->height};
    if (image->transformFlags & AVIF_TRANSFORM_CLAP) {
        avifDiagnostics diagnostics{};
        if (!avifCropRectFromCleanApertureBox(&crop, &image->clap, image->width, image->height, &diagnostics)) {
            return;
        }
    }
    const uint8_t rotation = (image->transformFlags & AVIF_TRANSFORM_IROT) ? image->irot.angle : 0;
    const int mirrorAxis = (image->transformFlags & AVIF_TRANSFORM_IMIR) ? image->imir.axis : -1;

    avifRGBImage rgb{};
    avifRGBImageSetDefaults(&rgb, image);
    rgb.depth = 8;
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.alphaPremultiplied = AVIF_FALSE;
    rgb.rowBytes = image->width * RGBA_BYTES_PER_PIXEL;
    const size_t byteLength = static_cast<size_t>(rgb.rowBytes) * image->height;
    std::unique_ptr<uint8_t[]> pixels(new (std::nothrow) uint8_t[byteLength]);
    if (!pixels) {
        return;
    }

    rgb.pixels = pixels.get();
    if (avifImageYUVToRGB(image, &rgb) != AVIF_RESULT_OK) {
        return;
    }
    decoder.reset();
    if (!ApplyTransforms(rgb, pixels, crop, rotation, mirrorAxis)) {
        return;
    }

    work.width = rgb.width;
    work.height = rgb.height;
    work.pixels = std::move(pixels);
}

void FreePixels(napi_env, void* data, void*)
{
    delete[] static_cast<uint8_t*>(data);
}

napi_value CreateFrame(napi_env env, DecodeWork& work)
{
    napi_value frame;
    napi_value width;
    napi_value height;
    napi_value rgba;
    const size_t byteLength = static_cast<size_t>(work.width) * work.height * RGBA_BYTES_PER_PIXEL;
    if (napi_create_object(env, &frame) != napi_ok || napi_create_uint32(env, work.width, &width) != napi_ok ||
        napi_create_uint32(env, work.height, &height) != napi_ok ||
        napi_create_external_arraybuffer(env, work.pixels.get(), byteLength, FreePixels, nullptr, &rgba) != napi_ok) {
        return nullptr;
    }
    work.pixels.release();

    const napi_property_descriptor properties[] = {
        {"width", nullptr, nullptr, nullptr, nullptr, width, napi_default_jsproperty, nullptr},
        {"height", nullptr, nullptr, nullptr, nullptr, height, napi_default_jsproperty, nullptr},
        {"rgba", nullptr, nullptr, nullptr, nullptr, rgba, napi_default_jsproperty, nullptr},
    };
    if (napi_define_properties(env, frame, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        return nullptr;
    }
    return frame;
}

void ResolveDecode(napi_env env, napi_deferred deferred, napi_value frame = nullptr)
{
    if (!frame) {
        bool exceptionPending = false;
        napi_value error;
        if (napi_is_exception_pending(env, &exceptionPending) == napi_ok && exceptionPending &&
            napi_get_and_clear_last_exception(env, &error) == napi_ok) {
            napi_reject_deferred(env, deferred, error);
            return;
        }
        if (napi_get_null(env, &frame) != napi_ok) {
            return;
        }
    }
    napi_resolve_deferred(env, deferred, frame);
}

void CompleteDecode(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<DecodeWork> work(static_cast<DecodeWork*>(data));
    napi_value frame = nullptr;
    if (status == napi_ok && work->pixels) {
        frame = CreateFrame(env, *work);
    }
    ResolveDecode(env, work->deferred, frame);
    napi_delete_async_work(env, work->work);
}

napi_value DecodeAvif(napi_env env, napi_callback_info info)
{
    napi_deferred deferred;
    napi_value promise;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Cannot create AVIF decode promise");
        return nullptr;
    }

    size_t argc = 1;
    napi_value path;
    size_t length;
    if (napi_get_cb_info(env, info, &argc, &path, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, path, nullptr, 0, &length) != napi_ok || length == 0 || length >= PATH_MAX) {
        ResolveDecode(env, deferred);
        return promise;
    }

    std::unique_ptr<DecodeWork> work(new (std::nothrow) DecodeWork);
    size_t copied;
    if (!work || napi_get_value_string_utf8(env, path, work->path, length + 1, &copied) != napi_ok || copied != length ||
        work->path[0] != '/' || std::memchr(work->path, '\0', length) != nullptr) {
        ResolveDecode(env, deferred);
        return promise;
    }

    work->deferred = deferred;
    napi_value resource;
    if (napi_create_string_utf8(env, "Nuwa AVIF decode", NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, Decode, CompleteDecode, work.get(), &work->work) != napi_ok) {
        ResolveDecode(env, deferred);
        return promise;
    }

    if (napi_queue_async_work(env, work->work) == napi_ok) {
        work.release();
    } else {
        ResolveDecode(env, deferred);
        napi_delete_async_work(env, work->work);
    }
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor decode = {
        "decodeAvif", nullptr, DecodeAvif, nullptr, nullptr, nullptr, napi_default, nullptr,
    };
    return napi_define_properties(env, exports, 1, &decode) == napi_ok ? exports : nullptr;
}

napi_module module = {NAPI_MODULE_VERSION, 0, nullptr, Init, "nuwa_avif", nullptr, {nullptr}};

__attribute__((constructor)) void RegisterNuwaAvif()
{
    napi_module_register(&module);
}

} // namespace
