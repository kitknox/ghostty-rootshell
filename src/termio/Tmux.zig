//! Tmux implements a termio backend for tmux control mode panes. Unlike the
//! exec backend, this does not spawn a subprocess or allocate a pty. Instead,
//! it routes terminal I/O through a tmux control mode connection that is
//! owned by a parent terminal surface.
//!
//! ROOTSHELL-TMUX: fork-owned file, no upstream equivalent. Carry forward
//! verbatim on rebase. See docs/tmux-control-mode-fork.md.
//!
//! User input (keyboard, paste, etc.) is formatted as tmux `send-keys -H`
//! commands targeting a specific pane, and written to the control connection
//! via the ControlWriter interface. The `ParentWriter` implementation routes
//! commands through the parent terminal's termio mailbox, which writes them
//! to the pty connected to `tmux -CC`. The parent terminal's stream handler
//! is responsible for routing `%output` notifications back to this backend's
//! terminal.
//!
//! This backend's types are always compiled into the backend union so that
//! switch exhaustiveness checks cover it. Actual usage (creating a tmux
//! surface) is gated at call sites by `tmux_control_mode` build option.
//!
//! ## Threading
//!
//! The ControlWriter is invoked on the IO thread of the child surface.
//! The `ParentWriter` implementation posts write requests to the parent's
//! SPSC termio mailbox. See `ParentWriter` doc comments for the full
//! threading contract. `apprt.surface.SurfaceRelayWriter` provides the
//! cross-thread relay path through the app mailbox.
const Tmux = @This();

const std = @import("std");
const global = @import("../global.zig");
const xev = global.xev;
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const apprt = @import("../apprt.zig");

const log = std.log.scoped(.io_tmux);

/// The pane ID this backend is attached to within the tmux session.
/// This is the numeric ID used in tmux's `%`-prefixed pane identifiers
/// (e.g., pane_id 5 corresponds to `%5`).
pane_id: usize,

/// The tmux window ID this pane belongs to. Identification/bookkeeping
/// only: the backend no longer sends `select-window` on focus gain (the
/// app echoes user-initiated focus explicitly — see focusGained).
window_id: usize,

/// Pointer to the viewer-owned terminal for this pane. When set, the
/// renderer's terminal pointer is swapped at `threadEnter` to read
/// directly from the viewer's terminal state rather than the Termio's
/// internal (unused) terminal. This implements Mitchell's single-terminal
/// architecture: the viewer's pane terminals ARE the terminals; child
/// surfaces render from them.
///
/// Upstream anchor: `src/termio/Options.zig:27-30` — "the IO impl is
/// free to change [the terminal pointer] if that is useful (i.e. doing
/// some sort of dual terminal implementation.)"
viewer_terminal: ?*terminal.Terminal,

/// Pointer to the viewer-owned pane for this surface. Used to register
/// the child surface's renderer mutex back to the pane during
/// `threadEnter`, enabling the viewer to acquire the correct mutex when
/// writing to the shared terminal.
viewer_pane: ?*terminal.tmux.Viewer.Pane,

/// The current grid size, tracked locally so we can issue resize
/// commands when the surface dimensions change.
grid_size: renderer.GridSize,

/// The current screen size in pixels.
screen_size: renderer.ScreenSize,

/// The writer used to send commands to the tmux control mode connection.
/// This is an interface so it can be mocked in tests and swapped for a
/// real implementation (see `ParentWriter`) when wired to the parent
/// terminal.
control_writer: ControlWriter,

/// Re-exported from `terminal.tmux` for convenience — the canonical
/// definition lives in the core layer (`terminal/tmux_cc/control_writer.zig`).
pub const ControlWriter = terminal.tmux.ControlWriter;

/// A ControlWriter implementation that routes tmux commands through
/// the parent terminal's termio mailbox. This posts a write request
/// into the parent's SPSC mailbox, which the parent's IO thread then
/// writes to the pty (connected to `tmux -CC`).
///
/// ## Threading Contract
///
/// This writer is safe to call from the parent's IO thread (the same
/// thread that runs the stream handler). The `.command` viewer action
/// already writes to the parent termio mailbox from the stream handler
/// via the same `Mailbox.send` path.
///
/// When child surfaces run on their own IO threads, the child does NOT
/// call ParentWriter directly. Instead, the child posts a message
/// through `apprt.surface.Mailbox` (which routes via the app thread),
/// and the parent's surface relays the command into its own termio
/// mailbox. This preserves the SPSC invariant: the parent's IO thread
/// remains the single producer.
///
/// ## Lifetime
///
/// The `mailbox` and `alloc` pointers must remain valid for the
/// lifetime of this writer. In practice, the parent `Termio` owns
/// both and outlives all child surfaces it creates.
///
/// ## References
///
/// - `stream_handler.zig` `.command` handler: uses the same
///   `Mailbox.send` path to write viewer commands to the parent pty.
/// - `mailbox.zig`: SPSC send.
pub const ParentWriter = struct {
    mailbox: *termio.Mailbox,
    alloc: Allocator,

    pub fn controlWriter(self: *ParentWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *ParentWriter = @ptrCast(@alignCast(context));
        const msg = termio.Message.writeReq(self.alloc, data) catch {
            // A dropped control command (select-pane, send-keys, ...) desyncs
            // tmux state silently; make the drop visible.
            log.warn("failed to allocate tmux control command, dropping {} bytes", .{data.len});
            return error.WriteFailed;
        };
        // Pass null for the mutex: this writer is called from the
        // parent's IO thread (see Threading Contract above) which does
        // NOT hold the renderer mutex. The slow-path in Mailbox.send
        // unlocks/relocks the mutex when non-null, which would be
        // undefined behavior on an unlocked mutex.
        self.mailbox.send(msg, null);
        self.mailbox.notify();
    }
};

