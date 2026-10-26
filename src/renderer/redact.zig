//! ROOTSHELL-REDACT: display-only masking of sensitive strings ("auto
//! redact"). The app supplies a set of needle strings via the frozen ABI
//! `ghostty_surface_set_redact` (see apprt/embedded.zig); any occurrence
//! of a needle in the rendered viewport is drawn as a mask codepoint at
//! exactly the original cell widths.
//!
//! This operates ONLY on the renderer's RenderState row copies, never on
//! page memory: selection, copy, scrollback, search, and dumps all see
//! the real text. Un-redaction (disable or needle change) is achieved by
//! forcing a full re-copy of the viewport from page memory (see the
//! `set_redact` handler in renderer/Thread.zig, which sets
//! `terminal.flags.dirty.clear` under the state mutex — same mechanism
//! as Surface.modsChanged).
//!
//! Threading: the Set is owned by the renderer thread (adopted from a
//! mailbox message, same arena-handoff pattern as SearchMatches). Both
//! entry points below are called from the renderer thread only:
//! `extendWrapDirty` inside the updateFrame critical section (terminal
//! lock held), `apply` after endUpdate with no lock required.
//!
//! Known, accepted limitations:
//! - Search highlights are computed from real terminal data, so
//!   searching for a redacted string still highlights its position
//!   (positions leak, contents don't).
//! - IME preedit cells render un-redacted (separate preedit path).
//! - Needles spanning a wrap chain truncated at the viewport edge
//!   won't match across the cut (same limitation as RenderState.string).
//! - Regex links run over masked text, so redacted emails/URLs
//!   intentionally stop being clickable.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const uucode = @import("uucode");
const terminal = @import("../terminal/main.zig");
const unicode = @import("../unicode/main.zig");
const page = terminal.page;

const log = std.log.scoped(.renderer_redact);

/// Default mask codepoint: U+2022 BULLET. Chosen over U+2588 FULL BLOCK
/// because covering glyphs get inverse-bg treatment in the cell renderer
/// (see cell.isCovering) which would flip colors under the mask.
pub const default_mask: u21 = 0x2022;

/// ABI flag bits for ghostty_surface_set_redact.
pub const flag_case_insensitive: u32 = 1;

