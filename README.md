# Touitsu

A Windows Japanese reader with Textractor hook capture, clipboard capture, offline dictionary lookups, configurable themes, and AnkiConnect integration.

## Build

Requirements: Windows x64, Zig 0.17.0, Python, Vulkan SDK, and Visual Studio C++ tools with CMake and Ninja. See `build.zig.zon` for the minimum Zig version.

Clone with submodules and apply the local Clang compatibility patch:

```powershell
git clone --recurse-submodules https://github.com/Svintoo/touitsu.git
cd touitsu
git -C src/third_party/Textractor apply ../../native/compat/textractor-common.patch
zig build
zig build run
```

The build packages both x86 and x64 hook backends. Keep the installed `x86` directory next to `Touitsu.exe`.

## Dictionaries and Anki

Place supported Yomitan dictionary ZIPs in the `dicts` folder next to the executable. Dictionary contents are supplied separately by the user.

For Anki, install AnkiConnect, keep Anki running, and enable the integration in Touitsu. Choose a deck and note type, then edit the field templates under **Card formatting**. Online pronunciation is optional and requires enabling internet access in the settings.

See [dictionary implementation](docs/native-dictionaries.md), [Anki notes](docs/anki.md), and [hook backend details](docs/textractor-backends.md).

## Checks

```powershell
zig build test-anki test-hook-preview test-selection
```

## Dependencies and credits

- [Textractor](https://github.com/Artikash/Textractor), retained as a submodule, and local hook backend adaptations. See its bundled license and [binary provenance](libs/Textractor-PROVENANCE.md).
- Knots UI and other Zig dependencies listed in [build.zig.zon](build.zig.zon).
- [SQLite](https://www.sqlite.org/), vendored in `src/third_party/sqlite`.
- [Jisho](https://jisho.org/) for optional pronunciation lookup.

Dependency licenses remain applicable to their respective components. Local Knots adaptations and themes include license files in their source directories.
