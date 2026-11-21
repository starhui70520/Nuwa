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
constexpr napi_type_tag ANIMATION_TYPE_TAG{0xae962c2177834f24ULL, 0x9d75ff9e434dbac9ULL};

struct DestroyDecoder {
    void operator()(avifDecoder* decoder) const
    {
        avifDecoderDestroy(decoder);
    }
};

using Decoder = std::unique_ptr<avifDecoder, DestroyDecoder>;

struct FramePixels {
    uint32_t width = 0;
    uint32_t height = 0;
    std::unique_ptr<uint8_t[]> pixels;
};

struct DecodeWork {
    char path[PATH_MAX]{};
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    FramePixels frame;
    Decoder decoder;
};

struct Animation {
    Decoder decoder;
    uint32_t frameCount = 0;
    bool closed = false;
};

struct ReadFrameWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_ref animationRef = nullptr;
    Animation* animation = nullptr;
    Decoder decoder;
    uint32_t index = 0;
    double durationMs = 0;
    FramePixels frame;
};

struct CloseWork {
    napi_async_work work = nullptr;
    Decoder decoder;
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

Decoder OpenDecoder(const char* path, avifDecoderSource source)
{
    Decoder decoder(avifDecoderCreate());
    if (!decoder) {
        return nullptr;
    }

    decoder->maxThreads = 2;
    decoder->imageDimensionLimit = MAX_IMAGE_SIDE;
    decoder->imageSizeLimit = MAX_IMAGE_PIXELS;
    decoder->ignoreExif = AVIF_TRUE;
    decoder->ignoreXMP = AVIF_TRUE;
    if (avifDecoderSetSource(decoder.get(), source) != AVIF_RESULT_OK ||
        avifDecoderSetIOFile(decoder.get(), path) != AVIF_RESULT_OK ||
        decoder->io->sizeHint == 0 || decoder->io->sizeHint > MAX_FILE_BYTES ||
        avifDecoderParse(decoder.get()) != AVIF_RESULT_OK) {
        return nullptr;
    }
    return decoder;
}

bool ImageSizeAllowed(const avifImage* image)
{
    return image && image->width > 0 && image->height > 0 &&
           image->width <= MAX_IMAGE_SIDE && image->height <= MAX_IMAGE_SIDE &&
           static_cast<uint64_t>(image->width) * image->height <= MAX_IMAGE_PIXELS;
}

void ConvertFrame(Decoder& decoder, FramePixels& frame, bool releaseDecoder = false)
{
    const avifImage* image = decoder->image;
    if (!ImageSizeAllowed(image)) {
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
    if (releaseDecoder) {
        decoder.reset();
    }
    if (!ApplyTransforms(rgb, pixels, crop, rotation, mirrorAxis)) {
        return;
    }

    frame.width = rgb.width;
    frame.height = rgb.height;
    frame.pixels = std::move(pixels);
}

void Decode(napi_env, void* data)
{
    auto& work = *static_cast<DecodeWork*>(data);
    auto decoder = OpenDecoder(work.path, AVIF_DECODER_SOURCE_AUTO);
    if (decoder && avifDecoderNextImage(decoder.get()) == AVIF_RESULT_OK) {
        ConvertFrame(decoder, work.frame, true);
    }
}

void OpenAnimation(napi_env, void* data)
{
    auto& work = *static_cast<DecodeWork*>(data);
    auto decoder = OpenDecoder(work.path, AVIF_DECODER_SOURCE_TRACKS);
    if (decoder && decoder->imageSequenceTrackPresent && decoder->imageCount > 1 && decoder->timescale > 0 &&
        decoder->progressiveState == AVIF_PROGRESSIVE_STATE_UNAVAILABLE && ImageSizeAllowed(decoder->image)) {
        work.decoder = std::move(decoder);
    }
}

void ReadFrame(napi_env, void* data)
{
    auto& work = *static_cast<ReadFrameWork*>(data);
    // libavif advances directly for the next frame and seeks from a keyframe when looping or skipping.
    if (avifDecoderNthImage(work.decoder.get(), work.index) == AVIF_RESULT_OK) {
        work.durationMs = work.decoder->imageTiming.duration * 1000;
        ConvertFrame(work.decoder, work.frame);
    }
}

void FreePixels(napi_env, void* data, void*)
{
    delete[] static_cast<uint8_t*>(data);
}

napi_value CreateFrame(napi_env env, FramePixels& pixels, double durationMs = -1)
{
    napi_value frame;
    napi_value width;
    napi_value height;
    napi_value rgba;
    const size_t byteLength = static_cast<size_t>(pixels.width) * pixels.height * RGBA_BYTES_PER_PIXEL;
    if (napi_create_object(env, &frame) != napi_ok || napi_create_uint32(env, pixels.width, &width) != napi_ok ||
        napi_create_uint32(env, pixels.height, &height) != napi_ok ||
        napi_create_external_arraybuffer(env, pixels.pixels.get(), byteLength, FreePixels, nullptr, &rgba) != napi_ok) {
        return nullptr;
    }
    pixels.pixels.release();

    const napi_property_descriptor properties[] = {
        {"width", nullptr, nullptr, nullptr, nullptr, width, napi_default_jsproperty, nullptr},
        {"height", nullptr, nullptr, nullptr, nullptr, height, napi_default_jsproperty, nullptr},
        {"rgba", nullptr, nullptr, nullptr, nullptr, rgba, napi_default_jsproperty, nullptr},
    };
    if (napi_define_properties(env, frame, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        return nullptr;
    }
    if (durationMs >= 0) {
        napi_value duration;
        if (napi_create_double(env, durationMs, &duration) != napi_ok ||
            napi_set_named_property(env, frame, "durationMs", duration) != napi_ok) {
            return nullptr;
        }
    }
    return frame;
}

void ResolveDecode(napi_env env, napi_deferred deferred, napi_value result = nullptr)
{
    if (!result) {
        bool exceptionPending = false;
        napi_value error;
        if (napi_is_exception_pending(env, &exceptionPending) == napi_ok && exceptionPending &&
            napi_get_and_clear_last_exception(env, &error) == napi_ok) {
            napi_reject_deferred(env, deferred, error);
            return;
        }
        if (napi_get_null(env, &result) != napi_ok) {
            return;
        }
    }
    napi_resolve_deferred(env, deferred, result);
}

template<typename Work>
bool QueueWork(napi_env env, std::unique_ptr<Work>& work, const char* name,
               napi_async_execute_callback execute, napi_async_complete_callback complete)
{
    napi_value resource;
    if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, execute, complete, work.get(), &work->work) != napi_ok) {
        return false;
    }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        return false;
    }
    work.release();
    return true;
}

