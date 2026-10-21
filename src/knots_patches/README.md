App.zig is copied from Knots commit 9b5efa491005a386400695cddc9a1a4b15340c13.
Source: https://github.com/knots-ui/knots/blob/9b5efa491005a386400695cddc9a1a4b15340c13/src/App.zig

Only renderFrame is changed: validate current logical and physical extents on
every frame, after resize processing, then pass that snapshot to beginFrame.
Minimized windows stay zero-sized after their resize event has been consumed.
Worker-triggered redraws must not call beginFrame in that state.

The build creates a copy of upstream src with this App.zig overlay, without
mutating zig-pkg. Review/rebase this file when updating the Knots dependency.
Run zig build test-window for the extent guard regression test.

windows_root.zig is copied from the same upstream commit at
src/window/backend/windows/root.zig. The three HTMAXBUTTON mouse handlers now
forward to DefWindowProc for decorated/native windows. Only undecorated windows
translate these events into Knots input for custom title-bar widgets.
