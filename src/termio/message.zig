// ROOTSHELL-TMUX: this upstream-shared file carries the fork's
// `tmux_set_client_size` termio message variant. Grep "ROOTSHELL-TMUX" here for
// every hook. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment),
/// but the number of messages we send to the IO thread is also very small.
/// At the current size we can queue 26,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

    /// Request a color scheme report is sent to the PTY.
    color_scheme_report: struct {
        /// Force write the current color scheme
        force: bool,
    },

    /// Request a visibility report is sent to the PTY.
    visibility_report: struct {
        /// The visibility state to report.
        visible: bool,

        /// Send the report even when mode 2033 is disabled.
        force: bool,
    },

    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash: void,

    /// The derived configuration to update the implementation with. This
    /// is allocated via the allocator and is expected to be freed when done.
    change_config: struct {
        alloc: Allocator,
        ptr: *termio.Termio.DerivedConfig,
    },

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// Resize the window.
    resize: renderer.Size,

    /// Request a size report is sent to the PTY ([in-band
    /// size report, mode 2048](https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83) and
    /// [XTWINOPS](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Functions-using-CSI-_-ordered-by-the-final-character-lparen-s-rparen:CSI-Ps;Ps;Ps-t.1EB0)).
    size_report: SizeReport,

    /// Clear the screen.
    clear_screen: struct {
        /// Include clearing the history
        history: bool,
    },

    /// Scroll the viewport
    scroll_viewport: terminal.Terminal.ScrollViewport,

    /// Selection scrolling. If this is set to true then the termio
    /// thread starts a timer that will trigger a `selection_scroll_tick`
    /// message back to the surface. This ping/pong is because the
    /// surface thread doesn't have access to an event loop from libghostty.
    selection_scroll: bool,

    /// Jump forward/backward n prompts.
    jump_to_prompt: isize,

    /// Set the tmux control-mode client size (cols x rows in cells). Handled on
    /// the IO thread so it can safely touch the viewer's command queue. The
    /// stream handler sends `refresh-client -C <cols>x<rows>` to tmux so the
    /// active window's panes are laid out to the visible tab's size. No-op when
    /// no tmux viewer is active.
    tmux_set_client_size: struct { // ROOTSHELL-TMUX (id=termio-msg-set-client-size)
        cols: u16,
        rows: u16,
    },

    /// A raw, pre-formatted tmux command (with trailing newline) relayed from a
    /// child pane backend (resize-pane / select-pane / select-window). Handled
    /// on the IO thread so it can be routed through the viewer's command queue
    /// instead of written straight to tmux, keeping the command/response FIFO
    /// aligned (a stray untracked block otherwise blanks a pane on attach).
    /// `data` is owned and freed after handling. See
    /// `StreamHandler.tmuxQueuePaneCommand`.
    tmux_pane_command: struct { // ROOTSHELL-TMUX (id=termio-msg-pane-command)
        alloc: Allocator,
        data: []const u8,
    },

    /// An app-issued tmux query command (with trailing newline) whose response
    /// must be delivered back to the app, correlated by `tag` (see the
    /// `command_response` viewer action / GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE).
    /// Handled on the IO thread so it can be routed through the viewer's
    /// command queue (FIFO-safe, like `tmux_pane_command`). Heap-allocated
    /// payload (alloc + data + tag exceeds the 40-byte Message budget); the
    /// handler frees both the data and the payload struct. See
    /// `StreamHandler.tmuxQueueQueryCommand`.
    tmux_query_command: *TmuxQueryCommand, // ROOTSHELL-TMUX (id=termio-msg-query-command)

    /// Untracked `send-keys` (typed input / paste / focus reports) relayed from a
    /// child pane backend. Recorded as an `.untracked` marker in the viewer's
    /// sent-FIFO (under tmux_mutex, just before the write — see Thread
    /// id=thread-tmux-write-record-atomic) and written straight to the
    /// `tmux -CC` pty (no command-queue gating, so keystroke latency is
    /// unchanged), so its `%begin/%end` ack is matched/swallowed in order
    /// instead of being mis-attributed to an in-flight tracked command (which
    /// would desync the response FIFO). `data` is owned and freed after
    /// handling. See `StreamHandler.recordTmuxUntrackedSend`.
    tmux_send_keys: struct { // ROOTSHELL-TMUX (id=termio-msg-send-keys)
        alloc: Allocator,
        data: []const u8,
    },

    /// A tracked tmux command (already formatted, with trailing newline) emitted
    /// by the viewer. Recorded as a `.tracked` marker and written to the pty.
    /// Recording happens at this single drain point (NOT at the viewer enqueue
    /// site) because the SPSC mailbox can reorder the actual write behind a
    /// `send-keys` already queued ahead of it; recording at the drain, in drain
    /// order, guarantees marker order == pty write order == tmux block order
    /// (see Thread id=thread-tmux-write-record-atomic for the record-before-
    /// write rationale). `data` is owned and freed after handling. See
    /// `StreamHandler.recordTmuxTrackedSend`.
    tmux_track_command: struct { // ROOTSHELL-TMUX (id=termio-msg-track-command)
        alloc: Allocator,
        data: []const u8,
    },

    /// Detach the tmux control-mode client for this surface's viewer. Handled on
    /// the IO thread so it can queue a `detach-client` through the viewer's
    /// command queue (FIFO-safe, NOT a raw write that would desync the response
    /// FIFO). tmux replies %exit, which tears the viewer down and lets the
    /// `tmux -CC` process exit back to its shell. No-op when no tmux viewer is
    /// active. See `StreamHandler.tmuxDetach`.
    tmux_detach: void, // ROOTSHELL-TMUX (id=termio-msg-detach)

    /// Resume tmux control mode on this surface after the app relaunched and
    /// tssh reattached a still-live `tmux -CC` pty. Handled on the IO thread:
    /// it synthesizes the `ESC P 1000 p` control-mode entry on the (fresh)
    /// stream so the viewer is created exactly as on a real hook, then puts the
    /// viewer into the resync state to drain the reattached stream and rebuild
    /// the topology. No-op when no resume is appropriate (tmux disabled, viewer
    /// already active). See `Thread` `.tmux_resume` + `StreamHandler.enterResync`.
    /// Optional locally selected tmux window to recover first on a cold app
    /// restoration. Nil preserves the legacy server-active startup order.
    tmux_resume: ?usize, // ROOTSHELL-TMUX (id=termio-msg-resume)

    /// Abort an in-progress tmux control-mode resume (the app's resume watchdog
    /// fired because no reconcile arrived: tmux died / the session expired / the
    /// reattached pty is at a bare shell). Handled on the IO thread: tears down
    /// the resync viewer and forces the VT parser back to ground so the gateway
    /// renders its shell normally. No-op when no viewer is active. See
    /// `StreamHandler.tmuxResumeAbort`.
    tmux_resume_abort: void, // ROOTSHELL-TMUX (id=termio-msg-resume-abort)

    /// Recover a LIVE tmux control-mode gateway whose command/response stream
    /// desynced or that lost mid-stream data (the tsshd buffer overflowed while
    /// the app was backgrounded). Handled on the IO thread: drives a live
    /// re-resync (reset the command pipeline, realign the parser, re-probe,
    /// rebuild via list-windows) WITHOUT tearing down panes. No-op unless a
    /// viewer is live in the steady command-queue state. Distinct from
    /// `tmux_resume` (which only acts when NO viewer exists). See `Thread`
    /// `.tmux_recover` + `StreamHandler.tmuxForceResync`. ROOTSHELL-TMUX
    /// (id=termio-msg-recover)
    tmux_recover: void, // ROOTSHELL-TMUX (id=termio-msg-recover)

    /// Full RESET of a LIVE tmux control-mode gateway after a LOSSY reconnect (the
    /// tsshd server discarded buffered output, dropping bytes mid-`%output`/control
    /// block). Handled on the IO thread: like `tmux_recover` (re-resync + parser
    /// realign + re-probe + list-windows rebuild) but ADDITIONALLY force-recaptures
    /// EVERY pane so dropped content is rebuilt to a consistent state, and re-arms
    /// the title subscription. Preserves the window/tab topology (no flicker).
    /// No-op unless a viewer is live in the steady command-queue state. See `Thread`
    /// `.tmux_reset` + `StreamHandler.tmuxForceReset`. ROOTSHELL-TMUX
    /// (id=termio-msg-reset)
    tmux_reset: void, // ROOTSHELL-TMUX (id=termio-msg-reset)

    /// Re-send the resync probe on a gateway ALREADY waiting for its marker.
    /// Handled on the IO thread by `StreamHandler.tmuxResumeResendProbe` and
    /// NOTHING else — no viewer creation, no control-mode entry. This is the
    /// difference from `tmux_resume`, whose no-viewer branch synthesizes `ESC P
    /// 1000 p` and would RESURRECT a gateway that has since gone away; the app's
    /// resync watchdog re-probes on a cadence and cannot know whether a queued
    /// message will drain before or after the viewer disappears. Strictly a no-op
    /// unless a viewer exists AND is resyncing. See `Thread` `.tmux_reprobe`.
    /// ROOTSHELL-TMUX (id=termio-msg-reprobe)
    tmux_reprobe: void, // ROOTSHELL-TMUX (id=termio-msg-reprobe)

    /// Forcibly exit tmux control mode LOCALLY on a live gateway, equivalent to a
    /// `%exit`: tear down the viewer, emit an empty-topology snapshot (so the app
    /// prunes the projected tabs via the normal reconcile path, which also drops
    /// the controller), and return the VT parser to ground so the gateway renders
    /// its shell. Used by the app's recovery watchdog when a wedge cannot be
    /// healed (does NOT wait for tmux to answer a `detach-client`, unlike
    /// `tmux_detach`, so it works even if tmux/the link is unresponsive). The tmux
    /// server/session stays alive. See `Thread` `.tmux_force_exit` +
    /// `StreamHandler.tmuxForceExit`. ROOTSHELL-TMUX (id=termio-msg-force-exit)
    tmux_force_exit: void, // ROOTSHELL-TMUX (id=termio-msg-force-exit)

    /// Retry tmux pane work deferred by bounded renderer-lock timeouts
    /// (spilled %output, deferred resizes, dropped-spill re-fetch) and re-send
    /// a topology snapshot that was dropped under app-mailbox backpressure.
    /// Sent by the app's heartbeat as an idle-session nudge; cheap and
    /// idempotent when nothing is deferred. See `Thread` `.tmux_flush_deferred`
    /// + `StreamHandler.tmuxFlushDeferred`. ROOTSHELL-TMUX
    /// (id=termio-msg-flush-deferred)
    tmux_flush_deferred: void,

    /// Send this when a synchronized output mode is started. This will
    /// start the timer so that the output mode is disabled after a
    /// period of time so that a bad actor can't hang the terminal.
    start_synchronized_output: void,

    /// Enable or disable linefeed mode (mode 20).
    linefeed_mode: bool,

    /// The surface gained or lost focus.
    focused: bool,

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: WriteReq.Stable,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }

    /// Free resources owned by a message that will not be processed.
    /// The message is invalid after this call.
    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.ptr.deinit();
                v.alloc.destroy(v.ptr);
            },
            .write_alloc => |v| v.alloc.free(v.data),
            .tmux_pane_command => |v| v.alloc.free(v.data),
            // ROOTSHELL-TMUX (id=termio-msg-query-command)
            .tmux_query_command => |v| {
                v.alloc.free(v.data);
                v.alloc.destroy(v);
            },
            .tmux_send_keys => |v| v.alloc.free(v.data), // ROOTSHELL-TMUX (id=termio-msg-send-keys)
            .tmux_track_command => |v| v.alloc.free(v.data), // ROOTSHELL-TMUX (id=termio-msg-track-command)
            else => {},
        }
    }

    /// The types of size reports that we support.
    pub const SizeReport = terminal.size_report.Style;

    /// Heap payload for `tmux_query_command`. ROOTSHELL-TMUX
    /// (id=termio-msg-query-command)
    pub const TmuxQueryCommand = struct {
        alloc: Allocator,
        data: []const u8,
        tag: u32,
    };
};

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}
