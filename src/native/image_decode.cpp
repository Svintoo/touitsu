// Windows Imaging Component decodes local images to the RGBA pixels Knots accepts.
#define INITGUID
#include <windows.h>
#include <wincodec.h>
#include <cstdint>
#include <cstdlib>

extern "C" int touitsu_image_load(const uint16_t* path, unsigned char** pixels,
                                  uint32_t* width, uint32_t* height) {
    *pixels = nullptr;
    *width = *height = 0;
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool uninitialize = SUCCEEDED(apartment);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return 1;
    IWICImagingFactory* factory = nullptr;
    IWICBitmapDecoder* decoder = nullptr;
    IWICBitmapFrameDecode* frame = nullptr;
    IWICFormatConverter* converter = nullptr;
    unsigned char* data = nullptr;
    UINT w = 0, h = 0;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_IWICImagingFactory, reinterpret_cast<void**>(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromFilename(
        reinterpret_cast<const wchar_t*>(path), nullptr, GENERIC_READ,
        WICDecodeMetadataCacheOnDemand, &decoder);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr)) hr = frame->GetSize(&w, &h);
    if (SUCCEEDED(hr) && (w == 0 || h == 0 || w > 8192 || h > 8192 ||
                          static_cast<uint64_t>(w) * h > 32ull * 1024 * 1024)) hr = E_INVALIDARG;
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) hr = converter->Initialize(frame, GUID_WICPixelFormat32bppRGBA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr)) {
        data = static_cast<unsigned char*>(std::malloc(static_cast<size_t>(w) * h * 4));
        if (!data) hr = E_OUTOFMEMORY;
    }
    if (SUCCEEDED(hr)) hr = converter->CopyPixels(nullptr, w * 4, w * h * 4, data);
    if (converter) converter->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    if (factory) factory->Release();
    if (uninitialize) CoUninitialize();
    if (FAILED(hr)) { std::free(data); return 1; }
    *pixels = data;
    *width = w;
    *height = h;
    return 0;
}
extern "C" void touitsu_image_free(unsigned char* pixels) { std::free(pixels); }
#include <d3d11.h>
#include <d2d1_3.h>
#include <d2d1svg.h>
#include <algorithm>
#include <cmath>
#include <cstring>

template<class T> struct LocalCom {
    T* p = nullptr;
    ~LocalCom() { if (p) p->Release(); }
    T* operator->() const { return p; }
};

static HRESULT decodeRasterBytes(const unsigned char* bytes, uint32_t size,
                                 unsigned char** pixels, uint32_t* width, uint32_t* height) {
    LocalCom<IWICImagingFactory> factory;
    LocalCom<IWICStream> stream;
    LocalCom<IWICBitmapDecoder> decoder;
    LocalCom<IWICBitmapFrameDecode> frame;
    LocalCom<IWICBitmapScaler> scaler;
    LocalCom<IWICFormatConverter> converter;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_IWICImagingFactory, reinterpret_cast<void**>(&factory.p));
    if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream.p);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromMemory(const_cast<BYTE*>(bytes), size);
    if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromStream(stream.p, nullptr, WICDecodeMetadataCacheOnDemand, &decoder.p);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame.p);
    UINT w = 0, h = 0;
    if (SUCCEEDED(hr)) hr = frame->GetSize(&w, &h);
    if (FAILED(hr) || !w || !h || w > 32768 || h > 32768) return E_INVALIDARG;
    const double factor = std::min(1.0, 1024.0 / std::max(w, h));
    const UINT outW = std::max(1u, static_cast<UINT>(std::ceil(w * factor)));
    const UINT outH = std::max(1u, static_cast<UINT>(std::ceil(h * factor)));
    hr = factory->CreateBitmapScaler(&scaler.p);
    if (SUCCEEDED(hr)) hr = scaler->Initialize(frame.p, outW, outH, WICBitmapInterpolationModeFant);
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter.p);
    if (SUCCEEDED(hr)) hr = converter->Initialize(scaler.p, GUID_WICPixelFormat32bppRGBA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) return hr;
    auto data = static_cast<unsigned char*>(std::malloc(static_cast<size_t>(outW) * outH * 4));
    if (!data) return E_OUTOFMEMORY;
    hr = converter->CopyPixels(nullptr, outW * 4, outW * outH * 4, data);
    if (FAILED(hr)) { std::free(data); return hr; }
    *pixels = data; *width = outW; *height = outH;
    return S_OK;
}

