// tx_find.cpp - hook search ("Search for hooks" / "Search for specific text") for the shim.
// Kept separate from tx_shim.cpp. Compiled into the same DLL (see build.zig).
//
// Textractor flow: Host::FindHooks sends a FindHookCmd to the injected texthook.dll, which scans
// the game's memory while the game runs and reports each candidate hook back. Candidates arrive
// on host pipe threads, one callback per candidate, so queue them on the Zig side.

#include "common.h"
#include "host.h"
#include "hookcode.h"
#include <cstdint>
#include <cstring>
#include <string>

#include "tx_api.h"
#ifdef _WIN64
#include "tx_bridge.h"
#endif

extern "C" bool tx_is_stopping();

static tx_found_cb g_found = nullptr;
static void* g_found_user = nullptr;

TX_API void tx_set_find_callback(void* user, tx_found_cb cb)
{
	g_found_user = user;
	g_found = cb;
#ifdef _WIN64
    txbridge::foundCallback(user, cb);
#endif
}

// codepage: text encoding to search for (932 Shift-JIS, 65001 UTF-8, ...).
// text: if non-empty, search for that specific on-screen text instead of generic candidates.
TX_API bool tx_find_hooks(uint32_t pid, uint32_t codepage, const wchar_t* text)
{
	try
	{
#ifdef _WIN64
        if (txbridge::owns(pid)) return txbridge::find(pid, codepage, text);
#endif
		SearchParam sp = {}; // keeps the struct's own default member values (record limits, etc.)
		sp.codepage = codepage;
        sp.searchTime = 30000;
		if (text && *text)
		{
			size_t n = wcslen(text);
			const size_t cap = sizeof(sp.text) / sizeof(sp.text[0]) - 1;
			if (n > cap) n = cap;
			memcpy(sp.text, text, n * sizeof(wchar_t));
			sp.text[n] = 0;
		}
		Host::FindHooks(pid, sp, [pid](HookParam hp, std::wstring found)
		{
			if (tx_is_stopping() || !g_found) return;
			std::wstring code = HookCode::Generate(hp, pid);
			g_found(g_found_user, pid, code.c_str(), found.c_str(), found.size());
		});
		return true;
	}
	catch (...) { return false; }
}