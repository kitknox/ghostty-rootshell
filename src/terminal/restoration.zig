//! ROOTSHELL: terminal restoration replay.
//!
//! Serializes a terminal as VT bytes that rebuild it in a fresh terminal: both
//! screens, their Kitty keyboard stacks and DECSC slots, modes and their
//! XTSAVE values, tab stops, margins, charsets, the pen and the cursor. The
//! embedder stores the bytes and replays them into a new surface after the
//! process is relaunched while the remote program kept running.
//!
//! An open hyperlink and character protection are left out on purpose. The
//! output a restored program resumes with can have a gap, and if the bytes
//! that end either one fell into it, everything printed later would inherit
//! them.
//!
//! Everything is read from the terminal itself. An embedder that mirrors this
//! state from the output stream has to predict the parser byte for byte, and
//! one that queries it has to inject requests into that stream, which is not
//! safe inside a passthrough such as tmux control mode.
const restoration = @This();

const std = @import("std");
const charsets = @import("charsets.zig");
const formatter = @import("formatter.zig");
const kitty = @import("kitty.zig");
const modespkg = @import("modes.zig");
const mouse = @import("mouse.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Selection = @import("Selection.zig");
const size = @import("size.zig");
const stream = @import("stream.zig");
const Terminal = @import("Terminal.zig");

const Writer = std.Io.Writer;

/// Where the primary screen dump sits inside a snapshot, so the embedder can
/// store or truncate it without dumping the screen a second time. Bytes that
/// belong to the snapshot come both before and after it.
pub const Range = struct {
    offset: usize,
    len: usize,
};

/// CUP addresses the whole screen once origin mode and the margins are off.
const absolute_addressing = "\x1b[?6l\x1b[?69l\x1b[r";

/// Leaves the cursor with a wrap pending where it stands: the fork's
/// `restore_pending_wrap` action (stream.zig). CUP clears a pending wrap,
/// and printing only sets one at the right margin or in the last column,
/// while DECRC and a screen switch can leave one anywhere.
const pending_wrap = std.fmt.comptimePrint(
    "\x1b[?{d}h",
    .{stream.Action.restore_pending_wrap_param},
);

/// The pen a screen dump expects: no attributes, ASCII in every slot, G0 in GL
/// and G2 in GR.
const neutral_pen = "\x1b[0m\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b}";

/// Write the complete replay to `aw` and return the range of the primary
/// screen dump, or null if the primary screen has nothing to dump.
///
/// The bytes start with RIS, so they are self-contained: whatever the target
/// showed before is discarded. The caller must hold the terminal's lock.
pub fn writeSnapshot(
    t: *const Terminal,
    aw: *Writer.Allocating,
) Writer.Error!?Range {
    const w = &aw.writer;
    const primary = t.screens.get(.primary) orelse return null;

    try w.writeAll("\x1bc");

    // Each screen's DECSC slot goes before its contents, while the screen
    // is still empty: a slot can hold a single shift, which only printing
    // uses up, so it is spent on a space that is erased again.
    // The dump replays the primary screen `raised` rows higher than it is
    // here, so every row on that screen is addressed that much higher too.
    const raised = primaryBoundary(primary).raised;
    try writeSavedCursor(w, primary, raised);
    const offset = aw.written().len;
    if (!try writePrimaryScreen(t, w)) return null;
    const range: Range = .{ .offset = offset, .len = aw.written().len - offset };
    try writeKittyKeyboard(w, primary.kitty_keyboard);

    // Also while the primary screen is active: the alternate one keeps its
    // keyboard stack and DECSC slot, and under mode 47 its contents, for the
    // next time the program switches to it.
    if (t.screens.get(.alternate)) |alternate| {
        // Mode 47 switches without clearing or saving the cursor: 1049 would
        // overwrite the primary DECSC slot written above.
        try w.writeAll("\x1b[?47h" ++ absolute_addressing ++ neutral_pen);
        try writeSavedCursor(w, alternate, 0);
        _ = try writeAlternateScreen(t, w);
        try writeKittyKeyboard(w, alternate.kitty_keyboard);
        if (t.screens.active_key == .primary) try w.writeAll("\x1b[?47l");
    }

    try writeTabstops(t, w);
    try writeModes(t, w);
    try writeMargins(t, w);
    if (t.flags.modify_other_keys_2) try w.writeAll("\x1b[>4;2m");
    switch (t.flags.mouse_shift_capture) {
        .null => {},
        .false => try w.writeAll("\x1b[>0s"),
        .true => try w.writeAll("\x1b[>1s"),
    }
    try writeCursorStyle(t, w);

    // Last, because the modes and margins above home the cursor.
    try writeCursor(t, w, raised);
    var pen: formatter.ScreenFormatter = .init(t.screens.active, dumpOptions(t, false));
    pen.content = .none;
    pen.extra = .{
        .cursor = false,
        .style = true,
        .hyperlink = false,
        .protection = false,
        .kitty_keyboard = false,
        .charsets = true,
    };
    try pen.format(w);
    // Last of all: the next printed character uses it up.
    try writeSingleShift(w, t.screens.active.charset);

    return range;
}

/// Dump the primary screen, scrollback included, as ANSI-styled text. Reads
/// the primary screen even while the alternate one is active. Soft-wrapped
/// lines are unwrapped so they re-wrap at any width. Returns false if there
/// is nothing to dump.
/// Where the dump of the primary screen splits scrollback from the active
/// area. The boundary moves down so it doesn't split a soft-wrapped line: if
/// the last scrollback row has wrap=true, the first active row is a
/// continuation, and the whole wrapped line goes out with the scrollback to
/// preserve unwrap continuity. The active area is then replayed `raised`
/// rows higher than it is here.
fn primaryBoundary(screen: *const Screen) struct {
    top: PageList.Pin,
    raised: size.CellCountInt,
} {
    var top = screen.pages.getTopLeft(.active);
    var raised: size.CellCountInt = 0;
    while (true) {
        const above = top.up(1) orelse break;
        if (!above.rowAndCell().row.wrap) break;
        // Row above has wrap=true, so `top` is a continuation. Move it
        // forward past this row.
        top = top.down(1) orelse break;
        raised += 1;
    }
    return .{ .top = top, .raised = raised };
}

pub fn writePrimaryScreen(t: *const Terminal, w: *Writer) Writer.Error!bool {
    const screen = t.screens.get(.primary) orelse return false;
    _ = screen.pages.getBottomRight(.screen) orelse return false;
    const br_active = screen.pages.getBottomRight(.active) orelse return false;

    const boundary = primaryBoundary(screen);
    const adjusted_tl_active = boundary.top;
    const boundary_offset = boundary.raised;

    const fmt_opts = dumpOptions(t, true);

    // Phase 1: Dump scrollback (everything above the adjusted active
    // boundary). We check if there's a row above the boundary; if so,
    // scrollback exists and we dump it separately.
    if (adjusted_tl_active.up(1)) |last_scrollback| {
        const tl_screen = screen.pages.getTopLeft(.screen);
        var br_scrollback = last_scrollback;
        br_scrollback.x = screen.pages.cols - 1;

        var scrollback_fmt: formatter.ScreenFormatter = .init(screen, fmt_opts);
        scrollback_fmt.content = .{
            .selection = Selection.init(tl_screen, br_scrollback, false),
        };
        try scrollback_fmt.format(w);

        // Emit LF × rows to push scrollback content into the
        // scrollback buffer. Unlike SU (which scrolls regardless of
        // cursor position and can inject blank rows into history),
        // LF first moves the cursor down through existing blank rows
        // without scrolling, then only scrolls when it reaches the
        // bottom margin — so only actual content enters scrollback.
        for (0..screen.pages.rows) |_| try w.writeByte('\n');
    }

    // Phase 2: Emit active area on a clean viewport.
    // Reset SGR, home the cursor, then clear from home before writing
    // active content. The earlier scrollback replay may leave wider
    // historical rows in the viewport; clearing here prevents shorter
    // active rows (for example prompts) from drawing over stale cells.
    try w.writeAll("\x1b[0m\x1b[H\x1b[J");

    var active_fmt: formatter.ScreenFormatter = .init(screen, fmt_opts);
    active_fmt.content = .{
        .selection = Selection.init(adjusted_tl_active, br_active, false),
    };
    try active_fmt.format(w);

    // No erase after the content: the viewport was cleared before it, and a
    // last row that fills the width leaves the cursor on its last cell with
    // a wrap pending, where ED would take that cell away.
    try w.writeAll("\x1b[0m");

    // Position cursor within the active area. Adjust for any rows
    // that were moved from the active area into the scrollback pass
    // due to wrap continuation boundary adjustment.
    try w.print("\x1b[{d};{d}H", .{
        @as(usize, screen.cursor.y -| boundary_offset) + 1,
        @as(usize, screen.cursor.x) + 1,
    });
    return true;
}

/// Dump the alternate screen's viewport as ANSI-styled text. Rows are not
/// unwrapped: cursor-addressed programs own their layout. Returns false if
/// the alternate screen was never initialized.
pub fn writeAlternateScreen(t: *const Terminal, w: *Writer) Writer.Error!bool {
    const screen = t.screens.get(.alternate) orelse return false;
    const br_active = screen.pages.getBottomRight(.active) orelse return false;
    const tl_active = screen.pages.getTopLeft(.active);

    // Clear the viewport, then emit it. The erase comes first: after a last
    // row that fills the width, such as a status line, the cursor sits on
    // its last cell with a wrap pending and ED would take that cell away.
    try w.writeAll("\x1b[0m\x1b[H\x1b[J");

    var active_fmt: formatter.ScreenFormatter = .init(screen, dumpOptions(t, false));
    active_fmt.content = .{
        .selection = Selection.init(tl_active, br_active, false),
    };
    try active_fmt.format(w);
    try w.writeAll("\x1b[0m");

    try w.print("\x1b[{d};{d}H", .{
        @as(usize, screen.cursor.y) + 1,
        @as(usize, screen.cursor.x) + 1,
    });
    return true;
}

fn dumpOptions(t: *const Terminal, unwrap: bool) formatter.Options {
    return .{
        .emit = .vt,
        .unwrap = unwrap,
        .trim = false,
        .palette = &t.colors.palette.current,
    };
}

/// Rebuild the whole Kitty keyboard stack, not only its top: the program pops
/// back to the entries below when it exits. The stack's screen must be the
/// active one when the bytes are replayed.
fn writeKittyKeyboard(w: *Writer, stack: kitty.KeyFlagStack) Writer.Error!void {
    const used = for (stack.flags) |flags| {
        if (flags.int() != kitty.KeyFlags.disabled.int()) break true;
    } else false;
    if (!used) return;

    // The stack is a ring, so pushing every entry from the oldest to the
    // current one rotates it without changing what a pop reveals.
    try w.print("\x1b[<{d}u", .{stack.flags.len});
    for (1..stack.flags.len + 1) |step| {
        const i = (@as(usize, stack.idx) + step) % stack.flags.len;
        try w.print("\x1b[>{d}u", .{stack.flags[i].int()});
    }
}

/// The active screen's cursor. The dumps positioned it on an unconstrained
/// screen; in origin mode CUP counts from the top-left of the scrolling
/// region, which is in place by now.
fn writeCursor(
    t: *const Terminal,
    w: *Writer,
    raised: size.CellCountInt,
) Writer.Error!void {
    const cursor = &t.screens.active.cursor;
    var top: size.CellCountInt = if (t.screens.active_key == .primary) raised else 0;
    var left: size.CellCountInt = 0;
    if (t.modes.get(.origin)) {
        top +|= t.scrolling_region.top;
        left = t.scrolling_region.left;
    }
    try w.print("\x1b[{d};{d}H", .{
        @as(usize, cursor.y -| top) + 1,
        @as(usize, cursor.x -| left) + 1,
    });
    if (cursor.pending_wrap) try w.writeAll(pending_wrap);
}

/// Recreate a screen's DECSC slot. The screen must be the active one and
/// still empty when the bytes are replayed; its contents come `raised` rows
/// higher than they are here. The slot holds an absolute position, so the
/// margins come off first; writeSnapshot restores them afterwards.
fn writeSavedCursor(
    w: *Writer,
    screen: *const Screen,
    raised: size.CellCountInt,
) Writer.Error!void {
    const saved = screen.saved_cursor orelse return;

    try w.writeAll(absolute_addressing);
    try w.print("{f}", .{saved.style.formatterVt()});
    try writeCharsets(w, saved.charset);
    // Origin mode homes the cursor, so set it before the position. With full
    // margins the origin is still the top-left of the screen.
    if (saved.origin) try w.writeAll("\x1b[?6h");
    try w.print("\x1b[{d};{d}H", .{
        @as(usize, saved.y -| raised) + 1,
        @as(usize, saved.x) + 1,
    });
    if (saved.pending_wrap) try w.writeAll(pending_wrap);
    try writeSingleShift(w, saved.charset);
    try w.writeAll("\x1b7");

    // The slot's pen must not leak into the screen dump that follows.
    // Resetting origin mode homes the cursor.
    try w.writeAll("\x1b[?6l" ++ neutral_pen);
    // Nor its single shift, which stays behind until a character is
    // printed: a space, which no charset maps, on the still empty screen.
    if (saved.charset.single_shift != null) try w.writeAll(" \x1b[H\x1b[J");
}

/// SS2 or SS3 for a single shift that is waiting for its character.
fn writeSingleShift(w: *Writer, state: Screen.CharsetState) Writer.Error!void {
    const slot = state.single_shift orelse return;
    try w.writeAll(switch (slot) {
        .G2 => "\x1bN",
        .G3 => "\x1bO",
        // Only G2 and G3 have a single shift.
        .G0, .G1 => "",
    });
}

fn writeCharsets(w: *Writer, state: Screen.CharsetState) Writer.Error!void {
    for (std.enums.values(charsets.Slots)) |slot| {
        const intermediate: u8 = switch (slot) {
            .G0 => '(',
            .G1 => ')',
            .G2 => '*',
            .G3 => '+',
        };
        const final: u8 = switch (state.charsets.get(slot)) {
            .utf8, .ascii => 'B',
            .british => 'A',
            .dec_special => '0',
        };
        try w.writeAll(&.{ 0x1b, intermediate, final });
    }
    try w.writeAll(switch (state.gl) {
        .G0 => "\x0f",
        .G1 => "\x0e",
        .G2 => "\x1bn",
        .G3 => "\x1bo",
    });
    try w.writeAll(switch (state.gr) {
        .G0 => "", // GR can't hold G0.
        .G1 => "\x1b~",
        .G2 => "\x1b}",
        .G3 => "\x1b|",
    });
}

/// Tab stops, if the program moved them off the default of every 8 columns.
/// Runs before the modes: origin mode would shift the column addressing.
fn writeTabstops(t: *const Terminal, w: *Writer) Writer.Error!void {
    const moved = for (0..t.cols) |col| {
        const default = col != 0 and col % 8 == 0 and col < t.cols - 1;
        if (t.tabstops.get(col) != default) break true;
    } else false;
    if (!moved) return;

    try w.writeAll("\x1b[3g");
    for (0..t.cols) |col| {
        if (t.tabstops.get(col)) try w.print("\x1b[{d}G\x1bH", .{col + 1});
    }
}

/// Modes whose set or reset does more than flip the bit, in a way a replay
/// must not repeat.
fn replayable(mode: modespkg.Mode) bool {
    return switch (mode) {
        // DECCOLM resizes and clears the screen, and mode 40 only arms it.
        .@"132_column",
        .enable_mode_3,
        // Both screens and their DECSC slots are replayed explicitly.
        .alt_screen_legacy,
        .alt_screen,
        .alt_screen_save_cursor_clear_enter,
        .save_cursor,
        // Would hold back rendering until a timer fires.
        .synchronized_output,
        => false,

        else => true,
    };
}

/// The modes that select the mouse event and the mouse format. Each group
/// shares one effective value in the terminal flags.
const mouse_event_modes = [_]modespkg.Mode{
    .mouse_event_x10,
    .mouse_event_normal,
    .mouse_event_button,
    .mouse_event_any,
};
const mouse_format_modes = [_]modespkg.Mode{
    .mouse_format_utf8,
    .mouse_format_sgr,
    .mouse_format_urxvt,
    .mouse_format_sgr_pixels,
};

fn isMouseMode(mode: modespkg.Mode) bool {
    for (mouse_event_modes ++ mouse_format_modes) |m| {
        if (m == mode) return true;
    }
    return false;
}

/// One mouse group: every bit the program set, and the value in effect. The
/// mode set last wins and resetting any mode of the group turns its value
/// off, so the bits alone don't say what is in effect; a mode query still
/// reports each bit.
fn writeMouseGroup(
    t: *const Terminal,
    w: *Writer,
    group: []const modespkg.Mode,
    effective: ?modespkg.Mode,
) Writer.Error!void {
    var any = false;
    for (group) |mode| {
        if (!t.modes.get(mode)) continue;
        any = true;
        if (effective == null or effective.? != mode) try writeMode(w, mode, true);
    }
    if (effective) |mode| {
        // Set last, so it is the one in effect.
        if (t.modes.get(mode)) try writeMode(w, mode, true);
        return;
    }
    if (!any) return;

    // Bits are set but nothing is in effect: the program reset another mode
    // of the group afterwards. Resetting one that is reset does the same.
    for (group) |mode| {
        if (!t.modes.get(mode)) return writeMode(w, mode, false);
    }
}

fn writeMode(w: *Writer, mode: modespkg.Mode, enabled: bool) Writer.Error!void {
    const tag: modespkg.ModeTag = .fromMode(mode);
    try w.print("\x1b[{s}{d}{c}", .{
        if (tag.ansi) "" else "?",
        tag.value,
        @as(u8, if (enabled) 'h' else 'l'),
    });
}

fn writeModes(t: *const Terminal, w: *Writer) Writer.Error!void {
    const initial: modespkg.ModePacked = .{};
    const mode_fields = @typeInfo(modespkg.Mode).@"enum".fields;

    // XTSAVE values first: saving copies the current value, so each mode is
    // set to its saved value, saved, and then given its real value below.
    // Only DEC private modes can be saved.
    inline for (mode_fields) |field| {
        const mode: modespkg.Mode = @enumFromInt(field.value);
        const saved = @field(t.modes.saved, field.name);
        if (comptime replayable(mode) and !modespkg.ModeTag.fromMode(mode).ansi) {
            if (saved != @field(initial, field.name)) {
                try writeMode(w, mode, saved);
                try w.print("\x1b[?{d}s", .{modespkg.ModeTag.fromMode(mode).value});
            }
        }
    }

    inline for (mode_fields) |field| {
        const mode: modespkg.Mode = @enumFromInt(field.value);
        if (comptime replayable(mode)) {
            // What the target holds now: the saved value if the pass above
            // wrote one, the reset default otherwise.
            const saved = @field(t.modes.saved, field.name);
            const wrote_saved = comptime !modespkg.ModeTag.fromMode(mode).ansi;
            const before = if (wrote_saved and saved != @field(initial, field.name))
                saved
            else
                @field(t.modes.default, field.name);
            const current = t.modes.get(mode);
            if (comptime isMouseMode(mode)) {
                // Reset here; writeMouseGroup decides what gets set.
                if (before) try writeMode(w, mode, false);
            } else if (current != before or mode == .cursor_blinking) {
                // Blinking is always written: a reset leaves it at the
                // cursor's configured default, not at the mode's.
                try writeMode(w, mode, current);
            }
        }
    }

    try writeMouseGroup(t, w, &mouse_event_modes, switch (t.flags.mouse_event) {
        .none => null,
        .x10 => .mouse_event_x10,
        .normal => .mouse_event_normal,
        .button => .mouse_event_button,
        .any => .mouse_event_any,
    });
    try writeMouseGroup(t, w, &mouse_format_modes, switch (t.flags.mouse_format) {
        .x10 => null,
        .utf8 => .mouse_format_utf8,
        .sgr => .mouse_format_sgr,
        .urxvt => .mouse_format_urxvt,
        .sgr_pixels => .mouse_format_sgr_pixels,
    });
}

fn writeMargins(t: *const Terminal, w: *Writer) Writer.Error!void {
    const region = &t.scrolling_region;
    if (region.top != 0 or region.bottom != t.rows - 1) {
        try w.print("\x1b[{d};{d}r", .{
            @as(usize, region.top) + 1,
            @as(usize, region.bottom) + 1,
        });
    }
    // Without mode 69 `CSI s` saves the cursor instead.
    if (t.modes.get(.enable_left_and_right_margin) and
        (region.left != 0 or region.right != t.cols - 1))
    {
        try w.print("\x1b[{d};{d}s", .{
            @as(usize, region.left) + 1,
            @as(usize, region.right) + 1,
        });
    }
}

/// DECSCUSR, only if the program chose a shape: `CSI 0 SP q` would otherwise
/// pin whatever the default is today.
fn writeCursorStyle(t: *const Terminal, w: *Writer) Writer.Error!void {
    if (t.cursor.is_default) return;
    const blink = t.modes.get(.cursor_blinking);
    const steady: u8 = switch (t.screens.active.cursor.cursor_style) {
        .bar => 6,
        .underline => 4,
        else => 2,
    };
    try w.print("\x1b[{d} q", .{if (blink) steady - 1 else steady});
}

const testing = std.testing;

/// Feeds `input` to a terminal, replays its snapshot into a second one and
/// hands both to `check`.
fn expectRoundTrip(
    input: []const u8,
    comptime check: fn (*Terminal, *Terminal) anyerror!void,
) !void {
    const alloc = testing.allocator;

    var t = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(input);

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const range = (try writeSnapshot(&t, &aw)).?;
    const replay = aw.written();
    try testing.expect(std.mem.startsWith(u8, replay, "\x1bc"));
    try testing.expect(range.offset >= 2 and range.offset + range.len <= replay.len);

    var t2 = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    // The target is never pristine: it has shown a connection spinner.
    s2.nextSlice("\x1b[?1049h\x1b[?25l\x1b[2;4r\x1b[>5uspinner\x1b(0");
    s2.nextSlice(replay);

    try expectSameState(&t, &t2);
    try check(&t, &t2);

    // A snapshot of the restored terminal restores the same terminal.
    var aw2: Writer.Allocating = .init(alloc);
    defer aw2.deinit();
    _ = (try writeSnapshot(&t2, &aw2)).?;
    var t3 = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t3.deinit(alloc);
    var s3 = t3.vtStream();
    defer s3.deinit();
    s3.nextSlice(aw2.written());
    try expectSameState(&t2, &t3);
}

fn expectSameScreenText(a: *Terminal, b: *Terminal, key: @TypeOf(a.screens.active_key)) !void {
    const sa = a.screens.get(key).?;
    const sb = b.screens.get(key).?;
    const alloc = testing.allocator;
    const ta = try sa.dumpStringAlloc(alloc, .{ .active = .{} });
    defer alloc.free(ta);
    const tb = try sb.dumpStringAlloc(alloc, .{ .active = .{} });
    defer alloc.free(tb);

    try testing.expectEqualStrings(ta, tb);
}

fn expectSameState(a: *Terminal, b: *Terminal) !void {
    try testing.expectEqual(a.screens.active_key, b.screens.active_key);
    try expectSameScreenText(a, b, .primary);
    if (a.screens.get(.alternate) != null) try expectSameScreenText(a, b, .alternate);

    inline for (@typeInfo(modespkg.Mode).@"enum".fields) |field| {
        const mode: modespkg.Mode = @enumFromInt(field.value);
        if (comptime replayable(mode)) {
            testing.expectEqual(a.modes.get(mode), b.modes.get(mode)) catch |err| {
                std.debug.print("mode {s} differs\n", .{field.name});
                return err;
            };
            testing.expectEqual(
                @field(a.modes.saved, field.name),
                @field(b.modes.saved, field.name),
            ) catch |err| {
                std.debug.print("saved mode {s} differs\n", .{field.name});
                return err;
            };
        }
    }
    try testing.expectEqual(a.flags.mouse_event, b.flags.mouse_event);
    try testing.expectEqual(a.flags.mouse_format, b.flags.mouse_format);
    try testing.expectEqual(a.flags.mouse_shift_capture, b.flags.mouse_shift_capture);
    try testing.expectEqual(a.flags.modify_other_keys_2, b.flags.modify_other_keys_2);
    try testing.expectEqual(a.scrolling_region, b.scrolling_region);
    for (0..a.cols) |col| try testing.expectEqual(a.tabstops.get(col), b.tabstops.get(col));
    try testing.expectEqual(a.cursor.is_default, b.cursor.is_default);

    const ca = a.screens.active.cursor;
    const cb = b.screens.active.cursor;
    try testing.expectEqual(ca.x, cb.x);
    try testing.expectEqual(ca.y, cb.y);
    try testing.expectEqual(ca.pending_wrap, cb.pending_wrap);
    try testing.expectEqual(ca.cursor_style, cb.cursor_style);
    try testing.expect(ca.style.eql(cb.style));
    try expectSameCharsets(a.screens.active.charset, b.screens.active.charset);

    for ([_]@TypeOf(a.screens.active_key){ .primary, .alternate }) |key| {
        const sa = a.screens.get(key) orelse continue;
        const sb = b.screens.get(key).?;
        try expectSameKittyStack(sa.kitty_keyboard, sb.kitty_keyboard);
        if (sa.saved_cursor) |saved_a| {
            const saved_b = sb.saved_cursor.?;
            try testing.expectEqual(saved_a.x, saved_b.x);
            try testing.expectEqual(saved_a.y, saved_b.y);
            try testing.expectEqual(saved_a.origin, saved_b.origin);
            try testing.expectEqual(saved_a.pending_wrap, saved_b.pending_wrap);
            try testing.expect(saved_a.style.eql(saved_b.style));
            try expectSameCharsets(saved_a.charset, saved_b.charset);
        } else try testing.expect(sb.saved_cursor == null);
    }
}

/// ASCII and UTF-8 print the same; only a replay can tell them apart.
fn expectSameCharsets(a: Screen.CharsetState, b: Screen.CharsetState) !void {
    try testing.expectEqual(a.gl, b.gl);
    try testing.expectEqual(a.gr, b.gr);
    try testing.expectEqual(a.single_shift, b.single_shift);
    for (std.enums.values(charsets.Slots)) |slot| {
        const ca = a.charsets.get(slot);
        const cb = b.charsets.get(slot);
        try testing.expectEqual(
            if (ca == .utf8) .ascii else ca,
            if (cb == .utf8) .ascii else cb,
        );
    }
}

/// Equal as stacks: the same flags from the top down.
fn expectSameKittyStack(a: kitty.KeyFlagStack, b: kitty.KeyFlagStack) !void {
    var sa = a;
    var sb = b;
    for (0..sa.flags.len) |_| {
        try testing.expectEqual(sa.current().int(), sb.current().int());
        sa.pop(1);
        sb.pop(1);
    }
}

fn noCheck(_: *Terminal, _: *Terminal) anyerror!void {}

test "restoration: plain shell" {
    try expectRoundTrip("one\r\ntwo\r\n$ ", noCheck);
}

test "restoration: scrollback and wrapped lines" {
    try expectRoundTrip(
        "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n" ++
            "a line that is longer than the screen is wide\r\n$ ",
        struct {
            fn check(a: *Terminal, b: *Terminal) !void {
                const alloc = testing.allocator;
                const ta = try a.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
                defer alloc.free(ta);
                const tb = try b.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
                defer alloc.free(tb);
                try testing.expectEqualStrings(ta, tb);
            }
        }.check,
    );
}

test "restoration: modes, margins and pen" {
    try expectRoundTrip(
        "\x1b[?2004h\x1b[?1h\x1b[?7l\x1b[?25l\x1b[4h\x1b=\x1b[?1004h" ++
            "\x1b[?69h\x1b[2;5r\x1b[3;18s\x1b[?6h" ++
            "\x1b[1;38;5;196;48;2;1;2;3m\x1b(0\x1b[>4;2m\x1b[>1s\x1b[5 q" ++
            "\x1b[2;4Hx",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expect(b.modes.get(.bracketed_paste));
                try testing.expect(b.modes.get(.origin));
                try testing.expect(!b.modes.get(.wraparound));
                try testing.expectEqual(1, b.scrolling_region.top);
                try testing.expectEqual(2, b.scrolling_region.left);
                try testing.expectEqual(.bar, b.screens.active.cursor.cursor_style);
                try testing.expect(b.modes.get(.cursor_blinking));
                try testing.expect(b.screens.active.cursor.style.flags.bold);
                try testing.expect(b.flags.modify_other_keys_2);
                try testing.expectEqual(.true, b.flags.mouse_shift_capture);
                try testing.expectEqual(.dec_special, b.screens.active.charset.charsets.get(.G0));
                try testing.expect(b.modes.get(.keypad_keys));
                try testing.expect(b.modes.get(.insert));
            }
        }.check,
    );
}