/// Configuration for the tmux backend.
pub const Config = struct {
    /// The tmux pane ID this surface represents.
    pane_id: usize,

    /// The tmux window ID this pane belongs to.
    window_id: usize,

    /// The writer for sending commands to the tmux control connection.
    control_writer: ControlWriter,

    /// Pointer to the viewer-owned terminal for this pane. When non-null,
    /// the child surface's renderer will read from this terminal instead
    /// of the Termio's internal terminal. See `Tmux.viewer_terminal`.
    viewer_terminal: ?*terminal.Terminal = null,

    /// Pointer to the viewer-owned pane. When non-null, the child surface
    /// registers its renderer mutex to the pane during `threadEnter`.
    /// See `Tmux.viewer_pane`.
    viewer_pane: ?*terminal.tmux.Viewer.Pane = null,
};

/// Initialize the tmux backend. This does NOT start any I/O; it only
/// stores the configuration needed to operate.
pub fn init(cfg: Config) Tmux {
    return .{
        .pane_id = cfg.pane_id,
        .window_id = cfg.window_id,
        .viewer_terminal = cfg.viewer_terminal,
        .viewer_pane = cfg.viewer_pane,
        .grid_size = .{},
        .screen_size = .{ .width = 0, .height = 0 },
        .control_writer = cfg.control_writer,
    };
}

pub fn deinit(self: *Tmux) void {
    self.* = undefined;
}

/// Set initial terminal state for this backend. Called once before
/// any I/O begins. This must NOT perform any I/O — only local state
/// updates. The first resize command to tmux will be sent after
/// threadEnter when the runtime resize path is invoked.
pub fn initTerminal(self: *Tmux, term: *terminal.Terminal) void {
    // Store the initial dimensions locally. We intentionally do NOT
    // call resize() here because that emits a command through the
    // ControlWriter, violating the lifecycle contract: initTerminal
    // runs before threadEnter, so no I/O may occur.
    self.grid_size = .{
        .columns = term.cols,
        .rows = term.rows,
    };
    self.screen_size = .{
        .width = term.width_px,
        .height = term.height_px,
    };
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    log.info("tmux backend thread enter pane_id={}", .{self.pane_id});

    // Register this child surface's renderer mutex and wake callback on the
    // viewer pane FIRST — before publishing the pane terminal to the renderer.
    // ROOTSHELL-TMUX (id=tmux-attach-order): attachRenderer installs
    // `pane.renderer_mutex = io.renderer_state.mutex`; until it runs, the
    // gateway's `pane.lockRenderer()` is a no-op, so the gateway would write the
    // shared pane terminal UNLOCKED. The child's renderer thread is already
    // running (spawned before the IO thread, Surface.zig) and reads
    // `io.renderer_state.terminal` under this same mutex, so swapping the
    // terminal pointer first would open a window where gateway writes race the
    // renderer's reads of the pane terminal (the crash class the detach drain
    // fixed, on the attach side). Attaching first, then swapping under the mutex
    // below, serializes every gateway write of the pane terminal against the
    // renderer. The viewer (parent gateway IO thread) acquires the mutex before
    // writing to the shared terminal and invokes the wake callback after.
    // `Pane.attachRenderer` publishes all of this with release ordering so the
    // gateway never observes a half-built handshake on a weakly-ordered target
    // (see `Pane`'s id=viewer-pane-atomics notes). The wake context
    // `&io.renderer_wakeup` is stable for the lifetime of the child surface's IO
    // and is cleared in threadExit before teardown; the child's own IO thread
    // (this tmux backend) never processes pane output, so without the explicit
    // wake the pane would not repaint until some unrelated event (the source of
    // the "super slow" pane behavior).
    if (self.viewer_pane) |pane| {
        pane.attachRenderer(
            io.renderer_state.mutex,
            @ptrCast(io),
            &wakeRenderer,
            // OSC post context = this child's io, giving postOscEvent access to
            // io.surface_mailbox (+ io.alloc). Cleared by detachRenderer.
            // ROOTSHELL-TMUX (id=viewer-pane-osc)
            @ptrCast(io),
            &postOscEvent,
        );
    }

    // Now publish the viewer's pane terminal to the renderer. This makes the
    // child surface render directly from the viewer-owned terminal, which the
    // parent IO thread feeds via VT output processing. The swap happens under
    // the renderer mutex — which the gateway now also holds when writing, thanks
    // to attachRenderer above — so the renderer transitions atomically from the
    // child's own (empty) terminal to the shared viewer pane terminal with no
    // unlocked-write window.
    if (self.viewer_terminal) |vt| {
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        // occlusionCallback updates whichever terminal is currently published
        // under this same mutex. Copy from the relay terminal before replacing
        // it so a tab switch racing this handoff wins in either ordering.
        vt.flags.visible = io.renderer_state.terminal.flags.visible;
        io.renderer_state.terminal = vt;
    }

    // Populate the thread data with our (empty) thread state.
    td.backend = .{ .tmux = .{} };
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .tmux);
    log.info("tmux backend thread exit pane_id={}", .{self.pane_id});

    // Unregister the renderer mutex and wake callback from the viewer pane so
    // the gateway stops touching memory that's about to be freed with this child
    // surface. `detachRenderer` holds a keep-alive ref across the whole detach,
    // flushes the renderer, clears the handshake, DRAINS any in-flight gateway
    // access (a gateway that loaded the mutex pointer just before the clear), and
    // then releases its hold — which performs the final reap if this pane is an
    // orphan whose viewer is gone. After it returns no gateway or renderer is
    // mid-access of this pane, so the child surface can free its renderer_state
    // (mutex + wake target) without a use-after-free. `pane` may be freed by the
    // call; do not touch it afterward. See id=viewer-renderer-users-drain /
    // id=viewer-detach-hold.
    if (self.viewer_pane) |pane| {
        pane.detachRenderer();
    }
}

