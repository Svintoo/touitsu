#pragma once
#include <windows.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>
#include <algorithm>
#include "tx_api.h"

// Only fixed-width integers and counted UTF-16 strings cross architecture boundaries.
namespace txipc {
constexpr uint32_t magic = 0x31585454, version = 1, max_payload = 1024 * 1024;
enum Kind : uint32_t { hello = 1, ack, connected, disconnected, created, destroyed, output, found, error,
    attach = 20, detach, insert, find, shutdown, ping, remove };
struct Header { uint32_t magic, version, kind, length, request; };
static_assert(sizeof(Header) == 20);
struct Writer {
    std::vector<uint8_t> data;
    bool valid = true;
    template<class T> void integer(T n) {
        if (data.size() + sizeof(n) > max_payload) { valid = false; return; }
        const auto* p = reinterpret_cast<const uint8_t*>(&n);
        data.insert(data.end(), p, p + sizeof(n));
    }
    void u32(uint32_t n) { integer(n); }
    void u64(uint64_t n) { integer(n); }
    void wide(std::wstring_view s) {
        if (s.size() > (max_payload - 4) / 2 || data.size() + 4 + s.size() * 2 > max_payload) { valid = false; return; }
        u32(static_cast<uint32_t>(s.size()));
        const auto* p = reinterpret_cast<const uint8_t*>(s.data());
        if (!s.empty()) data.insert(data.end(), p, p + s.size() * 2);
    }
    void info(const tx_thread_info& i) { u64(i.handle); u32(i.pid); u64(i.addr); u64(i.ctx); u64(i.ctx2); wide(i.name); wide(i.hook_code); }
};
struct Reader {
    const std::vector<uint8_t>& data;
    size_t at = 0;
    bool valid = true;
    template<class T> T integer() {
        T n{};
        if (at > data.size() || data.size() - at < sizeof(n)) { valid = false; return n; }
        std::memcpy(&n, data.data() + at, sizeof(n)); at += sizeof(n); return n;
    }
    uint32_t u32() { return integer<uint32_t>(); }
    uint64_t u64() { return integer<uint64_t>(); }
    std::wstring wide() {
        const auto count = u32();
        if (!valid || at > data.size() || count > (data.size() - at) / 2) { valid = false; return {}; }
        std::wstring out(count, L'\0');
        if (count) std::memcpy(out.data(), data.data() + at, count * 2);
        at += count * 2; return out;
    }
    bool done() const { return valid && at == data.size(); }
    tx_thread_info info(std::wstring& name, std::wstring& code) {
        tx_thread_info i{};
        i.handle = u64(); i.pid = u32(); i.addr = u64(); i.ctx = u64(); i.ctx2 = u64();
        name = wide(); code = wide(); i.name = name.c_str(); i.hook_code = code.c_str(); return i;
    }
};
// All pipe handles are opened OVERLAPPED. Cancellation completes before local
// buffers/events go away; a dead/hung helper cannot block a UI write forever.
inline bool transfer(HANDLE pipe, void* data, uint32_t size, bool writing, DWORD timeout, HANDLE cancel = nullptr) {
    auto* p = static_cast<uint8_t*>(data);
    while (size) {
        if (cancel && WaitForSingleObject(cancel, 0) == WAIT_OBJECT_0) return false;
        OVERLAPPED ov{};
        ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!ov.hEvent) return false;
        DWORD count = 0;
        BOOL ok = writing ? WriteFile(pipe, p, size, &count, &ov) : ReadFile(pipe, p, size, &count, &ov);
        if (!ok && GetLastError() == ERROR_IO_PENDING) {
            HANDLE waits[] = {ov.hEvent, cancel};
            const auto wait = cancel ? WaitForMultipleObjects(2, waits, FALSE, timeout) : WaitForSingleObject(ov.hEvent, timeout);
            if (wait == WAIT_OBJECT_0) ok = GetOverlappedResult(pipe, &ov, &count, FALSE);
            else {
                CancelIoEx(pipe, &ov);
                GetOverlappedResult(pipe, &ov, &count, TRUE);
                ok = FALSE;
            }
        }
        CloseHandle(ov.hEvent);
        if (!ok || count == 0 || count > size) return false;
        p += count; size -= count;
    }
    return true;
}
inline bool send(HANDLE pipe, Kind kind, uint32_t request, const Writer& payload) {
    if (!payload.valid || payload.data.size() > max_payload) return false;
    Header h{magic, version, kind, static_cast<uint32_t>(payload.data.size()), request};
    return transfer(pipe, &h, sizeof(h), true, 2000) &&
        transfer(pipe, const_cast<uint8_t*>(payload.data.data()), h.length, true, 2000);
}
inline bool receive(HANDLE pipe, Header& h, std::vector<uint8_t>& payload, HANDLE cancel = nullptr) {
    if (!transfer(pipe, &h, sizeof(h), false, INFINITE, cancel)) return false;
    if (h.magic != magic || h.version != version || h.length > max_payload) return false;
    payload.resize(h.length);
    return transfer(pipe, payload.data(), h.length, false, INFINITE, cancel);
}
}
