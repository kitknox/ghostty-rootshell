// ROOTSHELL-TMUX: this upstream-shared file carries fork-owned tmux control-mode
// hooks (tmux_viewer field, %-notification dispatch, client-size helper, empty
// topology snapshot on exit). Grep "ROOTSHELL-TMUX" here for every hook. See
// docs/tmux-control-mode-fork.md.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const terminal = @import("../terminal/main.zig");
const terminfo = @import("../terminfo/main.zig");
const posix = std.posix;

const log = std.log.scoped(.io_handler);

/// Milliseconds on the monotonic clock, for the tmux debug mirror, the
/// post-exit drain and the read-progress gauges. `std.time.milliTimestamp`
/// was removed in Zig 0.16; these values are only ever consumed as deltas,
/// so a monotonic clock is strictly more correct than the old wall clock.
/// `.awake` is CLOCK_UPTIME_RAW on Darwin: it pauses while the device sleeps,
/// so ages under-report across a sleep (the app's watchdogs see a shorter gap
/// right after wake, never a spurious timeout). ROOTSHELL-TMUX (id=tmux-debug-mirror)
fn nowMs() i64 {
    const ts: std.Io.Timestamp = .now(global.io(), .awake);
    return ts.toMilliseconds();
}

// ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=tmux-debug-snapshot-struct)
// Privacy-safe scalar snapshot of tmux control-mode internals, filled by
// `ghostty_surface_tmux_debug_snapshot` for the iOS debug log. Contains ONLY
// numeric ids, counts, enum codes, ages (ms) and booleans — never pane output,
// titles, command text, keystrokes, or hostnames — so the log is safe for users
// to share with us. Read losslessly off the IO thread via an atomic mirror, so
// it stays valid even when the IO thread is wedged (the exact case this exists
// to diagnose). Layout is FROZEN: only APPEND new fields at the end and bump
// `abi_version`; never reorder or resize existing fields (the Swift bridge maps
// it by C layout). Mirrored byte-for-byte in include/ghostty.h. See
// docs/tmux-control-mode-fork.md.
pub const TmuxDebugSnapshot = extern struct {
    /// Snapshot ABI version. Bumped when fields are appended. Currently 2
    /// (v2 appended the read-thread progress fields at the tail).
    abi_version: u32,

    // --- liveness / state (booleans are 0/1) ---
    /// 0 none, 1 startup, 2 resync, 3 command_queue, 4 defunct.
    viewer_state: u8,
    /// 0 inactive(unhooked), 1 idle, 2 notification, 3 block, 4 broken.
    parser_state: u8,
    parser_tolerant: u8,
    tmux_active: u8,
    /// DCS still hooked after %exit / broken — the gateway-stuck signal.
    force_unhook_pending: u8,
    resume_pending: u8,
    command_in_flight: u8,
    /// Command union tag of the in-flight command (0 none). See commandKindCode:
    /// 1 list_windows, 2 pane_history, 3 pane_visible, 4 pane_state,
    /// 5 tmux_version, 6 subscribe_titles, 7 pane_mode_query, 8 client_size,
    /// 9 continue_pane, 10 pane_color_report, 11 user, 12 enable_pause,
    /// 13 user_query.
    in_flight_cmd_kind: u8,
    /// control.ErrorCode of the parser / viewer respectively.
    parser_last_error: u8,
    viewer_last_error: u8,

    // --- command pipeline ---
    command_queue_depth: u32,
    command_queue_highwater: u32,
    sent_fifo_depth: u32,
    sent_fifo_highwater: u32,

    // --- topology ---
    session_id: u32,
    window_count: u32,
    pane_count: u32,
    retired_pane_count: u32,
    paused_pane_count: u32,
    uninitialized_pane_count: u32,
    /// Sum of per-pane query replies buffered but not yet flushed back to tmux
    /// (a TUI waiting on a reply tmux never answered shows up here).
    pending_pane_responses: u32,

    // --- control buffer (bytes only, never the content) ---
    parser_buffer_bytes: u32,
    parser_buffer_highwater: u32,
    parser_buffer_max_bytes: u32,

    // --- timings, ms; computed at read time so they grow during a stall.
    //     0 means "never / n.a." ---
    ms_since_last_output: u64,
    ms_since_last_block: u64,
    ms_since_last_command_sent: u64,
    ms_since_last_notification: u64,
    ms_since_viewer_created: u64,
    resync_age_ms: u64,

    // --- monotonic counters since viewer creation ---
    total_notifications: u64,
    total_blocks: u64,
    total_output_events: u64,
    total_commands_sent: u64,

    // --- ABI v2 appendix: read-thread progress (id=tmux-debug-read-progress).
    //     Diagnoses bytes vanishing between the transport and the tmux parser:
    //     `gw_read_enter_bytes` counts bytes entering Termio.processOutput for
    //     this surface (stamped BEFORE any lock), `gw_read_done_bytes` after
    //     the parse completes, `gw_tmux_put_bytes` bytes that reached the tmux
    //     DCS put path. When enter > done and `ms_since_read_enter` grows, the
    //     read thread is BLOCKED; `read_thread_site` (TmuxReadSite: 0 idle,
    //     1 awaiting-gateway-lock, 2 parsing, 3 pane-lock, 4 mailbox-send,
    //     5 surface-mailbox-send) and `read_site_pane_id` name where. ---
    gw_read_enter_bytes: u64,
    gw_read_done_bytes: u64,
    gw_tmux_put_bytes: u64,
    ms_since_read_enter: u64,
    ms_since_read_done: u64,
    pane_lock_timeouts: u64,
    read_site_pane_id: u32,
    read_thread_site: u8,
    _reserved_v2: [3]u8,
};
// ROOTSHELL-TMUX END FROZEN-ABI (id=tmux-debug-snapshot-struct)

/// IO-thread-written / app-thread-read atomic mirror backing
/// `TmuxDebugSnapshot`. The IO thread refreshes it at existing tmux event sites
/// (only while `enabled`, so it is a no-op until the app first calls the
/// snapshot ABI); the app thread reads it locklessly with relaxed ordering.
/// Per-field relaxed atomics (not a seqlock): fields may be from instants a few
/// microseconds apart, which is irrelevant for a 1–2 Hz diagnostic dump and
/// keeps the read free of any dependency on the (possibly wedged) IO thread.
/// Timestamps are monotonic ms (`nowMs`), 0 = never; the app reader converts
/// them to ages. ROOTSHELL-TMUX (id=tmux-debug-mirror)
const TmuxDebugMirror = struct {
    enabled: std.atomic.Value(bool) = .init(false),

    viewer_state: std.atomic.Value(u8) = .init(0),
    parser_state: std.atomic.Value(u8) = .init(0),
    parser_tolerant: std.atomic.Value(bool) = .init(false),
    force_unhook: std.atomic.Value(bool) = .init(false),
    resume_pending: std.atomic.Value(bool) = .init(false),
    command_in_flight: std.atomic.Value(bool) = .init(false),
    in_flight_cmd_kind: std.atomic.Value(u8) = .init(0),
    parser_last_error: std.atomic.Value(u8) = .init(0),
    viewer_last_error: std.atomic.Value(u8) = .init(0),

    command_queue_depth: std.atomic.Value(u32) = .init(0),
    command_queue_highwater: std.atomic.Value(u32) = .init(0),
    sent_fifo_depth: std.atomic.Value(u32) = .init(0),
    sent_fifo_highwater: std.atomic.Value(u32) = .init(0),

    session_id: std.atomic.Value(u32) = .init(0),
    window_count: std.atomic.Value(u32) = .init(0),
    pane_count: std.atomic.Value(u32) = .init(0),
    retired_pane_count: std.atomic.Value(u32) = .init(0),
    paused_pane_count: std.atomic.Value(u32) = .init(0),
    uninitialized_pane_count: std.atomic.Value(u32) = .init(0),
    pending_pane_responses: std.atomic.Value(u32) = .init(0),

    parser_buffer_bytes: std.atomic.Value(u32) = .init(0),
    parser_buffer_highwater: std.atomic.Value(u32) = .init(0),
    parser_buffer_max_bytes: std.atomic.Value(u32) = .init(0),

    last_output_ms: std.atomic.Value(i64) = .init(0),
    last_block_ms: std.atomic.Value(i64) = .init(0),
    last_command_ms: std.atomic.Value(i64) = .init(0),
    last_notification_ms: std.atomic.Value(i64) = .init(0),
    viewer_created_ms: std.atomic.Value(i64) = .init(0),
    resync_started_ms: std.atomic.Value(i64) = .init(0),

    total_notifications: std.atomic.Value(u64) = .init(0),
    total_blocks: std.atomic.Value(u64) = .init(0),
    total_output_events: std.atomic.Value(u64) = .init(0),
    total_commands_sent: std.atomic.Value(u64) = .init(0),

    // ROOTSHELL-TMUX (id=tmux-debug-read-progress): read-thread progress
    // gauges, written DIRECTLY at the byte sites (not via refreshTmuxDebug —
    // a wedged read thread never reaches the event-site refresh, which is the
    // exact case these exist to diagnose). `read_site` says where the read
    // thread last was (see TmuxReadSite); when it is nonzero and
    // `read_enter_ms` is old, the thread is BLOCKED at that site.
    read_enter_bytes: std.atomic.Value(u64) = .init(0),
    read_done_bytes: std.atomic.Value(u64) = .init(0),
    tmux_put_bytes: std.atomic.Value(u64) = .init(0),
    read_enter_ms: std.atomic.Value(i64) = .init(0),
    read_done_ms: std.atomic.Value(i64) = .init(0),
    read_site: std.atomic.Value(u8) = .init(0),
    read_site_pane: std.atomic.Value(u32) = .init(0),
    pane_lock_timeouts: std.atomic.Value(u64) = .init(0),
};

/// ROOTSHELL-TMUX (id=tmux-debug-read-progress): where the gateway's
/// byte-processing thread last was. Written by the read thread (and, for the
/// mailbox/pane sites, occasionally the IO event-loop thread running viewer
/// code under tmux_mutex) — last-writer-wins is fine for a diagnostic.
pub const TmuxReadSite = enum(u8) {
    idle = 0,
    /// Waiting to acquire the gateway parse lock (renderer or tmux mutex).
    awaiting_gateway_lock = 1,
    /// Inside the stream parse.
    parsing = 2,
    /// Waiting on a pane child surface's renderer mutex (pane id alongside).
    pane_lock = 3,
    /// Inside a termio mailbox send.
    mailbox_send = 4,
    /// Inside a surface (app) mailbox send.
    surface_mailbox_send = 5,
};