test "restoration: alternate screen keeps both screens and keyboard stacks" {
    try expectRoundTrip(
        "shell\r\n$ vi\x1b[>1u\x1b[>3u" ++
            "\x1b[?1049h\x1b[>5u\x1b[>7u\x1b[=15;1u\x1b[2;3Heditor\x1b[?1002h\x1b[?1006h",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expectEqual(.alternate, b.screens.active_key);
                try testing.expectEqual(15, b.screens.active.kitty_keyboard.current().int());
                try testing.expectEqual(3, b.screens.get(.primary).?.kitty_keyboard.current().int());
                // Leaving restores the shell's cursor from the DECSC slot.
                var s = b.vtStream();
                defer s.deinit();
                s.nextSlice("\x1b[?1049l");
                try testing.expectEqual(.primary, b.screens.active_key);
                try testing.expectEqual(4, b.screens.active.cursor.x);
                try testing.expectEqual(1, b.screens.active.cursor.y);
            }
        }.check,
    );
}

test "restoration: DECSC slots on both screens" {
    try expectRoundTrip(
        "\x1b[2;5r\x1b[?6h\x1b[1;4m\x1b(0\x1b[2;3H\x1b7" ++
            "\x1b[0m\x1b(B\x1b[?6l\x1b[r\x1b[?47h\x1b[3;9H\x1b[7m\x1b7\x1b[0m\x1b[Hq",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                const primary = b.screens.get(.primary).?.saved_cursor.?;
                try testing.expect(primary.origin);
                try testing.expectEqual(2, primary.x);
                try testing.expectEqual(2, primary.y);
                try testing.expectEqual(.dec_special, primary.charset.charsets.get(.G0));
                const alternate = b.screens.get(.alternate).?.saved_cursor.?;
                try testing.expectEqual(8, alternate.x);
                try testing.expect(alternate.style.flags.inverse);
                // The slots' pens stayed in the slots.
                try testing.expect(!b.screens.active.cursor.style.flags.inverse);
                try testing.expect(!b.modes.get(.origin));
            }
        }.check,
    );
}

