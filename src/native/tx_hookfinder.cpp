// Textractor GPL-3.0 hook finder, with search ownership and callback lifetime fixes.
// Upstream: src/third_party/Textractor/texthook/hookfinder.cc.
#include "hookfinder.h"
#include "defs.h"
#include "main.h"
#include "util.h"
#include "MinHook.h"

extern const char* HOOK_SEARCH_STARTING;
extern const char* HOOK_SEARCH_INITIALIZING;
extern const char* HOOK_SEARCH_INITIALIZED;
extern const char* MAKE_GAME_PROCESS_TEXT;
extern const char* HOOK_SEARCH_FINISHED;
extern const char* OUT_OF_RECORDS_RETRY;
extern const char* NOT_ENOUGH_TEXT;
extern const char* COULD_NOT_FIND;

namespace
{
    // Shared with the UI host, including when a 32-bit helper routes the search.
    struct SearchDeadline {
        HANDLE event;
        ULONGLONG deadline = GetTickCount64() + 30000;
        SearchDeadline() {
            wchar_t name[96];
            swprintf_s(name, L"Local\\TouitsuHookSearchStop.%lu", GetCurrentProcessId());
            event = CreateEventW(nullptr, TRUE, FALSE, name);
            if (event) ResetEvent(event);
        }
        ~SearchDeadline() { if (event) CloseHandle(event); }
        bool stopped() const { return GetTickCount64() >= deadline || (event && WaitForSingleObject(event, 0) == WAIT_OBJECT_0); }
        void wait() const {
            const auto now = GetTickCount64();
            const DWORD remaining = now < deadline ? DWORD(deadline - now) : 0;
            if (event) WaitForSingleObject(event, remaining); else Sleep(remaining);
        }
    };
	SearchParam sp;