/// Wake callback registered on the viewer pane (see `Viewer.Pane.wake_fn`).
/// `ctx` is this child surface's termio. It wakes the renderer and emits one
/// coalesced content edge for this exact tmux pane.
/// Safe to call from the viewer's (parent gateway) IO thread because
/// `xev.Async` is purpose-built for cross-thread notification.
fn wakeRenderer(ctx: ?*anyopaque) void {
    const io: *termio.Termio = @ptrCast(@alignCast(ctx orelse return));
    // Null-tolerant: a concurrent threadExit may have cleared wake_ctx between
    // the gateway's wake_fn load and this call. `Pane.detachRenderer` clears
    // wake_fn before wake_ctx, so the gateway usually skips entirely, but guard
    // here too rather than deref a null/torn context.
    io.renderer_wakeup.notify() catch {};
    io.surface_mailbox.contentChanged();
}

/// Per-pane OSC post callback registered on the viewer pane (see
/// `Viewer.Pane.osc_post_fn`). `ctx` is THIS child surface's `*termio.Termio`,
/// stable for the child IO lifetime like the wake context. Invoked by the viewer
/// (parent gateway) IO thread inside its `lockRenderer` window — the
/// `renderer_users` drain keeps this `io` alive for the call. Builds the matching
/// `apprt.surface.Message` (mirroring `stream_handler.zig`'s
/// `reportPwd`/`showDesktopNotification`/`progressReport`) and posts it to THIS
/// pane surface's mailbox, so the normal `Surface.handleMessage` → `performAction`
/// path attributes progress / pwd / notification to the correct pane — reusing the
/// per-surface handlers with no new action. Borrowed strings are copied into the
/// message synchronously here. ROOTSHELL-TMUX (id=viewer-pane-osc)
/// Reduce an OSC 7 value to a bare path for display in the pane. ROOTSHELL-TMUX
/// (id=viewer-pane-osc): the normal `reportPwd` parses the URL and gates on
/// `isLocal`, but a tmux pane is typically a REMOTE shell (SSH) whose pwd host is
/// never local, so we skip that gate and just strip a leading `file://host` (or
/// `kitty-shell-cwd://host`) to the path. Bare paths and unknown forms pass
/// through unchanged. (Percent-decoding is intentionally skipped — rare in cwd
/// reports; revisit if a path with `%xx` shows up.)
fn pwdPath(raw: []const u8) []const u8 {
    const schemes = [_][]const u8{ "file://", "kitty-shell-cwd://" };
    for (schemes) |scheme| {
        if (std.mem.startsWith(u8, raw, scheme)) {
            const after = raw[scheme.len..];
            // `after` = "host/path…"; the path starts at the first '/'.
            return if (std.mem.indexOfScalar(u8, after, '/')) |slash| after[slash..] else "/";
        }
    }
    return raw;
}

fn postOscEvent(ctx: ?*anyopaque, event: terminal.tmux.Viewer.PaneOscEvent) void {
    const io: *termio.Termio = @ptrCast(@alignCast(ctx orelse return));
    const msg: apprt.surface.Message = switch (event) {
        .progress => |report| .{ .progress_report = report },
        .pwd => |raw| .{ .pwd_change = apprt.surface.Message.WriteReq.init(io.alloc, pwdPath(raw)) catch return },
        .notification => |n| msg: {
            var m = apprt.surface.Message{ .desktop_notification = undefined };
            const tlen = @min(n.title.len, m.desktop_notification.title.len);
            @memcpy(m.desktop_notification.title[0..tlen], n.title[0..tlen]);
            m.desktop_notification.title[tlen] = 0;
            const blen = @min(n.body.len, m.desktop_notification.body.len);
            @memcpy(m.desktop_notification.body[0..blen], n.body[0..blen]);
            m.desktop_notification.body[blen] = 0;
            break :msg m;
        },
    };
    // NEVER block here. postOscEvent runs on the viewer (gateway) IO thread inside
    // its `lockRenderer`/`lockPaneBounded` window — i.e. while a renderer/pane mutex
    // is held — and `surface_mailbox` is drained only by the main thread
    // (ghostty_app_tick -> App.tick -> drainMailbox), which can itself be blocked
    // acquiring that same renderer mutex (e.g. ghostty_surface_mouse_captured during
    // a focus change). A `.forever` push under the lock therefore deadlocks the UI
    // once the 64-slot queue fills under back-pressure. Drop on full instead: these
    // OSC side-effects (progress / pwd / notification) are non-critical and
    // coalesceable — a dropped progress report is harmless, a deadlock is not.
    _ = io.surface_mailbox.push(msg, .{ .instant = {} });
}

