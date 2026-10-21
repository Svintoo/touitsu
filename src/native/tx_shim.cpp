// tx_shim.cpp - C ABI around Textractor's C++ Host API, for use from Zig (or anything).
//
// Lives in YOUR repo (src/native/), not inside the Textractor submodule. CMakeLists.txt
// compiles it together with Textractor's host sources via include paths.
// Mirrors host/CLI/main.cpp, which is the reference for how Host:: is meant to be driven.
//
// IMPORTANT: all callbacks fire on Textractor's internal pipe-reader threads,
// NOT on your UI thread. Queue the events and drain them from the UI side.

// Textractor's host sources rely on a force-included precompiled header (DWORD, std types, ...).
// The CMake build force-includes it too; this include also makes editors/IntelliSense happy.
#include "common.h"
#include "host.h"
#include "hookcode.h"
#include <cstdint>
#include <string>
#include <cstdio>
#include <exception>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <set>
#include <vector>

#include "tx_api.h"
#ifdef _WIN64
#include "tx_bridge.h"
#endif

static void* g_user = nullptr;
static tx_process_cb g_connect = nullptr, g_disconnect = nullptr;
static tx_thread_cb g_create = nullptr, g_destroy = nullptr;
static tx_output_cb g_output = nullptr;
static tx_error_cb g_error = nullptr;
static void* g_error_user = nullptr;
TX_API void tx_set_error_callback(void* user, tx_error_cb callback) { g_error_user = user; g_error = callback; }
TX_API void tx_report_error(uint32_t pid, const wchar_t* message) { if (g_error) g_error(g_error_user, pid, message); }
TX_API bool tx_remove_hook(uint32_t pid, uint64_t address) {
    try {
#ifdef _WIN64
        if (txbridge::owns(pid)) return txbridge::remove(pid, address);
#endif
        Host::RemoveHook(pid, address);
        return true;
    } catch (...) { return false; }
}
TX_API bool tx_probe_x86() {
#ifdef _WIN64
    try { return txbridge::probe(); }
    catch (...) { tx_report_error(0, L"Could not start the 32-bit hooking helper."); return false; }
#else
    return false;
#endif
}

// Host::DetachProcess only sends a pipe command. Keep the host alive until
// disconnect callbacks confirm that the injected side accepted detachment.
static std::atomic<bool> g_stopping{false};
static std::mutex g_lifecycle_mutex;
static std::condition_variable g_lifecycle_changed;
static std::set<uint32_t> g_connected, g_connecting;

static void DetachConnected(uint32_t pid)
{
    try { Host::DetachProcess(pid); }
    catch (...) {} // A process may have exited between the snapshot and send.
}

template <typename F>
static void WithInfo(TextThread& thread, F&& f)
{
	std::wstring code = HookCode::Generate(thread.hp, thread.tp.processId);
	tx_thread_info info{
		thread.handle,
		(uint32_t)thread.tp.processId,
		thread.tp.addr,
		thread.tp.ctx,
		thread.tp.ctx2,
		thread.name.c_str(),
		code.c_str(),
	};
	f(info);
}

TX_API void tx_start(void* user, tx_process_cb on_connect, tx_process_cb on_disconnect,
                     tx_thread_cb on_create, tx_thread_cb on_destroy, tx_output_cb on_output)
{
	g_user = user;
	g_connect = on_connect; g_disconnect = on_disconnect;
	g_create = on_create;   g_destroy = on_destroy;
	g_output = on_output;
#ifdef _WIN64
    txbridge::configure(user, on_connect, on_disconnect, on_create, on_destroy, on_output);
#endif

	Host::Start(
		[](auto pid) {
            {
                std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
                g_connecting.erase((uint32_t)pid);
                g_connected.insert((uint32_t)pid);
            }
            g_lifecycle_changed.notify_all();
            // Injection may finish after shutdown started. Detach that late
            // connection instead of loading the saved hooks again.
            if (g_stopping.load()) DetachConnected((uint32_t)pid);
            else if (g_connect) g_connect(g_user, (uint32_t)pid);
        },
		[](auto pid) {
            {
                std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
                g_connected.erase((uint32_t)pid);
                g_connecting.erase((uint32_t)pid);
            }
            g_lifecycle_changed.notify_all();
            if (!g_stopping.load() && g_disconnect) g_disconnect(g_user, (uint32_t)pid);
        },
		[](auto& thread) { if (!g_stopping.load() && g_create) WithInfo(thread, [&](const tx_thread_info& i) { g_create(g_user, &i); }); },
		[](auto& thread) { if (!g_stopping.load() && g_destroy) WithInfo(thread, [&](const tx_thread_info& i) { g_destroy(g_user, &i); }); },
		[](TextThread& thread, std::wstring& output)
		{
			if (!g_stopping.load() && g_output) WithInfo(thread, [&](const tx_thread_info& i) { g_output(g_user, &i, output.c_str(), output.size()); });
			return false; // same as the CLI: don't swallow the text
		});
}