	constexpr int MAX_STRING_SIZE = 500, CACHE_SIZE = 749993, GOOD_PAGE = -1;
	struct HookRecord
	{
		uint64_t address = 0;
		uintptr_t padding = 0;
		int offset = 0;
		char text[MAX_STRING_SIZE] = {};
	};
	std::unique_ptr<HookRecord[]> records;
	long recordsAvailable;
	volatile LONG capturing = 0, activeSenders = 0;
	// Retire executable allocations until process exit: a suspended game thread
	// can still return through a disabled detour. Bound repeated-search memory.
	size_t retiredSearchBytes = 0;
	uint64_t signatureCache[CACHE_SIZE] = {};
	long sumCache[CACHE_SIZE] = {};
	uintptr_t pageCache[CACHE_SIZE] = {};

#ifndef _WIN64
	BYTE trampoline[] =
	{
		0x9c, // pushfd
		0x60, // pushad
		0x68, 0,0,0,0, // push @addr ; after this a total of 0x28 bytes are pushed
		0x8d, 0x44, 0x24, 0x28, // lea eax,[esp+0x28]
		0x50, // push eax ; stack
		0xbb, 0,0,0,0, // mov ebx,@Send
		0xff, 0xd3, // call ebx
		0x83, 0xc4, 0x08, // add esp, 0x8 ; doesn't matter which register
		0x61, // popad
		0x9d,  // popfd
		0x68, 0,0,0,0, // push @original
		0xc3  // ret ; basically absolute jmp to @original
	};
	constexpr int addr_offset = 3, send_offset = 13, original_offset = 25, registers = 8;
#else
	BYTE trampoline[] = {
		0x9c, // push rflags
		0x50, // push rax
		0x53, // push rbx
		0x51, // push rcx
		0x52, // push rdx
		0x54, // push rsp
		0x55, // push rbp
		0x56, // push rsi
		0x57, // push rdi
		0x41, 0x50, // push r8
		0x41, 0x51, // push r9
		0x41, 0x52, // push r10
		0x41, 0x53, // push r11
		0x41, 0x54, // push r12
		0x41, 0x55, // push r13
		0x41, 0x56, // push r14
		0x41, 0x57, // push r15
		// https://docs.microsoft.com/en-us/cpp/build/x64-calling-convention
		// https://stackoverflow.com/questions/43358429/save-value-of-xmm-registers
		0x48, 0x83, 0xec, 0x60, // reserve all six volatile XMM registers
		0xf3, 0x0f, 0x7f, 0x04, 0x24,
		0xf3, 0x0f, 0x7f, 0x4c, 0x24, 0x10,
		0xf3, 0x0f, 0x7f, 0x54, 0x24, 0x20,
		0xf3, 0x0f, 0x7f, 0x5c, 0x24, 0x30,
		0xf3, 0x0f, 0x7f, 0x64, 0x24, 0x40,
		0xf3, 0x0f, 0x7f, 0x6c, 0x24, 0x50,
		0x48, 0x8d, 0x8c, 0x24, 0xe8, 0x00, 0x00, 0x00, // original stack
		0x48, 0xba, 0,0,0,0,0,0,0,0, // mov rcx,@addr
		0x48, 0xb8, 0,0,0,0,0,0,0,0, // mov rax,@Send
		0x48, 0x89, 0xe3, // mov rbx,rsp
		0x48, 0x83, 0xe4, 0xf0, // and rsp,0xfffffffffffffff0 ; align stack
		0xff, 0xd0, // call rax
		0x48, 0x89, 0xdc, // mov rsp,rbx
		0xf3, 0x0f, 0x6f, 0x04, 0x24,
		0xf3, 0x0f, 0x6f, 0x4c, 0x24, 0x10,
		0xf3, 0x0f, 0x6f, 0x54, 0x24, 0x20,
		0xf3, 0x0f, 0x6f, 0x5c, 0x24, 0x30,
		0xf3, 0x0f, 0x6f, 0x64, 0x24, 0x40,
		0xf3, 0x0f, 0x6f, 0x6c, 0x24, 0x50,
		0x48, 0x83, 0xc4, 0x60,
		0x41, 0x5f, // pop r15
		0x41, 0x5e, // pop r14
		0x41, 0x5d, // pop r13
		0x41, 0x5c, // pop r12
		0x41, 0x5b, // pop r11
		0x41, 0x5a, // pop r10
		0x41, 0x59, // pop r9
		0x41, 0x58, // pop r8
		0x5f, // pop rdi
		0x5e, // pop rsi
		0x5d, // pop rbp
		0x5c, // pop rsp
		0x5a, // pop rdx
		0x59, // pop rcx
		0x5b, // pop rbx
		0x58, // pop rax
		0x9d, // pop rflags
		0xff, 0x25, 0x00, 0x00, 0x00, 0x00, // jmp qword ptr [rip]
		0,0,0,0,0,0,0,0 // @original
	};
	constexpr int addr_offset = 74, send_offset = 84, original_offset = 174, registers = 16;
#endif
	static_assert(original_offset + sizeof(void*) + (x64 ? 0 : 1) == sizeof(trampoline), "Search trampoline offsets must match the machine code");
}

bool IsBadReadPtr(void* data)
{
	if (data > records.get() && data < records.get() + sp.maxRecords) return true;
	uintptr_t BAD_PAGE = (uintptr_t)data >> 12;
	auto& cacheEntry = pageCache[BAD_PAGE % CACHE_SIZE];
	if (cacheEntry == BAD_PAGE) return true;
	if (cacheEntry == GOOD_PAGE) return false;

	__try
	{
		volatile char _ = *(char*)data;
		cacheEntry = GOOD_PAGE;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		if (GetExceptionCode() == EXCEPTION_GUARD_PAGE)
		{
			MEMORY_BASIC_INFORMATION info;
			VirtualQuery(data, &info, sizeof(info));
			VirtualProtect(data, 1, info.Protect | PAGE_GUARD, DUMMY);
		}
		cacheEntry = BAD_PAGE;
	}
	return cacheEntry == BAD_PAGE;
}

