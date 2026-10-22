# Native dictionary lookup

Touitsu imports Yomitan format 3 term dictionary ZIPs into `dictionaries.sqlite3`
beside the running executable. No browser, extension, or network connection is
needed for lookup. Dictionaries are supplied by the user; none are bundled.

## Use

1. Place Yomitan format 3 term dictionary ZIPs in `dicts` beside `Touitsu.exe`.
2. Start or restart Touitsu. ZIPs are scanned in the background; unchanged
   archives reuse the SQLite cache. No dictionary import form is needed.
3. Open the Dictionaries sidebar tab for scan status, counts, and lookup priorities.
   Rank 1 is highest. Each dictionary has an Enable/Disable button; disabling
   excludes it from lookup results and word matching while retaining its rank.
   The enabled state is saved by title and survives restarts and ZIP replacement.
4. Hold Shift over a character in the reader to highlight the longest dictionary
   word beginning there, without holding a mouse button. For example, hovering
   文 in 文字 highlights 文字. Release Shift to keep the selection. The floating dictionary
   window shows matching expressions, readings, definitions, and dictionary names.

Shift is polled while Touitsu is unfocused, so the game can retain focus.
The pointer must be over the visible reader; covered windows are not scanned.
Shift is not intercepted or suppressed in the foreground game. Starting a new
Shift gesture replaces the previous selection. Selection stays within one
reader entry. The Reader Options menu's "Automatically select dictionary words"
option enables word scanning by default. Turn it off to extend a manual selection
by moving across glyphs. "Always select entire line" takes precedence over word
scanning. The same scanner is used by horizontal and both vertical layouts.

The popup opens above the selection when there is space, otherwise below it.
Its content scrolls. Full-word/deinflected matches appear first, followed by
exact term matches for the starting kanji (for example, 文字 then 文). Dictionary
priority applies within each group; duplicate rows already in the word group
are excluded from the character group. A single-character selection is not
repeated, and kana/Latin selections do not add a kanji group.
Each group fetches up to 30 entries. The popup displays at most 32 visual lines,
including group labels and space occupied by images. When both groups exist,
word matches use at most 24 lines so the character group has at least 8 lines;
unused word space is available to the character group.

Changing a dictionary ZIP replaces its previous entries in a transaction. A
failed import rolls back that replacement. A successful folder scan removes
cached dictionaries whose ZIPs are no longer present. A failed scan preserves
older cached entries. Use one ZIP per dictionary title. The folder is the source
of truth: previously manually imported dictionaries need their ZIP in `dicts`.
Imported data survives application restarts. Preview builds have their own database beside the
preview executable, separate from `zig-out/bin`.

## First milestone

Supported: format 3 `index.json`, `term_bank_N.json`, standard stored/deflated ZIPs,
expression/reading lookup and common Japanese deinflection across imported
dictionaries, plus readable
text from structured definitions. Image-bearing definitions retain their original
text/image order. Archive-local PNG, JPEG, GIF, BMP and SVG assets are stored as
SQLite blobs and decoded on demand; WebP depends on installed WIC codec support.
Monochrome gaiji use the theme text color. CSS and interactive links are not rendered. The engine is independently implemented against the
published format; no Yomitan source is incorporated.

Native Japanese lookup supports common polite, negative, past, te/progressive,
potential/passive, causative, conditional, volitional, and adjective forms,
including chained forms and suru/kuru irregulars. For example, 食べました resolves
to 食べる. Suru compounds can resolve to noun headwords such as 勉強. Dictionary
conjugation metadata filters candidates when available; dictionaries without it
use headword matches. Popup results show the reversal steps, and Anki receives
the dictionary headword. This is an independent implementation, not full Yomitan
language-engine parity.

Scanning examines at most 32 codepoints from the hovered glyph and respects
sentence/whitespace boundaries. Candidate generation is bounded to 192 forms
and six reversal steps. Repeated hovering on the same source position reuses
its match. Dictionary priorities are preserved, and duplicate result rows are
removed before the per-group 30-result and shared 32-display-line limits.

Not implemented yet: comprehensive text normalization, dictionary enable controls,
kanji dictionaries, frequency/pitch metadata, and audio.
Dictionary priorities and Anki integration are supported. Metadata-only and kanji-only dictionaries are rejected with
`NoTermEntries` rather than reported as usable term dictionaries.

Compressed archives are memory-mapped; one decompressed JSON bank is parsed at a
time, with unescaped strings borrowed from that bank. Archive paths are never
extracted to disk. Limits: ordinary ZIP up to 4 GiB minus 1 byte, 128 MiB per bank,
16 GiB cumulative decompressed term banks and media, and 64 MiB per image file.
ZIP64, encryption and multi-disk archives are unsupported. Import failures preserve
existing entries. Existing cached archives automatically reimport once after the
image-support upgrade, preserving title-based dictionary priorities.

