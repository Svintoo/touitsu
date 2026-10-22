//! Shared test entry point. Keep src as the import root for component tests.
const std = @import("std");
const source = @import("entrypoint").source;

test {
    if (comptime std.mem.eql(u8, source, "components/dictionaries/dictionary.zig")) {
        _ = @import("components/dictionaries/dictionary.zig");
    } else if (comptime std.mem.eql(u8, source, "components/reader/shift_selection.zig")) {
        _ = @import("components/reader/shift_selection.zig");
    } else if (comptime std.mem.eql(u8, source, "components/anki/anki_connect.zig")) {
        _ = @import("components/anki/anki_connect.zig");
    } else if (comptime std.mem.eql(u8, source, "components/anki/anki_settings.zig")) {
        _ = @import("components/anki/anki_settings.zig");
    } else if (comptime std.mem.eql(u8, source, "components/pronunciation/audio_sources.zig")) {
        _ = @import("components/pronunciation/audio_sources.zig");
    } else if (comptime std.mem.eql(u8, source, "platform/image_decode.zig")) {
        _ = @import("platform/image_decode.zig");
    } else if (comptime std.mem.eql(u8, source, "components/reader/reading_layout.zig")) {
        _ = @import("components/reader/reading_layout.zig");
    } else {
        @compileError("Unknown component test source");
    }
}