/// Focus gained/lost notification. The tmux backend deliberately sends
/// NOTHING here. It used to echo `select-window` + `select-pane` on every
/// surface focus gain, but a surface gains focus both from user intent AND
/// programmatically (following a remote client's %window-pane-changed, view
/// reparenting after a layout change, focus watchdog re-asserts). Echoing
/// the programmatic gains is catastrophic with two clients attached to the
/// same session: each client follows notifications one step behind its own
/// echoes, so a single divergence (e.g. a split) becomes a self-sustaining
/// %window-pane-changed oscillation — and because every command also makes
/// its client tmux's "latest" client, the window size ping-pongs between
/// differently-sized clients in an infinite %layout-change storm.
///
/// Only the APP knows whether a focus gain was user-initiated, so the app
/// now sends select-window/select-pane explicitly on user focus changes
/// (tap, split navigation, tab switch) via the tracked command path
/// (ghostty_surface_tmux_command). ROOTSHELL-TMUX
/// (id=tmux-select-pane-user-only)
pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    assert(td.backend == .tmux);
    _ = self;
    _ = focused;
}

/// Notify the tmux backend of a terminal resize. This sends a
/// `resize-pane` command to tmux via the control connection.
///
/// Errors from the ControlWriter are propagated to the caller so that
/// a dead control channel is not silently hidden.
pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) ControlWriter.WriteError!void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    // A below-floor grid is never a real layout — it's a transient apprt pass
    // (view mid-teardown, split collapsing). For a sole-pane window the viewer
    // rewrites this resize-pane into the CLIENT size (`refresh-client -C`),
    // which clamps the server window down for every attached client, so a
    // transient 1x1 here becomes a stuck 1x1 window session-wide. Mirrors the
    // viewer's setClientSize floor. ROOTSHELL-TMUX (id=tmux-size-floor)
    if (grid_size.columns < terminal.tmux.Viewer.min_client_cols or
        grid_size.rows < terminal.tmux.Viewer.min_client_rows)
    {
        log.warn("ignoring below-floor pane resize {}x{} pane=%{}", .{
            grid_size.columns,
            grid_size.rows,
            self.pane_id,
        });
        return;
    }

    // Format and send a resize-pane command. tmux resize-pane uses
    // -x for width (columns) and -y for height (rows).
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "resize-pane -t %{d} -x {d} -y {d}\n", .{
        self.pane_id,
        grid_size.columns,
        grid_size.rows,
    }) catch |err| {
        log.warn("resize command too large for buffer err={}", .{err});
        return;
    };

    try self.control_writer.write(cmd);
}

/// Forward this child surface's cell pixel size (font cell metrics) onto the
/// viewer-owned pane terminal so its `width_px`/`height_px` track the cell
/// grid. The gateway only ever sizes the pane terminal in cells, leaving its
/// pixel geometry at zero; without this an auto-sized iTerm2 image (imgcat)
/// collapses to a 0x0 placement and never renders, and `CSI 14/16/18 t`
/// cell-size queries go unanswered. Called from `Termio.resize` inside the
/// renderer-mutex critical section — the same mutex the viewer attached to this
/// pane — so it is serialized against the gateway's pane-terminal writes/reads.
/// ROOTSHELL-TMUX (id=tmux-pane-pixel-geometry)
pub fn updateViewerPaneCell(self: *Tmux, cell_width: u32, cell_height: u32) void {
    const pane = self.viewer_pane orelse return;
    pane.cell_width = cell_width;
    pane.cell_height = cell_height;
    pane.recomputePixelSize();
}

/// Forward a raw command to the tmux control mode connection.
/// This is the IO-thread entry point for commands that originate from
/// user keybindings (split-window, kill-pane, etc.) and are queued via
/// the `tmux_command` termio message. The command must include a
/// trailing newline since tmux control mode is line-oriented.
pub fn tmuxCommand(self: *Tmux, cmd: []const u8) void {
    self.control_writer.write(cmd) catch |err| {
        log.warn("failed to send tmux command err={}", .{err});
    };
}

