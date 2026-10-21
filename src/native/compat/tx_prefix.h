// compat/tx_prefix.h - force-included BEFORE Textractor's common.h (see build.zig).
//
// Textractor uses &CloseHandle and &GlobalUnlock as constant template arguments
// (std::integral_constant<..., CloseHandle>). MSVC allows that for dllimport functions;
// clang/MinGW doesn't, because the address of an imported function isn't a constant.
//
// Declaring ONLY these two functions without dllimport, before <Windows.h> is included,
// makes their addresses constant (clang drops the later dllimport with a harmless warning).
//
// Do NOT use -D_KERNEL32_ instead: it un-imports every kernel32 function, and then
// &LoadLibraryW (which Textractor passes to CreateRemoteThread) points at a stub inside
// our own DLL rather than at kernel32 in the target process -> the target crashes on inject.
extern "C" {
int __stdcall CloseHandle(void*);
int __stdcall GlobalUnlock(void*);
}

// Define the original constants first, then override use sites. The staged hook
// DLLs receive the identical fixed-length names in scripts/patch_texthook.py.
#ifdef TOUITSU_PRIVATE_PIPES
#include "common.h"
namespace {
#include "defs.h"
}
#include "../tx_pipe_names.h"
#endif