test "restoration: an alternate screen left under mode 47 is still there" {
    try expectRoundTrip(
        "shell\r\n$ \x1b[?47h\x1b[2;3Hkept\x1b[>5u\x1b[3;9H\x1b[7m\x1b7\x1b[0m\x1b[?47l\x1b[2;3H",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expectEqual(.primary, b.screens.active_key);
                try testing.expectEqual(2, b.screens.active.cursor.x);
                try testing.expectEqual(1, b.screens.active.cursor.y);
                try testing.expectEqual(0, b.screens.active.kitty_keyboard.current().int());

                var s = b.vtStream();
                defer s.deinit();
                s.nextSlice("\x1b[?47h");
                const text = try b.plainString(testing.allocator);
                defer testing.allocator.free(text);
                try testing.expectEqualStrings("\n  kept", text);
                try testing.expectEqual(5, b.screens.active.kitty_keyboard.current().int());
                try testing.expect(b.screens.active.saved_cursor.?.style.flags.inverse);
            }
        }.check,
    );
}

test "restoration: a DECSC slot keeps its pending wrap" {
    for ([_][]const u8{
        // Saved at the edge, on the primary and on the alternate screen.
        "\x1b[3;1H12345678901234567890\x1b7\x1b[H",
        "\x1b[?47h\x1b[3;1H12345678901234567890\x1b7\x1b[H",
        // The cell under the slot was erased or holds a wide character.
        "\x1b[3;1H12345678901234567890\x1b7\x1b[2J\x1b[H",
        "\x1b[3;1H123456789012345678\xe4\xb8\xad\x1b7\x1b[H",
    }) |input| {
        try expectRoundTrip(input, struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expect(b.screens.active.saved_cursor.?.pending_wrap);
                // Restoring the slot and printing wraps to the next line.
                var s = b.vtStream();
                defer s.deinit();
                s.nextSlice("\x1b8x");
                try testing.expectEqual(1, b.screens.active.cursor.x);
                try testing.expectEqual(3, b.screens.active.cursor.y);
            }
        }.check);
    }
}

