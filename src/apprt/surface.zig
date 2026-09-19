// ROOTSHELL-TMUX: this upstream-shared file carries fork-owned tmux control-mode
// message variants and the SurfaceRelayWriter; the payload value types live in
// the sidecar apprt/surface_tmux.zig. Grep "ROOTSHELL-TMUX" here for every hook.
// See docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// A fixed-size desktop notification payload sent to the app thread.
    pub const DesktopNotification = struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,

        pub fn init(title: []const u8, body: []const u8) DesktopNotification {
            var result: DesktopNotification = undefined;
            copyUtf8Z(result.title.len, &result.title, title);
            copyUtf8Z(result.body.len, &result.body, body);
            return result;
        }

        /// UTF-8 continuation bytes occupy the range 0x80 through 0xBF.
        fn isUtf8ContinuationByte(byte: u8) bool {
            return switch (byte) {
                0x80...0xBF => true,
                else => false,
            };
        }

        /// Copy as much of `src` as fits, backing up from a UTF-8 continuation
        /// byte so valid input is never truncated in the middle of a codepoint.
        fn copyUtf8Z(
            comptime capacity: usize,
            dst: *[capacity:0]u8,
            src: []const u8,
        ) void {
            var len = @min(src.len, capacity);
            while (len > 0 and
                len < src.len and
                isUtf8ContinuationByte(src[len])) : (len -= 1)
            {}

            @memcpy(dst[0..len], src[0..len]);
            dst[len] = 0;
        }
    };

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Coalesced notification that the active terminal content changed.
    /// Carries no data; the mailbox already identifies the exact surface.
    surface_content_changed,

    /// Report the window title back to the terminal
    report_title: ReportTitleStyle,

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: apprt.Clipboard,

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: DesktopNotification,

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// The IO thread resized the terminal; the external pty may follow.
    pty_resize: apprt.action.PtyResize,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: terminal.osc.color.ColoredTarget,

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional u8 is the exit code
    /// of the command.
    stop_command: ?u8,

    /// The scrollbar state changed for the surface.
    scrollbar: terminal.Scrollbar,

    /// Search progress update
    search_total: ?usize,

    /// Selected search index change
    search_selected: ?usize,

    /// The tmux viewer's window topology has changed. The snapshot is a
    /// deep copy of the viewer's windows and layouts, allocated on its own
    /// arena. The receiver (app thread) owns the snapshot and must call
    /// deinit when done.
    tmux_topology_changed: *TmuxTopologySnapshot, // ROOTSHELL-TMUX (id=apprt-msg-topology)

    /// A tmux child pane is relaying a command to its parent surface's
    /// pty. The child's IO thread constructs this message targeting the
    /// parent surface's mailbox. The parent surface's `handleMessage`
    /// forwards the command bytes to its own termio mailbox via `queueIo`.
    ///
    /// This preserves the SPSC invariant: the parent's IO thread remains
    /// the single consumer of its termio mailbox. The child never writes
    /// directly to the parent's mailbox.
    tmux_write_command: WriteReq, // ROOTSHELL-TMUX (id=apprt-msg-write)

    /// The active pane changed in tmux (`%window-pane-changed`
    /// notification). The parent surface's stream handler constructs
    /// this message so the app thread can update focus to the correct
    /// window tab and pane surface.
    ///
    /// Lightweight value type — no heap allocation needed since it
    /// carries only two IDs.
    tmux_focus_changed: TmuxFocusChanged, // ROOTSHELL-TMUX (id=apprt-msg-focus)

    /// A tmux title changed — either a window rename (tab title) or
    /// a session rename (Ghostty window title). The parent surface's
    /// stream handler constructs this message so the app thread can
    /// update the displayed title.
    ///
    /// Lightweight value type — fixed-size buffer, no heap allocation.
    tmux_title_changed: TmuxTitleChanged, // ROOTSHELL-TMUX (id=apprt-msg-title)

    /// Response to an app-issued tmux query command (see
    /// `ghostty_surface_tmux_command_with_reply`). Heap pointer like
    /// `tmux_topology_changed`; the app thread owns it and must call
    /// deinit after consuming.
    tmux_command_response: *TmuxCommandResponse, // ROOTSHELL-TMUX (id=apprt-msg-command-response)

    /// The set of sessions on the tmux server changed (or another client
    /// attached/detached/switched). The app refreshes any session list UI.
    tmux_sessions_changed: void, // ROOTSHELL-TMUX (id=apprt-msg-sessions-changed)

    /// The identity of the session this gateway is attached to changed
    /// (startup, switch, or rename). Lightweight fixed-buffer value.
    tmux_session_info: TmuxSessionInfo, // ROOTSHELL-TMUX (id=apprt-msg-session-info)

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "GhosttyApprtChildExited" },
            ),

            .none => void,
        };
    };

    // ROOTSHELL-TMUX BEGIN (id=apprt-surface-tmux-types-extracted)
    // The tmux message payload value types (TmuxFocusChanged, TmuxTitleChanged,
    // TmuxTopologySnapshot) were extracted to the fork-owned sidecar
    // src/apprt/surface_tmux.zig to shrink the tmux footprint in this
    // upstream-shared union. They stay re-exported here as `Message.Tmux*` so
    // external references (e.g. stream_handler.zig's
    // `apprt.surface.Message.TmuxTopologySnapshot.initFromWindows`) keep
    // resolving, and so the tmux_* variants above resolve them in-scope.
    //
    // reapply: if this conflicts on rebase, keep these three aliases inside the
    // Message union; the bodies live in surface_tmux.zig. See
    // docs/tmux-control-mode-fork.md.
    pub const TmuxFocusChanged = @import("surface_tmux.zig").TmuxFocusChanged;
    pub const TmuxTitleChanged = @import("surface_tmux.zig").TmuxTitleChanged;
    pub const TmuxTopologySnapshot = @import("surface_tmux.zig").TmuxTopologySnapshot;
    pub const TmuxCommandResponse = @import("surface_tmux.zig").TmuxCommandResponse;
    pub const TmuxSessionInfo = @import("surface_tmux.zig").TmuxSessionInfo;
    // ROOTSHELL-TMUX END (id=apprt-surface-tmux-types-extracted)
};