/// A set of redaction needles, pre-decoded to codepoints (and pre-folded
/// when case-insensitive) so the per-frame scan never touches UTF-8.
pub const Set = struct {
    /// Owns all needle memory. The Set is freed by deiniting this.
    arena: ArenaAllocator,

    /// The needles as codepoint sequences. Never empty (init returns
    /// null instead) and no needle is empty.
    needles: []const []const u21,

    /// The mask codepoint written over matched cells. Always width 1.
    mask: u21,

    /// Whether matching is case-insensitive (full Unicode case fold).
    fold: bool,

    /// Emergency fallback mode: ignore the needles and mask EVERY text
    /// cell of every dirty line. Used when a replacement set could not
    /// be built (allocation failure): over-masking the whole screen is
    /// the only allocation-free way to guarantee a just-added secret is
    /// not rendered in the clear. Cleared by the next successful
    /// set_redact.
    mask_all: bool = false,

    /// Allocation-free constructor for the emergency fallback set.
    pub fn maskAllFallback(gpa: Allocator) Set {
        return .{
            .arena = .init(gpa),
            .needles = &.{},
            .mask = default_mask,
            .fold = false,
            .mask_all = true,
        };
    }

    /// Build a set from UTF-8 needle strings. Returns null if no valid
    /// needle remains after validation (the caller should treat null as
    /// "redaction disabled"). Needles are skipped when empty, invalid
    /// UTF-8, or containing the mask codepoint (the mask guard keeps
    /// masking idempotent: masked output can never re-match) or the
    /// Kitty graphics placeholder.
    pub fn init(
        gpa: Allocator,
        strs: []const [*:0]const u8,
        mask_codepoint: u32,
        flags: u32,
    ) Allocator.Error!?Set {
        const fold = flags & flag_case_insensitive != 0;
        const mask: u21 = mask: {
            if (mask_codepoint == 0 or
                mask_codepoint > std.math.maxInt(u21) or
                !std.unicode.utf8ValidCodepoint(@intCast(mask_codepoint)) or
                unicode.codepointWidth(@intCast(mask_codepoint)) != 1)
                break :mask default_mask;
            break :mask @intCast(mask_codepoint);
        };

        var arena: ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var needles: std.ArrayList([]const u21) = .empty;
        outer: for (strs) |str| {
            const bytes = std.mem.span(str);
            if (bytes.len == 0) continue;
            const view = std.unicode.Utf8View.init(bytes) catch {
                log.warn("ignoring invalid UTF-8 redact needle", .{});
                continue;
            };

            var needle: std.ArrayList(u21) = .empty;
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp == mask or cp == placeholder_cp) continue :outer;
                try appendFolded(&needle, alloc, cp, fold);
            }
            if (needle.items.len == 0) continue;
            try needles.append(alloc, needle.items);
        }

        if (needles.items.len == 0) {
            arena.deinit();
            return null;
        }

        return .{
            .arena = arena,
            .needles = needles.items,
            .mask = mask,
            .fold = fold,
        };
    }

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
    }

    /// Mask all needle occurrences within dirty logical lines of the
    /// render state. Must be called after endUpdate (styles denormalized,
    /// row dirty flags still set for the downstream GPU rebuild) and
    /// before anything display-related reads the row text (e.g. regex
    /// link matching). Only reads/writes RenderState memory; no terminal
    /// lock required.
    ///
    /// FAIL CLOSED: if the per-line scan cannot allocate, the whole
    /// logical line is masked wholesale (allocation-free) instead of
    /// being rendered in the clear. Over-redacting one frame is
    /// acceptable; leaking a configured secret is not.
    pub fn apply(
        self: *const Set,
        state: *terminal.RenderState,
        scratch: Allocator,
    ) void {
        const row_data = state.row_data.slice();
        const raws = row_data.items(.raw);
        const dirties = row_data.items(.dirty);
        const cells = row_data.items(.cells);

        const range = state.rowDataRange();
        const nrows = range.end;
        var y: usize = range.start;
        while (y < nrows) {
            // Group the soft-wrapped logical line starting at y. `wrap`
            // means "continues onto the next row".
            var end = y;
            while (end + 1 < nrows and raws[end].wrap) end += 1;
            const line_end = end + 1;
            defer y = line_end;

            // Only scan lines with at least one dirty row. Clean rows
            // were not re-copied from page memory this frame, so they
            // are already in their final (possibly masked) state.
            // extendWrapDirty guarantees that a partially-dirty line
            // has been fully re-copied, so scanning the whole line here
            // always sees fresh page text.
            const dirty = dirty: {
                for (dirties[y..line_end]) |d| if (d) break :dirty true;
                break :dirty false;
            };
            if (!dirty) continue;

            if (self.mask_all) {
                self.maskLineWholesale(cells[y..line_end], dirties[y..line_end]);
                continue;
            }

            self.applyLine(cells[y..line_end], scratch) catch |err| {
                log.warn("error scanning line, masking wholesale err={}", .{err});
                self.maskLineWholesale(cells[y..line_end], dirties[y..line_end]);
            };
        }
    }

    /// Allocation-free fallback: mask every text cell of the given rows
    /// and mark them dirty. Used when the needle scan (or the wrap-chain
    /// refresh) cannot run, so redaction degrades to over-masking rather
    /// than exposing text.
    fn maskLineWholesale(
        self: *const Set,
        line: []std.MultiArrayList(terminal.RenderState.Cell),
        dirties: []bool,
    ) void {
        for (line, dirties) |*row_cells, *dirty| {
            const cell_raws = row_cells.slice().items(.raw);
            for (cell_raws, 0..) |cell, x| {
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_tail, .spacer_head => continue,
                }
                const cp = cell.codepoint();
                if (cp == 0 or cp == placeholder_cp) continue;
                self.maskCell(row_cells, @intCast(x));
            }
            dirty.* = true;
        }
    }

    /// One haystack position: the cell it originated from. Folding and
    /// grapheme expansion can map multiple consecutive positions to the
    /// same cell; masking is per-cell and idempotent so that's fine.
    const Pos = struct {
        row: u32,
        x: u32,
    };

    fn applyLine(
        self: *const Set,
        line: []std.MultiArrayList(terminal.RenderState.Cell),
        scratch: Allocator,
    ) Allocator.Error!void {
        // Build the codepoint haystack for the logical line along with
        // a parallel per-position cell map. Spacers are skipped (a wide
        // char is a single haystack position at the wide cell), empty
        // and bg-only cells contribute codepoint 0 which no needle can
        // contain, acting as natural separators.
        var hay: std.ArrayList(u21) = .empty;
        defer hay.deinit(scratch);
        var map: std.ArrayList(Pos) = .empty;
        defer map.deinit(scratch);

        // A cheap 256-bit presence filter over the low byte of every
        // haystack codepoint lets us skip needle searches that cannot
        // match this line.
        var bloom: [4]u64 = @splat(0);

        for (line, 0..) |*row_cells, row| {
            const slice = row_cells.slice();
            const cell_raws = slice.items(.raw);
            const cell_graphemes = slice.items(.grapheme);
            for (cell_raws, 0..) |cell, x| {
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_tail, .spacer_head => continue,
                }

                const pos: Pos = .{ .row = @intCast(row), .x = @intCast(x) };
                const cp = cell.codepoint();
                try appendHay(&hay, &map, scratch, cp, pos, self.fold, &bloom);
                if (cell.hasGrapheme()) {
                    for (cell_graphemes[x]) |gcp| try appendHay(
                        &hay,
                        &map,
                        scratch,
                        gcp,
                        pos,
                        self.fold,
                        &bloom,
                    );
                }
            }
        }

        for (self.needles) |needle| {
            if (!bloomHas(&bloom, needle[0])) continue;

            var idx: usize = 0;
            while (std.mem.indexOfPos(u21, hay.items, idx, needle)) |start| {
                idx = start + 1;
                for (map.items[start..][0..needle.len]) |pos| {
                    self.maskCell(&line[pos.row], pos.x);
                }
            }
        }
    }

    /// Mask a single cell (and its spacer tail when wide), preserving
    /// style, hyperlink state, protection, semantic content — and
    /// therefore width: a wide cell plus its tail become two narrow
    /// mask cells occupying the same two columns.
    fn maskCell(
        self: *const Set,
        row_cells: *std.MultiArrayList(terminal.RenderState.Cell),
        x: u32,
    ) void {
        const cell_raws = row_cells.slice().items(.raw);
        const cell = &cell_raws[x];
        switch (cell.wide) {
            .narrow => {},
            .wide => {
                // A wide cell is always followed by its spacer tail on
                // the same row (a wide char that would straddle the last
                // column becomes a spacer_head instead).
                const tail = &cell_raws[x + 1];
                assert(tail.wide == .spacer_tail);
                tail.content_tag = .codepoint;
                tail.content = .{ .codepoint = .{ .data = self.mask } };
                tail.wide = .narrow;
            },
            // Never in the haystack.
            .spacer_tail, .spacer_head => unreachable,
        }

        // Setting the tag to .codepoint also neutralizes any grapheme
        // slice (only read when the tag is .codepoint_grapheme).
        cell.content_tag = .codepoint;
        cell.content = .{ .codepoint = .{ .data = self.mask } };
        cell.wide = .narrow;
    }
};