void DisposeDecoder(napi_env env, Decoder decoder)
{
    if (!decoder) {
        return;
    }
    std::unique_ptr<CloseWork> work(new (std::nothrow) CloseWork);
    if (!work) {
        return;
    }
    work->decoder = std::move(decoder);
    QueueWork(env, work, "Nuwa AVIF animation close", [](napi_env, void* data) {
        static_cast<CloseWork*>(data)->decoder.reset();
    }, [](napi_env env, napi_status, void* data) {
        std::unique_ptr<CloseWork> work(static_cast<CloseWork*>(data));
        napi_delete_async_work(env, work->work);
    });
}

void CompleteDecode(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<DecodeWork> work(static_cast<DecodeWork*>(data));
    napi_value frame = nullptr;
    if (status == napi_ok && work->frame.pixels) {
        frame = CreateFrame(env, work->frame);
    }
    ResolveDecode(env, work->deferred, frame);
    napi_delete_async_work(env, work->work);
}

void FinalizeAnimation(napi_env, void* data, void*)
{
    delete static_cast<Animation*>(data);
}

napi_value CreateAnimation(napi_env env, Decoder& decoder)
{
    std::unique_ptr<Animation> animation(new (std::nothrow) Animation);
    if (!animation) {
        return nullptr;
    }
    animation->frameCount = static_cast<uint32_t>(decoder->imageCount);
    const uint32_t playCount = decoder->repetitionCount < 0 ? 0 : static_cast<uint32_t>(decoder->repetitionCount) + 1;
    napi_value handle;
    napi_value frameCountValue;
    napi_value playCountValue;
    if (napi_create_object(env, &handle) != napi_ok ||
        napi_create_uint32(env, animation->frameCount, &frameCountValue) != napi_ok ||
        napi_create_uint32(env, playCount, &playCountValue) != napi_ok) {
        return nullptr;
    }
    const napi_property_descriptor properties[] = {
        {"frameCount", nullptr, nullptr, nullptr, nullptr, frameCountValue, napi_enumerable, nullptr},
        {"playCount", nullptr, nullptr, nullptr, nullptr, playCountValue, napi_enumerable, nullptr},
    };
    if (napi_define_properties(env, handle, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok ||
        napi_type_tag_object(env, handle, &ANIMATION_TYPE_TAG) != napi_ok ||
        napi_wrap(env, handle, animation.get(), FinalizeAnimation, nullptr, nullptr) != napi_ok) {
        return nullptr;
    }
    animation->decoder = std::move(decoder);
    animation.release();
    return handle;
}

void CompleteOpenAnimation(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<DecodeWork> work(static_cast<DecodeWork*>(data));
    napi_value animation = nullptr;
    if (status == napi_ok && work->decoder) {
        animation = CreateAnimation(env, work->decoder);
    }
    ResolveDecode(env, work->deferred, animation);
    napi_delete_async_work(env, work->work);
}

Animation* GetAnimation(napi_env env, napi_value handle)
{
    bool tagged = false;
    void* animation = nullptr;
    if (napi_check_object_type_tag(env, handle, &ANIMATION_TYPE_TAG, &tagged) != napi_ok || !tagged ||
        napi_unwrap(env, handle, &animation) != napi_ok) {
        return nullptr;
    }
    return static_cast<Animation*>(animation);
}

void CompleteReadFrame(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<ReadFrameWork> work(static_cast<ReadFrameWork*>(data));
    napi_value frame = nullptr;
    if (status == napi_ok && !work->animation->closed && work->frame.pixels) {
        frame = CreateFrame(env, work->frame, work->durationMs);
        if (frame) {
            work->animation->decoder = std::move(work->decoder);
        }
    }
    ResolveDecode(env, work->deferred, frame);
    napi_delete_reference(env, work->animationRef);
    napi_delete_async_work(env, work->work);
    DisposeDecoder(env, std::move(work->decoder));
}

napi_value QueueDecodePath(napi_env env, napi_callback_info info, const char* name,
                           napi_async_execute_callback execute, napi_async_complete_callback complete)
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
    if (!QueueWork(env, work, name, execute, complete)) {
        ResolveDecode(env, deferred);
    }
    return promise;
}