/// A ControlWriter implementation that routes tmux commands through
/// the app mailbox to the parent surface. When a child tmux pane runs
/// on its own IO thread, it cannot safely write directly into the
/// parent's SPSC termio mailbox.
///
/// Instead, command bytes are wrapped in an `apprt.surface.Message`
/// (.tmux_write_command) and pushed to the parent surface's mailbox.
/// The app mailbox is MPSC-safe, so any thread can push. The app
/// thread delivers the message to the parent surface's `handleMessage`,
/// which forwards the command bytes into the parent's termio mailbox
/// via `queueIo` — preserving the SPSC invariant.
///
/// ## Relay Path
///
///   Child IO thread: SurfaceRelayWriter.writeFn()
///     → constructs WriteReq from command bytes
///     → pushes .tmux_write_command to parent surface mailbox
///     → (app mailbox MPSC push, safe from any thread)
///   App thread: drainMailbox → parent Surface.handleMessage
///     → .tmux_write_command → queueIo(.write_small/.write_alloc)
///     → parent termio mailbox (SPSC: app thread is single producer)
///
/// ## Lifetime
///
/// The `parent_mailbox` must remain valid for the lifetime of this
/// writer. In practice, the parent surface outlives all child surfaces
/// it creates.
// ROOTSHELL-TMUX (id=apprt-relay-writer): MPSC relay of a child tmux pane's
// writes to the parent surface mailbox. Kept here (not in surface_tmux.zig)
// because it is tightly coupled to this file's Message/Mailbox types.
pub const SurfaceRelayWriter = struct {
    const ControlWriter = terminal.tmux.ControlWriter;

    parent_mailbox: Mailbox,
    alloc: Allocator,

    pub fn controlWriter(self: *SurfaceRelayWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *SurfaceRelayWriter = @ptrCast(@alignCast(context));

        // Construct a surface-level WriteReq from the command bytes.
        // Surface WriteReq (MessageData(u8, 255)) can hold up to 255
        // bytes inline; larger commands are heap-allocated.
        const SurfaceWriteReq = Message.WriteReq;
        const req = SurfaceWriteReq.init(self.alloc, data) catch
            return error.WriteFailed;

        // Push to the parent surface's mailbox. This goes through the
        // app mailbox (MPSC-safe). Use .forever since we don't hold
        // any mutex that could deadlock with the app thread.
        _ = self.parent_mailbox.push(
            .{ .tmux_write_command = req },
            .{ .forever = {} },
        );
    }
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
    /// Queue one coalesced content edge for this exact surface.
    pub fn contentChanged(self: Mailbox) void {
        self.surface.queueContentChanged();
    }
};

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};

pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) Allocator.Error!Config {
    // Create a shallow clone
    var copy = config.shallowClone(app.alloc);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Get our previously focused surface for some inherited values.
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = .{ .path = pwd };
            }
        }
    }

    return copy;
}

test "DesktopNotification init" {
    const notification = Message.DesktopNotification.init("Title", "Body");

    try std.testing.expectEqualStrings("Title", std.mem.sliceTo(&notification.title, 0));
    try std.testing.expectEqualStrings("Body", std.mem.sliceTo(&notification.body, 0));
}

test "copyUtf8Z handles len at the final byte of every UTF-8 sequence length" {
    const DesktopNotification = Message.DesktopNotification;

    var dst_1_byte: [1:0]u8 = undefined;
    const src_ending_in_1_byte_codepoint = "ab";
    try std.testing.expect(!DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_1_byte_codepoint[dst_1_byte.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_1_byte.len,
        &dst_1_byte,
        src_ending_in_1_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_1_byte, 0));

    var dst_2_bytes: [2:0]u8 = undefined;
    const src_ending_in_2_byte_codepoint = "aЯ";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_2_byte_codepoint[dst_2_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_2_bytes.len,
        &dst_2_bytes,
        src_ending_in_2_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_2_bytes, 0));

    var dst_3_bytes: [3:0]u8 = undefined;
    const src_ending_in_3_byte_codepoint = "a€";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_3_byte_codepoint[dst_3_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_3_bytes.len,
        &dst_3_bytes,
        src_ending_in_3_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_3_bytes, 0));

    var dst_4_bytes: [4:0]u8 = undefined;
    const src_ending_in_4_byte_codepoint = "a😀";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_4_byte_codepoint[dst_4_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_4_bytes.len,
        &dst_4_bytes,
        src_ending_in_4_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_4_bytes, 0));
}

test "copyUtf8Z keeps a complete codepoint at the truncation boundary" {
    var dst: [5:0]u8 = undefined;

    Message.DesktopNotification.copyUtf8Z(dst.len, &dst, "abcЯz");

    try std.testing.expectEqualStrings("abcЯ", std.mem.sliceTo(&dst, 0));
}

test "copyUtf8Z preserves UTF-8 that fits" {
    var dst: [5:0]u8 = undefined;

    Message.DesktopNotification.copyUtf8Z(dst.len, &dst, "abcЯ");

    try std.testing.expectEqualStrings("abcЯ", std.mem.sliceTo(&dst, 0));
}