test "restoration: the cursor follows a wrapped line moved into scrollback" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    // The long line starts in scrollback and ends in the active area, so the
    // dump replays its two active rows with the scrollback. The DECSC slot
    // sits on the row of `b`.
    s.nextSlice("1\r\na line that is much longer than the screen is wide\r\na\r\nb\r\nc\r\n$ ");
    s.nextSlice("\x1b[4;2H\x1b7\x1b[6;3H");
    try testing.expectEqual(5, t.screens.active.cursor.y);

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();
    _ = (try writeSnapshot(&t, &aw)).?;

    var t2 = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(aw.written());

    try testing.expectEqual(3, t2.screens.active.cursor.y);
    try testing.expectEqual(2, t2.screens.active.cursor.x);
    try testing.expectEqual(1, t2.screens.active.saved_cursor.?.y);

    // What the program prints next lands right after the prompt.
    s2.nextSlice("ls\x1b8!");
    const text = try t2.plainString(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("a\nb!\nc\n$ ls", text);
}

test "restoration: XTSAVE values survive beside the current ones" {
    try expectRoundTrip(
        "\x1b[?1000h\x1b[?1000s\x1b[?1000l\x1b[?2004s\x1b[?2004h\x1b[?25l\x1b[?25s\x1b[?25h",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expect(!b.modes.get(.mouse_event_normal));
                try testing.expectEqual(.none, b.flags.mouse_event);
                var s = b.vtStream();
                defer s.deinit();
                s.nextSlice("\x1b[?1000r\x1b[?2004r\x1b[?25r");
                try testing.expect(b.modes.get(.mouse_event_normal));
                try testing.expect(!b.modes.get(.bracketed_paste));
                try testing.expect(!b.modes.get(.cursor_visible));
            }
        }.check,
    );
}