/// The Kitty graphics unicode placeholder (see
/// terminal/kitty/graphics_unicode.zig). Cells carrying it position
/// virtual images; needles containing it are rejected so it can never
/// be masked. Hardcoded because terminal.kitty.graphics is an empty
/// struct when the kitty_graphics build option is disabled.
const placeholder_cp: u21 = 0x10EEEE;

/// Append a codepoint (folded when fold is set) to the haystack, mapping
/// every emitted position back to the originating cell.
fn appendHay(
    hay: *std.ArrayList(u21),
    map: *std.ArrayList(Set.Pos),
    alloc: Allocator,
    cp: u21,
    pos: Set.Pos,
    fold: bool,
    bloom: *[4]u64,
) Allocator.Error!void {
    var buf: [1]u21 = .{cp};
    const cps: []const u21 = if (fold)
        uucode.get(.case_folding_full, cp).with(&buf, cp)
    else
        &buf;
    for (cps) |c| {
        bloomAdd(bloom, c);
        try hay.append(alloc, c);
        try map.append(alloc, pos);
    }
}

/// Append a codepoint to a needle being built, folding when requested.
fn appendFolded(
    list: *std.ArrayList(u21),
    alloc: Allocator,
    cp: u21,
    fold: bool,
) Allocator.Error!void {
    if (!fold) return try list.append(alloc, cp);
    var buf: [1]u21 = undefined;
    const cps = uucode.get(.case_folding_full, cp).with(&buf, cp);
    try list.appendSlice(alloc, cps);
}

fn bloomAdd(bloom: *[4]u64, cp: u21) void {
    const b: u8 = @truncate(cp);
    bloom[b >> 6] |= @as(u64, 1) << @truncate(b);
}

fn bloomHas(bloom: *const [4]u64, cp: u21) bool {
    const b: u8 = @truncate(cp);
    return bloom[b >> 6] & (@as(u64, 1) << @truncate(b)) != 0;
}

