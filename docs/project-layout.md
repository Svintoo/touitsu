# Project layout

`src/main.zig` owns application startup, shared application state, and the frame
loop. Feature code lives under `src/components`, with each feature's settings
menu beside its supporting logic:

| Folder | Contents |
| --- | --- |
| `src/components/about` | Getting-started guide, hook-search caveat, and external learning resources |
| `src/components/anki` | Anki settings, card formatting, and AnkiConnect protocol |
| `src/components/appearance` | Theme and popup settings, backgrounds, and glass materials |
| `src/components/dictionaries` | Dictionary settings and results, SQLite lookup/import, ZIPs, and glossary content |
| `src/components/fonts` | Font settings and font installation |
| `src/components/pronunciation` | Playback controls, JapanesePod101 recordings, and Jisho fallback |
| `src/components/reader` | Reader UI, cached document layout and viewport rendering, history and persistence, text layout, selection, and lookup popups |
| `src/components/textractor` | Hook settings and controls, native host bindings, processes, saved hooks, and capture filters |
| `src/ui` | Shared buttons, settings sections, sidebar navigation, drop zones, and text context menus |
| `src/platform` | Windows window integration and file access, native image decoding bindings, and SQLite API declarations |
| `src/text` | Japanese matching and deinflection helpers |
| `src/checks` | Standalone smoke checks for Anki, dictionary import, pronunciation, and hooks |
| `src/native` | C/C++ implementations, Windows resources, and hook backend build files |
| `src/testdata` | Fixtures and the isolated AnkiConnect mock server |
| `src/icons`, `src/fonts`, `src/themes` | Bundled artwork, font, and themes |
| `src/third_party` | Vendored SQLite and the Textractor submodule |

Start with a feature's `*_settings.zig` or `*_ui.zig` for its settings menu.
Reader settings are in `reader.zig`; the sidebar chooses which menu to display.
Shared widgets belong in `src/ui`; feature-specific rendering stays with the
feature. Relative imports make dependencies between features explicit.

`build.zig` retains the existing build and test commands. `src/tests.zig` selects
the requested component test suite, and `src/check.zig` selects a standalone
check. These entry points keep `src` as the import root so tests and checks can
share components and bundled assets. When adding a new suite or check, register
it in the corresponding entry point and use `componentModule` in `build.zig`.

Tests stay beside the functions they exercise. Application UI integration tests
remain in `main.zig` and run through `zig build test-hook-preview`.