test "restoration: the mouse mode set last stays in effect" {
    try expectRoundTrip(
        "\x1b[?1003h\x1b[?1000h\x1b[?1006h\x1b[?1015h",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expectEqual(.normal, b.flags.mouse_event);
                try testing.expectEqual(.urxvt, b.flags.mouse_format);
                try testing.expect(b.modes.get(.mouse_event_any));
                try testing.expect(b.modes.get(.mouse_format_sgr));
            }
        }.check,
    );
}

test "restoration: cursor blinking set through mode 12" {
    for ([_][]const u8{ "\x1b[?12h", "\x1b[?12l", "\x1b[4 q\x1b[?12h", "\x1b[3 q\x1b[?12l" }) |input| {
        try expectRoundTrip(input, noCheck);
    }
}

test "restoration: tab stops the program moved" {
    try expectRoundTrip(
        "\x1b[3g\x1b[5G\x1bH\x1b[12G\x1bH\x1b[?69h\x1b[4;18s\x1b[?6h\x1b[2;3Hx",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expect(b.tabstops.get(4));
                try testing.expect(b.tabstops.get(11));
                try testing.expect(!b.tabstops.get(8));
            }
        }.check,
    );
}

test "restoration: an open hyperlink and protection are not carried over" {
    try expectRoundTrip(
        "\x1b]8;;https://example.com\x1b\\link\x1b[1\"qguarded",
        struct {
            fn check(a: *Terminal, b: *Terminal) !void {
                try testing.expect(a.screens.active.cursor.hyperlink != null);
                try testing.expect(a.screens.active.cursor.protected);
                try testing.expect(b.screens.active.cursor.hyperlink == null);
                try testing.expect(!b.screens.active.cursor.protected);
            }
        }.check,
    );
}