Raster images are decoded using WIC; SVG images use Direct2D's SVG support
(Windows 10 Creators Update or later). Decoded images have a maximum side of
1024 pixels (512 for SVG), and the popup keeps at most 32 MiB of decoded pixels
per selection. Original media blobs remain available in the dictionary database.
Image-only entries are retained even when they have no searchable headword.
Anki continues to receive the complete plain-text definition.

## Source layout

- `dictionary.zig`: transactional SQLite import, glossary text, indexed lookup and word scanning.
- `japanese.zig`: native conjugation candidates, dictionary class filtering and scan boundaries.
- `dictionary_zip.zig`: bounded ZIP reader and CRC verification.
- `dictionary_content.zig`: structured glossary text/image runs.
- `image_decode.zig` / `native/image_decode.cpp`: WIC and Direct2D asset decoding.
- `sqlite_api.zig`: declarations for the SQLite C API subset in use.
- `dictionary_files.zig`: archive reads and executable-relative database path.
- `dictionary_ui.zig`: folder scanning, worker ownership, cached results and result UI.
- `selection_popup.zig`: selection positioning and floating dictionary window.
- `shift_selection.zig`: background Shift/cursor polling and UTF-8 glyph selection.
- `third_party/sqlite`: pinned official SQLite amalgamation and provenance.

## Validation

Run `zig build test-dictionary`. Synthetic fixtures test Japanese expressions
and readings, structured glossary text, stored and deflated archives, failed
replacement rollback, successful replacement, checksum errors, unsupported
formats, blank queries, image blobs, image-only headwords, import-cache upgrades,
priorities, and closing/reopening the persistent database. `zig build test-image`
checks both raster and SVG decoding. `zig test src/components/dictionaries/dictionary_content.zig` checks
structured text/image ordering. Dictionary/selection tests also cover longest
matches, deinflection chains, conjugation metadata, source UTF-8 ranges, and
whole-line/manual selection precedence. To check an existing verification database:
`zig build check-dictionary-import -Doptimize=ReleaseFast -- --lookup .zig-cache/check.sqlite3 食べました`

For a real-archive check without modifying the application's database:
`zig build check-dictionary-import -Doptimize=ReleaseFast -- .zig-cache/check.sqlite3 path/to/dictionary.zip`
The supplied database path is explicit; use a separate verification database.
The tool imports every supplied ZIP and decodes a sample PNG/SVG asset.

Format reference: https://github.com/yomidevs/yomitan/blob/master/docs/making-yomitan-dictionaries.md

Run `zig build test-selection` for gesture extension and wrapped UTF-8 glyph hit tests.

## Fonts and sidebar

The sidebar has **Textractor** and **Font settings** tabs. The header and tabs
remain visible while the current tab's content scrolls. The hamburger/collapse
controls apply to the entire sidebar.

Place Japanese-capable TrueType `.ttf` files in `fonts` beside the executable and
restart Touitsu. The build also places the bundled `jp.ttf` there. Font settings
controls the reader's font, reader text size, dictionary text size and spacing
between reader entries. Values persist in `font-settings.json`. The UI keeps
its bundled font so controls remain readable when a custom font is unsuitable.
Some OpenType/CFF and font collection formats are not supported by this loader.

Every reader entry has an end-of-line delete button visible only while that row
is hovered. Space for the button stays reserved, so hovering does not rewrap
text. Deletion still supports Undo and updates the persisted reading log.

## Background image

Open **Settings** in the sidebar and drop a PNG, JPEG, BMP or GIF into the
**Background image** drop zone. The first frame of an animated image is used.
The image fills the reader area with centered cropping and is drawn underneath
the glass surface. Reader text and controls remain separate from the image.

A copy is saved as `reader-background.image` beside the executable and restored
on startup; moving the original picture does not break the background.
**Remove background** clears that saved copy. Invalid images leave the current
background unchanged. Limits: 64 MiB source file, 8192 pixels per side, 32 million
pixels total. Decoding uses Windows Imaging Component.

This pinned Knots version has file drops through `Frame.droppedPaths()`.
`src/ui/drops.zig` supplies the UI drop-zone component; `src/components/appearance/background_image.zig`
handles settings and rendering, and `src/platform/image_decode.zig` wraps the native
Windows decoder. `zig build test-image` validates PNG decoding and invalid input.
Sidebar icon insertion comments are beside the items in `SidebarTabs.render`
in `src/main.zig`.