/// Write user input to the tmux pane. Input bytes are formatted as
/// `send-keys -H` commands with hex-encoded key values, targeting this
/// backend's pane ID.
///
/// Format: `send-keys -H -t %{pane_id} {hex bytes...}\n`
///
/// The `-H` flag tells tmux to interpret the arguments as hex byte
/// values, which is the most reliable way to send arbitrary data
/// including control characters and escape sequences.
///
/// Large inputs (e.g. a 10KB paste) are split into multiple send-keys
/// commands of at most `max_send_keys_bytes` *input* bytes each (before
/// hex encoding). While modern tmux (3.x) has no hard command-length
/// limit in control mode, chunking avoids blocking the control channel
/// with a single massive command and maintains compatibility with older
/// tmux versions.
///
/// All command lines for one call are emitted as a SINGLE
/// `control_writer.write`. For a child pane the control writer relays
/// through the app mailbox and the gateway's termio mailbox (both
/// fixed-capacity with drop-on-sustained-backpressure); one write per
/// chunk let a large paste fan out into ~100 independent messages, and
/// any dropped chunk tore the bracketed paste apart (lost `ESC[201~`
/// = remote app stuck in an open paste). Batching keeps a paste
/// all-or-nothing through every queue. The parent IO thread records one
/// untracked ack marker per `\n` in the payload, so the batch MUST
/// contain only complete send-keys lines. ROOTSHELL-TMUX (id=tmux-send-keys-batch)
pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    assert(td.backend == .tmux);
    if (data.len == 0) return;

    // We need to handle linefeed mode: replace \r with \r\n in the
    // data before hex-encoding it.
    const effective_data = if (!linefeed) data else blk: {
        // Count how many \r bytes we need to expand
        var cr_count: usize = 0;
        for (data) |b| {
            if (b == '\r') cr_count += 1;
        }
        if (cr_count == 0) break :blk data;

        const expanded = try alloc.alloc(u8, data.len + cr_count);
        var j: usize = 0;
        for (data) |b| {
            expanded[j] = b;
            j += 1;
            if (b == '\r') {
                expanded[j] = '\n';
                j += 1;
            }
        }
        break :blk expanded[0..j];
    };
    defer if (linefeed and effective_data.ptr != data.ptr) {
        alloc.free(effective_data);
    };

    const id_digits = digitCount(self.pane_id);

    // Fast path: fits one command (every keystroke, small pastes).
    // Format on the stack — no allocation, one write.
    if (effective_data.len <= max_send_keys_bytes) {
        var sbuf: [max_single_cmd_len]u8 = undefined;
        const cmd_len = writeSendKeysCmd(&sbuf, send_keys_prefix, self.pane_id, id_digits, effective_data);
        try self.control_writer.write(sbuf[0..cmd_len]);
        return;
    }

    // Batch path: format every command line into one exactly-sized buffer
    // and issue a single write. Per command the formatted size is exactly
    // prefix + id_digits + space + 3*chunk_len (each input byte becomes
    // two hex chars plus a separator space or the final newline).
    const n_chunks = (effective_data.len + max_send_keys_bytes - 1) / max_send_keys_bytes;
    const total_len = n_chunks * (send_keys_prefix.len + id_digits + 1) + 3 * effective_data.len;

    const buf = alloc.alloc(u8, total_len) catch {
        // OOM: degrade to one write per chunk (the pre-batch behavior)
        // using the allocation-free stack buffer. Correctness only drops
        // back to multi-message delivery.
        var sbuf: [max_single_cmd_len]u8 = undefined;
        var offset: usize = 0;
        while (offset < effective_data.len) {
            const chunk_len = @min(effective_data.len - offset, max_send_keys_bytes);
            const chunk = effective_data[offset..][0..chunk_len];
            const cmd_len = writeSendKeysCmd(&sbuf, send_keys_prefix, self.pane_id, id_digits, chunk);
            try self.control_writer.write(sbuf[0..cmd_len]);
            offset += chunk_len;
        }
        return;
    };
    defer alloc.free(buf);

    var pos: usize = 0;
    var offset: usize = 0;
    while (offset < effective_data.len) {
        const chunk_len = @min(effective_data.len - offset, max_send_keys_bytes);
        const chunk = effective_data[offset..][0..chunk_len];
        pos += writeSendKeysCmd(buf[pos..], send_keys_prefix, self.pane_id, id_digits, chunk);
        offset += chunk_len;
    }
    assert(pos == total_len);
    try self.control_writer.write(buf[0..pos]);
}

/// Maximum number of input bytes per send-keys command. Each input
/// byte becomes 3 hex characters ("XX "), so 1024 bytes produce a
/// command of ~3.1KB — well within any practical limit.
const max_send_keys_bytes = 1024;

const send_keys_prefix = "send-keys -H -t %";

/// Maximum decimal digits of a pane id (usize max on 64-bit).
const max_pane_id_digits = 20;

/// Exact formatted size of one full-chunk send-keys command with the
/// largest possible pane id; sizes the stack buffer used by the
/// single-command fast path and the OOM fallback.
const max_single_cmd_len = send_keys_prefix.len + max_pane_id_digits + 1 + 3 * max_send_keys_bytes;

/// Format a `send-keys -H -t %<id> <hex>...\n` command into `buf`.
/// Returns the number of bytes written. The caller must ensure `buf`
/// is large enough for the given `chunk` (see `queueWrite` allocation).
fn writeSendKeysCmd(
    buf: []u8,
    prefix: []const u8,
    pane_id: usize,
    id_digits: usize,
    chunk: []const u8,
) usize {
    var pos: usize = 0;

    // Write the prefix
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // Write the pane ID
    const id_slice = std.fmt.bufPrint(buf[pos..][0..id_digits], "{d}", .{pane_id}) catch unreachable;
    pos += id_slice.len;

    // Space separator
    buf[pos] = ' ';
    pos += 1;

    // Write hex-encoded bytes
    const hex_chars = "0123456789ABCDEF";
    for (chunk, 0..) |byte, i| {
        buf[pos] = hex_chars[byte >> 4];
        pos += 1;
        buf[pos] = hex_chars[byte & 0x0F];
        pos += 1;
        if (i < chunk.len - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }

    // Trailing newline
    buf[pos] = '\n';
    pos += 1;

    return pos;
}

/// No child process to report on — this is a no-op.
pub fn childExitedAbnormally(
    self: *Tmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Thread-local data for the tmux backend. Currently empty — the tmux
/// backend does not participate in the xev event loop directly.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        self.* = undefined;
    }
};

/// Count the number of decimal digits in a usize value.
fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

/// A test mock for ControlWriter that captures all written commands.
const TestControlWriter = struct {
    alloc: Allocator,
    commands: std.ArrayList([]const u8) = .empty,

    fn init(alloc: Allocator) TestControlWriter {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *TestControlWriter) void {
        for (self.commands.items) |cmd| {
            self.alloc.free(cmd);
        }
        self.commands.deinit(self.alloc);
    }

    fn controlWriter(self: *TestControlWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *TestControlWriter = @ptrCast(@alignCast(context));
        const copy = self.alloc.dupe(u8, data) catch return error.WriteFailed;
        self.commands.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return error.WriteFailed;
        };
    }

    fn lastCommand(self: *const TestControlWriter) ?[]const u8 {
        if (self.commands.items.len == 0) return null;
        return self.commands.items[self.commands.items.len - 1];
    }
};

