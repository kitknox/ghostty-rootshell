const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const link_extend = terminal.link_extend;
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true if this link's highlight condition matches the given mouse state.
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => mouse_viewport != null,
            .hover_mods => |v| mouse_viewport != null and mouse_mods.equal(v),
        };
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Fills matches with the matches from regex link matches.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Determine if any links are active before building the string and
        // byte-to-cell map. Those buffers scale with viewport size and this
        // function runs during frame updates, so avoid allocating them when
        // the current mouse/modifier state can't highlight any regex links.
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods)) break;
        } else return;

        // Convert our render state to a string + byte map.
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });

        const str = builder.writer.buffered();

        // Go through each link and see if we have any matches.
        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods)) continue;

            var offset: usize = 0;
            while (offset < str.len) {
                var region = link.regex.search(
                    str[offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();

                // We have a match!
                const offset_start: usize = @intCast(region.starts()[0]);
                const offset_end: usize = @intCast(region.ends()[0]);
                const start = offset + offset_start;
                const end = offset + offset_end;

                // Increment our offset by the number of bytes in the match.
                // We defer this so that we can return the match before
                // modifying the offset.
                defer offset = end;

                // Try to extend the match across non-soft-wrapped row
                // boundaries (e.g., tmux pane wrapping). This appends
                // coordinates for continuation cells to ext_coords.
                var ext_coords: terminal.RenderState.StringMap = .empty;
                defer ext_coords.deinit(alloc);
                if (end > start) {
                    _ = extendMatchAcrossRows(
                        alloc,
                        link.regex,
                        render_state,
                        str[start..end],
                        map.items[end - 1],
                        &ext_coords,
                    ) catch {};
                }

                // Check hover against both original and extended cells.
                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (mouse_viewport) |vp| {
                        var found = false;
                        for (map.items[start..end]) |pt| {
                            if (pt.eql(vp)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            for (ext_coords.items) |pt| {
                                if (pt.eql(vp)) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) continue;
                    } else continue,
                }

                // Record the match (original + extended cells).
                for (map.items[start..end]) |pt| {
                    try result.put(alloc, pt, {});
                }
                for (ext_coords.items) |pt| {
                    try result.put(alloc, pt, {});
                }
            }
        }
    }
};

