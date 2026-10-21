#pragma once
#include <cstdint>
#include <cstddef>

struct tx_thread_info {
    uint64_t handle;
    uint32_t pid;
    uint64_t addr, ctx, ctx2;
    const wchar_t* name;
    const wchar_t* hook_code;
};
using tx_process_cb = void (*)(void*, uint32_t);
using tx_thread_cb = void (*)(void*, const tx_thread_info*);
using tx_output_cb = void (*)(void*, const tx_thread_info*, const wchar_t*, size_t);
using tx_found_cb = void (*)(void*, uint32_t, const wchar_t*, const wchar_t*, size_t);
using tx_error_cb = void (*)(void*, uint32_t, const wchar_t*);

#ifdef TX_SHIM_BUILD
#define TX_API extern "C" __declspec(dllexport)
#else
#define TX_API extern "C" __declspec(dllimport)
#endif
TX_API void tx_start(void*, tx_process_cb, tx_process_cb, tx_thread_cb, tx_thread_cb, tx_output_cb);
TX_API bool tx_attach(uint32_t);
TX_API bool tx_detach(uint32_t);
TX_API uint32_t tx_shutdown(uint32_t);
TX_API bool tx_insert_hook(uint32_t, const wchar_t*);
TX_API bool tx_remove_hook(uint32_t, uint64_t);
TX_API void tx_set_find_callback(void*, tx_found_cb);
TX_API bool tx_find_hooks(uint32_t, uint32_t, const wchar_t*);
TX_API void tx_set_error_callback(void*, tx_error_cb);
TX_API bool tx_probe_x86();
TX_API void tx_report_error(uint32_t, const wchar_t*);