test "restoration: mouse mode queries answer as before" {
    // The event is off again, but mode 1000 was never reset. The same for
    // the format with mode 1006.
    try expectRoundTrip(
        "\x1b[?1000h\x1b[?1002l\x1b[?1006h\x1b[?1015l",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expectEqual(.none, b.flags.mouse_event);
                try testing.expectEqual(.x10, b.flags.mouse_format);
                try testing.expectEqual(.set, b.modes.getReport(.{ .value = 1000 }).state);
                try testing.expectEqual(.reset, b.modes.getReport(.{ .value = 1002 }).state);
                try testing.expectEqual(.set, b.modes.getReport(.{ .value = 1006 }).state);
                try testing.expectEqual(.reset, b.modes.getReport(.{ .value = 1015 }).state);
            }
        }.check,
    );
    // Every bit of a group set, with a saved value in between.
    try expectRoundTrip(
        "\x1b[?9h\x1b[?1000h\x1b[?1003h\x1b[?1003s\x1b[?1002h\x1b[?1003l",
        struct {
            fn check(_: *Terminal, b: *Terminal) !void {
                try testing.expectEqual(.none, b.flags.mouse_event);
                try testing.expectEqual(.set, b.modes.getReport(.{ .value = 1002 }).state);
                try testing.expectEqual(.reset, b.modes.getReport(.{ .value = 1003 }).state);
            }
        }.check,
    );
}