/// Ensure every soft-wrap-linked logical line that has at least one
/// dirty row is FULLY re-copied from page memory. Without this, a line
/// whose other rows still hold masked copies from a prior frame would
/// be scanned as a mix of masked and fresh text and a needle spanning
/// the row boundary would silently fail to match.
///
/// Must be called inside the updateFrame critical section (terminal
/// lock held, row pins valid), after beginUpdate*/before endUpdate: the
/// row rebuilds append pending style runs that the following endUpdate
/// denormalizes.
///
/// FAIL CLOSED: a chain that cannot be fully re-copied (allocation
/// failure) is masked wholesale instead, so a boundary-spanning needle
/// fragment can never render in the clear because its sibling row was
/// stale.
pub fn extendWrapDirty(
    self: *const Set,
    state: *terminal.RenderState,
    alloc: Allocator,
) void {
    // The mask-all fallback doesn't match needles, so span consistency
    // across wrap boundaries is irrelevant: every dirty line is masked
    // wholesale by apply regardless.
    if (self.mask_all) return;

    const row_data = state.row_data.slice();
    const raws = row_data.items(.raw);
    const dirties = row_data.items(.dirty);
    const cells = row_data.items(.cells);

    const range = state.rowDataRange();
    const nrows = range.end;
    var y: usize = range.start;
    while (y < nrows) {
        var end = y;
        while (end + 1 < nrows and raws[end].wrap) end += 1;
        const line_end = end + 1;
        defer y = line_end;

        // Single-row lines need no extension.
        if (line_end - y == 1) continue;

        const dirty = dirty: {
            for (dirties[y..line_end]) |d| if (d) break :dirty true;
            break :dirty false;
        };
        if (!dirty) continue;

        for (y..line_end) |ry| {
            if (dirties[ry]) continue;
            state.rebuildViewportRow(alloc, ry) catch |err| {
                log.warn("error refreshing wrap chain, masking wholesale err={}", .{err});
                self.maskLineWholesale(cells[y..line_end], dirties[y..line_end]);
                break;
            };
        }
    }
}

test "redact simple match masks exact cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xABCy");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"ABC"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'x'), cells[0].codepoint());
    try testing.expectEqual(default_mask, cells[1].codepoint());
    try testing.expectEqual(default_mask, cells[2].codepoint());
    try testing.expectEqual(default_mask, cells[3].codepoint());
    try testing.expectEqual(@as(u21, 'y'), cells[4].codepoint());
}

test "redact case-insensitive fold" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xAbCdY");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Case-sensitive: no match.
    {
        var set = (try Set.init(alloc, &.{"abcd"}, 0, 0)).?;
        defer set.deinit();
        set.apply(&state, alloc);
        const cells = state.row_data.items(.cells)[0].slice().items(.raw);
        try testing.expectEqual(@as(u21, 'A'), cells[1].codepoint());
    }

    // Case-insensitive: masked.
    {
        var set = (try Set.init(alloc, &.{"abcd"}, 0, flag_case_insensitive)).?;
        defer set.deinit();
        set.apply(&state, alloc);
        const cells = state.row_data.items(.cells)[0].slice().items(.raw);
        try testing.expectEqual(@as(u21, 'x'), cells[0].codepoint());
        for (1..5) |x| try testing.expectEqual(default_mask, cells[x].codepoint());
        try testing.expectEqual(@as(u21, 'Y'), cells[5].codepoint());
    }
}

test "redact wide chars fill both columns" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("x日本y");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"日本"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'x'), cells[0].codepoint());
    for (1..5) |x| {
        try testing.expectEqual(default_mask, cells[x].codepoint());
        try testing.expectEqual(page.Cell.Wide.narrow, cells[x].wide);
    }
    try testing.expectEqual(@as(u21, 'y'), cells[5].codepoint());
}

test "redact grapheme cluster collapses to mask" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ae\u{0301}b");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"e\u{0301}"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'a'), cells[0].codepoint());
    try testing.expectEqual(default_mask, cells[1].codepoint());
    try testing.expectEqual(page.Cell.ContentTag.codepoint, cells[1].content_tag);
    try testing.expectEqual(@as(u21, 'b'), cells[2].codepoint());
}

test "redact needle across soft-wrap boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    // Row 0: "abKIT" (wraps), row 1: "KNOXc".
    s.nextSlice("abKITKNOXc");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"KITKNOX"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    const row0 = state.row_data.items(.cells)[0].slice().items(.raw);
    const row1 = state.row_data.items(.cells)[1].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'a'), row0[0].codepoint());
    try testing.expectEqual(@as(u21, 'b'), row0[1].codepoint());
    for (2..5) |x| try testing.expectEqual(default_mask, row0[x].codepoint());
    for (0..4) |x| try testing.expectEqual(default_mask, row1[x].codepoint());
    try testing.expectEqual(@as(u21, 'c'), row1[4].codepoint());
}

