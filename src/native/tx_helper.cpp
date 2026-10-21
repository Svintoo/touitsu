// Architecture-matched Textractor host. Its private IPC never carries native pointers.
#include "tx_protocol.h"
#include <shellapi.h>
#include <mutex>
#include <atomic>
#include <cstdlib>

namespace {
HANDLE pipe = INVALID_HANDLE_VALUE;
std::mutex output_mutex;
std::atomic<bool> exiting{false};
void send(txipc::Kind kind, const txipc::Writer& w, uint32_t request = 0) {
    std::lock_guard<std::mutex> lock(output_mutex);
    if (!txipc::send(pipe, kind, request, w)) exiting.store(true);
}
void connected(void*, uint32_t pid) { txipc::Writer w; w.u32(pid); send(txipc::connected, w); }
void disconnected(void*, uint32_t pid) { txipc::Writer w; w.u32(pid); send(txipc::disconnected, w); }
void created(void*, const tx_thread_info* info) { if (!info->pid) return; txipc::Writer w; w.info(*info); send(txipc::created, w); }
void destroyed(void*, const tx_thread_info* info) { if (!info->pid) return; txipc::Writer w; w.info(*info); send(txipc::destroyed, w); }
void output(void*, const tx_thread_info* info, const wchar_t* text, size_t length) {
    if (!info->pid) return;
    txipc::Writer w; w.info(*info); w.wide({text, length}); send(txipc::output, w);
}
void found(void*, uint32_t pid, const wchar_t* code, const wchar_t* text, size_t length) {
    txipc::Writer w; w.u32(pid); w.wide(code); w.wide({text, length}); send(txipc::found, w);
}
void error(void*, uint32_t pid, const wchar_t* message) { txipc::Writer w; w.u32(pid); w.wide(message); send(txipc::error, w); }
}
int main() {
    static_assert(sizeof(void*) == 4, "The helper must be built for x86");
    int argc = 0;
    auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 2) return 2;
    pipe = CreateFileW(argv[1], GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    LocalFree(argv);
    if (pipe == INVALID_HANDLE_VALUE) return 3;
    tx_set_error_callback(nullptr, error);
    tx_set_find_callback(nullptr, found);
    tx_start(nullptr, connected, disconnected, created, destroyed, output);
    txipc::Writer greeting; greeting.u32(32); send(txipc::hello, greeting);
    txipc::Header h{};
    std::vector<uint8_t> payload;
    bool clean = false;
    try {
        while (!exiting.load() && txipc::receive(pipe, h, payload)) {
            txipc::Reader r{payload};
            bool ok = false;
            uint32_t value = 0;
            if (h.kind == txipc::attach || h.kind == txipc::detach) {
                const auto pid = r.u32(); if (!r.done()) break;
                ok = h.kind == txipc::attach ? tx_attach(pid) : tx_detach(pid);
            } else if (h.kind == txipc::insert) {
                const auto pid = r.u32(); const auto code = r.wide(); if (!r.done()) break;
                ok = tx_insert_hook(pid, code.c_str());
            } else if (h.kind == txipc::remove) {
                const auto pid = r.u32(); const auto address = r.u64(); if (!r.done()) break;
                ok = tx_remove_hook(pid, address);
            } else if (h.kind == txipc::find) {
                const auto pid = r.u32(), cp = r.u32(); const auto text = r.wide(); if (!r.done()) break;
                ok = tx_find_hooks(pid, cp, text.empty() ? nullptr : text.c_str());
            } else if (h.kind == txipc::ping) {
                if (!r.done()) break; ok = true; value = 32;
            } else if (h.kind == txipc::shutdown) {
                const auto timeout = r.u32(); if (!r.done()) break;
                value = tx_shutdown(std::min(timeout, 10000u)); ok = true; clean = true;
            } else break;
            txipc::Writer reply; reply.u32(ok ? 1 : 0); reply.u32(value); send(txipc::ack, reply, h.request);
            if (clean) break;
        }
    } catch (...) {}
    if (!clean) tx_shutdown(2000);
    exiting.store(true);
    CloseHandle(pipe);
    // Host pipe threads have process lifetime; avoid static-destructor races.
    ExitProcess(clean ? 0 : 1);
}