test "restoration: pending wrap at a right margin" {
    for ([_][]const u8{
        // The live cursor, then DECSC slots on both screens.
        "\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890",
        "\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890\x1b7\x1b[H",
        "\x1b[?47h\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890\x1b7\x1b[H",
        // The margin the slot was saved at is gone or has moved since.
        "\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890\x1b7\x1b[?69l\x1b[H",
        "\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890\x1b7\x1b[3;15s\x1b[?6h\x1b[2;2H",
        // An empty and a wide cell under the slot.
        "\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890\x1b7\x1b[2J\x1b[H",
        "\x1b[?69h\x1b[1;10s\x1b[3;1H12345678\xe4\xb8\xad\x1b7\x1b[H",
    }) |input| {
        try expectRoundTrip(input, struct {
            fn check(a: *Terminal, b: *Terminal) !void {
                // What the program prints next wraps in both terminals.
                for ([_]*Terminal{ a, b }) |t| {
                    var s = t.vtStream();
                    defer s.deinit();
                    if (t.screens.active.saved_cursor != null) s.nextSlice("\x1b8");
                    try testing.expect(t.screens.active.cursor.pending_wrap);
                    s.nextSlice("x");
                }
                try testing.expectEqual(a.screens.active.cursor.x, b.screens.active.cursor.x);
                try testing.expectEqual(a.screens.active.cursor.y, b.screens.active.cursor.y);
                try testing.expectEqual(3, b.screens.active.cursor.y);
            }
        }.check);
    }
}

test "restoration: pending wrap DECRC left where a margin used to be" {
    const save_at_margin = "\x1b[?69h\x1b[1;10s\x1b[3;1H1234567890\x1b7";
    for ([_][]const u8{
        // The margin is gone, or has moved, and DECRC made the slot the cursor.
        save_at_margin ++ "\x1b[?69l\x1b[H\x1b8",
        save_at_margin ++ "\x1b[3;15s\x1b8\x1b[1m",
        save_at_margin ++ "\x1b[?69l\x1b[2;5r\x1b[?6h\x1b[?6l\x1b8",
        // The same on the alternate screen, and with the slot's charset.
        "\x1b[?47h\x1b(0" ++ save_at_margin ++ "\x1b(B\x1b[?69l\x1b[H\x1b8\x1b(B",
        // The cursor went on to the other screen, whose slot is empty or
        // holds something else, with the margin gone or moved.
        save_at_margin ++ "\x1b[?69l\x1b[H\x1b8\x1b[?47h",
        save_at_margin ++ "\x1b[3;15s\x1b8\x1b[?47h",
        "\x1b[?47h\x1b[2;2H\x1b7\x1b[?47l" ++ save_at_margin ++ "\x1b[3;15s\x1b8\x1b[?47h",
    }) |input| {
        try expectRoundTrip(input, struct {
            fn check(a: *Terminal, b: *Terminal) !void {
                try testing.expect(a.screens.active.cursor.pending_wrap);
                try testing.expect(!b.modes.get(.enable_left_and_right_margin) or
                    b.scrolling_region.right != 9);
                // What the program prints next lands in the same cell.
                for ([_]*Terminal{ a, b }) |t| {
                    var s = t.vtStream();
                    defer s.deinit();
                    s.nextSlice("x");
                }
                try testing.expectEqual(a.screens.active.cursor.x, b.screens.active.cursor.x);
                try testing.expectEqual(a.screens.active.cursor.y, b.screens.active.cursor.y);
            }
        }.check);
    }
}