/// This is used as the handler for the terminal.Stream type. This is
/// stateful and is expected to live for the entire lifetime of the terminal.
/// It is NOT VALID to stop a stream handler, create a new one, and use that
/// unless all of the member fields are copied.
pub const StreamHandler = struct {
    alloc: Allocator,
    size: *renderer.Size,
    terminal: *terminal.Terminal,

    /// Mailbox for data to the termio thread.
    termio_mailbox: *termio.Mailbox,

    /// Mailbox for the surface.
    surface_mailbox: apprt.surface.Mailbox,

    /// The shared render state
    renderer_state: *renderer.State,

    /// The mailbox for notifying the renderer of things.
    renderer_mailbox: *renderer.Thread.Mailbox,

    /// A handle to wake up the renderer. This hints to the renderer that
    /// a repaint should happen.
    renderer_wakeup: xev.Async,

    /// The response to use for ENQ requests. The memory is owned by
    /// whoever owns StreamHandler.
    enquiry_response: []const u8,

    /// The color reporting format for OSC requests.
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,

    /// The clipboard write access configuration.
    clipboard_write: configpkg.ClipboardAccess,

    /// Whether tmux control mode is enabled at runtime.
    tmux_control_mode: bool = true,

    /// Cached OS color scheme (true = dark), refreshed in changeConfig from
    /// config.conditional_state.theme. Lets `sendColorSchemeReport` answer the
    /// CSI ?996n / mode-2031 theme query INLINE on the read thread — under the
    /// renderer lock we already hold while parsing — instead of deferring a
    /// `color_scheme_report` message that the IO thread's drainMailbox must
    /// re-acquire renderer_state.mutex to handle. That cross-thread re-lock
    /// gets starved under a heavy-output flood (zellij), stalling the drain for
    /// seconds and dropping write_small. (id=streamhandler-inline-reports)
    color_scheme_is_dark: bool = true,

    //---------------------------------------------------------------
    // Internal state

    /// The APC command handler maintains the APC state. APC is like
    /// CSI or OSC, but it is a private escape sequence that is used
    /// to send commands to the terminal emulator. This is used by
    /// the kitty graphics protocol.
    apc: terminal.apc.Handler = .{},

    /// The DCS handler maintains DCS state. DCS is like CSI or OSC,
    /// but requires more stateful parsing. This is used by functionality
    /// such as XTGETTCAP.
    dcs: terminal.dcs.Handler = .{},

    /// The tmux control mode viewer state.
    tmux_viewer: if (tmux_enabled) ?*terminal.tmux.Viewer else void = if (tmux_enabled) null else {}, // ROOTSHELL-TMUX (id=streamhandler-viewer-field)

    /// Atomic mirror of "a tmux control-mode viewer exists", written by the IO
    /// thread alongside every `tmux_viewer` mutation and read cross-thread by the
    /// app thread (`ghostty_surface_tmux_active` → `tmuxActive`). The viewer
    /// POINTER must never be read off-thread (the IO thread can free it); this
    /// atomic bool is the well-defined cross-thread signal instead. ROOTSHELL-TMUX
    /// (id=streamhandler-tmux-active-flag)
    tmux_active_flag: std.atomic.Value(bool) = .init(false),

    /// Set when tmux control mode ends (`%exit`) so the next stream check forces
    /// the parser out of the control-mode DCS passthrough. Without this the
    /// gateway parser stays hooked after `tmux -CC` exits and swallows the shell's
    /// prompt, leaving the tab stuck. See `dcsConsumeGroundRequest`.
    tmux_force_unhook: bool = false, // ROOTSHELL-TMUX (id=streamhandler-force-unhook-field)

    /// Set by `tmuxResumeShouldEnter` just before the synthetic `ESC P 1000 p`
    /// is fed on a control-mode RESUME (app relaunch reattaching a live
    /// `tmux -CC` over tssh). The `.enter` DCS dispatch checks it: instead of
    /// leaving the freshly-created viewer in `.startup` (waiting for a fresh
    /// handshake that never comes on a resume), it flips the viewer into
    /// `.resync` and sends the resync probe. Cleared as soon as it is consumed.
    /// ROOTSHELL-TMUX (id=streamhandler-resume-pending-field)
    tmux_resume_pending: bool = false,

    /// Restored local selection carried by the first resume message. Consumed
    /// with tmux_resume_pending when the synthetic control-mode entry creates
    /// its viewer, so cold recovery can schedule that window first.
    /// ROOTSHELL-TMUX (id=streamhandler-resume-priority)
    tmux_resume_preferred_window: ?usize = null,

    /// Atomic mirror of tmux control-mode internals for the iOS debug snapshot
    /// (`ghostty_surface_tmux_debug_snapshot`). Written by the IO thread at tmux
    /// event sites via `refreshTmuxDebug` (only once the app has opted in), read
    /// locklessly by the app thread via `tmuxDebugSnapshot`. ROOTSHELL-TMUX
    /// (id=tmux-debug-mirror)
    tmux_debug: if (tmux_enabled) TmuxDebugMirror else void = if (tmux_enabled) .{} else {},

    /// This is set to true when a message was written to the termio
    /// mailbox. This can be used by callers to determine if they need
    /// to wake up the termio thread.
    termio_messaged: bool = false,

    /// ROOTSHELL-TMUX (id=streamhandler-unlocked-io): true while the current
    /// thread is executing handler/viewer code while HOLDING
    /// `Termio.tmux_mutex` (with or without the renderer mutex). While set,
    /// `messageWriter` / `surfaceMessageWriter` / `rendererMessageWriter`
    /// must use bounded no-unlock sends. The queue-full slow paths otherwise
    /// unlock/relock the renderer mutex, which is (a) UB when it isn't held
    /// (tmux-only paths) and (b) an ABBA deadlock when it IS held: re-locking
    /// renderer while holding tmux violates the renderer -> tmux lock order
    /// against any thread doing renderer -> tmux. Always read/written under
    /// tmux_mutex, so a plain bool is sound.
    tmux_unlocked_io: bool = false,

    /// ROOTSHELL-TMUX (id=streamhandler-parse-liveness): true only while the
    /// current parse holds the renderer mutex (the ordinary-surface block in
    /// `Termio.processOutput`). Together with `!tmuxControlHooked()` it marks
    /// the state where a queue-full send may safely release BOTH mutexes and
    /// wait for the consumer (upstream behavior): no tmux state is in flight
    /// pre-hook, and hook state only changes on this parsing thread so it
    /// cannot flip while we wait. Without this escape hatch the bounded
    /// no-unlock sends hold the renderer mutex through every full-queue
    /// retry, while the consumers that would drain the queues (termio
    /// thread, app thread) need that same mutex — a livelock that starves
    /// the main thread indefinitely and ends in a 0x8BADF00D watchdog kill.
    /// Set/reset under both mutexes. The liveness sends MUST clear it before
    /// releasing the locks and restore it after reacquiring: it is shared
    /// handler state, and another tmux_mutex holder seeing it set would
    /// unlock a renderer mutex it does not own.
    tmux_renderer_held: bool = false,

    /// ROOTSHELL-TMUX (id=streamhandler-parse-liveness): pointer to
    /// `Termio.tmux_mutex` so the send helpers can release/reacquire it on
    /// the liveness path. Assigned per-chunk by `Termio.processOutput`
    /// alongside `tmux_renderer_held`.
    tmux_mutex: ?*std.Io.Mutex = null,

    /// ROOTSHELL-TMUX (id=streamhandler-unlocked-io): fork-only analog of
    /// `termio_messaged` for sends made on the unlocked control-mode path.
    /// Atomic because it is set under tmux_mutex but consumed (swap) by
    /// `Termio.processOutputTmuxPrefix` which then notifies the mailbox after
    /// unlocking. Upstream's `termio_messaged` field and its call sites stay
    /// byte-identical.
    tmux_termio_messaged: std.atomic.Value(bool) = .init(false),

    /// ROOTSHELL-TMUX (id=streamhandler-unlocked-io): a tmux topology
    /// snapshot (possibly the non-rederivable empty teardown snapshot) was
    /// dropped under app-mailbox backpressure; `tmuxFlushDeferred` re-sends
    /// it. Accessed only under tmux_mutex.
    tmux_topology_retry: bool = false,

    /// ROOTSHELL-TMUX (id=streamhandler-post-exit-drain): armed ONLY by
    /// `tmuxForceExit` (never on a clean `%exit`). While set, inbound bytes are
    /// discarded up to the real `%exit` + ST boundary (bounded by budget and
    /// deadline) so a swallowed control-mode backlog that floods in after the
    /// force-exit teardown doesn't paint raw protocol garbage into the revealed
    /// shell. Accessed only under tmux_mutex.
    tmux_post_exit_drain: if (tmux_enabled) ?terminal.tmux.ExitDrain else void =
        if (tmux_enabled) null else {},

    /// This is set to true when we've seen a title escape sequence. We use
    /// this to determine if we need to default the window title.
    seen_title: bool = false,

    pub const Stream = terminal.Stream(StreamHandler);

    /// True if we have tmux control mode built in.
    pub const tmux_enabled = terminal.options.tmux_control_mode;

    pub fn deinit(self: *StreamHandler) void {
        self.apc.deinit();
        self.dcs.deinit();
        if (comptime tmux_enabled) tmux: { // ROOTSHELL-TMUX (id=streamhandler-deinit-viewer): tear down viewer on handler deinit
            const viewer = self.tmux_viewer orelse break :tmux;
            viewer.deinit();
            self.alloc.destroy(viewer);
            self.tmux_viewer = null;
            self.tmux_active_flag.store(false, .monotonic); // ROOTSHELL-TMUX (id=streamhandler-tmux-active-flag)
        }
    }

    /// This queues a render operation with the renderer thread. The render
    /// isn't guaranteed to happen immediately but it will happen as soon as
    /// practical.
    pub inline fn queueRender(self: *StreamHandler) !void {
        try self.renderer_wakeup.notify();
    }

    /// Change the configuration for this handler.
    pub fn changeConfig(self: *StreamHandler, config: *termio.DerivedConfig) void {
        self.osc_color_report_format = config.osc_color_report_format;
        self.clipboard_write = config.clipboard_write;
        self.enquiry_response = config.enquiry_response;
        // Cache the resolved theme so we can answer the color-scheme query
        // inline (id=streamhandler-inline-reports). Must run before the
        // color-scheme report emitted at the end of this function.
        self.color_scheme_is_dark = config.conditional_state.theme == .dark;
        // If tmux control mode was just disabled and a viewer is active,
        // proactively tear down the viewer and close child surfaces so
        // they don't leak until the tmux server sends an exit.
        if (comptime tmux_enabled) { // ROOTSHELL-TMUX (id=streamhandler-changeconfig-disable): tear down viewer if tmux disabled at runtime
            if (self.tmux_control_mode and !config.tmux_control_mode) {
                // See id=streamhandler-resume-pending-clear.
                self.tmux_resume_pending = false;
                self.tmux_resume_preferred_window = null;
                if (self.tmux_viewer) |viewer| {
                    self.sendEmptyTopologySnapshot();
                    viewer.deinit();
                    self.alloc.destroy(viewer);
                    self.tmux_viewer = null;
                    self.tmux_active_flag.store(false, .monotonic); // ROOTSHELL-TMUX (id=streamhandler-tmux-active-flag)
                }
            }
        }
        self.tmux_control_mode = config.tmux_control_mode;
        // A config reload may have changed the theme; refresh the tmux viewer's
        // colors (background/foreground/cursor + ANSI palette) so existing pane
        // terminals re-render with the new theme and OSC 10/11 color queries
        // answer correctly. Read from `config` directly because
        // Termio.changeConfig updates `self.terminal.colors` only AFTER this
        // handler returns.
        if (comptime tmux_enabled) { // ROOTSHELL-TMUX (id=streamhandler-changeconfig-colors): re-report pane colors on theme change
            if (self.tmux_viewer) |viewer| {
                // Resolve the cursor color exactly as Termio.changeConfig does
                // (config.cursor_color is optional, and so is its RGB form).
                const cursor: ?terminal.color.RGB = cursor: {
                    const cc = config.cursor_color orelse break :cursor null;
                    break :cursor cc.toTerminalRGB() orelse break :cursor null;
                };
                viewer.updateColors(
                    config.foreground.toTerminalRGB(),
                    config.background.toTerminalRGB(),
                    cursor,
                    config.palette,
                );
                // Flush the queued color reports now (the queue may be idle).
                self.pumpTmuxCommandQueue(viewer);
                // Push the cursor style/blink to existing panes too.
                // ROOTSHELL-TMUX (id=viewer-cursor-style-default)
                viewer.updateCursorDefaults(
                    config.cursor_style,
                    config.cursor_blink,
                );
            }
        }
        self.terminal.setDefaultCursorStyle(config.cursor_style);
        self.terminal.setDefaultCursorBlink(config.cursor_blink);

        // The config could have changed any of our colors so update mode 2031.
        // (suppress-gateway + mode check live inside sendColorSchemeReport)
        self.sendColorSchemeReport(false);
    }

    /// ROOTSHELL-TMUX (id=streamhandler-parse-liveness): whether an
    /// unlocked-io send may fall back to the upstream release-and-wait slow
    /// path on a full queue: the ordinary-surface parse holds the renderer
    /// mutex and the control channel is not hooked, so no tmux state is in
    /// flight and hook state cannot change while we wait (only this thread
    /// hooks). Releasing both mutexes (relocked in renderer -> tmux order)
    /// lets the termio and app threads drain the queues, which the bounded
    /// no-unlock retries can never achieve — those consumers need the
    /// renderer mutex we'd be holding.
    inline fn tmuxParseMayUnlock(self: *const StreamHandler) bool {
        if (comptime !tmux_enabled) return false;
        return self.tmux_renderer_held and !self.tmuxControlHooked();
    }

    inline fn surfaceMessageWriter(
        self: *StreamHandler,
        msg: apprt.surface.Message,
    ) void {
        // ROOTSHELL-TMUX (id=streamhandler-unlocked-io): on the unlocked
        // control-mode path the renderer mutex is NOT held, so the
        // unlock/relock slow path below would be UB. Use bounded timed
        // retries instead; on sustained backpressure free the message and
        // drop it (topology snapshots are re-derivable from the viewer and
        // query responses are backstopped by the app-side timeout).
        if (comptime tmux_enabled) {
            if (self.tmux_unlocked_io) {
                self.tmuxDbgReadSite(.surface_mailbox_send, 0);
                defer self.tmuxDbgReadSite(.parsing, 0);
                if (self.surface_mailbox.push(msg, .{ .instant = {} }) > 0) return;
                // ROOTSHELL-TMUX (id=streamhandler-parse-liveness): full
                // queue on the not-hooked renderer-held parse — release
                // both mutexes and wait for the app thread to drain, like
                // upstream. No drops, no renderer-held stall.
                if (self.tmuxParseMayUnlock()) {
                    const tmux_mutex = self.tmux_mutex.?;
                    // Clear the ownership marker before releasing: it is
                    // shared handler state, and another tmux_mutex holder
                    // (io-thread arms run unlocked-io sends too) must not
                    // satisfy tmuxParseMayUnlock() and unlock a renderer
                    // mutex it does not hold while we wait.
                    self.tmux_renderer_held = false;
                    tmux_mutex.unlock(global.io());
                    self.renderer_state.mutex.unlock(global.io());
                    _ = self.surface_mailbox.push(msg, .{ .forever = {} });
                    self.renderer_state.mutex.lockUncancelable(global.io());
                    tmux_mutex.lockUncancelable(global.io());
                    // Another tmux_mutex holder (e.g. the termio thread's
                    // tmux_reset arm) toggles tmux_unlocked_io around its
                    // own work; we are still inside the unlocked-io parse
                    // with both locks held again, so reassert both flags.
                    self.tmux_unlocked_io = true;
                    self.tmux_renderer_held = true;
                    return;
                }
                var attempts: usize = 0;
                while (attempts < 50) : (attempts += 1) {
                    if (self.surface_mailbox.push(
                        msg,
                        .{ .ns = 2 * std.time.ns_per_ms },
                    ) > 0) return;
                }
                log.warn(
                    "dropping surface message after sustained backpressure tag={s}",
                    .{@tagName(msg)},
                );
                self.dropSurfaceMessage(msg);
                return;
            }
        }

        // See messageWriter which has similar logic and explains why
        // we may have to do this.
        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            self.renderer_state.mutex.unlock(global.io());
            defer self.renderer_state.mutex.lockUncancelable(global.io());
            _ = self.surface_mailbox.push(msg, .{ .forever = {} });
        }
    }

    /// Free the heap-carrying payload of a surface message we are dropping
    /// instead of delivering (bounded-backpressure path above). Only the
    /// tmux message kinds can reach the drop path; value-type messages need
    /// no cleanup. A dropped TOPOLOGY snapshot is not always re-derivable
    /// later (the empty teardown snapshot's viewer is gone immediately
    /// after), so flag a retry; the heartbeat-driven `tmuxFlushDeferred`
    /// re-sends it. ROOTSHELL-TMUX (id=streamhandler-unlocked-io)
    fn dropSurfaceMessage(self: *StreamHandler, msg: apprt.surface.Message) void {
        switch (msg) {
            // Pointer payloads own heap memory (and topology snapshots hold
            // pane refs that MUST be released or panes leak forever).
            .tmux_topology_changed => |snapshot| {
                snapshot.deinit();
                if (comptime tmux_enabled) self.tmux_topology_retry = true;
            },
            .tmux_command_response => |resp| resp.deinit(),
            // The viewer dedupes repeat titles; a dropped one must be
            // re-sendable on the next event. (id=viewer-title-dedupe)
            .tmux_title_changed => |tc| if (comptime tmux_enabled) {
                if (tc.tmux_window_id) |window_id| {
                    if (self.tmux_viewer) |viewer| viewer.forgetEmittedTitle(window_id);
                }
            },
            // Ordinary messages reach the bounded drop path too (the
            // unhooked parse also runs with the flag set): WriteReq payloads
            // may be `.alloc` and own heap memory (OSC 52 clipboard writes,
            // OSC 7 pwd changes, tmux write relays).
            .clipboard_write => |v| v.req.deinit(),
            .pwd_change => |req| req.deinit(),
            .tmux_write_command => |req| req.deinit(),
            else => {},
        }
    }

    /// Retry work deferred by the unlocked control-mode path: pane writes
    /// deferred by bounded renderer-lock timeouts, and a topology snapshot
    /// dropped under app-mailbox backpressure. Driven by the app's heartbeat
    /// (idle-session nudge) via the `.tmux_flush_deferred` message; also safe
    /// to call any time on the IO thread under tmux_mutex. Idempotent and
    /// cheap when nothing is deferred. ROOTSHELL-TMUX
    /// (id=termio-msg-flush-deferred)
    pub fn tmuxFlushDeferred(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;

        if (self.tmux_topology_retry) {
            self.tmux_topology_retry = false;
            if (self.tmux_viewer) |viewer| {
                // Viewer alive: the authoritative topology lives in tmux —
                // re-derive (and re-emit) it via a queued list-windows.
                viewer.queueTopologyRefresh() catch |err| {
                    log.warn("failed to queue topology refresh err={}", .{err});
                    self.tmux_topology_retry = true;
                };
            } else {
                // Viewer gone (teardown snapshot was the one dropped):
                // re-send the empty snapshot so the app prunes the orphaned
                // tabs. A re-drop re-sets the flag for the next nudge.
                self.sendEmptyTopologySnapshot();
            }
        }

        if (self.tmux_viewer) |viewer| {
            // Collect deferred OSC 52 clipboard writes so we deliver them NOW: on
            // an idle session this nudge is the only path that flushes deferred
            // pane work, and without delivery a pane's clipboard SET buffered in
            // deferred output would strand (or land late on a later unrelated
            // %output). The action payloads live on the viewer's action arena
            // (valid until the next `next()`); we forward them to the surface
            // mailbox immediately below, which copies the bytes into a WriteReq.
            // The list backing is arena-allocated by flushPaneClipboard, so it
            // needs no separate deinit. ROOTSHELL-TMUX
            // (id=streamhandler-flush-deferred-clipboard)
            var clip_actions: std.ArrayList(terminal.tmux.Viewer.Action) = .empty;
            viewer.flushAllDeferredPanes(&clip_actions, 2 * std.time.ns_per_ms);
            for (clip_actions.items) |action| {
                const cw = switch (action) {
                    .pane_clipboard_write => |w| w,
                    else => continue,
                };
                const clipboard_type: apprt.Clipboard = switch (cw.kind) {
                    'c' => .standard,
                    's' => .selection,
                    'p' => .primary,
                    else => .standard,
                };
                const req = apprt.surface.Message.WriteReq.init(self.alloc, cw.data) catch |err| {
                    log.warn("failed to allocate deferred tmux clipboard write req err={}", .{err});
                    continue;
                };
                self.surfaceMessageWriter(.{ .clipboard_write = .{
                    .req = req,
                    .clipboard_type = clipboard_type,
                } });
            }
            // The flush (and the topology retry above) may have QUEUED
            // commands (pane_visible re-fetches, buffered pane responses,
            // list-windows); the queue is pull-based, so on an idle session
            // nothing else would ever send them. Pump exactly once at the
            // end so everything queued here goes out now.
            // ROOTSHELL-TMUX (id=termio-msg-flush-deferred)
            self.pumpTmuxCommandQueue(viewer);
        }
    }

    /// Send an empty topology snapshot so the reconciler prunes all tmux
    /// windows/panes. Used by both the DCS unhook (.exit) path and the
    /// viewer defunct (.exit action) path.
    fn sendEmptyTopologySnapshot(self: *StreamHandler) void {
        if (apprt.surface.Message.TmuxTopologySnapshot.initFromWindows(
            self.alloc,
            &.{},
            null,
            null,
        )) |snapshot| {
            self.surfaceMessageWriter(.{ .tmux_topology_changed = snapshot });
        } else |err| {
            log.warn("failed to create exit topology snapshot: {}", .{err});
        }
    }

    /// Tear down the active tmux control-mode viewer: prune all child pane
    /// surfaces (empty topology snapshot so the reconciler closes them), free
    /// the viewer, and clear the cross-thread active flag. Shared by the `%exit`
    /// and `.broken` control-stream paths so a malformed stream recovers exactly
    /// like a clean exit instead of orphaning child tabs and leaving the gateway
    /// stuck-active. No-op when there is no viewer. ROOTSHELL-TMUX
    /// (id=streamhandler-tmux-teardown)
    fn tmuxTeardownViewer(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        // A resume that was pending when the viewer died is no longer valid:
        // left set, it would flip the NEXT real control-mode entry (a fresh
        // `tmux -CC attach`) into resync and drain its clean startup
        // handshake as stale bytes. ROOTSHELL-TMUX (id=streamhandler-resume-pending-clear)
        self.tmux_resume_pending = false;
        self.tmux_resume_preferred_window = null;
        const viewer = self.tmux_viewer orelse return;
        // Error pending app queries back before the queue dies with the
        // viewer. ROOTSHELL-TMUX (id=streamhandler-query-command)
        self.failPendingTmuxQueries(viewer);
        // Prune all tmux windows/panes so child surfaces are closed.
        self.sendEmptyTopologySnapshot();
        viewer.deinit();
        self.alloc.destroy(viewer);
        self.tmux_viewer = null;
        self.tmux_active_flag.store(false, .monotonic); // ROOTSHELL-TMUX (id=streamhandler-tmux-active-flag)
    }

    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        _ = self.messageWriterChecked(msg);
    }

    /// Like `messageWriter` but reports whether the message was actually
    /// queued. Callers whose correctness depends on delivery (tracked tmux
    /// commands — a drop must roll back the viewer's in-flight state) use
    /// this; fire-and-forget callers use `messageWriter`.
    /// ROOTSHELL-TMUX (id=streamhandler-unlocked-io)
    inline fn messageWriterChecked(self: *StreamHandler, msg: termio.Message) bool {
        // ROOTSHELL-TMUX (id=streamhandler-unlocked-io): on the unlocked
        // control-mode path the renderer mutex is NOT held, so Mailbox.send's
        // unlock/relock slow path would be UB. sendBounded does the bounded
        // retry without any mutex and reports drops. The wake flag goes to the
        // fork-only atomic (consumed by Termio.processOutputTmuxPrefix after
        // unlocking) so upstream's `termio_messaged` sites stay untouched.
        if (comptime tmux_enabled) {
            if (self.tmux_unlocked_io) {
                self.tmuxDbgReadSite(.mailbox_send, 0);
                defer self.tmuxDbgReadSite(.parsing, 0);
                // ROOTSHELL-TMUX (id=streamhandler-parse-liveness): on the
                // not-hooked renderer-held parse, use the upstream send
                // (instant fast path; on a full queue it releases the
                // renderer mutex around its wait so the termio thread can
                // drain). Release tmux_mutex across the call so the wait
                // never holds it; send relocks renderer before returning
                // and tmux is relocked after, preserving the lock order.
                if (self.tmuxParseMayUnlock()) {
                    const tmux_mutex = self.tmux_mutex.?;
                    // Clear the ownership marker before releasing: it is
                    // shared handler state, and another tmux_mutex holder
                    // (io-thread arms run unlocked-io sends too) must not
                    // satisfy tmuxParseMayUnlock() and unlock a renderer
                    // mutex it does not hold while we wait.
                    self.tmux_renderer_held = false;
                    tmux_mutex.unlock(global.io());
                    self.termio_mailbox.send(msg, self.renderer_state.mutex);
                    tmux_mutex.lockUncancelable(global.io());
                    // Another tmux_mutex holder (e.g. the termio thread's
                    // tmux_reset arm) toggles tmux_unlocked_io around its
                    // own work; we are still inside the unlocked-io parse
                    // with both locks held again, so reassert both flags.
                    self.tmux_unlocked_io = true;
                    self.tmux_renderer_held = true;
                    self.tmux_termio_messaged.store(true, .monotonic);
                    return true;
                }
                const ok = self.termio_mailbox.sendBounded(msg);
                if (ok) self.tmux_termio_messaged.store(true, .monotonic);
                return ok;
            }
        }
        // Upstream path: send() has its own bounded drop but doesn't report
        // it; that exposure predates the fork and is unchanged here.
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
        self.termio_messaged = true;
        return true;
    }

    /// Whether the tmux control channel is hooked on this surface (the DCS
    /// handler routes every byte to the control parser). Callers must hold
    /// `Termio.tmux_mutex`. ROOTSHELL-TMUX (id=termio-tmux-process-output)
    pub inline fn tmuxControlHooked(self: *const StreamHandler) bool {
        if (comptime !tmux_enabled) return false;
        return self.dcs.state == .tmux;
    }

    /// Feed `buf` through the post-force-exit drain if one is armed,
    /// returning the suffix that must be processed normally (the whole `buf`
    /// when no drain is active). Caller must hold `Termio.tmux_mutex`.
    /// ROOTSHELL-TMUX (id=streamhandler-post-exit-drain)
    pub fn tmuxPostExitDrainFeed(self: *StreamHandler, buf: []const u8) []const u8 {
        if (comptime !tmux_enabled) return buf;
        const drain = if (self.tmux_post_exit_drain) |*d| d else return buf;
        const consumed = drain.feed(buf, nowMs());
        if (drain.isDone()) {
            log.info(
                "tmux post-exit drain finished (consumed {} trailing bytes)",
                .{consumed},
            );
            self.tmux_post_exit_drain = null;
        }
        return buf[consumed..];
    }

    // ROOTSHELL-TMUX (id=tmux-debug-read-progress): read-thread progress
    // stamps. Written directly at the byte sites (NOT via refreshTmuxDebug —
    // a blocked read thread never reaches the event-site refresh, which is
    // the exact case these diagnose). All no-ops until the gateway's debug
    // mirror is enabled, so non-gateway surfaces pay one relaxed load.

    pub inline fn tmuxDbgReadEnter(self: *StreamHandler, len: usize) void {
        if (comptime !tmux_enabled) return;
        const m = &self.tmux_debug;
        if (!m.enabled.load(.monotonic)) return;
        _ = m.read_enter_bytes.fetchAdd(len, .monotonic);
        m.read_enter_ms.store(nowMs(), .monotonic);
    }

    pub inline fn tmuxDbgReadDone(self: *StreamHandler, len: usize) void {
        if (comptime !tmux_enabled) return;
        const m = &self.tmux_debug;
        if (!m.enabled.load(.monotonic)) return;
        _ = m.read_done_bytes.fetchAdd(len, .monotonic);
        m.read_done_ms.store(nowMs(), .monotonic);
        m.read_site.store(@intFromEnum(TmuxReadSite.idle), .monotonic);
        m.read_site_pane.store(0, .monotonic);
    }

    pub inline fn tmuxDbgReadSite(
        self: *StreamHandler,
        site: TmuxReadSite,
        pane_id: u32,
    ) void {
        if (comptime !tmux_enabled) return;
        const m = &self.tmux_debug;
        if (!m.enabled.load(.monotonic)) return;
        m.read_site.store(@intFromEnum(site), .monotonic);
        m.read_site_pane.store(pane_id, .monotonic);
    }

    // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): iTerm2-style report suppression while this surface is the tmux control-mode gateway.
    inline fn suppressPtyReportForTmuxGateway(
        self: *StreamHandler,
        comptime label: []const u8,
    ) bool {
        if (comptime !tmux_enabled) return false;
        if (self.tmux_viewer == null) return false;
        log.debug("suppressing {s} report on tmux control-mode gateway", .{label});
        return true;
    }

    /// Send a renderer message and unlock the renderer state mutex
    /// if necessary to ensure we don't deadlock.
    ///
    /// This assumes the renderer state mutex is locked.
    inline fn rendererMessageWriter(
        self: *StreamHandler,
        msg: renderer.Message,
    ) void {
        // See termio.Mailbox.send for more details on how this works.

        // Try instant first. If it works then we can return.
        if (self.renderer_mailbox.push(msg, .{ .instant = {} }) > 0) {
            return;
        }

        // ROOTSHELL-TMUX (id=streamhandler-unlocked-io): while tmux_mutex is
        // held we must NOT unlock/relock the renderer mutex (lock-order
        // violation / UB — see tmux_unlocked_io). Bounded timed retries, then
        // drop: renderer messages are repaint hints and lossy-tolerant.
        if (comptime tmux_enabled) {
            if (self.tmux_unlocked_io) {
                // ROOTSHELL-TMUX (id=streamhandler-parse-liveness): on the
                // not-hooked renderer-held parse, mirror the upstream slow
                // path below but release tmux_mutex too (relocked renderer
                // first, then tmux — lock order preserved).
                if (self.tmuxParseMayUnlock()) {
                    const tmux_mutex = self.tmux_mutex.?;
                    // Clear the ownership marker before releasing: it is
                    // shared handler state, and another tmux_mutex holder
                    // (io-thread arms run unlocked-io sends too) must not
                    // satisfy tmuxParseMayUnlock() and unlock a renderer
                    // mutex it does not hold while we wait.
                    self.tmux_renderer_held = false;
                    tmux_mutex.unlock(global.io());
                    self.renderer_state.mutex.unlock(global.io());
                    self.renderer_wakeup.notify() catch |err| {
                        log.warn(
                            "failed to notify renderer, may deadlock err={}",
                            .{err},
                        );
                    };
                    _ = self.renderer_mailbox.push(msg, .{ .forever = {} });
                    self.renderer_state.mutex.lockUncancelable(global.io());
                    tmux_mutex.lockUncancelable(global.io());
                    // Another tmux_mutex holder (e.g. the termio thread's
                    // tmux_reset arm) toggles tmux_unlocked_io around its
                    // own work; we are still inside the unlocked-io parse
                    // with both locks held again, so reassert both flags.
                    self.tmux_unlocked_io = true;
                    self.tmux_renderer_held = true;
                    return;
                }
                self.renderer_wakeup.notify() catch {};
                var attempts: usize = 0;
                while (attempts < 50) : (attempts += 1) {
                    if (self.renderer_mailbox.push(
                        msg,
                        .{ .ns = 2 * std.time.ns_per_ms },
                    ) > 0) return;
                }
                log.warn(
                    "dropping renderer message under tmux lock backpressure tag={s}",
                    .{@tagName(msg)},
                );
                return;
            }
        }

        // Instant would have blocked. Release the renderer mutex,
        // wake up the renderer to allow it to process the message,
        // and then try again.
        self.renderer_state.mutex.unlock(global.io());
        defer self.renderer_state.mutex.lockUncancelable(global.io());
        self.renderer_wakeup.notify() catch |err| {
            // This is an EXTREMELY unlikely case. We still don't return
            // and attempt to send the message because its most likely
            // that everything is fine, but log in case a freeze happens.
            log.warn(
                "failed to notify renderer, may deadlock err={}",
                .{err},
            );
        };
        _ = self.renderer_mailbox.push(msg, .{ .forever = {} });
    }

    pub fn vt(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| {
            log.warn("error handling VT action action={} err={}", .{ action, err });
        };
    }

    inline fn vtFallible(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) !void {
        // The branch hints here are based on real world data
        // which indicates that the most common actions are:
        //
        // 1. print
        // 2. set_attribute
        // 3. carriage_return
        // 4. line_feed
        // 5. cursor_pos
        //
        // Together, these 5 actions make up nearly 98% of
        // all actions encountered in real world scenarios.
        //
        // ref: https://github.com/qwerasd205/asciinema-stats
        switch (action) {
            .print => {
                @branchHint(.likely);
                try self.terminal.print(value.cp);
            },
            .print_slice => {
                @branchHint(.likely);
                try self.terminal.printSlice(value.cps);
            },
            .print_repeat => try self.terminal.printRepeat(value),
            .bell => self.bell(),
            .backspace => self.terminal.backspace(),
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .linefeed => {
                @branchHint(.likely);
                try self.linefeed();
            },
            .carriage_return => {
                @branchHint(.likely);
                self.terminal.carriageReturn();
            },
            .enquiry => try self.enquiry(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => {
                @branchHint(.likely);
                self.terminal.setCursorPos(value.row, value.col);
            },
            .cursor_col => self.terminal.setCursorPos(self.terminal.screens.active.cursor.y + 1, value.value),
            .cursor_row => self.terminal.setCursorPos(value.value, self.terminal.screens.active.cursor.x + 1),
            .cursor_col_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1,
                self.terminal.screens.active.cursor.x + 1 +| value.value,
            ),
            .cursor_row_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1 +| value.value,
                self.terminal.screens.active.cursor.x + 1,
            ),
            .cursor_style => self.terminal.setCursorStyle(value),
            .erase_display_below => self.terminal.eraseDisplay(.below, value),
            .erase_display_above => self.terminal.eraseDisplay(.above, value),
            .erase_display_complete => {
                self.terminal.scrollViewport(.{ .bottom = {} });
                self.renderer_state.smooth_scroll_y_px = 0;
                self.renderer_state.smooth_scroll_active = false;
                self.terminal.eraseDisplay(.complete, value);
            },
            .erase_display_scrollback => self.terminal.eraseDisplay(.scrollback, value),
            .erase_display_scroll_complete => self.terminal.eraseDisplay(.scroll_complete, value),
            .erase_line_right => self.terminal.eraseLine(.right, value),
            .erase_line_left => self.terminal.eraseLine(.left, value),
            .erase_line_complete => self.terminal.eraseLine(.complete, value),
            .erase_line_right_unless_pending_wrap => self.terminal.eraseLine(.right_unless_pending_wrap, value),
            .delete_chars => self.terminal.deleteChars(value),
            .erase_chars => self.terminal.eraseChars(value),
            .insert_lines => self.terminal.insertLines(value),
            .insert_blanks => self.terminal.insertBlanks(value),
            .delete_lines => self.terminal.deleteLines(value),
            .scroll_up => try self.terminal.scrollUp(value),
            .scroll_down => self.terminal.scrollDown(value),
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .index => try self.index(),
            .next_line => try self.nextLine(),
            .reverse_index => try self.reverseIndex(),
            .full_reset => try self.fullReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                // For restore mode we have to restore but if we set it, we
                // always have to call setMode because setting some modes have
                // side effects and we want to make sure we process those.
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .request_mode => try self.requestMode(value.mode),
            .request_mode_unknown => try self.requestModeUnknown(value.mode, value.ansi),
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => try self.saveCursor(),
            .restore_cursor => try self.restoreCursor(),
            .modify_key_format => try self.setModifyKeyFormat(value),
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .size_report => self.sendSizeReport(value),
            .xtversion => try self.reportXtversion(),
            .device_attributes => try self.deviceAttributes(value),
            .device_status => try self.deviceStatusReport(value.request),
            .kitty_keyboard_query => try self.queryKittyKeyboard(),
            .kitty_keyboard_push => {
                log.debug("pushing kitty keyboard mode: {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.push(value.flags);
            },
            .kitty_keyboard_pop => {
                log.debug("popping kitty keyboard mode n={}", .{value});
                self.terminal.screens.active.kitty_keyboard.pop(@intCast(value));
            },
            .kitty_keyboard_set => {
                log.debug("setting kitty keyboard mode: set {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.set, value.flags);
            },
            .kitty_keyboard_set_or => {
                log.debug("setting kitty keyboard mode: or {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags);
            },
            .kitty_keyboard_set_not => {
                log.debug("setting kitty keyboard mode: not {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.not, value.flags);
            },
            .kitty_color_report => try self.kittyColorReport(value),
            .color_operation => try self.colorOperation(value.op, &value.requests, value.terminator),
            .end_hyperlink => try self.endHyperlink(),
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.decaln(),
            .window_title => try self.windowTitle(value.title),
            .report_pwd => try self.reportPwd(value.url),
            .show_desktop_notification => try self.showDesktopNotification(value.title, value.body),
            .progress_report => self.progressReport(value),
            .start_hyperlink => try self.startHyperlink(value.uri, value.id),
            .clipboard_contents => try self.clipboardContents(value.kind, value.data),
            .iterm2_image => self.terminal.iterm2Image(self.alloc, value),
            .semantic_prompt => try self.semanticPrompt(value),
            .mouse_shape => try self.setMouseShape(value),
            .configure_charset => self.configureCharset(value.slot, value.charset),
            .set_attribute => {
                @branchHint(.likely);
                switch (value) {
                    .unknown => |unk| {
                        // We optimize for the happy path scenario here, since
                        // unknown/invalid SGRs aren't that common in the wild.
                        @branchHint(.unlikely);
                        log.warn("unimplemented or unknown SGR attribute: {any}", .{unk});
                    },
                    else => {
                        @branchHint(.likely);
                        self.terminal.setAttribute(value) catch |err| {
                            @branchHint(.cold);
                            log.warn("error setting attribute {}: {}", .{ value, err });
                        };
                    },
                }
            },
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .apc_start => self.apc.start(),
            .apc_end => try self.apcEnd(),
            .apc_put => self.apc.feed(self.alloc, value),
            .apc_put_slice => self.apc.feedSlice(self.alloc, value.bytes),

            // Unimplemented
            .title_push,
            .title_pop,
            .kitty_clipboard,
            => {},
        }
    }

    /// Set the tmux control-mode client size and push it to tmux so the active
    /// window's panes are laid out to the visible tab's grid. Called on the IO
    /// thread (via the `tmux_set_client_size` mailbox message), so it can touch
    /// the viewer's command queue safely.
    pub fn tmuxSetClientSize(self: *StreamHandler, cols: u16, rows: u16) void { // ROOTSHELL-TMUX (id=streamhandler-set-client-size)
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;

        // Store the size; if we're mid command-queue this also queues an
        // in-order, response-matched client_size command, and the startup
        // sequence (`tryFinishStartup`) sends the stored size as a tracked
        // command.
        //
        // We must NOT direct-send a raw `refresh-client` here. The viewer
        // matches command-response blocks to queued commands by blind FIFO (no
        // command id), so any command whose response is not represented in the
        // queue shifts every subsequent match by one — over SSH/tssh a stray
        // resize response landed DURING the per-pane capture-pane sequence,
        // stranding a pane on its (scrollback-less) alternate screen. The
        // tracked client_size command queued above avoids that. But the queue
        // is pull-based — it only sends the next command when an inbound tmux
        // notification arrives — so on an idle session (a shell prompt with no
        // output) the resize would sit unsent and the window never relays out.
        // `pumpTmuxCommandQueue` flushes it now, in order, without desyncing
        // the FIFO.
        viewer.setClientSize(@intCast(cols), @intCast(rows));
        self.pumpTmuxCommandQueue(viewer);
    }

    /// Flush a queued-but-unsent head command to tmux. The viewer's command
    /// pump is pull-based (it sends the next queued command only when an inbound
    /// tmux notification arrives in `Viewer.next`). Commands queued out of that
    /// flow — `setClientSize` (resize), `queueUserCommand` (relayed pane
    /// resize/select), `updateColors` — would otherwise wait for the next
    /// notification, which never comes on an idle session. Call this right after
    /// such an enqueue so the command, most importantly a `refresh-client -C`
    /// resize, reaches tmux immediately. `takePendingCommand` returns the head
    /// only when nothing is in flight, so the response FIFO stays in order.
    fn pumpTmuxCommandQueue(self: *StreamHandler, viewer: *terminal.tmux.Viewer) void { // ROOTSHELL-TMUX (id=streamhandler-pump-command-queue)
        if (comptime !tmux_enabled) return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const cmd = (viewer.takePendingCommand(arena.allocator()) catch {
            log.warn("failed to format pending tmux command", .{});
            return;
        }) orelse return;
        // takePendingCommand marked the command in-flight; if we fail to actually
        // hand it to the pty, roll that back so the pump retries instead of
        // wedging with command_in_flight stuck true and no response coming.
        if (!self.writeTrackedTmuxCommand(cmd)) viewer.rollbackInFlightCommand();
    }

    /// Write a tracked tmux command (the viewer's own commands) to the pty via a
    /// `.tmux_track_command` message rather than a raw `.write_*`. The IO thread
    /// records a `.tracked` marker in the viewer's sent-FIFO at the drain point
    /// (just before writing, under tmux_mutex — see Thread
    /// id=thread-tmux-write-record-atomic), so the marker order matches the
    /// actual pty write order (which the SPSC mailbox can reorder relative to
    /// the viewer enqueue order — that's why recording must happen at the drain
    /// point, not here). `cmd` is copied. ROOTSHELL-TMUX
    /// (id=streamhandler-write-tracked-command)
    fn writeTrackedTmuxCommand(self: *StreamHandler, cmd: []const u8) bool {
        const copy = self.alloc.dupe(u8, cmd) catch {
            log.warn("failed to dupe tracked tmux command", .{});
            return false;
        };
        // Checked send: a drop under mailbox backpressure must report false
        // so the caller rolls back command_in_flight — otherwise the viewer
        // waits forever for a %begin/%end that can never come.
        // ROOTSHELL-TMUX (id=streamhandler-unlocked-io)
        return self.messageWriterChecked(.{ .tmux_track_command = .{
            .alloc = self.alloc,
            .data = copy,
        } });
    }

    /// Record (on the IO thread, at the drain/write point) that a tracked tmux
    /// command was just written. ROOTSHELL-TMUX (id=streamhandler-record-tracked)
    pub fn recordTmuxTrackedSend(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        viewer.recordTrackedSend();
        self.tmuxDebugNoteCommandsSent(1); // ROOTSHELL-TMUX (id=tmux-debug-mirror)
    }

    /// Record (on the IO thread, at the drain/write point) that `n` untracked
    /// `send-keys` command lines were just written. A batched write carries
    /// several `\n`-terminated lines in one message and tmux acks each line
    /// with its own `%begin/%end` block, so one marker per line keeps the
    /// sent-FIFO aligned. ROOTSHELL-TMUX (id=streamhandler-record-untracked)
    pub fn recordTmuxUntrackedSend(self: *StreamHandler, n: usize) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        viewer.recordUntrackedSends(n);
        self.tmuxDebugNoteCommandsSent(n); // ROOTSHELL-TMUX (id=tmux-debug-mirror)
    }

    /// Stamp "commands were just written to tmux" into the debug mirror, then
    /// refresh so the in-flight/FIFO depth reflects the send. No-op until the app
    /// opts in. ROOTSHELL-TMUX (id=tmux-debug-mirror)
    fn tmuxDebugNoteCommandsSent(self: *StreamHandler, n: usize) void {
        if (comptime !tmux_enabled) return;
        const m = &self.tmux_debug;
        if (m.enabled.load(.monotonic)) {
            m.last_command_ms.store(nowMs(), .monotonic);
            _ = m.total_commands_sent.fetchAdd(n, .monotonic);
        }
        self.refreshTmuxDebug();
    }

    /// Detach this tmux control-mode client. Queues a `detach-client` through the
    /// viewer's command queue (in FIFO order with the viewer's own commands, NOT
    /// a raw write that desyncs the response FIFO) and flushes it. tmux detaches
    /// the control client and replies %exit, which makes the viewer defunct and
    /// tears down control mode; the `tmux -CC` process then exits and the gateway
    /// returns to its shell. The tmux server/session stays alive. No-op when no
    /// viewer is active.
    /// Whether this surface is currently a live tmux control-mode gateway (the
    /// DCS control channel is hooked and a viewer exists). Read cross-thread from
    /// the app thread by `ghostty_surface_tmux_active` as a best-effort ESC
    /// escape-hatch hint; a slightly-stale value only means one ESC press may be a
    /// no-op during a teardown transition. ROOTSHELL-TMUX
    /// (id=streamhandler-tmux-active)
    pub fn tmuxActive(self: *const StreamHandler) bool {
        if (comptime !tmux_enabled) return false;
        // Atomic load — NOT `self.tmux_viewer != null`. This runs on the app
        // thread while the IO thread may be freeing the viewer; reading the
        // pointer would be a data race. The flag is stored next to every viewer
        // mutation on the IO thread.
        return self.tmux_active_flag.load(.monotonic);
    }

    /// Enable + prime the tmux debug mirror when a viewer is created. The mirror
    /// runs for the gateway's whole lifetime (NOT only after the app opts into
    /// logging) so a snapshot taken after the user hits a hang and THEN enables
    /// logging still reflects real state — the diagnostic's whole point. Cost is
    /// bounded to tmux control-mode DCS events (the high-volume %output path is
    /// skipped in `refreshTmuxDebugAfter`); non-tmux surfaces never enable it.
    /// Resets per-session fields so a fresh gateway starts clean. ROOTSHELL-TMUX
    /// (id=tmux-debug-mirror)
    fn tmuxDebugOnViewerCreated(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        const m = &self.tmux_debug;
        m.command_queue_highwater.store(0, .monotonic);
        m.sent_fifo_highwater.store(0, .monotonic);
        m.parser_buffer_highwater.store(0, .monotonic);
        m.viewer_created_ms.store(0, .monotonic); // refresh stamps "now"
        m.resync_started_ms.store(0, .monotonic);
        m.last_output_ms.store(0, .monotonic);
        m.last_block_ms.store(0, .monotonic);
        m.last_command_ms.store(0, .monotonic);
        m.last_notification_ms.store(0, .monotonic);
        m.total_notifications.store(0, .monotonic);
        m.total_blocks.store(0, .monotonic);
        m.total_output_events.store(0, .monotonic);
        m.total_commands_sent.store(0, .monotonic);
        m.parser_last_error.store(0, .monotonic);
        m.viewer_last_error.store(0, .monotonic);
        // Read-progress gauges (id=tmux-debug-read-progress).
        m.read_enter_bytes.store(0, .monotonic);
        m.read_done_bytes.store(0, .monotonic);
        m.tmux_put_bytes.store(0, .monotonic);
        m.read_enter_ms.store(0, .monotonic);
        m.read_done_ms.store(0, .monotonic);
        m.read_site.store(0, .monotonic);
        m.read_site_pane.store(0, .monotonic);
        m.pane_lock_timeouts.store(0, .monotonic);
        m.enabled.store(true, .monotonic);
        self.refreshTmuxDebug(); // populate immediately so an idle session is warm
    }

    /// Refresh after a completed DCS command, skipping the full field sync for
    /// high-volume %output/%extended-output (their last-output timestamp is
    /// stamped cheaply in the .tmux dispatch arm; the diagnostic fields only move
    /// on lower-volume events — blocks, layout/window/session changes — and on
    /// command sends). Keeps the hot path to a couple of atomic stores.
    /// ROOTSHELL-TMUX (id=tmux-debug-mirror)
    fn refreshTmuxDebugAfter(self: *StreamHandler, cmd: *const terminal.dcs.Command) void {
        if (comptime !tmux_enabled) return;
        switch (cmd.*) {
            .tmux => |t| switch (t) {
                .output, .extended_output => return,
                else => {},
            },
            else => {},
        }
        self.refreshTmuxDebug();
    }

    /// Refresh the tmux debug mirror from the current viewer + DCS-parser state.
    /// Runs on the IO thread at tmux event sites; a no-op unless a tmux gateway
    /// has enabled the mirror (`tmuxDebugOnViewerCreated`). O(1) plus a tiny pane
    /// loop, no allocation, never touches the pty or blocks. ROOTSHELL-TMUX
    /// (id=tmux-debug-mirror)
    fn refreshTmuxDebug(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        const m = &self.tmux_debug;
        if (!m.enabled.load(.monotonic)) return;
        const now = nowMs();

        // Parser (DCS control channel) state. The control parser lives at
        // self.dcs.state.tmux only while the channel is hooked.
        switch (self.dcs.state) {
            .tmux => |*p| {
                const code: u8 = switch (p.state) {
                    .idle => 1,
                    .notification => 2,
                    .block => 3,
                    .broken => 4,
                };
                m.parser_state.store(code, .monotonic);
                m.parser_tolerant.store(p.tolerant, .monotonic);
                m.parser_last_error.store(@intFromEnum(p.last_error), .monotonic);
                // The buffer is deinited while broken; never read it then.
                const blen: u32 = if (p.state != .broken)
                    @intCast(@min(p.buffer.written().len, std.math.maxInt(u32)))
                else
                    0;
                m.parser_buffer_bytes.store(blen, .monotonic);
                if (blen > m.parser_buffer_highwater.load(.monotonic))
                    m.parser_buffer_highwater.store(blen, .monotonic);
                m.parser_buffer_max_bytes.store(
                    @intCast(@min(p.max_bytes, std.math.maxInt(u32))),
                    .monotonic,
                );
            },
            else => {
                m.parser_state.store(0, .monotonic);
                m.parser_tolerant.store(false, .monotonic);
            },
        }

        m.force_unhook.store(self.tmux_force_unhook, .monotonic);
        m.resume_pending.store(self.tmux_resume_pending, .monotonic);

        if (self.tmux_viewer) |viewer| {
            const vcode: u8 = switch (viewer.state) {
                .startup => 1,
                .resync => 2,
                .command_queue => 3,
                .defunct => 4,
            };
            m.viewer_state.store(vcode, .monotonic);
            m.command_in_flight.store(viewer.command_in_flight, .monotonic);
            m.viewer_last_error.store(@intFromEnum(viewer.last_error), .monotonic);
            m.session_id.store(@intCast(@min(viewer.session_id, std.math.maxInt(u32))), .monotonic);

            const qd: u32 = @intCast(@min(viewer.command_queue.len(), std.math.maxInt(u32)));
            m.command_queue_depth.store(qd, .monotonic);
            if (qd > m.command_queue_highwater.load(.monotonic))
                m.command_queue_highwater.store(qd, .monotonic);

            const fd: u32 = @intCast(@min(viewer.sent_fifo.len(), std.math.maxInt(u32)));
            m.sent_fifo_depth.store(fd, .monotonic);
            if (fd > m.sent_fifo_highwater.load(.monotonic))
                m.sent_fifo_highwater.store(fd, .monotonic);

            // In-flight command kind: per the command_queue precondition, the
            // head is the in-flight command while command_in_flight is set.
            const kind: u8 = if (viewer.command_in_flight)
                if (viewer.command_queue.first()) |first| switch (first.*) {
                    .list_windows => 1,
                    .pane_history => 2,
                    .pane_visible => 3,
                    .pane_state, .window_pane_state => 4,
                    .tmux_version => 5,
                    .subscribe_titles => 6,
                    .pane_mode_query => 7,
                    .client_size => 8,
                    .continue_pane => 9,
                    .pane_color_report => 10,
                    .user => 11,
                    .enable_pause => 12,
                    .user_query => 13,
                } else 0
            else
                0;
            m.in_flight_cmd_kind.store(kind, .monotonic);

            m.window_count.store(@intCast(@min(viewer.windows.items.len, std.math.maxInt(u32))), .monotonic);
            m.retired_pane_count.store(@intCast(@min(viewer.retired_panes.items.len, std.math.maxInt(u32))), .monotonic);

            var pcount: u32 = 0;
            var paused: u32 = 0;
            var uninit: u32 = 0;
            var pending: u32 = 0;
            var it = viewer.panes.iterator();
            while (it.next()) |entry| {
                const pane = entry.value_ptr.*;
                pcount += 1;
                if (pane.paused) paused += 1;
                if (!pane.initialized) uninit += 1;
                pending += @intCast(@min(pane.responses.items.len, std.math.maxInt(u32)));
            }
            m.pane_count.store(pcount, .monotonic);
            m.paused_pane_count.store(paused, .monotonic);
            m.uninitialized_pane_count.store(uninit, .monotonic);
            m.pending_pane_responses.store(pending, .monotonic);

            if (m.viewer_created_ms.load(.monotonic) == 0)
                m.viewer_created_ms.store(now, .monotonic);
            if (viewer.isResyncing()) {
                if (m.resync_started_ms.load(.monotonic) == 0)
                    m.resync_started_ms.store(now, .monotonic);
            } else {
                m.resync_started_ms.store(0, .monotonic);
            }
        } else {
            // No viewer: zero the viewer-scoped fields so a stale topology from a
            // prior session can't read back after teardown.
            m.viewer_state.store(0, .monotonic);
            m.command_in_flight.store(false, .monotonic);
            m.in_flight_cmd_kind.store(0, .monotonic);
            m.command_queue_depth.store(0, .monotonic);
            m.sent_fifo_depth.store(0, .monotonic);
            m.session_id.store(0, .monotonic);
            m.window_count.store(0, .monotonic);
            m.pane_count.store(0, .monotonic);
            m.retired_pane_count.store(0, .monotonic);
            m.paused_pane_count.store(0, .monotonic);
            m.uninitialized_pane_count.store(0, .monotonic);
            m.pending_pane_responses.store(0, .monotonic);
            m.viewer_created_ms.store(0, .monotonic);
            m.resync_started_ms.store(0, .monotonic);
        }
    }

    /// Fill `out` with a privacy-safe snapshot of this surface's tmux
    /// control-mode internals for the iOS debug log. Lockless atomic read on the
    /// APP thread (no IO-thread hop), so it stays valid even when control mode is
    /// protocol-stalled. The mirror is warmed for the whole gateway lifetime (see
    /// `tmuxDebugOnViewerCreated`), so it reads real state even if the app enables
    /// logging only AFTER a hang. Returns false (and zero-fills) when this surface
    /// isn't a live tmux gateway. ROOTSHELL-TMUX (id=tmux-debug-snapshot)
    pub fn tmuxDebugSnapshot(self: *StreamHandler, out: *TmuxDebugSnapshot) bool {
        out.* = std.mem.zeroes(TmuxDebugSnapshot);
        out.abi_version = 2;
        if (comptime !tmux_enabled) return false;
        const m = &self.tmux_debug;
        if (!self.tmux_active_flag.load(.monotonic)) return false;

        const now = nowMs();

        out.viewer_state = m.viewer_state.load(.monotonic);
        out.parser_state = m.parser_state.load(.monotonic);
        out.parser_tolerant = @intFromBool(m.parser_tolerant.load(.monotonic));
        out.tmux_active = 1;
        out.force_unhook_pending = @intFromBool(m.force_unhook.load(.monotonic));
        out.resume_pending = @intFromBool(m.resume_pending.load(.monotonic));
        out.command_in_flight = @intFromBool(m.command_in_flight.load(.monotonic));
        out.in_flight_cmd_kind = m.in_flight_cmd_kind.load(.monotonic);
        out.parser_last_error = m.parser_last_error.load(.monotonic);
        out.viewer_last_error = m.viewer_last_error.load(.monotonic);

        out.command_queue_depth = m.command_queue_depth.load(.monotonic);
        out.command_queue_highwater = m.command_queue_highwater.load(.monotonic);
        out.sent_fifo_depth = m.sent_fifo_depth.load(.monotonic);
        out.sent_fifo_highwater = m.sent_fifo_highwater.load(.monotonic);

        out.session_id = m.session_id.load(.monotonic);
        out.window_count = m.window_count.load(.monotonic);
        out.pane_count = m.pane_count.load(.monotonic);
        out.retired_pane_count = m.retired_pane_count.load(.monotonic);
        out.paused_pane_count = m.paused_pane_count.load(.monotonic);
        out.uninitialized_pane_count = m.uninitialized_pane_count.load(.monotonic);
        out.pending_pane_responses = m.pending_pane_responses.load(.monotonic);

        out.parser_buffer_bytes = m.parser_buffer_bytes.load(.monotonic);
        out.parser_buffer_highwater = m.parser_buffer_highwater.load(.monotonic);
        out.parser_buffer_max_bytes = m.parser_buffer_max_bytes.load(.monotonic);

        out.ms_since_last_output = msSince(now, m.last_output_ms.load(.monotonic));
        out.ms_since_last_block = msSince(now, m.last_block_ms.load(.monotonic));
        out.ms_since_last_command_sent = msSince(now, m.last_command_ms.load(.monotonic));
        out.ms_since_last_notification = msSince(now, m.last_notification_ms.load(.monotonic));
        out.ms_since_viewer_created = msSince(now, m.viewer_created_ms.load(.monotonic));
        out.resync_age_ms = msSince(now, m.resync_started_ms.load(.monotonic));

        out.total_notifications = m.total_notifications.load(.monotonic);
        out.total_blocks = m.total_blocks.load(.monotonic);
        out.total_output_events = m.total_output_events.load(.monotonic);
        out.total_commands_sent = m.total_commands_sent.load(.monotonic);

        // ABI v2 appendix. ROOTSHELL-TMUX (id=tmux-debug-read-progress)
        out.gw_read_enter_bytes = m.read_enter_bytes.load(.monotonic);
        out.gw_read_done_bytes = m.read_done_bytes.load(.monotonic);
        out.gw_tmux_put_bytes = m.tmux_put_bytes.load(.monotonic);
        out.ms_since_read_enter = msSince(now, m.read_enter_ms.load(.monotonic));
        out.ms_since_read_done = msSince(now, m.read_done_ms.load(.monotonic));
        out.pane_lock_timeouts = m.pane_lock_timeouts.load(.monotonic);
        out.read_site_pane_id = m.read_site_pane.load(.monotonic);
        out.read_thread_site = m.read_site.load(.monotonic);

        return true;
    }

    /// Milliseconds between a stored `nowMs` timestamp and `now`; 0 when the
    /// timestamp is unset (0) or `now` is older. ROOTSHELL-TMUX
    /// (id=tmux-debug-mirror)
    fn msSince(now: i64, then: i64) u64 {
        if (then == 0) return 0;
        const d = now - then;
        return if (d > 0) @intCast(d) else 0;
    }

    /// Whether the `.tmux_resume` message should feed the synthetic control-mode
    /// entry on this surface. Returns false (and does nothing) when tmux is
    /// disabled at build/runtime or a viewer is already active; otherwise sets
    /// `tmux_resume_pending` so the upcoming `.enter` dispatch enters resync.
    /// The caller (Thread) then feeds `ESC P 1000 p` into the stream. Keeping the
    /// gate here lets Thread stay agnostic of the tmux build flag. ROOTSHELL-TMUX
    /// (id=streamhandler-resume-should-enter)
    pub fn tmuxResumeShouldEnter(self: *StreamHandler, preferred_window: ?usize) bool {
        if (comptime !tmux_enabled) return false;
        if (!self.tmux_control_mode) return false;
        if (self.tmux_viewer != null) return false;
        self.tmux_resume_pending = true;
        self.tmux_resume_preferred_window = preferred_window;
        return true;
    }

    /// Per-probe nonce for the dead-shell echo matcher. ROOTSHELL-TMUX
    /// (id=streamhandler-detach-echo)
    const ProbeNonce = [terminal.tmux.ProbeEchoMatcher.nonce_len]u8;
    const ResyncProbeBuf = [
        terminal.tmux.Viewer.resync_probe_prefix.len +
            terminal.tmux.ProbeEchoMatcher.nonce_len +
            terminal.tmux.Viewer.resync_probe_suffix.len
    ]u8;

    /// Build a resync probe command carrying a fresh random nonce into `buf`,
    /// returning the full command slice (writeReq copies it, so the stack
    /// buffer is fine) and the nonce for arming the echo matcher. The nonce is
    /// what makes the probe's shell ECHO unforgeable: the PUBLIC marker text
    /// can legitimately appear in pane output (these sources, docs, a user
    /// echoing the marker) whose %output framing was lost to the same
    /// corruption that started the resync — but this token exists only in the
    /// one command string just written. ROOTSHELL-TMUX
    /// (id=streamhandler-detach-echo)
    fn buildResyncProbe(buf: *ResyncProbeBuf, nonce_out: *ProbeNonce) []const u8 {
        var raw: [terminal.tmux.ProbeEchoMatcher.nonce_len / 2]u8 = undefined;
        global.io().random(&raw);
        nonce_out.* = std.fmt.bytesToHex(raw, .lower);
        const prefix = terminal.tmux.Viewer.resync_probe_prefix;
        const suffix = terminal.tmux.Viewer.resync_probe_suffix;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..nonce_out.len], nonce_out);
        @memcpy(buf[prefix.len + nonce_out.len ..][0..suffix.len], suffix);
        return buf;
    }

    /// Re-send the resync probe to tmux. Called when a viewer already exists and
    /// is still resyncing (the app retries the probe on a cadence). The first
    /// probe can be lost if it is written before the tssh transport finished
    /// attaching, and an idle tmux session only ever answers OUR probe, so the
    /// retry is what actually drives the rebuild. No-op once we have left resync
    /// (the reconcile is in progress) or there is no viewer. ROOTSHELL-TMUX
    /// (id=streamhandler-resume-resend-probe)
    pub fn tmuxResumeResendProbe(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        if (!viewer.isResyncing()) return;
        var probe_buf: ResyncProbeBuf = undefined;
        var nonce: ProbeNonce = undefined;
        const queued = self.messageWriterChecked(termio.Message.writeReq(
            self.alloc,
            buildResyncProbe(&probe_buf, &nonce),
        ) catch return);
        // Count the probe ONLY if it was actually queued. On the unlocked-IO path
        // sendBounded can DROP the message under sustained mailbox backpressure;
        // recording a phantom outstanding probe would leave the viewer waiting for
        // a marker that was never written (wedged in resync). A dropped probe just
        // retries on the next cadence tick (this fn is the cadence). Counting a
        // queued probe also lets a later stray response be dropped by count rather
        // than an unconditional sentinel scan. ROOTSHELL-TMUX (id=viewer-resync-probe-count)
        if (queued) {
            viewer.recordResyncProbeSent();
            // Arm dead-shell detach detection only for a viewer with projected
            // topology (the app watchdog re-probing a wedged LIVE gateway). A
            // restore-resume retry (no windows yet) is deliberately excluded:
            // there is no Swift controller yet, so our empty-topology snapshot
            // would be ignored and the resume watchdog would churn re-entries —
            // its 12s abort already owns that path. ROOTSHELL-TMUX
            // (id=streamhandler-detach-echo)
            if (viewer.windows.items.len > 0) self.dcs.armTmuxProbeEcho(nonce);
        }
    }

    /// Drive a LIVE re-resync of the control channel: reset the viewer's command
    /// pipeline (preserving panes/windows), realign the control parser, and send
    /// a fresh resync probe whose marker reply rebuilds the topology via
    /// list-windows. This is the recovery for a block-framing desync (the
    /// observed command-pipeline hang) and for mid-stream data loss (the tsshd
    /// buffer overflowing while backgrounded drops a chunk). Same probe logic as
    /// the resume `.enter` path. Triggered from `tmuxMaybeRecover` (the control
    /// parser raised its recover edge) and from the app's
    /// `ghostty_surface_tmux_recover` watchdog. No-op unless a viewer is live in
    /// the steady `.command_queue` state (a fresh startup/resume drives its own
    /// resync). Runs on the IO thread; the read path holds the renderer mutex, so
    /// `messageWriter` is safe. ROOTSHELL-TMUX (id=streamhandler-force-resync)
    pub fn tmuxForceResync(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        if (!viewer.isCommandQueue()) return;
        log.warn("tmux control desync/data-loss detected; forcing live re-resync", .{});
        var probe_buf: ResyncProbeBuf = undefined;
        var nonce: ProbeNonce = undefined;
        const probe_msg = termio.Message.writeReq(
            self.alloc,
            buildResyncProbe(&probe_buf, &nonce),
        ) catch |err| {
            log.warn("failed to allocate tmux resync probe message: {}; forcing control-mode exit", .{err});
            self.tmuxForceExit();
            return;
        };

        // Error pending app queries back before forceResync clears the
        // command queue. ROOTSHELL-TMUX (id=streamhandler-query-command)
        self.failPendingTmuxQueries(viewer);
        viewer.forceResync();
        // Realign the parser to a clean line boundary (the live stream may resume
        // mid-line after data loss) so it does not break on the next byte.
        self.dcs.beginTmuxResync();
        // Count the probe ONLY if it was actually queued. On the unlocked-IO path
        // sendBounded can DROP it under sustained mailbox backpressure; a phantom
        // outstanding probe would wedge the viewer in resync (already entered
        // above) with no marker ever coming. Unlike the resume/resend paths there
        // is no external cadence re-driving this one-shot live recovery, so on a
        // drop exit control mode cleanly NOW (the IO path is overwhelmed) rather
        // than wedge until the app's 15s resync-stuck watchdog — mirrors the
        // alloc-failure branch above. ROOTSHELL-TMUX (id=viewer-resync-probe-count)
        if (self.messageWriterChecked(probe_msg)) {
            viewer.recordResyncProbeSent();
            // If the remote is actually a plain shell (tmux exited but its
            // `%exit` was lost to the same data loss that got us here), this
            // probe is typed at the prompt and ECHOED back — arm the detach
            // scan so that echo converts into a clean exit instead of a
            // wedged resync. ROOTSHELL-TMUX (id=streamhandler-detach-echo)
            self.dcs.armTmuxProbeEcho(nonce);
            // Surface the new state immediately (no-op unless the app opted in).
            self.refreshTmuxDebug();
        } else {
            log.warn("tmux resync probe dropped (mailbox backpressure); forcing control-mode exit", .{});
            self.tmuxForceExit();
        }
    }

    /// Drive a LIVE full RESET of the control channel for a LOSSY reconnect
    /// (`ghostty_surface_tmux_reset`): like `tmuxForceResync`, but the viewer also
    /// force-recaptures EVERY pane so dropped `%output` content is rebuilt to a
    /// consistent state (and re-arms the title subscription). Used when the app
    /// detects the tsshd server discarded buffered output on a reconnect — a
    /// discard can drop bytes mid-block, so the cheaper reuse path would leave
    /// gapped panes/scrollback. No-op unless a viewer is live in the steady
    /// `.command_queue` state. Runs on the IO thread; the read path holds the
    /// renderer mutex, so `messageWriter` is safe.
    /// ROOTSHELL-TMUX (id=streamhandler-force-reset)
    pub fn tmuxForceReset(self: *StreamHandler, preferred_window: ?usize) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        // Always record the intent first. If a resync is ALREADY in flight (e.g. a
        // cheaper wedge `forceResync`), `forceReset` can't start (it needs
        // `.command_queue`); the in-flight rebuild's marker handler honors
        // `reset_pending` and upgrades itself into a full recapture, so a discard
        // landing during the resync probe window is never dropped. A real
        // `forceReset` below clears the flag. ROOTSHELL-TMUX (id=streamhandler-force-reset)
        viewer.requestResetPrioritized(preferred_window);
        if (!viewer.isCommandQueue()) return;
        log.warn("tmux output discard detected; forcing full surface reset + recapture", .{});
        var probe_buf: ResyncProbeBuf = undefined;
        var nonce: ProbeNonce = undefined;
        const probe_msg = termio.Message.writeReq(
            self.alloc,
            buildResyncProbe(&probe_buf, &nonce),
        ) catch |err| {
            log.warn("failed to allocate tmux reset probe message: {}; forcing control-mode exit", .{err});
            self.tmuxForceExit();
            return;
        };

        // Error pending app queries back before forceReset clears the
        // command queue. ROOTSHELL-TMUX (id=streamhandler-query-command)
        self.failPendingTmuxQueries(viewer);
        viewer.forceResetPrioritized(preferred_window);
        // Realign the parser to a clean line boundary (the live stream may resume
        // mid-line after data loss) so it does not break on the next byte.
        self.dcs.beginTmuxResync();
        // Same one-shot probe-drop handling as tmuxForceResync: nothing external
        // re-drives this recovery, so on a mailbox-backpressure drop exit control
        // mode cleanly NOW rather than wedge until the app's 15s resync-stuck
        // watchdog. ROOTSHELL-TMUX (id=viewer-resync-probe-count)
        if (self.messageWriterChecked(probe_msg)) {
            viewer.recordResyncProbeSent();
            // Same dead-shell detach arming as tmuxForceResync: a discard that
            // also swallowed `%exit` leaves a plain shell that echoes this
            // probe back. ROOTSHELL-TMUX (id=streamhandler-detach-echo)
            self.dcs.armTmuxProbeEcho(nonce);
            // Surface the new state immediately (no-op unless the app opted in).
            self.refreshTmuxDebug();
        } else {
            log.warn("tmux reset probe dropped (mailbox backpressure); forcing control-mode exit", .{});
            self.tmuxForceExit();
        }
    }

    /// After feeding control-mode bytes, consume the parser's recover edge and
    /// drive a live re-resync if it was raised (a stray byte, a run of mismatched
    /// block terminators, or a runaway block — all signatures of mid-stream data
    /// loss). Cheap: a take-and-clear bool unless a desync was actually flagged.
    /// ROOTSHELL-TMUX (id=streamhandler-force-resync)
    inline fn tmuxMaybeRecover(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        // Detach beats recover: the echo is positive proof the remote is a
        // plain shell, so a re-resync would only type another command into it.
        // ROOTSHELL-TMUX (id=streamhandler-detach-echo)
        if (self.dcs.tmuxTakeDetachRequest()) {
            self.tmuxDetachEchoExit();
            return;
        }
        if (self.dcs.tmuxTakeRecoverRequest()) self.tmuxForceResync();
    }

    /// The recovery probe was ECHOED back by a plain shell: tmux exited but
    /// its `%exit` was lost to mid-stream data loss, and the remote pty is at
    /// a prompt. Tear down exactly like a clean `%exit` (see the `.exit`
    /// handler): prune child surfaces, free the viewer, and request the
    /// deferred DCS unhook. The deferred flag (not a synchronous
    /// `dcs.unhook()`) is correct here because bytes ARE flowing — the byte
    /// that completed the match is a `dcs_put`, and the stream consumes the
    /// ground request immediately after it returns, so the parser grounds
    /// within the same byte and the shell's following output ("command not
    /// found", the prompt) paints normally. Deliberately NO ExitDrain: the
    /// echo is by construction past the shell transition — the remote client
    /// already exited, no `%exit` will ever arrive, and draining would eat
    /// real shell output; the echoed line's own tail is consumed by the
    /// matcher's drain_line state instead. ROOTSHELL-TMUX
    /// (id=streamhandler-detach-echo)
    fn tmuxDetachEchoExit(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        if (self.tmux_viewer == null) return;
        log.warn("tmux resync probe echoed by a plain shell; remote detached — exiting control mode", .{});
        self.tmuxTeardownViewer();
        self.tmux_force_unhook = true;
        self.refreshTmuxDebug();
    }

    /// Abort an in-progress control-mode resume (see `Viewer.enterResync`).
    /// Called when the app's resume watchdog fires because no reconcile arrived:
    /// tmux died, the session expired, or the reattached pty is at a bare shell,
    /// so the resync probe will never echo back. Tears down the resync viewer AND
    /// synchronously resets the DCS handler back to `.inactive` (the caller, in
    /// Thread, separately forces the outer VT parser to ground). Both resets are
    /// required: without the DCS unhook, `self.dcs.state` stays `.tmux`, and the
    /// NEXT real `ESC P 1000 p` (a fresh `tmux -CC attach`) trips
    /// `dcs.Handler.hook`'s `assert(state == .inactive)` / corrupts state, leaving
    /// the new control mode broken (empty tabs). `dcsConsumeGroundRequest` only
    /// fires during later DCS processing, which may never happen on abort, so we
    /// unhook here directly. No-op when no viewer is active. ROOTSHELL-TMUX
    /// (id=streamhandler-resume-abort)
    pub fn tmuxResumeAbort(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        self.tmux_resume_pending = false;
        self.tmux_resume_preferred_window = null;
        if (self.tmux_viewer) |viewer| {
            // Error pending app queries back before the queue dies with the
            // viewer. ROOTSHELL-TMUX (id=streamhandler-query-command)
            self.failPendingTmuxQueries(viewer);
            // Do NOT send an empty topology snapshot here: the abort fires before
            // any window was projected (a reconcile would have cancelled the
            // watchdog), so there is nothing to prune — and an empty reconcile
            // would otherwise make the app create a windowless (stale) controller
            // that never tears down, re-marking the gateway tmux-active on save.
            viewer.deinit();
            self.alloc.destroy(viewer);
            self.tmux_viewer = null;
            self.tmux_active_flag.store(false, .monotonic); // ROOTSHELL-TMUX (id=streamhandler-tmux-active-flag)
        }
        // Reset the DCS handler out of `.tmux` (frees the control parser buffer)
        // so a later real control-mode hook starts from `.inactive`. Mirrors
        // `dcsConsumeGroundRequest`'s unhook; the returned `.tmux = .exit` command
        // is redundant here (viewer already gone), so just free it.
        if (self.dcs.unhook()) |cmd| {
            var freed = cmd;
            freed.deinit();
        }
        // The DCS handler is already reset above, so clear the deferred flag to
        // avoid a redundant unhook on the next stray DCS put.
        self.tmux_force_unhook = false;
    }

    pub fn tmuxDetach(self: *StreamHandler) void { // ROOTSHELL-TMUX (id=streamhandler-detach)
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        viewer.queueUserCommand("detach-client\n") catch |err| {
            log.warn("failed to queue tmux detach err={}", .{err});
            return;
        };
        self.pumpTmuxCommandQueue(viewer);
    }

    /// Forcibly exit control mode LOCALLY (recovery watchdog gave up on a wedge
    /// it could not heal). Unlike `tmuxDetach`, this does NOT ask tmux to exit
    /// (no `detach-client` round-trip) — it tears down locally so it works even
    /// when tmux/the link is unresponsive. `tmuxTeardownViewer` emits the
    /// empty-topology snapshot exactly like `%exit`, so the app prunes the
    /// projected tabs through the normal reconcile path (which also drops the
    /// controller) and the gateway returns to its shell. The caller (Thread)
    /// forces the VT parser back to ground; `tmux_force_unhook` resets the DCS
    /// handler out of `.tmux` so a later real hook starts clean. The tmux
    /// server/session stays alive. No-op when no viewer is active. ROOTSHELL-TMUX
    /// (id=streamhandler-force-exit)
    pub fn tmuxForceExit(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;
        if (self.tmux_viewer == null) return;
        log.warn("tmux recovery gave up; forcing local control-mode exit", .{});
        // Arm the post-exit drain: the remote `tmux -CC` client is still
        // attached, so the transport may deliver a swallowed control backlog
        // plus (after our best-effort detach-client) a real `%exit` + ST.
        // Discard up to that boundary instead of painting raw protocol bytes
        // into the revealed shell. ROOTSHELL-TMUX (id=streamhandler-post-exit-drain)
        self.tmux_post_exit_drain = terminal.tmux.ExitDrain.init(nowMs());
        // Emits the empty-topology snapshot (the app prunes via the reconcile
        // path) and frees the viewer + clears the active flag.
        self.tmuxTeardownViewer();
        // Reset the DCS handler out of `.tmux` SYNCHRONOUSLY (frees the control
        // parser buffer). This is REQUIRED, not deferrable: the caller (Thread)
        // forces the VT parser straight to `.ground`, which bypasses the only
        // caller of `dcsConsumeGroundRequest`, so the deferred `tmux_force_unhook`
        // would never run and `self.dcs.state` would stay `.tmux` — tripping
        // `dcs.Handler.hook`'s `assert(state == .inactive)` on the next real
        // control-mode entry. Mirrors `tmuxResumeAbort`; the returned `.tmux =
        // .exit` command is redundant (viewer already gone), so free it.
        // ROOTSHELL-TMUX (id=streamhandler-force-exit)
        if (self.dcs.unhook()) |cmd| {
            var freed = cmd;
            freed.deinit();
        }
        // DCS already reset above; clear the deferred flag so a later stray DCS
        // put doesn't redundantly unhook.
        self.tmux_force_unhook = false;
        self.refreshTmuxDebug();
    }

    /// Called by `terminal.stream` after each `dcs_put`. Returns true to ask the
    /// stream to return the parser to ground. The fork's parse table deliberately
    /// never leaves `dcs_passthrough` on ESC / C1 / CAN / SUB (so a control-mode
    /// payload isn't cut short), so the parser has no native exit from
    /// passthrough — this is the only path back to ground. Two cases:
    ///
    ///   1. Leaving tmux control mode: `tmux -CC`'s `%exit` (and the malformed
    ///      `.broken` recovery) is parsed as a `dcs_put` and sets
    ///      `tmux_force_unhook`. tmux may not emit a clean closing ST, so without
    ///      forcing ground the gateway keeps routing the shell's prompt into the
    ///      (now freed) tmux parser and the tab looks frozen. We also reset the
    ///      DCS handler out of `.tmux` so a later DCS hook doesn't trip the
    ///      `state == .inactive` assert in `dcs.Handler.hook`.
    ///
    ///   2. An ORDINARY DCS on this surface (XTGETTCAP, DECRQSS, sixel,
    ///      unknown→ignore): `dcs.Handler.put` performs its own 7-bit `ESC \` /
    ///      8-bit `0x9C` ST and CAN/SUB abort detection and returns the handler
    ///      to `.inactive` when the control string ends. Once it is inactive we
    ///      must return the parser to ground ourselves, or every subsequent byte
    ///      is silently swallowed by the now-inactive DCS handler (the wedge this
    ///      whole mechanism exists to prevent — see `dcs.Handler.isInactive`).
    ///
    /// Both cases work in a non-tmux build too (case 1 is compiled out).
    /// ROOTSHELL-TMUX (id=streamhandler-dcs-ground).
    pub fn dcsConsumeGroundRequest(self: *StreamHandler) bool {
        if (comptime tmux_enabled) {
            if (self.tmux_force_unhook) {
                self.tmux_force_unhook = false;
                // The returned `.tmux = .exit` command is redundant here (the
                // viewer is already gone), so we just free it.
                if (self.dcs.unhook()) |cmd| {
                    var freed = cmd;
                    freed.deinit();
                }
                return true;
            }
        }

        // Ordinary DCS: dcs.put has its own ST/abort detection and goes inactive
        // when the control string ends.
        return self.dcs.isInactive();
    }

    /// Route a raw tmux command relayed out-of-band from a child pane backend
    /// (resize-pane / select-pane / select-window) through the viewer's command
    /// queue, so its %begin/%end response is tracked and consumed in order
    /// rather than injected as a stray block that desyncs the capture-pane FIFO.
    /// `cmd` includes its trailing newline and is copied by the viewer.
    pub fn tmuxQueuePaneCommand(self: *StreamHandler, cmd: []const u8) void { // ROOTSHELL-TMUX (id=streamhandler-pane-command)
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse {
            // No viewer (should not happen for a pane relay): write directly so
            // the command still reaches tmux rather than being silently lost.
            self.messageWriter(termio.Message.writeReq(self.alloc, cmd) catch return);
            return;
        };
        // queueRelayedPaneCommand forwards select-pane/select-window verbatim,
        // but rewrites a `resize-pane` for a single-pane window into a
        // `refresh-client -C` (client size) — tmux won't reflow a sole pane via
        // resize-pane. This keeps the resize path in the core layer using the
        // pane's own (cell/font/inset-aware) grid, so the apprt never computes
        // tmux geometry.
        viewer.queueRelayedPaneCommand(cmd) catch |err| {
            log.warn("failed to queue tmux pane command err={}", .{err});
            return;
        };
        // Flush now in case the queue was idle, so a pane resize/select takes
        // effect without waiting for the next inbound notification.
        self.pumpTmuxCommandQueue(viewer);
    }

    /// Route an app-issued query command (session dashboard: list-sessions,
    /// list-windows -t, new-session -P, ...) through the viewer's command
    /// queue. Its `%begin/%end` (or `%error`) response comes back as a
    /// `command_response` viewer action, forwarded to the app correlated by
    /// `tag`. When no viewer is active (or the queue fails), an error
    /// response is posted immediately so the app-side continuation fails
    /// fast instead of waiting out its timeout. ROOTSHELL-TMUX
    /// (id=streamhandler-query-command)
    pub fn tmuxQueueQueryCommand(self: *StreamHandler, cmd: []const u8, tag: u32) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse {
            self.postTmuxQueryError(tag);
            return;
        };
        viewer.queueUserQuery(cmd, tag) catch |err| {
            log.warn("failed to queue tmux query command err={}", .{err});
            self.postTmuxQueryError(tag);
            return;
        };
        // Flush now in case the queue was idle (an idle session never pumps).
        self.pumpTmuxCommandQueue(viewer);
    }

    /// Post an error `tmux_command_response` (empty body) for `tag` so the
    /// app's pending query fails fast. ROOTSHELL-TMUX (id=streamhandler-query-command)
    fn postTmuxQueryError(self: *StreamHandler, tag: u32) void {
        const resp = apprt.surface.Message.TmuxCommandResponse.create(
            self.alloc,
            tag,
            "",
            true,
        ) catch |err| {
            // The app-side timeout is the backstop here.
            log.warn("failed to allocate tmux query error response tag={} err={}", .{ tag, err });
            return;
        };
        self.surfaceMessageWriter(.{ .tmux_command_response = resp });
    }

    /// Error every queued/in-flight app query back to the app. Called before
    /// any reset that destroys or clears the viewer's command queue
    /// (teardown, forceResync, resume abort) — the queries' responses will
    /// never arrive, and without this the app-side continuations hang until
    /// their timeout. ROOTSHELL-TMUX (id=streamhandler-query-command)
    fn failPendingTmuxQueries(
        self: *StreamHandler,
        viewer: *terminal.tmux.Viewer,
    ) void {
        if (comptime !tmux_enabled) return;
        viewer.forEachPendingQueryTag(self, struct {
            fn cb(handler: *StreamHandler, tag: u32) void {
                handler.postTmuxQueryError(tag);
            }
        }.cb);
    }

    pub inline fn dcsHook(self: *StreamHandler, dcs: terminal.DCS) !void {
        const maybe = self.dcs.hook(self.alloc, dcs);
        // Heal a control-mode framing desync / mid-stream data loss the parser
        // flagged while consuming this input, before processing any command.
        // ROOTSHELL-TMUX (id=streamhandler-force-resync)
        if (comptime tmux_enabled) self.tmuxMaybeRecover();
        var cmd = maybe orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
        // Sync the tmux debug mirror after each completed DCS command (no-op
        // unless a tmux gateway is live). ROOTSHELL-TMUX (id=tmux-debug-mirror)
        if (comptime tmux_enabled) self.refreshTmuxDebugAfter(&cmd);
    }

    pub inline fn dcsPut(self: *StreamHandler, byte: u8) !void {
        // Count bytes that actually reach the tmux control channel, so a log
        // can distinguish "transport delivered but the parser never saw it"
        // from "the parser saw it". ROOTSHELL-TMUX (id=tmux-debug-read-progress)
        if (comptime tmux_enabled) {
            if (self.dcs.state == .tmux and
                self.tmux_debug.enabled.load(.monotonic))
            {
                _ = self.tmux_debug.tmux_put_bytes.fetchAdd(1, .monotonic);
            }
        }
        const maybe = self.dcs.put(byte);
        if (comptime tmux_enabled) self.tmuxMaybeRecover(); // ROOTSHELL-TMUX (id=streamhandler-force-resync)
        var cmd = maybe orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
        if (comptime tmux_enabled) self.refreshTmuxDebugAfter(&cmd); // ROOTSHELL-TMUX (id=tmux-debug-mirror)
    }

    pub inline fn dcsUnhook(self: *StreamHandler) !void {
        const maybe = self.dcs.unhook();
        if (comptime tmux_enabled) self.tmuxMaybeRecover(); // ROOTSHELL-TMUX (id=streamhandler-force-resync)
        var cmd = maybe orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
        if (comptime tmux_enabled) self.refreshTmuxDebugAfter(&cmd); // ROOTSHELL-TMUX (id=tmux-debug-mirror)
    }

    fn dcsCommand(self: *StreamHandler, cmd: *terminal.dcs.Command) !void {
        // log.warn("DCS command: {}", .{cmd});
        switch (cmd.*) {
            .tmux => |tmux| tmux: { // ROOTSHELL-TMUX (id=streamhandler-dcs-dispatch): tmux %-notification dispatch to the viewer
                // If tmux control mode is disabled at the build level,
                // then this whole block shouldn't be analyzed.
                if (comptime !tmux_enabled) break :tmux;

                // Do NOT log the event with `{f}`: the formatter dumps raw
                // payloads (`%output` pane bytes, `%begin/%end` block content
                // such as `capture-pane` scrollback) which is sensitive user
                // data and arrives at very high volume. Log only the variant
                // name at debug level.
                log.debug("tmux control mode event={s}", .{@tagName(tmux)});

                // Stamp per-kind arrival timestamps/counters into the debug
                // mirror (no-op until the app opts in). The full field sync runs
                // after dcsCommand returns (see dcsPut/dcsHook/dcsUnhook).
                // ROOTSHELL-TMUX (id=tmux-debug-mirror)
                tmuxdbg: {
                    const m = &self.tmux_debug;
                    if (!m.enabled.load(.monotonic)) break :tmuxdbg;
                    const now = nowMs();
                    m.last_notification_ms.store(now, .monotonic);
                    _ = m.total_notifications.fetchAdd(1, .monotonic);
                    switch (tmux) {
                        .output, .extended_output => {
                            m.last_output_ms.store(now, .monotonic);
                            _ = m.total_output_events.fetchAdd(1, .monotonic);
                        },
                        .block_end, .block_err => {
                            m.last_block_ms.store(now, .monotonic);
                            _ = m.total_blocks.fetchAdd(1, .monotonic);
                        },
                        else => {},
                    }
                }

                switch (tmux) {
                    .enter => {
                        // Runtime config gate: only block entering tmux
                        // control mode when disabled. Exit and other events
                        // must still be processed to tear down an active
                        // viewer (e.g. config toggled off mid-session).
                        if (!self.tmux_control_mode) break :tmux;

                        // Setup our viewer state
                        assert(self.tmux_viewer == null);
                        const viewer = try self.alloc.create(terminal.tmux.Viewer);
                        errdefer self.alloc.destroy(viewer);
                        viewer.* = try .init(
                            global.io(),
                            self.alloc,
                            self.terminal.cols,
                            self.terminal.rows,
                        );
                        errdefer viewer.deinit();
                        // Theme the viewer's pane terminals with the gateway
                        // terminal's colors so default-background cells match the
                        // app theme instead of the built-in dark default.
                        viewer.colors = self.terminal.colors;
                        // Configured cursor style/blink, so panes honor
                        // `cursor-style`/`cursor-style-blink` like a normal
                        // surface. Blink stays nullable: null = honor tmux's
                        // reported blink, not forced.
                        // ROOTSHELL-TMUX (id=viewer-cursor-style-default)
                        viewer.default_cursor_style = self.terminal.cursor.default_style;
                        viewer.default_cursor_blink = self.terminal.cursor.default_blink;
                        self.tmux_viewer = viewer;
                        self.tmux_active_flag.store(true, .monotonic); // ROOTSHELL-TMUX (id=streamhandler-tmux-active-flag)
                        // Warm the debug mirror for this gateway's lifetime so a
                        // snapshot taken after a hang (logging enabled late) is
                        // populated. ROOTSHELL-TMUX (id=tmux-debug-mirror)
                        self.tmuxDebugOnViewerCreated();
                        // Hand the viewer pointers into the read-progress
                        // gauges so its pane-lock waits are visible in the
                        // snapshot. ROOTSHELL-TMUX (id=tmux-debug-read-progress)
                        viewer.debug_progress = .{
                            .site = &self.tmux_debug.read_site,
                            .pane = &self.tmux_debug.read_site_pane,
                            .pane_lock_timeouts = &self.tmux_debug.pane_lock_timeouts,
                        };

                        // Print a minimal in-TUI menu into the gateway terminal so
                        // the user has a discoverable, safe way to leave control
                        // mode. Swift intercepts ESC on the gateway view and sends
                        // `detach-client`. Best-effort: a print error must not abort
                        // viewer setup.
                        self.printTmuxGatewayMenu() catch |err| log.warn(
                            "failed to print tmux gateway menu: {}",
                            .{err},
                        );

                        // ROOTSHELL-TMUX (id=streamhandler-enter-resume): on a
                        // control-mode RESUME the synthetic `ESC P 1000 p` (fed
                        // by `.tmux_resume`) created this viewer, but there is no
                        // fresh startup handshake coming — the live `tmux -CC`
                        // resumes mid-protocol. Flip the viewer into resync and
                        // probe for a clean point; the probe's marker reply
                        // (handled in viewer.nextResync) drives the list-windows
                        // rebuild that reprojects the windows/panes.
                        if (self.tmux_resume_pending) {
                            self.tmux_resume_pending = false;
                            const preferred_window = self.tmux_resume_preferred_window;
                            self.tmux_resume_preferred_window = null;
                            viewer.enterResyncPrioritized(preferred_window);
                            // Realign the control parser to a clean line boundary:
                            // the live stream resumes mid-line, so without this the
                            // parser's `.idle` "non-'%' => broken" rule trips on the
                            // first reattach byte (→ defunct → tabs torn down).
                            self.dcs.beginTmuxResync();
                            log.info("tmux control mode resuming (re-entered after reattach)", .{});
                            // Nonce'd for a uniform probe shape; the echo
                            // matcher is deliberately NOT armed on the resume
                            // path (see tmuxResumeResendProbe), so the nonce
                            // is unused here. ROOTSHELL-TMUX
                            // (id=streamhandler-detach-echo)
                            var probe_buf: ResyncProbeBuf = undefined;
                            var probe_nonce: ProbeNonce = undefined;
                            const probe_queued = self.messageWriterChecked(termio.Message.writeReq(
                                self.alloc,
                                buildResyncProbe(&probe_buf, &probe_nonce),
                            ) catch break :tmux);
                            // Count only if actually queued: sendBounded can drop
                            // under backpressure, and a phantom outstanding probe
                            // would wedge resume in resync. The app's resume
                            // watchdog re-sends on a cadence (tmuxResumeResendProbe),
                            // so a dropped probe retries. ROOTSHELL-TMUX
                            // (id=viewer-resync-probe-count)
                            if (probe_queued) viewer.recordResyncProbeSent();
                        }
                        break :tmux;
                    },

                    .exit => {
                        // Tear down the viewer: prune all child surfaces and free
                        // the viewer state.
                        self.tmuxTeardownViewer();

                        // Control mode is over (tmux detached / exited). `%exit`
                        // is delivered as a `dcs_put` while the parser is still in
                        // DCS passthrough, so request that the stream return the
                        // parser to ground after this put — otherwise the gateway
                        // keeps routing the shell's post-detach output into the
                        // (now freed) tmux parser and the tab looks frozen.
                        self.tmux_force_unhook = true;

                        // And always break since we assert below
                        // that we're not handling an exit command.
                        break :tmux;
                    },

                    .broken => {
                        // ROOTSHELL-TMUX (id=streamhandler-broken-control-unhook):
                        // a malformed control stream must recover EXACTLY like a
                        // clean `%exit` — prune child surfaces, free and null the
                        // viewer, and clear the active flag — not merely set
                        // tmux_force_unhook. Otherwise child tabs are orphaned
                        // (frozen), `tmuxActive()` stays true so ESC keeps sending
                        // detach-client into a dead stream and the surface
                        // re-persists as a gateway, and a later genuine `%enter`
                        // trips `assert(self.tmux_viewer == null)` (UB under
                        // inlineAssert in ReleaseFast: silent pointer overwrite +
                        // leak).
                        log.warn("tmux control stream became malformed; tearing down gateway", .{});
                        self.tmuxTeardownViewer();
                        self.tmux_force_unhook = true;
                        break :tmux;
                    },

                    else => {},
                }

                assert(tmux != .enter);
                assert(tmux != .exit);
                assert(tmux != .broken);

                const viewer = self.tmux_viewer orelse {
                    // This can happen if we failed to initialize the
                    // viewer on enter, or if tmux_control_mode was
                    // disabled mid-session while the server continues
                    // sending notifications.
                    log.debug(
                        "received tmux control mode command without viewer: {s}",
                        .{@tagName(tmux)},
                    );

                    break :tmux;
                };

                // ROOTSHELL-TMUX (id=streamhandler-block-fifo-filter): a
                // `%begin/%end` ack for an untracked `send-keys` must be matched
                // in send-order and SWALLOWED here, never fed to the viewer. The
                // viewer matches blocks to queued commands by blind FIFO; feeding
                // it a send-keys ack while a tracked command is in flight (which a
                // tab switch causes: focus-report send-keys + select-window/
                // select-pane/refresh-client together) mis-attributes the ack,
                // desyncs the response stream, garbles the next list-windows into
                // an empty window list, and prunes every tmux tab while tmux is
                // still alive. `.tracked` / `.empty` (e.g. the startup attach
                // block we never wrote) fall through to the viewer unchanged.
                switch (tmux) {
                    .block_end, .block_err => |block| {
                        // Server-originated blocks (flags bit 0 clear) are not
                        // replies to commands we wrote. Do not consume the
                        // sent-FIFO for them; the viewer will either use them in
                        // startup/resync or ignore them in steady state.
                        if (block.info.flags & 1 != 0) {
                            // Drop a stray resync-probe response that arrived AFTER
                            // resync completed (from a retried probe). Dropping it
                            // WITHOUT classifyBlock keeps the positional sent-FIFO
                            // aligned with the rebuild commands (a raw probe carries no
                            // FIFO marker, so consuming one here would desync). During
                            // resync the marker block is the legit one and is handled
                            // by the viewer, so only guard once we have left resync.
                            //
                            // ROOTSHELL-TMUX (id=streamhandler-drop-stray-probe): gate
                            // the sentinel scan on the viewer's outstanding-probe COUNT
                            // (set when each probe is written, decremented as responses
                            // arrive). In normal steady state the count is zero, so a
                            // genuine tracked block whose scrollback content happens to
                            // contain the 24-char sentinel is NOT dropped. The first
                            // non-probe block clears the count, so a probe lost before
                            // the transport attached can't keep the scan armed forever.
                            if (!viewer.isResyncing() and viewer.hasOutstandingResyncProbes()) {
                                if (std.mem.indexOf(u8, block.content, terminal.tmux.Viewer.resync_marker) != null) {
                                    viewer.consumeResyncProbe();
                                    break :tmux;
                                }
                                viewer.clearOutstandingResyncProbes();
                            }
                            switch (viewer.classifyBlock()) {
                                .untracked => break :tmux,
                                .tracked, .empty => {},
                            }
                        } else if (!viewer.isResyncing() and viewer.hasOutstandingResyncProbes()) {
                            viewer.clearOutstandingResyncProbes();
                        }
                    },
                    else => {},
                }

                // ROOTSHELL-TMUX (id=streamhandler-defunct-teardown): set if the
                // viewer emits `.exit` (went defunct on an internal error). We
                // cannot tear down inside the loop — actions alias viewer-owned
                // memory — so we defer it to just after the loop.
                var viewer_defunct = false;
                var viewer_recover = false;
                for (viewer.next(.{ .tmux = tmux })) |action| {
                    // `{f}` would dump payloads (window topology, raw command
                    // bytes, server message text); log only the variant name.
                    log.debug("tmux viewer action={s}", .{@tagName(action)});
                    switch (action) {
                        .exit => {
                            // The viewer went defunct on an INTERNAL error (failed
                            // to process a layout/command, OOM) — distinct from a
                            // clean `%exit` DCS event or a `.broken` parser stream,
                            // both handled above. We CANNOT free the viewer here:
                            // `action` aliases viewer-owned memory we are still
                            // iterating. Defer teardown to after the loop, then tear
                            // down + force-unhook exactly like `.broken` — otherwise
                            // the gateway tab freezes (later output is consumed by the
                            // defunct viewer), tmuxActive() stays true (ESC keeps
                            // sending detach-client into a dead stream), and the
                            // viewer lingers allocated.
                            viewer_defunct = true;
                        },

                        .recover => {
                            viewer_recover = true;
                        },

                        .command => |command| {
                            assert(command.len > 0);
                            assert(command[command.len - 1] == '\n');
                            // ROOTSHELL-TMUX (id=streamhandler-command-tracked):
                            // route through the tracked-command message so the IO
                            // thread records a `.tracked` sent-FIFO marker after
                            // writing (keeps block matching aligned vs untracked
                            // send-keys). The viewer set command_in_flight when it
                            // emitted this `.command`; roll it back if the write
                            // fails so the pump doesn't wedge (id=viewer-rollback-in-flight).
                            if (!self.writeTrackedTmuxCommand(command)) {
                                viewer.rollbackInFlightCommand();
                            }
                        },

                        .windows => |windows| {
                            // ROOTSHELL-TMUX (id=streamhandler-windows-empty-guard):
                            // never forward an EMPTY window list as a topology
                            // snapshot. A live tmux session always has >=1 window,
                            // so an empty mid-session list is only ever a desync
                            // artifact or the deliberate `sessionChanged` reset
                            // (which immediately re-runs list-windows; the next
                            // non-empty snapshot prunes stale windows via the diff,
                            // and tmux never reuses window ids across sessions).
                            // Forwarding it would prune EVERY tmux tab and tear
                            // down the app's controller while tmux is still alive
                            // (gateway stuck, ESC dead). Genuine teardown prunes
                            // via the separate `sendEmptyTopologySnapshot()` on the
                            // `.exit` path, which is unaffected.
                            if (windows.len == 0) continue;

                            // Deep-copy the window topology and forward it to
                            // the app thread via the surface mailbox. The app
                            // thread will reconcile tmux windows/panes into
                            // apprt surfaces.
                            //
                            // The viewer already maintains the authoritative
                            // window list; this handler forwards the topology
                            // so the app thread can diff and create/destroy
                            // surfaces.
                            for (windows) |window| {
                                log.debug("tmux window id={} size={}x{}", .{
                                    window.id,
                                    window.width,
                                    window.height,
                                });
                                logPaneIds(window.layout);
                            }

                            const snapshot = apprt.surface.Message.TmuxTopologySnapshot.initFromWindows(
                                self.alloc,
                                windows,
                                &viewer.panes,
                                &viewer.pane_titles, // ROOTSHELL-TMUX (id=snapshot-feed-pane-titles)
                            ) catch |err| {
                                log.warn("failed to snapshot tmux topology: {}", .{err});
                                continue;
                            };
                            self.surfaceMessageWriter(.{ .tmux_topology_changed = snapshot });
                        },

                        .focus => |focus| {
                            // Forward focus change to the parent surface's
                            // mailbox so the app thread can update which tab
                            // and pane has focus.
                            //
                            // Lightweight value message — no heap allocation
                            // needed, just two IDs.
                            self.surfaceMessageWriter(.{
                                .tmux_focus_changed = .{
                                    .window_id = focus.window_id,
                                    .pane_id = focus.pane_id,
                                },
                            });
                        },

                        .title => |t| {
                            // Forward window rename to the app thread so it
                            // can update the tab title.
                            self.surfaceMessageWriter(.{
                                .tmux_title_changed = apprt.surface.Message.TmuxTitleChanged.init(
                                    t.window_id,
                                    t.name,
                                ),
                            });
                        },

                        .session_title => |st| {
                            // Forward session rename to the app thread so it
                            // can update the Ghostty window title.
                            self.surfaceMessageWriter(.{
                                .tmux_title_changed = apprt.surface.Message.TmuxTitleChanged.init(
                                    null,
                                    st.name,
                                ),
                            });
                        },

                        .pane_paused => |pp| {
                            // Log the pause state change at info level so it's
                            // visible in ReleaseFast (log_level = .info): a
                            // %pause over a backgrounded/slow link is the signal
                            // that tmux discarded a pane's output, which the
                            // viewer recovers via re-capture (id=pause-after-recover).
                            log.info("tmux pane {} {s}", .{
                                pp.pane_id,
                                if (pp.paused) "paused" else "continued",
                            });
                        },

                        .pane_mode_changed => |pm| {
                            // Log the mode change. Visual indicators
                            // (e.g., copy mode overlay) will be added in
                            // a follow-up PR.
                            log.debug("tmux pane {} mode changed to {s}", .{
                                pm.pane_id,
                                @tagName(pm.mode),
                            });
                        },

                        .message => |msg| {
                            // Log the tmux server message. Runtime visual
                            // feedback (toast, status bar) will be added in
                            // a follow-up PR.
                            log.info("tmux message: {s}", .{msg.text});
                        },

                        .command_response => |cr| {
                            // Deliver an app query's response across the
                            // surface mailbox (heap pointer — bodies can be
                            // large, e.g. list-windows -a). On alloc failure
                            // the app-side timeout is the backstop.
                            // ROOTSHELL-TMUX (id=streamhandler-query-command)
                            const resp = apprt.surface.Message.TmuxCommandResponse.create(
                                self.alloc,
                                cr.tag,
                                cr.body,
                                cr.is_err,
                            ) catch |err| {
                                log.warn("failed to allocate tmux command response tag={} err={}", .{ cr.tag, err });
                                continue;
                            };
                            self.surfaceMessageWriter(.{ .tmux_command_response = resp });
                        },

                        .sessions_changed => {
                            // Session list churn (create/destroy/other-client
                            // attach/detach/switch): nudge the app to refresh
                            // any session dashboard. ROOTSHELL-TMUX
                            // (id=viewer-sessions-changed)
                            self.surfaceMessageWriter(.{ .tmux_sessions_changed = {} });
                        },

                        .session_info => |si| {
                            // Attached-session identity (startup / switch /
                            // rename) for dashboard state + reconnect-by-name
                            // persistence. ROOTSHELL-TMUX (id=viewer-session-info)
                            self.surfaceMessageWriter(.{
                                .tmux_session_info = apprt.surface.Message.TmuxSessionInfo.init(
                                    si.id,
                                    si.name,
                                ),
                            });
                        },

                        .pane_clipboard_write => |cw| {
                            // A pane inside tmux -CC emitted OSC 52. tmux never
                            // forwards the clipboard to a control client (no tty),
                            // so the viewer captured the raw bytes; route them to
                            // the system clipboard via the SAME surface message the
                            // normal (non-tmux) OSC 52 path uses (see
                            // `clipboardContents`). The base64 stays encoded —
                            // `Surface.clipboardWrite` decodes it. ROOTSHELL-TMUX
                            // (id=streamhandler-pane-clipboard)
                            const clipboard_type: apprt.Clipboard = switch (cw.kind) {
                                'c' => .standard,
                                's' => .selection,
                                'p' => .primary,
                                else => .standard,
                            };
                            const req = apprt.surface.Message.WriteReq.init(
                                self.alloc,
                                cw.data,
                            ) catch |err| {
                                log.warn("failed to allocate tmux clipboard write req err={}", .{err});
                                continue;
                            };
                            self.surfaceMessageWriter(.{ .clipboard_write = .{
                                .req = req,
                                .clipboard_type = clipboard_type,
                            } });
                        },
                    }
                }

                // Now that the action loop is done (no more aliasing of viewer
                // memory), tear down a viewer that went defunct mid-batch. Mirrors
                // the `.broken` path so an internal viewer failure recovers exactly
                // like a clean exit instead of freezing the gateway.
                // ROOTSHELL-TMUX (id=streamhandler-defunct-teardown)
                if (viewer_defunct) {
                    log.warn("tmux viewer went defunct; tearing down gateway", .{});
                    self.tmuxTeardownViewer();
                    self.tmux_force_unhook = true;
                } else if (viewer_recover) {
                    self.tmuxForceResync();
                }
            },

            .xtgettcap => |*gettcap| {
                // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
                if (self.suppressPtyReportForTmuxGateway("XTGETTCAP")) return;
                const map = comptime terminfo.ghostty.xtgettcapMap();
                while (gettcap.next()) |key| {
                    const response = map.get(key) orelse continue;
                    self.messageWriter(.{ .write_stable = response });
                }
            },

            .decrqss => |decrqss| {
                // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
                if (self.suppressPtyReportForTmuxGateway("DECRQSS")) return;
                var response: [terminal.dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
                const encoded = try decrqss.encode(self.terminal, &response);
                const msg = try termio.Message.writeReq(
                    self.alloc,
                    encoded,
                );
                self.messageWriter(msg);
            },
        }
    }

    pub fn apcEnd(self: *StreamHandler) !void {
        var result = self.apc.end() orelse return;
        defer result.deinit(self.alloc);

        // log.warn("APC command: {}", .{result});
        switch (result) {
            .unknown => return,
            .kitty => |*kitty_cmd| {
                // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
                if (self.suppressPtyReportForTmuxGateway("kitty graphics")) return;
                if (self.terminal.kittyGraphics(global.io(), self.alloc, kitty_cmd)) |resp| {
                    var buf: [1024]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try resp.encode(&writer);
                    const final = writer.buffered();
                    if (final.len > 2) {
                        log.debug("kitty graphics response: {x}", .{final});
                        self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                    }
                }
            },

            .glyph => |*glyph_req| {
                const resp = self.terminal.glyphProtocol(self.alloc, glyph_req);
                switch (glyph_req.*) {
                    .register, .clear => try self.queueRender(),
                    .support, .query => {},
                }

                if (resp) |r| {
                    var buf: [terminal.apc.glyph.Response.max_wire_bytes]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try r.formatWire(&writer);
                    const final = writer.buffered();
                    log.debug("glyph protocol response: {x}", .{final});
                    self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                }
            },
        }
    }

    inline fn bell(self: *StreamHandler) void {
        self.surfaceMessageWriter(.ring_bell);
    }

    inline fn horizontalTab(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn horizontalTabBack(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn linefeed(self: *StreamHandler) !void {
        // Small optimization: call index instead of linefeed because they're
        // identical and this avoids one layer of function call overhead.
        try self.terminal.index();
    }

    /// Print a minimal control-mode menu into the gateway terminal (the surface
    /// running `tmux -CC`). Gives the user a discoverable, in-TUI way to leave
    /// control mode: Swift intercepts ESC on the gateway view and sends
    /// `detach-client`. Called once from the tmux `.enter` dispatch.
    /// ROOTSHELL-TMUX (id=streamhandler-gateway-menu).
    fn printTmuxGatewayMenu(self: *StreamHandler) !void {
        try self.nextLine();
        try self.terminal.printString("[ rootshell tmux control mode ]");
        try self.nextLine();
        try self.terminal.printString("Press ESC to detach.");
        try self.nextLine();
    }

    pub inline fn reverseIndex(self: *StreamHandler) !void {
        self.terminal.reverseIndex();
    }

    pub inline fn index(self: *StreamHandler) !void {
        try self.terminal.index();
    }

    pub inline fn nextLine(self: *StreamHandler) !void {
        try self.terminal.index();
        self.terminal.carriageReturn();
    }

    pub fn setModifyKeyFormat(self: *StreamHandler, format: terminal.ModifyKeyFormat) !void {
        self.terminal.flags.modify_other_keys_2 = false;
        switch (format) {
            .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
            else => {},
        }
    }

    fn requestMode(self: *StreamHandler, mode: terminal.Mode) !void {
        self.sendModeReport(self.terminal.modes.getReport(.fromMode(mode)));
    }

    fn requestModeUnknown(self: *StreamHandler, mode_raw: u16, ansi: bool) !void {
        self.sendModeReport(self.terminal.modes.getReport(.{ .value = @truncate(mode_raw), .ansi = ansi }));
    }

    fn sendModeReport(self: *StreamHandler, report: terminal.modes.Report) void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("mode")) return;
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        report.encode(&writer) catch |err| {
            log.err("error encoding mode report err={}", .{err});
            return;
        };
        self.messageWriter(.{ .write_small = .{
            .data = data,
            .len = @intCast(writer.buffered().len),
        } });
    }

    pub fn setMode(self: *StreamHandler, mode: terminal.Mode, enabled: bool) !void {
        // Note: this function doesn't need to grab the render state or
        // terminal locks because it is only called from process() which
        // grabs the lock.

        // If we are setting cursor blinking, we ignore it if we have
        // a default cursor blink setting set. This is a really weird
        // behavior so this comment will go deep into trying to explain it.
        //
        // There are two ways to set cursor blinks: DECSCUSR (CSI _ q)
        // and DEC mode 12. DECSCUSR is the modern approach and has a
        // way to revert to the "default" (as defined by the terminal)
        // cursor style and blink by doing "CSI 0 q". DEC mode 12 controls
        // blinking and is either on or off and has no way to set a
        // default. DEC mode 12 is also the more antiquated approach.
        //
        // The problem is that if the user specifies a desired default
        // cursor blink with `cursor-style-blink`, the moment a running
        // program uses DEC mode 12, the cursor blink can never be reset
        // to the default without an explicit DECSCUSR. But if a program
        // is using mode 12, it is by definition not using DECSCUSR.
        // This makes for somewhat annoying interactions where a poorly
        // (or legacy) behaved program will stop blinking, and it simply
        // never restarts.
        //
        // To get around this, we have a special case where if the user
        // specifies some explicit default cursor blink desire, we ignore
        // DEC mode 12. We allow DECSCUSR to still set the cursor blink
        // because programs using DECSCUSR usually are well behaved and
        // reset the cursor blink to the default when they exit.
        //
        // To be extra safe, users can also add a manual `CSI 0 q` to
        // their shell config when they render prompts to ensure the
        // cursor is exactly as they request.
        if (mode == .cursor_blinking and
            self.terminal.cursor.default_blink != null)
        {
            return;
        }

        // We first always set the raw mode on our mode state.
        self.terminal.modes.set(mode, enabled);

        // And then some modes require additional processing.
        switch (mode) {
            // Just noting here that autorepeat has no effect on
            // the terminal. xterm ignores this mode and so do we.
            // We know about just so that we don't log that it is
            // an unknown mode.
            .autorepeat => {},

            // Schedule a render since we changed colors
            .reverse_colors => self.terminal.flags.dirty.reverse_colors = true,

            // Origin resets cursor pos. This is called whether or not
            // we're enabling or disabling origin mode and whether or
            // not the value changed.
            .origin => self.terminal.setCursorPos(1, 1),

            .enable_left_and_right_margin => if (!enabled) {
                // When we disable left/right margin mode we need to
                // reset the left/right margins.
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },

            .alt_screen_legacy => {
                try self.terminal.switchScreenMode(.@"47", enabled);
            },

            .alt_screen => {
                try self.terminal.switchScreenMode(.@"1047", enabled);
            },

            .alt_screen_save_cursor_clear_enter => {
                try self.terminal.switchScreenMode(.@"1049", enabled);
            },

            // Mode 1048 is xterm's conditional save cursor depending
            // on if alt screen is enabled or not (at the terminal emulator
            // level). Alt screen is always enabled for us so this just
            // does a save/restore cursor.
            .save_cursor => {
                if (enabled) {
                    self.terminal.saveCursor();
                } else {
                    self.terminal.restoreCursor();
                }
            },

            // Force resize back to the window size
            .enable_mode_3 => {
                const grid_size = self.size.grid();
                self.terminal.resize(
                    self.alloc,
                    .{
                        .cols = grid_size.columns,
                        .rows = grid_size.rows,
                    },
                ) catch |err| {
                    log.err("error updating terminal size: {}", .{err});
                };
            },

            .@"132_column" => try self.terminal.deccolm(
                self.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            // We need to start a timer to prevent the emulator being hung
            // forever.
            .synchronized_output => {
                if (enabled) self.messageWriter(.{ .start_synchronized_output = {} });
            },

            .linefeed => {
                self.messageWriter(.{ .linefeed_mode = enabled });
            },

            // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
            .in_band_size_reports => if (enabled and
                !self.suppressPtyReportForTmuxGateway("in-band size"))
            {
                self.emitSizeReport(.mode_2048);
            },

            // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
            .report_visibility => if (enabled and
                !self.suppressPtyReportForTmuxGateway("visibility"))
            {
                self.messageWriter(.{
                    .visibility_report = .{
                        .visible = self.terminal.flags.visible,
                        .force = true,
                    },
                });
            },

            .focus_event => if (enabled and
                !self.suppressPtyReportForTmuxGateway("focus"))
            {
                self.messageWriter(.{ .focused = self.terminal.flags.focused });
            },

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },

            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,

            else => {},
        }
    }

    inline fn startHyperlink(self: *StreamHandler, uri: []const u8, id: ?[]const u8) !void {
        try self.terminal.screens.active.startHyperlink(uri, id);
    }

    pub inline fn endHyperlink(self: *StreamHandler) !void {
        self.terminal.screens.active.endHyperlink();
    }

    pub fn deviceAttributes(
        self: *StreamHandler,
        req: terminal.DeviceAttributeReq,
    ) !void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("device attributes")) return;
        // For the below, we quack as a VT220. We don't quack as
        // a 420 because we don't support DCS sequences.
        switch (req) {
            .primary => self.messageWriter(.{
                // 62 = Level 2 conformance
                // 22 = Color text
                // 52 = Clipboard access
                .write_stable = if (self.clipboard_write != .deny)
                    "\x1B[?62;22;52c"
                else
                    "\x1B[?62;22c",
            }),

            .secondary => self.messageWriter(.{
                .write_stable = "\x1B[>1;10;0c",
            }),

            else => log.warn("unimplemented device attributes req: {}", .{req}),
        }
    }

    pub fn deviceStatusReport(
        self: *StreamHandler,
        req: terminal.device_status.Request,
    ) !void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("device status")) return;
        switch (req) {
            .operating_status => self.messageWriter(.{ .write_stable = "\x1B[0n" }),

            .cursor_position => {
                const pos: struct {
                    x: usize,
                    y: usize,
                } = if (self.terminal.modes.get(.origin)) .{
                    .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
                    .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
                } else .{
                    .x = self.terminal.screens.active.cursor.x,
                    .y = self.terminal.screens.active.cursor.y,
                };

                // Response always is at least 4 chars, so this leaves the
                // remainder for the row/column as base-10 numbers. This
                // will support a very large terminal.
                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.fmt.bufPrint(&msg.write_small.data, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);

                self.messageWriter(msg);
            },

            // (suppress-gateway + mode check live inside sendColorSchemeReport)
            .color_scheme => self.sendColorSchemeReport(true),

            // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): the
            // gateway must not answer queries tmux answers for the client.
            .visibility => if (!self.suppressPtyReportForTmuxGateway("visibility")) {
                self.messageWriter(.{ .visibility_report = .{
                    .visible = self.terminal.flags.visible,
                    .force = true,
                } });
            },
        }
    }

    pub inline fn decaln(self: *StreamHandler) !void {
        try self.terminal.decaln();
    }

    pub inline fn saveCursor(self: *StreamHandler) !void {
        self.terminal.saveCursor();
    }

    pub inline fn restoreCursor(self: *StreamHandler) !void {
        self.terminal.restoreCursor();
    }

    pub fn enquiry(self: *StreamHandler) !void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("enquiry")) return;
        log.debug("sending enquiry response={s}", .{self.enquiry_response});
        self.messageWriter(try termio.Message.writeReq(self.alloc, self.enquiry_response));
    }

    fn configureCharset(
        self: *StreamHandler,
        slot: terminal.CharsetSlot,
        set: terminal.Charset,
    ) void {
        self.terminal.configureCharset(slot, set);
    }

    pub fn fullReset(
        self: *StreamHandler,
    ) !void {
        self.terminal.fullReset();
        try self.setMouseShape(.text);

        // Reset resets our palette so we report it for mode 2031.
        // (suppress-gateway + mode check live inside sendColorSchemeReport)
        self.sendColorSchemeReport(false);

        // Clear the progress bar
        self.progressReport(.{ .state = .remove });
    }

    pub fn queryKittyKeyboard(self: *StreamHandler) !void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("kitty keyboard")) return;
        log.debug("querying kitty keyboard mode", .{});
        var data: termio.Message.WriteReq.Small.Array = undefined;
        const resp = try std.fmt.bufPrint(&data, "\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        });

        self.messageWriter(.{
            .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            },
        });
    }

    pub fn reportXtversion(
        self: *StreamHandler,
    ) !void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("XTVERSION")) return;
        log.debug("reporting XTVERSION: ghostty {s}", .{build_config.version_string});
        var buf: [288]u8 = undefined;
        const resp = try std.fmt.bufPrint(
            &buf,
            "\x1BP>|{s} {s}\x1B\\",
            .{
                "ghostty",
                build_config.version_string,
            },
        );
        const msg = try termio.Message.writeReq(self.alloc, resp);
        self.messageWriter(msg);
    }

    //-------------------------------------------------------------------------
    // OSC

    fn windowTitle(self: *StreamHandler, title: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (title.len >= buf.len) {
            log.warn("change title requested larger than our buffer size, ignoring", .{});
            return;
        }

        // Set the title on the terminal state. We ignore any errors since
        // we can continue to operate just fine without it.
        self.terminal.setTitle(title) catch |err| {
            log.warn("error setting title in terminal state: {}", .{err});
        };

        @memcpy(buf[0..title.len], title);
        buf[title.len] = 0;

        // Special handling for the empty title. We treat the empty title
        // as resetting to as if we never saw a title. Other terminals
        // behave this way too (e.g. iTerm2).
        if (title.len == 0) {
            // If we have a pwd then we set the title as the pwd else
            // we just set it to blank.
            if (self.terminal.getPwd()) |pwd| pwd: {
                if (pwd.len >= buf.len) break :pwd;
                @memcpy(buf[0..pwd.len], pwd);
                buf[pwd.len] = 0;
            }

            self.surfaceMessageWriter(.{ .set_title = buf });
            self.seen_title = false;
            return;
        }

        self.seen_title = true;
        self.surfaceMessageWriter(.{ .set_title = buf });
    }

    inline fn setMouseShape(
        self: *StreamHandler,
        shape: terminal.MouseShape,
    ) !void {
        // Avoid changing the shape if it is already set to avoid excess
        // cross-thread messaging.
        if (self.terminal.mouse_shape == shape) return;

        self.terminal.mouse_shape = shape;
        self.surfaceMessageWriter(.{ .set_mouse_shape = shape });
    }

    fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        // Note: we ignore the "kind" field and always use the standard clipboard.
        // iTerm also appears to do this but other terminals seem to only allow
        // certain. Let's investigate more.

        const clipboard_type: apprt.Clipboard = switch (kind) {
            'c' => .standard,
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };

        // Get clipboard contents
        if (data.len == 1 and data[0] == '?') {
            self.surfaceMessageWriter(.{ .clipboard_read = clipboard_type });
            return;
        }

        // Write clipboard contents
        self.surfaceMessageWriter(.{
            .clipboard_write = .{
                .req = try apprt.surface.Message.WriteReq.init(
                    self.alloc,
                    data,
                ),
                .clipboard_type = clipboard_type,
            },
        });
    }

    fn semanticPrompt(
        self: *StreamHandler,
        cmd: Stream.Action.SemanticPrompt,
    ) !void {
        switch (cmd.action) {
            .end_input_start_output => {
                self.surfaceMessageWriter(.start_command);
            },

            .end_command => {
                // The specification seems to not specify the type but
                // other terminals accept 32-bits, but exit codes are really
                // bytes, so we just do our best here.
                const code: u8 = code: {
                    const raw: i32 = cmd.readOption(.exit_code) orelse 0;
                    break :code std.math.cast(u8, raw) orelse 1;
                };

                self.surfaceMessageWriter(.{ .stop_command = code });
            },

            // Handled by Terminal, no special handling by us
            .end_prompt_start_input,
            .end_prompt_start_input_terminate_eol,
            .fresh_line,
            .fresh_line_new_prompt,
            .new_command,
            .prompt_start,
            => {},
        }

        // We do this last so failures are still processed correctly
        // above.
        try self.terminal.semanticPrompt(cmd);
    }

    fn reportPwd(self: *StreamHandler, url: []const u8) !void {
        // Special handling for the empty URL. We treat the empty URL
        // as resetting the pwd as if we never saw a pwd. I can't find any
        // other terminal that does this but it seems like a reasonable
        // behavior that enables some useful features. For example, the macOS
        // proxy icon can be hidden when a program reports it doesn't know
        // the pwd rather than showing a stale pwd.
        if (url.len == 0) {
            // Blank value can never fail because no allocs happen.
            self.terminal.setPwd("") catch unreachable;

            // If we haven't seen a title, we're using the pwd as our title.
            // Set it to blank which will reset our title behavior.
            if (!self.seen_title) {
                try self.windowTitle("");
                assert(!self.seen_title);
            }

            // Report the change.
            self.surfaceMessageWriter(.{ .pwd_change = .{ .stable = "" } });
            return;
        }

        if (builtin.os.tag == .windows) {
            log.warn("reportPwd unimplemented on windows", .{});
            return;
        }

        // Attempt to parse this file-style URI using options appropriate
        // for this OSC 7 context (e.g. kitty-shell-cwd expects the full,
        // unencoded path).
        const uri: std.Uri = internal_os.uri.parse(url, .{
            .mac_address = comptime builtin.os.tag != .macos,
            .raw_path = std.mem.startsWith(u8, url, "kitty-shell-cwd://"),
        }) catch |e| {
            log.warn("invalid url in OSC 7: {}", .{e});
            return;
        };

        if (!std.mem.eql(u8, "file", uri.scheme) and
            !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme))
        {
            log.warn("OSC 7 scheme must be file or kitty-shell-cwd, got: {s}", .{uri.scheme});
            return;
        }

        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buffer) catch |err| switch (err) {
            error.UriMissingHost => {
                log.warn("OSC 7 uri must contain a hostname: {}", .{err});
                return;
            },
        };

        // OSC 7 is a little sketchy because anyone can send any value from
        // any host (such an SSH session). The best practice terminals follow
        // is to valid the hostname to be local.
        const host_valid = internal_os.hostname.isLocal(host.bytes) catch |err| switch (err) {
            error.PermissionDenied,
            error.Unexpected,
            => {
                log.warn("failed to get hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };
        if (!host_valid) {
            log.warn("OSC 7 host ({s}) must be local", .{host.bytes});
            return;
        }

        // We need the raw path, which might require unescaping. We try to
        // avoid making any heap allocations by using the stack first.
        var arena_alloc: std.heap.ArenaAllocator = .init(self.alloc);
        var stack_alloc = std.heap.stackFallback(1024, arena_alloc.allocator());
        defer arena_alloc.deinit();
        const path = try uri.path.toRawMaybeAlloc(stack_alloc.get());

        log.debug("terminal pwd: {s}", .{path});
        try self.terminal.setPwd(path);

        // Report it to the surface. If creating our write request fails
        // then we just ignore it.
        if (apprt.surface.Message.WriteReq.init(self.alloc, path)) |req| {
            self.surfaceMessageWriter(.{ .pwd_change = req });
        } else |err| {
            log.warn("error notifying surface of pwd change err={}", .{err});
        }

        // If we haven't seen a title, use our pwd as the title.
        if (!self.seen_title) {
            try self.windowTitle(path);
            self.seen_title = false;
        }
    }

    fn colorOperation(
        self: *StreamHandler,
        op: terminal.osc.color.Operation,
        requests: *const terminal.osc.color.List,
        terminator: terminal.osc.Terminator,
    ) !void {
        // We'll need op one day if we ever implement reporting special colors.
        _ = op;

        // return early if there is nothing to do
        if (requests.count() == 0) return;

        var buffer: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        const alloc = fba.allocator();

        var response: std.Io.Writer.Allocating = .init(alloc);

        var it = requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .set => |set| {
                    switch (set.target) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.set(i, set.color);
                        },
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.set(set.color),
                            .background => self.terminal.colors.background.set(set.color),
                            .cursor => self.terminal.colors.cursor.set(set.color),
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => log.info("setting dynamic color {s} not implemented", .{
                                @tagName(dynamic),
                            }),
                        },
                        .special => log.info("setting special colors not implemented", .{}),
                    }

                    // Notify the surface of the color change
                    self.surfaceMessageWriter(.{ .color_change = .{
                        .target = set.target,
                        .color = set.color,
                    } });
                },

                .reset => |target| switch (target) {
                    .palette => |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(i);

                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = target,
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    },
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => {
                            self.terminal.colors.foreground.reset();

                            if (self.terminal.colors.foreground.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .background => {
                            self.terminal.colors.background.reset();

                            if (self.terminal.colors.background.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .cursor => {
                            self.terminal.colors.cursor.reset();

                            if (self.terminal.colors.cursor.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .pointer_foreground,
                        .pointer_background,
                        .tektronix_foreground,
                        .tektronix_background,
                        .highlight_background,
                        .tektronix_cursor,
                        .highlight_foreground,
                        => log.warn("resetting dynamic color {s} not implemented", .{
                            @tagName(dynamic),
                        }),
                    },
                    .special => log.info("resetting special colors not implemented", .{}),
                },

                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = .{ .palette = @intCast(i) },
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    }
                    mask.* = .initEmpty();
                },

                .reset_special => log.warn(
                    "resetting all special colors not implemented",
                    .{},
                ),

                .query => |kind| report: {
                    if (self.osc_color_report_format == .none) break :report;
                    // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
                    if (self.suppressPtyReportForTmuxGateway("OSC color")) break :report;

                    const color = switch (kind) {
                        .palette => |i| self.terminal.colors.palette.current[i],
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.get().?,
                            .background => self.terminal.colors.background.get().?,
                            .cursor => self.terminal.colors.cursor.get() orelse
                                self.terminal.colors.foreground.get().?,
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {
                                log.info(
                                    "reporting dynamic color {s} not implemented",
                                    .{@tagName(dynamic)},
                                );
                                break :report;
                            },
                        },
                        .special => {
                            log.info("reporting special colors not implemented", .{});
                            break :report;
                        },
                    };

                    switch (self.osc_color_report_format) {
                        .@"16-bit" => switch (kind) {
                            .palette => |i| try response.writer.print(
                                "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    i,
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .dynamic => |dynamic| try response.writer.print(
                                "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    @intFromEnum(dynamic),
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .special => unreachable,
                        },

                        .@"8-bit" => switch (kind) {
                            .palette => |i| try response.writer.print(
                                "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    i,
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .dynamic => |dynamic| try response.writer.print(
                                "\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    @intFromEnum(dynamic),
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .special => unreachable,
                        },

                        .none => unreachable,
                    }

                    try response.writer.writeAll(terminator.string());
                },
            }
        }

        if (response.writer.end > 0) {
            // If any of the operations were reports, finalize the report
            // string and send it to the terminal.
            const msg = try termio.Message.writeReq(self.alloc, response.writer.buffered());
            self.messageWriter(msg);
        }
    }

    fn showDesktopNotification(
        self: *StreamHandler,
        title: []const u8,
        body: []const u8,
    ) !void {
        self.surfaceMessageWriter(.{
            .desktop_notification = .init(title, body),
        });
    }

    /// Answer the CSI ?996n / mode-2031 color-scheme query INLINE on the read
    /// thread. We already hold renderer_state.mutex while parsing, so the mode
    /// check + cached theme are free here, and the reply goes out as a plain
    /// `write_stable` (static string, no alloc) that drainMailbox can flush
    /// WITHOUT re-acquiring renderer_state.mutex. Routing this through a
    /// `color_scheme_report` message instead made the IO thread re-lock — which
    /// the read thread starves under a heavy-output flood (zellij), wedging the
    /// drain for seconds and dropping write_small. (id=streamhandler-inline-reports)
    fn sendColorSchemeReport(self: *StreamHandler, force: bool) void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("color scheme")) return;
        if (!force and !self.terminal.modes.get(.report_color_scheme)) return;
        const output: []const u8 = if (self.color_scheme_is_dark)
            "\x1B[?997;1n"
        else
            "\x1B[?997;2n";
        self.messageWriter(.{ .write_stable = output });
    }

    /// Encode a size report INLINE (self.size is consistent under the renderer
    /// lock we hold while parsing) and send it as a plain write, so the IO
    /// thread never has to re-acquire renderer_state.mutex to answer it. Same
    /// flood-starvation rationale as sendColorSchemeReport.
    fn emitSizeReport(self: *StreamHandler, style: terminal.size_report.Style) void {
        const grid_size = self.size.grid();
        const report_size: terminal.size_report.Size = .{
            .rows = grid_size.rows,
            .columns = grid_size.columns,
            .cell_width = self.size.cell.width,
            .cell_height = self.size.cell.height,
        };
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminal.size_report.encode(&writer, style, report_size) catch return;
        const msg = termio.Message.writeReq(self.alloc, writer.buffered()) catch |err| {
            log.warn("failed to build size report: {}", .{err});
            return;
        };
        self.messageWriter(msg);
    }

    /// Send a report to the pty.
    pub fn sendSizeReport(self: *StreamHandler, style: terminal.SizeReportStyle) void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("size")) return;
        switch (style) {
            .csi_14_t => self.emitSizeReport(.csi_14_t),
            .csi_16_t => self.emitSizeReport(.csi_16_t),
            .csi_18_t => self.emitSizeReport(.csi_18_t),
            .csi_21_t => self.surfaceMessageWriter(.{ .report_title = .csi_21_t }),
        }
    }

    fn kittyColorReport(
        self: *StreamHandler,
        request: terminal.kitty.color.OSC,
    ) !void {
        // ROOTSHELL-TMUX (id=streamhandler-suppress-gateway-reports): drop report-generating replies on the tmux gateway.
        if (self.suppressPtyReportForTmuxGateway("kitty color")) return;
        var stream: std.Io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();
        const writer = &stream.writer;

        for (request.list.items) |item| {
            switch (item) {
                .query => |key| {
                    // If the writer buffer is empty, we need to write our prefix
                    if (stream.written().len == 0) try writer.writeAll("\x1b]21");

                    const color: terminal.color.RGB = switch (key) {
                        .palette => |palette| self.terminal.colors.palette.current[palette],
                        .special => |special| switch (special) {
                            .foreground => self.terminal.colors.foreground.get(),
                            .background => self.terminal.colors.background.get(),
                            .cursor => self.terminal.colors.cursor.get(),
                            else => {
                                log.warn("ignoring unsupported kitty color protocol key: {f}", .{key});
                                continue;
                            },
                        },
                    } orelse {
                        try writer.print(";{f}=", .{key});
                        continue;
                    };

                    try writer.print(
                        ";{f}=rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                        .{ key, color.r, color.g, color.b },
                    );
                },
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },

                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{v.key},
                            );
                            continue;
                        },
                    },
                },
                .reset => |key| switch (key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(palette);
                    },

                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{key},
                            );
                            continue;
                        },
                    },
                },
            }
        }

        // If we had any writes to our buffer, we queue them now
        if (stream.written().len > 0) {
            try writer.writeAll(request.terminator.string());
            self.messageWriter(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = try stream.toOwnedSlice(),
                },
            });
        }

        // Note: we don't have to do a queueRender here because every
        // processed stream will queue a render once it is done processing
        // the read() syscall.
    }

    /// Display a GUI progress report.
    fn progressReport(self: *StreamHandler, report: terminal.osc.Command.ProgressReport) void {
        self.surfaceMessageWriter(.{ .progress_report = report });
    }

    /// Log pane IDs from a tmux layout tree. Walks the tree recursively
    /// to find all leaf panes so we can observe the topology in logs.
    fn logPaneIds(layout: terminal.tmux.Layout) void {
        switch (layout.content) {
            .pane => |pane_id| {
                log.debug("tmux pane id={} pos={}x{}+{}+{}", .{
                    pane_id,
                    layout.width,
                    layout.height,
                    layout.x,
                    layout.y,
                });
            },
            .horizontal => |children| {
                for (children) |child| logPaneIds(child);
            },
            .vertical => |children| {
                for (children) |child| logPaneIds(child);
            },
        }
    }

    test "logPaneIds walks single leaf pane" {
        // Base case: a single pane with no children. Verifies
        // the function handles leaf nodes without crashing.
        const layout: terminal.tmux.Layout = .{
            .width = 80,
            .height = 24,
            .x = 0,
            .y = 0,
            .content = .{ .pane = 1 },
        };
        logPaneIds(layout);
    }

    test "logPaneIds walks horizontal split" {
        // Two panes in a horizontal split. Verifies recursion
        // into .horizontal children.
        const children = [_]terminal.tmux.Layout{
            .{
                .width = 40,
                .height = 24,
                .x = 0,
                .y = 0,
                .content = .{ .pane = 1 },
            },
            .{
                .width = 40,
                .height = 24,
                .x = 40,
                .y = 0,
                .content = .{ .pane = 2 },
            },
        };
        const layout: terminal.tmux.Layout = .{
            .width = 80,
            .height = 24,
            .x = 0,
            .y = 0,
            .content = .{ .horizontal = &children },
        };
        logPaneIds(layout);
    }

    test "logPaneIds walks nested layout tree" {
        // A horizontal split where the right child is a vertical
        // split of two panes. Exercises deeper recursion.
        const right_children = [_]terminal.tmux.Layout{
            .{
                .width = 40,
                .height = 12,
                .x = 40,
                .y = 0,
                .content = .{ .pane = 2 },
            },
            .{
                .width = 40,
                .height = 12,
                .x = 40,
                .y = 12,
                .content = .{ .pane = 3 },
            },
        };
        const children = [_]terminal.tmux.Layout{
            .{
                .width = 40,
                .height = 24,
                .x = 0,
                .y = 0,
                .content = .{ .pane = 1 },
            },
            .{
                .width = 40,
                .height = 24,
                .x = 40,
                .y = 0,
                .content = .{ .vertical = &right_children },
            },
        };
        const layout: terminal.tmux.Layout = .{
            .width = 80,
            .height = 24,
            .x = 0,
            .y = 0,
            .content = .{ .horizontal = &children },
        };
        logPaneIds(layout);
    }
};
