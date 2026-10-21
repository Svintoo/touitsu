#include "tx_protocol.h"
#include <shellapi.h>
#include <tlhelp32.h>
#include <cstdio>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <set>
#include <stdexcept>

namespace {
std::mutex state;
std::condition_variable changed;
std::set<uint32_t> connections;
uint32_t pid32 = 0, pid64 = 0;
bool text32 = false, text64 = false;
uint64_t address32 = 0, address64 = 0;
size_t found32 = 0, found64 = 0;
void found(void*, uint32_t pid, const wchar_t*, const wchar_t*, size_t) {
    { std::lock_guard<std::mutex> lock(state); if (pid == pid32) ++found32; if (pid == pid64) ++found64; }
    changed.notify_all();
}
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void connect(void*, uint32_t pid) { std::fprintf(stderr, "connected %u\n", pid); { std::lock_guard<std::mutex> lock(state); connections.insert(pid); } changed.notify_all(); }
void disconnect(void*, uint32_t pid) { { std::lock_guard<std::mutex> lock(state); connections.erase(pid); } changed.notify_all(); }
void thread(void*, const tx_thread_info* info) { if (info->pid) std::fwprintf(stderr, L"thread %u: %ls [%ls]\n", info->pid, info->name, info->hook_code); }
void output(void*, const tx_thread_info* info, const wchar_t* text, size_t length) {
    const std::wstring value(text, length);
    if (info->pid == 0 && wcscmp(info->name, L"Console") == 0 && value.find(L"search") != std::wstring::npos)
        std::fwprintf(stderr, L"[search] %ls\n", value.c_str());
    { std::lock_guard<std::mutex> lock(state);
        if (info->pid == pid32 && value.find(L"TOUITSU_X86 日本語") != std::wstring::npos) text32 = true;
        if (info->pid == pid64 && value.find(L"TOUITSU_X64 日本語") != std::wstring::npos) text64 = true;
        if (info->pid == pid32 && text32) address32 = info->addr;
        if (info->pid == pid64 && text64) address64 = info->addr;
    }
    changed.notify_all();
}
void error(void*, uint32_t pid, const wchar_t* message) { std::fwprintf(stderr, L"[backend %u] %ls\n", pid, message); }
template<class F> bool wait(F&& predicate, int seconds = 12) {
    std::unique_lock<std::mutex> lock(state);
    return changed.wait_for(lock, std::chrono::seconds(seconds), predicate);
}
struct Fixture {
    PROCESS_INFORMATION process{};
    explicit Fixture(const wchar_t* path) {
        std::wstring command = L"\"" + std::wstring(path) + L"\"";
        STARTUPINFOW startup{}; startup.cb = sizeof(startup);
        require(CreateProcessW(path, command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process), "could not start owned hook fixture");
        CloseHandle(process.hThread); process.hThread = nullptr;
    }
    void stop() { if (process.hProcess) { TerminateProcess(process.hProcess, 0); WaitForSingleObject(process.hProcess, 2000); CloseHandle(process.hProcess); process.hProcess = nullptr; } }
    ~Fixture() { stop(); }
};
HANDLE helperProcess() {
    const auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
    HANDLE result = nullptr;
    if (Process32FirstW(snapshot, &entry)) do {
        if (entry.th32ParentProcessID == GetCurrentProcessId() && _wcsicmp(entry.szExeFile, L"tx_helper.exe") == 0) {
            result = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, entry.th32ProcessID); break;
        }
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot); return result;
}
void protocolChecks() {
    txipc::Writer w; w.u64(0xfedcba9876543210ull); w.wide(L"日本語");
    txipc::Reader r{w.data};
    require(r.u64() == 0xfedcba9876543210ull && r.wide() == L"日本語" && r.done(), "wire-format round trip failed");
    w.data.pop_back(); txipc::Reader short_read{w.data}; short_read.u64(); short_read.wide();
    require(!short_read.done(), "truncated UTF-16 payload accepted");
    txipc::Writer huge; huge.wide(std::wstring(txipc::max_payload, L'x'));
    require(!huge.valid, "oversized IPC payload accepted");
}
}
int main() {
    try {
        protocolChecks();
        int argc = 0; auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        require(argv && argc == 3, "expected x86 and x64 fixture paths");
        Fixture x86(argv[1]), x64(argv[2]); LocalFree(argv);
        pid32 = x86.process.dwProcessId; pid64 = x64.process.dwProcessId;
        tx_set_error_callback(nullptr, error);
        tx_start(nullptr, connect, disconnect, thread, thread, output);
        tx_set_find_callback(nullptr, found);
        require(tx_probe_x86(), "x86 helper handshake failed");
        require(tx_attach(pid32) && tx_attach(pid64), "dual-architecture attach command failed");
        require(wait([] { return connections.count(pid32) && connections.count(pid64); }), "fixtures did not connect to their matching hosts");
        // One-character search text returns immediately inside Textractor; this
        // checks architecture/codepage/text routing without a lengthy hook scan.
        require(tx_find_hooks(pid32, 932, L"x") && tx_find_hooks(pid64, 65001, L"x"), "hook-search command routing failed");
        require(!tx_insert_hook(pid32, L"invalid") && !tx_insert_hook(pid64, L"invalid"), "invalid hook codes accepted");
        require(tx_insert_hook(pid32, L"HQN4@0:tx_fixture_x86.exe:fixture_text"), "x86 hook insertion failed");
        require(tx_insert_hook(pid64, L"HQN-1C@0:tx_fixture_x64.exe:fixture_text"), "x64 hook insertion failed");
        require(wait([] { return text32 && text64; }), "did not receive both x86 and x64 UTF-16 text streams");
        std::fprintf(stderr, "PASS: concurrent x86/x64 injection, hook insertion, Unicode output and IPC validation\n");
        require(tx_find_hooks(pid32, 932, nullptr) && tx_find_hooks(pid64, 65001, nullptr), "generic hook searches did not start");
        if (!wait([] { return found32 && found64; }, 60)) {
            std::fprintf(stderr, "search results: x86=%zu x64=%zu; target wait states %lu/%lu\n", found32, found64, WaitForSingleObject(x86.process.hProcess, 0), WaitForSingleObject(x64.process.hProcess, 0));
            require(false, "generic searches did not produce both x86 and x64 candidates");
        }
        // Results are sent after teardown. Both targets and the hooks installed
        // before the search must still work; a command acknowledgement is insufficient.
        Sleep(1500);
        { std::lock_guard<std::mutex> lock(state); text32 = text64 = false; }
        require(wait([] { return text32 && text64; }), "existing hooks stopped after generic search cleanup");
        require(WaitForSingleObject(x86.process.hProcess, 0) == WAIT_TIMEOUT && WaitForSingleObject(x64.process.hProcess, 0) == WAIT_TIMEOUT, "a fixture crashed at search completion");
        require(tx_remove_hook(pid32, address32) && tx_remove_hook(pid64, address64), "hook removal failed");
        Sleep(1500);
        { std::lock_guard<std::mutex> lock(state); text32 = text64 = false; }
        require(!wait([] { return text32 || text64; }, 2), "removed hooks continued output");
        require(tx_insert_hook(pid32, L"HQN4@0:tx_fixture_x86.exe:fixture_text") && tx_insert_hook(pid64, L"HQN-1C@0:tx_fixture_x64.exe:fixture_text"), "hook reinsertion after removal failed");
        require(wait([] { return text32 && text64; }), "hooks did not resume after reinsertion");
        std::fprintf(stderr, "PASS: x86/x64 generic search completion preserves targets and existing hooks; remove/reinsert works\n");
        HANDLE helper = helperProcess();
        require(helper != nullptr, "managed helper not found");
        TerminateProcess(helper, 99); WaitForSingleObject(helper, 2000); CloseHandle(helper);
        require(wait([] { return !connections.count(pid32); }), "helper failure did not clear x86 attachment");
        { std::lock_guard<std::mutex> lock(state); require(connections.count(pid64) != 0, "helper failure disconnected the x64 backend"); text64 = false; }
        require(wait([] { return text64; }), "x64 output stopped after helper failure");
        Sleep(500);
        require(tx_probe_x86(), "helper could not restart after failure");
        require(tx_attach(pid32), "x86 reattach command failed");
        require(wait([] { return connections.count(pid32) != 0; }), "x86 fixture could not reconnect after helper restart");
        { std::lock_guard<std::mutex> lock(state); text32 = false; }
        require(tx_insert_hook(pid32, L"HQN4@0:tx_fixture_x86.exe:fixture_text"), "x86 reinsertion failed");
        require(wait([] { return text32; }), "x86 output did not recover");
        require(tx_detach(pid32), "x86 manual detach command failed");
        require(wait([] { return !connections.count(pid32); }), "x86 manual detach was not confirmed");
        require(tx_shutdown(5000) == 0, "shutdown left pending connections");
        require(helperProcess() == nullptr, "helper process survived shutdown");
        x86.stop(); x64.stop();
        std::fprintf(stderr, "PASS: helper failure isolation, restart, reattach and confirmed shutdown\n");
        ExitProcess(0);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "FAIL: %s\n", e.what());
        tx_shutdown(2000);
        ExitProcess(1);
    }
}