void Send(char** stack, uintptr_t address)
{
	// it is unsafe to call ANY external functions from this, as they may have been hooked (if called the hook would call this function making an infinite loop)
	// the exceptions are compiler intrinsics like _InterlockedDecrement
	_InterlockedIncrement(&activeSenders);
	if (!_InterlockedCompareExchange(&capturing, 0, 0)) {
		_InterlockedDecrement(&activeSenders);
		return;
	}
	if (recordsAvailable > 0) for (int i = -registers; i < 10; ++i) for (auto padding : { uintptr_t{}, sp.padding })
	{
		char* str = stack[i] + padding;
		if (IsBadReadPtr(str) || IsBadReadPtr(str + MAX_STRING_SIZE)) continue;
		__try
		{
			int length = 0, sum = 0;
			for (; (str[length] || str[length + 1]) && length < MAX_STRING_SIZE; length += 2) sum += *(uint16_t*)(str + length);
			if (length > STRING && length < MAX_STRING_SIZE - 1)
			{
				// many duplicate results with same address, offset, and third/fourth character will be found: filter them out
				uint64_t signature = ((uint64_t)i << 56) | ((uint64_t)(str[2] + str[3]) << 48) | address;
				if (signatureCache[signature % CACHE_SIZE] == signature) continue;
				signatureCache[signature % CACHE_SIZE] = signature;
				// if there are huge amount of strings that are the same, it's probably garbage: filter them out
				// can't store all the strings, so use sum as heuristic instead
				if (_InterlockedIncrement(sumCache + (sum % CACHE_SIZE)) > 25) continue;
				long n = sp.maxRecords - _InterlockedDecrement(&recordsAvailable);
				if (n < sp.maxRecords)
				{
					records[n].address = address;
					records[n].padding = padding;
					records[n].offset = i * sizeof(char*);
					for (int j = 0; j < length; ++j) records[n].text[j] = str[j];
					records[n].text[length] = 0;
				}
				if (n == sp.maxRecords)
				{
					spDefault.maxRecords = sp.maxRecords * 2;
					// Report on the search thread; external calls inside a detour can recurse.
				}
			}
		}
		__except (EXCEPTION_EXECUTE_HANDLER) {}
	}
	_InterlockedDecrement(&activeSenders);
}

std::vector<uint64_t> GetFunctions(uintptr_t module)
{
	if (!module) return {};
	IMAGE_DOS_HEADER* dosHeader = (IMAGE_DOS_HEADER*)module;
	if (dosHeader->e_magic != IMAGE_DOS_SIGNATURE) return {};
	IMAGE_NT_HEADERS* ntHeader = (IMAGE_NT_HEADERS*)(module + dosHeader->e_lfanew);
	if (ntHeader->Signature != IMAGE_NT_SIGNATURE) return {};
	DWORD exportAddress = ntHeader->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
	if (!exportAddress) return {};
	IMAGE_EXPORT_DIRECTORY* exportDirectory = (IMAGE_EXPORT_DIRECTORY*)(module + exportAddress);
	std::vector<uint64_t> functions;
	for (int i = 0; i < exportDirectory->NumberOfNames; ++i)
		//char* funcName = (char*)(module + *(DWORD*)(module + exportDirectory->AddressOfNames + i * sizeof(DWORD)));
		functions.push_back(module + *(DWORD*)(module + exportDirectory->AddressOfFunctions +
			sizeof(DWORD) * *(WORD*)(module + exportDirectory->AddressOfNameOrdinals + i * sizeof(WORD))));
	return functions;
}

