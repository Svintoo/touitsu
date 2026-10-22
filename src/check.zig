//! Entry point for the standalone checks selected by build.zig.
const std = @import("std");
const source = @import("entrypoint").source;

pub const main = if (std.mem.eql(u8, source, "checks/anki_smoke.zig"))
    @import("checks/anki_smoke.zig").main
else if (std.mem.eql(u8, source, "checks/dictionary_import_smoke.zig"))
    @import("checks/dictionary_import_smoke.zig").main
else if (std.mem.eql(u8, source, "checks/pronunciation_smoke.zig"))
    @import("checks/pronunciation_smoke.zig").main
else if (std.mem.eql(u8, source, "checks/tx_test.zig"))
    @import("checks/tx_test.zig").main
else
    @compileError("Unknown standalone check source");
