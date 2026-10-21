// The 64-bit host routes x86 commands through one private, job-owned helper.
#include "tx_bridge.h"
#include "tx_protocol.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <set>
#include <thread>

namespace txbridge {
namespace {
void* user = nullptr;
void* found_user = nullptr;
tx_process_cb on_connect = nullptr, on_disconnect = nullptr;
tx_thread_cb on_create = nullptr, on_destroy = nullptr;
tx_output_cb on_output = nullptr;
tx_found_cb on_found = nullptr;
std::mutex manager_mutex;
std::atomic<bool> stopping{false};

struct Session {
    HANDLE pipe = INVALID_HANDLE_VALUE, process = nullptr, job = nullptr, stop_event = nullptr;
    std::thread reader;
    std::mutex state_mutex, call_mutex;
    std::condition_variable changed;
    bool alive = false, ready = false, closing = false, replied = false, reply_ok = false;
    uint32_t next_request = 0, awaited = 0, reply_value = 0;
    std::set<uint32_t> targets;
    ~Session() { close(); }

    void failed(const wchar_t* message) {
        std::vector<uint32_t> disconnected;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            if (!alive) return;
            alive = false; ready = false;
            if (!closing) disconnected.assign(targets.begin(), targets.end());
            targets.clear();
        }
        changed.notify_all();
        for (auto pid : disconnected) {
            if (on_disconnect) on_disconnect(user, pid);
            tx_report_error(pid, message);
        }
    }
    bool isAlive() { std::lock_guard<std::mutex> lock(state_mutex); return alive && ready; }
    bool has(uint32_t pid) { std::lock_guard<std::mutex> lock(state_mutex); return targets.count(pid) != 0; }
    void close() {
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            closing = true; alive = false; ready = false;
        }
        changed.notify_all();
        if (stop_event) SetEvent(stop_event);
        if (pipe != INVALID_HANDLE_VALUE) CancelIoEx(pipe, nullptr);
        if (reader.joinable()) reader.join();
        if (pipe != INVALID_HANDLE_VALUE) { DisconnectNamedPipe(pipe); CloseHandle(pipe); pipe = INVALID_HANDLE_VALUE; }
        if (process) {
            if (WaitForSingleObject(process, 1000) != WAIT_OBJECT_0) TerminateProcess(process, 1);
            WaitForSingleObject(process, 2000);
            CloseHandle(process); process = nullptr;
        }
        if (job) { CloseHandle(job); job = nullptr; }
        if (stop_event) { CloseHandle(stop_event); stop_event = nullptr; }
    }
    void readLoop() {
        txipc::Header h{};
        std::vector<uint8_t> payload;
        try {
            while (txipc::receive(pipe, h, payload, stop_event)) {
                txipc::Reader r{payload};
                if (h.kind == txipc::hello) {
                    const auto bits = r.u32();
                    if (!r.done() || bits != 32) break;
                    { std::lock_guard<std::mutex> lock(state_mutex); ready = true; }
                    changed.notify_all();
                } else if (h.kind == txipc::ack) {
                    const auto ok = r.u32(), value = r.u32();
                    if (!r.done()) break;
                    {
                        std::lock_guard<std::mutex> lock(state_mutex);
                        if (h.request == awaited) { replied = true; reply_ok = ok != 0; reply_value = value; }
                    }
                    changed.notify_all();
                } else if (h.kind == txipc::connected || h.kind == txipc::disconnected) {
                    const auto pid = r.u32();
                    if (!r.done()) break;
                    if (h.kind == txipc::connected) {
                        { std::lock_guard<std::mutex> lock(state_mutex); targets.insert(pid); }
                        if (on_connect) on_connect(user, pid);
                    } else {
                        { std::lock_guard<std::mutex> lock(state_mutex); targets.erase(pid); }
                        if (on_disconnect) on_disconnect(user, pid);
                    }
                } else if (h.kind == txipc::created || h.kind == txipc::destroyed || h.kind == txipc::output) {
                    std::wstring name, code;
                    const auto info = r.info(name, code);
                    const auto text = h.kind == txipc::output ? r.wide() : std::wstring{};
                    if (!r.done()) break;
                    // The x64 host supplies Console/Clipboard; do not duplicate helper built-ins.
                    if (info.pid == 0) continue;
                    if (h.kind == txipc::created && on_create) on_create(user, &info);
                    if (h.kind == txipc::destroyed && on_destroy) on_destroy(user, &info);
                    if (h.kind == txipc::output && on_output) on_output(user, &info, text.data(), text.size());
                } else if (h.kind == txipc::found) {
                    const auto pid = r.u32();
                    const auto code = r.wide(), text = r.wide();
                    if (!r.done()) break;
                    if (on_found) on_found(found_user, pid, code.c_str(), text.data(), text.size());
                } else if (h.kind == txipc::error) {
                    const auto pid = r.u32();
                    const auto message = r.wide();
                    if (!r.done()) break;
                    tx_report_error(pid, message.c_str());
                } else break;
            }
        } catch (...) {}
        failed(L"The 32-bit hooking helper stopped. Attach again to restart it.");
    }
    bool start() {
        wchar_t exe[32768];
        const auto length = GetModuleFileNameW(nullptr, exe, 32768);
        if (!length || length == 32768) return false;
        std::wstring directory(exe, length);
        directory.resize(directory.find_last_of(L"\\/") + 1);
        const std::wstring helper = directory + L"x86\\tx_helper.exe";
        if (GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES ||
            GetFileAttributesW((directory + L"x86\\tx_shim.dll").c_str()) == INVALID_FILE_ATTRIBUTES ||
            GetFileAttributesW((directory + L"x86\\texthook.dll").c_str()) == INVALID_FILE_ATTRIBUTES) {
            tx_report_error(0, L"Missing x86 helper or DLLs. Rebuild or restore the complete x86 backend folder.");
            return false;
        }
        const auto name = L"\\\\.\\pipe\\Touitsu-x86-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
        pipe = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) return false;
        OVERLAPPED connection{};
        connection.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!connection.hEvent) return false;
        const BOOL connected = ConnectNamedPipe(pipe, &connection);
        const auto connection_error = connected ? ERROR_SUCCESS : GetLastError();
        if (!connected && connection_error != ERROR_IO_PENDING && connection_error != ERROR_PIPE_CONNECTED) { CloseHandle(connection.hEvent); return false; }
        job = CreateJobObjectW(nullptr, nullptr);
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        bool ok = job && SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
        std::wstring command = L"\"" + helper + L"\" \"" + name + L"\"";
        STARTUPINFOW startup{}; startup.cb = sizeof(startup);
        PROCESS_INFORMATION child{};
        if (ok) ok = CreateProcessW(helper.c_str(), command.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, (directory + L"x86").c_str(), &startup, &child) != FALSE;
        if (ok) {
            process = child.hProcess;
            ok = AssignProcessToJobObject(job, process) && ResumeThread(child.hThread) != static_cast<DWORD>(-1);
            CloseHandle(child.hThread);
        }
        if (ok && !connected && connection_error == ERROR_IO_PENDING) {
            HANDLE waits[] = {connection.hEvent, process};
            DWORD bytes = 0;
            ok = WaitForMultipleObjects(2, waits, FALSE, 5000) == WAIT_OBJECT_0 && GetOverlappedResult(pipe, &connection, &bytes, FALSE);
        }
        if (ok) {
            ULONG client_pid = 0;
            ok = GetNamedPipeClientProcessId(pipe, &client_pid) && client_pid == child.dwProcessId;
        }
        if (!ok) { CancelIoEx(pipe, &connection); DWORD ignored; GetOverlappedResult(pipe, &connection, &ignored, TRUE); }
        CloseHandle(connection.hEvent);
        if (!ok) return false;
        { std::lock_guard<std::mutex> lock(state_mutex); alive = true; }
        stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!stop_event) return false;
        reader = std::thread([this] { readLoop(); });
        std::unique_lock<std::mutex> lock(state_mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [this] { return ready || !alive; }) && ready;
    }
    bool call(txipc::Kind kind, const txipc::Writer& payload, uint32_t timeout = 2000, uint32_t* value = nullptr) {
        std::lock_guard<std::mutex> serial(call_mutex);
        uint32_t request;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            if (!alive || !ready) return false;
            awaited = request = ++next_request; replied = false;
        }
        if (!txipc::send(pipe, kind, request, payload)) { failed(L"Could not send a command to the 32-bit helper."); return false; }
        std::unique_lock<std::mutex> lock(state_mutex);
        if (!changed.wait_for(lock, std::chrono::milliseconds(timeout), [this] { return replied || !alive; }) || !replied) {
            lock.unlock();
            failed(L"The 32-bit hooking helper did not respond. Attach again to restart it.");
            return false;
        }
        if (value) *value = reply_value;
        return reply_ok;
    }
};
std::shared_ptr<Session> session;
std::shared_ptr<Session> current() { std::lock_guard<std::mutex> lock(manager_mutex); return session; }
std::shared_ptr<Session> ensure() {
    std::lock_guard<std::mutex> lock(manager_mutex);
    if (stopping.load()) return {};
    if (session && session->isAlive()) return session;
    session.reset();
    auto candidate = std::make_shared<Session>();
    if (!candidate->start()) { tx_report_error(0, L"Could not start the 32-bit hooking helper. Check the x86 backend files."); return {}; }
    session = candidate;
    return session;
}
}
void configure(void* u, tx_process_cb c, tx_process_cb d, tx_thread_cb cr, tx_thread_cb de, tx_output_cb o) {
    user = u; on_connect = c; on_disconnect = d; on_create = cr; on_destroy = de; on_output = o;
}
void foundCallback(void* u, tx_found_cb cb) { found_user = u; on_found = cb; }
bool is32(uint32_t pid) {
    const auto process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return false;
    BOOL wow = FALSE;
    const bool ok = IsWow64Process(process, &wow) != FALSE;
    CloseHandle(process); return ok && wow;
}
bool owns(uint32_t pid) { const auto s = current(); return s && s->has(pid); }
bool attach(uint32_t pid) {
    const auto s = ensure(); if (!s) return false;
    { std::lock_guard<std::mutex> lock(s->state_mutex); s->targets.insert(pid); }
    txipc::Writer w; w.u32(pid);
    const bool ok = s->call(txipc::attach, w);
    if (!ok) { std::lock_guard<std::mutex> lock(s->state_mutex); s->targets.erase(pid); }
    return ok;
}
bool detach(uint32_t pid) { const auto s = current(); txipc::Writer w; w.u32(pid); return s && s->call(txipc::detach, w); }
bool insert(uint32_t pid, const wchar_t* code) { const auto s = current(); txipc::Writer w; w.u32(pid); w.wide(code); return s && s->call(txipc::insert, w); }
bool remove(uint32_t pid, uint64_t address) { const auto s = current(); txipc::Writer w; w.u32(pid); w.u64(address); return s && s->call(txipc::remove, w); }
bool find(uint32_t pid, uint32_t cp, const wchar_t* text) { const auto s = current(); txipc::Writer w; w.u32(pid); w.u32(cp); w.wide(text ? text : L""); return s && s->call(txipc::find, w); }
bool probe() { const auto s = ensure(); txipc::Writer w; uint32_t bits = 0; return s && s->call(txipc::ping, w, 2000, &bits) && bits == 32; }
uint32_t shutdown(uint32_t timeout) {
    stopping.store(true);
    std::shared_ptr<Session> s;
    { std::lock_guard<std::mutex> lock(manager_mutex); s = std::move(session); }
    if (!s) return 0;
    { std::lock_guard<std::mutex> lock(s->state_mutex); s->closing = true; }
    txipc::Writer w; w.u32(timeout);
    uint32_t remaining = 0;
    if (!s->call(txipc::shutdown, w, timeout + 2000, &remaining)) remaining = 1;
    s->close();
    return remaining;
}
}
