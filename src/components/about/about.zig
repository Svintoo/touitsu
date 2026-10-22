//! Getting-started guide and external learning resources.
const ui = @import("ui");
const Section = @import("../../ui/settings_section.zig");
pub fn render(_: *@This(), frame: *ui.Frame) !void {
    const intro: Section = .{ .key = .str("about.intro"), .title = "About Touitsu" };
    _ = try intro.open(frame);
    try frame.e(ui.component.Text{ .key = .str("about.version"), .content = "Version: 0.1", .style = &.{ .font_size = .sm, .foreground = .dimmed }, .selectable = true });
    try paragraph(frame, .str("about.description"), "Touitsu brings visual novel text capture, dictionary lookup, and Anki card creation into one reader.");
    try intro.close(frame);

    const basics: Section = .{ .key = .str("about.basics"), .title = "Getting started" };
    _ = try basics.open(frame);
    const steps = [_][]const u8{
        "1. Import your dictionary ZIPs in Dictionaries. Set their lookup order (1 is highest) and enable the dictionaries you want to use.",
        "2. Start your game and open the Textractor tab. Find and select the game's process to attach, then advance the dialogue and select the text stream that matches it.",
        "3. Select a hook under active hooks to read the output into the main text screen, you can also add a hook code and if valid it gets saved, clipboard can be useful if youre mining videos with mpv script",
        "4. Read the captured text in the reader. Select a word or phrase to look it up. Save the selected hook to reuse it the next time you play.",
        "5. To make cards, run Anki with AnkiConnect installed. Configure your connection, deck, note type, and fields in Anki Settings, then add cards from dictionary results.",
        "6. Adjust fonts, themes, and reading direction in Font settings, Theme, and Settings.",
    };
    for (steps, 0..) |step, i| try paragraph(frame, ui.Key.str("about.step").indexed(i), step);
    try basics.close(frame);

    const hooks: Section = .{ .key = .str("about.hooks"), .title = "Hook searching" };
    _ = try hooks.open(frame);
    try paragraph(frame, .str("about.hooks.warning"), "Hook searching is still unstable and may crash Touitsu or the game. Save your game before searching.");
    try paragraph(frame, .str("about.hooks.alternative"), "Searching with the standalone Textractor app may yield better results. Once you find a working hook there, copy its hook code into Touitsu's hook-code field and click Add hook with the game attached.");
    try hooks.close(frame);

    const resources: Section = .{ .key = .str("about.resources"), .title = "More about mining" };
    _ = try resources.open(frame);
    defer resources.close(frame) catch {};
    try paragraph(frame, .str("about.resources.description"), "Animecards has guides to Japanese learning and mining, including Anki setup and capturing audio and screenshots.");
    try paragraph(frame, .str("about.resources.note"), "Skip the parts Touitsu already handles: text capture, dictionary lookup, and card creation.");
    try paragraph(frame, .str("about.animecards"), "https://animecards.site/");
}

fn paragraph(frame: *ui.Frame, key: ui.Key, text: []const u8) !void {
    try frame.e(ui.component.Text{ .key = key, .content = text, .style = &.{ .width = .grow(), .wrap = true, .font_size = .sm }, .selectable = true });
}
