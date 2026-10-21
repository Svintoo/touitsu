# Textractor hook DLLs

Both original binaries are from the official Artikash/Textractor v5.2.0 release:

https://github.com/Artikash/Textractor/releases/tag/v5.2.0

Archive:
https://github.com/Artikash/Textractor/releases/download/v5.2.0/Textractor-5.2.0-Zip-Version-English-Only.zip

| Local source | Original archive entry | SHA-256 |
| --- | --- | --- |
| `texthook.dll` | `Textractor/x64/texthook.dll` | `43b966f566e1d6362416041bfb55dc4e04aef7bcb8b5aae2da8179c24b2dd58e` |
| `texthook-x86.dll` | `Textractor/x86/texthook.dll` | `8fde589a24ef861c581b61829626d35d6b0fcc958aaaeca620dff630f1ed465b` |

Textractor is GPL-3.0 licensed. Its source and license are retained in
`src/third_party/Textractor`; the build includes that license in the output.
The checkout's hook command structures match the v5.2.0 release for both
architectures.

The originals are never overwritten and are now retained as reference artifacts.
The packaged DLLs are compiled from `src/third_party/Textractor` with the local
GPL-3.0 hook finder in `src/native/tx_hookfinder.cpp` and a generated MinHook
trampoline-lifetime patch. See `docs/textractor-backends.md` for the changes and
build requirements. `scripts/patch_texthook.py` remains available for verifying
the older reference binary layout; it is not used for current packaging.