test "redact wrap chain partial dirty rescans whole line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("abKITKNOXc");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"KITKNOX"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    // Simulate the renderer consuming the dirty flags.
    for (state.row_data.items(.dirty)) |*d| d.* = false;

    // Touch only row 1: overwrite the trailing 'c' with 'd'. Row 0's
    // copy still holds masked cells.
    s.nextSlice("\x1b[2;5Hd");

    // The renderer sequence: begin (re-copies only dirty page rows),
    // wrap-dirty extension, end, apply.
    try state.beginUpdate(alloc, &t);
    extendWrapDirty(&set, &state, alloc);
    state.endUpdate();
    set.apply(&state, alloc);

    const row0 = state.row_data.items(.cells)[0].slice().items(.raw);
    const row1 = state.row_data.items(.cells)[1].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'a'), row0[0].codepoint());
    for (2..5) |x| try testing.expectEqual(default_mask, row0[x].codepoint());
    for (0..4) |x| try testing.expectEqual(default_mask, row1[x].codepoint());
    try testing.expectEqual(@as(u21, 'd'), row1[4].codepoint());
}

test "redact is idempotent and rejects mask-containing needles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A needle containing the mask codepoint is rejected; with no other
    // needles the set is null (disabled).
    try testing.expectEqual(
        @as(?Set, null),
        try Set.init(alloc, &.{"a\u{2022}b"}, 0, 0),
    );

    // Empty input is also null.
    try testing.expectEqual(@as(?Set, null), try Set.init(alloc, &.{}, 0, 0));
    try testing.expectEqual(@as(?Set, null), try Set.init(alloc, &.{""}, 0, 0));

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xABCy");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"ABC"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);
    // Second apply over the already-masked row must be a no-op.
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'x'), cells[0].codepoint());
    try testing.expectEqual(default_mask, cells[1].codepoint());
    try testing.expectEqual(default_mask, cells[3].codepoint());
    try testing.expectEqual(@as(u21, 'y'), cells[4].codepoint());
}

test "redact disable restores original text via full re-copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xABCy");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"ABC"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    // The set_redact mailbox handler forces this flag when redaction is
    // disabled; the next update must re-copy every row from page memory.
    t.flags.dirty.clear = true;
    try state.update(alloc, &t);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'x'), cells[0].codepoint());
    try testing.expectEqual(@as(u21, 'A'), cells[1].codepoint());
    try testing.expectEqual(@as(u21, 'B'), cells[2].codepoint());
    try testing.expectEqual(@as(u21, 'C'), cells[3].codepoint());
    try testing.expectEqual(@as(u21, 'y'), cells[4].codepoint());
}

test "redact multiple needles with overlap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xABCDEy");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{ "ABC", "CDE" }, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(@as(u21, 'x'), cells[0].codepoint());
    for (1..6) |x| try testing.expectEqual(default_mask, cells[x].codepoint());
    try testing.expectEqual(@as(u21, 'y'), cells[6].codepoint());
}

test "redact fails closed when scan allocation fails" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xABCy");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = (try Set.init(alloc, &.{"ABC"}, 0, 0)).?;
    defer set.deinit();

    // Scratch allocator that always fails: the scan cannot run, so the
    // whole dirty line must be masked wholesale rather than exposed.
    var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    set.apply(&state, failing.allocator());

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    for (0..5) |x| try testing.expectEqual(default_mask, cells[x].codepoint());
    // Empty cells have nothing to leak and stay empty.
    try testing.expectEqual(@as(u21, 0), cells[5].codepoint());
}

test "redact mask-all fallback masks every text cell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("xABCy");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set: Set = .maskAllFallback(alloc);
    defer set.deinit();
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    for (0..5) |x| try testing.expectEqual(default_mask, cells[x].codepoint());
    try testing.expectEqual(@as(u21, 0), cells[5].codepoint());
}

test "redact preserves styles on masked cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    // Bold red "AB", plain "y".
    s.nextSlice("\x1b[1;31mAB\x1b[0my");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const before_id = state.row_data.items(.cells)[0].slice().items(.raw)[0].style_id;
    try testing.expect(before_id != 0);

    var set = (try Set.init(alloc, &.{"AB"}, 0, 0)).?;
    defer set.deinit();
    set.apply(&state, alloc);

    const cells = state.row_data.items(.cells)[0].slice().items(.raw);
    try testing.expectEqual(default_mask, cells[0].codepoint());
    try testing.expectEqual(before_id, cells[0].style_id);
    try testing.expectEqual(@as(u21, 'y'), cells[2].codepoint());
}
