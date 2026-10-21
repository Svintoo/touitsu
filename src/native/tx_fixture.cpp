// Owned integration-test process: no interaction with user games or applications.
#include <windows.h>
static volatile unsigned long sink = 1;
extern "C" __declspec(dllexport) __declspec(noinline) void fixture_text(const wchar_t* text) {
    for (int i = 0; i < 24; ++i) sink = sink * 33 + text[i % 8];
}
// Deliberately recognizable function prolog for the generic hook-search test.
extern "C" __declspec(dllexport) __declspec(naked) __attribute__((aligned(64))) void fixture_search_text(const wchar_t*) {
#ifdef _WIN64
    __asm__ volatile(".byte 0xcc,0xcc,0x48,0x89,0x4c,0x24,0x08,0xc3");
#else
    __asm__ volatile(".byte 0xcc,0xcc,0x55,0x8b,0xec,0x5d,0xc3");
#endif
}
int main() {
    const auto searchable = reinterpret_cast<void (*)(const wchar_t*)>(reinterpret_cast<uintptr_t>(&fixture_search_text) + 2);
    const auto until = GetTickCount64() + 180000;
    while (GetTickCount64() < until) {
#ifdef _WIN64
        fixture_text(L"TOUITSU_X64 日本語");
        searchable(L"TOUITSU_X64 日本語");
#else
        fixture_text(L"TOUITSU_X86 日本語");
        searchable(L"TOUITSU_X86 日本語");
#endif
        // Textractor flushes a sentence after 500 ms without incoming characters.
        Sleep(700);
    }
    return 0;
}