void SearchForHooks(SearchParam spUser)
{
	std::thread([=]
	{
		static std::mutex m;
		std::unique_lock lock(m, std::try_to_lock);
        if (!lock.owns_lock()) return;
        SearchDeadline deadline;
		*(void**)(trampoline + send_offset) = Send;

		sp = spUser.length == 0 ? spDefault : spUser;

		ConsoleOutput(HOOK_SEARCH_INITIALIZING, 0.);
		do
			try { records = std::make_unique<HookRecord[]>(recordsAvailable = sp.maxRecords); }
			catch (std::bad_alloc) { ConsoleOutput("Textractor: SearchForHooks ERROR: out of memory, retrying to allocate %d", sp.maxRecords /= 2); }
		while (!records && sp.maxRecords);

		std::vector<uint64_t> addresses;
		if (*sp.boundaryModule) std::tie(sp.minAddress, sp.maxAddress) = Util::QueryModuleLimits(GetModuleHandleW(sp.boundaryModule));
		if (*sp.exportModule) addresses = GetFunctions((uintptr_t)GetModuleHandleW(sp.exportModule));
		else for (auto& addr : addresses = Util::SearchMemory(sp.pattern, sp.length, PAGE_EXECUTE, sp.minAddress, sp.maxAddress)) addr += sp.offset;

		auto limits = Util::QueryModuleLimits(GetModuleHandleW(ITH_DLL));
		addresses.erase(std::remove_if(addresses.begin(), addresses.end(), [&](uint64_t addr) { return addr > limits.first && addr < limits.second; }), addresses.end());
		// Hooking OS synchronization, exception handling and allocator functions can
		// recurse into the search callback itself. Search game/engine code instead.
		wchar_t windowsPath[MAX_PATH] = {};
		const auto windowsLength = GetWindowsDirectoryW(windowsPath, MAX_PATH);
		addresses.erase(std::remove_if(addresses.begin(), addresses.end(), [&](uint64_t addr) {
			HMODULE module = nullptr;
			if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)(uintptr_t)addr, &module)) return false;
			wchar_t path[32768] = {};
			const auto length = GetModuleFileNameW(module, path, 32768);
			return windowsLength && windowsLength < MAX_PATH && length > windowsLength && path[windowsLength] == L'\\'
				&& CompareStringOrdinal(path, windowsLength, windowsPath, windowsLength, TRUE) == CSTR_EQUAL;
		}), addresses.end());

		const size_t bytes = sizeof(trampoline) * addresses.size();
		if (bytes > 128 * 1024 * 1024 - retiredSearchBytes) {
			ConsoleOutput("Textractor: search code memory limit reached; restart the game before searching again");
			records.reset(); return;
		}
		auto trampolines = (decltype(trampoline)*)VirtualAlloc(NULL, bytes, MEM_COMMIT, PAGE_READWRITE);
		if (!trampolines) { records.reset(); return; }
		if (!VirtualProtect(trampolines, addresses.size() * sizeof(trampoline), PAGE_EXECUTE_READWRITE, DUMMY)) {
			VirtualFree(trampolines, 0, MEM_RELEASE); records.reset(); return;
		}
		std::vector<uint64_t> owned;
		bool usedAllocation = false;
		for (int i = 0; i < addresses.size(); ++i)
		{
			void* original = nullptr;
			// Never take ownership of an engine hook or a manually inserted hook.
			if (deadline.stopped()) break;
            if (MH_CreateHook((void*)addresses[i], trampolines[i], &original) != MH_OK) continue;
			memcpy(trampolines[i], trampoline, sizeof(trampoline));
			*(uintptr_t*)(trampolines[i] + addr_offset) = addresses[i];
			*(void**)(trampolines[i] + original_offset) = original;
			usedAllocation = true;
			owned.push_back(addresses[i]);
			MH_QueueEnableHook((void*)addresses[i]);
			if (i % 2500 == 0) ConsoleOutput(HOOK_SEARCH_INITIALIZING, 1 + 98. * i / addresses.size());
		}
		FlushInstructionCache(GetCurrentProcess(), trampolines, addresses.size() * sizeof(trampoline));
		ConsoleOutput(HOOK_SEARCH_INITIALIZED, owned.size());
		_InterlockedExchange(&capturing, 1);
		MH_ApplyQueued();
		ConsoleOutput(HOOK_SEARCH_STARTING);
		ConsoleOutput(MAKE_GAME_PROCESS_TEXT, sp.searchTime / 1000);
		deadline.wait();
		_InterlockedExchange(&capturing, 0);
		for (auto addr : owned) MH_QueueDisableHook((void*)addr);
		MH_ApplyQueued();
		while (_InterlockedCompareExchange(&activeSenders, 0, 0)) Sleep(1);
		// Our MinHook build retires its original-code buffers too. Removing the
		// entries lets a chosen result be installed as a normal extraction hook.
		for (auto addr : owned) MH_RemoveHook((void*)addr);
		ConsoleOutput(HOOK_SEARCH_FINISHED, sp.maxRecords - recordsAvailable);
		for (int i = 0, results = 0; i < sp.maxRecords; ++i)
		{
			if (!records[i].address) continue;
			if (++results % 100'000 == 0) ConsoleOutput("Textractor: %d results processed", results);
			HookParam hp = {};
			hp.offset = records[i].offset;
			hp.type = USING_UNICODE | USING_STRING;
			hp.address = records[i].address;
			hp.padding = records[i].padding;
			hp.codepage = sp.codepage;
			if (sp.hookPostProcessor) sp.hookPostProcessor(hp);
			NotifyHookFound(hp, (wchar_t*)records[i].text);
		}
		records.reset();
		if (!usedAllocation) VirtualFree(trampolines, 0, MEM_RELEASE);
		else retiredSearchBytes += bytes;
		for (int i = 0; i < CACHE_SIZE; ++i) signatureCache[i] = sumCache[i] = 0;
	}).detach();
}