test "restoration: CSI ? 7502 h sets a pending wrap without being a mode" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();

    s.nextSlice("\x1b[2;5H\x1b[?7502h");
    try testing.expect(t.screens.active.cursor.pending_wrap);
    // Nothing is stored for it: the mode table, which the binary snapshot
    // format mirrors bit for bit, doesn't know the number.
    try testing.expectEqual(.not_recognized, t.modes.getReport(.{ .value = 7502 }).state);
    try testing.expect(modespkg.modeFromInt(7502, false) == null);
    // The next character wraps, as after DECRC of such a cursor.
    s.nextSlice("x");
    try testing.expectEqual(1, t.screens.active.cursor.x);
    try testing.expectEqual(2, t.screens.active.cursor.y);

    s.nextSlice("\x1b[2;5H\x1b[?7502h\x1b[?7502l");
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    // A replay only ever sets it, once per cursor that needs it.
    s.nextSlice("\x1b[2;5H\x1b[?7502h\x1b7");
    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();
    _ = (try writeSnapshot(&t, &aw)).?;
    try testing.expectEqual(2, std.mem.count(u8, aw.written(), pending_wrap));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?7502l") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?7502s") == null);
}

test "restoration: a single shift waiting for its character" {
    for ([_][]const u8{
        // Pending for the next character.
        "\x1b*0\x1bN",
        "ab\x1b+0\x1bO",
        // Saved with the cursor on either screen, and used up since.
        "ab\x1b*0\x1bN\x1b7q",
        "top\r\n\x1b[?47h\x1b[2;2Halt\x1b*0\x1bN\x1b7q\x1b[?47l",
        // Saved, with scrollback and both screens holding text.
        "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n\x1b*0\x1bN\x1b7q\x1b[?47h\x1b[2;2Halt\x1b[?47l",
    }) |input| {
        try expectRoundTrip(input, struct {
            fn check(a: *Terminal, b: *Terminal) !void {
                // A line-drawing q comes out of DEC Special Graphics in both.
                const alloc = testing.allocator;
                var text: [2][]const u8 = undefined;
                for ([_]*Terminal{ a, b }, 0..) |t, i| {
                    var s = t.vtStream();
                    defer s.deinit();
                    // The slot with the shift may be the other screen's.
                    if (t.screens.active.saved_cursor == null and t.screens.get(.alternate) != null) {
                        s.nextSlice("\x1b[?47h");
                    }
                    if (t.screens.active.saved_cursor != null) s.nextSlice("\x1b8");
                    try testing.expect(t.screens.active.charset.single_shift != null);
                    s.nextSlice("qq");
                    text[i] = try t.plainString(alloc);
                }
                defer for (text) |str| alloc.free(str);
                try testing.expectEqualStrings(text[0], text[1]);
                try testing.expect(std.mem.indexOf(u8, text[1], "\u{2500}q") != null);
            }
        }.check);
    }
}

test "restoration: a full-width last row keeps its last cell" {
    // A status line on both screens, the cursor parked elsewhere.
    try expectRoundTrip(
        "\x1b[6;1H12345678901234567890\x1b[H\x1b[?47h\x1b[6;1Habcdefghijklmnopqrst\x1b[2;2H",
        noCheck,
    );
}

test "restoration: pending wrap at the right edge" {
    try expectRoundTrip("\x1b[3;1H12345678901234567890", noCheck);
}

test "restoration: the kitty stack wraps like the original" {
    try expectRoundTrip(
        "\x1b[>1u\x1b[>2u\x1b[>3u\x1b[>4u\x1b[>5u\x1b[>6u\x1b[>7u\x1b[>8u\x1b[>9u\x1b[>10u\x1b[<2u",
        noCheck,
    );
}

test "restoration: side-effect modes are never replayed as modes" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[?40h\x1b[?2026h\x1b[?1048h\x1b[?1049h");

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();
    _ = (try writeSnapshot(&t, &aw)).?;
    const replay = aw.written();
    for ([_][]const u8{ "\x1b[?3h", "\x1b[?40h", "\x1b[?2026h", "\x1b[?1048h", "\x1b[?1049h", "\x1b[?1047h" }) |seq| {
        try testing.expect(std.mem.indexOf(u8, replay, seq) == null);
    }
    // Nothing in a replay asks the terminal a question.
    for ([_][]const u8{ "\x1b[6n", "$p", "\x1b[c", "\x1b[?u" }) |seq| {
        try testing.expect(std.mem.indexOf(u8, replay, seq) == null);
    }
}

test "restoration: the primary range is the primary dump" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[31mred\x1b[0m\r\n$ \x1b[?1049halt");

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const range = (try writeSnapshot(&t, &aw)).?;

    var dump: Writer.Allocating = .init(alloc);
    defer dump.deinit();
    try testing.expect(try writePrimaryScreen(&t, &dump.writer));
    try testing.expectEqualStrings(
        dump.written(),
        aw.written()[range.offset..][0..range.len],
    );
}