/// A test mock for ControlWriter that always returns ConnectionClosed.
/// Used to verify that callers handle write failures gracefully without
/// corrupting internal state.
const FailingControlWriter = struct {
    fn controlWriter() ControlWriter {
        return .{
            .context = undefined,
            .writeFn = &writeFn,
        };
    }

    fn writeFn(_: *anyopaque, _: []const u8) ControlWriter.WriteError!void {
        return error.ConnectionClosed;
    }
};

/// Create a minimal Termio.ThreadData with .tmux backend for testing.
/// Only the `backend` field is meaningfully set; other fields are
/// undefined since the tmux backend does not access them in queueWrite.
fn testThreadData() termio.Termio.ThreadData {
    var td: termio.Termio.ThreadData = undefined;
    td.backend = .{ .tmux = .{} };
    return td;
}

test "pwdPath strips file scheme + host" {
    // ROOTSHELL-TMUX (id=viewer-pane-osc)
    try testing.expectEqualStrings("/home/kit", pwdPath("file://host/home/kit"));
    try testing.expectEqualStrings("/home/kit", pwdPath("file:///home/kit")); // empty host
    try testing.expectEqualStrings("/", pwdPath("file://hostonly")); // host, no path
    try testing.expectEqualStrings("/bare/path", pwdPath("/bare/path")); // already a path
    try testing.expectEqualStrings("", pwdPath("")); // empty
}

test "init sets pane_id and initial sizes" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    const tmux = Tmux.init(.{
        .pane_id = 42,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try testing.expectEqual(@as(usize, 42), tmux.pane_id);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.rows);
}

test "resize sends resize-pane command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 5,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 80, .rows = 24 },
        .{ .width = 800, .height = 600 },
    );

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("resize-pane -t %5 -x 80 -y 24\n", writer.lastCommand().?);

    // Verify internal state was updated
    try testing.expectEqual(@as(renderer.GridSize.Unit, 80), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 24), tmux.grid_size.rows);
}

test "resize with large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 12345,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );

    try testing.expectEqualStrings("resize-pane -t %12345 -x 120 -y 40\n", writer.lastCommand().?);
}

test "resize consecutive calls track latest dimensions" {
    // Verify that multiple resize calls correctly update internal state
    // and emit one command per call. The coalesce timer in Thread.zig
    // handles deduplication at the IO thread level — the backend itself
    // must faithfully emit every resize it receives.
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // First resize
    try tmux.resize(
        .{ .columns = 80, .rows = 24 },
        .{ .width = 800, .height = 480 },
    );
    // Second resize (window grew)
    try tmux.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );
    // Third resize (window shrunk)
    try tmux.resize(
        .{ .columns = 60, .rows = 15 },
        .{ .width = 600, .height = 300 },
    );

    // All three commands must have been emitted
    try testing.expectEqual(@as(usize, 3), writer.commands.items.len);
    try testing.expectEqualStrings("resize-pane -t %3 -x 80 -y 24\n", writer.commands.items[0]);
    try testing.expectEqualStrings("resize-pane -t %3 -x 120 -y 40\n", writer.commands.items[1]);
    try testing.expectEqualStrings("resize-pane -t %3 -x 60 -y 15\n", writer.commands.items[2]);

    // Internal state must reflect the latest resize
    try testing.expectEqual(@as(renderer.GridSize.Unit, 60), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 15), tmux.grid_size.rows);
    try testing.expectEqual(@as(u32, 600), tmux.screen_size.width);
    try testing.expectEqual(@as(u32, 300), tmux.screen_size.height);
}

test "resize updates state even when control writer fails" {
    // The resize method updates grid_size and screen_size before
    // attempting the control_writer.write call. This ensures local
    // state remains consistent even if the control connection is dead.
    var tmux = Tmux.init(.{
        .pane_id = 99,
        .window_id = 0,
        .control_writer = FailingControlWriter.controlWriter(),
    });

    // Verify initial state is zero
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.rows);

    // resize should propagate the ConnectionClosed error
    try testing.expectError(error.ConnectionClosed, tmux.resize(
        .{ .columns = 100, .rows = 50 },
        .{ .width = 1000, .height = 500 },
    ));

    // But state must still be updated (write happens after state update)
    try testing.expectEqual(@as(renderer.GridSize.Unit, 100), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 50), tmux.grid_size.rows);
    try testing.expectEqual(@as(u32, 1000), tmux.screen_size.width);
    try testing.expectEqual(@as(u32, 500), tmux.screen_size.height);
}

test "resize tracks screen_size alongside grid_size" {
    // Verify that screen_size (pixel dimensions) is tracked alongside
    // grid_size (cell dimensions). Both are needed: grid_size for the
    // resize-pane command, screen_size for pixel-level state in
    // Termio.resize (terminal.width_px / height_px).
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 132, .rows = 43 },
        .{ .width = 1584, .height = 774 },
    );

    // Grid size
    try testing.expectEqual(@as(renderer.GridSize.Unit, 132), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 43), tmux.grid_size.rows);
    // Screen size (pixel dimensions)
    try testing.expectEqual(@as(u32, 1584), tmux.screen_size.width);
    try testing.expectEqual(@as(u32, 774), tmux.screen_size.height);
    // Command uses grid dimensions, not pixel dimensions
    try testing.expectEqualStrings("resize-pane -t %1 -x 132 -y 43\n", writer.lastCommand().?);
}

