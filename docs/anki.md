# Anki integration

Open **Anki Settings** in the sidebar, enable integration and keep Anki running
with AnkiConnect installed. The default server is `http://127.0.0.1:8765`.
The address and optional AnkiConnect API key are editable.

Once connected, choose your deck, note type and two destination fields.
Use a note type whose templates display the chosen front/back fields; Basic
works out of the box. This version does not supply cloze deletion markers.

Select reader text with Shift to open its dictionary popup. **Add to Anki**
creates a note using the first dictionary match:

- Front: dictionary word.
- Back: reading, definition and the full original reader line.
- Tag: `touitsu`.

After confirmation, **Show in Anki** opens Anki's browser filtered to the new
note. Notes created during this session retain that button when you select
the word again with the same deck, note type and field mapping.
AnkiConnect rejects duplicate notes; failures appear in the popup and are
never retried automatically. A failed network response can leave creation
uncertain, so check Anki before retrying.

Settings are saved in `anki-settings.json` next to the executable, including
the optional API key. Connection work runs off the UI thread. Checks repeat
every ten seconds while enabled; disabling stops new automatic requests.
An already submitted request may finish after the toggle is disabled.

Validation: `zig build test-anki` checks card mapping and protocol responses.
`zig build test-anki-http` requires Python and runs the real native HTTP client
against a temporary local mock server, without accessing your Anki collection.