// Host:: calls look processes up in internal maps with .at(), which throws if the process
// isn't (or is no longer) known - e.g. detaching a game that already crashed. An exception
// escaping an extern "C" function would terminate the whole app, so catch it and report failure.
TX_API bool tx_attach(uint32_t pid)
{
    std::fprintf(stderr, "[tx_shim] InjectProcess(%u) starting\n", pid);
    std::fflush(stderr);

    try
    {
#ifdef _WIN64
        if (txbridge::is32(pid)) return txbridge::attach(pid);
#endif
        const auto access = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
        if (!access) { tx_report_error(pid, L"Cannot open the game for hooking. Check that it is running and has matching permissions."); return false; }
        CloseHandle(access);
        {
            std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
            if (g_stopping.load()) return false;
            g_connecting.insert(pid);
        }
        Host::InjectProcess(pid);

        std::fprintf(stderr, "[tx_shim] InjectProcess(%u) returned\n", pid);
        std::fflush(stderr);
        return true;
    }
    catch (const std::exception& e)
    {
        std::fprintf(stderr, "[tx_shim] InjectProcess exception: %s\n", e.what());
        std::fflush(stderr);
        {
            std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
            g_connecting.erase(pid);
        }
        g_lifecycle_changed.notify_all();
        return false;
    }
    catch (...)
    {
        std::fprintf(stderr, "[tx_shim] InjectProcess: unknown C++ exception\n");
        std::fflush(stderr);
        {
            std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
            g_connecting.erase(pid);
        }
        g_lifecycle_changed.notify_all();
        return false;
    }
}

TX_API bool tx_detach(uint32_t pid)
{
	try {
#ifdef _WIN64
        if (txbridge::owns(pid)) return txbridge::detach(pid);
#endif
        Host::DetachProcess(pid); return true;
    }
	catch (...) { return false; }
}

TX_API bool tx_is_stopping() { return g_stopping.load(); }

// Returns how many connections did not confirm disconnect before the deadline.
// Call once at application shutdown, before allowing this host DLL to terminate.
TX_API uint32_t tx_shutdown(uint32_t timeout_ms)
{
    try
    {
        const auto started = std::chrono::steady_clock::now();
        g_stopping.store(true);
        uint32_t remote_remaining = 0;
#ifdef _WIN64
        remote_remaining = txbridge::shutdown(timeout_ms);
#endif
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        const auto wait_ms = elapsed < timeout_ms ? timeout_ms - (uint32_t)elapsed : 0;
        std::vector<uint32_t> connected;
        {
            std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
            g_stopping.store(true);
            connected.assign(g_connected.begin(), g_connected.end());
        }
        for (uint32_t pid : connected) DetachConnected(pid);
        std::unique_lock<std::mutex> lock(g_lifecycle_mutex);
        g_lifecycle_changed.wait_for(lock, std::chrono::milliseconds(wait_ms), [] {
            return g_connected.empty() && g_connecting.empty();
        });
        const uint32_t remaining = (uint32_t)(g_connected.size() + g_connecting.size());
        if (remaining != 0)
            std::fprintf(stderr, "[tx_shim] Detach timed out: %zu connected, %zu pending\n", g_connected.size(), g_connecting.size());
        return remaining + remote_remaining;
    }
    catch (...) { return 1; }
}

// Insert a hook from an /H-style code, e.g. L"/HS-4@0". Returns false if the code is invalid
// or the process is unknown.
TX_API bool tx_insert_hook(uint32_t pid, const wchar_t* code)
{
	try
	{
#ifdef _WIN64
        if (txbridge::owns(pid)) return txbridge::insert(pid, code);
#endif
		if (auto hp = HookCode::Parse(code))
		{
			Host::InsertHook(pid, hp.value());
			return true;
		}
	}
	catch (...) {}
	return false;
}