test "queueWrite formats send-keys with hex encoding" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 2,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // "ls\r" = 0x6C 0x73 0x0D
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "ls\r", false);

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("send-keys -H -t %2 6C 73 0D\n", writer.lastCommand().?);
}

test "queueWrite single byte" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 0,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "a", false);

    try testing.expectEqualStrings("send-keys -H -t %0 61\n", writer.lastCommand().?);
}

test "queueWrite escape sequence" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 10,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // Up arrow: ESC [ A = 0x1B 0x5B 0x41
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "\x1B[A", false);

    try testing.expectEqualStrings("send-keys -H -t %10 1B 5B 41\n", writer.lastCommand().?);
}

test "queueWrite with linefeed mode" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // "ab\rcd" with linefeed=true should become "ab\r\ncd"
    // hex: 61 62 0D 0A 63 64
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "ab\rcd", true);

    try testing.expectEqualStrings("send-keys -H -t %3 61 62 0D 0A 63 64\n", writer.lastCommand().?);
}

test "queueWrite empty data is no-op" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "", false);

    try testing.expectEqual(@as(usize, 0), writer.commands.items.len);
}

test "queueWrite large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 99999,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "X", false);

    try testing.expectEqualStrings("send-keys -H -t %99999 58\n", writer.lastCommand().?);
}

test "queueWrite chunks large input into one batched write" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 5,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // Create input slightly larger than one chunk (max_send_keys_bytes + 1).
    const input_len = max_send_keys_bytes + 1;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    @memset(input, 'A'); // 0x41

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    // Two command lines batched into a SINGLE write.
    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    const batch = writer.commands.items[0];
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, batch, "\n"));

    var lines = std.mem.splitScalar(u8, batch, '\n');
    const line1 = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, line1, "send-keys -H -t %5 "));

    // Second command line: the 1 remaining byte.
    try testing.expectEqualStrings("send-keys -H -t %5 41", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
}

test "queueWrite exactly max_send_keys_bytes is single command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 0,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    const input = try alloc.alloc(u8, max_send_keys_bytes);
    defer alloc.free(input);
    @memset(input, 'B'); // 0x42

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    // Exactly at the limit — should be a single command.
    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
}

test "queueWrite large input with linefeed mode chunks correctly" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // Create input that, after linefeed expansion, exceeds one chunk.
    // Fill with \r so each byte becomes \r\n (doubles the size).
    const input_len = max_send_keys_bytes / 2 + 1;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    @memset(input, '\r');

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, true);

    // After expansion: (max_send_keys_bytes / 2 + 1) * 2 = max_send_keys_bytes + 2
    // Two command lines, batched into a single write.
    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    const batch = writer.commands.items[0];
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, batch, "\n"));

    // Every expanded byte is \r or \n — verify the full hex round-trip
    // across the chunk boundary: alternating 0D 0A pairs.
    var decoded: usize = 0;
    var lines = std.mem.splitScalar(u8, batch, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, line["send-keys -H -t %1 ".len..], ' ');
        while (it.next()) |pair| {
            const byte = try std.fmt.parseInt(u8, pair, 16);
            try testing.expectEqual(@as(u8, if (decoded % 2 == 0) '\r' else '\n'), byte);
            decoded += 1;
        }
    }
    try testing.expectEqual(@as(usize, max_send_keys_bytes + 2), decoded);
}

test "queueWrite multiple full chunks" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // 3 full chunks exactly
    const input_len = max_send_keys_bytes * 3;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    @memset(input, 'C');

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    // 3 command lines, one write.
    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, writer.commands.items[0], "\n"),
    );
}

test "queueWrite batch hex round-trips to input" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 12,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    // ~2.5 chunks of a repeating byte pattern.
    const input_len = max_send_keys_bytes * 5 / 2;
    const input = try alloc.alloc(u8, input_len);
    defer alloc.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i);

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, input, false);

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    const batch = writer.commands.items[0];
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, batch, "\n"));

    // Decode every hex pair back and compare against the input.
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    defer decoded.deinit(alloc);
    var lines = std.mem.splitScalar(u8, batch, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.startsWith(u8, line, "send-keys -H -t %12 "));
        var it = std.mem.tokenizeScalar(u8, line["send-keys -H -t %12 ".len..], ' ');
        while (it.next()) |pair| {
            try decoded.append(alloc, try std.fmt.parseInt(u8, pair, 16));
        }
    }
    try testing.expectEqualSlices(u8, input, decoded.items);
}

test "queueWrite batch alloc failure falls back to per-chunk writes" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 5,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    const input = try alloc.alloc(u8, max_send_keys_bytes * 2 + 1);
    defer alloc.free(input);
    @memset(input, 'A');

    // With linefeed=false the batch buffer is the only allocation in
    // queueWrite, so failing the first allocation exercises the fallback.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var td = testThreadData();
    try tmux.queueWrite(failing.allocator(), &td, input, false);

    // Fallback degrades to one write per chunk.
    try testing.expectEqual(@as(usize, 3), writer.commands.items.len);
    try testing.expectEqualStrings("send-keys -H -t %5 41\n", writer.commands.items[2]);
}

test "deinit resets state" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    tmux.deinit();
    // After deinit, the struct is undefined — we just verify it
    // doesn't crash.
}

test "digitCount" {
    try testing.expectEqual(@as(usize, 1), digitCount(0));
    try testing.expectEqual(@as(usize, 1), digitCount(1));
    try testing.expectEqual(@as(usize, 1), digitCount(9));
    try testing.expectEqual(@as(usize, 2), digitCount(10));
    try testing.expectEqual(@as(usize, 2), digitCount(99));
    try testing.expectEqual(@as(usize, 3), digitCount(100));
    try testing.expectEqual(@as(usize, 5), digitCount(12345));
    try testing.expectEqual(@as(usize, 5), digitCount(99999));
}

