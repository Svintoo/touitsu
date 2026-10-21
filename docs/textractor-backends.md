# x86 and x64 game hooking

Touitsu remains a 64-bit Windows application. The process list labels targets
`x86` or `x64`; selecting either uses the matching backend automatically. Both
architectures can remain attached simultaneously. Saved hooks and hook searches
use the same routing as manual hook insertion.

Installed layout:

```text
Touitsu.exe             64-bit reader and application
tx_shim.dll             64-bit Textractor host and x86 bridge
texthook.dll            64-bit injected hook DLL
x86/tx_helper.exe       32-bit helper, started on the first x86 attachment
x86/tx_shim.dll         32-bit Textractor host
x86/texthook.dll        32-bit injected hook DLL
licenses/Textractor-LICENSE.txt
```

Keep the complete `x86` directory beside the application. There is no mode
switch and no need to launch the helper manually. Missing backend files and
helper failures appear in the Textractor status. If the helper exits unexpectedly,
its attachments are cleared; attaching again starts a replacement. An x86
helper failure does not stop the in-process x64 backend.

## Host isolation and lifecycle

The x64 shim checks the selected process architecture. For x86 it starts a
hidden helper in a kill-on-close Windows job and connects a private local named
pipe. The helper's process ID is verified before accepting the connection.
Protocol frames contain a version, bounded lengths, fixed-width integers, and
counted UTF-16 strings. Native pointers and architecture-dependent C++ structures
never cross that pipe. Hook addresses, handles and context values remain 64-bit
on the wire, including when they originate in the x86 host.

The bridge forwards attach, detach, insertion, removal, search and shutdown requests.
Connection, thread, text, search-result and error callbacks go back into the
existing thread-safe Zig event queue. Only the x64 host supplies the built-in
Console and Clipboard threads, so they are not duplicated by the helper.

Request waits and writes are bounded. Reader I/O is cancellable. Normal shutdown
waits for game disconnect confirmation and closes the helper. The Windows job
also terminates the helper if the application exits unexpectedly. Textractor's
injected side detects the closed host pipes and unloads, as exercised by the
helper-restart integration check.

Stock Textractor hosts share global pipe/event names. Running stock x86 and x64
hosts side by side could send a game to a host with an incompatible ABI. The
build compiles both injected DLLs from source. Hosts and hook DLLs share pipe
names derived from their installation directory and architecture, so an isolated
verification build cannot consume connections intended for the installed app.
The original vendor binaries in `libs` remain reference artifacts.

`src/native/tx_hookfinder.cpp` carries the local search fixes. Search only disables
and removes detours it created, excludes Windows system modules, preserves x64
volatile SIMD registers, and stops capture before releasing result buffers.
Executable detours and MinHook original-code buffers remain allocated until the
target exits because a suspended game thread may still return through them.
Repeated searches have a 128 MiB budget for retired search-detour allocations.
Text searches report candidates instead of immediately installing read hooks.
The build generates the MinHook change and two x86 host calling-convention fixes;
the Textractor submodule's existing local changes are preserved.

Use one Touitsu instance for hooking: pipe namespaces separate architectures,
not application instances. Stock Textractor and Touitsu also cannot both inject
their `texthook.dll` into the same game.

## Building and verification

`zig build` builds the x64 application and both host architectures, then stages
the matching DLLs. The UI target is x86_64 Windows; an x86 UI build is unnecessary.
Python 3 and Visual Studio 2022 with C++ tools, CMake and a Windows SDK are needed
at build time for the injected DLLs (they use MSVC structured exception handling).
End users running the packaged app do not need Python or a compiler.

`zig build test-backends --prefix zig-out/dual-arch-check` creates and starts
two owned fixture programs. It checks:

- Wire-format round trips, truncated strings and oversized payload rejection.
- Helper handshake and simultaneous x86/x64 injection.
- Hook insertion, invalid-code rejection, and short search-command routing.
- Full generic searches on both architectures, with existing hooks surviving cleanup.
- Hook removal and reinsertion through the x86 bridge and native x64 host.
- Actual Japanese UTF-16 text from both fixtures.
- Helper failure isolation while x64 output continues.
- Helper restart, x86 reattachment, manual detach and confirmed shutdown.

The check never attaches to an existing game or user application. Fixture
processes are cleaned up and have a fallback lifetime limit. Game-specific search
compatibility and automatic engine hooks still require testing against the relevant
games. `tx_test.exe` can also attach to either architecture
using `TX_PID`, with optional `TX_HOOK` and `TX_SEARCH` environment variables.

The root Zig build is authoritative for the packaged dual-architecture app.
`src/native/CMakeLists.txt` remains a legacy single-host library build.