/// Attempt to extend a regex match across non-soft-wrapped row boundaries.
///
/// When terminal multiplexers like tmux render pane content using explicit
/// cursor positioning, the terminal never sets soft-wrap flags. URLs that
/// span multiple visual rows within a pane appear as separate fragments.
///
/// This function detects when a match ends at a "logical window boundary"
/// (the right edge of a column range bounded by box-drawing dividers or
/// terminal edges), then concatenates text from subsequent rows within the
/// same window and re-runs the regex to find a longer match.
///
/// Extended cell coordinates are appended to `ext_coords`. Returns true
/// if the match was successfully extended.
fn extendMatchAcrossRows(
    alloc: Allocator,
    regex: oni.Regex,
    render_state: *const terminal.RenderState,
    initial_text: []const u8,
    end_coord: point.Coordinate,
    ext_coords: *terminal.RenderState.StringMap,
) !bool {
    // Must have rows below the current match end.
    // Rows include the captured overscan below (smooth scrolling). Match
    // coordinates are viewport rows, so index from the viewport start.
    const vp_start = render_state.viewportStart();
    const rows = render_state.rowDataRange().end - vp_start;
    if (end_coord.y + 1 >= rows) return false;

    const row_slice = render_state.row_data.slice();
    const row_raws = row_slice.items(.raw)[vp_start..];
    const row_cells_all = row_slice.items(.cells)[vp_start..];

    // Don't extend if the row is part of a soft-wrap chain; the standard
    // string concatenation in RenderState.string() handles that case.
    // Must match the Surface-side guard (linkAtPinExtended) which rejects
    // both wrap and wrap_continuation to keep highlight and activation
    // consistent.
    const end_row = row_raws[end_coord.y];
    if (end_row.wrap or end_row.wrap_continuation) return false;

    // Get the cells for the row where the match ends.
    const end_row_cells = row_cells_all[end_coord.y].slice().items(.raw);

    // Detect the logical column window around the match end position.
    const window = link_extend.detectColumnWindow(
        end_row_cells,
        end_coord.x,
        render_state.cols,
    );

    // Check if the match is at the right boundary of the window.
    if (!link_extend.isAtRightBoundary(end_row_cells, end_coord.x, window)) return false;

    // Only extend scheme-based URLs (https://, ftp://, etc.), NOT file
    // path matches. The path branches of the URL regex are too broad
    // (allow spaces, bare relatives) and would stitch unrelated text.
    if (!link_extend.hasUrlScheme(initial_text)) return false;

    // Build the extended string: initial match text + continuation rows.
    var ext_builder: std.Io.Writer.Allocating = .init(alloc);
    defer ext_builder.deinit();
    var ext_map: std.ArrayListUnmanaged(point.Coordinate) = .empty;
    defer ext_map.deinit(alloc);

    // Prepend the initial match text (coordinates already tracked in the
    // caller's map, so we only track continuation coordinates).
    try ext_builder.writer.writeAll(initial_text);
    const initial_len = initial_text.len;

    // Extend across subsequent rows within the same column window.
    const max_y: usize = @min(
        @as(usize, end_coord.y) + link_extend.max_extend_rows + 1,
        rows,
    );

    var next_y: usize = @as(usize, end_coord.y) + 1;
    while (next_y < max_y) : (next_y += 1) {
        // Stop at any soft-wrap boundary to avoid mixing contexts.
        // A row with wrap_continuation is the tail of a soft-wrapped line
        // above; a row with wrap starts a soft-wrapped continuation below.
        const next_row_raw = row_raws[next_y];
        if (next_row_raw.wrap or next_row_raw.wrap_continuation) break;

        const next_slice = row_cells_all[next_y].slice();
        const next_cells_raw = next_slice.items(.raw);
        const next_cells_grapheme = next_slice.items(.grapheme);

        // Verify that the same column window exists on this row.
        const next_window = link_extend.detectColumnWindow(
            next_cells_raw,
            window.left,
            render_state.cols,
        );
        if (next_window.left != window.left or next_window.right != window.right) break;

        // Extract text from this row within the window.
        try link_extend.extractWindowText(
            &ext_builder.writer,
            next_cells_raw,
            next_cells_grapheme,
            next_window,
            @intCast(next_y),
            .{ .alloc = alloc, .map = &ext_map },
        );

        // If this row's content doesn't fill the window, it's likely
        // the last row of the URL. Include it but stop extending.
        var last_content_x: ?@TypeOf(end_coord.x) = null;
        {
            var x = next_window.right;
            while (true) {
                const cp = next_cells_raw[x].codepoint();
                if (cp != 0 and cp != ' ') {
                    last_content_x = x;
                    break;
                }
                if (x == next_window.left) break;
                x -= 1;
            }
        }
        if (last_content_x == null or last_content_x.? < next_window.right) break;
    }

    if (ext_map.items.len == 0) return false;

    // Re-run the regex on the extended string to find the full match.
    const ext_str = ext_builder.writer.buffered();
    var regex_mut = regex;
    var ext_region = regex_mut.search(ext_str, .{}) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    defer ext_region.deinit();

    // The match must start at position 0 (continuation of the same URL).
    if (ext_region.starts()[0] != 0) return false;

    // Check that the match extends beyond the initial text.
    const match_end: usize = @intCast(ext_region.ends()[0]);
    if (match_end <= initial_len) return false;

    // The extended portion covers bytes initial_len..match_end.
    // ext_map tracks coordinates starting from the first continuation byte.
    const ext_byte_count = @min(match_end - initial_len, ext_map.items.len);
    if (ext_byte_count == 0) return false;

    for (ext_map.items[0..ext_byte_count]) |pt| {
        try ext_coords.append(alloc, pt);
    }

    return true;
}

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
    );

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}