static HRESULT decodeSvgBytes(const unsigned char* bytes, uint32_t size,
                              unsigned char** pixels, uint32_t* width, uint32_t* height) {
    LocalCom<ID3D11Device> d3d;
    LocalCom<IDXGIDevice> dxgi;
    LocalCom<ID2D1Factory1> factory;
    LocalCom<ID2D1Device> device;
    LocalCom<ID2D1DeviceContext> context;
    LocalCom<ID2D1DeviceContext5> svgContext;
    LocalCom<IStream> stream;
    LocalCom<ID2D1SvgDocument> document;
    LocalCom<ID2D1SvgElement> root;
    LocalCom<ID2D1Bitmap1> target;
    LocalCom<ID2D1Bitmap1> staging;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &d3d.p, nullptr, nullptr);
    if (SUCCEEDED(hr)) hr = d3d->QueryInterface(IID_IDXGIDevice, reinterpret_cast<void**>(&dxgi.p));
    D2D1_FACTORY_OPTIONS options = {};
    if (SUCCEEDED(hr)) hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
        IID_ID2D1Factory1, &options, reinterpret_cast<void**>(&factory.p));
    if (SUCCEEDED(hr)) hr = factory->CreateDevice(dxgi.p, &device.p);
    if (SUCCEEDED(hr)) hr = device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context.p);
    if (SUCCEEDED(hr)) hr = context->QueryInterface(IID_ID2D1DeviceContext5, reinterpret_cast<void**>(&svgContext.p));
    if (FAILED(hr)) return hr;
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!memory) return E_OUTOFMEMORY;
    void* dest = GlobalLock(memory);
    if (!dest) { GlobalFree(memory); return E_OUTOFMEMORY; }
    std::memcpy(dest, bytes, size);
    GlobalUnlock(memory);
    hr = CreateStreamOnHGlobal(memory, TRUE, &stream.p);
    if (FAILED(hr)) { GlobalFree(memory); return hr; }
    hr = svgContext->CreateSvgDocument(stream.p, D2D1::SizeF(512, 512), &document.p);
    if (FAILED(hr)) return hr;
    document->GetRoot(&root.p);
    float w = 512, h = 512;
    D2D1_SVG_VIEWBOX box = {};
    if (root.p && SUCCEEDED(root->GetAttributeValue(L"viewBox", D2D1_SVG_ATTRIBUTE_POD_TYPE_VIEWBOX, &box, sizeof(box))) && box.width > 0 && box.height > 0) {
        w = box.width; h = box.height;
    } else if (root.p) {
        D2D1_SVG_LENGTH x = {}, y = {};
        if (SUCCEEDED(root->GetAttributeValue(L"width", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &x, sizeof(x))) && x.value > 0) w = x.value;
        if (SUCCEEDED(root->GetAttributeValue(L"height", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &y, sizeof(y))) && y.value > 0) h = y.value;
    }
    if (!std::isfinite(w) || !std::isfinite(h) || w <= 0 || h <= 0) return E_INVALIDARG;
    const float factor = 512.0f / std::max(w, h);
    const UINT outW = std::max(1u, static_cast<UINT>(std::ceil(w * factor)));
    const UINT outH = std::max(1u, static_cast<UINT>(std::ceil(h * factor)));
    hr = document->SetViewportSize(D2D1::SizeF(static_cast<float>(outW), static_cast<float>(outH)));
    auto props = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
    if (SUCCEEDED(hr)) hr = context->CreateBitmap(D2D1::SizeU(outW, outH), nullptr, 0, &props, &target.p);
    if (FAILED(hr)) return hr;
    context->SetTarget(target.p);
    context->BeginDraw();
    context->Clear(D2D1::ColorF(0, 0));
    svgContext->DrawSvgDocument(document.p);
    hr = context->EndDraw();
    context->SetTarget(nullptr);
    props.bitmapOptions = static_cast<D2D1_BITMAP_OPTIONS>(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW);
    if (SUCCEEDED(hr)) hr = context->CreateBitmap(D2D1::SizeU(outW, outH), nullptr, 0, &props, &staging.p);
    if (SUCCEEDED(hr)) hr = staging->CopyFromBitmap(nullptr, target.p, nullptr);
    D2D1_MAPPED_RECT mapped = {};
    if (SUCCEEDED(hr)) hr = staging->Map(D2D1_MAP_OPTIONS_READ, &mapped);
    if (FAILED(hr)) return hr;
    auto data = static_cast<unsigned char*>(std::malloc(static_cast<size_t>(outW) * outH * 4));
    if (!data) { staging->Unmap(); return E_OUTOFMEMORY; }
    for (UINT y = 0; y < outH; ++y) {
        const BYTE* src = mapped.bits + y * mapped.pitch;
        BYTE* dst = data + y * outW * 4;
        for (UINT x = 0; x < outW; ++x) {
            const unsigned a = src[x * 4 + 3];
            dst[x * 4] = a ? static_cast<BYTE>(std::min(255u, (src[x * 4 + 2] * 255u + a / 2) / a)) : 0;
            dst[x * 4 + 1] = a ? static_cast<BYTE>(std::min(255u, (src[x * 4 + 1] * 255u + a / 2) / a)) : 0;
            dst[x * 4 + 2] = a ? static_cast<BYTE>(std::min(255u, (src[x * 4] * 255u + a / 2) / a)) : 0;
            dst[x * 4 + 3] = static_cast<BYTE>(a);
        }
    }
    staging->Unmap();
    *pixels = data; *width = outW; *height = outH;
    return S_OK;
}

extern "C" int touitsu_image_memory(const unsigned char* bytes, uint32_t size, int svg,
                                    unsigned char** pixels, uint32_t* width, uint32_t* height) {
    *pixels = nullptr; *width = *height = 0;
    if (!bytes || !size || size > 64u * 1024 * 1024) return 1;
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return 1;
    const HRESULT hr = svg ? decodeSvgBytes(bytes, size, pixels, width, height)
                           : decodeRasterBytes(bytes, size, pixels, width, height);
    if (SUCCEEDED(apartment)) CoUninitialize();
    return FAILED(hr) ? 1 : 0;
}