Settings also includes a Light/Dark theme dropdown using Knots' built-in themes,
a reader glass blur slider (0-40 px), a Knots tint color picker and tint opacity
slider. Changes apply immediately and persist in `appearance.json` beside the
executable. Tint color/opacity replaces the reader's old fixed `white_tint`;
blur changes the glass material independently. The dictionary popup keeps its
own glass settings.

The collapsed sidebar now retains its full-height edge button, which toggles
between collapse and expand arrows. Settings includes all ten Knots playground
themes: Light, Dark, Forest night, Graphite neon, Gruvbox, Midnight ocean,
Monochrome ash, Nord frost, Rose mist, and Warm sand. The eight additional theme
files are kept under `src/themes` with upstream attribution.

## Reading direction

The reader exposes all retained history as one continuous document, within the
existing approximate 500,000-word, 8 MiB, and 100,000-line limits. There is no
separate character/page display limit. `reader_document.zig` caches each entry's
layout and renders a viewport with overscan, preserving the full scroll extent
and original text for selection. Vertical character cells are also culled outside
that range. Latest returns to the newest text; incoming text preserves the
current paragraph position when the reader is away from the latest edge.

Custom glyph layouts use a bounded cache. Accessibility exposes a paragraph text
run rather than a node for every glyph, keeping small-font/fullscreen layouts
below Knots' node limit. Character counts are cached until history or count
options change. Hook events wake the UI immediately; the idle timeout refreshes
timers and background jobs once per second without an extra forced redraw.

Settings -> Text direction offers Horizontal, Vertical: left to right, and
Vertical: right to left. Direction persists in `appearance.json`.
Vertical text reads top to bottom and wraps into columns in the selected order.
Entries also progress in that order. The ordinary wheel follows that progression;
wheel-up reverses it. Horizontal trackpad gestures and scrollbar dragging remain
available. Latest and incoming-text follow mode use the corresponding latest edge.
Wheel input over the dictionary popup continues to scroll the popup itself.

Shift selection, dictionary lookup, and hover-only entry deletion work in both
orientations. Vertical selection retains the original text's UTF-8 offsets.
The initial vertical renderer uses upright character cells and common Japanese
vertical punctuation substitutions; full OpenType vertical shaping, sideways
Latin runs and complex combining/grapheme handling are not implemented.
Run `zig build test-reading test-selection` for the layout/scroll and selection
checks. Native layout is in `reading_layout.zig` and `vertical_reader.zig`.

Font settings includes Character spacing (0-24 px), persisted with the font
settings. It changes spacing between characters in horizontal and vertical
reader layouts; wrapping, selection byte offsets and the delete button follow
the spaced layout. At nonzero horizontal spacing the reader uses character
cells, so advanced ligature/grapheme shaping is not applied.

Touitsu starts at its normal windowed size with the native Windows title bar and minimize,
maximize/restore and close controls. Window management uses these native controls.
The root layout uses the current logical client-area size after resizing.

F11 and Settings > Display toggle Knots' fullscreen display mode, hiding the
native title bar and covering the monitor. Escape exits fullscreen. Touitsu
remembers whether the previous mode was maximized or windowed when restoring.
Reader scrollbar presses own their entire drag until release, including when the
pointer moves over text. Both horizontal and vertical scrollbar gutters are
excluded from new reader selection gestures.

Knots is used without source overlays. `src/platform/window_integration.zig`
sets the embedded resource icon on the application window using `WM_SETICON`.
It wraps Knots' frame handler through `Window.setFrameHandler` after the first
frame, skipping subsequent frames while client or framebuffer dimensions are
zero. This prevents worker-triggered redraws from entering the UI while minimized.
On restore, the existing Knots handler consumes the resize and resumes rendering.

A Windows window subclass routes native caption maximize-button mouse messages
to `DefWindowProcW`, leaving other messages with Knots. The pinned Knots backend
otherwise intercepts these messages for custom title-bar widgets even when the
application uses native decorations. This is an application-side workaround,
not a fix supplied by the framework. Remove it when upstream supports the case.

`zig build test-window` launches a disposable copy of Touitsu, checks both window
icons, sends repeated paint requests while minimized, cycles restore/maximize,
and checks clean shutdown. It requires a Windows desktop and working Vulkan
driver. It tests maximize through system commands; physical caption-button clicks
and the Windows snap flyout still need a manual check.

## Textractor shutdown

Normal application exit calls `Client.shutdown(5000)` before disposing reader or
UI resources. The native shim tracks actual connected and still-connecting
processes, including automatic reconnects that may not be in the UI attach list.
It sends detach commands and waits for disconnect callbacks, detaches connections
that complete during shutdown, and stops forwarding text/search callbacks.
A five-second timeout logs any unconfirmed connections rather than waiting
indefinitely. This is graceful-close handling; force termination cannot run it.