void SearchForText(wchar_t* text, UINT codepage)
{
    SearchDeadline deadline;
	bool found = false;
	char utf8Text[PATTERN_SIZE * 4] = {};
	WideCharToMultiByte(CP_UTF8, 0, text, PATTERN_SIZE, utf8Text, PATTERN_SIZE * 4, nullptr, nullptr);
	char codepageText[PATTERN_SIZE * 4] = {};
	WideCharToMultiByte(codepage, 0, text, PATTERN_SIZE, codepageText, PATTERN_SIZE * 4, nullptr, nullptr);
	if (strlen(utf8Text) < 4 || strlen(codepageText) < 4 || wcslen(text) < 4) return ConsoleOutput(NOT_ENOUGH_TEXT);
	ConsoleOutput(HOOK_SEARCH_STARTING);
	auto GenerateHooks = [&](std::vector<uint64_t> addresses, HookParamType type)
	{
		for (auto addr : addresses)
		{
            if (deadline.stopped()) return;
			if (abs((long long)(utf8Text - addr)) < 20000) continue; // don't add read code if text is on this thread's stack
			found = true;
			HookParam hp = {};
			hp.type = DIRECT_READ | type;
			hp.address = addr;
			hp.codepage = codepage;
			// Searching discovers candidates; activation requires an explicit UI action.
			NotifyHookFound(hp, text);
		}
	};
	if (!deadline.stopped()) GenerateHooks(Util::SearchMemory(utf8Text, strlen(utf8Text), PAGE_READWRITE), USING_UTF8);
	if (!deadline.stopped()) GenerateHooks(Util::SearchMemory(codepageText, strlen(codepageText), PAGE_READWRITE), USING_STRING);
	if (!deadline.stopped()) GenerateHooks(Util::SearchMemory(text, wcslen(text) * sizeof(wchar_t), PAGE_READWRITE), USING_UNICODE);
	if (!found) ConsoleOutput(COULD_NOT_FIND);
}