test "ParentWriter routes commands through mailbox" {
    const alloc = testing.allocator;

    // Create a real SPSC mailbox
    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
    };
    const writer = parent_writer.controlWriter();

    // Write a command through the ParentWriter
    try writer.write("list-windows\n");

    // Verify the command was queued in the mailbox
    const msg = mailbox.spsc.queue.pop(std.testing.io) orelse {
        return error.TestUnexpectedResult;
    };

    // The message should be a write_small or write_alloc depending on size.
    // "list-windows\n" is 14 bytes, which fits in write_small.
    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("list-windows\n", data);

    // Clean up alloc data if it was heap-allocated
    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "ParentWriter handles large commands" {
    const alloc = testing.allocator;

    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
    };
    const writer = parent_writer.controlWriter();

    // Write a command larger than WriteReq.Small capacity (38 bytes)
    const large_cmd = "send-keys -H -t %12345 41 42 43 44 45 46 47 48\n";
    try writer.write(large_cmd);

    const msg = mailbox.spsc.queue.pop(std.testing.io) orelse {
        return error.TestUnexpectedResult;
    };

    // Large command should use write_alloc
    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(large_cmd, data);

    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "ParentWriter used as backend ControlWriter" {
    // Verify that ParentWriter integrates with the Tmux backend:
    // create a Tmux backend with a ParentWriter, call resize, and
    // confirm the resize-pane command reaches the mailbox.
    const alloc = testing.allocator;

    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
    };

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .window_id = 0,
        .control_writer = parent_writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 100, .rows = 30 },
        .{ .width = 1000, .height = 600 },
    );

    const msg = mailbox.spsc.queue.pop(std.testing.io) orelse {
        return error.TestUnexpectedResult;
    };

    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("resize-pane -t %7 -x 100 -y 30\n", data);

    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "tmux relay: WriteReq fits small tmux commands inline" {
    // Verify that typical tmux commands (< 255 bytes) produce a
    // WriteReq.small variant, confirming the surface-level WriteReq
    // handles them without allocation.
    const alloc = testing.allocator;
    const SurfaceWriteReq = apprt.surface.Message.WriteReq;

    // A typical resize-pane command (~30 bytes)
    const cmd: []const u8 = "resize-pane -t %5 -x 80 -y 24\n";
    const req = try SurfaceWriteReq.init(alloc, cmd);
    try testing.expect(req == .small);
    try testing.expectEqualStrings(cmd, req.slice());
}

test "tmux relay: WriteReq allocates for large commands" {
    // Verify that commands exceeding 255 bytes (surface WriteReq.Small
    // capacity) use the alloc variant.
    const alloc = testing.allocator;
    const SurfaceWriteReq = apprt.surface.Message.WriteReq;

    // Construct a send-keys command larger than 255 bytes
    const large_cmd: []const u8 = "send-keys -H -t %12345 " ++ "41 " ** 100 ++ "\n";
    const req = try SurfaceWriteReq.init(alloc, large_cmd);
    defer req.deinit();
    try testing.expect(req == .alloc);
    try testing.expectEqualStrings(large_cmd, req.slice());
}

test "tmux relay: conversion preserves data across WriteReq size boundaries" {
    // Verify the full relay conversion: surface WriteReq.small (up to
    // 255 bytes) -> termio.Message.writeReq -> write_small (<=38) or
    // write_alloc (>38). This tests the size mismatch handling in the
    // Surface.handleMessage(.tmux_write_command) path.
    const alloc = testing.allocator;
    const SurfaceWriteReq = apprt.surface.Message.WriteReq;

    // Case 1: Command fits in BOTH surface small (255) and termio small (38)
    {
        const cmd: []const u8 = "list-windows\n"; // 14 bytes
        const surface_req = try SurfaceWriteReq.init(alloc, cmd);
        try testing.expect(surface_req == .small);

        // Simulate relay: extract data, convert to termio message
        const io_msg = try termio.Message.writeReq(alloc, surface_req.slice());
        try testing.expect(io_msg == .write_small);
        const data = switch (io_msg) {
            .write_small => |s| s.data[0..s.len],
            else => unreachable,
        };
        try testing.expectEqualStrings(cmd, data);
    }

    // Case 2: Command fits in surface small (255) but NOT termio small (38)
    {
        const cmd: []const u8 = "send-keys -H -t %12345 41 42 43 44 45 46 47 48\n"; // 49 bytes
        try testing.expect(cmd.len > 38);
        try testing.expect(cmd.len <= 255);

        const surface_req = try SurfaceWriteReq.init(alloc, cmd);
        try testing.expect(surface_req == .small);

        // Simulate relay: this must produce write_alloc, not write_small
        const io_msg = try termio.Message.writeReq(alloc, surface_req.slice());
        try testing.expect(io_msg == .write_alloc);
        switch (io_msg) {
            .write_alloc => |a| {
                try testing.expectEqualStrings(cmd, a.data);
                a.alloc.free(a.data);
            },
            else => unreachable,
        }
    }
}

test "tmuxCommand sends raw command to control writer" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .window_id = 0,
        .control_writer = writer.controlWriter(),
    });

    tmux.tmuxCommand("split-window -h -t %3\n");

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("split-window -h -t %3\n", writer.lastCommand().?);
}