napi_value DecodeAvif(napi_env env, napi_callback_info info)
{
    return QueueDecodePath(env, info, "Nuwa AVIF decode", Decode, CompleteDecode);
}

napi_value OpenAvifAnimation(napi_env env, napi_callback_info info)
{
    return QueueDecodePath(env, info, "Nuwa AVIF animation open", OpenAnimation, CompleteOpenAnimation);
}

napi_value ReadAvifAnimationFrame(napi_env env, napi_callback_info info)
{
    napi_deferred deferred;
    napi_value promise;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Cannot create AVIF frame promise");
        return nullptr;
    }

    size_t argc = 2;
    napi_value args[2];
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        ResolveDecode(env, deferred);
        return promise;
    }
    auto* animation = GetAnimation(env, args[0]);
    double index;
    if (!animation || !animation->decoder || napi_get_value_double(env, args[1], &index) != napi_ok ||
        !(index >= 0 && index < animation->frameCount) || index != static_cast<uint32_t>(index)) {
        ResolveDecode(env, deferred);
        return promise;
    }

    std::unique_ptr<ReadFrameWork> work(new (std::nothrow) ReadFrameWork);
    if (!work || napi_create_reference(env, args[0], 1, &work->animationRef) != napi_ok) {
        ResolveDecode(env, deferred);
        return promise;
    }
    // Moving the decoder into the worker prevents overlapping reads. The JS reference keeps the handle alive.
    work->decoder = std::move(animation->decoder);
    work->animation = animation;
    work->index = static_cast<uint32_t>(index);
    work->deferred = deferred;
    if (!QueueWork(env, work, "Nuwa AVIF frame read", ReadFrame, CompleteReadFrame)) {
        animation->decoder = std::move(work->decoder);
        napi_delete_reference(env, work->animationRef);
        ResolveDecode(env, deferred);
    }
    return promise;
}

napi_value CloseAvifAnimation(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value handle;
    if (napi_get_cb_info(env, info, &argc, &handle, nullptr, nullptr) == napi_ok && argc == 1) {
        auto* animation = GetAnimation(env, handle);
        if (animation) {
            animation->closed = true;
            DisposeDecoder(env, std::move(animation->decoder));
        }
    }
    napi_value result;
    return napi_get_undefined(env, &result) == napi_ok ? result : nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor methods[] = {
        {"decodeAvif", nullptr, DecodeAvif, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openAvifAnimation", nullptr, OpenAvifAnimation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readAvifAnimationFrame", nullptr, ReadAvifAnimationFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeAvifAnimation", nullptr, CloseAvifAnimation, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    return napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods) == napi_ok ? exports : nullptr;
}

napi_module module = {NAPI_MODULE_VERSION, 0, nullptr, Init, "nuwa_avif", nullptr, {nullptr}};

__attribute__((constructor)) void RegisterNuwaAvif()
{
    napi_module_register(&module);
}

} // namespace
