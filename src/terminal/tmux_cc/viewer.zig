// ROOTSHELL-TMUX: fork-owned tmux control-mode viewer. This entire src/terminal/tmux_cc/
// directory is fork-owned and was relocated off the upstream-shared src/terminal/tmux/
// path so upstream's experimental tmux parser can never 3-way-merge against it. On
// rebase, take OUR version wholesale; if upstream edits src/terminal/tmux/*, keep them
// deleted. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const color = @import("../color.zig");
const clipboard = @import("../clipboard.zig"); // ROOTSHELL-TMUX (id=viewer-clipboard): protocol-neutral clipboard write effect
const mouse = @import("../mouse.zig");
const osc = @import("../osc.zig"); // ROOTSHELL-TMUX (id=viewer-pane-osc): OSC 9;4 progress report type
const device_attributes = @import("../device_attributes.zig"); // ROOTSHELL-TMUX (id=streamterm-tmux-passthrough): DA reply for wrapped queries
const size_report = @import("../size_report.zig"); // ROOTSHELL-TMUX (id=streamterm-tmux-passthrough): pixel-size reply for wrapped queries
const TerminalStream = @import("../stream_terminal.zig").Stream;
const TerminalStreamHandler = @import("../stream_terminal.zig").Handler;
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// Initial capacity of the sent-command FIFO (see `sent_fifo`). Holds one
/// entry per command written-but-unacked; in steady state only a handful are
/// outstanding (tmux acks each with exactly one %begin/%end block, consumed in
/// order), so a small ring suffices and grows on demand. ROOTSHELL-TMUX
/// (id=viewer-sent-fifo)
const SENT_FIFO_INITIAL = 8;

/// Diagnostic-only depth at which we log once that the sent-command FIFO is
/// unusually deep. This is NOT a cap: dropping/clearing markers would desync the
/// block matcher (the exact bug this FIFO prevents), and a large paste legitimately
/// enqueues one marker per `send-keys` chunk (`Tmux.queueWrite` splits at 1 KiB,
/// so a multi-hundred-KiB paste can outstrip tmux's ack rate transiently). Markers
/// are 1 byte each, so the FIFO simply grows and drains as acks arrive — cheap and
/// self-bounding. The warning just surfaces "many send-keys outstanding / slow
/// acks" for diagnosis. ROOTSHELL-TMUX (id=viewer-sent-fifo)
const SENT_FIFO_WARN = 4096;

/// Maximum windows materialized from one session's topology, and maximum
/// total panes across all of them. Every pane allocates a Terminal with a
/// 10 MiB scrollback ceiling here plus a Metal-backed TerminalView on the
/// app's main actor, so an unbounded server-controlled topology (a hostile
/// server opening thousands of windows, or wide layout strings bounded only
/// by the 64 MiB control buffer) is a one-shot remote OOM / watchdog-kill on
/// attach. Windows beyond the cap are DROPPED with a log — the session stays
/// usable (degraded) instead of killing the app. Real sessions sit far below
/// both caps (the per-layout node cap is separate, see
/// Layout.max_parse_nodes). The Swift reconcile enforces the same caps as a
/// backstop. ROOTSHELL-TMUX (id=viewer-topology-caps)
pub const MAX_WINDOWS = 128;
pub const MAX_TOTAL_PANES = 512;

/// Seconds a pane may fall behind the control client before tmux pauses it.
/// Sent as `-f pause-after=<N>` in the initial `refresh-client`. tmux parses
/// this as SECONDS (server-client.c: `pause-after=%u` then `*= 1000`), NOT
/// bytes. Enabling pause mode means tmux PAUSES a lagging pane (emitting
/// `%pause`, which we auto-continue) instead of KILLING the control client once
/// it exceeds CONTROL_MAXIMUM_AGE (300s). The real backpressure is structural
/// (the synchronous read loop + bounded pane scrollback), so this is a generous
/// kill-avoidance margin comfortably under 300s, NOT a tight flow-control knob —
/// a small value would just churn pause/continue since we have no paused-pane UX
/// to leave a pane paused. ROOTSHELL-TMUX (id=pause-after-seconds)
const PAUSE_AFTER_SECONDS = 200;

// ROOTSHELL-TMUX (id=viewer-pane-bounded-lock): renderer-lock budgets for
// pane writes driven from the control channel. The channel must never block
// indefinitely on a pane renderer; on timeout the work spills/re-queues.
/// Live `%output` writes: short — output spills losslessly to `pending_vt`.
const PANE_LOCK_OUTPUT_BUDGET_NS: u64 = 20 * std.time.ns_per_ms;
/// Capture-reply application (history/visible/state): longer — a timeout
/// costs a re-fetch round trip to tmux.
const PANE_LOCK_CAPTURE_BUDGET_NS: u64 = 250 * std.time.ns_per_ms;
/// Cosmetic/re-driven work (theme refresh, layout resize): short — a timeout
/// just defers to the next opportunity.
const PANE_LOCK_QUICK_BUDGET_NS: u64 = 10 * std.time.ns_per_ms;
/// Cap on per-pane spilled live output. On overflow the spill is discarded
/// and the pane's visible content is re-fetched from tmux instead.
const PANE_PENDING_VT_MAX: usize = 1024 * 1024;
/// Max capture-reply re-queues after lock timeouts per pane (resets on a
/// successful application) so a permanently-stuck renderer can't loop.
const PANE_CAPTURE_RETRY_MAX: u8 = 3;

/// Maximum scrollback lines replayed per pane at attach (`capture-pane
/// -S -<N>`; tmux clamps to available history, so shorter panes are
/// unaffected). Previously `-S -` (unbounded), which made the attach replay
/// proportional to the pane's entire history: a pane with hundreds of
/// thousands of CJK-heavy lines produced a multi-megabyte reply in ONE
/// command block, a burst large enough to stall the iOS app's UDP transport
/// bidirectionally (observed: command pipeline wedged on pane_history with
/// zero further inbound bytes). The viewer pane's own scrollback is finite
/// anyway, so replaying more than this is pure transfer cost.
/// ROOTSHELL-TMUX (id=pane-history-max-lines)
const PANE_HISTORY_MAX_LINES = 10_000;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Threading Model
///
/// The Viewer is **single-threaded**: all methods are called exclusively
/// from the parent surface's I/O thread (the termio thread that owns the
/// control mode connection). There are no internal mutexes or atomics.
///
/// Cross-thread coordination occurs at one point: each `Pane` holds an
/// optional `renderer_mutex` that, when non-null, points to the child
/// surface's `renderer_state.mutex`. The viewer acquires this mutex in
/// all terminal-write paths (`receivedOutput`, `receivedPaneHistory`,
/// `receivedPaneState`) to coordinate with the
/// child's renderer thread, which reads from the same `Terminal` under
/// this mutex.
///
/// The `renderer_mutex` lifecycle is managed externally by `Tmux.zig`:
/// - Set during `threadEnter` (child surface's I/O thread has started,
///   renderer is about to begin reading the terminal).
/// - Cleared during `threadExit` (child is shutting down, renderer will
///   no longer read).
///
/// When `renderer_mutex` is null (before a child surface attaches or
/// after it detaches), no locking is needed because no other thread
/// is reading the terminal.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │              startup                        │
///                              │                                             │
///                              │  Wait for both:                             │
///                              │  1. Initial %begin/%end block (response to  │
///                              │     the attach command)                     │
///                              │  2. %session-changed notification (gives    │
///                              │     us the session ID)                      │
///                              │  Either can arrive first.                   │
///                              └─────────────────┬───────────────────────────┘
///                                                │ both received
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                    ┌───────────────────────────┴───────────────────────────┐
///                    │                  For each new pane:                   │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (primary screen)     │                            │     (primary screen)     │
///     │                          │                            │                          │
///     │  Capture scrollback      │                            │  Capture visible area    │
///     │  history into terminal.  │                            │  into terminal.          │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (alternate screen)   │                            │     (alternate screen)   │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    └───────────────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///

// ROOTSHELL-TMUX (id=viewer-orphan-graveyard): process-global graveyard of panes
// orphaned by viewer teardown while still retained (a child renderer or an
// in-flight snapshot/payload still holds a raw pointer to them). The viewer is
// gone, so its IO-thread reap can no longer free them; instead the LAST holder
// to release (`Pane.detachRenderer` on the child IO thread, or
// `Pane.releaseSnapshotRef` on the app/main thread) reaps the pane here. An
// intrusive singly-linked list via `Pane.orphan_next`, serialized by
// `orphan_mutex` so the "still in the list?" check + unlink + free is atomic and
// exactly one releaser frees. The membership check compares pointer VALUES, so a
// stale pointer (already-reaped pane) is simply not found — never dereferenced.
var orphan_mutex: std.Io.Mutex = .init;
var orphan_head: ?*Viewer.Pane = null;

/// Transfer a still-retained pane to the graveyard at viewer teardown (IO
/// thread). It will be freed by `reapOrphan` once its last child / snapshot hold
/// is released. ROOTSHELL-TMUX (id=viewer-orphan-graveyard)
fn orphanPane(pane: *Viewer.Pane, alloc: Allocator) void {
    orphan_mutex.lockUncancelable(pane.io);
    defer orphan_mutex.unlock(pane.io);
    // Re-check retention UNDER the lock. A hold may have been released between
    // the caller's `isRetained()` check and here (e.g. the child detached on its
    // own thread, whose `reapOrphan` found the pane not-yet-listed and no-op'd).
    // If nothing retains it now, free it directly — listing it would leak it,
    // since no future release would call `reapOrphan` for it.
    if (!pane.isRetained()) {
        pane.deinit(alloc);
        alloc.destroy(pane);
        return;
    }
    pane.orphan_alloc = alloc;
    pane.orphan_next = orphan_head;
    orphan_head = pane;
}

/// Reap `pane` if it is a graveyard orphan whose last hold has now been
/// released. Called after every child-detach / snapshot-ref release; a no-op
/// (cheap list-empty check) while the owning viewer is alive. ROOTSHELL-TMUX
/// (id=viewer-orphan-graveyard)
fn reapOrphan(pane: *Viewer.Pane) void {
    orphan_mutex.lockUncancelable(pane.io);
    defer orphan_mutex.unlock(pane.io);

    // Locate `pane` in the list, comparing addresses only (never dereferences a
    // possibly-freed pointer). If it isn't present it was never orphaned, or
    // another releaser already reaped it — either way, nothing to do.
    var prev: ?*Viewer.Pane = null;
    var cur = orphan_head;
    while (cur) |node| {
        if (node == pane) break;
        prev = node;
        cur = node.orphan_next;
    } else return;

    // Found and still alive (list membership guarantees it isn't freed). Leave it
    // if another hold remains; the holder that releases last will reap it.
    if (pane.isRetained()) return;

    if (prev) |p| {
        p.orphan_next = pane.orphan_next;
    } else {
        orphan_head = pane.orphan_next;
    }
    const alloc = pane.orphan_alloc.?;
    pane.deinit(alloc);
    alloc.destroy(pane);
}

pub const Viewer = struct {
    /// I/O implementation used for the pane renderer mutexes and for any
    /// terminal we create. ROOTSHELL-TMUX (id=viewer-io)
    io: std.Io,

    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// During startup, tracks whether we've received the initial
    /// %begin/%end block. Once both this and startup_got_session are
    /// set, we transition to command_queue. Only meaningful in .startup state.
    startup_got_block: bool,

    /// During startup, tracks whether we've received %session-changed.
    /// Only meaningful in .startup state.
    startup_got_session: bool,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The current session name. Stored on the windows arena and
    /// valid until the next list-windows refresh. Empty if not yet
    /// known (session name is set from `%session-changed` on attach
    /// and updated via `%session-renamed`).
    session_name: []const u8,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// Current control client size (columns and rows). Sent to tmux
    /// via `refresh-client -C` on startup so tmux knows our display
    /// dimensions. Updated externally via `setClientSize` when the
    /// parent terminal resizes.
    client_cols: size.CellCountInt,
    client_rows: size.CellCountInt,

    /// Themed colors applied to each pane terminal so default-background cells
    /// match the app theme (the viewer-owner/gateway terminal's colors) instead
    /// of the built-in dark default. Defaults to `.default` (unset) so tests and
    /// the plain `init` are unchanged; the stream handler sets this to the
    /// gateway terminal's colors right after creating the viewer, and
    /// `sessionChanged` carries it forward to the replacement viewer.
    colors: Terminal.Colors = .default,

    /// Configured cursor style/blink, set by the stream handler from the
    /// gateway's config (mirrors `colors` above) so tmux -CC panes honor
    /// `cursor-style`/`cursor-style-blink`. Blink is `?bool`: null means the
    /// user did not configure it, so tmux's reported blink is honored rather
    /// than forced (matches a normal surface, which only overrides DEC mode 12
    /// when blink is explicitly set). Defaults match the bare `init` so tests
    /// are unchanged. ROOTSHELL-TMUX (id=viewer-cursor-style-default)
    default_cursor_style: Screen.CursorStyle = .block,
    default_cursor_blink: ?bool = null,

    /// Whether a command has been sent to tmux and we're awaiting its
    /// `%begin`/`%end` response block. This disambiguates "queue is
    /// empty because nothing was queued" from "queue has entries but
    /// the first one was already sent." Without this, externally-queued
    /// commands (e.g. from `setClientSize`) that land in an empty queue
    /// would be mistaken for an already-sent in-flight command.
    command_in_flight: bool,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// Provenance for each entry in `command_queue`, kept in exact FIFO
    /// lockstep. Incremental recovery must yield to ordinary tracked work and
    /// rewind a partial pane capture across that interruption, but commands
    /// generated by recovery itself must not rewind scheduler progress.
    /// ROOTSHELL-TMUX (id=viewer-recovery-command-ownership)
    command_owners: CommandOwnerQueue,

    /// Ordered record of EVERY command written to the `tmux -CC` pty awaiting a
    /// `%begin/%end` block, tagged tracked vs untracked, in pty-write order. The
    /// viewer matches blocks to queued commands by blind FIFO; but `send-keys`
    /// (typed input / paste / focus reports) is written directly, bypassing the
    /// command_queue, so its ack is invisible to that matcher and — if it lands
    /// while a tracked command is in flight (e.g. a tab switch fires
    /// select-window/select-pane/refresh-client concurrently with a focus-report
    /// send-keys) — gets mis-attributed, desyncing the response stream. This FIFO
    /// lets `classifyBlock` consume an untracked ack in order and swallow it
    /// before it reaches `next`, keeping the command/response FIFO aligned.
    /// Markers are appended at the single drain/write point (`Thread.zig`), NOT
    /// at the viewer enqueue site, because the SPSC mailbox can reorder the write
    /// behind a send-keys queued ahead of it. ROOTSHELL-TMUX (id=viewer-sent-fifo)
    sent_fifo: SentFifo,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// Arena that owns all window and layout data. Layout trees (allocated
    /// by `Layout.parseWithChecksum`) and the window structs' layout
    /// pointers all live here. Reset-and-rebuild on every topology change
    /// (`receivedListWindows`, `layoutChanged`, `sessionChanged`).
    windows_arena: ArenaAllocator.State,

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// Panes pruned by tmux (e.g. the pane process exited) while a child
    /// surface's renderer was still attached (`renderer_mutex != null`). We
    /// must NOT free such a pane's terminal yet: the child surface renders
    /// from it on its own renderer thread, and freeing it out from under that
    /// thread is a use-after-free. We retire the pane here and free it in
    /// `reapRetiredPanes` once the child detaches (its `threadExit` clears
    /// `renderer_mutex`).
    retired_panes: std.ArrayListUnmanaged(*Pane) = .empty,

    /// Resolved display title per window id, fed by the `@*` title format
    /// subscription (see `title_subscription_name`): the active pane's title
    /// (`#T`) while the window name is automatic, the manually chosen window
    /// name (`#W`) once any client has renamed the window
    /// (id=viewer-title-subscription-rename). Values are owned on
    /// `self.alloc` — NOT the windows arena — so they survive list-windows
    /// rebuilds (tmux only re-sends a subscription value when it changes, so
    /// we must retain the last one) and stay bounded to one string per window
    /// even when a pane rewrites its title rapidly. Empty/missing means
    /// "nothing resolved yet; fall back to the window name".
    /// Freed on replace and on deinit.
    pane_titles: PaneTitlesMap = .empty,

    /// Last title emitted as a `.title` action per window id, owned on
    /// `self.alloc`. One OSC title frame reaches us twice (the pane-output
    /// fingerprint and the `#T` subscription), so `emitWindowTitle` drops a
    /// repeat before it becomes a mailbox message and an app-thread reconcile.
    /// Cleared whenever the app side may need a re-send (full list-windows
    /// rebuild, forced title re-push). ROOTSHELL-TMUX (id=viewer-title-dedupe)
    last_emitted_titles: PaneTitlesMap = .empty,

    /// Whether the pane-title subscription command has been queued yet. We
    /// queue it once, after the first list-windows' capture sequence, so it
    /// trails (rather than interrupts) the startup command flow. The tmux
    /// subscription is client-scoped and persists across session changes; a
    /// replacement viewer (new session) starts false and re-queues it, which
    /// tmux deduplicates by name.
    title_subscription_queued: bool = false,

    /// A full surface reset (`ghostty_surface_tmux_reset`) was requested while a
    /// resync was already in flight, so `forceReset` could not run (it requires
    /// `.command_queue`). The in-flight resync's marker handler (`nextResync`)
    /// honors this by upgrading its rebuild into a full recapture
    /// (`flagAllPanesForReset`), so a lossy discard landing during the resync
    /// probe window is never dropped. Set by `requestReset`; cleared by the honor
    /// point or a real `forceReset`. ROOTSHELL-TMUX (id=viewer-force-reset)
    reset_pending: bool = false,

    /// Preferred window carried by a prioritized discard reset. This survives
    /// the resync probe and is resolved against authoritative topology before
    /// capture work begins. A later select-window updates it so an unrecovered
    /// tab can jump ahead at the next command boundary.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    reset_preferred_window: ?usize = null,

    /// A live reset already has valid tmux-version, pause-mode and pane-color
    /// state. Reuse those after the clean-stream marker. Client size is reused
    /// only when the currently stored size was acknowledged by tmux; otherwise
    /// it is re-sent before authoritative topology. Fresh startup/resume retains
    /// the full handshake.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    reuse_resync_metadata: bool = false,

    /// Last client size whose tracked command tmux acknowledged. Comparing this
    /// with client_cols/client_rows lets a live reset preserve its short path
    /// while still re-sending a resize that resetCommandPipeline dropped or that
    /// arrived during `.resync` (where setClientSize only stores dimensions).
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    last_applied_client_size: ?struct {
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    } = null,

    /// Incremental, interruptible discard-recovery work. Only one capture/state
    /// step from this scheduler is queued at a time; short recovery-owned setup
    /// batches (such as paired color reports) retain explicit provenance.
    /// Ordinary tracked work already in the queue runs before the next capture.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    recovery_jobs: std.ArrayListUnmanaged(RecoveryJob) = .empty,
    recovery_queued: ?RecoveryQueued = null,
    recovery_priority_window: ?usize = null,
    recovery_started: ?std.Io.Timestamp = null,
    recovery_first_window_ready: bool = false,
    /// Include panes created by a cold prioritized resume in the incremental
    /// recovery scheduler instead of the eager all-pane startup batch.
    recovery_new_panes_incrementally: bool = false,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    /// Most recent error this viewer hit, surfaced to the iOS debug snapshot
    /// (`ghostty_surface_tmux_debug_snapshot`) so a defunct viewer can explain
    /// itself. Diagnostic only — sticky (last specific write wins); never reset.
    /// ROOTSHELL-TMUX (id=control-error-code)
    last_error: control.ErrorCode = .none,

    /// ROOTSHELL-TMUX (id=viewer-resync-probe-count): number of resync probes
    /// written but not yet matched to a `%begin/%end` response. The resume path
    /// retries the probe on a cadence (all sends happen during `.resync`); the
    /// first response completes resync, the rest arrive in steady state and must
    /// be dropped WITHOUT consuming a sent-FIFO marker (a raw probe records
    /// none). The stream handler uses this count to gate that drop so it only
    /// looks for stray probe responses while some are actually outstanding —
    /// rather than substring-scanning EVERY steady-state block for the sentinel,
    /// which would drop a real tracked block whose content happens to contain it.
    outstanding_resync_probes: usize = 0,

    /// ROOTSHELL-TMUX (id=tmux-debug-read-progress): optional pointers into
    /// the gateway's debug mirror so pane-lock waits and timeouts are visible
    /// in the iOS debug snapshot. Wired by the stream handler at viewer
    /// creation; null in tests / when the mirror is absent.
    debug_progress: ?DebugProgress = null,

    pub const DebugProgress = struct {
        site: *std.atomic.Value(u8),
        pane: *std.atomic.Value(u32),
        pane_lock_timeouts: *std.atomic.Value(u64),

        /// Values mirror stream_handler.TmuxReadSite.
        pub const site_parsing: u8 = 2;
        pub const site_pane_lock: u8 = 3;
    };

    pub const CommandQueue = CircBuf(Command, undefined);
    const CommandOwner = enum { ordinary, recovery };
    const CommandOwnerQueue = CircBuf(CommandOwner, undefined);

    /// Sentinel printed by the resync probe (`display-message -p`) on a
    /// control-mode RESUME (app relaunch reattaching a live `tmux -CC` over
    /// tssh). The reattached stream may carry buffered output and in-flight
    /// `%begin/%end` blocks from before the relaunch; in `.resync` the viewer
    /// drops everything until it sees this marker echoed back in a command
    /// block, which proves the stream is clean from that point. A stale block
    /// can NEVER contain it (we emit it for the first time on resume), so it is
    /// an unambiguous "stream is clean from here" signal. ROOTSHELL-TMUX
    /// (id=viewer-resync-marker)
    pub const resync_marker = "__ROOTSHELL_TMUX_RESYNC__";

    /// The probe command sent on resume, split around a per-probe random
    /// nonce: the full command is `resync_probe_prefix ++ <nonce> ++
    /// resync_probe_suffix` (built by the stream handler at each write).
    /// `#{session_id}` is evaluated by tmux at runtime (the literal string
    /// carries no per-session value), so the probe's output gives us the
    /// attached session id alongside the marker. We need that id for the
    /// session-scoped `list-panes -s -t $<id>` pane_state command (otherwise
    /// learned only from a `%session-changed`, which does not arrive on a
    /// resume). The nonce rides inside the quoted string AFTER the session id
    /// so `parseResyncSessionId` (which stops at the first non-digit) is
    /// unaffected; its only consumer is the probe-echo detach matcher, which
    /// needs a token that public text can never contain. Plain ASCII (no raw
    /// ESC) so the gateway report stripper leaves it intact. Typed as
    /// `[]const u8` (NOT the inferred `*const [N:0]u8`) so slices concatenate
    /// cleanly for `termio.Message.writeReq`. ROOTSHELL-TMUX
    /// (id=viewer-resync-probe)
    pub const resync_probe_prefix: []const u8 = "display-message -p '" ++ resync_marker ++ " #{session_id} ";
    pub const resync_probe_suffix: []const u8 = "'\n";

    // The probe-echo detach matcher (id=probe-echo-detach) recognizes this
    // probe's shell ECHO as its static needle_prefix followed immediately by
    // the nonce and closing quote; a probe edit that breaks that shape would
    // silently disable dead-shell detach detection. ROOTSHELL-TMUX
    // (id=control-probe-echo)
    comptime {
        const ProbeEchoMatcher = @import("probe_echo.zig").ProbeEchoMatcher;
        assert(std.mem.endsWith(u8, resync_probe_prefix, ProbeEchoMatcher.needle_prefix));
        assert(resync_probe_suffix[0] == '\'');
    }

    /// Whether a written-but-unacked command was tracked (issued by the viewer
    /// through the command_queue) or untracked (a `send-keys` written directly).
    /// ROOTSHELL-TMUX (id=viewer-sent-fifo)
    pub const SentKind = enum { tracked, untracked };
    pub const SentFifo = CircBuf(SentKind, undefined);

    /// Result of classifying an incoming `%begin/%end` block against the
    /// sent-FIFO. `.empty` means we have no record for it (e.g. the startup
    /// attach block, which we never wrote) — caller should fall through to the
    /// normal startup/command handling. ROOTSHELL-TMUX (id=viewer-sent-fifo)
    pub const BlockClass = enum { tracked, untracked, empty };

    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, *Pane);
    // ROOTSHELL-TMUX (id=viewer-pane-titles-map): active-pane title (#T) per
    // window id, fed by the `@*:#{pane_title}` subscription. Named so the
    // topology snapshot can resolve the same title precedence (see
    // resolveWindowTitle / Surface_tmux planTmuxReconcile).
    pub const PaneTitlesMap = std.AutoHashMapUnmanaged(usize, []u8);

    const RecoveryJob = struct {
        window_id: usize,
        pane_id: usize,
        /// Number of completed capture steps: primary history/visible, then
        /// alternate history/visible. Four means ready for window pane_state.
        completed: u3 = 0,
        /// Cold resume discovers every already-running server pane as locally
        /// new. Delay its color reports until this prioritized job is selected,
        /// so background panes do not add two round trips ahead of the active
        /// tab. A pane truly created during live recovery reports immediately
        /// at admission instead.
        colors_before_capture: bool = false,
    };

    const RecoveryQueued = struct {
        window_id: usize,
        pane_id: ?usize,
        /// 0...3 are the four capture steps; 4 is window-scoped pane_state.
        step: u3,
        /// A priority change or pane move invalidated this command. Its reply
        /// still has to drain from tmux's serial command stream, but must not be
        /// applied or advance the old job: the pane has to restart at history
        /// to avoid a scrollback gap across the interruption/topology boundary.
        preempted: bool = false,
    };

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// The command stream appears desynchronized but the control connection
        /// is still alive. The caller should force a live resync/rebuild.
        recover,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        /// The active pane changed in tmux. The caller should update
        /// focus to the specified window and pane. This is emitted in
        /// response to `%window-pane-changed` notifications from tmux.
        ///
        /// Rationale for tmux→Ghostty focus sync: Mitchell's upstream
        /// viewer ignores `%window-pane-changed` because "we handle our
        /// own focus." However, in multi-client scenarios (SSH pair
        /// programming, automation scripts, `tmux select-pane` from
        /// another terminal), the active pane can change externally.
        /// Without this sync, Ghostty's visible focus would diverge
        /// from tmux's actual active pane. We keep bidirectional focus
        /// sync (Ghostty→tmux via `select-pane`, tmux→Ghostty via
        /// this action) to stay consistent in these real-world cases.
        focus: struct {
            window_id: usize,
            pane_id: usize,
        },

        /// A tmux window was renamed. The caller should update the
        /// tab title for the given window ID.
        title: struct {
            window_id: usize,
            /// Window name, stored on the viewer's windows arena.
            /// Valid until the next list-windows refresh.
            name: []const u8,
        },

        /// The tmux session was renamed. The caller should update the
        /// Ghostty window title.
        session_title: struct {
            /// Session name, stored on the viewer's windows arena.
            /// Valid until the next list-windows refresh.
            name: []const u8,
        },

        /// A pane's pause state changed. When `paused` is true, tmux
        /// has stopped sending `%output` for this pane (output is
        /// buffered server-side). The caller should send
        /// `refresh-client -A '%<pane_id>:continue'` to resume, e.g.
        /// when the user switches focus to the paused pane.
        pane_paused: struct {
            pane_id: usize,
            paused: bool,
        },

        /// A pane's mode changed in tmux. This is emitted in response
        /// to `%pane-mode-changed` notifications after querying the
        /// actual mode via `display-message`. The caller can use this
        /// to show visual indicators (e.g., copy mode overlay).
        pane_mode_changed: struct {
            pane_id: usize,
            mode: PaneMode,
        },

        /// A message from the tmux server (via `display-message` or
        /// server-level informational/error messages). The runtime can
        /// surface this in a status bar, toast, or log view.
        message: struct {
            text: []const u8,
        },

        /// Response to an app-issued query command (`queueUserQuery`).
        /// `body` is the raw `%begin/%end` block content (or the `%error`
        /// body when `is_err`), stored on the action arena — valid only
        /// until the next call to `next()`. An empty body with `is_err`
        /// means the query was dropped before tmux answered it (viewer
        /// reset/teardown); the app should fail the pending request.
        /// ROOTSHELL-TMUX (id=viewer-user-query)
        command_response: struct {
            /// App-provided correlation tag, echoed back verbatim.
            tag: u32,
            body: []const u8,
            is_err: bool,
        },

        /// The set of sessions on the tmux server changed (a session was
        /// created or destroyed), or another client attached, detached, or
        /// switched sessions — anything that can change what a session
        /// list UI displays (names, counts, attached flags). The app
        /// should refresh any visible session list. Debounce lives
        /// app-side. ROOTSHELL-TMUX (id=viewer-sessions-changed)
        sessions_changed,

        /// The identity of the session THIS client is attached to.
        /// Emitted when startup completes, on `%session-changed` (a
        /// switch), and on `%session-renamed`. The name is stored on the
        /// windows arena — valid until the next list-windows refresh, so
        /// the caller must copy it. ROOTSHELL-TMUX (id=viewer-session-info)
        session_info: struct {
            id: usize,
            name: []const u8,
        },

        /// A pane requested an OSC 52 clipboard SET. The caller should write
        /// `data` (still base64-encoded) to the system clipboard. `kind` is the
        /// selection ('c'/'s'/'p'). `data` is stored on the action arena — valid
        /// only until the next call to `next()`. ROOTSHELL-TMUX
        /// (id=viewer-clipboard)
        pane_clipboard_write: struct {
            kind: u8,
            data: []const u8,
        },

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        switch (u_field.type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout: Layout,
        /// Active pane for this tmux window. In list-windows context,
        /// `pane_id` is the active pane for the window.
        active_pane_id: usize = 0,
        /// tmux window index (display order; may be non-contiguous). The app
        /// sorts its tmux tabs by this so new-window -a / move-window /
        /// swap-window are reflected. ROOTSHELL-TMUX (id=tmux-window-order)
        index: usize = 0,
        /// True when the window is zoomed (one pane shown fullscreen). The
        /// zoomed pane is the window's active pane (`active_pane_id`). Set from
        /// `#{window_zoomed_flag}` (list-windows) and the `Z` flag of
        /// `%layout-change`. ROOTSHELL-TMUX (id=tmux-zoom)
        zoomed: bool = false,
        /// Window name from tmux (e.g., "bash", "vim"). Stored on the
        /// shared windows arena and valid until the next list-windows
        /// refresh. Empty slice if not yet known.
        name: []const u8 = "",
    };

    /// ROOTSHELL-TMUX (id=viewer-pane-osc): a per-pane OSC event captured from
    /// live `%output` and forwarded to the pane's OWN child surface (progress
    /// OSC 9;4, pwd OSC 7, desktop notification OSC 9/777). Terminal-layer type
    /// (no apprt dependency); `termio/Tmux.zig` turns it into the matching
    /// `apprt.surface.Message`. Strings are borrowed for the duration of the
    /// post call only (the message-builder copies them synchronously).
    pub const PaneOscEvent = union(enum) {
        progress: osc.Command.ProgressReport,
        pwd: []const u8,
        notification: struct { title: []const u8, body: []const u8 },
    };

    pub const Pane = struct {
        /// I/O implementation used for this pane's renderer mutex.
        /// ROOTSHELL-TMUX (id=viewer-io)
        io: std.Io,

        terminal: Terminal,
        stream: TerminalStream,

        /// Cell pixel size reported by the child surface's renderer (its font
        /// cell metrics), forwarded through `Tmux.updateViewerPaneCell` on every
        /// child resize. Zero until a child has attached and reported. Used to
        /// derive the pane terminal's `width_px`/`height_px` (see
        /// `recomputePixelSize`) so auto-sized iTerm2 images (imgcat) and
        /// `CSI 14/16/18 t` cell-size replies work — the gateway never sizes the
        /// pane terminal in pixels, only in cells. ROOTSHELL-TMUX
        /// (id=tmux-pane-pixel-geometry)
        cell_width: u32 = 0,
        cell_height: u32 = 0,

        /// Mutex protecting concurrent access to `terminal`. This is set
        /// by the child surface's tmux backend during `threadEnter` to
        /// point at the child's `renderer_state.mutex`. Before it is set
        /// (null), no child renderer is reading, so no locking is needed.
        ///
        /// The viewer acquires this mutex in all terminal-write paths
        /// (`receivedOutput`, `receivedPaneHistory`, `receivedPaneState`) to
        /// coordinate with the child surface's
        /// renderer thread.
        renderer_mutex: ?*std.Io.Mutex = null,

        /// Opaque wake callback registered by the child surface's tmux
        /// backend in `Tmux.threadEnter` (cleared in `threadExit`). The viewer
        /// invokes it after writing to `terminal` so the child surface's
        /// renderer thread is woken to draw the new content. The child's own
        /// IO thread (the tmux backend) never processes this output, so
        /// without an explicit wake the pane would not repaint until some
        /// unrelated event. Kept opaque (a fn pointer + context) so the
        /// terminal layer stays decoupled from the IO/renderer/xev layer.
        wake_ctx: ?*anyopaque = null,
        wake_fn: ?*const fn (?*anyopaque) void = null,

        /// ROOTSHELL-TMUX (id=viewer-pane-osc): cross-thread post of a per-pane
        /// OSC event to THIS pane's own child surface mailbox. Published by the
        /// child in `attachRenderer` and cleared in `detachRenderer`, exactly
        /// like `wake_ctx`/`wake_fn` — the gateway loads them with acquire inside
        /// a `lockRenderer` window and the `renderer_users` drain keeps `ctx`
        /// (the child's io) valid for the call. Null when no child is attached.
        osc_post_ctx: ?*anyopaque = null,
        osc_post_fn: ?*const fn (?*anyopaque, PaneOscEvent) void = null,

        /// True from the moment this pane's terminal is created (io thread,
        /// `initLayout`) until a child surface attaches its renderer
        /// (`Tmux.threadEnter` clears it). While true, a child surface for this
        /// pane is "en route": the reconcile op has been (or will be) emitted but
        /// the child hasn't bound yet, so `renderer_mutex` is still null. The
        /// viewer must NOT free the pane in this window or the child later binds
        /// to freed memory (the `tmux -CC attach` / `%session-changed` crash).
        /// All free paths treat this like `renderer_mutex != null`.
        pending_attach: bool = false,

        /// Keep-alive holds, independent of renderer-attach state. Taken by (a)
        /// in-flight topology snapshots / reconcile payloads that carry a RAW
        /// pointer to this pane across to the app (and Swift) threads, and (b) the
        /// in-progress child detach (`detachRenderer` holds one across its whole
        /// flush/clear/drain so a concurrent release can't reap the pane mid-detach
        /// — id=viewer-detach-hold). Independent of attach state because an
        /// existing pane's child can detach (clearing `renderer_mutex`) WHILE a
        /// reconcile payload still references the pane, so attach state alone
        /// cannot guard the pointer. Acquired on the IO thread when a snapshot/payload captures
        /// the pointer; released on the app thread when that snapshot/payload is
        /// freed. While > 0 no free path may destroy the pane (see `isRetained`).
        /// Accessed from both threads — always via the atomic helpers below.
        /// ROOTSHELL-TMUX (id=viewer-snapshot-refcount)
        snapshot_refs: usize = 0,

        /// Count of gateway IO-thread accesses currently inside the
        /// `lockRenderer`/`unlockRenderer` window (load `renderer_mutex` -> lock ->
        /// write terminal -> unlock). The child's `detachRenderer` clears
        /// `renderer_mutex` then drains this to zero before returning, so a gateway
        /// that loaded the mutex pointer just before the clear cannot lock the
        /// (about-to-be-freed) child mutex, nor read the (about-to-be-reaped)
        /// terminal, after detach completes. Incremented only by the gateway IO
        /// thread (single writer, so 0 or 1), read by the child IO thread; seq_cst
        /// throughout to order it against the `renderer_mutex` store/load. See
        /// `lockRenderer`. ROOTSHELL-TMUX (id=viewer-renderer-users-drain)
        renderer_users: usize = 0,

        /// Orphan-graveyard linkage. ROOTSHELL-TMUX (id=viewer-orphan-graveyard):
        /// when the viewer is torn down (`%exit` / `.broken` / `%session-changed`)
        /// while this pane is still retained (a child renderer or an in-flight
        /// snapshot/payload references it), ownership transfers to the
        /// process-global graveyard list instead of leaking — the LAST holder to
        /// release (child `threadExit` or snapshot/payload deinit) reaps it. Only
        /// touched under `orphan_mutex`, so plain (non-atomic) fields are fine.
        orphan_next: ?*Pane = null,
        orphan_alloc: ?Allocator = null,

        // ROOTSHELL-TMUX (id=viewer-pane-atomics): the four fields above
        // (`renderer_mutex`, `wake_ctx`, `wake_fn`, `pending_attach`) form a
        // cross-thread handshake between the gateway (parent) IO thread that owns
        // this Viewer and the child surface's IO thread (`Tmux.threadEnter` /
        // `threadExit`). On weakly-ordered targets (ARM64 / Apple Silicon, the
        // shipping target) plain stores have no inter-thread ordering, so the
        // gateway could observe `pending_attach == false` before the matching
        // `renderer_mutex` write (free-guard frees a pane the child is binding) or
        // `wake_fn` set while `wake_ctx` is still null (wake deref of null). ALL
        // access goes through the methods below, which publish with release and
        // consume with acquire so a half-built handshake is never observed.
        //
        // The teardown LIFETIME window (the child surface freeing its
        // `renderer_state` mutex + wake target while a gateway still references
        // them) is closed by `detachRenderer`: it flushes the renderer, clears the
        // handshake, then DRAINS in-flight gateway accesses via the
        // `renderer_users` counter (id=viewer-renderer-users-drain) so no gateway
        // can lock the freed mutex or read the reaped terminal after detach
        // returns. Gateway terminal access must go through `lockRenderer` /
        // `unlockRenderer` for that drain to be correct.

        /// Whether this pane has been fully initialized with captured
        /// content and terminal state from tmux. Output notifications
        /// are suppressed until this is true to avoid displaying
        /// partial/stale data before the capture-pane sequence completes.
        initialized: bool = false,

        // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock): deferred work for a
        // pane whose renderer mutex was contended past its budget. The
        // control channel must NEVER block indefinitely on a pane renderer
        // (a stuck pane renderer would starve every other pane AND all
        // command replies — the attach-wedge bug), so contended writes spill
        // here and are applied at the next successful lock window
        // (`flushPaneDeferred`). All fields are touched only by the thread
        // holding `Termio.tmux_mutex`, so they stay plain (non-atomic).

        /// Live `%output` bytes (already unescaped) that couldn't be written
        /// under the renderer mutex in time. Flushed before any newer data.
        pending_vt: std.ArrayList(u8) = .empty,

        /// The spill overflowed its cap and content was discarded; the next
        /// successful lock window re-fetches the pane's visible content from
        /// tmux (the source of truth) instead of replaying a hole.
        pending_dropped: bool = false,

        /// A terminal resize that timed out on the renderer mutex; applied
        /// at the next successful lock window.
        pending_resize: ?struct {
            cols: size.CellCountInt,
            rows: size.CellCountInt,
        } = null,

        /// Capture-reply retries consumed after renderer-lock timeouts
        /// (capture replies are re-queued rather than copied; bounded so a
        /// permanently-stuck pane renderer can't loop forever).
        capture_retries: u8 = 0,

        /// This pane's slice of the last session-scoped pane_state reply
        /// timed out on the renderer lock; the completion arm must not mark
        /// it initialized (the alt-screen swap is gated on !initialized) and
        /// re-queues a pane_state to revisit it.
        state_pending: bool = false,

        /// A history/visible capture for this pane timed out on the renderer
        /// lock and its retry suffix (capture(s) + trailing pane_state) is
        /// still queued. The completion arm must not mark the pane
        /// initialized off an EARLIER pane_state — live %output would
        /// interleave before the retry replay. Cleared when a capture for
        /// this pane succeeds or gives up.
        ///
        /// KNOWN IMPRECISION (accepted): an already-queued OLDER capture for
        /// this pane can succeed first and clear the flag before the retry
        /// suffix lands, letting an earlier pane_state initialize the pane.
        /// This is convergent, not corrupting: retried captures are FRESH
        /// (tmux re-captures at execution, including any interleaved live
        /// output) and receivedPaneHistory clears screen+scrollback before
        /// replaying, so the suffix re-establishes a consistent state. Cost
        /// is a brief redraw, vs. generation-tracking complexity.
        capture_pending: bool = false,

        /// A pause-after recapture is in flight for this pane: the `%pause`
        /// handler parked it uninitialized and queued the
        /// history/visible/state batch to recover the output tmux discarded
        /// on pause. Distinguishes a pause-recapture uninit from a STARTUP
        /// uninit (which never set this), so a re-pause mid-recapture can be
        /// scheduled (`recapture_again`) instead of dropped. Cleared when the
        /// pane is finally re-initialized. ROOTSHELL-TMUX
        /// (id=pause-after-recover)
        pause_recapture: bool = false,

        /// The pane paused AGAIN while a pause-recapture was still in flight,
        /// so tmux discarded a fresh gap that the in-flight batch may not
        /// cover. The pane_state completion arm re-runs the recapture
        /// (instead of initializing) when it would otherwise mark this pane
        /// initialized, then clears this. Self-healing: as long as pauses
        /// keep arriving, recaptures keep being scheduled; the final batch
        /// initializes the pane. ROOTSHELL-TMUX (id=pause-after-recover)
        recapture_again: bool = false,

        /// A full surface RESET (`forceReset`, `ghostty_surface_tmux_reset`) has
        /// flagged this pane for re-capture. Unlike the wedge `forceResync` —
        /// which preserves `self.panes` and so reuses every pane with NO
        /// recapture — the reset path force-recaptures every pane to recover from
        /// a lossy reconnect that dropped bytes mid-`%output`/control block. The
        /// post-resync `syncLayouts` reads-and-clears this: a reused pane carrying
        /// it is captured (history+visible+state, self-clearing via
        /// `eraseDisplay`) instead of skipped. Read/cleared for ALL panes in
        /// `syncLayouts`, so it never leaks into a later wedge resync.
        /// ROOTSHELL-TMUX (id=viewer-force-reset)
        reset_recapture: bool = false,

        /// This pane belongs to an incremental full-reset recovery job. Any
        /// unrelated session-wide pane_state must leave it uninitialized; only
        /// its own window-scoped state command may release live output.
        /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
        recovery_pending: bool = false,

        /// Whether this pane is currently paused by tmux. When true,
        /// tmux is buffering output server-side and not sending
        /// `%output` for this pane. Set by `%pause` notification,
        /// cleared by `%continue`.
        paused: bool = false,

        /// The current mode of this pane as reported by tmux. Updated
        /// via `display-message -p '#{pane_mode}'` queries triggered by
        /// `%pane-mode-changed` notifications.
        mode: PaneMode = .normal,

        /// Query replies generated by this pane's terminal while processing
        /// live `%output` (e.g. kitty-keyboard, DECRQM, OSC 4/12 replies for
        /// queries tmux itself does not answer). Each entry is one complete
        /// reply from a single `write_pty` call. Drained, filtered, and routed
        /// back to the app as `send-keys` after each `%output` feed (see
        /// `flushPaneResponses`). Only `pane.stream` (live output) installs the
        /// router; capture-pane replays use throwaway readonly streams so stale
        /// queries in history never produce replies.
        responses: std.ArrayList([]const u8) = .empty,

        /// OSC 52 clipboard SET requests captured from this pane's live
        /// `%output`. ROOTSHELL-TMUX (id=viewer-clipboard): tmux relays the
        /// app's raw OSC 52 bytes (a control client has no tty for tmux to set
        /// the clipboard itself), so the pane stream's `clipboard_write` effect
        /// buffers each here. Drained after every `%output` feed and emitted as
        /// `pane_clipboard_write` actions routed to the app's clipboard. Each
        /// `data` is an owned copy of the still-base64-encoded payload. Only
        /// `pane.stream` (live output) installs the effect; capture-pane replays
        /// use throwaway readonly streams so stale OSC 52 in history is ignored.
        clipboard_writes: std.ArrayList(struct { kind: u8, data: []const u8 }) = .empty,

        /// ROOTSHELL-TMUX (id=streamterm-tmux-passthrough): inner bytes recovered
        /// from `ESC P tmux; ...` passthrough envelopes seen in this pane's live
        /// `%output` (e.g. yazi's wrapped Kitty graphics). The pane handler can
        /// only buffer (it has no Stream reference), so it appends here via the
        /// `dcs_passthrough` effect; `receivedOutput` re-feeds them through the
        /// pane stream after the `%output` feed so the wrapped sequence takes
        /// effect. Only `pane.stream` (live output) installs the effect; capture
        /// replays use throwaway readonly streams, so history is unaffected.
        replay: std.ArrayList(u8) = .empty,

        /// ROOTSHELL-TMUX (id=alt-screen-fix): deferred `capture-pane` VISIBLE
        /// captures, stashed by `receivedPaneVisible` and applied to the correct
        /// FINAL terminal screen by `receivedPaneState` once `alternate_on` is
        /// known. `*_primary` is the no-`-a` capture (the active grid: the
        /// alt-screen app when the pane is in its alternate screen, else the
        /// normal screen); `*_alternate` is the `-a` capture (the saved grid: the
        /// normal screen's last visible row(s), empty when no alternate screen).
        /// Routing them here — instead of the old whole-`Screen` pointer swap —
        /// keeps the normal-screen scrollback (captured by the no-`-a`
        /// `pane_history` into `.primary`, which has the real scrollback budget)
        /// from being stranded on the 0-scrollback alternate screen. Each is an
        /// owned copy of the still-encoded visible bytes; freed after application
        /// in `receivedPaneState`, or in `Pane.deinit`.
        captured_visible_primary: ?[]const u8 = null,
        captured_visible_alternate: ?[]const u8 = null,

        /// Child IO thread (`Tmux.threadEnter`): publish the attach handshake.
        /// Stores the wake context/fn and renderer mutex with release ordering,
        /// then clears `pending_attach` LAST, so a gateway acquire-load that sees
        /// `!pending_attach` is guaranteed to also see `renderer_mutex`, and one
        /// that sees `wake_fn` is guaranteed to also see `wake_ctx`.
        /// ROOTSHELL-TMUX (id=viewer-pane-atomics)
        pub fn attachRenderer(
            self: *Pane,
            mutex: *std.Io.Mutex,
            wake_ctx: *anyopaque,
            wake_fn: *const fn (?*anyopaque) void,
            osc_post_ctx: *anyopaque,
            osc_post_fn: *const fn (?*anyopaque, PaneOscEvent) void,
        ) void {
            @atomicStore(?*anyopaque, &self.wake_ctx, wake_ctx, .release);
            @atomicStore(?*const fn (?*anyopaque) void, &self.wake_fn, wake_fn, .release);
            // Same publish ordering as wake (ctx before fn): a gateway that
            // acquire-loads a non-null fn is guaranteed to see ctx.
            // ROOTSHELL-TMUX (id=viewer-pane-osc)
            @atomicStore(?*anyopaque, &self.osc_post_ctx, osc_post_ctx, .release);
            @atomicStore(?*const fn (?*anyopaque, PaneOscEvent) void, &self.osc_post_fn, osc_post_fn, .release);
            @atomicStore(?*std.Io.Mutex, &self.renderer_mutex, mutex, .release);
            @atomicStore(bool, &self.pending_attach, false, .release);
        }

        /// Child IO thread (`Tmux.threadExit`): tear down the attach handshake so
        /// the gateway stops accessing this pane and the child can free its
        /// renderer_state (mutex + wake target) without a use-after-free.
        ///
        /// 1. FLUSH the renderer thread while `renderer_mutex` is STILL registered
        ///    (the pane stays retained, so a concurrent snapshot/payload release
        ///    cannot reap it mid-flush): lock/unlock the mutex the renderer reads
        ///    this pane's terminal under, draining any in-flight render read.
        /// 2. Clear the handshake — `wake_fn` first so a concurrent wake skips,
        ///    then the mutex so future gateway loads see null and won't lock.
        /// 3. DRAIN: spin until `renderer_users` hits 0, so a gateway that loaded
        ///    the mutex pointer just BEFORE step 2 and is mid `lockRenderer` cannot
        ///    lock the (about-to-be-freed) mutex nor read the (about-to-be-reaped)
        ///    terminal after we return. seq_cst orders the drain against the
        ///    `renderer_mutex` store and the gateway's increment+load. Bounded: the
        ///    gateway is a single thread, so at most one access is outstanding.
        ///
        /// Closes the renderer-mutex / terminal lifetime gap (findings: a gateway
        /// that already loaded the mutex but had not locked it). ROOTSHELL-TMUX
        /// (id=viewer-renderer-users-drain)
        pub fn detachRenderer(self: *Pane) void {
            // (0) Hold a keep-alive ref for the WHOLE detach. Once we null
            // `renderer_mutex` below, `isRetained` drops the child reason, and a
            // concurrent snapshot/payload `releaseSnapshotRef` (app thread) could
            // see the snapshot count hit 0 and reap this pane out from under us
            // while we are still flushing / draining `self`. This ref keeps
            // `isRetained` true throughout (detach is itself a retention reason),
            // and releasing it at the end performs the FINAL reap (last-releaser-
            // frees) once the detach/drain handoff is complete. ROOTSHELL-TMUX
            // (id=viewer-detach-hold). Entry is safe: `renderer_mutex` is still set
            // here (this child is attached), so the pane is retained right now.
            self.acquireSnapshotRef();

            const mutex = @atomicLoad(?*std.Io.Mutex, &self.renderer_mutex, .seq_cst);
            if (mutex) |m| {
                m.lockUncancelable(self.io);
                m.unlock(self.io);
            }
            @atomicStore(?*const fn (?*anyopaque) void, &self.wake_fn, null, .release);
            @atomicStore(?*anyopaque, &self.wake_ctx, null, .release);
            // Clear the OSC post handshake the same way (fn first), so a
            // concurrent gateway post skips. ROOTSHELL-TMUX (id=viewer-pane-osc)
            @atomicStore(?*const fn (?*anyopaque, PaneOscEvent) void, &self.osc_post_fn, null, .release);
            @atomicStore(?*anyopaque, &self.osc_post_ctx, null, .release);
            @atomicStore(?*std.Io.Mutex, &self.renderer_mutex, null, .seq_cst);
            while (@atomicLoad(usize, &self.renderer_users, .seq_cst) > 0) {
                std.atomic.spinLoopHint();
            }

            // Release the detach hold. If it was the pane's last hold (an orphan
            // whose viewer is gone, with no child and no other snapshot/payload
            // refs), this reaps `self`. `self` may be freed here; do not touch it
            // afterward.
            self.releaseSnapshotRef();
        }

        /// Gateway IO thread: enter the renderer-access window for a terminal
        /// write — register as a `renderer_users` user (seq_cst so `detachRenderer`
        /// observes it), load `renderer_mutex`, and lock it if a child is attached.
        /// Returns the locked mutex (or null). MUST be paired with
        /// `unlockRenderer`. ROOTSHELL-TMUX (id=viewer-renderer-users-drain)
        pub fn lockRenderer(self: *Pane) ?*std.Io.Mutex {
            _ = @atomicRmw(usize, &self.renderer_users, .Add, 1, .seq_cst);
            const m = @atomicLoad(?*std.Io.Mutex, &self.renderer_mutex, .seq_cst);
            if (m) |mu| mu.lockUncancelable(self.io);
            return m;
        }

        /// Gateway IO thread: leave the renderer-access window opened by
        /// `lockRenderer` — unlock the mutex (if any) then drop the
        /// `renderer_users` registration. ROOTSHELL-TMUX
        /// (id=viewer-renderer-users-drain)
        pub fn unlockRenderer(self: *Pane, m: ?*std.Io.Mutex) void {
            if (m) |mu| mu.unlock(self.io);
            _ = @atomicRmw(usize, &self.renderer_users, .Sub, 1, .seq_cst);
        }

        /// Recompute the pane terminal's pixel geometry from its current cell
        /// grid and the child surface's reported cell size. No-op until a child
        /// has reported a cell size. Without this the pane terminal has
        /// `width_px == height_px == 0`, which makes an auto-sized Kitty/iTerm2
        /// placement collapse to a 0x0 grid (`Placement.gridSize` divides by the
        /// per-cell pixel size) — so imgcat images render invisibly. Caller must
        /// hold the pane renderer lock (the gateway reads `width_px` while
        /// dispatching images under the same lock). ROOTSHELL-TMUX
        /// (id=tmux-pane-pixel-geometry)
        pub fn recomputePixelSize(self: *Pane) void {
            if (self.cell_width == 0 or self.cell_height == 0) return;
            self.terminal.width_px = @as(u32, @intCast(self.terminal.cols)) * self.cell_width;
            self.terminal.height_px = @as(u32, @intCast(self.terminal.rows)) * self.cell_height;
        }

        /// The pane's cell size for `Terminal.Resize.cell_size_px`, or null
        /// when we don't know it yet (the gateway sizes panes in cells only,
        /// so the app may not have pushed a cell size yet). Null leaves the
        /// terminal's pixel geometry untouched, matching `recomputePixelSize`.
        /// ROOTSHELL-TMUX (id=tmux-pane-pixel-geometry)
        pub fn cellSizePx(self: *const Pane) @FieldType(Terminal.Resize, "cell_size_px") {
            if (self.cell_width == 0 or self.cell_height == 0) return null;
            return .{ .width = self.cell_width, .height = self.cell_height };
        }

        /// Result of a bounded renderer-lock attempt. `.acquired` (with the
        /// possibly-null mutex) must be paired with `unlockRenderer`;
        /// `.timeout` has already dropped the `renderer_users` registration
        /// and must NOT be unlocked. ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
        pub const BoundedLock = union(enum) {
            acquired: ?*std.Io.Mutex,
            timeout,
        };

        /// Like `lockRenderer` but gives up after `budget_ns` instead of
        /// blocking indefinitely. The control channel calls this for every
        /// pane-terminal write so a stuck pane renderer (holding its mutex
        /// across a blocked frame) can never starve the channel; contended
        /// work spills to the pane's pending state instead. Preserves the
        /// `renderer_users` retain/drain protocol: the registration is held
        /// for the whole attempt (so `detachRenderer` cannot free the mutex
        /// under our tryLock) and dropped on timeout. ROOTSHELL-TMUX
        /// (id=viewer-pane-bounded-lock)
        pub fn lockRendererBounded(self: *Pane, budget_ns: u64) BoundedLock {
            _ = @atomicRmw(usize, &self.renderer_users, .Add, 1, .seq_cst);
            const m = @atomicLoad(?*std.Io.Mutex, &self.renderer_mutex, .seq_cst);
            const mu = m orelse return .{ .acquired = null };
            if (mu.tryLock()) return .{ .acquired = m };
            const started: std.Io.Timestamp = .now(self.io, .awake);
            while (started.durationTo(.now(self.io, .awake)).nanoseconds < budget_ns) {
                std.Io.sleep(self.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
                if (mu.tryLock()) return .{ .acquired = m };
            }
            _ = @atomicRmw(usize, &self.renderer_users, .Sub, 1, .seq_cst);
            return .timeout;
        }

        /// Gateway IO thread: whether a child renderer is attached OR en route,
        /// in which case this pane's terminal must NOT be freed. Loads
        /// `pending_attach` with acquire FIRST: if the child has cleared it, the
        /// paired release store guarantees the `renderer_mutex` it published is
        /// visible to the subsequent load. Reading `renderer_mutex` first could
        /// observe a stale null and free a pane the child is mid-bind on.
        pub fn isHeldByChild(self: *const Pane) bool {
            if (@atomicLoad(bool, &self.pending_attach, .acquire)) return true;
            return @atomicLoad(?*std.Io.Mutex, &self.renderer_mutex, .acquire) != null;
        }

        /// Gateway IO thread: invoke the child's wake callback if one is
        /// registered (after writing to this pane's terminal).
        pub fn wake(self: *const Pane) void {
            const f = @atomicLoad(?*const fn (?*anyopaque) void, &self.wake_fn, .acquire);
            if (f) |func| func(@atomicLoad(?*anyopaque, &self.wake_ctx, .acquire));
        }

        /// Gateway IO thread: forward a per-pane OSC event to the child surface's
        /// mailbox if a child is attached. MUST be called inside a
        /// `lockRenderer`/`unlockRenderer` window so the `renderer_users` drain
        /// keeps the child io (`ctx`) alive for the call (the effect that calls
        /// this fires during `receivedOutput`'s `nextSlice`, which holds it).
        /// ROOTSHELL-TMUX (id=viewer-pane-osc)
        pub fn postOscEvent(self: *const Pane, event: PaneOscEvent) void {
            const f = @atomicLoad(?*const fn (?*anyopaque, PaneOscEvent) void, &self.osc_post_fn, .acquire);
            if (f) |func| func(@atomicLoad(?*anyopaque, &self.osc_post_ctx, .acquire), event);
        }

        /// Gateway IO thread: clear the en-route flag (reset paths). The
        /// creation-time `pending_attach = true` initializer runs before the pane
        /// is published into `panes`, so it stays a plain store.
        pub fn clearPendingAttach(self: *Pane) void {
            @atomicStore(bool, &self.pending_attach, false, .release);
        }

        /// Take a hold for an in-flight snapshot/payload that captured a raw
        /// pointer to this pane (IO thread, at snapshot/payload build). Pairs
        /// with `releaseSnapshotRef`. ROOTSHELL-TMUX (id=viewer-snapshot-refcount)
        pub fn acquireSnapshotRef(self: *Pane) void {
            _ = @atomicRmw(usize, &self.snapshot_refs, .Add, 1, .acq_rel);
        }

        /// Drop a hold taken by `acquireSnapshotRef` (app thread, when the
        /// snapshot/payload is freed). After this returns the IO thread may
        /// destroy the pane if nothing else retains it, so the caller must not
        /// touch the pane again. ROOTSHELL-TMUX (id=viewer-snapshot-refcount)
        pub fn releaseSnapshotRef(self: *Pane) void {
            _ = @atomicRmw(usize, &self.snapshot_refs, .Sub, 1, .acq_rel);
            // May now be a fully-released orphan whose viewer is gone — reap it.
            // After this `self` may be freed; do not touch it again.
            reapOrphan(self);
        }

        /// Whether any in-flight snapshot/payload still holds this pane.
        pub fn hasSnapshotRefs(self: *const Pane) bool {
            return @atomicLoad(usize, &self.snapshot_refs, .acquire) > 0;
        }

        /// Whether this pane must NOT be freed: a child renderer is attached or
        /// en route, OR an in-flight snapshot/payload still references its raw
        /// pointer. Every viewer free path checks this. ROOTSHELL-TMUX
        /// (id=viewer-snapshot-refcount)
        pub fn isRetained(self: *const Pane) bool {
            return self.isHeldByChild() or self.hasSnapshotRefs();
        }

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            for (self.responses.items) |chunk| alloc.free(chunk);
            self.responses.deinit(alloc);
            for (self.clipboard_writes.items) |cw| alloc.free(cw.data);
            self.clipboard_writes.deinit(alloc);
            self.replay.deinit(alloc);
            // ROOTSHELL-TMUX (id=alt-screen-fix): deferred visible captures.
            if (self.captured_visible_primary) |b| alloc.free(b);
            if (self.captured_visible_alternate) |b| alloc.free(b);
            self.pending_vt.deinit(alloc); // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
            self.stream.deinit();
            self.terminal.deinit(alloc);
        }
    };

    pub const PaneMode = enum {
        /// Normal terminal mode (no special mode active).
        normal,
        /// Copy mode — tmux's scrollback/selection mode.
        copy,
        /// View mode — read-only copy mode (e.g., from `capture-pane -e`).
        view,

        /// Parse a tmux `#{pane_mode}` string into this enum.
        /// Empty string = normal, "copy-mode" = copy, "view-mode" = view.
        /// Unknown mode names are logged and treated as normal.
        pub fn fromString(s: []const u8) PaneMode {
            if (s.len == 0) return .normal;
            if (std.mem.eql(u8, s, "copy-mode")) return .copy;
            if (std.mem.eql(u8, s, "view-mode")) return .view;
            log.info("unknown pane mode: {s}", .{s});
            return .normal;
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(
        io: std.Io,
        alloc: Allocator,
        client_cols: size.CellCountInt,
        client_rows: size.CellCountInt,
    ) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        var command_owners: CommandOwnerQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_owners.deinit(alloc);

        // Ordered record of sent (tracked/untracked) commands awaiting their
        // %begin/%end block. ROOTSHELL-TMUX (id=viewer-sent-fifo)
        var sent_fifo: SentFifo = try .init(alloc, SENT_FIFO_INITIAL);
        errdefer sent_fifo.deinit(alloc);

        return .{
            .io = io,
            .alloc = alloc,
            .state = .startup,
            .startup_got_block = false,
            .startup_got_session = false,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .session_name = "",
            .tmux_version = "",
            .client_cols = client_cols,
            .client_rows = client_rows,
            .command_in_flight = false,
            .command_queue = command_queue,
            .command_owners = command_owners,
            .sent_fifo = sent_fifo,
            .windows = .empty,
            .windows_arena = .{},
            .panes = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            self.windows.deinit(self.alloc);
            self.windows_arena.promote(self.alloc).deinit();
        }
        {
            // Normal on a mid-activity detach, but on an unexplained teardown a
            // non-empty queue points at lost command responses — log the depth
            // so a desync is diagnosable from the shutdown trace.
            if (!self.command_queue.empty()) log.info(
                "viewer deinit with {} unanswered queued commands",
                .{self.command_queue.len()},
            );
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
            self.command_owners.deinit(self.alloc);
        }
        // ROOTSHELL-TMUX (id=viewer-sent-fifo): markers are plain enums, no
        // per-entry free. A fresh viewer (sessionChanged) starts with an empty
        // FIFO; straggler blocks owed for pre-reset commands then classify as
        // `.empty` and fall through to the existing "unexpected block" handling
        // exactly as before this change (no carry-forward — carrying a tracked
        // marker into a new session could mis-match a new in-flight command).
        self.sent_fifo.deinit(self.alloc);
        self.recovery_jobs.deinit(self.alloc);
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| {
                const pane = kv.value_ptr.*;
                // A child surface's renderer may still point at this pane's
                // terminal (renderer_mutex != null => still attached). The
                // viewer can be deinited while children are alive — tmux's
                // stream_handler frees the viewer synchronously on `%exit`, and
                // `sessionChanged` deinits the old viewer on `%session-changed`,
                // both BEFORE the child pane surfaces have been torn down. Freeing
                // a retained pane's terminal here would UAF that renderer thread
                // (crash in updateFrame/updateExtraRows) or an in-flight reconcile
                // payload. Hand it to the orphan graveyard instead of leaking:
                // the last holder to release reaps it (id=viewer-orphan-graveyard).
                // Detached, unreferenced panes free normally.
                if (pane.isRetained()) {
                    orphanPane(pane, self.alloc);
                    continue;
                }
                pane.deinit(self.alloc);
                self.alloc.destroy(pane);
            }
            self.panes.deinit(self.alloc);
        }
        {
            // Free retired panes whose child has already detached; orphan any
            // still attached / en route / snapshot-referenced (same as above).
            for (self.retired_panes.items) |pane| {
                if (pane.isRetained()) {
                    orphanPane(pane, self.alloc);
                    continue;
                }
                pane.deinit(self.alloc);
                self.alloc.destroy(pane);
            }
            self.retired_panes.deinit(self.alloc);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        {
            var it = self.pane_titles.iterator();
            while (it.next()) |kv| self.alloc.free(kv.value_ptr.*);
            self.pane_titles.deinit(self.alloc);
        }
        self.clearEmittedTitles();
        self.last_emitted_titles.deinit(self.alloc);
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Minimum client size we will ever store or send. A control client's size
    /// is a hard downward clamp on the tmux server (resize.c
    /// clients_calculate_size) in every window-size mode while the client is
    /// attached, so a single transient tiny size (an apprt mid-teardown layout
    /// pass funneled through the sole-pane resize-pane rewrite) shrinks the
    /// window to ~1x1 for EVERY attached client and sticks. No legitimate
    /// viewer surface is ever this small. Mirrors the apprt-side push floor.
    /// ROOTSHELL-TMUX (id=tmux-size-floor)
    pub const min_client_cols: size.CellCountInt = 10;
    pub const min_client_rows: size.CellCountInt = 3;

    /// Update the stored control client dimensions and queue a
    /// `refresh-client -C WxH` command if we're in the `command_queue`
    /// state. The command will be sent to tmux on the next notification
    /// cycle (pull-based). During startup/resync this only stores the
    /// dimensions: startup deliberately remains sizeless until the app's first
    /// layout pass, while a live reset re-sends a stored size that differs from
    /// the last command tmux acknowledged.
    ///
    /// Below-floor dimensions are dropped entirely (not stored either: a
    /// resync re-sends `client_cols/rows`, so a stored transient would
    /// resurface later).
    pub fn setClientSize(
        self: *Viewer,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) void {
        if (cols < min_client_cols or rows < min_client_rows) {
            log.warn("ignoring below-floor client size {}x{}", .{ cols, rows });
            return;
        }

        self.client_cols = cols;
        self.client_rows = rows;

        if (self.state == .command_queue) {
            // Coalesce with a queued-but-unsent client_size instead of piling
            // up one stale size per resize step (keyboard show/hide, window
            // drag). ROOTSHELL-TMUX (id=viewer-coalesce-client-size)
            if (self.coalescePendingClientSize(cols, rows)) return;
            self.queueCommands(&.{.{ .client_size = .{
                .cols = cols,
                .rows = rows,
            } }}) catch {
                log.warn("failed to queue client_size command", .{});
            };
        }
    }

    /// Update the themed colors after a config reload, applying them to BOTH
    /// future pane terminals (via `self.colors`, consumed by `initLayout`) and
    /// every EXISTING pane terminal so the live render reflects the new theme
    /// immediately, and re-report fg/bg to tmux so OSC 10/11 queries answer
    /// with the current theme. Covers the full `Terminal.Colors` set the theme
    /// can change: background, foreground, cursor, and the 256-color palette —
    /// mirroring how `Termio.changeConfig` applies config colors. Only the
    /// `default` slot (and the palette `original`/default entries) is changed,
    /// so a live OSC override still wins: `DynamicPalette.changeDefault`
    /// preserves OSC-4 overrides and `DynamicRGB.default` sits under any OSC
    /// 10/11/12 override. `cursor` is applied as-given (a full snapshot, so a
    /// null clears the themed cursor) because the caller always passes the
    /// complete current config; `fg`/`bg`/`palette` keep their present-guards
    /// only defensively (the caller always supplies them). The fg/bg report is
    /// queued only when we are in the `command_queue` state and have concrete
    /// colors; the terminal-color refresh above takes effect regardless.
    pub fn updateColors(
        self: *Viewer,
        fg: ?color.RGB,
        bg: ?color.RGB,
        cursor: ?color.RGB,
        palette: ?color.Palette,
    ) void {
        if (fg) |c| self.colors.foreground.default = c;
        if (bg) |c| self.colors.background.default = c;
        self.colors.cursor.default = cursor;
        if (palette) |p| self.colors.palette.changeDefault(p);

        // Refresh the colors of panes that already exist so the live render
        // picks up the new theme immediately. New panes already inherit
        // `self.colors` via `initLayout`; existing panes were built once and
        // never refreshed, so without this they stay stale until a
        // detach/reattach rebuilds them. Mirrors how `Termio.changeConfig`
        // updates a normal surface's terminal colors. Runs regardless of viewer
        // state (NOT gated on `.command_queue` like the OSC report below).
        // ROOTSHELL-TMUX (id=viewer-update-existing-pane-colors)
        {
            var pit = self.panes.iterator();
            while (pit.next()) |kv| {
                const pane = kv.value_ptr.*;
                // Hold the child's renderer mutex (if a child is attached)
                // while mutating the terminal the child's renderer thread
                // reads, the same discipline as the `initLayout` resize path.
                // Bounded: a contended pane just keeps its stale theme until
                // the next theme change or lock window — never worth blocking
                // the control channel. ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
                const m = self.lockPaneBounded(
                    pane,
                    kv.key_ptr.*,
                    PANE_LOCK_QUICK_BUDGET_NS,
                ) orelse continue;
                defer pane.unlockRenderer(m);
                if (fg) |c| pane.terminal.colors.foreground.default = c;
                if (bg) |c| pane.terminal.colors.background.default = c;
                pane.terminal.colors.cursor.default = cursor;
                if (palette) |p| pane.terminal.colors.palette.changeDefault(p);
                // Mark colors dirty so the next frame does a full rebuild and
                // default/palette cells re-resolve, matching the `dirty.palette`
                // set in `Termio.changeConfig`.
                pane.terminal.flags.dirty.palette = true;
                // Wake the child's renderer so an idle pane (no pending output)
                // repaints. No-ops when no child is attached.
                wakePane(pane);
            }
        }

        if (self.state != .command_queue) return;
        if (!self.supportsPaneColorReport()) return;
        const rfg = self.colors.foreground.get() orelse return;
        const rbg = self.colors.background.get() orelse return;
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            // Two separate reports per pane: tmux parses one OSC per report.
            self.queueCommands(&.{
                .{ .pane_color_report = .{ .pane_id = kv.key_ptr.*, .code = 10, .color = rfg } },
                .{ .pane_color_report = .{ .pane_id = kv.key_ptr.*, .code = 11, .color = rbg } },
            }) catch {
                log.warn("failed to queue pane_color_report on theme change", .{});
            };
        }
    }

    /// Apply a live `cursor-style`/`cursor-style-blink` config change to the
    /// viewer default and to existing panes (new panes inherit via `initLayout`).
    /// Only panes still showing the default cursor follow the change — a pane
    /// that set its own shape via DECSCUSR keeps it, matching how a normal
    /// surface's `changeConfig` reapplies only when `default_cursor` is set.
    /// ROOTSHELL-TMUX (id=viewer-cursor-style-default)
    pub fn updateCursorDefaults(
        self: *Viewer,
        style: Screen.CursorStyle,
        blink: ?bool,
    ) void {
        self.default_cursor_style = style;
        self.default_cursor_blink = blink;

        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane = kv.value_ptr.*;
            // Bounded renderer-mutex hold, same discipline as updateColors.
            const m = self.lockPaneBounded(
                pane,
                kv.key_ptr.*,
                PANE_LOCK_QUICK_BUDGET_NS,
            ) orelse continue;
            defer pane.unlockRenderer(m);
            pane.terminal.cursor.default_style = style;
            // `orelse true` mirrors how a normal surface resolves DECSCUSR 0.
            pane.terminal.cursor.default_blink = blink orelse true;
            if (pane.terminal.cursor.is_default) {
                pane.terminal.screens.active.cursor.cursor_style = style;
                // Only force blink when explicitly configured; an unset blink
                // leaves the pane's current value (don't flip steady->blinking).
                if (blink) |b| pane.terminal.modes.set(.cursor_blinking, b);
                // Cursor is an overlay redrawn each frame, so a wake is enough —
                // no cell rebuild needed.
                wakePane(pane);
            }
        }
    }

    /// Format the head command for sending IF it is queued-but-unsent, and
    /// mark it in flight. Returns the formatted command (owned by `arena_alloc`,
    /// including its trailing newline) or null when there is nothing to send.
    ///
    /// This exists because the viewer's command pump is pull-based: the next
    /// queued command is only formatted and emitted inside `next()` when an
    /// inbound tmux notification arrives. Commands queued OUT of that flow —
    /// `setClientSize` (a `refresh-client -C` resize), `queueUserCommand` (a
    /// relayed pane `resize-pane`/`select-pane`), `updateColors` — would
    /// otherwise sit unsent until the next notification, which never comes on an
    /// idle session (e.g. a shell prompt with no output). The stream handler
    /// calls this right after such an enqueue to flush the resize immediately.
    ///
    /// The response FIFO stays intact: we only return the head when nothing is
    /// in flight (`command_in_flight == false`), so at most one command is sent
    /// ahead of its %begin/%end and every later command still waits in order
    /// (the `nextCommand` pump sends them as each predecessor completes). During
    /// startup we return null — the stored size is sent by `tryFinishStartup`.
    pub fn takePendingCommand(
        self: *Viewer,
        arena_alloc: Allocator,
    ) Allocator.Error!?[]const u8 {
        if (self.state != .command_queue) return null;
        if (self.command_in_flight) return null;
        const first = self.command_queue.first() orelse return null;

        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        first.formatCommand(&builder.writer) catch return error.OutOfMemory;
        self.command_in_flight = true;
        return builder.writer.buffered();
    }

    /// Roll back the `command_in_flight` flag set by `takePendingCommand` (or by
    /// a viewer-emitted `.command` action) when the stream handler fails to
    /// actually hand the command to the pty (e.g. OOM duping it). Without this
    /// the pump wedges: the flag stays set, no `%begin/%end` response ever
    /// arrives to clear it, and no further queued command is sent. Nothing was
    /// written and no sent-FIFO marker was recorded, so clearing the flag is
    /// consistent. ROOTSHELL-TMUX (id=viewer-rollback-in-flight)
    pub fn rollbackInFlightCommand(self: *Viewer) void {
        self.command_in_flight = false;
    }

    /// Record that a tracked command was written to the tmux pty (called at the
    /// drain/write point after the bytes are written). ROOTSHELL-TMUX
    /// (id=viewer-sent-fifo)
    pub fn recordTrackedSend(self: *Viewer) void {
        self.recordSent(.tracked, 1);
    }

    /// Record that untracked `send-keys` command lines were written to the tmux
    /// pty (called at the drain/write point after the bytes are written). A
    /// batched send-keys write carries several `\n`-terminated command lines in
    /// one message, and tmux acks EACH line with one `%begin/%end` block — so
    /// the caller passes the line count. ROOTSHELL-TMUX (id=viewer-sent-fifo)
    pub fn recordUntrackedSends(self: *Viewer, n: usize) void {
        self.recordSent(.untracked, n);
    }

    fn recordSent(self: *Viewer, kind: SentKind, n: usize) void {
        if (n == 0) return;
        // Always grow + append — never drop/clear a marker. Dropping one would
        // misalign the block matcher and let a later untracked ack fall through to
        // `next`, reintroducing the desync this FIFO exists to prevent. Outstanding
        // (written-but-unacked) commands self-bound to the control-channel pipeline
        // depth (tmux acks each with one block, consumed in order); markers are 1
        // byte each so even a large in-flight paste is cheap. Only genuine
        // allocator exhaustion can drop a marker, and there's nothing better to do
        // then.
        self.sent_fifo.ensureUnusedCapacity(self.alloc, n) catch {
            self.last_error = .sent_fifo_oom; // ROOTSHELL-TMUX (id=control-error-code)
            log.warn("tmux sent-FIFO out of memory; dropping markers (may desync)", .{});
            return;
        };
        const old_len = self.sent_fifo.len();
        for (0..n) |_| self.sent_fifo.appendAssumeCapacity(kind);
        // Diagnostic only (not a cap): surface an unusually deep FIFO once, e.g. a
        // huge paste in flight or tmux acking very slowly. It drains as acks arrive.
        // Crossing check, not equality — a bulk append can jump the threshold.
        const new_len = self.sent_fifo.len();
        if (old_len < SENT_FIFO_WARN and new_len >= SENT_FIFO_WARN) {
            log.warn("tmux sent-FIFO deep ({} outstanding); large paste or slow acks", .{new_len});
        }
    }

    /// Classify (and consume) the FIFO entry for an incoming `%begin/%end` block.
    /// Returns `.untracked` for a `send-keys` ack (caller MUST swallow it without
    /// feeding `next`), `.tracked` for a viewer-issued command (caller feeds
    /// `next` as usual), or `.empty` when we have no record (startup attach block
    /// / post-reset straggler — caller falls through to existing handling).
    /// ROOTSHELL-TMUX (id=viewer-sent-fifo)
    pub fn classifyBlock(self: *Viewer) BlockClass {
        const first = self.sent_fifo.first() orelse return .empty;
        const kind = first.*;
        self.sent_fifo.deleteOldest(1);
        return switch (kind) {
            .tracked => .tracked,
            .untracked => .untracked,
        };
    }

    /// Record that a resync probe was written to the tmux pty. ROOTSHELL-TMUX
    /// (id=viewer-resync-probe-count). See `outstanding_resync_probes`.
    pub fn recordResyncProbeSent(self: *Viewer) void {
        self.outstanding_resync_probes += 1;
    }

    /// Whether the viewer still expects one or more resync probe responses.
    pub fn hasOutstandingResyncProbes(self: *const Viewer) bool {
        return self.outstanding_resync_probes > 0;
    }

    /// Account for one resync probe response (the marker block that completes
    /// resync, or a stray retry consumed in steady state). Saturating.
    pub fn consumeResyncProbe(self: *Viewer) void {
        self.outstanding_resync_probes -|= 1;
    }

    /// Stop expecting resync probe responses. Called when the first NON-probe
    /// block arrives in steady state: any probes that were lost (e.g. sent
    /// before the transport attached) will never be answered, so we must not
    /// keep looking for the sentinel in later blocks.
    pub fn clearOutstandingResyncProbes(self: *Viewer) void {
        self.outstanding_resync_probes = 0;
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    ///
    /// Lifetime: the returned slice and any pointers within the actions
    /// are valid only until the next call to `next()`.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.

        // Retry pane work deferred by bounded-lock timeouts on every inbound
        // event (a cheap field sweep when nothing is deferred). Budget 0 =
        // pure tryLock: a still-stuck pane must not tax every event with a
        // sleep-retry loop. The idle-session case (no further events) is
        // covered by the app's heartbeat nudge via
        // ghostty_surface_tmux_flush_deferred, which uses a real budget.
        // Null action sink: clipboard from any pane flushed here is delivered by
        // the subsequent receivedOutput drain (or the idle ABI flush below).
        // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
        self.flushAllDeferredPanes(null, 0);

        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
        };
    }

    /// Queue a list-windows so tmux re-derives (and the viewer re-emits) the
    /// full window topology. Used to recover a topology snapshot dropped
    /// under app-mailbox backpressure. ROOTSHELL-TMUX
    /// (id=termio-msg-flush-deferred)
    pub fn queueTopologyRefresh(self: *Viewer) !void {
        try self.queueCommands(&.{.list_windows});
    }

    /// Retry deferred pane work (spilled output, deferred resize, dropped-
    /// spill re-fetch) for every pane that has any, with a short bounded
    /// lock. Spilled output is invisible until applied, and applying it
    /// requires a lock window that may never come on its own if the pane
    /// goes quiet — so this runs on every viewer event and on the app's
    /// heartbeat nudge. O(1) when nothing is deferred. ROOTSHELL-TMUX
    /// (id=viewer-pane-bounded-lock)
    pub fn flushAllDeferredPanes(self: *Viewer, actions: ?*std.ArrayList(Action), budget_ns: u64) void {
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane = kv.value_ptr.*;
            // clipboard_writes / replay are included so a pane whose pending_vt
            // was already drained by the null-sink live pre-pass (`next`, which
            // buffers OSC 52 / wrapped-passthrough bytes but cannot emit/replay
            // them) stays eligible for the sink-bearing idle flush. Otherwise
            // those side effects strand whenever the NEXT inbound event is not a
            // %output drain for this pane. ROOTSHELL-TMUX (id=viewer-clipboard)
            const has_deferred = pane.pending_vt.items.len > 0 or
                pane.pending_dropped or pane.pending_resize != null or
                pane.clipboard_writes.items.len > 0 or
                pane.replay.items.len > 0;
            if (!has_deferred) continue;
            const m = self.lockPaneBounded(
                pane,
                kv.key_ptr.*,
                budget_ns,
            ) orelse continue;
            defer pane.unlockRenderer(m);
            self.flushPaneDeferred(pane, kv.key_ptr.*);
            // Replay any passthrough (wrapped Kitty graphics) the just-flushed
            // deferred bytes buffered, so deferred image data is not stranded on
            // an idle session until the next %output. Shares the live path's
            // clean-boundary replay. ROOTSHELL-TMUX (id=streamterm-tmux-passthrough)
            self.replayPanePassthrough(pane, kv.key_ptr.*);
            // Deliver any deferred OSC 52 clipboard writes when the caller gave an
            // action sink (the idle-flush ABI path) — otherwise a clipboard SET in
            // deferred output would strand on an idle pane or be delivered late on
            // a later unrelated %output. The live `next()` path passes null: it
            // drains clipboard via the subsequent receivedOutput. Title still
            // self-heals via the #{pane_title} subscription. ROOTSHELL-TMUX
            // (id=viewer-clipboard)
            if (actions) |a| self.flushPaneClipboard(a, pane);
            wakePane(pane);
        }
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup => self.nextStartup(n),
            .resync => self.nextResync(n),
            .command_queue => self.nextCommand(n),
        };
    }

    /// Put a freshly-initialized viewer into the `.resync` state. Used by the
    /// stream handler's `tmuxResume` path: after the app relaunches and tssh
    /// reattaches the live `tmux -CC` pty, we synthesize control-mode entry on a
    /// brand-new surface (so the VT parser passthrough + viewer are set up
    /// exactly as on a real `ESC P 1000 p`), but there is no fresh startup
    /// handshake. `.resync` drains the reattached stream until the resume probe
    /// marker proves it is clean, then rebuilds the full topology. ROOTSHELL-TMUX
    /// (id=viewer-enter-resync)
    pub fn enterResync(self: *Viewer) void {
        self.enterResyncPrioritized(null);
    }

    /// Cold-resume entry carrying the restored locally selected window. A fresh
    /// viewer has no panes to flag for reset, so syncLayouts must place newly
    /// discovered panes directly into the incremental active-first scheduler.
    /// ROOTSHELL-TMUX (id=viewer-active-first-cold-resume)
    pub fn enterResyncPrioritized(self: *Viewer, preferred_window: ?usize) void {
        assert(self.state == .startup);
        self.reset_preferred_window = preferred_window;
        self.recovery_new_panes_incrementally = preferred_window != null;
        self.state = .resync;
    }

    /// Re-enter `.resync` from a LIVE `.command_queue` viewer whose control
    /// channel desynced — a block-framing mismatch (the observed hang) or
    /// mid-stream data loss (the tsshd buffer overflowing while backgrounded
    /// drops a byte chunk, so command replies are lost and the block stream
    /// shifts). Resets ONLY the command pipeline; it deliberately PRESERVES
    /// `panes`/`windows` (and their child surfaces / per-pane VT decoders) so the
    /// post-marker `list-windows` rebuild reuses INITIALIZED panes with no
    /// recapture and no flicker — `initLayout`/`syncLayouts` reuse a pane by id.
    /// UNINITIALIZED panes are the exception: they were mid-capture (a reset
    /// recapture, a new pane's initial capture, or a retry/pause recapture) and
    /// the pipeline reset just dropped their queued captures, so their recapture
    /// intent must be restored — otherwise the rebuild's syncLayouts skips them
    /// (their `reset_recapture` was already consumed at queue time) and they are
    /// stranded uninitialized forever with live `%output` suppressed. The caller
    /// (stream handler) realigns the parser (`beginTmuxResync`) and sends the
    /// resync probe, exactly like the resume path. No-op unless we are in
    /// `.command_queue` (a fresh startup/resume drives its own resync).
    /// ROOTSHELL-TMUX (id=viewer-force-resync)
    pub fn forceResync(self: *Viewer) void {
        if (self.state != .command_queue) return;
        self.resetCommandPipeline();
        // Restore recapture intent for panes whose captures were just dropped.
        // Initialized panes keep the wedge path's reuse-without-recapture
        // semantics. ROOTSHELL-TMUX (id=viewer-force-resync-reflag)
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane = kv.value_ptr.*;
            if (!pane.initialized) self.flagPaneForReset(pane);
        }
        self.state = .resync;
    }

    /// Shared pipeline reset for `forceResync` (wedge) and `forceReset`
    /// (lossy-discard). Drops the in-flight + queued commands, realigns the block
    /// matcher (`sent_fifo`), clears the resync-probe counter, drops buffered
    /// per-pane query replies / clipboard SETs / passthrough bytes, and recycles
    /// the action arena. Deliberately does NOT touch `panes`/`windows` or flip
    /// `.state` — the callers own those (so the two recovery modes can't diverge
    /// on the pipeline-reset half). ROOTSHELL-TMUX (id=viewer-reset-command-pipeline)
    fn resetCommandPipeline(self: *Viewer) void {
        // Drop the stranded in-flight command and every queued command: the
        // rebuild re-establishes topology + focus, and keeping them would just
        // desync against the post-resync block stream.
        self.command_in_flight = false;
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.clear();
            self.command_owners.clear();
        }
        // Markers are plain enums (no per-entry free). Clearing realigns the
        // block matcher against the fresh probe + rebuild stream.
        self.sent_fifo.clear();
        // The probe the stream handler is about to send re-arms this to 1.
        self.outstanding_resync_probes = 0;
        self.clearRecoveryJobs();

        // Drop buffered per-pane query replies. Panes are preserved across the
        // resync, so replies buffered before the desync would otherwise flush
        // after recovery (`flushPaneResponses`) — stale bytes delivered to a
        // pane app that stopped waiting for them. ROOTSHELL-TMUX
        // (id=viewer-force-resync-drop-responses)
        {
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                const pane = kv.value_ptr.*;
                for (pane.responses.items) |chunk| self.alloc.free(chunk);
                pane.responses.clearRetainingCapacity();
                // Same rationale for buffered OSC 52 clipboard SETs (id=viewer-clipboard).
                for (pane.clipboard_writes.items) |cw| self.alloc.free(cw.data);
                pane.clipboard_writes.clearRetainingCapacity();
                // ...and for un-replayed passthrough inner bytes (id=streamterm-tmux-passthrough).
                pane.replay.clearRetainingCapacity();
                // ...and for stashed VISIBLE captures: `forceResync` reuses panes
                // WITHOUT recapture, so a `pane_visible` reply stashed before the
                // desync would otherwise survive and be replayed by a later
                // unrelated session-wide pane_state. ROOTSHELL-TMUX (id=alt-screen-fix)
                self.freeStashedVisibles(pane);
            }
        }

        // Recycle the action arena so a stale action slice can't alias freed
        // memory after the state flip.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }
    }

    /// Live RESET for a lossy reconnect (`ghostty_surface_tmux_reset`): everything
    /// `forceResync` does PLUS force every pane to be re-captured from tmux, so
    /// each pane grid is rebuilt to a complete consistent state. A tsshd output
    /// discard drops bytes mid-`%output`/control block, so the parser desyncs AND
    /// pane content is gapped; `forceResync` alone realigns the parser but REUSES
    /// pane grids (no recapture) and would leave the gap. By flagging every pane
    /// `reset_recapture`, the post-marker `list-windows -> syncLayouts` rebuild
    /// recaptures each (history+visible+state, self-clearing via `eraseDisplay`)
    /// — identical to a fresh `tmux -CC attach` plus full content — while keeping
    /// the window/tab topology (no flicker). No-op unless in `.command_queue`.
    /// ROOTSHELL-TMUX (id=viewer-force-reset)
    pub fn forceReset(self: *Viewer) void {
        self.forceResetPrioritized(null);
    }

    /// Active-first form of forceReset. The preference is advisory: if the
    /// window disappeared before list-windows lands, tmux's server-active
    /// window (then the lowest window index) is recovered first.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    pub fn forceResetPrioritized(self: *Viewer, preferred_window: ?usize) void {
        if (self.state != .command_queue) return;
        self.resetCommandPipeline();
        self.reset_preferred_window = preferred_window;
        self.recovery_new_panes_incrementally = true;
        self.reuse_resync_metadata = true;
        self.flagAllPanesForReset();
        self.reset_pending = false;
        self.state = .resync;
    }

    /// Record that a full reset is wanted even though we cannot start one right
    /// now (the viewer is mid-resync — e.g. a cheaper wedge `forceResync` is
    /// already in flight). The in-flight resync's marker handler (`nextResync`)
    /// honors this and upgrades that rebuild into a full recapture, so a lossy
    /// discard that lands during the resync probe window is never dropped (the
    /// `forceReset` no-op-while-resyncing case). Cleared by the honor point or by
    /// a real `forceReset`. ROOTSHELL-TMUX (id=viewer-force-reset)
    pub fn requestReset(self: *Viewer) void {
        self.requestResetPrioritized(null);
    }

    /// Record a prioritized reset while another resync is already in flight.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    pub fn requestResetPrioritized(self: *Viewer, preferred_window: ?usize) void {
        self.reset_pending = true;
        self.reset_preferred_window = preferred_window;
        self.recovery_new_panes_incrementally = true;
        // A live viewer already negotiated this metadata. Cold resume has no
        // panes/version to reuse and retains the complete handshake.
        if (self.panes.count() > 0 and self.tmux_version.len > 0) {
            self.reuse_resync_metadata = true;
        }
    }

    /// Flag ONE pane for full recapture AND reset its live VT parser. Called for
    /// every pane by `flagAllPanesForReset` (full reset) and for still-capturing
    /// panes by `forceResync` (whose pipeline reset just dropped their queued
    /// captures). `initialized=false` suppresses live `%output` between the
    /// resync marker and capture completion; the transient capture flags are
    /// normalized (the in-flight capture suffix, if any, was dropped with the
    /// command queue); the pane_state completion arm re-initializes the pane once
    /// its captures land.
    ///
    /// The capture REPLAY uses a throwaway `vtStream`, but live `%output` resumes
    /// through the long-lived `pane.stream`, whose parser a discard can strand
    /// mid-escape/DCS/UTF-8 (the dropped bytes were the rest of the sequence) —
    /// the first post-recovery `%output` would then be misparsed. Reset that
    /// parser + UTF-8 decoder to ground and drop any spilled pre-discard bytes.
    /// ROOTSHELL-TMUX (id=viewer-force-reset)
    fn flagPaneForReset(self: *Viewer, pane: *Pane) void {
        pane.initialized = false;
        pane.reset_recapture = true;
        pane.capture_pending = false;
        pane.state_pending = false;
        pane.recapture_again = false;
        pane.pause_recapture = false;
        pane.recovery_pending = false;
        pane.capture_retries = 0;
        // A dropped `%pause`/`%continue` can't be trusted; the recapture
        // fetches current content. (Moot over tssh — discard mode keeps the
        // link drained so tmux never pause-afters — but safe.)
        pane.paused = false;
        // Fully RE-CREATE the live stream so a discard that truncated an
        // OSC/DCS/APC/UTF-8 sequence can't leak buffered parser/handler state
        // into the first post-recovery `%output`. A field poke (`parser =
        // .init()`) is WRONG: it drops the OSC allocator (vtStream uses
        // `initAlloc` for large OSC), skips `Parser.deinit()` (leaks an active
        // OSC capture buffer), and leaves the handler's persistent
        // apc_handler / dcs_pending_esc / dcs_ground_request / tmux_passthrough
        // state live. `deinit` frees all of that; `vtStream` re-creates with
        // the terminal's allocator; effects are re-installed. pane.terminal
        // (the grid the recapture rebuilds) and the child binding are
        // preserved. Safe here: live `%output` is suppressed (initialized=false)
        // until the recapture completes, so nothing feeds this stream meanwhile.
        pane.stream.deinit();
        pane.stream = pane.terminal.vtStream();
        installPaneStreamEffects(pane, self.default_cursor_style, self.default_cursor_blink);
        // A stranded synchronized-output (DECSET 2026) bit is NOT cleared here:
        // this bookkeeping path holds no pane renderer lock and issues no wake,
        // so a `terminal.modes` write would race the child renderer and repaint
        // nothing anyway. The recapture this reset triggers always ends in a
        // pane_state, and receivedPaneState clears the bit under the pane lock +
        // wakePane. ROOTSHELL-TMUX (id=viewer-sync-output-attach-clear)
        // Drop spilled pre-discard `%output`; the recapture replaces content.
        // Also clear `pending_dropped`: the recapture already re-fetches every
        // screen + state, so leaving it set would make the first recapture
        // handler queue ANOTHER visible/state refresh behind ours (stale work
        // that can race with live output after the pane re-initializes).
        pane.pending_vt.clearRetainingCapacity();
        pane.pending_dropped = false;
        // Drop any stashed VISIBLE captures: the recapture re-stashes fresh
        // before its trailing pane_state re-applies, so an old buffer left here
        // could be replayed stale in the window before the recapture lands.
        // ROOTSHELL-TMUX (id=alt-screen-fix)
        self.freeStashedVisibles(pane);
    }

    /// Flag every pane for full recapture. Shared by `forceReset` (immediate)
    /// and the `reset_pending` honor in `nextResync` (deferred). Also re-arms
    /// the title subscription so tmux re-pushes titles that changed during the
    /// outage (they're cached and only re-sent on change).
    /// ROOTSHELL-TMUX (id=viewer-force-reset)
    fn flagAllPanesForReset(self: *Viewer) void {
        var panes_it = self.panes.iterator();
        while (panes_it.next()) |kv| self.flagPaneForReset(kv.value_ptr.*);
        // Force a title re-push (see id=viewer-force-reset-titles): titles come
        // from the `@*:#{pane_title}` subscription, cached in `pane_titles`
        // because tmux re-sends a subscribed value only when it CHANGES. A title
        // that changed DURING the discard was dropped, so the cache is stale.
        // Clearing this re-issues `.subscribe_titles` in `receivedListWindows`,
        // making tmux re-push every current title. The cache is KEPT so unchanged
        // tabs render immediately (no blank flash) until the re-push lands.
        self.title_subscription_queued = false;
        // The re-push must reach the app even when the value is unchanged.
        self.clearEmittedTitles();
    }

    fn clearRecoveryJobs(self: *Viewer) void {
        self.recovery_jobs.clearRetainingCapacity();
        self.recovery_queued = null;
        self.recovery_priority_window = null;
        self.recovery_started = null;
        self.recovery_first_window_ready = false;
        self.recovery_new_panes_incrementally = false;
        var panes_it = self.panes.iterator();
        while (panes_it.next()) |kv| kv.value_ptr.*.recovery_pending = false;
    }

    /// Whether the viewer is still awaiting its resync probe marker. The app
    /// re-sends the probe on a cadence while this is true (the first probe can
    /// be lost if sent before the transport finished attaching, and an idle tmux
    /// session only ever answers our probe). Also used to drop a stray duplicate
    /// probe response once we have left resync. ROOTSHELL-TMUX (id=viewer-is-resyncing)
    pub fn isResyncing(self: *const Viewer) bool {
        return self.state == .resync;
    }

    /// Whether the viewer is in the steady-state command-queue phase (startup and
    /// resync are complete). The live-recovery path (`forceResync`) only fires
    /// here; a fresh startup/resume drives its own resync. ROOTSHELL-TMUX
    /// (id=viewer-force-resync)
    pub fn isCommandQueue(self: *const Viewer) bool {
        return self.state == .command_queue;
    }

    /// Handle a notification while resyncing a resumed control-mode stream.
    /// Drops all pre-reattach noise (stale command blocks, buffered %output,
    /// topology notifications) until our resume probe's marker is seen, then
    /// rebuilds the topology exactly like `tryFinishStartup` (client size,
    /// version, list-windows). The post-marker list-windows -> syncLayouts path
    /// recaptures every pane and its scrollback, so the resumed session is
    /// rebuilt identically to a fresh `tmux -CC attach`. ROOTSHELL-TMUX
    /// (id=viewer-next-resync)
    fn nextResync(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .resync);

        switch (n) {
            .enter => unreachable,
            .exit, .broken => return self.defunct(),

            // Command-output blocks: the only one we care about is the resume
            // probe's, identified by `resync_marker` in its content. Anything
            // else is a block buffered before the reattach — drop it. We must
            // NOT feed it to `receivedCommandOutput`, which would mis-match it
            // against a rebuild command we have not sent yet (the FIFO
            // slot-shift / blank-pane bug class).
            .block_end, .block_err => |block| {
                // Drop every block until the resume probe's marker proves the
                // stream is clean (stale blocks from before the reattach can't
                // contain it).
                const content = block.content;
                const idx = std.mem.indexOf(u8, content, resync_marker) orelse return &.{};

                // This marker block is one probe's response; account for it so
                // the stream handler drops only the REMAINING in-flight probe
                // responses (retries) in steady state. ROOTSHELL-TMUX
                // (id=viewer-resync-probe-count)
                self.consumeResyncProbe();

                // Recover the attached session id from `<marker> $<id>` so the
                // rebuild's session-scoped pane_state covers EVERY window's
                // panes (not just the active window's). Keep the prior id if the
                // probe output is malformed.
                if (parseResyncSessionId(content[idx + resync_marker.len ..])) |sid| {
                    self.session_id = sid;
                }
                log.info("tmux control mode resync complete (session={}), rebuilding topology", .{self.session_id});

                // A full reset was requested while THIS resync was already in
                // flight (a lossy discard landed during the probe window, so
                // `forceReset` could not start its own resync). Upgrade this
                // rebuild into a full recapture: flag every pane so the post-marker
                // list-windows -> syncLayouts recaptures it (and reset each pane's
                // live parser). Without this, a cheaper wedge `forceResync` in
                // flight would rebuild WITHOUT recapture and the dropped output
                // would stay lost. ROOTSHELL-TMUX (id=viewer-force-reset)
                if (self.reset_pending) {
                    self.flagAllPanesForReset();
                    self.reset_pending = false;
                }

                // Stream is clean from here. A LIVE reset can reuse the already
                // negotiated pause mode, tmux version, and pane color reports.
                // Re-send client size only if a resize arrived after the last
                // acknowledged one (including a queued size the reset dropped or
                // a setClientSize call during this resync). A cold resume retains
                // the complete startup handshake.
                // ROOTSHELL-TMUX (id=viewer-active-first-recovery)
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);
                const reuse_metadata = self.reuse_resync_metadata;
                self.reuse_resync_metadata = false;
                return self.enterCommandQueue(arena.allocator(), if (reuse_metadata)
                    if (self.last_applied_client_size) |last|
                        if (last.cols == self.client_cols and last.rows == self.client_rows)
                            &.{.list_windows}
                        else
                            &.{ .{ .client_size = .{
                                .cols = self.client_cols,
                                .rows = self.client_rows,
                                .enable_pause = true,
                            } }, .list_windows }
                    else
                        &.{ .{ .client_size = .{
                            .cols = self.client_cols,
                            .rows = self.client_rows,
                            .enable_pause = true,
                        } }, .list_windows }
                else
                    &.{ .{ .client_size = .{
                        .cols = self.client_cols,
                        .rows = self.client_rows,
                        .enable_pause = true,
                    } }, .tmux_version, .list_windows }) catch {
                    self.last_error = .resync_rebuild_failed; // ROOTSHELL-TMUX (id=control-error-code)
                    log.warn("resync: failed to queue rebuild, becoming defunct", .{});
                    return self.defunct();
                };
            },

            // Any other notification (live %output, %window-*, %session-changed,
            // etc.) seen before the probe marker is pre-reattach noise. Drop it;
            // the post-marker list-windows rebuild is the source of truth.
            else => return &.{},
        }
    }

    /// Parse the `$<id>` session id tmux appends after the resync marker in the
    /// probe's output (`<marker> $<id>`). Returns null if absent/malformed.
    /// ROOTSHELL-TMUX (id=viewer-resync-session-id)
    fn parseResyncSessionId(rest: []const u8) ?usize {
        const trimmed = std.mem.trim(u8, rest, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '$') return null;
        var end: usize = 1;
        while (end < trimmed.len and trimmed[end] >= '0' and trimmed[end] <= '9') : (end += 1) {}
        if (end == 1) return null;
        return std.fmt.parseInt(usize, trimmed[1..end], 10) catch null;
    }

    fn nextStartup(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            .exit,
            .broken,
            => return self.defunct(),

            // The initial %begin/%end block is the response to the
            // attach command. Any end (even error) counts.
            .block_end, .block_err => {
                self.startup_got_block = true;
                return self.tryFinishStartup();
            },

            // %session-changed gives us the session ID. tmux currently
            // sends this after the block, but we handle either order.
            .session_changed => |info| {
                self.session_id = info.id;
                {
                    var win_arena = self.windows_arena.promote(self.alloc);
                    defer self.windows_arena = win_arena.state;
                    self.session_name = win_arena.allocator().dupe(u8, info.name) catch "";
                }
                self.startup_got_session = true;
                return self.tryFinishStartup();
            },

            // Startup is a special case of looking for very specific
            // things that are unlikely to expand.
            else => return &.{},
        }
    }

    /// Check if both startup prerequisites are met and transition to
    /// command_queue if so.
    fn tryFinishStartup(self: *Viewer) []const Action {
        if (!self.startup_got_block or !self.startup_got_session) return &.{};

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);

        // Enable pause-after flow control but DO NOT send a client size: a
        // sizeless control client is ignored for window sizing, so tmux keeps
        // each window at the size it was left at on the previous detach instead
        // of reflowing every app to our (possibly stale/narrow) gateway grid on
        // attach (the lossy shrink-then-grow this avoids). The app's first
        // layout pass sizes the viewport via a normal `client_size`, one
        // deliberate resize like a regular `tmux attach`. ROOTSHELL-TMUX
        // (id=viewer-startup-pause-only)
        const arena_alloc = arena.allocator();
        const cmd_actions = self.enterCommandQueue(
            arena_alloc,
            &.{ .enable_pause, .tmux_version, .list_windows },
        ) catch {
            log.warn("failed to queue command, becoming defunct", .{});
            return self.defunct();
        };

        // Also deliver the attached session's identity (captured from the
        // startup %session-changed) to the app. On OOM fall back to just
        // the command action — session_info is best-effort cosmetics/
        // persistence, the command MUST go out. ROOTSHELL-TMUX
        // (id=viewer-session-info)
        var list: std.ArrayList(Action) = .empty;
        list.append(arena_alloc, .{ .session_info = .{
            .id = self.session_id,
            .name = self.session_name,
        } }) catch return cmd_actions;
        list.appendSlice(arena_alloc, cmd_actions) catch return cmd_actions;
        return list.items;
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // Track whether the in-flight command slot is available. Starts true
        // if no command is currently awaiting a response. Set to true when a
        // command completes (block_end/block_err) or the queue is reset
        // (session_changed).
        var command_consumed = !self.command_in_flight;

        switch (n) {
            .enter => unreachable,
            .exit,
            .broken,
            => return self.defunct(),

            inline .block_end,
            .block_err,
            => |block, tag| {
                const is_server_originated = block.info.flags & 1 == 0;
                if (is_server_originated) {
                    // tmux uses flags bit 0 to mark client-originated command
                    // replies. Server-originated blocks can appear due to hooks
                    // or async tmux activity; they are not replies to our FIFO
                    // command stream and must not complete command_in_flight or
                    // advance the pump.
                    log.debug("ignoring server-originated tmux block in command queue err={}", .{tag == .block_err});
                    command_consumed = false;
                    return actions.items;
                }

                if (self.command_in_flight) {
                    self.receivedCommandOutput(
                        &actions,
                        block.content,
                        tag == .block_err,
                    ) catch {
                        log.warn("failed to process command output, becoming defunct", .{});
                        return self.defunct();
                    };
                    self.command_in_flight = false;
                } else {
                    self.last_error = .unexpected_block; // ROOTSHELL-TMUX (id=control-error-code)
                    log.info("unexpected client-originated block output (no command in flight) err={}", .{tag == .block_err});
                    var arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = arena.state;
                    actions.append(arena.allocator(), .recover) catch return self.defunct();
                    command_consumed = false;
                    return actions.items;
                }

                // Slot is available because a client-originated block completed
                // the tracked command in flight.
                command_consumed = true;
            },

            .output => |out| self.handlePaneOutput(&actions, out.pane_id, out.data),

            // Extended output: sent instead of %output when pause-after
            // flow control is enabled. Treated identically to %output;
            // the age_ms field is informational for flow control timing.
            .extended_output => |out| self.handlePaneOutput(&actions, out.pane_id, out.data),

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                    info.name,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed because sessionChanged resets
                // our entire viewer.
                command_consumed = true;
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
                info.raw_flags,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => self.refreshWindowList() catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // The active window changed in the session. Refresh the
            // window list so that layout reconciliation can update
            // the active window/pane focus. Only react if this
            // notification is for our current session.
            .session_window_changed => |info| {
                if (info.session_id == self.session_id) {
                    self.refreshWindowList() catch {
                        log.warn("failed to handle session window change, becoming defunct", .{});
                        return self.defunct();
                    };
                }
            },

            // A window was closed in this session.
            .window_close => self.refreshWindowList() catch {
                log.warn("failed to handle window close, becoming defunct", .{});
                return self.defunct();
            },

            // The active pane changed in tmux. Forward to the caller
            // so it can update focus to the correct window and pane.
            .window_pane_changed => |info| {
                // The notification can race ahead of the pane's creation (a
                // split's %window-pane-changed can land before our layout
                // refresh tracked the new pane). Recording an untracked id
                // would project a focus op for a nonexistent pane into every
                // later reconcile; refresh the window list instead, which
                // re-reads layouts AND active panes. Must NOT return early:
                // the command-pump tail below is what emits the queued
                // list-windows when nothing is in flight. ROOTSHELL-TMUX
                // (id=viewer-pane-changed-untracked)
                if (!self.panes.contains(info.pane_id)) {
                    log.info("window-pane-changed for untracked pane={}, refreshing window list", .{info.pane_id});
                    self.refreshWindowList() catch {
                        log.warn("failed to handle window pane change, becoming defunct", .{});
                        return self.defunct();
                    };
                } else {
                    for (self.windows.items) |*window| {
                        if (window.id == info.window_id) {
                            window.active_pane_id = info.pane_id;
                            break;
                        }
                    }

                    var arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = arena.state;
                    actions.append(arena.allocator(), .{
                        .focus = .{
                            .window_id = info.window_id,
                            .pane_id = info.pane_id,
                        },
                    }) catch {
                        log.warn("failed to queue focus action for window={} pane={}", .{
                            info.window_id,
                            info.pane_id,
                        });
                    };
                }
            },

            // A session was created or destroyed somewhere on the server.
            // If it was our own session we will get an exit notification
            // very soon. Either way, forward an action so the app can
            // refresh any visible session list (dashboard).
            // ROOTSHELL-TMUX (id=viewer-sessions-changed)
            .sessions_changed => {
                var act_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = act_arena.state;
                actions.append(act_arena.allocator(), .sessions_changed) catch {
                    log.warn("failed to queue sessions_changed action", .{});
                };
            },

            // Update the window name and notify the caller so it can
            // update the tab title.
            .window_renamed => |info| {
                var win_arena = self.windows_arena.promote(self.alloc);
                defer self.windows_arena = win_arena.state;
                const win_alloc = win_arena.allocator();

                for (self.windows.items) |*window| {
                    if (window.id == info.id) {
                        // Dupe the new name onto the windows arena. The old
                        // name leaks on the arena until the next full reset
                        // (receivedListWindows). This is bounded in practice:
                        // renames are infrequent, and any topology change
                        // (add/close/switch) triggers list_windows which
                        // resets the arena via free_all.
                        window.name = win_alloc.dupe(u8, info.name) catch {
                            log.warn("failed to dupe window name for rename", .{});
                            break;
                        };
                        // Emit through the shared precedence helper: the
                        // active-pane title (#T) keeps priority over the
                        // window name (#W) when one is set.
                        self.emitWindowTitle(&actions, info.id);
                        return actions.items;
                    }
                }
            },

            // A pane's mode changed (e.g., entered/exited copy mode).
            // Query the actual mode since the notification only provides
            // the pane ID, not the mode name.
            .pane_mode_changed => |info| {
                if (self.panes.contains(info.pane_id)) {
                    self.queueCommands(&.{
                        .{ .pane_mode_query = info.pane_id },
                    }) catch {
                        log.warn("failed to queue pane mode query for pane={}", .{info.pane_id});
                    };
                }
            },

            // Update the session name and notify the caller so it can
            // update the Ghostty window title. The old name leaks on
            // windows_arena until the next receivedListWindows reset
            // (see window_renamed for the same bounded-leak rationale).
            //
            // tmux BROADCASTS this to every control client with no session
            // gate (control-notify.c control_notify_session_renamed, unlike
            // control_notify_window_renamed just above it), so a rename of
            // ANY session on the server lands here. Applying a foreign one
            // would relabel this gateway with another session's name and
            // corrupt the attached-session identity the app's tab-menu
            // "Rename Session" then targets. Those only get the list-churn
            // nudge. ROOTSHELL-TMUX (id=viewer-session-renamed-scope)
            .session_renamed => |info| {
                var act_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = act_arena.state;
                const act_alloc = act_arena.allocator();

                if (info.id != self.session_id) {
                    actions.append(act_alloc, .sessions_changed) catch {
                        log.warn("failed to queue sessions_changed action", .{});
                    };
                    return actions.items;
                }

                var win_arena = self.windows_arena.promote(self.alloc);
                defer self.windows_arena = win_arena.state;
                const win_alloc = win_arena.allocator();

                self.session_name = win_alloc.dupe(u8, info.name) catch {
                    log.warn("failed to dupe session name for rename", .{});
                    return actions.items;
                };
                actions.append(act_alloc, .{ .session_title = .{
                    .name = self.session_name,
                } }) catch {
                    log.warn("failed to queue session_title action", .{});
                    return actions.items;
                };
                // Renames also update the app's persisted session identity
                // (reconnect-by-name). ROOTSHELL-TMUX (id=viewer-session-info)
                actions.append(act_alloc, .{ .session_info = .{
                    .id = self.session_id,
                    .name = self.session_name,
                } }) catch {
                    log.warn("failed to queue session_info action", .{});
                };
                // A dashboard open on THIS gateway lists every session on the
                // server, so its row for us is now stale too.
                actions.append(act_alloc, .sessions_changed) catch {
                    log.warn("failed to queue sessions_changed action", .{});
                };
                return actions.items;
            },

            // A subscribed format value changed (`refresh-client -B`). We
            // subscribe to `@*:#{pane_title}`, so each notification carries a
            // window id and that window's active-pane title (#T). Store it and
            // refresh the tab title (pane title preferred, window name as the
            // fallback). Unsolicited like the other %-notifications, so fall
            // through and leave the command-slot bookkeeping untouched.
            .subscription_changed => |info| {
                if (std.mem.eql(u8, info.name, control.title_subscription_name)) {
                    self.setPaneTitle(info.window_id, info.value) catch {
                        log.warn("failed to store pane title for window={}", .{info.window_id});
                    };
                    self.emitWindowTitle(&actions, info.window_id);
                }
            },

            // Pause/continue relate to refresh-client -A pause-after flow
            // control. When a pane falls `pause-after` seconds behind (e.g.
            // the iOS app was backgrounded and stopped draining the link),
            // tmux PAUSES the pane: it DISCARDS that pane's queued output
            // (tmux control.c control_pause_pane -> control_discard_pane,
            // control_check_age) and sends %pause. %continue does NOT replay
            // the discarded gap — control_continue_pane just resets the
            // offset to the pane's CURRENT content — so the only way to
            // recover the lost bytes is to re-capture the pane. We therefore
            // auto-continue AND re-fetch the pane's history+visible state.
            // ROOTSHELL-TMUX (id=pause-after-recover)
            .pause => |info| {
                if (self.panes.getEntry(info.pane_id)) |entry| {
                    const pane = entry.value_ptr.*;
                    pane.paused = true;
                    var act_arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = act_arena.state;
                    actions.append(act_arena.allocator(), .{ .pane_paused = .{
                        .pane_id = info.pane_id,
                        .paused = true,
                    } }) catch {
                        log.warn("failed to queue pane_paused action for pane={}", .{info.pane_id});
                    };
                    // Auto-continue: resume live %output. This resets tmux's
                    // offset to the current pane content, so the bytes
                    // discarded while paused are gone from the stream.
                    const owner: CommandOwner = if (self.recovery_jobs.items.len > 0)
                        .recovery
                    else
                        .ordinary;
                    self.queueCommandsWithOwner(
                        &.{.{ .continue_pane = info.pane_id }},
                        owner,
                    ) catch {
                        log.warn("failed to queue continue_pane for pane={}", .{info.pane_id});
                    };
                    // Re-capture to recover the discarded gap, but ONLY when
                    // the pane is already initialized: a still-capturing pane
                    // is mid-startup-batch, and stacking another batch would
                    // corrupt the command FIFO (we just re-send continue for
                    // it). Park the pane uninitialized + capture_pending so
                    // live %output is suppressed during the history replay
                    // (which blanks the active area; see
                    // id=viewer-pane-bounded-lock) and so the trailing
                    // session-wide pane_state can't re-initialize OTHER panes
                    // that are mid-recapture. The pane_state re-initializes
                    // THIS pane (completion arm in receivedPaneState).
                    if (pane.initialized) {
                        log.info("tmux pane {} paused (pause-after); re-capturing to recover discarded output", .{info.pane_id});
                        pane.initialized = false;
                        pane.capture_pending = true;
                        pane.pause_recapture = true;
                        self.queueCommands(&.{
                            .{ .pane_history = .{ .id = info.pane_id, .screen_key = .primary } },
                            .{ .pane_visible = .{ .id = info.pane_id, .screen_key = .primary } },
                            .{ .pane_history = .{ .id = info.pane_id, .screen_key = .alternate } },
                            .{ .pane_visible = .{ .id = info.pane_id, .screen_key = .alternate } },
                            .{ .pane_state = self.session_id },
                        }) catch {
                            // OOM: re-arm so live output isn't suppressed
                            // forever (degrade to no-recapture, not a wedge).
                            pane.initialized = true;
                            pane.capture_pending = false;
                            pane.pause_recapture = false;
                            log.warn("failed to queue pause recapture for pane={}", .{info.pane_id});
                        };
                    } else if (pane.pause_recapture) {
                        // Already mid pause-recapture and tmux discarded ANOTHER
                        // gap (the link is still congested). The in-flight batch
                        // may have captured BEFORE this newest gap, so schedule a
                        // FRESH recapture to run after the current batch completes
                        // (handled in the pane_state completion arm). We do NOT
                        // stack a second batch now — that would corrupt the
                        // command FIFO. Self-healing: pauses keep scheduling
                        // recaptures until the link quiets. ROOTSHELL-TMUX
                        // (id=pause-after-recover)
                        pane.recapture_again = true;
                        log.info("tmux pane {} re-paused mid-recapture; scheduling another recapture", .{info.pane_id});
                    } else {
                        // Uninitialized because of the STARTUP capture sequence,
                        // not a pause recapture: the in-flight capture-pane will
                        // fetch the current content, so just continue. (A real
                        // %pause here is near-impossible — a freshly attached
                        // pane has ~0s of lag — but handle it safely.)
                        log.info("tmux pane {} paused (pause-after) during startup capture; continue only", .{info.pane_id});
                    }
                }
            },
            .@"continue" => |info| {
                if (self.panes.getEntry(info.pane_id)) |entry| {
                    entry.value_ptr.*.paused = false;
                    var act_arena = self.action_arena.promote(self.alloc);
                    defer self.action_arena = act_arena.state;
                    actions.append(act_arena.allocator(), .{ .pane_paused = .{
                        .pane_id = info.pane_id,
                        .paused = false,
                    } }) catch {
                        log.warn("failed to queue pane_paused action for pane={}", .{info.pane_id});
                    };
                }
            },

            // A message from the tmux server. Forward as an action so
            // the runtime can surface it (status bar, toast, etc.).
            .message => |info| {
                var act_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = act_arena.state;
                const act_alloc = act_arena.allocator();

                const text = act_alloc.dupe(u8, info.text) catch {
                    log.warn("failed to dupe message text", .{});
                    return actions.items;
                };
                actions.append(act_alloc, .{ .message = .{
                    .text = text,
                } }) catch {
                    log.warn("failed to queue message action", .{});
                    return actions.items;
                };
                return actions.items;
            },

            // These are about OTHER clients (for us we'd get `exit` or
            // `session_changed` instead), but they change what a session
            // list displays — `session_attached` counts and which session
            // each client is on — so forward the same refresh nudge as
            // `%sessions-changed`. ROOTSHELL-TMUX (id=viewer-sessions-changed)
            .client_detached,
            .client_session_changed,
            => {
                var act_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = act_arena.state;
                actions.append(act_arena.allocator(), .sessions_changed) catch {
                    log.warn("failed to queue sessions_changed action", .{});
                };
            },
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands. We only emit a
        // command if a prior command was consumed (or never existed).
        if (self.state == .command_queue and command_consumed) {
            self.ensureRecoveryCommandQueued() catch {
                log.warn("failed to queue incremental tmux recovery command", .{});
                return self.defunct();
            };
            if (self.command_queue.first()) |next_command| {
                // We should not have any commands, because our nextCommand
                // always queues them.
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();

                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
                self.command_in_flight = true;
            }
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
        raw_flags: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        // Update the zoom state from the window-flags field of %layout-change so a
        // live `prefix-z` toggle is reflected without waiting for a list-windows
        // refresh. The 'Z' flag means the active pane is shown fullscreen.
        // ROOTSHELL-TMUX (id=tmux-zoom)
        window.zoomed = std.mem.indexOfScalar(u8, raw_flags, 'Z') != null;

        // Validate the layout string before doing any destructive arena
        // work. The arena reset below invalidates all existing layout
        // pointers, so a parse failure after that point would leave
        // dangling references. Validating first keeps state intact on
        // bad input from tmux.
        {
            var check_arena: ArenaAllocator = .init(self.alloc);
            defer check_arena.deinit();
            const checked = Layout.parseWithChecksum(check_arena.allocator(), layout_str) catch {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return;
            };

            // Topology cap: %layout-change grows panes without passing
            // through receivedListWindows' caps, so a hostile server could
            // otherwise inflate every window one layout-change at a time.
            // Reject (keep the old layout) when the session's total pane
            // count would exceed the cap; per-layout width is already
            // bounded by the parser's node cap. ROOTSHELL-TMUX
            // (id=viewer-topology-caps)
            var total_panes: usize = checked.countPanes();
            for (self.windows.items) |w| {
                if (w.id == window_id) continue;
                total_panes += w.layout.countPanes();
            }
            if (total_panes > MAX_TOTAL_PANES) {
                log.warn(
                    "topology cap: rejecting layout change for window id={} ({} total panes > {})",
                    .{ window_id, total_panes, MAX_TOTAL_PANES },
                );
                return;
            }
        }

        // Clone unchanged windows' layouts into a temporary arena BEFORE
        // resetting the shared arena. After arena.reset(.retain_capacity),
        // the backing pages are reused and old layout pointers become
        // invalid — new allocations from the same arena will overwrite
        // the old data. We must preserve the unchanged layouts in
        // separate memory first.
        var tmp_arena: ArenaAllocator = .init(self.alloc);
        defer tmp_arena.deinit();
        const tmp_alloc = tmp_arena.allocator();

        for (self.windows.items) |*w| {
            // Window names live on the SAME shared arena (receivedListWindows
            // and %window-renamed both dupe onto it), so the reset below
            // invalidates them too — including the changed window's, which is
            // why this is unconditional while the layout clone skips it.
            // A dangling name silently becomes whatever the fresh layout
            // allocations overwrite it with, and resolveWindowTitle hands it
            // straight to the tab title for any window whose #{pane_title} is
            // empty: the garbage tab titles seen when a second, smaller client
            // attaches and floods %layout-change with no list-windows between.
            // ROOTSHELL-TMUX (id=layout-change-preserve-window-name)
            w.name = try tmp_alloc.dupe(u8, w.name);

            if (w.id == window_id) continue;
            w.layout = try w.layout.clone(tmp_alloc);
        }

        // Reset the shared windows arena and rebuild all layouts. We must
        // rebuild all windows because their layout data shares the arena.
        // Window count is small so this is cheap.
        var win_arena = self.windows_arena.promote(self.alloc);
        defer self.windows_arena = win_arena.state;

        // Save session_name to the stack before resetting, since it
        // lives on this arena and the reset invalidates the pointer.
        var saved_name_buf: [256]u8 = undefined;
        const saved_name_len = @min(self.session_name.len, saved_name_buf.len);
        @memcpy(saved_name_buf[0..saved_name_len], self.session_name[0..saved_name_len]);

        _ = win_arena.reset(.retain_capacity);
        const win_alloc = win_arena.allocator();

        // Re-dupe session_name from the stack copy onto the fresh arena.
        self.session_name = win_alloc.dupe(u8, saved_name_buf[0..saved_name_len]) catch "";

        // Parse the layout. Validation above confirmed the string is
        // well-formed, so only allocation failure is possible here.
        const new_layout: Layout = try Layout.parseWithChecksum(win_alloc, layout_str);
        window.layout = new_layout;

        // Track the size tmux actually resolved. Without this, width/height are
        // only ever written by receivedListWindows, so after a foreign client
        // clamps the session the ensure_window op keeps reporting the old, larger
        // size. The app reads that as the window having GROWN and re-pushes its
        // own size, tmux clamps it again, and the resulting %layout-change
        // sustains the loop. ROOTSHELL-TMUX (id=layout-change-track-window-size)
        window.width = new_layout.width;
        window.height = new_layout.height;

        // Re-clone unchanged windows' layouts from the temporary arena
        // onto the fresh shared arena. The tmp_arena data is still valid
        // since we haven't freed it yet (deferred above).
        for (self.windows.items) |*w| {
            // Re-dupe from the tmp_arena copy taken above; unconditional for
            // the same reason. ROOTSHELL-TMUX (id=layout-change-preserve-window-name)
            w.name = try win_alloc.dupe(u8, w.name);

            if (w.id == window_id) continue;
            w.layout = try w.layout.clone(win_alloc);
        }

        // Reset our action arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
    }

    /// Refresh the full window list from tmux. Used by window add, close,
    /// and session-window-changed notifications — all of which discard the
    /// individual window ID and do a full list-windows query instead.
    ///
    /// Coalesces duplicate requests: if a `.list_windows` command is already
    /// queued (or in-flight as the first entry), no additional one is appended.
    /// Back-to-back add/close/switch notifications during session restructuring
    /// would otherwise grow the queue with redundant full refreshes.
    fn refreshWindowList(self: *Viewer) !void {
        // Check whether list_windows is already queued.
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |cmd| {
            if (cmd.* == .list_windows) return;
        }
        try self.queueCommands(&.{.list_windows});
    }

    /// Store the active-pane title for a window (from the `#{pane_title}`
    /// subscription). Owns a copy on `self.alloc`, freeing any prior value.
    /// No-op when the value is unchanged.
    fn setPaneTitle(self: *Viewer, window_id: usize, value: []const u8) Allocator.Error!void {
        if (self.pane_titles.get(window_id)) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        const dup = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(dup);
        const gop = try self.pane_titles.getOrPut(self.alloc, window_id);
        if (gop.found_existing) self.alloc.free(gop.value_ptr.*);
        gop.value_ptr.* = dup;
    }

    /// Resolve a window's tab title applying the title precedence: the
    /// active-pane title (`#T`, from the `pane_titles` cache) wins; the tmux
    /// window name (`#W`) is the fallback. Shared by `emitWindowTitle` (the
    /// live `%subscription-changed` / `%window-renamed` path) and the topology
    /// snapshot (`apprt/surface_tmux.zig`) so a full `planTmuxReconcile` rebuild
    /// preserves `#T` for inactive windows that tmux won't re-send (it dedups
    /// subscription values server-side). Returns "" when neither is known.
    /// ROOTSHELL-TMUX (id=viewer-resolve-window-title).
    pub fn resolveWindowTitle(self: *const Viewer, window_id: usize, window_name: []const u8) []const u8 {
        const pane_title: []const u8 = if (self.pane_titles.get(window_id)) |t| t else "";
        return if (pane_title.len > 0) pane_title else window_name;
    }

    /// Append a `.title` action for a window, applying the title precedence via
    /// `resolveWindowTitle`: the active-pane title (`#T`) wins; the tmux window
    /// name (`#W`) is the fallback when the pane has no title set. Mirrors a
    /// regular `tmux attach` with `set-titles-string '#T'`. No-op if neither is
    /// known yet. The title slice (pane title on `self.alloc`, or window name on
    /// the windows arena) stays valid through the synchronous action processing
    /// in the caller.
    fn emitWindowTitle(self: *Viewer, actions: *std.ArrayList(Action), window_id: usize) void {
        const window_name: []const u8 = name: {
            for (self.windows.items) |w| {
                if (w.id == window_id) break :name w.name;
            }
            break :name "";
        };
        const title: []const u8 = self.resolveWindowTitle(window_id, window_name);
        if (title.len == 0) return;

        // Same value the app already has: skip the message and the reconcile.
        if (self.last_emitted_titles.get(window_id)) |last| {
            if (std.mem.eql(u8, last, title)) return;
        }

        var act_arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = act_arena.state;
        actions.append(act_arena.allocator(), .{ .title = .{
            .window_id = window_id,
            .name = title,
        } }) catch {
            log.warn("failed to queue title action for window={}", .{window_id});
            return;
        };
        // Recorded only once queued; a later mailbox drop calls
        // forgetEmittedTitle so the next event re-sends.
        self.rememberEmittedTitle(window_id, title) catch {
            log.warn("failed to record emitted title for window={}", .{window_id});
        };
    }

    /// The app never received the last emitted title for this window (the
    /// surface mailbox dropped it); let the next resolve send it again.
    pub fn forgetEmittedTitle(self: *Viewer, window_id: usize) void {
        if (self.last_emitted_titles.fetchRemove(window_id)) |kv| self.alloc.free(kv.value);
    }

    fn rememberEmittedTitle(self: *Viewer, window_id: usize, title: []const u8) Allocator.Error!void {
        const dup = try self.alloc.dupe(u8, title);
        errdefer self.alloc.free(dup);
        const gop = try self.last_emitted_titles.getOrPut(self.alloc, window_id);
        if (gop.found_existing) self.alloc.free(gop.value_ptr.*);
        gop.value_ptr.* = dup;
    }

    /// Forget every emitted title so the next resolve for each window is sent
    /// again. Keeps the map's capacity.
    fn clearEmittedTitles(self: *Viewer) void {
        var it = self.last_emitted_titles.iterator();
        while (it.next()) |kv| self.alloc.free(kv.value_ptr.*);
        self.last_emitted_titles.clearRetainingCapacity();
    }

    fn windowForActivePane(self: *const Viewer, pane_id: usize) ?usize {
        for (self.windows.items) |window| {
            if (window.active_pane_id == pane_id) return window.id;
        }
        return null;
    }

    fn emitPaneTitle(self: *Viewer, actions: *std.ArrayList(Action), pane_id: usize, title: []const u8) void {
        const window_id = self.windowForActivePane(pane_id) orelse return;
        self.setPaneTitle(window_id, title) catch {
            log.warn("failed to store pane title for window={}", .{window_id});
            return;
        };
        self.emitWindowTitle(actions, window_id);
    }

    /// Handle output (or extended output) for a pane. Suppresses data for
    /// panes that haven't completed their capture-pane initialization
    /// sequence — processing output before capture completes would corrupt
    /// the terminal state being built up by receivedPaneHistory/Visible.
    fn handlePaneOutput(self: *Viewer, actions: *std.ArrayList(Action), pane_id: usize, data: []const u8) void {
        const pane = if (self.panes.getEntry(pane_id)) |entry|
            entry.value_ptr.*
        else
            null;
        if (pane != null and !pane.?.initialized) {
            log.debug("suppressing output for uninitialized pane id={}", .{pane_id});
        } else {
            self.receivedOutput(actions, pane_id, data) catch |err| {
                log.warn("failed to process output for pane id={}: {}", .{ pane_id, err });
            };
        }
    }

    /// Free retired panes whose child surface has detached (its `threadExit`
    /// cleared `renderer_mutex`). Safe to call any time; still-attached panes
    /// stay retired until their child goes away (or the viewer deinits).
    fn reapRetiredPanes(self: *Viewer) void {
        var i: usize = 0;
        while (i < self.retired_panes.items.len) {
            const pane = self.retired_panes.items[i];
            if (!pane.isRetained()) {
                pane.deinit(self.alloc);
                self.alloc.destroy(pane);
                _ = self.retired_panes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn recoveryWindowForPane(windows: []const Window, pane_id: usize) ?usize {
        for (windows) |window| {
            if (layoutContainsPane(window.layout, pane_id)) return window.id;
        }
        return null;
    }

    fn recoveryHasWindow(self: *const Viewer, window_id: usize) bool {
        for (self.recovery_jobs.items) |job| {
            if (job.window_id == window_id) return true;
        }
        return false;
    }

    fn recoveryWindowIndex(self: *const Viewer, window_id: usize) usize {
        for (self.windows.items) |window| {
            if (window.id == window_id) return window.index;
        }
        return std.math.maxInt(usize);
    }

    fn nextRecoveryWindow(self: *const Viewer) ?usize {
        if (self.recovery_priority_window) |preferred| {
            if (self.recoveryHasWindow(preferred)) return preferred;
        }
        var result: ?usize = null;
        var result_index: usize = std.math.maxInt(usize);
        for (self.recovery_jobs.items) |job| {
            const index = self.recoveryWindowIndex(job.window_id);
            if (result == null or index < result_index or
                (index == result_index and job.window_id < result.?))
            {
                result = job.window_id;
                result_index = index;
            }
        }
        return result;
    }

    /// Add exactly one recovery command when no ordinary tracked command is
    /// waiting. The pull pump calls this after every command completion, making
    /// background work interruptible without ever canceling a streaming block.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    fn ensureRecoveryCommandQueued(self: *Viewer) Allocator.Error!void {
        if (self.recovery_queued != null or self.recovery_jobs.items.len == 0) return;
        if (!self.command_queue.empty()) {
            assert(self.command_queue.len() == self.command_owners.len());
            var owners = self.command_owners.iterator(.forward);
            while (owners.next()) |owner| {
                if (owner.* == .ordinary) {
                    // Ordinary tracked work may be inserted between incremental
                    // capture steps (resize, query, pause recapture, topology
                    // refresh, etc.). While it runs the pane remains gated, so
                    // preserving an earlier history/visible step can leave output
                    // that scrolled during the interruption in neither snapshot.
                    // Recovery-owned commands are deliberately ignored: rewinding
                    // for our own color/state/title work makes multi-pane recovery
                    // repeat quadratically.
                    var rewound = false;
                    for (self.recovery_jobs.items) |*job| {
                        if (job.completed > 0) {
                            job.completed = 0;
                            rewound = true;
                        }
                    }
                    if (rewound) {
                        log.info("tmux discard recovery interrupted; rewinding partial captures", .{});
                    }
                    break;
                }
            }
            return;
        }
        const window_id = self.nextRecoveryWindow() orelse return;

        for (self.recovery_jobs.items) |*job| {
            if (job.window_id != window_id or job.completed >= 4) continue;
            if (job.colors_before_capture) {
                job.colors_before_capture = false;
                try self.queuePaneColorReports(job.pane_id, .recovery);
                if (!self.command_queue.empty()) return;
            }
            const command: Command = switch (job.completed) {
                0 => .{ .pane_history = .{ .id = job.pane_id, .screen_key = .primary } },
                1 => .{ .pane_visible = .{ .id = job.pane_id, .screen_key = .primary } },
                2 => .{ .pane_history = .{ .id = job.pane_id, .screen_key = .alternate } },
                3 => .{ .pane_visible = .{ .id = job.pane_id, .screen_key = .alternate } },
                else => unreachable,
            };
            try self.queueRecoveryCommands(&.{command});
            self.recovery_queued = .{
                .window_id = window_id,
                .pane_id = job.pane_id,
                .step = job.completed,
            };
            return;
        }

        // Every pane in this window has all four captures. Apply state only to
        // this window, then release its live output independently of background
        // windows.
        try self.queueRecoveryCommands(&.{.{ .window_pane_state = window_id }});
        self.recovery_queued = .{
            .window_id = window_id,
            .pane_id = null,
            .step = 4,
        };
    }

    fn completeRecoveryCommand(self: *Viewer, command: Command) void {
        const queued = self.recovery_queued orelse {
            // A renderer-lock retry appends its own scoped state command after
            // the scheduler's original one. When that retry succeeds there is
            // no recovery_queued slot left, but it can complete the window
            // directly instead of making the scheduler send a third copy.
            if (command == .window_pane_state) {
                self.completeRecoveryWindow(command.window_pane_state);
            }
            return;
        };
        const matches = recoveryCommandMatches(queued, command);
        if (!matches) return;
        self.recovery_queued = null;

        // The capture result may already have reached the pane parser, but the
        // job was rewound when another window took priority. Do not preserve
        // this stale step: recovery will recapture history through visible as
        // one uninterrupted sequence when it returns to this pane.
        if (queued.preempted) return;

        if (queued.step < 4) {
            for (self.recovery_jobs.items) |*job| {
                // Capture commands target a pane id, so their result remains
                // valid if authoritative topology moved that pane to another
                // window while the command was in flight.
                if (job.pane_id == queued.pane_id.?) {
                    if (job.completed == queued.step) job.completed += 1;
                    return;
                }
            }
            return;
        }

        self.completeRecoveryWindow(queued.window_id);
    }

    fn recoveryCommandMatches(queued: RecoveryQueued, command: Command) bool {
        return switch (command) {
            .pane_history => |cap| match: {
                const expected: ScreenSet.Key = if (queued.step == 0) .primary else .alternate;
                break :match (queued.step == 0 or queued.step == 2) and
                    queued.pane_id == cap.id and cap.screen_key == expected;
            },
            .pane_visible => |cap| match: {
                const expected: ScreenSet.Key = if (queued.step == 1) .primary else .alternate;
                break :match (queued.step == 1 or queued.step == 3) and
                    queued.pane_id == cap.id and cap.screen_key == expected;
            },
            .window_pane_state => |window_id| queued.step == 4 and
                queued.window_id == window_id,
            else => false,
        };
    }

    fn completeRecoveryWindow(self: *Viewer, window_id: usize) void {
        var has_jobs = false;
        for (self.recovery_jobs.items) |job| {
            if (job.window_id != window_id) continue;
            has_jobs = true;
            if (self.panes.get(job.pane_id)) |pane| {
                if (pane.recovery_pending) return;
            }
        }
        if (!has_jobs) return;

        var i: usize = 0;
        while (i < self.recovery_jobs.items.len) {
            if (self.recovery_jobs.items[i].window_id == window_id) {
                _ = self.recovery_jobs.orderedRemove(i);
            } else i += 1;
        }
        if (self.recovery_priority_window == window_id) {
            self.recovery_priority_window = null;
        }

        const elapsed_ms = if (self.recovery_started) |started|
            started.durationTo(.now(self.io, .awake)).toMilliseconds()
        else
            0;
        if (!self.recovery_first_window_ready) {
            self.recovery_first_window_ready = true;
            log.info(
                "tmux discard recovery selected-ready window=@{} elapsed_ms={} pending_windows={}",
                .{ window_id, elapsed_ms, self.recoveryPendingWindowCount() },
            );
            // Titles are no longer on the selected-window critical path. Restore
            // the subscription now, before incremental background recovery.
            if (!self.title_subscription_queued) {
                self.queueRecoveryCommands(&.{.subscribe_titles}) catch {
                    log.warn("failed to restore tmux title subscription after selected-ready", .{});
                    return;
                };
                self.title_subscription_queued = true;
            }
        }
        if (self.recovery_jobs.items.len == 0) {
            log.info("tmux discard recovery all-ready elapsed_ms={}", .{elapsed_ms});
            self.recovery_started = null;
            self.recovery_new_panes_incrementally = false;
        }
    }

    fn recoveryPendingWindowCount(self: *const Viewer) usize {
        var count: usize = 0;
        for (self.recovery_jobs.items, 0..) |job, index| {
            var seen = false;
            for (self.recovery_jobs.items[0..index]) |prior| {
                if (prior.window_id == job.window_id) {
                    seen = true;
                    break;
                }
            }
            if (!seen) count += 1;
        }
        return count;
    }

    fn prioritizeRecoveryWindow(self: *Viewer, window_id: usize) void {
        self.reset_preferred_window = window_id;
        if (self.recoveryHasWindow(window_id)) {
            // A pane is not live until its full capture sequence and scoped
            // pane-state application finish. If we preserve partial progress
            // while another window recovers, output that scrolls between the
            // history and visible snapshots can fall into neither. Rewind all
            // displaced partial jobs, and invalidate a displaced in-flight
            // reply, so they resume from a fresh history snapshot.
            const finishing_window: ?usize = if (self.recovery_queued) |queued|
                if (queued.step == 4) queued.window_id else null
            else
                null;
            for (self.recovery_jobs.items) |*job| {
                if (job.window_id != window_id and
                    job.window_id != finishing_window and
                    job.completed > 0)
                {
                    job.completed = 0;
                }
            }
            if (self.recovery_queued) |*queued| {
                if (queued.window_id != window_id and queued.step < 4) {
                    queued.preempted = true;
                }
            }
            self.recovery_priority_window = window_id;
            log.info("tmux discard recovery reprioritized window=@{}", .{window_id});
        }
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Reap any panes pruned earlier whose child surfaces have since
        // detached, before we churn the pane map again.
        self.reapRetiredPanes();

        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.*.deinit(self.alloc);
                    self.alloc.destroy(kv.value_ptr.*);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.io,
            self.alloc,
            self.colors,
            self.default_cursor_style,
            self.default_cursor_blink,
            &self.panes,
            &panes,
            window.layout,
            // When the window is zoomed, tmux renders the active pane at the
            // full window content size, but window_layout still reports the
            // saved (unzoomed) leaf dims. Override that one pane's grid to the
            // layout root size (= window content size) so output doesn't wrap
            // at the pre-zoom width. The hidden panes keep their saved dims,
            // matching tmux's actual pane sizes. ROOTSHELL-TMUX
            // (id=tmux-zoom-grid-size)
            if (window.zoomed) .{
                .pane_id = window.active_pane_id,
                .width = window.layout.width,
                .height = window.layout.height,
            } else null,
        );

        // Reconcile unfinished recovery against authoritative topology. Closed
        // panes/windows disappear. A pane move invalidates any partial capture:
        // while recovery of its new window is delayed, output can scroll across
        // the old history/visible boundary even though the pane remains gated.
        // Rewind it to history and drain any displaced in-flight capture without
        // applying it. A window-scoped state reply remains valid for the panes
        // that stayed in its window; the moved pane is excluded below because
        // its job now belongs to the new window and is back at step zero.
        var recovery_i: usize = 0;
        while (recovery_i < self.recovery_jobs.items.len) {
            const pane_id = self.recovery_jobs.items[recovery_i].pane_id;
            const window_id = recoveryWindowForPane(windows, pane_id) orelse {
                _ = self.recovery_jobs.orderedRemove(recovery_i);
                continue;
            };
            if (!panes.contains(pane_id)) {
                _ = self.recovery_jobs.orderedRemove(recovery_i);
                continue;
            }
            const job = &self.recovery_jobs.items[recovery_i];
            if (job.window_id != window_id) {
                job.window_id = window_id;
                job.completed = 0;
                if (self.recovery_queued) |*queued| {
                    if (queued.pane_id == pane_id and queued.step < 4) {
                        queued.preempted = true;
                    }
                }
            }
            recovery_i += 1;
        }
        if (self.recovery_priority_window) |preferred| {
            if (!self.recoveryHasWindow(preferred)) self.recovery_priority_window = null;
        }
        if (self.recovery_jobs.items.len == 0) {
            // All unfinished work disappeared with authoritative topology.
            // Drop its timing/priority slot so a later reset starts fresh.
            self.recovery_queued = null;
            self.recovery_priority_window = null;
            self.recovery_started = null;
            self.recovery_first_window_ready = false;
        }

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);
        const recovery_jobs_start = self.recovery_jobs.items.len;
        errdefer self.recovery_jobs.shrinkRetainingCapacity(recovery_jobs_start);

        // Get our list of added panes and setup our command queue
        // to populate them.
        //
        // If queueCommands fails partway through (OOM), some capture-pane
        // commands may already be queued for panes that won't be added
        // (because the panes errdefer above cleans up the new pane map).
        // This is safe: receivedPaneHistory and receivedPaneVisible both
        // check panes.getEntry() and gracefully skip untracked pane IDs.
        // CircBuf has no deleteNewest operation, and snapshotting head/full
        // is unsafe across potential resize+rotate, so we rely on the
        // response handlers' existing resilience rather than rolling back.
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                // A full surface RESET (`forceReset`) flags every existing pane
                // `reset_recapture` so it is re-captured HERE instead of reused —
                // recovering content a lossy discard dropped. The flag lives on the
                // (shared) Pane pointer initLayout carried over by id, so read+clear
                // it via the new map's value_ptr. Read-and-clear for ALL panes so it
                // can never leak into a later wedge `forceResync` (which never sets
                // it → reused, no recapture). ROOTSHELL-TMUX (id=viewer-force-reset)
                const pane_ptr = kv.value_ptr.*;
                const force_recapture = pane_ptr.reset_recapture;
                pane_ptr.reset_recapture = false;
                const existed = self.panes.contains(pane_id);
                if ((force_recapture and existed) or
                    (self.recovery_new_panes_incrementally and !existed))
                {
                    const window_id = recoveryWindowForPane(windows, pane_id) orelse {
                        // The pane is no longer present in authoritative
                        // topology; don't leave its old child suppressed.
                        pane_ptr.initialized = true;
                        pane_ptr.recovery_pending = false;
                        continue;
                    };
                    // A cold viewer has no prior local panes: these are
                    // already-running server panes reconstructed from the
                    // first topology. Their colors are scheduled per priority
                    // window. With any prior pane present, !existed means tmux
                    // really created this process during live recovery, and
                    // its report must be admitted immediately.
                    const cold_reconstruction = !existed and self.panes.count() == 0;
                    self.recovery_jobs.append(self.alloc, .{
                        .window_id = window_id,
                        .pane_id = pane_id,
                        .colors_before_capture = cold_reconstruction,
                    }) catch |err| {
                        // Same OOM degradation as the former eager queue: reuse
                        // the pre-discard grid rather than strand the pane.
                        if (existed) {
                            pane_ptr.initialized = true;
                            pane_ptr.recovery_pending = false;
                            continue;
                        }
                        return err;
                    };
                    // A genuinely new pane's process may issue OSC 10/11 as
                    // soon as tmux starts it. Publish the client colors at
                    // admission, ahead of its first recovery capture, so tmux
                    // can answer that already-pending query. Existing panes
                    // being recaptured retain their prior reports.
                    // ROOTSHELL-TMUX (id=viewer-incremental-pane-colors)
                    if (!existed and !cold_reconstruction) {
                        try self.queuePaneColorReports(pane_id, .recovery);
                    }
                    pane_ptr.recovery_pending = true;
                    continue;
                }
                if (existed) continue;
                added = true;
                self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                }) catch |err| {
                    // OOM: for a reset-forced recapture of an EXISTING pane, degrade
                    // to reuse-without-recapture (re-mark initialized so live
                    // %output isn't suppressed forever) instead of tearing the whole
                    // viewer down. A genuinely new pane has no prior content to fall
                    // back on, so keep the original propagate-to-defunct.
                    if (force_recapture) {
                        pane_ptr.initialized = true;
                        continue;
                    }
                    return err;
                };

                // Hand tmux this pane's fg/bg up front so it can answer the
                // app's OSC 10/11 color queries instead of returning nothing
                // (which hangs apps like opencode that probe the background on
                // startup; see the `pane_color_report` command docs). Only sent
                // when we have concrete colors: the gateway terminal always does
                // (its defaults come from config), while tests/plain init use
                // `.default` (unset) colors and correctly skip the report.
                // Foreground (10) and background (11) go as two separate
                // commands: tmux parses only one OSC sequence per report.
                try self.queuePaneColorReports(pane_id, .ordinary);

                // Other terminal queries an app makes inside the pane (kitty
                // keyboard `\x1b[?u`, DECRQM of modes tmux ignores like 2026,
                // OSC 4 palette, OSC 12 cursor) hang for a `-CC` client because
                // tmux answers none of them. We answer those from the pane
                // terminal itself: tmux relays the app's raw query bytes in
                // `%output`, so the pane stream sees them and its `write_pty`
                // router (installed in `initLayout`) turns the reply into a
                // `send-keys` back to the app (see `flushPaneResponses` /
                // `reportColorQuery`). Queries tmux DOES answer (DA, DSR,
                // OSC 10/11, XTVERSION) are dropped by `tmuxAnswersResponse` so
                // the app never gets a double reply.
                //
                // Still unanswered (deliberate gaps; rare on startup, higher
                // cost, untested against the target app): OSC 52 clipboard reads
                // and XTGETTCAP (`\x1bP+q…`). If a capture shows an app stalling
                // on one of these, add its reply generation in
                // `stream_terminal.zig` the same way as `reportColorQuery`.
            }

            // If we added any panes, then we also want to resync the pane
            // state (terminal modes and cursor positions and so on). The
            // session id targets list-panes at the whole session so EVERY
            // window's panes are covered (ROOTSHELL-TMUX).
            if (added) try self.queueCommands(&.{.{ .pane_state = self.session_id }});
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes. If a pane still has a child
            // surface's renderer attached, we must not free its terminal now
            // (the child's renderer thread reads it). Retire it for deferred
            // free once the child detaches; otherwise free it immediately.
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                const pane = entry_const.value;
                if (pane.isRetained()) {
                    // Child still attached/en route, or an in-flight snapshot or
                    // reconcile payload still holds a raw pointer to it: defer the
                    // free. On allocation failure we leak rather than free under a
                    // live (or imminent) renderer / pointer holder.
                    self.retired_panes.append(self.alloc, pane) catch {};
                } else {
                    pane.deinit(self.alloc);
                    self.alloc.destroy(pane);
                }
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }

        if (self.recovery_jobs.items.len > 0) {
            if (self.recovery_started == null) {
                self.recovery_started = .now(self.io, .awake);
                self.recovery_first_window_ready = false;
            }
            if (self.recovery_priority_window == null) {
                if (self.reset_preferred_window) |preferred| {
                    if (self.recoveryHasWindow(preferred)) {
                        self.recovery_priority_window = preferred;
                    }
                }
            }
            if (self.recovery_priority_window == null) {
                self.recovery_priority_window = self.nextRecoveryWindow();
            }
            log.info(
                "tmux discard recovery queued preferred=@{?} windows={} panes={}",
                .{ self.recovery_priority_window, self.recoveryPendingWindowCount(), self.recovery_jobs.items.len },
            );
            self.ensureRecoveryCommandQueued() catch {
                // Allocation failure: preserve liveness using the old grids.
                for (self.recovery_jobs.items) |job| {
                    if (self.panes.get(job.pane_id)) |pane| {
                        pane.initialized = true;
                        pane.recovery_pending = false;
                    }
                }
                self.clearRecoveryJobs();
            };
        } else {
            self.recovery_new_panes_incrementally = false;
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
        session_name: []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        // Carry forward the current client size.
        var replacement: Viewer = try .init(self.io, self.alloc, self.client_cols, self.client_rows);
        errdefer replacement.deinit();
        // Carry the themed pane colors forward across the session reset.
        replacement.colors = self.colors;
        // This is the same tmux control client, so its acknowledged size remains
        // valid across a session switch just like its stored current dimensions.
        replacement.last_applied_client_size = self.last_applied_client_size;

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Fail every pending app query back to the app BEFORE the old
        // viewer (and its command queue) is deinited below — otherwise the
        // app-side continuations hang until their timeout. Tags are
        // scalars and the body is an empty literal, so nothing here
        // aliases the dying viewer. ROOTSHELL-TMUX (id=viewer-user-query)
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| switch (command.*) {
                .user_query => |q| try actions.append(arena_alloc, .{
                    .command_response = .{
                        .tag = q.tag,
                        .body = "",
                        .is_err = true,
                    },
                }),
                else => {},
            };
        }

        // Setup our command queue and put ourselves in the command queue
        // state.
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and name, jump directly to the list
        self.session_id = session_id;
        {
            var win_arena = self.windows_arena.promote(self.alloc);
            defer self.windows_arena = win_arena.state;
            self.session_name = win_arena.allocator().dupe(u8, session_name) catch "";
        }

        // Tell the app which session we are attached to now (it persists
        // the name for reconnect and marks the dashboard's current row).
        // Appended on the (new) action arena post-swap; the name lives on
        // the new windows arena. ROOTSHELL-TMUX (id=viewer-session-info)
        {
            var act_arena = self.action_arena.promote(self.alloc);
            defer self.action_arena = act_arena.state;
            actions.append(act_arena.allocator(), .{ .session_info = .{
                .id = self.session_id,
                .name = self.session_name,
            } }) catch log.warn("failed to queue session_info action", .{});
        }

        assert(self.state == .command_queue);
    }

    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return;
        };
        assert(self.command_queue.len() == self.command_owners.len());
        const command_owner = self.command_owners.first().?.*;
        self.command_queue.deleteOldest(1);
        self.command_owners.deleteOldest(1);
        defer command.deinit(self.alloc);

        // ROOTSHELL-TMUX (id=viewer-command-error): tmux answered this command with
        // `%error` instead of `%end`. The block body is a human-readable error
        // string, NOT the command's expected output, so feeding it to the
        // per-command parser would corrupt state — an `%error` on `list-windows`
        // parses as ZERO windows and prunes every pane; an `%error` on
        // `capture-pane` injects the error text into the pane's scrollback. The
        // command is already consumed (deleteOldest above), so just skip parsing.
        // tmux's serial command queue means the NEXT command's response is
        // unaffected. (Don't log the body: it can carry sensitive context.)
        if (is_err) {
            self.last_error = .control_error; // ROOTSHELL-TMUX (id=control-error-code)
            log.info("tmux command {s} returned %error", .{@tagName(command)});
            // pane_state is the LAST command of the capture sequence and is what
            // un-gates live output (marks panes initialized). Even when it errors
            // we must still mark panes initialized — otherwise live %output for
            // them stays suppressed (handlePaneOutput) and the projected panes are
            // blank/frozen until recreated. We only skip PARSING the error body as
            // pane state. ROOTSHELL-TMUX (id=viewer-command-error)
            //
            // BUT honor the same mid-batch guards as the success completion
            // arm — even when erroring this pane_state must not strand a
            // pane that still has recovery work pending:
            //  - capture_pending/state_pending: a pane whose OWN capture/state
            //    batch is still queued (e.g. a concurrent pause recapture)
            //    must NOT be force-initialized off a FOREIGN pane's erroring
            //    session-wide pane_state — live %output would interleave
            //    before its history/visible replay and corrupt the screen. Its
            //    own trailing pane_state (success or error, once its captures
            //    cleared capture_pending) initializes it.
            //  - recapture_again: the pane paused AGAIN mid-recapture, so tmux
            //    discarded a fresh gap. Even though this pane_state errored, we
            //    must re-run the recapture (NOT initialize) or that second gap
            //    is lost. Mirrors the success arm: re-queue the history/visible
            //    batch + a shared trailing pane_state.
            // ROOTSHELL-TMUX (id=pause-after-recover)
            const state_tag = std.meta.activeTag(command);
            if (state_tag == .pane_state or state_tag == .window_pane_state) {
                const recovery_window: ?usize = if (state_tag == .window_pane_state)
                    command.window_pane_state
                else
                    null;
                var requeue_state = false;
                var panes_it = self.panes.iterator();
                while (panes_it.next()) |kv| {
                    const pane = kv.value_ptr.*;
                    if (!self.paneIncludedInStateCompletion(
                        kv.key_ptr.*,
                        pane,
                        recovery_window,
                    )) continue;
                    if (pane.capture_pending or pane.state_pending) continue;
                    if (pane.recapture_again) {
                        try self.queueCommandsWithOwner(&.{
                            .{ .pane_history = .{ .id = kv.key_ptr.*, .screen_key = .primary } },
                            .{ .pane_visible = .{ .id = kv.key_ptr.*, .screen_key = .primary } },
                            .{ .pane_history = .{ .id = kv.key_ptr.*, .screen_key = .alternate } },
                            .{ .pane_visible = .{ .id = kv.key_ptr.*, .screen_key = .alternate } },
                        }, command_owner);
                        pane.recapture_again = false;
                        pane.capture_pending = true;
                        requeue_state = true;
                        continue;
                    }
                    // ROOTSHELL-TMUX (id=alt-screen-fix): receivedPaneState was
                    // SKIPPED for this %error (the error body is not pane state), so
                    // this pane's stashed visible captures were never applied. Apply
                    // them best-effort to their own capture screen (no alternate_on
                    // available on error, so no alt-aware crossing — this mirrors the
                    // pre-defer eager behavior) before initializing, else the active
                    // area is blank with live %output resumed on top. Lock like the
                    // success path; on a lock timeout drop the stash (degraded — this
                    // is already the error path).
                    if (pane.captured_visible_primary != null or
                        pane.captured_visible_alternate != null)
                    {
                        var applied = false;
                        if (self.lockPaneBounded(
                            pane,
                            kv.key_ptr.*,
                            PANE_LOCK_CAPTURE_BUDGET_NS,
                        )) |rm| {
                            defer pane.unlockRenderer(rm);
                            const t: *Terminal = &pane.terminal;
                            applyCapturedVisible(t, .primary, pane.captured_visible_primary) catch {};
                            applyCapturedVisible(t, .alternate, pane.captured_visible_alternate) catch {};
                            applied = true;
                        }
                        self.freeStashedVisibles(pane);
                        // Wake the child renderer so the just-applied capture is
                        // drawn — an attached idle child won't redraw on its own.
                        // Mirrors the success path's wakePane. ROOTSHELL-TMUX
                        // (id=alt-screen-fix)
                        if (applied) wakePane(pane);
                    }
                    pane.initialized = true;
                    pane.pause_recapture = false;
                    if (recovery_window != null) pane.recovery_pending = false;
                }
                if (requeue_state) {
                    const state_command: Command = if (recovery_window) |window_id|
                        .{ .window_pane_state = window_id }
                    else
                        .{ .pane_state = self.session_id };
                    try self.queueCommandsWithOwner(&.{state_command}, command_owner);
                }
            }
            // An app-issued query still gets its answer: the %error body is
            // the human-readable failure (e.g. "duplicate session: x") that
            // the app surfaces inline. ROOTSHELL-TMUX (id=viewer-user-query)
            if (std.meta.activeTag(command) == .user_query) {
                var err_arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = err_arena.state;
                const err_alloc = err_arena.allocator();
                try actions.append(err_alloc, .{ .command_response = .{
                    .tag = command.user_query.tag,
                    .body = try err_alloc.dupe(u8, content),
                    .is_err = true,
                } });
            }
            self.completeRecoveryCommand(command);
            return;
        }

        // A newly selected window invalidated this partial capture. Drain the
        // tmux reply without applying it to the pane: the rewound job will
        // replace it with a fresh history-to-visible sequence after priority
        // recovery, and skipping here also prevents renderer-lock retry work
        // from escaping the incremental scheduler.
        if (self.recovery_queued) |queued| {
            if (queued.preempted and recoveryCommandMatches(queued, command)) {
                self.completeRecoveryCommand(command);
                return;
            }
        }

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            .client_size => |cs| self.last_applied_client_size = .{
                .cols = cs.cols,
                .rows = cs.rows,
            },

            .user, .enable_pause, .continue_pane, .pane_color_report, .subscribe_titles => {},

            // Deliver the query's block content back to the app, correlated
            // by tag. ROOTSHELL-TMUX (id=viewer-user-query)
            .user_query => |q| try actions.append(arena_alloc, .{ .command_response = .{
                .tag = q.tag,
                .body = try arena_alloc.dupe(u8, content),
                .is_err = false,
            } }),

            inline .pane_state, .window_pane_state => |_, tag| {
                const recovery_window: ?usize = if (tag == .window_pane_state)
                    command.window_pane_state
                else
                    null;
                try self.receivedPaneState(content, recovery_window);

                // The pane_state command is the last in the capture
                // sequence. Mark all panes as initialized so they
                // can start receiving live output notifications.
                // Panes whose state application timed out on the renderer
                // lock stay uninitialized (their alt-screen swap is gated on
                // !initialized). While uninitialized, their live %output is
                // suppressed and pane_state does not carry content — so
                // re-fetch each affected pane's visible area (covers output
                // dropped in the window) and THEN re-run pane_state, in the
                // startup sequence's order. ROOTSHELL-TMUX
                // (id=viewer-pane-bounded-lock)
                var requeue_state = false;
                var panes_it = self.panes.iterator();
                while (panes_it.next()) |kv| {
                    const pane = kv.value_ptr.*;
                    if (!self.paneIncludedInStateCompletion(
                        kv.key_ptr.*,
                        pane,
                        recovery_window,
                    )) continue;
                    if (pane.state_pending) {
                        requeue_state = true;
                        try self.queueCommandsWithOwner(&.{
                            .{ .pane_visible = .{
                                .id = kv.key_ptr.*,
                                .screen_key = .primary,
                            } },
                            .{ .pane_visible = .{
                                .id = kv.key_ptr.*,
                                .screen_key = .alternate,
                            } },
                        }, command_owner);
                        continue;
                    }
                    if (pane.capture_pending) {
                        // A capture retry suffix (with its own trailing
                        // pane_state) is still queued for this pane; keep it
                        // uninitialized until that lands so live %output
                        // can't interleave before the replay.
                        continue;
                    }
                    if (pane.recapture_again) {
                        // The pane paused AGAIN while this pause-recapture was
                        // in flight, so tmux discarded a fresh gap. Re-run the
                        // recapture instead of initializing: re-queue the
                        // history/visible batch and keep the pane uninitialized
                        // + capture_pending (so live %output and foreign
                        // pane_states can't init it mid-replay). The shared
                        // trailing pane_state queued below (requeue_state)
                        // re-initializes it once these captures land.
                        // ROOTSHELL-TMUX (id=pause-after-recover)
                        try self.queueCommandsWithOwner(&.{
                            .{ .pane_history = .{ .id = kv.key_ptr.*, .screen_key = .primary } },
                            .{ .pane_visible = .{ .id = kv.key_ptr.*, .screen_key = .primary } },
                            .{ .pane_history = .{ .id = kv.key_ptr.*, .screen_key = .alternate } },
                            .{ .pane_visible = .{ .id = kv.key_ptr.*, .screen_key = .alternate } },
                        }, command_owner);
                        pane.recapture_again = false;
                        pane.capture_pending = true;
                        requeue_state = true;
                        continue;
                    }
                    pane.initialized = true;
                    pane.pause_recapture = false;
                    if (recovery_window != null) pane.recovery_pending = false;
                }
                if (requeue_state) {
                    const state_command: Command = if (recovery_window) |window_id|
                        .{ .window_pane_state = window_id }
                    else
                        .{ .pane_state = self.session_id };
                    try self.queueCommandsWithOwner(&.{state_command}, command_owner);
                }
            },

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
                command_owner,
            ),

            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                content,
            ),

            .tmux_version => try self.receivedTmuxVersion(content),

            .pane_mode_query => |pane_id| try self.receivedPaneMode(
                arena_alloc,
                actions,
                pane_id,
                content,
            ),
        }
        self.completeRecoveryCommand(command);
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch {
            log.info("failed to parse tmux version: {s}", .{line});
            return;
        };

        // Dupe into a temp BEFORE freeing the old buffer: if the dupe fails
        // (OOM), `self.tmux_version` must keep pointing at valid memory, not a
        // freed buffer with len > 0 (which deinit and sessionChanged would then
        // double-free / read-after-free). ROOTSHELL-TMUX (id=viewer-version-dupe)
        const dup = try self.alloc.dupe(u8, data.version);
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = dup;
    }

    fn supportsPaneColorReport(self: *const Viewer) bool {
        // `refresh-client -r` landed in tmux 3.5. Older servers reject the
        // command with %error, so skip OSC 10/11 pre-answering there.
        return tmuxVersionAtLeast(self.tmux_version, 3, 5);
    }

    fn queuePaneColorReports(
        self: *Viewer,
        pane_id: usize,
        owner: CommandOwner,
    ) !void {
        if (!self.supportsPaneColorReport()) return;
        if (self.colors.foreground.get()) |fg| {
            try self.queueCommandsWithOwner(&.{.{ .pane_color_report = .{
                .pane_id = pane_id,
                .code = 10,
                .color = fg,
            } }}, owner);
        }
        if (self.colors.background.get()) |bg| {
            try self.queueCommandsWithOwner(&.{.{ .pane_color_report = .{
                .pane_id = pane_id,
                .code = 11,
                .color = bg,
            } }}, owner);
        }
    }

    fn receivedPaneMode(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        pane_id: usize,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");

        // Parse the response — a single pane_mode field.
        const data = output.parseFormatStruct(
            Format.pane_mode.Struct(),
            line,
            Format.pane_mode.delim,
        ) catch {
            log.info("failed to parse pane mode response: {s}", .{line});
            return;
        };

        const entry = self.panes.getEntry(pane_id) orelse {
            log.info("pane mode response for unknown pane={}", .{pane_id});
            return;
        };

        const mode = PaneMode.fromString(data.pane_mode);
        entry.value_ptr.*.mode = mode;

        try actions.append(arena_alloc, .{ .pane_mode_changed = .{
            .pane_id = pane_id,
            .mode = mode,
        } });
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // If there is an error, reset our actions to what it was before. Capture
        // the length NOW — `shrinkRetainingCapacity(actions.items.len)` evaluated
        // at errdefer time would shrink to the current (already-grown) length, a
        // no-op that leaves half-built actions in place. ROOTSHELL-TMUX
        // (id=viewer-listwindows-errdefer)
        const actions_start_len = actions.items.len;
        errdefer actions.shrinkRetainingCapacity(actions_start_len);

        // Reset the shared windows arena so all layout allocations start
        // fresh. This is safe because every Window's layout data lives on
        // this arena and we are about to rebuild all of them.
        //
        // Save session_name to the stack first since it also lives on
        // this arena and the reset frees the underlying pages.
        var saved_name_buf: [256]u8 = undefined;
        const saved_name_len = @min(self.session_name.len, saved_name_buf.len);
        @memcpy(saved_name_buf[0..saved_name_len], self.session_name[0..saved_name_len]);

        var win_arena = self.windows_arena.promote(self.alloc);
        errdefer self.windows_arena = win_arena.state;
        _ = win_arena.reset(.free_all);
        const win_alloc = win_arena.allocator();

        // A rebuild re-projects every window on the app side; let the live
        // title route re-send once per window afterwards.
        self.clearEmittedTitles();

        // Re-dupe session_name from the stack copy onto the fresh arena.
        self.session_name = win_alloc.dupe(u8, saved_name_buf[0..saved_name_len]) catch "";

        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        defer windows.deinit(self.alloc);

        // Track the active window's ID and its active pane for initial focus.
        var active_window_id: ?usize = null;
        var active_pane_id: ?usize = null;

        // Running pane total for the topology caps. ROOTSHELL-TMUX
        // (id=viewer-topology-caps)
        var total_panes: usize = 0;
        var dropped_windows: usize = 0;

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch {
                log.info("failed to parse list-windows line: {s}", .{line});
                continue;
            };

            // Parse the layout onto the shared windows arena
            const layout: Layout = Layout.parseWithChecksum(
                win_alloc,
                data.window_layout,
            ) catch {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                continue;
            };

            // Topology caps: a hostile/buggy server can list thousands of
            // windows or panes, each of which becomes a Terminal grid here
            // and a Metal view in the app. Drop windows beyond the caps
            // (whole-window granularity keeps every materialized window's
            // layout internally consistent) instead of OOMing the client.
            // Dropped windows never reach self.windows, so the reconcile
            // neither ensures nor focuses them. ROOTSHELL-TMUX
            // (id=viewer-topology-caps)
            const layout_panes = layout.countPanes();
            if (windows.items.len >= MAX_WINDOWS or
                total_panes + layout_panes > MAX_TOTAL_PANES)
            {
                dropped_windows += 1;
                continue;
            }
            total_panes += layout_panes;

            // Record the active window and its current pane
            if (data.window_active) {
                active_window_id = data.window_id;
                active_pane_id = data.pane_id;
            }

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout = layout,
                .active_pane_id = data.pane_id,
                .index = data.window_index,
                .zoomed = data.window_zoomed_flag,
                .name = try win_alloc.dupe(u8, data.window_name),
            });
        }

        if (dropped_windows > 0) {
            log.warn(
                "topology cap: dropped {} window(s) (kept {} windows / {} panes, caps {}/{})",
                .{ dropped_windows, windows.items.len, total_panes, MAX_WINDOWS, MAX_TOTAL_PANES },
            );
        }

        // Save arena state before we hand off to syncLayouts/actions
        self.windows_arena = win_arena.state;

        // A legacy reset has no app-selected preference. Use tmux's active
        // window from this authoritative reply, then syncLayouts falls back to
        // the lowest window index if that window disappeared or was capped.
        // ROOTSHELL-TMUX (id=viewer-active-first-recovery)
        var resetting = false;
        var panes_it = self.panes.iterator();
        while (panes_it.next()) |kv| {
            if (kv.value_ptr.*.reset_recapture) {
                resetting = true;
                break;
            }
        }
        if (resetting) {
            const preferred_exists = exists: {
                const preferred = self.reset_preferred_window orelse break :exists false;
                for (windows.items) |window| {
                    if (window.id == preferred) break :exists true;
                }
                break :exists false;
            };
            if (!preferred_exists) self.reset_preferred_window = active_window_id;
        }

        // Sync up our layouts first — this copies windows into
        // self.windows so the action can reference the persistent
        // field. Using the local windows.items would be a
        // use-after-free since defer windows.deinit frees it.
        try self.syncLayouts(windows.items);

        // Subscribe (once) to each window's active-pane title now that the
        // initial capture/pane_state commands are queued. Appended last so it
        // trails — rather than interrupts — the startup command flow. The tmux
        // subscription then drives live tab-title updates via
        // %subscription-changed. See title_subscription_name.
        if (!self.title_subscription_queued and self.recovery_jobs.items.len == 0) {
            try self.queueCommands(&.{.subscribe_titles});
            self.title_subscription_queued = true;
        }

        // Setup our windows action so the caller can process GUI
        // window changes. Uses self.windows.items (persistent) to
        // match the layoutChanged pattern.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // A cold prioritized resume restores the app's locally selected tab,
        // which may differ from tmux's server-active window. Keep that local
        // selection for the initial focus action as well as capture scheduling;
        // otherwise a fresh controller immediately navigates the UI to an
        // unrecovered background tab. If the preference vanished, retain the
        // authoritative server-active fallback.
        // ROOTSHELL-TMUX (id=viewer-cold-resume-focus)
        var focus_window_id = active_window_id;
        var focus_pane_id = active_pane_id;
        if (self.recovery_jobs.items.len > 0) {
            if (self.reset_preferred_window) |preferred| {
                for (self.windows.items) |window| {
                    if (window.id != preferred) continue;
                    focus_window_id = window.id;
                    focus_pane_id = window.active_pane_id;
                    break;
                }
            }
        }
        if (focus_window_id) |win_id| {
            if (focus_pane_id) |pane_id| {
                try actions.append(arena_alloc, .{
                    .focus = .{
                        .window_id = win_id,
                        .pane_id = pane_id,
                    },
                });
            }
        }
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
        recovery_window: ?usize,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch {
                log.info("failed to parse list-panes line: {s}", .{line});
                continue;
            };
            const focus_flag_present = delimitedFieldNonEmpty(
                line,
                Format.list_panes.delim,
                comptime formatFieldIndex(Format.list_panes, .focus_flag),
            );

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr.*;
            if (!self.paneIncludedInStateCompletion(data.pane_id, pane, recovery_window)) {
                continue;
            }

            // Bounded lock: on timeout, flag the pane so the completion arm
            // skips marking it initialized and re-queues a pane_state (the
            // alt-screen swap is gated on !initialized and must not be
            // skipped). ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
            const render_mutex = self.lockPaneBounded(
                pane,
                data.pane_id,
                PANE_LOCK_CAPTURE_BUDGET_NS,
            ) orelse {
                if (pane.capture_retries < PANE_CAPTURE_RETRY_MAX) {
                    pane.capture_retries += 1;
                    pane.state_pending = true;
                } else {
                    // Retries exhausted: clear the flag so the completion arm
                    // marks the pane initialized (degraded — possibly wrong
                    // alt-screen mapping) instead of requeueing pane_state
                    // forever. ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
                    pane.state_pending = false;
                    // We never acquired the lock to apply this pane's stashed
                    // visibles, and the completion arm is about to initialize it.
                    // DROP the stash so a later session-wide pane_state (gated only
                    // on !capture_pending) can't replay this stale capture content
                    // over the now-live pane. ROOTSHELL-TMUX (id=alt-screen-fix)
                    self.freeStashedVisibles(pane);
                    log.warn(
                        "pane {} state application dropped after retries",
                        .{data.pane_id},
                    );
                }
                continue;
            };
            defer pane.unlockRenderer(render_mutex);
            if (!pane.capture_pending) pane.capture_retries = 0;
            pane.state_pending = false;
            self.flushPaneDeferred(pane, data.pane_id);

            const t: *Terminal = &pane.terminal;

            // ROOTSHELL-TMUX (id=alt-screen-fix): apply the deferred VISIBLE
            // captures (stashed by `receivedPaneVisible`) to their FINAL screens
            // now that `alternate_on` is known. tmux's `capture-pane` (no `-a`)
            // returns the ACTIVE grid and `-a` the SAVED grid; when a pane is in
            // its alternate screen the alt-screen app is the no-`-a` visible and
            // the normal screen's last visible row(s) are the `-a` visible — they
            // belong to OPPOSITE terminal screens. The normal-screen SCROLLBACK is
            // the no-`-a` `pane_history`, already replayed into `.primary` (which
            // keeps the real scrollback budget). We DO NOT swap the `Screen`
            // objects (the old approach): that moved the scrollback onto the
            // 0-scrollback alternate screen (history lost when the app exits) AND
            // made that 0-scrollback object the live primary ("rubber band": no
            // new scrollback could ever accumulate). Routing the visibles here
            // instead keeps `.primary` as the real scrollback-bearing screen.
            //
            // This applies to BOTH a fresh capture/recapture (uninitialized pane)
            // AND a live `pending_dropped` visible re-fetch of an already-initialized
            // pane (`flushPaneDeferred` re-fetches visible+state) — in both cases the
            // freshly stashed buffers must reach the screen, so the gate is "captures
            // done", NOT "!initialized". Gate on `!capture_pending` so a pane whose
            // capture suffix is still being retried waits for its FINAL trailing
            // pane_state (when both screens' visibles are stashed together); else a
            // partial re-stash could drop one screen. `applyCapturedVisible` no-ops on
            // a null buffer, so a session-wide pane_state revisiting a pane with
            // nothing freshly stashed does nothing. Free the buffers once applied; a
            // pause/force-reset recapture re-stashes fresh before re-applying.
            if (!pane.capture_pending) {
                if (data.alternate_on) {
                    // normal-screen visible = the `-a` capture -> .primary;
                    // alt-screen app = the no-`-a` capture -> .alternate.
                    try applyCapturedVisible(t, .primary, pane.captured_visible_alternate);
                    try applyCapturedVisible(t, .alternate, pane.captured_visible_primary);
                } else {
                    // No alternate screen: the no-`-a` capture is the normal
                    // screen's visible -> .primary.
                    try applyCapturedVisible(t, .primary, pane.captured_visible_primary);
                }
                self.freeStashedVisibles(pane);
            }

            // Determine which screen to use based on alternate_on
            const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

            // Switch the terminal to the correct active screen. The visible
            // application above and the capture sequence may leave the terminal
            // on either screen, so pin it here.
            _ = try t.switchScreen(screen_key);

            // Classify the cursor shape tmux reports for this pane. tmux encodes
            // a default cursor (app set no DECSCUSR) as empty OR literal
            // "default"; an explicit block/underline/bar means the app chose it.
            // A default follows the configured `cursor-style`/`cursor-style-blink`.
            // Recording this on the handler's `default_cursor` flag keeps a later
            // config reload (`updateCursorDefaults`) from clobbering an app-set
            // cursor — the capture replay never re-emits DECSCUSR, so the flag
            // must be reconstructed here. ROOTSHELL-TMUX (id=viewer-cursor-style-default)
            const shape_is_default = data.cursor_shape.len == 0 or
                std.mem.eql(u8, data.cursor_shape, "default");
            const shape_is_explicit =
                std.mem.eql(u8, data.cursor_shape, "block") or
                std.mem.eql(u8, data.cursor_shape, "underline") or
                std.mem.eql(u8, data.cursor_shape, "bar");
            if (shape_is_default or shape_is_explicit) {
                pane.terminal.cursor.is_default = shape_is_default;
            }

            // Set cursor position on the appropriate screen (tmux uses 0-based)
            if (t.screens.get(screen_key)) |screen| {
                cursor: {
                    const cursor_x = std.math.cast(
                        size.CellCountInt,
                        data.cursor_x,
                    ) orelse break :cursor;
                    const cursor_y = std.math.cast(
                        size.CellCountInt,
                        data.cursor_y,
                    ) orelse break :cursor;
                    if (cursor_x >= screen.pages.cols or
                        cursor_y >= screen.pages.rows) break :cursor;
                    screen.cursorAbsolute(cursor_x, cursor_y);
                }

                // Set cursor shape on this screen; "default" follows the config.
                // ROOTSHELL-TMUX (id=viewer-cursor-style-default)
                if (std.mem.eql(u8, data.cursor_shape, "block")) {
                    screen.cursor.cursor_style = .block;
                } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                    screen.cursor.cursor_style = .underline;
                } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                    screen.cursor.cursor_style = .bar;
                } else if (shape_is_default) {
                    screen.cursor.cursor_style = self.default_cursor_style;
                }
                // unrecognized non-empty shape: leave the live cursor as-is
            }

            // Restore the saved cursor for the INACTIVE screen.
            //
            // tmux's alternate_saved_x/y is the cursor that was saved when the
            // pane entered the alternate screen via mode 1049 — i.e. the primary
            // screen's cursor to restore when the alt-screen app exits. When
            // alternate_on we must seed the primary screen's DECSC saved-cursor
            // SLOT (not just its live cursor): the live `ESC[?1049l` the app emits
            // on exit calls `restoreCursor()`, which reads `saved_cursor` and
            // DEFAULTS TO (0,0) when it is null — so without this the cursor snaps
            // to the top-left after the app quits (the wrong-location report on
            // detach/reattach). ROOTSHELL-TMUX (id=alt-screen-cursor-restore). We
            // also set the live cursor so the position is right if the screen is
            // shown by a non-1049 path. When alternate_on is false this targets the
            // alternate screen (tmux usually sends MAX_INT — no saved position).
            {
                const saved_screen_key: ScreenSet.Key = if (data.alternate_on) .primary else .alternate;
                if (t.screens.get(saved_screen_key)) |saved_screen| cursor: {
                    const alt_x = std.math.cast(
                        size.CellCountInt,
                        data.alternate_saved_x,
                    ) orelse break :cursor;
                    const alt_y = std.math.cast(
                        size.CellCountInt,
                        data.alternate_saved_y,
                    ) orelse break :cursor;

                    // If our coordinates are outside our screen we ignore it.
                    // tmux actually sends MAX_INT for when there isn't a set
                    // cursor position, so this isn't theoretical.
                    if (alt_x >= saved_screen.pages.cols or
                        alt_y >= saved_screen.pages.rows) break :cursor;

                    saved_screen.cursorAbsolute(alt_x, alt_y);
                    // Seed the DECSC saved-cursor slot the app's exit `1049l`
                    // restoreCursor() reads (mirrors Terminal.saveCursor; pen/
                    // charset from the just-replayed screen, pending_wrap cleared
                    // since we positioned absolutely).
                    saved_screen.saved_cursor = .{
                        .x = alt_x,
                        .y = alt_y,
                        .style = saved_screen.cursor.style,
                        .protected = saved_screen.cursor.protected,
                        .pending_wrap = false,
                        .origin = t.modes.get(.origin),
                        .charset = saved_screen.charset,
                    };
                }
            }

            // Set cursor visibility
            t.modes.set(.cursor_visible, data.cursor_flag);

            // Set cursor blinking. A default-shape cursor uses the configured
            // blink only when explicitly set; otherwise (and for an explicit
            // shape) it honors tmux's reported blink — so an unconfigured default
            // doesn't force a steady cursor to blink on attach/recapture.
            // ROOTSHELL-TMUX (id=viewer-cursor-style-default)
            t.modes.set(
                .cursor_blinking,
                if (shape_is_default)
                    (self.default_cursor_blink orelse data.cursor_blinking)
                else
                    data.cursor_blinking,
            );

            // Terminal modes
            t.modes.set(.insert, data.insert_flag);
            t.modes.set(.wraparound, data.wrap_flag);
            t.modes.set(.keypad_keys, data.keypad_flag);
            t.modes.set(.cursor_keys, data.keypad_cursor_flag);
            t.modes.set(.origin, data.origin_flag);

            // Mouse modes. tmux's mouse_any_flag is an aggregate
            // ALL_MOUSE_MODES indicator; the concrete mutually exclusive
            // modes are standard/button/all.
            t.modes.set(.mouse_event_x10, false);
            t.modes.set(.mouse_event_normal, data.mouse_standard_flag);
            t.modes.set(.mouse_event_button, data.mouse_button_flag);
            t.modes.set(.mouse_event_any, data.mouse_all_flag);
            t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
            t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);
            t.flags.mouse_event = if (data.mouse_all_flag)
                .any
            else if (data.mouse_button_flag)
                .button
            else if (data.mouse_standard_flag)
                .normal
            else
                .none;
            t.flags.mouse_format = if (data.mouse_sgr_flag)
                .sgr
            else if (data.mouse_utf8_flag)
                .utf8
            else
                .x10;

            // Focus reporting. tmux < 3.5 lacks `focus_flag`, so the format
            // field expands empty and parses as false. Do not let that clobber
            // the pane's live focus-event mode.
            if (focus_flag_present) {
                t.modes.set(.focus_event, data.focus_flag);
            }

            // Force synchronized output (DECSET 2026) off. A completed
            // capture-pane snapshot is a settled, non-synchronized frame —
            // tmux has no persistent sync flag, it's transient. During attach
            // the balancing `2026l` can be dropped (uninitialized-pane output
            // suppression / spill overflow), latching the bit ON with no live
            // stream to clear it; the renderer then skips every frame and the
            // pane stays blank. Mirrors the resize-path clear in c/terminal.zig.
            // ROOTSHELL-TMUX (id=viewer-sync-output-attach-clear)
            t.modes.set(.synchronized_output, false);

            // Bracketed paste is intentionally NOT synced from tmux. tmux
            // exposes no `bracketed_paste` format variable — `#{bracketed_paste}`
            // returns empty on every tmux through 3.6 — so syncing it would
            // clobber the value the pane's own `%output` stream already tracks
            // (from the app's `\033[?2004h`/`l`) down to a constant `false`,
            // leaving every paste into the pane un-bracketed. The live stream is
            // authoritative; mirror iTerm2, whose `pasteHelperShouldBracket`
            // reads its own per-pane screen mode and never asks tmux.
            // ROOTSHELL-TMUX (id=tmux-pane-bracketed-paste)

            // Scroll region (tmux uses 0-based, inclusive). Clamp to the pane's
            // current rows and require a valid (top < bottom) region, mirroring
            // `Terminal.setTopAndBottomMargin`'s bounds but WITHOUT its
            // cursor-home side effect (the cursor was already restored above). A
            // tmux-reported region taller than the pane terminal's current rows
            // (a real transient during resize/relayout) would otherwise feed OOB
            // row math, and top >= bottom would underflow the region height. On a
            // degenerate report we leave the default full-screen region.
            // ROOTSHELL-TMUX (id=viewer-pane-state-scroll-clamp)
            scroll: {
                if (t.rows == 0) break :scroll;
                const upper = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_upper,
                ) orelse break :scroll;
                const lower = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_lower,
                ) orelse break :scroll;
                const max_row: size.CellCountInt = @intCast(t.rows - 1);
                const scroll_top = @min(upper, max_row);
                const scroll_bottom = @min(lower, max_row);
                if (scroll_top >= scroll_bottom) break :scroll;
                t.scrolling_region.top = scroll_top;
                t.scrolling_region.bottom = scroll_bottom;
            }

            // Tab stops - parse comma-separated list and set
            t.tabstops.reset(0); // Clear all tabstops first
            if (data.pane_tabs.len > 0) {
                var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
                while (tabs_it.next()) |tab_str| {
                    const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                    const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                    if (col_cell >= t.cols) continue;
                    t.tabstops.set(col_cell);
                }
            }

            wakePane(pane);
        }
    }

    fn paneIncludedInStateCompletion(
        self: *const Viewer,
        pane_id: usize,
        pane: *const Pane,
        recovery_window: ?usize,
    ) bool {
        if (recovery_window) |window_id| {
            // A topology change can add a new pane while this window-scoped
            // state command is already in flight. Layout membership alone is
            // therefore insufficient: only a job whose four captures already
            // completed may consume this response. A zero-progress new-pane job
            // stays gated and prevents completeRecoveryWindow from draining the
            // window until its own capture sequence and a later state command.
            if (!pane.recovery_pending) return false;
            var capture_complete = false;
            for (self.recovery_jobs.items) |job| {
                if (job.window_id == window_id and
                    job.pane_id == pane_id and
                    job.completed == 4)
                {
                    capture_complete = true;
                    break;
                }
            }
            if (!capture_complete) return false;
            for (self.windows.items) |window| {
                if (window.id == window_id) {
                    return layoutContainsPane(window.layout, pane_id);
                }
            }
            return false;
        }
        // Session-scoped state belongs to startup/new-pane/pause recovery. It
        // must never release a pane whose discard recapture has not run yet.
        return !pane.recovery_pending;
    }

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
        command_owner: CommandOwner,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // Bounded lock: on timeout, re-queue the capture (tmux re-sends the
        // content) instead of blocking the control channel; bounded retries
        // so a permanently-stuck pane renderer degrades instead of looping.
        // The retry goes to the queue TAIL, behind this pane's possibly
        // already-applied visible/state — and a late history replay BLANKS
        // the active area — so the retry re-queues the full ordered suffix
        // (history -> visible -> state) to restore the capture invariants.
        // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
        const render_mutex = self.lockPaneBounded(
            pane,
            id,
            PANE_LOCK_CAPTURE_BUDGET_NS,
        ) orelse {
            if (pane.capture_retries < PANE_CAPTURE_RETRY_MAX) {
                pane.capture_retries += 1;
                // Keep the pane uninitialized until the RETRY's pane_state:
                // if the original pane_state (already queued) marked it
                // initialized, live %output would interleave before the late
                // history replay and corrupt the screen/scrollback. A
                // SEPARATE flag from state_pending so a successful earlier
                // pane_state can't release the hold while this retry is
                // still queued.
                pane.capture_pending = true;
                try self.queueCommandsWithOwner(&.{
                    .{ .pane_history = .{ .id = id, .screen_key = screen_key } },
                    .{ .pane_visible = .{ .id = id, .screen_key = screen_key } },
                    .{ .pane_state = self.session_id },
                }, command_owner);
            } else {
                pane.capture_pending = false;
                self.freeStashedVisibles(pane);
                log.warn("pane {} history capture dropped after retries", .{id});
            }
            return;
        };
        defer pane.unlockRenderer(render_mutex);
        pane.capture_retries = 0;
        pane.capture_pending = false;
        self.flushPaneDeferred(pane, id);

        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);

        // Make the history apply idempotent: a RETRIED history (after a lock
        // timeout) lands on a screen that may already hold visible content,
        // which the replay below would otherwise push into scrollback as
        // duplicated lines. Clearing is a no-op for the normal flow (fresh
        // terminal). ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
        t.eraseDisplay(.scrollback, false);
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);

        const screen: *Screen = t.screens.active;

        // Get a VT stream from the terminal so we can send data as-is into
        // it. This will populate the active area too so it won't be exactly
        // correct but we'll get the active contents soon.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
        stream.nextSlice("\x1b[0m");

        // Populate the active area to be empty since this is only history.
        // We'll fill it with blanks and move the cursor to the top-left.
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }

        // History replay deliberately leaves the active area blank until the
        // matching visible captures and trailing pane_state are available.
        // Waking here exposes that internal frame (and the alternate-history
        // frame after it) to fast UI consumers such as tab expose, making a new
        // attach appear to render its scrollback two or three times. The final
        // pane_state application wakes once with the complete coherent frame.
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // ROOTSHELL-TMUX (id=alt-screen-fix): STASH the visible capture; do not
        // replay it into the terminal here. Which terminal screen a visible
        // capture belongs to depends on the pane's `alternate_on` state, which
        // isn't known until the trailing session-wide `pane_state` reply — so
        // `receivedPaneState` applies these to the correct FINAL screens (no
        // more whole-`Screen` swap, which used to strand the normal-screen
        // scrollback on the 0-scrollback alternate screen). Because we don't
        // touch the terminal here, no renderer lock / bounded-lock retry is
        // needed (the stash can't fail on a lock). Dup so the bytes survive past
        // this control block; freed in `receivedPaneState` or `Pane.deinit`. A
        // re-queued capture (history/state lock-timeout retry) simply overwrites
        // the prior stash.
        const buf = try self.alloc.dupe(u8, content);
        switch (screen_key) {
            .primary => {
                if (pane.captured_visible_primary) |old| self.alloc.free(old);
                pane.captured_visible_primary = buf;
            },
            .alternate => {
                if (pane.captured_visible_alternate) |old| self.alloc.free(old);
                pane.captured_visible_alternate = buf;
            },
        }
    }

    /// ROOTSHELL-TMUX (id=alt-screen-fix): replay a stashed VISIBLE `capture-pane`
    /// reply into the given terminal screen's active area. No-op when `content` is
    /// null (the capture was absent — e.g. the `-a` visible of a pane with no
    /// alternate screen, or a capture dropped after retries). Mirrors the
    /// erase-active + `vtStream` replay the inline `receivedPaneVisible` used
    /// before the visible application was deferred to `receivedPaneState` (so the
    /// correct final screen could be chosen from `alternate_on`).
    fn applyCapturedVisible(
        t: *Terminal,
        key: ScreenSet.Key,
        content: ?[]const u8,
    ) !void {
        const bytes = content orelse return;
        _ = try t.switchScreen(key);
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[0m");
        stream.nextSlice(bytes);
        stream.nextSlice("\x1b[0m");
    }

    /// ROOTSHELL-TMUX (id=alt-screen-fix): free + null a pane's stashed VISIBLE
    /// captures after they've been applied (success path in `receivedPaneState`,
    /// degraded path in the `%error` arm). Safe on already-null buffers.
    fn freeStashedVisibles(self: *Viewer, pane: *Pane) void {
        if (pane.captured_visible_primary) |b| {
            self.alloc.free(b);
            pane.captured_visible_primary = null;
        }
        if (pane.captured_visible_alternate) |b| {
            self.alloc.free(b);
            pane.captured_visible_alternate = null;
        }
    }

    /// Returns true if `c` is an octal digit (0-7).
    fn isOctalDigit(c: u8) bool {
        return c >= '0' and c <= '7';
    }

    /// Wake the child surface's renderer (if one is attached) so it redraws
    /// the pane after the viewer has written to its terminal. No-op when no
    /// child is attached (`wake_fn == null`). See `Pane.wake_fn`.
    fn wakePane(pane: *const Pane) void {
        pane.wake();
    }

    /// Bounded pane renderer-lock with debug-progress stamping. Returns the
    /// (possibly null) locked mutex to pass to `unlockRenderer`, or null on
    /// timeout (the registration is already dropped; the caller must defer
    /// its work via the pane's pending state instead of blocking).
    /// ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
    fn lockPaneBounded(
        self: *Viewer,
        pane: *Pane,
        pane_id: usize,
        budget_ns: u64,
    ) ??*std.Io.Mutex {
        if (self.debug_progress) |dp| {
            dp.site.store(DebugProgress.site_pane_lock, .monotonic);
            dp.pane.store(
                @intCast(@min(pane_id, std.math.maxInt(u32))),
                .monotonic,
            );
        }
        defer if (self.debug_progress) |dp| {
            dp.site.store(DebugProgress.site_parsing, .monotonic);
            dp.pane.store(0, .monotonic);
        };
        switch (pane.lockRendererBounded(budget_ns)) {
            .acquired => |m| return m,
            .timeout => {
                if (self.debug_progress) |dp|
                    _ = dp.pane_lock_timeouts.fetchAdd(1, .monotonic);
                log.warn(
                    "pane {} renderer lock contended past {}ms; deferring write",
                    .{ pane_id, budget_ns / std.time.ns_per_ms },
                );
                return null;
            },
        }
    }

    /// Apply work deferred by earlier renderer-lock timeouts. Called at the
    /// START of every successful pane lock window so deferred state lands
    /// before any newer data: pending resize first (the spilled bytes were
    /// produced for the new grid), then either the re-fetch for a dropped
    /// spill or the spilled bytes themselves. ROOTSHELL-TMUX
    /// (id=viewer-pane-bounded-lock)
    fn flushPaneDeferred(self: *Viewer, pane: *Pane, pane_id: usize) void {
        if (pane.pending_resize) |pr| {
            pane.pending_resize = null;
            // cell_size_px keeps pixel geometry consistent with the new cell
            // grid so auto-sized images don't collapse, and upstream rolls it
            // back with the rest of the resize on failure. ROOTSHELL-TMUX
            // (id=tmux-pane-pixel-geometry)
            pane.terminal.resize(self.alloc, .{
                .cols = pr.cols,
                .rows = pr.rows,
                .cell_size_px = pane.cellSizePx(),
            }) catch |err| {
                log.warn("deferred pane {} resize failed err={}", .{ pane_id, err });
            };
        }

        if (pane.pending_dropped) {
            pane.pending_dropped = false;
            pane.pending_vt.clearRetainingCapacity();
            // Content was lost; tmux is the source of truth — re-fetch the
            // visible area for both screens rather than replaying a hole,
            // then pane_state to restore the active screen/cursor/modes
            // (receivedPaneVisible leaves the terminal on the last refreshed
            // screen with the cursor at the content end). Pane titles
            // self-heal via the title subscription.
            self.queueCommands(&.{
                .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                .{ .pane_state = self.session_id },
            }) catch |err| {
                log.warn("failed to queue dropped-spill refresh for pane {} err={}", .{ pane_id, err });
            };
            return;
        }

        if (pane.pending_vt.items.len > 0) {
            pane.stream.nextSlice(pane.pending_vt.items);
            pane.pending_vt.clearRetainingCapacity();
            // Mirror the live-output path's side effect: the replayed bytes
            // can contain terminal queries whose replies the pane terminal
            // buffered via write_pty — route them back now, not at some
            // unrelated future output. (Queued as a send-keys command; the
            // pull-based queue sends it on the next block reply, or the
            // heartbeat's pump on an idle session.) Title changes are NOT
            // re-detected here: the #{pane_title} subscription is the
            // authoritative title source and self-heals on its own cadence.
            // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
            self.flushPaneResponses(pane_id, pane) catch |err| {
                log.warn(
                    "failed to flush pane {} deferred query replies err={}",
                    .{ pane_id, err },
                );
            };
        }
    }

    /// Replay inner sequences recovered from `ESC P tmux; ...` passthrough
    /// envelopes (e.g. yazi's wrapped Kitty graphics) back through the pane
    /// stream. The pane handler can only buffer (no Stream ref), so the recovered
    /// bytes are re-fed HERE, outside the original nextSlice (not re-entrant).
    /// CRITICAL: only replay at a fully clean boundary — VT parser at ground AND
    /// the UTF-8 decoder idle (`utf8decoder.state == 0`) — else injecting the
    /// recovered bytes mid-sequence corrupts the stream (a mid-envelope or
    /// mid-multibyte `%output` split; the "random diamonds"). When not clean we
    /// defer: bytes stay buffered and drain on a later clean boundary. Bounded so
    /// a pathological nested envelope can't loop forever. Shared by the live
    /// `receivedOutput` path and the idle `flushAllDeferredPanes` path so deferred
    /// image data is not stranded on an idle session. ROOTSHELL-TMUX
    /// (id=streamterm-tmux-passthrough)
    fn replayPanePassthrough(self: *Viewer, pane: *Pane, id: usize) void {
        const max_rounds = 8;
        var rounds: usize = 0;
        while (pane.replay.items.len > 0 and
            pane.stream.parser.state == .ground and
            pane.stream.utf8decoder.state == 0) : (rounds += 1)
        {
            if (rounds >= max_rounds) {
                const left = pane.replay.items.len;
                log.warn("pane {} passthrough replay exceeded {} rounds; dropping {} bytes", .{ id, max_rounds, left });
                pane.replay.clearRetainingCapacity();
                break;
            }
            // Any replies this wrapped query generates (e.g. yazi's primary-DA
            // sentinel) must bypass the tmuxAnswersResponse drop: tmux never saw
            // the wrapped query, so we are the only responder. Capture the
            // responses base, replay, then route the new replies unfiltered so
            // flushPaneResponses (filtered) only handles raw-feed replies.
            const resp_base = pane.responses.items.len;
            const chunk = pane.replay.toOwnedSlice(self.alloc) catch break;
            defer self.alloc.free(chunk);
            pane.stream.nextSlice(chunk);
            self.routePaneResponsesUnfiltered(id, pane, resp_base) catch |err| {
                log.warn("failed to route pane {} passthrough replies err={}", .{ id, err });
            };
        }
    }

    fn titleFingerprint(title: ?[:0]const u8) u64 {
        const slice: []const u8 = title orelse "";
        var hasher = std.hash.Wyhash.init(slice.len);
        hasher.update(slice);
        return hasher.final();
    }

    fn receivedOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // tmux escapes control bytes (< 0x20) and the backslash itself as
        // `\ooo` (a backslash followed by exactly three octal digits) in
        // %output and %extended-output. We must unescape before feeding the
        // VT stream, otherwise sequences such as ESC (`\033`) render as literal
        // text. A `\ooo` escape never spans a single notification, so no
        // cross-call state is needed, and the decoded length never exceeds the
        // input length.
        //
        // Because tmux escapes EVERY real control byte, any RAW control byte
        // (< 0x20) still present in the payload is line-driver framing noise the
        // SSH/PTY discipline sprinkled in (a stray CR), never pane data. We drop
        // it, and when reading the three octal digits of a `\ooo` escape we skip
        // any such noise injected between them. The line-level trailing-CR strip
        // only caught the END of the line; a CR landing mid-payload would
        // otherwise reach the pane VT stream and snap the cursor to column 0 (the
        // helix scroll / gutter corruption).
        // ROOTSHELL-TMUX (id=control-strip-trailing-cr)
        //
        // NOTE: the upstream octal-decode PRs (#11217, #12076) were not merged
        // (code-quality review), so this is a fork-local fix on the one path
        // that actually writes pane output to a terminal.
        const buf = try self.alloc.alloc(u8, data.len);
        defer self.alloc.free(buf);
        var n: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            const c = data[i];
            if (c == '\\') {
                // Read exactly three octal digits, skipping any raw control byte
                // (a CR the line driver inserted) between them.
                var value: u16 = 0;
                var digits: usize = 0;
                var j = i + 1;
                while (digits < 3 and j < data.len) : (j += 1) {
                    const d = data[j];
                    if (d < ' ') continue; // line-driver noise mid-escape
                    if (!isOctalDigit(d)) break;
                    value = (value << 3) | @as(u16, d - '0');
                    digits += 1;
                }
                if (digits == 3) {
                    // tmux only ever escapes single bytes (<= 0o377).
                    buf[n] = @truncate(value);
                    n += 1;
                    i = j;
                } else {
                    // Not a valid escape (split/garbled): keep the literal
                    // backslash; the next iteration handles whatever follows.
                    buf[n] = '\\';
                    n += 1;
                    i += 1;
                }
            } else if (c < ' ') {
                // Raw control byte = line-driver framing noise. Drop it.
                i += 1;
            } else {
                buf[n] = c;
                n += 1;
                i += 1;
            }
        }

        // Bounded renderer lock: the control channel must never block
        // indefinitely on a pane renderer. On timeout, spill the unescaped
        // bytes to the pane's pending buffer (flushed in order at the next
        // successful lock window); on overflow, drop the spill and re-fetch
        // from tmux. ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
        const render_mutex = self.lockPaneBounded(
            pane,
            id,
            PANE_LOCK_OUTPUT_BUDGET_NS,
        ) orelse {
            if (!pane.pending_dropped) {
                if (pane.pending_vt.items.len + n > PANE_PENDING_VT_MAX) {
                    pane.pending_dropped = true;
                    pane.pending_vt.clearRetainingCapacity();
                    log.warn(
                        "pane {} spill overflowed; will re-fetch visible content",
                        .{id},
                    );
                } else {
                    pane.pending_vt.appendSlice(self.alloc, buf[0..n]) catch {
                        pane.pending_dropped = true;
                        pane.pending_vt.clearRetainingCapacity();
                    };
                }
            }
            return;
        };
        defer pane.unlockRenderer(render_mutex);

        // Apply work deferred by earlier lock timeouts BEFORE the new data.
        self.flushPaneDeferred(pane, id);

        const title_before = titleFingerprint(pane.terminal.getTitle());
        pane.stream.nextSlice(buf[0..n]);
        if (titleFingerprint(pane.terminal.getTitle()) != title_before) {
            const title: []const u8 = pane.terminal.getTitle() orelse "";
            self.emitPaneTitle(actions, id, title);
        }

        // ROOTSHELL-TMUX (id=streamterm-tmux-passthrough): replay inner sequences
        // recovered from `ESC P tmux; ...` passthrough envelopes (e.g. yazi's
        // wrapped Kitty graphics). The pane handler can only buffer (no Stream
        // ref), so we re-feed the recovered bytes through the pane stream HERE,
        // outside the original nextSlice, so it is not re-entrant.
        //
        // CRITICAL: only replay when the stream is at a fully clean boundary —
        // the VT parser is at ground AND the UTF-8 decoder has no half-decoded
        // multibyte character pending (`utf8decoder.state == 0`). The recovered
        // bytes are fed back through the SAME stream; injecting them mid-sequence
        // corrupts it. Two distinct mid-sequence cases, both common because tmux
        // does NOT align `%output` chunk boundaries to anything:
        //   1. Mid-envelope: a large image's `%output` ends inside an open
        //      `ESC Ptmux;` passthrough (parser parked in dcs_passthrough). The
        //      old `mux;`/garbage leak + never-loaded image.
        //   2. Mid-multibyte: a `%output` ends inside a UTF-8 character — and
        //      `parser.state` is STILL `.ground` then (the scalar UTF-8 decoder
        //      buffers the partial char separately). Feeding the recovered APC's
        //      ESC into the pending decode corrupts that cell (yazi's Kitty
        //      Unicode placeholder cells are multibyte: U+10EEEE + diacritics) →
        //      the "random diamonds" that got worse under fragmentation/SSH.
        // When not clean we defer: the recovered bytes stay buffered and drain on
        // a later `%output` once the stream returns to a clean boundary. A small
        // single-`%output` query always ends clean, which is why it always worked.
        //
        // Bounded so a pathological nested envelope can't loop forever; snapshot+
        // clear each round so re-entrant appends land in a fresh buffer next round.
        // Done BEFORE flushPaneResponses so replies the inner sequence generates
        // (a wrapped DECRQM, a Kitty graphics response) are routed too. Shared
        // with the idle-flush path so deferred image data still replays.
        self.replayPanePassthrough(pane, id);

        // Route any query replies the pane terminal generated (kitty-keyboard,
        // DECRQM, OSC 4/12, ...) back to the app via send-keys. tmux relays the
        // app's raw queries in %output, so the pane terminal sees and answers
        // them here for the subset tmux itself leaves unanswered.
        self.flushPaneResponses(id, pane) catch |err| {
            log.warn("failed to flush pane {} query replies err={}", .{ id, err });
        };

        // Route any OSC 52 clipboard SETs the pane app emitted to the system
        // clipboard via a `pane_clipboard_write` action (tmux never sets the
        // clipboard for a -CC client). ROOTSHELL-TMUX (id=viewer-clipboard)
        self.flushPaneClipboard(actions, pane);

        wakePane(pane);
    }

    /// `write_pty` effect installed on each pane's live stream: buffer one
    /// query reply per call for later routing (see `flushPaneResponses`).
    /// Recovers the owning `Pane` from the handler's terminal pointer, which
    /// always points at `pane.terminal` (set by `vtStream`).
    fn paneWritePty(handler: *TerminalStreamHandler, data: [:0]const u8) void {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        const alloc = handler.terminal.gpa();
        const copy = alloc.dupe(u8, data) catch return;
        pane.responses.append(alloc, copy) catch alloc.free(copy);
    }

    /// `clipboard_write` effect installed on each pane's live stream: buffer one
    /// OSC 52 SET per call for emission as a `pane_clipboard_write` action after
    /// the `%output` feed (see `flushPaneClipboard`). Recovers the owning `Pane`
    /// from the handler's terminal pointer (always `pane.terminal`, set by
    /// `vtStream`).
    ///
    /// Upstream's protocol-neutral effect hands us DECODED contents, but the
    /// rest of this path feeds `apprt.surface.Message.clipboard_write`, whose
    /// payload `Surface.clipboardWrite` base64-decodes — the same contract the
    /// non-tmux OSC 52 path uses. So re-encode here and keep the pane action
    /// byte-identical to the normal path. ROOTSHELL-TMUX (id=viewer-clipboard)
    fn paneClipboardWrite(
        handler: *TerminalStreamHandler,
        write: clipboard.Write,
    ) clipboard.WriteResult {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        const alloc = handler.terminal.gpa();

        const kind: u8 = switch (write.location) {
            .selection => 's',
            .primary => 'p',
            else => 'c',
        };

        // An empty contents slice clears the destination; OSC 52 spells that
        // as an empty payload, which needs no encoding.
        if (write.contents.len == 0) {
            const empty = alloc.alloc(u8, 0) catch return .io_error;
            pane.clipboard_writes.append(alloc, .{
                .kind = kind,
                .data = empty,
            }) catch {
                alloc.free(empty);
                return .io_error;
            };
            return .success;
        }

        const enc = std.base64.standard.Encoder;
        const data = write.contents[0].data;
        const copy = alloc.alloc(u8, enc.calcSize(data.len)) catch return .io_error;
        _ = enc.encode(copy, data);
        pane.clipboard_writes.append(alloc, .{
            .kind = kind,
            .data = copy,
        }) catch {
            alloc.free(copy);
            return .io_error;
        };
        return .success;
    }

    /// `dcs_passthrough` effect installed on each pane's live stream: buffer the
    /// recovered (un-doubled) inner bytes of an `ESC P tmux; ...` envelope for
    /// replay through the pane stream after the `%output` feed (see the drain
    /// in `receivedOutput`). Recovers the owning `Pane` from the handler's
    /// terminal pointer (always `pane.terminal`, set by `vtStream`).
    /// ROOTSHELL-TMUX (id=streamterm-tmux-passthrough)
    fn paneDcsPassthrough(handler: *TerminalStreamHandler, data: []const u8) void {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        const alloc = handler.terminal.gpa();
        pane.replay.appendSlice(alloc, data) catch {};
    }

    /// `device_attributes` effect: answer a pane app's DA query. Apps that detect
    /// $TMUX (yazi, etc.) send their terminal-probe — XTVERSION + a Kitty query +
    /// a primary DA — WRAPPED in `ESC P tmux;` passthrough, and wait for the DA
    /// reply as the sentinel that all responses arrived. tmux does NOT answer the
    /// wrapped DA, so the unwrapped query reaches this pane terminal and we must.
    /// The reply is routed UNFILTERED (see `routePaneResponsesUnfiltered`) since
    /// tmux never saw it. Default `Attributes{}` encodes the standard primary DA
    /// `\e[?62;22c`. A RAW (unwrapped) DA still gets dropped by
    /// `tmuxAnswersResponse` (tmux answers those), so no double reply.
    /// ROOTSHELL-TMUX (id=streamterm-tmux-passthrough)
    fn paneDeviceAttributes(_: *TerminalStreamHandler) device_attributes.Attributes {
        return .{};
    }

    /// `size` effect: report the pane's pixel geometry for CSI 14/16/18 t queries
    /// (yazi needs the cell pixel size to scale images). Returns null until the
    /// child surface has reported pixel dimensions (width_px/height_px), so the
    /// query is simply unanswered rather than reporting a bogus zero size.
    /// ROOTSHELL-TMUX (id=streamterm-tmux-passthrough)
    fn paneSize(handler: *TerminalStreamHandler) ?size_report.Size {
        const t = handler.terminal;
        if (t.width_px == 0 or t.height_px == 0 or t.cols == 0 or t.rows == 0) return null;
        return .{
            .rows = t.rows,
            .columns = t.cols,
            .cell_width = t.width_px / @as(u32, @intCast(t.cols)),
            .cell_height = t.height_px / @as(u32, @intCast(t.rows)),
        };
    }

    /// `progress_report` / `pwd_report` / `desktop_notification` effects installed
    /// on each pane's live stream. Unlike clipboard (global → gateway), these are
    /// per-pane: forward them straight to the pane's OWN child surface via
    /// `postOscEvent` (no buffering / no gateway round-trip). The borrowed strings
    /// are copied synchronously by the message-builder in `termio/Tmux.zig`.
    /// ROOTSHELL-TMUX (id=viewer-pane-osc)
    fn paneProgressReport(handler: *TerminalStreamHandler, report: osc.Command.ProgressReport) void {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        pane.postOscEvent(.{ .progress = report });
    }

    fn panePwdReport(handler: *TerminalStreamHandler, pwd: []const u8) void {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        pane.postOscEvent(.{ .pwd = pwd });
    }

    fn paneDesktopNotification(
        handler: *TerminalStreamHandler,
        notification: TerminalStream.Action.ShowDesktopNotification,
    ) void {
        const pane: *Pane = @fieldParentPtr("terminal", handler.terminal);
        pane.postOscEvent(.{ .notification = .{
            .title = notification.title,
            .body = notification.body,
        } });
    }

    /// Drain the pane's buffered OSC 52 clipboard SETs into
    /// `pane_clipboard_write` actions (payload duplicated onto the action arena,
    /// valid until the next `next()`), then free the buffer. The gateway's full
    /// StreamHandler turns each action into a `clipboard_write` surface message.
    /// ROOTSHELL-TMUX (id=viewer-clipboard)
    fn flushPaneClipboard(self: *Viewer, actions: *std.ArrayList(Action), pane: *Pane) void {
        if (pane.clipboard_writes.items.len == 0) return;
        defer {
            for (pane.clipboard_writes.items) |cw| self.alloc.free(cw.data);
            pane.clipboard_writes.clearRetainingCapacity();
        }

        var act_arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = act_arena.state;
        for (pane.clipboard_writes.items) |cw| {
            const data = act_arena.allocator().dupe(u8, cw.data) catch {
                log.warn("failed to allocate clipboard write payload", .{});
                continue;
            };
            actions.append(act_arena.allocator(), .{ .pane_clipboard_write = .{
                .kind = cw.kind,
                .data = data,
            } }) catch {
                log.warn("failed to queue clipboard write action", .{});
            };
        }
    }

    /// Drain the pane's buffered query replies, drop the ones tmux answers
    /// itself (to avoid a double reply corrupting the app's input), and route
    /// the rest back to the app as a `send-keys -H -t %<id>` command.
    fn flushPaneResponses(self: *Viewer, pane_id: usize, pane: *Pane) !void {
        if (pane.responses.items.len == 0) return;
        defer {
            for (pane.responses.items) |chunk| self.alloc.free(chunk);
            pane.responses.clearRetainingCapacity();
        }

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.alloc);
        for (pane.responses.items) |chunk| {
            if (tmuxAnswersResponse(chunk)) continue;
            try payload.appendSlice(self.alloc, chunk);
        }
        if (payload.items.len == 0) return;

        const cmd = try formatSendKeys(self.alloc, pane_id, payload.items);
        self.queueCommands(&.{.{ .user = cmd }}) catch |err| {
            self.alloc.free(cmd);
            return err;
        };
    }

    /// Route `pane.responses[from..]` back to the pane UNFILTERED (bypassing the
    /// `tmuxAnswersResponse` double-reply drop), then free and remove them. Used
    /// for replies generated while replaying an `ESC P tmux;` passthrough query:
    /// tmux never saw the wrapped query, so it answered nothing and every reply
    /// (primary DA, XTVERSION, ...) must reach the app. ROOTSHELL-TMUX
    /// (id=streamterm-tmux-passthrough)
    fn routePaneResponsesUnfiltered(self: *Viewer, pane_id: usize, pane: *Pane, from: usize) !void {
        if (pane.responses.items.len <= from) return;
        defer {
            for (pane.responses.items[from..]) |chunk| self.alloc.free(chunk);
            pane.responses.shrinkRetainingCapacity(from);
        }

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.alloc);
        for (pane.responses.items[from..]) |chunk| {
            try payload.appendSlice(self.alloc, chunk);
        }
        if (payload.items.len == 0) return;

        const cmd = try formatSendKeys(self.alloc, pane_id, payload.items);
        self.queueCommands(&.{.{ .user = cmd }}) catch |err| {
            self.alloc.free(cmd);
            return err;
        };
    }

    /// Format `send-keys -H -t %<id> XX XX ...\n` (space-separated uppercase
    /// hex) for `data`. Caller owns the returned slice. Matches the encoding in
    /// `termio/Tmux.zig` so relayed bytes reach the pane app's stdin intact.
    fn formatSendKeys(alloc: Allocator, pane_id: usize, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "send-keys -H -t %");
        var idbuf: [20]u8 = undefined;
        const ids = std.fmt.bufPrint(&idbuf, "{d}", .{pane_id}) catch unreachable;
        try out.appendSlice(alloc, ids);
        const hex = "0123456789ABCDEF";
        for (data) |b| {
            try out.append(alloc, ' ');
            try out.append(alloc, hex[b >> 4]);
            try out.append(alloc, hex[b & 0x0F]);
        }
        try out.append(alloc, '\n');
        return try out.toOwnedSlice(alloc);
    }

    /// Whether tmux itself answers the query that produced reply `resp`, so we
    /// must NOT also send it (a double reply corrupts the app's input). tmux
    /// answers DA (suppressed upstream via a null effect), DSR, XTVERSION, the
    /// color-scheme DSR, and DECRQM for modes 12/1004/1006/2004. Everything else
    /// (kitty-keyboard `…u`, DECRQM of other modes, OSC 4/12, XTGETTCAP) is for
    /// us to deliver.
    fn tmuxAnswersResponse(resp: []const u8) bool {
        // XTVERSION: DCS > | ... ST
        if (std.mem.startsWith(u8, resp, "\x1bP>|")) return true;
        // DSR operating status: CSI 0 n
        if (std.mem.eql(u8, resp, "\x1b[0n")) return true;
        if (std.mem.startsWith(u8, resp, "\x1b[")) {
            const last = resp[resp.len - 1];
            // DSR cursor position report: CSI <row> ; <col> R
            if (last == 'R') return true;
            // Primary/secondary DA report: CSI ? ... c  /  CSI > ... c. tmux
            // answers DA for RAW pane queries; we also install a
            // device_attributes effect on the pane (to answer WRAPPED
            // `ESC Ptmux;` queries — e.g. yazi's primary-DA sentinel), so the
            // raw-feed copy must be dropped here to avoid a double reply that
            // echoes to the screen. The wrapped-DA reply bypasses this filter
            // via routePaneResponsesUnfiltered. ROOTSHELL-TMUX
            // (id=streamterm-tmux-passthrough)
            if (last == 'c' and resp.len >= 3 and (resp[2] == '?' or resp[2] == '>')) return true;
            // XTWINOPS size report: CSI 4 ; H ; W t (pixels) / CSI 6 ; H ; W t
            // (cell px) / CSI 8 ; rows ; cols t (chars). We install a `.size`
            // effect on every pane so a WRAPPED passthrough size query is
            // answered (yazi needs the cell pixel size to scale images), which
            // means a RAW size query now also produces a local reply. tmux
            // answers raw XTWINOPS itself, so drop our duplicate here; the
            // wrapped reply still bypasses this filter via
            // routePaneResponsesUnfiltered. ROOTSHELL-TMUX
            // (id=streamterm-tmux-passthrough)
            if (last == 't' and resp.len >= 4 and resp[3] == ';' and
                (resp[2] == '4' or resp[2] == '6' or resp[2] == '8')) return true;
            // DECRQM report: CSI ? <mode> ; <val> $ y. tmux answers a fixed set.
            if (last == 'y' and resp.len >= 4 and resp[2] == '?') {
                var i: usize = 3;
                var mode: usize = 0;
                while (i < resp.len and resp[i] >= '0' and resp[i] <= '9') : (i += 1) {
                    mode = mode * 10 + (resp[i] - '0');
                }
                return switch (mode) {
                    12, 1004, 1006, 2004 => true,
                    else => false,
                };
            }
        }
        return false;
    }

    /// Grid-size override for the zoomed pane of a zoomed window: tmux shows
    /// that pane at the full window content size while `window_layout` (which
    /// ignores zoom) still carries its saved leaf dims. ROOTSHELL-TMUX
    /// (id=tmux-zoom-grid-size)
    const ZoomOverride = struct {
        pane_id: usize,
        width: usize,
        height: usize,
    };

    fn initLayout(
        io: std.Io,
        gpa_alloc: Allocator,
        colors: Terminal.Colors,
        default_cursor_style: Screen.CursorStyle,
        default_cursor_blink: ?bool,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
        zoom: ?ZoomOverride,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        io,
                        gpa_alloc,
                        colors,
                        default_cursor_style,
                        default_cursor_blink,
                        panes_old,
                        panes_new,
                        l,
                        zoom,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                // The zoomed pane's real grid is the full window content
                // size, not the saved layout's leaf dims. ROOTSHELL-TMUX
                // (id=tmux-zoom-grid-size)
                var width = layout.width;
                var height = layout.height;
                if (zoom) |z| if (z.pane_id == id) {
                    width = z.width;
                    height = z.height;
                };

                // Validate dimensions before inserting into the map to
                // avoid leaving an uninitialized entry on overflow.
                const cols: size.CellCountInt = std.math.cast(size.CellCountInt, width) orelse {
                    log.info("pane {} width {} overflows CellCountInt, skipping", .{ id, width });
                    break :pane;
                };
                const rows: size.CellCountInt = std.math.cast(size.CellCountInt, height) orelse {
                    log.info("pane {} height {} overflows CellCountInt, skipping", .{ id, height });
                    break :pane;
                };

                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // If we already have this pane, it is already initialized
                // so just copy it over (and resize if the layout changed).
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;
                    const pane = gop.value_ptr.*;

                    // Resize the terminal if the pane's grid dimensions
                    // changed (e.g. after a split or window resize). This
                    // keeps the viewer's terminal in sync with tmux's
                    // actual pane size. Terminal.resize no-ops when the
                    // dimensions already match.
                    //
                    // Hold the child surface's renderer mutex (if a child is
                    // attached) across the resize: it mutates the terminal's
                    // PageList while the child's renderer thread reads the same
                    // terminal under that mutex. Without this lock a relayout
                    // during heavy output (e.g. running btop in a pane) races
                    // the renderer and crashes in updateFrame/updateExtraRows.
                    // Bounded: on timeout, stash the target size so the next
                    // successful lock window applies it (flushPaneDeferred) —
                    // never block the control channel on a pane renderer.
                    // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock)
                    const render_mutex = switch (pane.lockRendererBounded(
                        PANE_LOCK_QUICK_BUDGET_NS,
                    )) {
                        .acquired => |m| m,
                        .timeout => {
                            log.warn(
                                "pane {} renderer lock contended; deferring resize to {}x{}",
                                .{ id, cols, rows },
                            );
                            pane.pending_resize = .{ .cols = cols, .rows = rows };
                            wakePane(pane);
                            break :pane;
                        },
                    };
                    defer pane.unlockRenderer(render_mutex);
                    pane.pending_resize = null;
                    // See id=tmux-pane-pixel-geometry above: cell_size_px keeps
                    // the pane's pixel geometry in step with the cell grid.
                    try pane.terminal.resize(gpa_alloc, .{
                        .cols = cols,
                        .rows = rows,
                        .cell_size_px = pane.cellSizePx(),
                    });
                    // Wake the child surface's renderer so it repaints at the new
                    // size. Resizing the pane terminal reflows its content, but
                    // unlike the `%output` write paths this is NOT a write, so
                    // nothing else wakes the renderer. Without this, a pane whose
                    // program emits no output after a resize (e.g. an idle shell
                    // prompt) keeps drawing its old-size frame — the terminal
                    // "doesn't react" to window/divider resizes. wakePane no-ops
                    // when no child is attached. ROOTSHELL-TMUX (id=viewer-wake-on-resize)
                    wakePane(pane);
                    break :pane;
                }

                var t: Terminal = try .init(io, gpa_alloc, .{
                    .cols = cols,
                    .rows = rows,
                    // tmux replays each pane's recent history via `capture-pane
                    // -S -N` (bounded by PANE_HISTORY_MAX_LINES, and by tmux's
                    // own history-limit, default 2000 lines). The Terminal
                    // default max_scrollback is only 10_000 bytes (~a few lines), which
                    // would discard almost all of it, so give panes a real scrollback
                    // budget matching ghostty's default scrollback-limit (10 MiB).
                    // Actual memory tracks content and is bounded by tmux's own
                    // history-limit, so this is a ceiling, not a reservation.
                    .max_scrollback_bytes = 10 * 1024 * 1024,
                    // Use the gateway terminal's themed colors so default-background
                    // cells match the app theme rather than the built-in dark default
                    // (`.default` colors leave background `.unset`).
                    .colors = colors,
                });
                errdefer t.deinit(gpa_alloc);

                // Seed the configured cursor style/blink so a fresh pane honors
                // `cursor-style`/`cursor-style-blink` (the handler default is
                // seeded in installPaneStreamEffects, below). Only set blink when
                // configured; otherwise leave the Terminal default until the
                // pane_state replay supplies tmux's value. ROOTSHELL-TMUX
                // (id=viewer-cursor-style-default)
                t.screens.active.cursor.cursor_style = default_cursor_style;
                if (default_cursor_blink) |b| t.modes.set(.cursor_blinking, b);

                const pane = try gpa_alloc.create(Pane);
                errdefer gpa_alloc.destroy(pane);
                pane.* = .{
                    .io = io,
                    .terminal = t,
                    .stream = undefined,
                    // A child surface will be created for this new pane (the
                    // reconcile emits an ensure_pane op). Mark it en route so no
                    // free path reclaims it before that child attaches.
                    .pending_attach = true,
                };
                pane.stream = pane.terminal.vtStream();
                installPaneStreamEffects(pane, default_cursor_style, default_cursor_blink);
                gop.value_ptr.* = pane;
            },
        }
    }

    /// Install the per-pane effect routers on a freshly-created `pane.stream`,
    /// and seed the handler's configured cursor defaults so DECSCUSR reset
    /// (`CSI 0 q`) returns to `cursor-style` rather than hardcoded block. Shared
    /// by `initLayout` (new pane) and the discard-reset stream re-creation
    /// (`flagAllPanesForReset`) so the two never drift. ROOTSHELL-TMUX
    /// (id=viewer-force-reset, id=viewer-cursor-style-default)
    fn installPaneStreamEffects(
        pane: *Pane,
        default_cursor_style: Screen.CursorStyle,
        default_cursor_blink: ?bool,
    ) void {
        pane.terminal.cursor.default_style = default_cursor_style;
        // `orelse true` mirrors how a normal surface resolves DECSCUSR 0.
        pane.terminal.cursor.default_blink = default_cursor_blink orelse true;
        // Query-reply router: this pane answers the terminal queries tmux does NOT
        // handle for a control client (kitty-keyboard, DECRQM of unknown modes,
        // OSC 4/12, etc.). Replies are buffered on the pane and routed back to the
        // app via `send-keys` after each `%output` feed; queries tmux DOES answer
        // are dropped in `flushPaneResponses` to avoid double replies. (vtStream
        // defaults to readonly, so capture replays and other vtStream users are
        // unaffected.)
        pane.stream.handler.effects.write_pty = &paneWritePty;
        // Forward OSC 52 clipboard SETs from this pane to the app's system
        // clipboard — tmux never sets the clipboard for a -CC client (no tty).
        // ROOTSHELL-TMUX (id=viewer-clipboard)
        pane.stream.handler.effects.clipboard_write = &paneClipboardWrite;
        // Unwrap+replay `ESC P tmux; ...` passthrough DCS (wrapped Kitty graphics /
        // OSC / queries from apps that detect $TMUX). The handler buffers recovered
        // bytes onto `pane.replay`; the drain in `receivedOutput` re-feeds them.
        // ROOTSHELL-TMUX (id=streamterm-tmux-passthrough)
        pane.stream.handler.effects.dcs_passthrough = &paneDcsPassthrough;
        // Answer DA / pixel-size queries the pane app sends. These matter for apps
        // (yazi) that wrap their terminal probe in `ESC Ptmux;` passthrough: tmux
        // doesn't answer the wrapped query, so the unwrapped copy must be answered
        // here and routed unfiltered (the primary-DA reply is yazi's response-batch
        // sentinel — without it yazi reports "Terminal response timeout"). RAW
        // (unwrapped) DA/size replies are still dropped by `tmuxAnswersResponse` to
        // avoid double-answering what tmux already handles. ROOTSHELL-TMUX
        // (id=streamterm-tmux-passthrough)
        pane.stream.handler.effects.device_attributes = &paneDeviceAttributes;
        pane.stream.handler.effects.size = &paneSize;
        // Forward OSC 9;4 progress / OSC 7 pwd / OSC 9 notifications to this pane's
        // own child surface (the normal terminal-surface path handles them
        // downstream). ROOTSHELL-TMUX (id=viewer-pane-osc)
        pane.stream.handler.effects.progress_report = &paneProgressReport;
        pane.stream.handler.effects.pwd_report = &panePwdReport;
        pane.stream.handler.effects.desktop_notification = &paneDesktopNotification;
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our commands
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        try self.command_owners.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| {
            self.command_queue.appendAssumeCapacity(cmd);
            self.command_owners.appendAssumeCapacity(.ordinary);
        }

        // Move into the command queue state
        self.state = .command_queue;
        self.command_in_flight = true;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.queueCommandsWithOwner(commands, .ordinary);
    }

    fn queueRecoveryCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.queueCommandsWithOwner(commands, .recovery);
    }

    fn queueCommandsWithOwner(
        self: *Viewer,
        commands: []const Command,
        owner: CommandOwner,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        try self.command_owners.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
            self.command_owners.appendAssumeCapacity(owner);
        }
    }

    /// Update the first queued-but-unsent `.client_size` command in place
    /// instead of appending another one. Rapid resizes (keyboard show/hide,
    /// window drags) would otherwise pile up stale sizes that each cost a
    /// full server round-trip — the server visibly steps through obsolete
    /// sizes long after the resize settles, and every step SIGWINCH-storms
    /// the pane apps mid-output. The head entry is skipped while a command
    /// is in flight: its bytes were already formatted and written, and the
    /// response FIFO depends on it staying put. In-place mutation preserves
    /// FIFO/sent-FIFO alignment exactly (no add/remove). Only the dims are
    /// updated — `enable_pause` is preserved (the resync rebuild queues its
    /// client_size with the pause flag set). Returns true when coalesced.
    /// ROOTSHELL-TMUX (id=viewer-coalesce-client-size)
    fn coalescePendingClientSize(
        self: *Viewer,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) bool {
        var it = self.command_queue.iterator(.forward);
        if (self.command_in_flight) _ = it.next();
        while (it.next()) |entry| {
            if (entry.* == .client_size) {
                entry.client_size.cols = cols;
                entry.client_size.rows = rows;
                return true;
            }
        }
        return false;
    }

    /// For a per-window size push `refresh-client -C @<id>:<W>x<H>\n`,
    /// return its `refresh-client -C @<id>:` prefix (digits required between
    /// '@' and ':'); null for any other command.
    /// ROOTSHELL-TMUX (id=viewer-coalesce-window-refresh)
    fn windowRefreshPrefix(cmd: []const u8) ?[]const u8 {
        const lead = "refresh-client -C @";
        if (!std.mem.startsWith(u8, cmd, lead)) return null;
        const colon = std.mem.indexOfScalarPos(u8, cmd, lead.len, ':') orelse return null;
        if (colon == lead.len) return null;
        for (cmd[lead.len..colon]) |c| if (!std.ascii.isDigit(c)) return null;
        return cmd[0 .. colon + 1];
    }

    /// Replace a queued-but-unsent per-window size refresh (`refresh-client
    /// -C @<id>:WxH`) for the SAME window with the newer bytes, in place.
    /// Same head-skip and FIFO rationale as `coalescePendingClientSize`. The
    /// old `.user` buffer is freed and replaced with a gpa-owned dupe of
    /// `cmd` (ownership identical to the append path; `Command.deinit` frees
    /// `.user`). The dupe happens BEFORE the free so an allocation failure
    /// leaves the queue intact. Returns true when coalesced.
    /// ROOTSHELL-TMUX (id=viewer-coalesce-window-refresh)
    fn coalescePendingWindowRefresh(
        self: *Viewer,
        cmd: []const u8,
    ) Allocator.Error!bool {
        const prefix = windowRefreshPrefix(cmd) orelse return false;
        var it = self.command_queue.iterator(.forward);
        if (self.command_in_flight) _ = it.next();
        while (it.next()) |entry| {
            if (entry.* != .user) continue;
            if (!std.mem.startsWith(u8, entry.user, prefix)) continue;
            const copy = try self.alloc.dupe(u8, cmd);
            self.alloc.free(entry.user);
            entry.user = copy;
            return true;
        }
        return false;
    }

    /// Queue a raw, pre-formatted tmux command (already including its trailing
    /// newline) that was issued out-of-band by a child pane backend —
    /// `resize-pane`, `select-pane`, `select-window`. Routing it through the
    /// command queue (rather than writing it straight to tmux) is essential:
    /// the queue serializes it AFTER any in-flight capture-pane sequence and
    /// consumes its (empty) %begin/%end response, so it can never inject a
    /// stray block that shifts the response FIFO — which otherwise mis-matches
    /// pane_visible/pane_state and strands a pane on the wrong (scrollback-less)
    /// screen on attach. The bytes are copied; the copy is freed in
    /// `Command.deinit` via the `.user` arm.
    ///
    /// A per-window size refresh coalesces into a pending one for the same
    /// window (see `coalescePendingWindowRefresh`) instead of appending.
    pub fn queueUserCommand(self: *Viewer, cmd: []const u8) Allocator.Error!void {
        if (try self.coalescePendingWindowRefresh(cmd)) return;
        const copy = try self.alloc.dupe(u8, cmd);
        errdefer self.alloc.free(copy);
        try self.queueCommands(&.{.{ .user = copy }});
    }

    /// Queue an app-issued query command whose response is delivered back
    /// as a `command_response` action carrying `tag`. Same serialization
    /// rationale as `queueUserCommand`. A missing trailing newline is
    /// appended (the `.command` action contract requires it).
    /// ROOTSHELL-TMUX (id=viewer-user-query)
    pub fn queueUserQuery(self: *Viewer, cmd: []const u8, tag: u32) Allocator.Error!void {
        const needs_nl = cmd.len == 0 or cmd[cmd.len - 1] != '\n';
        const copy = copy: {
            if (!needs_nl) break :copy try self.alloc.dupe(u8, cmd);
            const buf = try self.alloc.alloc(u8, cmd.len + 1);
            @memcpy(buf[0..cmd.len], cmd);
            buf[cmd.len] = '\n';
            break :copy buf;
        };
        errdefer self.alloc.free(copy);
        try self.queueCommands(&.{.{ .user_query = .{ .cmd = copy, .tag = tag } }});
    }

    /// Invoke `cb` with the tag of every queued (including in-flight)
    /// `user_query` command. The stream handler uses this to error pending
    /// app queries back before a queue-clearing reset (`forceResync`) or
    /// viewer teardown — otherwise the app-side continuations would hang
    /// until their timeout. ROOTSHELL-TMUX (id=viewer-user-query)
    pub fn forEachPendingQueryTag(
        self: *Viewer,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), u32) void,
    ) void {
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |command| switch (command.*) {
            .user_query => |q| cb(ctx, q.tag),
            else => {},
        };
    }

    /// Queue a command relayed out-of-band from a child pane backend
    /// (`termio.Tmux`): `resize-pane` (the pane's grid changed — keyboard,
    /// font, rotation), `select-pane`, `select-window`. Most are forwarded
    /// verbatim like `queueUserCommand`, with ONE translation:
    ///
    /// A `resize-pane` targeting a pane that is the ONLY pane in its window is
    /// rewritten to a `client_size` (`refresh-client -C`). In a single-pane
    /// window the pane fills the window, whose size equals the control client
    /// size, so tmux treats `resize-pane` as a no-op — the window only reflows
    /// when the client size changes. The pane's grid (computed by the child
    /// surface, already cell-, font-, and inset-aware exactly like a normal
    /// surface) IS the desired window/client size, so we forward it as such.
    /// This keeps the whole resize path in the core/Zig layer — the apprt only
    /// drives `ghostty_surface_set_size`, identical to a non-tmux surface.
    ///
    /// Multi-pane `resize-pane` (a split-divider drag) is forwarded unchanged.
    pub fn queueRelayedPaneCommand(self: *Viewer, cmd: []const u8) Allocator.Error!void {
        if (parseSelectWindow(cmd)) |window_id| {
            self.prioritizeRecoveryWindow(window_id);
        }
        if (parseResizePane(cmd)) |rp| {
            if (self.windowIsSinglePane(rp.pane_id)) {
                // Single-pane window: the pane fills the window, so its grid IS
                // the desired client size. Reuse setClientSize: it stores the
                // dims and queues a tracked client_size ONLY in the command_queue
                // state (during startup it just stores, so the size is sent by
                // tryFinishStartup and never injected mid-startup-sequence).
                self.setClientSize(rp.cols, rp.rows);
                return;
            }

            // Multi-pane window: tmux owns the per-pane split. The apprt must NOT
            // echo a per-pane `resize-pane` here: a pane's grid is a pixel-rounded
            // cell count that never exactly matches tmux's cell-exact layout, so
            // forwarding it makes tmux nudge the layout, which re-renders the pane
            // off-by-one again on the next reconcile — an unbounded relayout loop
            // (hit by ANY multi-pane tmux window, from Cmd-D or tmux's own split
            // binding). The WHOLE-window size is driven instead from the apprt's
            // split container via `refresh-client -C`
            // (ghostty_surface_tmux_set_client_size); tmux distributes that across
            // the panes. So a multi-pane per-pane resize is intentionally dropped.
            // ROOTSHELL-TMUX (id=viewer-drop-multipane-resize)
            return;
        }
        try self.queueUserCommand(cmd);
    }

    /// Parse the exact command emitted by Rootshell when a projected tmux tab
    /// becomes selected. Keeping this private wire recognition avoids another
    /// public ABI while still allowing unfinished recovery to jump windows.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    fn parseSelectWindow(cmd: []const u8) ?usize {
        const trimmed = std.mem.trim(u8, cmd, " \r\n");
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        if (!std.mem.eql(u8, it.next() orelse return null, "select-window")) return null;
        if (!std.mem.eql(u8, it.next() orelse return null, "-t")) return null;
        const target = it.next() orelse return null;
        if (it.next() != null or target.len < 2 or target[0] != '@') return null;
        return std.fmt.parseInt(usize, target[1..], 10) catch null;
    }

    const ResizePane = struct {
        pane_id: usize,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    };

    /// Parse `resize-pane -t %<id> -x <cols> -y <rows>` — the exact format
    /// emitted by `termio.Tmux.resize`. Returns null for any other command.
    /// Byte-level, no allocation.
    fn parseResizePane(cmd: []const u8) ?ResizePane {
        const trimmed = std.mem.trim(u8, cmd, " \r\n");
        if (!std.mem.startsWith(u8, trimmed, "resize-pane ")) return null;
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        _ = it.next() orelse return null; // resize-pane
        var pane_id: ?usize = null;
        var cols: ?size.CellCountInt = null;
        var rows: ?size.CellCountInt = null;
        while (it.next()) |tok| {
            const val = it.next() orelse break;
            if (std.mem.eql(u8, tok, "-t")) {
                if (val.len < 2 or val[0] != '%') return null;
                pane_id = std.fmt.parseInt(usize, val[1..], 10) catch return null;
            } else if (std.mem.eql(u8, tok, "-x")) {
                cols = std.fmt.parseInt(size.CellCountInt, val, 10) catch return null;
            } else if (std.mem.eql(u8, tok, "-y")) {
                rows = std.fmt.parseInt(size.CellCountInt, val, 10) catch return null;
            }
        }
        return .{
            .pane_id = pane_id orelse return null,
            .cols = cols orelse return null,
            .rows = rows orelse return null,
        };
    }

    /// Whether `pane_id` is the sole pane in its window (its window's layout
    /// root is a single leaf). Returns false when the pane's window is unknown
    /// — be conservative and forward the `resize-pane` rather than resizing the
    /// whole client.
    fn windowIsSinglePane(self: *const Viewer, pane_id: usize) bool {
        for (self.windows.items) |w| {
            if (layoutContainsPane(w.layout, pane_id)) {
                return w.layout.content == .pane;
            }
        }
        return false;
    }

    fn layoutContainsPane(layout: Layout, pane_id: usize) bool {
        return switch (layout.content) {
            .pane => |id| id == pane_id,
            .horizontal, .vertical => |children| {
                for (children) |child| {
                    if (layoutContainsPane(child, pane_id)) return true;
                }
                return false;
            },
        };
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        // Record a generic defunct reason if a more specific error wasn't
        // already set on the way here. ROOTSHELL-TMUX (id=control-error-code)
        if (self.last_error == .none) self.last_error = .defunct;
        self.state = .defunct;
        return self.singleAction(.exit);
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We need two things before we can
    /// proceed: (1) the initial %begin/%end block for the attach
    /// command, and (2) a %session-changed notification for the
    /// session ID. tmux currently sends the block first, but we
    /// handle either order for robustness.
    startup,

    /// We entered this state on a control-mode RESUME: the iOS app
    /// relaunched and tssh reattached a still-live `tmux -CC` pty, so
    /// there is no fresh `ESC P 1000 p` handshake to wait for — the
    /// reattached stream resumes mid-protocol and may carry buffered
    /// output and in-flight `%begin/%end` blocks from before the
    /// relaunch. We drop everything until a `display-message` probe
    /// echoes our `resync_marker` back (proving the stream is clean
    /// from here), then transition to `command_queue` and rebuild the
    /// full topology with list-windows. See `nextResync`. ROOTSHELL-TMUX
    /// (id=viewer-state-resync)
    resync,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes. The
    /// payload is the session id: pane_state is targeted via
    /// `list-panes -s -t $<id>` so the state for EVERY window's panes is
    /// returned, not just the current window's. Without session scope,
    /// panes in non-active windows never get switched back to their real
    /// screen and stay stranded blank on the alternate screen.
    /// ROOTSHELL-TMUX
    pane_state: usize,

    /// Window-scoped pane state used by incremental discard recovery. This is
    /// what lets one selected window become interactive while other windows
    /// remain safely uninitialized in the background.
    /// ROOTSHELL-TMUX (id=viewer-active-first-recovery)
    window_pane_state: usize,

    /// Get the tmux server version.
    tmux_version,

    /// Enable control-mode pause-after flow control WITHOUT asserting a client
    /// size (`refresh-client -f pause-after=<n>`, no `-C`). Sent as the first
    /// startup command so tmux pauses a lagging pane instead of killing the
    /// client at CONTROL_MAXIMUM_AGE, while leaving the control client SIZELESS.
    /// A sizeless control client is ignored for window sizing, so tmux keeps
    /// each window at the size it was left at on the previous detach rather than
    /// reflowing every app to our (possibly stale/narrow) gateway grid on
    /// attach. The app's first layout pass then sets the real viewport via a
    /// normal `client_size`, giving one deliberate resize like a regular
    /// `tmux attach` instead of a lossy shrink-then-grow. ROOTSHELL-TMUX
    /// (id=viewer-startup-pause-only)
    enable_pause,

    /// Subscribe to each window's active-pane title via `refresh-client -B`.
    /// tmux then emits `%subscription-changed` whenever a window's
    /// `#{pane_title}` (`#T`) changes, which the viewer maps onto the tab
    /// title. The subscription is client-scoped and persists across session
    /// changes, so it is issued once during startup. See
    /// `title_subscription_name`.
    subscribe_titles,

    /// Query the current mode of a specific pane via display-message.
    /// Used to determine whether a pane is in copy-mode, view-mode, etc.
    pane_mode_query: usize,

    /// Set the control client size. tmux uses this (along with other
    /// attached clients) to determine window dimensions. When
    /// `enable_pause` is set, the pause-after flow control flag is
    /// also sent in the same refresh-client command.
    client_size: struct {
        cols: size.CellCountInt,
        rows: size.CellCountInt,
        enable_pause: bool = false,
    },

    /// Resume a paused pane. Sent as `refresh-client -A '%<id>:continue'`.
    continue_pane: usize,

    /// Report one of this pane's colors to tmux via
    /// `refresh-client -r "%<id>:<OSC report>"`. tmux stores it in
    /// `wp->control_fg`/`wp->control_bg` and uses it to answer an app's
    /// `OSC 10`/`OSC 11` color queries (`window_pane_get_fg_control_client` /
    /// `window_pane_get_bg_control_client`). Without this, tmux has no client
    /// color, `input_osc_colour_reply` returns nothing for the query, and the
    /// app (e.g. opencode) blocks forever waiting for a background-color reply.
    /// This mirrors iTerm2's per-pane `refresh-client -r` color reporting.
    ///
    /// Foreground (`code = 10`) and background (`code = 11`) MUST be sent as two
    /// SEPARATE commands: tmux's `cmd_refresh_report` calls `tty_keys_colours`
    /// once and it parses exactly one OSC sequence, so a combined buffer would
    /// only register the first color (iTerm2 sends two reports for the same
    /// reason).
    pane_color_report: struct {
        pane_id: usize,
        /// OSC code: 10 (foreground) or 11 (background).
        code: u8,
        color: color.RGB,
    },

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    /// App-issued query: like `user`, but the block response (or `%error`
    /// body) is delivered back to the app as a `command_response` action,
    /// correlated by the app-provided tag. Used by the session dashboard
    /// (`list-sessions`, `list-windows -t`, `new-session -P`, ...).
    /// ROOTSHELL-TMUX (id=viewer-user-query)
    user_query: struct {
        /// gpa-owned, freed in deinit. Includes the trailing newline.
        cmd: []const u8,
        /// Opaque app-side correlation tag, echoed back verbatim.
        tag: u32,
    },

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .window_pane_state,
            .tmux_version,
            .enable_pause,
            .subscribe_titles,
            .pane_mode_query,
            .client_size,
            .continue_pane,
            .pane_color_report,
            => {},
            .user => |v| alloc.free(v),
            .user_query => |v| alloc.free(v.cmd),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -J = join wrapped lines (id=capture-join-wrapped). This is the
                //   only flag that omits the `\n` between a soft-wrapped row and
                //   its continuation (tmux cmd-capture-pane.c: a newline is emitted
                //   iff the row is NOT GRID_LINE_WRAPPED). Feeding that joined,
                //   newline-free run into the pane terminal lets it re-wrap at the
                //   current width, so reattached scrollback reflows on a later
                //   resize — matching how a native `tmux attach` behaves. The
                //   tradeoff: `-J` implies `-T`, which makes tmux serialize each
                //   line only to its last glyph (`cellused`, not `cellsize`), so a
                //   background an app painted past that point with `\x1b[K` is
                //   dropped (slightly ragged colored rectangles in reattached
                //   scrollback, e.g. Claude Code diffs). The alternative, `-N`,
                //   keeps the full per-cell background but emits a hard `\n` after
                //   every row, hard-breaking soft-wrapped lines so they can never
                //   reflow. Reflow correctness wins (iTerm2 makes the same choice);
                //   recovering both would need a dual -N/-J capture + merge.
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S -N = start at most N lines above the visible top (tmux
                //   clamps to available history). Bounded so a huge-history
                //   pane can't produce a multi-MB reply in one block (see
                //   PANE_HISTORY_MAX_LINES, id=pane-history-max-lines).
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -J {s}-q -S -{d} -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    PANE_HISTORY_MAX_LINES,
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // See pane_history for the flags. (no -S/-E = visible area only)
                "capture-pane -p -e -J {s}-q -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            // ROOTSHELL-TMUX: `-s -t $<session>` lists panes for the WHOLE
            // session (every window), not just the current window. Without
            // `-s`, tmux returns only the current window's panes, so panes in
            // other windows never receive their pane_state and stay stranded
            // on the blank alternate screen (no scrollback). Mirrors iTerm2's
            // `list-panes -s -t $<sessionId>` (TmuxController.m).
            .pane_state => |session_id| try writer.print(
                "list-panes -s -t ${d} -F '{s}'\n",
                .{ session_id, comptime Format.list_panes.comptimeFormat() },
            ),

            .window_pane_state => |window_id| try writer.print(
                "list-panes -t @{d} -F '{s}'\n",
                .{ window_id, comptime Format.list_panes.comptimeFormat() },
            ),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            // Enable pause-after flow control without setting a size: no `-C`,
            // so the control client stays sizeless and tmux preserves each
            // window's pre-detach size on attach. ROOTSHELL-TMUX
            // (id=viewer-startup-pause-only)
            .enable_pause => try writer.print(
                "refresh-client -f pause-after={d}\n",
                .{PAUSE_AFTER_SECONDS},
            ),

            // Subscribe to every window's display title. `@*` = all windows;
            // the format is evaluated in each window's context. Single-quoted
            // so tmux stores the literal format (expanded per tick), not at
            // parse time.
            //
            // The format resolves the title precedence server-side:
            // `automatic-rename` is a flag option (expands 1/0 in formats),
            // so a window with an automatic name shows its active pane's
            // title (`#T`, rich), while a MANUALLY renamed window (any
            // client's rename-window flips automatic-rename off) shows the
            // chosen window name (`#W`). Without the conditional,
            // rename-window was invisible: `#T` always won and shells rewrite
            // it constantly. tmux re-evaluates the subscription whenever
            // either input changes, so renames and pane-title updates both
            // stream in live. ROOTSHELL-TMUX (id=viewer-title-subscription-rename)
            //
            // `#T` is never EMPTY, so the `resolveWindowTitle` fallback can't
            // catch an untitled pane: window_pane_create seeds every pane's
            // title with gethostname(), and a plain shell under tmux never
            // overwrites it (the macOS /etc/{bash,zsh}rc title hooks are gated
            // on an xterm*-class TERM, and TERM is screen-256color in tmux). A
            // fresh window therefore reported the tmux SERVER's host name as
            // its tab title instead of the running command. Detect that default
            // and fall through to `#W`, which under automatic-rename is
            // `#{pane_current_command}`. We match `#{host_short}` and
            // `#{host_short}.*` rather than plain `#{host}` because macOS
            // flips its host name between `Name.local` and `Name.localdomain`
            // as the network changes, and a pane created under the old suffix
            // would no longer compare equal to the current `#{host}`.
            // ROOTSHELL-TMUX (id=viewer-title-subscription-host-default)
            .subscribe_titles => try writer.writeAll(
                "refresh-client -B '" ++ control.title_subscription_name ++
                    ":@*:#{?automatic-rename," ++
                    "#{?#{||:#{==:#{pane_title},#{host_short}}," ++
                    "#{m:#{host_short}.*,#{pane_title}}}," ++
                    "#{window_name},#{pane_title}}," ++
                    "#{window_name}}'\n",
            ),

            .pane_mode_query => |pane_id| try writer.print(
                "display-message -p -t %{d} '{s}'\n",
                .{ pane_id, comptime Format.pane_mode.comptimeFormat() },
            ),

            .client_size => |cs| {
                try writer.print("refresh-client -C {d}x{d}", .{ cs.cols, cs.rows });
                if (cs.enable_pause) {
                    // pause-after (SECONDS) enables control-mode pause so tmux
                    // pauses a lagging pane instead of killing the client at
                    // CONTROL_MAXIMUM_AGE.
                    //
                    // Do NOT add `wait-exit` here. It makes the `tmux -CC` client
                    // BLOCK reading stdin after it prints `%exit` (client.c) until
                    // it receives an empty line. The app's gateway-detach path does
                    // not drain that handshake, so wait-exit leaves the gateway's
                    // `tmux -CC` stuck after an ESC detach (gateway never returns to
                    // its shell). ROOTSHELL-TMUX (id=client-flags)
                    try writer.print(" -f pause-after={d}", .{PAUSE_AFTER_SECONDS});
                }
                try writer.writeAll("\n");
            },

            .continue_pane => |pane_id| try writer.print(
                "refresh-client -A '%{d}:continue'\n",
                .{pane_id},
            ),

            .pane_color_report => |r| {
                // Hand tmux one color (OSC 10 fg or OSC 11 bg) so it can answer
                // the pane app's color query. The control bytes are written as
                // the ASCII-escaped octal `\033` (NOT a raw 0x1B) and the ST's
                // trailing backslash as `\\`: tmux's command lexer
                // (`yylex_token_escape`) unescapes `\033`->ESC and `\\`->`\`
                // inside the double-quoted argument, then `cmd_refresh_report`
                // feeds the resulting raw OSC reply to `tty_keys_colours`.
                // Because the bytes on the wire carry no 0x1B, the app-side
                // gateway report stripper (which drops any raw escape on the
                // command channel) leaves this command intact. The doubled-hex
                // (`{x:0>2}` twice per channel) matches tmux's own
                // `input_osc_colour_reply` 16-bit `rgb:RRRR/GGGG/BBBB` format.
                try writer.print(
                    "refresh-client -r \"%{d}:" ++
                        "\\033]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\\033\\\\\"\n",
                    .{
                        r.pane_id,
                        r.code,
                        r.color.r,
                        r.color.r,
                        r.color.g,
                        r.color.g,
                        r.color.b,
                        r.color.b,
                    },
                );
            },

            .user => |v| try writer.writeAll(v),

            .user_query => |v| try writer.writeAll(v.cmd),
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            //
            // tmux variable names differ from Ghostty's xterm mode names:
            //   mouse_standard_flag -> mouse_event_normal (DECSET 1000)
            //   mouse_button_flag   -> mouse_event_button (DECSET 1002)
            //   mouse_all_flag      -> mouse_event_any    (DECSET 1003)
            //   mouse_any_flag      -> any of the above modes is active
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            // bracketed_paste is requested for format-shape stability but its
            // value is deliberately IGNORED in receivedPaneState: tmux exposes
            // no such variable (`#{bracketed_paste}` expands to empty on every
            // tmux through 3.6), so applying it would clobber the pane's own
            // live DECSET-2004 tracking. See id=tmux-pane-bracketed-paste.
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
        },
    };

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_active,
            .window_index,
            .window_zoomed_flag,
            .pane_id,
            .window_width,
            .window_height,
            .window_layout,
            .window_name,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    const pane_mode: Format = .{
        .delim = ' ',
        .vars = &.{.pane_mode},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);
        defer {
            for (actions) |action| {
                if (action == .windows) {
                    var it = viewer.panes.iterator();
                    while (it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
                }
            }
        }

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

fn testBlock(content: []const u8, flags: usize) control.Block {
    return .{
        .content = content,
        .info = .{
            .time = 0,
            .command_id = 0,
            .flags = flags,
        },
    };
}

fn blockEnd(content: []const u8) control.Notification {
    return .{ .block_end = testBlock(content, 1) };
}

fn serverBlockEnd(content: []const u8) control.Notification {
    return .{ .block_end = testBlock(content, 0) };
}

fn delimitedFieldNonEmpty(line: []const u8, delim: u8, index: usize) bool {
    var it = std.mem.splitScalar(u8, line, delim);
    var i: usize = 0;
    while (it.next()) |field| : (i += 1) {
        if (i == index) return field.len > 0;
    }
    return false;
}

fn formatFieldIndex(comptime format: Format, comptime variable: output.Variable) usize {
    inline for (format.vars, 0..) |field, i| {
        if (field == variable) return i;
    }
    @compileError("format does not contain requested variable");
}

fn parseLeadingVersionNumber(s: []const u8, start: *usize) ?u32 {
    var i = start.*;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return null;

    var value: u32 = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        const digit: u32 = @intCast(s[i] - '0');
        value = std.math.mul(u32, value, 10) catch return null;
        value = std.math.add(u32, value, digit) catch return null;
    }
    start.* = i;
    return value;
}

fn tmuxVersionAtLeast(version: []const u8, min_major: u32, min_minor: u32) bool {
    const trimmed = std.mem.trim(u8, version, " \t\r\n");
    var i = std.mem.indexOfAny(u8, trimmed, "0123456789") orelse return false;
    const major = parseLeadingVersionNumber(trimmed, &i) orelse return false;

    var minor: u32 = 0;
    if (i < trimmed.len and trimmed[i] == '.') {
        i += 1;
        minor = parseLeadingVersionNumber(trimmed, &i) orelse 0;
    }

    if (major != min_major) return major > min_major;
    return minor >= min_minor;
}

test "client_size command formats refresh-client" {
    const cmd: Command = .{ .client_size = .{ .cols = 120, .rows = 36 } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings("refresh-client -C 120x36\n", result);
}

test "client_size with enable_pause formats pause-after flag" {
    const cmd: Command = .{ .client_size = .{ .cols = 80, .rows = 24, .enable_pause = true } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings("refresh-client -C 80x24 -f pause-after=200\n", result);
}

test "continue_pane command formats refresh-client -A" {
    const cmd: Command = .{ .continue_pane = 42 };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings("refresh-client -A '%42:continue'\n", result);
}

test "subscribe_titles command formats refresh-client -B" {
    const cmd: Command = .subscribe_titles;
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings(
        "refresh-client -B 'ghostty_title:@*:#{?automatic-rename," ++
            "#{?#{||:#{==:#{pane_title},#{host_short}}," ++
            "#{m:#{host_short}.*,#{pane_title}}}," ++
            "#{window_name},#{pane_title}}," ++
            "#{window_name}}'\n",
        result,
    );
}

test "capture-pane always uses -J (reflow) and never -N" {
    // -J joins soft-wrapped rows (no `\n` between a wrapped row and its
    // continuation), so reattached scrollback re-wraps at the current width and
    // reflows on resize. -N would keep the full per-cell trailing background but
    // hard-break every row, killing reflow. Reflow wins (see formatCommand), so
    // both pane_history and pane_visible must always emit -J and never -N.
    inline for (&[_][]const u8{ "pane_history", "pane_visible" }) |field| {
        inline for (&[_]ScreenSet.Key{ .primary, .alternate }) |screen_key| {
            const cmd: Command = @unionInit(Command, field, .{
                .id = 7,
                .screen_key = screen_key,
            });
            var builder: std.Io.Writer.Allocating = .init(testing.allocator);
            defer builder.deinit();
            try cmd.formatCommand(&builder.writer);
            const result = builder.writer.buffered();
            try testing.expect(std.mem.containsAtLeast(u8, result, 1, "-J "));
            try testing.expect(!std.mem.containsAtLeast(u8, result, 1, "-N"));
        }
    }
}

test "pane_history bounds the replay depth (-S -N, never -S - )" {
    // ROOTSHELL-TMUX (id=pane-history-max-lines): an unbounded `-S -` makes
    // the attach replay proportional to the pane's entire history; a
    // huge-history pane then answers with a multi-MB block whose burst can
    // stall the transport. The start line must be the bounded constant.
    inline for (&[_]ScreenSet.Key{ .primary, .alternate }) |screen_key| {
        const cmd: Command = .{ .pane_history = .{
            .id = 7,
            .screen_key = screen_key,
        } };
        var builder: std.Io.Writer.Allocating = .init(testing.allocator);
        defer builder.deinit();
        try cmd.formatCommand(&builder.writer);
        const result = builder.writer.buffered();
        try testing.expect(std.mem.containsAtLeast(u8, result, 1, "-S -10000 "));
        try testing.expect(!std.mem.containsAtLeast(u8, result, 1, "-S - "));
    }
}

test "pane_state formats session-scoped list-panes" {
    // ROOTSHELL-TMUX: pane_state MUST be `-s -t $<session>` so tmux returns
    // panes for EVERY window in the session, not just the current window.
    // Without session scope, panes in non-active windows never get switched
    // back to their real screen on attach and stay stranded blank on the
    // alternate screen (the multi-window scrollback-restore bug).
    const cmd: Command = .{ .pane_state = 3 };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, result, "list-panes -s -t $3 -F '"));
    try testing.expect(std.mem.endsWith(u8, result, "'\n"));
}

test "window_pane_state formats window-scoped list-panes" {
    const cmd: Command = .{ .window_pane_state = 7 };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, result, "list-panes -t @7 -F '"));
    try testing.expect(std.mem.endsWith(u8, result, "'\n"));
}

test "window recovery state only releases panes enrolled in recovery" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);

    const pane0 = viewer.panes.get(0).?;
    const pane1 = viewer.panes.get(1).?;
    pane0.recovery_pending = false;
    pane1.recovery_pending = true;
    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 1,
        .pane_id = 1,
        .completed = 4,
    });

    // %0 is in @0, but represents a pane added after @0's scoped state was
    // sent. Merely sharing the window must not let that older completion
    // initialize it. %1 is in @1, explicitly enrolled, and capture-complete,
    // so it matches.
    try testing.expect(!viewer.paneIncludedInStateCompletion(0, pane0, 0));
    try testing.expect(viewer.paneIncludedInStateCompletion(1, pane1, 1));
    try testing.expect(!viewer.paneIncludedInStateCompletion(1, pane1, 0));
}

test "pane_color_report formats refresh-client -r with escaped OSC 11 (bg)" {
    const cmd: Command = .{ .pane_color_report = .{
        .pane_id = 2,
        .code = 11,
        .color = .{ .r = 0x00, .g = 0x10, .b = 0x20 },
    } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    // On the wire the control bytes are the literal ASCII octal escape `\033`
    // and the ST's trailing backslash is doubled (`\\`); tmux's command lexer
    // unescapes both inside the double-quoted argument before handing the raw
    // OSC reply to `cmd_refresh_report`/`tty_keys_colours`.
    try testing.expectEqualStrings(
        "refresh-client -r \"%2:\\033]11;rgb:0000/1010/2020\\033\\\\\"\n",
        result,
    );
}

test "pane_color_report formats OSC 10 (fg)" {
    const cmd: Command = .{ .pane_color_report = .{
        .pane_id = 5,
        .code = 10,
        .color = .{ .r = 0xc0, .g = 0xc1, .b = 0xc2 },
    } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expectEqualStrings(
        "refresh-client -r \"%5:\\033]10;rgb:c0c0/c1c1/c2c2\\033\\\\\"\n",
        result,
    );
}

test "tmuxAnswersResponse drops tmux-handled replies, forwards the rest" {
    // Dropped: tmux answers these itself, so a second reply would corrupt input.
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[4;1R")); // DSR cursor position
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[0n")); // DSR operating status
    try testing.expect(Viewer.tmuxAnswersResponse("\x1bP>|tmux 3.6\x1b\\")); // XTVERSION
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[?2004;1$y")); // DECRQM bracketed paste
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[?12;1$y")); // DECRQM cursor blink
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[?62;22c")); // primary DA
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[>1;95;0c")); // secondary DA
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[8;24;80t")); // XTWINOPS text-area (chars)
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[6;18;9t")); // XTWINOPS cell size (px)
    try testing.expect(Viewer.tmuxAnswersResponse("\x1b[4;432;720t")); // XTWINOPS text-area (px)

    // Forwarded: tmux ignores these for a -CC client, so we must deliver them.
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b[?2026;2$y")); // DECRQM synchronized output
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b[?0u")); // kitty keyboard
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b]4;1;rgb:0000/0000/0000\x1b\\")); // OSC 4
    try testing.expect(!Viewer.tmuxAnswersResponse("\x1b]12;rgb:ffff/ffff/ffff\x07")); // OSC 12
}

test "formatSendKeys hex-encodes bytes targeting the pane" {
    const cmd = try Viewer.formatSendKeys(testing.allocator, 5, "\x1b[?0u");
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("send-keys -H -t %5 1B 5B 3F 30 75\n", cmd);
}

test "pane DCS terminates and doesn't swallow the rest of the stream" {
    // Regression: opencode (and other apps that detect $TMUX) emit
    // `ESC P tmux; ...` passthrough DCS in %output. The fork's parse table keeps
    // the parser in dcs_passthrough on ESC/C1 (so the gateway control-mode DCS
    // isn't cut short), so without the pane handler's own ST detection the DCS
    // would eat the following `1049h` and the entire UI -> blank pane.
    const dcs_prefixes = [_][]const u8{
        "\x1bPt\x1b\\", // minimal DCS, 7-bit ST
        "\x1bPtmux;\x1b\\", // tmux passthrough, empty
        "\x1bPtmux;\x1b\x1b[?1016$p\x1b\\", // tmux passthrough with doubled escapes
        "\x1bPq\x1b\\", // sixel-style
        "\x1bP+q544E\x1b\\", // XTGETTCAP
        "\x1bPt\x9c", // 8-bit C1 ST
        "\x1bPqÜ远\x1b\\", // 0x9C as a UTF-8 continuation byte is not ST
        "\x1bPtmux;\x1b\x1b]0;Ü远\x07\x1b\\", // same inside a tmux envelope
        "\x1bPq\xe0\x9c", // malformed UTF-8: 0x9C is a real 8-bit ST
        "\x1bPtmux;\xf4\x9c", // same inside a tmux envelope
    };
    for (dcs_prefixes) |prefix| {
        var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 100, .rows = 30 });
        defer t.deinit(testing.allocator);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(prefix);
        // A mode-set and a print after the DCS must take effect.
        stream.nextSlice("\x1b[?1049h");
        try testing.expectEqual(.alternate, t.screens.active_key);
        stream.nextSlice("ABC");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expect(std.mem.indexOf(u8, str, "ABC") != null);
    }
}

test "pane_color_report contains no raw ESC so it survives the gateway strip" {
    // The app-side `stripTerminalReports` drops any raw 0x1B on the tmux command
    // channel. This command MUST carry only ASCII-escaped `\033` (never a raw
    // ESC) so the color report actually reaches tmux instead of being stripped.
    const cmd: Command = .{ .pane_color_report = .{
        .pane_id = 7,
        .code = 11,
        .color = .{ .r = 0x1b, .g = 0x1b, .b = 0x1b },
    } };
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try cmd.formatCommand(&builder.writer);
    const result = builder.writer.buffered();
    try testing.expect(std.mem.indexOfScalar(u8, result, 0x1b) == null);
}

test "pane_color_report is gated to tmux versions with refresh-client -r" {
    try testing.expect(!tmuxVersionAtLeast("3.4", 3, 5));
    try testing.expect(!tmuxVersionAtLeast("3.4a", 3, 5));
    try testing.expect(tmuxVersionAtLeast("3.5", 3, 5));
    try testing.expect(tmuxVersionAtLeast("3.5a", 3, 5));
    try testing.expect(tmuxVersionAtLeast("next-3.5", 3, 5));
    try testing.expect(tmuxVersionAtLeast("3.10", 3, 5));
}

test "setClientSize queues command in command_queue state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence + pane_state + subscribe_titles.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
    });

    // Now in command_queue state with empty queue and no command in flight.
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(!viewer.command_in_flight);
    try testing.expect(viewer.command_queue.empty());

    // setClientSize should queue a client_size command.
    viewer.setClientSize(132, 43);
    try testing.expectEqual(@as(size.CellCountInt, 132), viewer.client_cols);
    try testing.expectEqual(@as(size.CellCountInt, 43), viewer.client_rows);
    try testing.expect(!viewer.command_queue.empty());

    // Next notification should trigger sending the queued command.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "x" } } },
            .contains_command = "refresh-client -C 132x43",
        },
        // Response to the refresh-client command
        .{ .input = .{ .tmux = blockEnd("") } },
    });

    // Queue should be empty again, no command in flight.
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

test "takePendingCommand flushes an idle-queued resize and keeps FIFO order" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain the capture-pane sequence + pane_state + subscribe_titles.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
    });

    // Idle command_queue: nothing to flush yet.
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(!viewer.command_in_flight);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try testing.expect((try viewer.takePendingCommand(arena.allocator())) == null);
    }

    // A resize queues a client_size command. takePendingCommand should now
    // format + return it and mark it in flight (this is the idle-session flush
    // that the pull-based pump would otherwise miss).
    viewer.setClientSize(132, 43);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expectEqualStrings("refresh-client -C 132x43\n", cmd);
        try testing.expect(viewer.command_in_flight);

        // A second resize before the first response must NOT be flushed early:
        // it waits behind the in-flight command so the response FIFO stays in
        // order.
        viewer.setClientSize(100, 50);
        try testing.expect((try viewer.takePendingCommand(arena.allocator())) == null);
    }

    // The first command's response sends the second in order via the pull pump.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "refresh-client -C 100x50",
        },
        .{ .input = .{ .tmux = blockEnd("") } },
    });
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

// ROOTSHELL-TMUX (id=viewer-sent-fifo): drive a fresh viewer to a steady
// command_queue state with exactly one window, leaving the queue empty and
// nothing in flight. The sent-FIFO is intentionally left empty (these helpers
// drive `next` directly, mirroring how the real flow has consumed every startup
// marker by steady state), so a test can then drive its own record/classify
// sequence with full control.
fn driveStartupOneWindow(viewer: *Viewer) !void {
    try testViewer(viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_tags = &.{ .windows, .command },
        },
    });
    // Drain the capture-pane sequence + pane_state + title subscription until
    // the queue is fully idle, regardless of the exact command count.
    var guard: usize = 0;
    while (!viewer.command_queue.empty() or viewer.command_in_flight) {
        _ = viewer.next(.{ .tmux = blockEnd("") });
        guard += 1;
        if (guard > 50) return error.TestDrainStuck;
    }
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
}

fn driveStartupTwoWindows(viewer: *Viewer) !void {
    try testViewer(viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
                \\$0 @1 0 1 0 %1 80 24 b25e,80x24,0,0,1 codex
            ) },
            .contains_tags = &.{ .windows, .command },
        },
    });
    var guard: usize = 0;
    while (!viewer.command_queue.empty() or viewer.command_in_flight) {
        _ = viewer.next(.{ .tmux = blockEnd("") });
        guard += 1;
        if (guard > 30) return error.TestDrainStuck;
    }
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expectEqual(@as(usize, 2), viewer.windows.items.len);
    try testing.expectEqual(@as(usize, 2), viewer.panes.count());
}

fn acknowledgeClientSize(
    viewer: *Viewer,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    viewer.setClientSize(cols, rows);
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try viewer.takePendingCommand(arena.allocator())).?;
    _ = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expectEqual(cols, viewer.last_applied_client_size.?.cols);
    try testing.expectEqual(rows, viewer.last_applied_client_size.?.rows);
}

fn firstCommandAction(actions: []const Viewer.Action) ?[]const u8 {
    for (actions) |action| {
        if (action == .command) return action.command;
    }
    return null;
}

test "pane_state leaves focus_event unchanged when tmux omits focus_flag" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    const t: *Terminal = &pane.terminal;
    t.modes.set(.focus_event, true);

    try viewer.receivedPaneState(
        \\%0;10;2;0;;0;1;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;0;0;23;8,16
    ,
        null,
    );
    try testing.expect(t.modes.get(.focus_event));

    try viewer.receivedPaneState(
        \\%0;10;2;0;;0;1;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;23;8,16
    ,
        null,
    );
    try testing.expect(!t.modes.get(.focus_event));
}

test "pane history retry cap survives capture-pending pane_state acquires" {
    // Regression for a livelock where a timed-out pane_history set
    // capture_pending, then an interleaved pane_state acquired the pane lock
    // and reset capture_retries without applying capture content. With the
    // counter reset defeated, repeated history lock timeouts reach the cap,
    // drop the stale capture, and the trailing pane_state initializes the pane.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    _ = viewer.next(.{ .tmux = blockEnd("") });
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } });
    _ = viewer.next(.{ .tmux = blockEnd("") });
    _ = viewer.next(.{ .tmux = blockEnd("3.5a") });
    var actions = viewer.next(.{ .tmux = blockEnd(
        \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
    ) });
    var panes_it = viewer.panes.iterator();
    while (panes_it.next()) |kv| kv.value_ptr.*.clearPendingAttach();

    const pane = viewer.panes.get(0).?;
    try testing.expect(!pane.initialized);

    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    const wake_fn = struct {
        fn wake(_: ?*anyopaque) void {}
    }.wake;
    const osc_post_fn = struct {
        fn post(_: ?*anyopaque, _: Viewer.PaneOscEvent) void {}
    }.post;
    pane.attachRenderer(&render_mutex, &dummy_ctx, wake_fn, &dummy_ctx, osc_post_fn);
    defer pane.detachRenderer();

    var current_command = firstCommandAction(actions) orelse return error.MissingCommand;
    var history_timeouts: usize = 0;
    var guard: usize = 0;
    while ((!viewer.command_queue.empty() or viewer.command_in_flight) and guard < 80) : (guard += 1) {
        const is_history =
            std.mem.containsAtLeast(u8, current_command, 1, "capture-pane") and
            std.mem.containsAtLeast(u8, current_command, 1, "-S -10000");
        const is_state = std.mem.startsWith(u8, current_command, "list-panes -s");

        if (is_history) {
            render_mutex.lockUncancelable(testing.io);
            history_timeouts += 1;
        }
        actions = viewer.next(.{ .tmux = blockEnd(if (is_state)
            \\%0;10;2;0;;0;1;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;23;8,16
        else if (is_history)
            "HISTORY"
        else
            "VISIBLE") });
        if (is_history) render_mutex.unlock(testing.io);

        current_command = firstCommandAction(actions) orelse "";
        if (current_command.len == 0 and viewer.command_in_flight) {
            return error.MissingCommand;
        }
    }

    try testing.expect(guard < 80);
    try testing.expect(history_timeouts >= PANE_CAPTURE_RETRY_MAX + 1);
    try testing.expect(pane.initialized);
    try testing.expect(!pane.capture_pending);
    try testing.expectEqual(@as(u8, 0), pane.capture_retries);
    try testing.expect(pane.captured_visible_primary == null);
    try testing.expect(pane.captured_visible_alternate == null);
}

test "untracked send-keys ack is swallowed, not matched to a tracked command" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // Reproduce the tab-switch ordering: a focus-report send-keys is written
    // first (untracked), THEN a tracked command is sent and goes in flight. tmux
    // acks in write order: [send-keys block, tracked block].
    viewer.recordUntrackedSends(1);
    try viewer.queueUserCommand("select-window -t @0\n");
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expect(std.mem.startsWith(u8, cmd, "select-window"));
    }
    viewer.recordTrackedSend();
    try testing.expect(viewer.command_in_flight);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());

    // Block 1 = the send-keys ack. It MUST classify as untracked and be
    // swallowed by the caller — the tracked command stays in flight and queued,
    // NOT falsely consumed.
    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    try testing.expect(viewer.command_in_flight);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());

    // Block 2 = the real tracked ack. Classified tracked → fed to next, which
    // consumes the queued command.
    try testing.expectEqual(Viewer.BlockClass.tracked, viewer.classifyBlock());
    _ = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(!viewer.command_in_flight);
    try testing.expect(viewer.command_queue.empty());

    // The swallowed block never corrupted the window list.
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
}

test "server-originated block does not consume command in flight" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserCommand("display-message -p '#{version}'\n");
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expect(std.mem.startsWith(u8, cmd, "display-message"));
    }
    try testing.expect(viewer.command_in_flight);

    const actions = viewer.next(.{ .tmux = serverBlockEnd("hook output") });
    try testing.expectEqual(@as(usize, 0), actions.len);
    try testing.expect(viewer.command_in_flight);
}

test "unexpected client-originated block requests recovery" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);
    try testing.expect(!viewer.command_in_flight);

    const actions = viewer.next(.{ .tmux = blockEnd("orphan response") });
    try testing.expectEqual(@as(usize, 1), actions.len);
    try testing.expect(actions[0] == .recover);
    try testing.expectEqual(control.ErrorCode.unexpected_block, viewer.last_error);
}

test "window list survives a send-keys block landing before list-windows" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // A focus-report send-keys is written (untracked); then a topology change
    // queues + sends a tracked list-windows. tmux acks send-keys first.
    viewer.recordUntrackedSends(1);
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 1 } } });
    try testing.expect(viewer.command_in_flight); // list-windows in flight
    viewer.recordTrackedSend();

    // Block 1 = send-keys ack → swallowed (NOT fed to next). Block 2 = the real
    // list-windows response → fed to next. WITHOUT the swallow, the empty
    // send-keys ack would be parsed as the list-windows response → zero windows →
    // empty topology snapshot → every tmux tab pruned. WITH it, the real window
    // survives.
    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    try testing.expectEqual(Viewer.BlockClass.tracked, viewer.classifyBlock());
    const actions = viewer.next(.{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") });
    var found_windows = false;
    for (actions) |a| {
        if (a == .windows) {
            found_windows = true;
            try testing.expectEqual(@as(usize, 1), a.windows.len);
        }
    }
    try testing.expect(found_windows);
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
}

test "topology cap drops excess windows from list-windows" {
    // A hostile server listing thousands of windows must not materialize a
    // Terminal per pane past the caps. ROOTSHELL-TMUX (id=viewer-topology-caps)
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // A topology change queues + sends a tracked list-windows.
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 1 } } });
    try testing.expect(viewer.command_in_flight);
    viewer.recordTrackedSend();

    // Build a response listing more windows than MAX_WINDOWS; each is a
    // single-pane 2x2 layout with a freshly computed checksum.
    const Checksum = @import("layout.zig").Checksum;
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    for (0..MAX_WINDOWS + 10) |i| {
        var layout_buf: [64]u8 = undefined;
        const layout = try std.fmt.bufPrint(&layout_buf, "2x2,0,0,{d}", .{i});
        const checksum_str = Checksum.calculate(layout).asString();
        try body.writer.print(
            "$0 @{d} {d} {d} 0 %{d} 2 2 {s},{s} w{d}\n",
            .{ i, @intFromBool(i == 0), i, i, checksum_str, layout, i },
        );
    }

    try testing.expectEqual(Viewer.BlockClass.tracked, viewer.classifyBlock());
    _ = viewer.next(.{ .tmux = blockEnd(body.writer.buffered()) });
    // No child surfaces in this test: clear the en-route flag like the
    // TestStep harness does, or deinit orphans every new pane (= test leak).
    {
        var it = viewer.panes.iterator();
        while (it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
    }

    // Only the first MAX_WINDOWS windows survive; the excess is dropped.
    try testing.expectEqual(@as(usize, MAX_WINDOWS), viewer.windows.items.len);
}

test "paste produces multiple untracked markers, all swallowed" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // A paste batches multiple send-keys command lines into one write; the
    // drain point records one marker per line in a single bulk call.
    viewer.recordUntrackedSends(3);
    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    // Command queue / in-flight / windows are untouched.
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
}

test "bulk untracked markers interleave correctly with a tracked command" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // A batched paste (2 command lines) is written, then a tracked command
    // goes in flight. tmux acks in write order.
    viewer.recordUntrackedSends(2);
    try viewer.queueUserCommand("select-window -t @0\n");
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = (try viewer.takePendingCommand(arena.allocator())).?;
    }
    viewer.recordTrackedSend();

    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    try testing.expectEqual(Viewer.BlockClass.untracked, viewer.classifyBlock());
    try testing.expectEqual(Viewer.BlockClass.tracked, viewer.classifyBlock());
    try testing.expectEqual(Viewer.BlockClass.empty, viewer.classifyBlock());
}

test "recordUntrackedSends zero is a no-op" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    viewer.recordUntrackedSends(0);
    try testing.expectEqual(Viewer.BlockClass.empty, viewer.classifyBlock());
}

test "classifyBlock on empty FIFO returns empty and startup still completes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    // Empty FIFO (the startup attach block we never wrote) classifies as empty,
    // so the caller falls through to the normal handling.
    try testing.expectEqual(Viewer.BlockClass.empty, viewer.classifyBlock());
    try driveStartupOneWindow(&viewer);
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
}

test "resync drops stale stream then rebuilds on probe marker" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 100, 40);
    defer viewer.deinit();

    // tmuxResume creates a fresh viewer in .startup then flips it to .resync.
    viewer.enterResync();
    try testing.expectEqual(.resync, viewer.state);

    // Buffered pre-reattach noise is dropped: a stale command block (e.g. a
    // capture-pane response in flight at relaunch) and stale %output produce no
    // actions and leave us in .resync. Critically, the stale block is NOT fed to
    // receivedCommandOutput (which would desync the rebuild FIFO).
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .tmux = blockEnd("stale capture output\nmore lines") }).len);
    try testing.expectEqual(.resync, viewer.state);
    try testing.expectEqual(@as(usize, 0), viewer.next(.{ .tmux = .{
        .output = .{ .pane_id = 0, .data = "junk" },
    } }).len);
    try testing.expectEqual(.resync, viewer.state);

    // The probe response (marker + session id) proves the stream is clean: we
    // parse the session id, move to command_queue, and emit the rebuild's first
    // command (client_size as refresh-client -C).
    {
        const actions = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $7") });
        var found = false;
        for (actions) |a| {
            if (a == .command and std.mem.startsWith(u8, a.command, "refresh-client -C")) {
                found = true;
            }
        }
        try testing.expect(found);
    }
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expectEqual(@as(usize, 7), viewer.session_id);

    // The rebuild then drives the normal version/list-windows flow. Feed the
    // version + a single-window list-windows and confirm the topology rebuilds.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$7 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_tags = &.{ .windows, .command },
        },
    });
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
}

test "cold prioritized resume recovers the restored selected window first" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 100, 40);
    defer viewer.deinit();

    viewer.colors.foreground.default = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    viewer.colors.background.default = .{ .r = 0x44, .g = 0x55, .b = 0x66 };
    viewer.enterResyncPrioritized(1);
    try testing.expect(viewer.recovery_new_panes_incrementally);

    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $7") });
    var actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.startsWith(
        u8,
        firstCommandAction(actions).?,
        "display-message",
    ));
    actions = viewer.next(.{ .tmux = blockEnd("3.5a") });
    try testing.expect(std.mem.startsWith(
        u8,
        firstCommandAction(actions).?,
        "list-windows",
    ));
    try testing.expect(viewer.recovery_new_panes_incrementally);
    actions = viewer.next(.{ .tmux = blockEnd(
        \\$7 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
        \\$7 @1 0 1 0 %1 80 24 b25e,80x24,0,0,1 codex
    ) });
    // Cold reconstruction reports only the priority pane's colors first; it
    // must not enqueue color round trips for every background window ahead of
    // the selected capture.
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "\"%1:") != null);
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "\\033]10;") != null);
    try testing.expectEqual(@as(usize, 2), viewer.recovery_jobs.items.len);
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());
    try testing.expect(viewer.recovery_queued == null);
    var found_focus = false;
    for (actions) |action| {
        if (action == .focus) {
            // tmux reports @0 active, but the restored app selection is @1.
            // The initial controller focus must not navigate away from the
            // prioritized pane before it has recovered.
            try testing.expectEqual(@as(usize, 1), action.focus.window_id);
            try testing.expectEqual(@as(usize, 1), action.focus.pane_id);
            found_focus = true;
        }
    }
    try testing.expect(found_focus);

    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "\"%1:") != null);
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "\\033]11;") != null);
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.startsWith(u8, firstCommandAction(actions).?, "capture-pane"));
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "-t %1") != null);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
    try testing.expectEqual(@as(usize, 1), viewer.recovery_queued.?.window_id);
    try testing.expectEqual(@as(usize, 1), viewer.recovery_queued.?.pane_id.?);
    try testing.expect(viewer.panes.get(0).?.recovery_pending);
    try testing.expect(viewer.panes.get(1).?.recovery_pending);
    // Model the app consuming the topology and either attaching or declining
    // each child surface before the viewer is destroyed.
    var panes_it = viewer.panes.iterator();
    while (panes_it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
}

test "parseResyncSessionId parses $<id>, rejects malformed" {
    try testing.expectEqual(@as(?usize, 7), Viewer.parseResyncSessionId(" $7"));
    try testing.expectEqual(@as(?usize, 12), Viewer.parseResyncSessionId(" $12\n"));
    try testing.expectEqual(@as(?usize, null), Viewer.parseResyncSessionId(" 7"));
    try testing.expectEqual(@as(?usize, null), Viewer.parseResyncSessionId(" $"));
    try testing.expectEqual(@as(?usize, null), Viewer.parseResyncSessionId(""));
}

test "session change resets the sent-FIFO" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // Outstanding markers at the moment a session change rebuilds the viewer.
    viewer.recordUntrackedSends(1);
    viewer.recordTrackedSend();

    // sessionChanged deinits the old viewer (freeing the old FIFO) and starts a
    // fresh one — no carry-forward (a stale tracked marker could mis-match a new
    // in-flight command). The fresh FIFO is empty.
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{ .id = 2, .name = "two" } } });
    try testing.expectEqual(Viewer.BlockClass.empty, viewer.classifyBlock());
}

test "parseResizePane parses target/cols/rows, rejects others" {
    const rp = Viewer.parseResizePane("resize-pane -t %7 -x 120 -y 40\n").?;
    try testing.expectEqual(@as(usize, 7), rp.pane_id);
    try testing.expectEqual(@as(size.CellCountInt, 120), rp.cols);
    try testing.expectEqual(@as(size.CellCountInt, 40), rp.rows);

    // Not a resize-pane.
    try testing.expect(Viewer.parseResizePane("select-pane -t %7\n") == null);
    try testing.expect(Viewer.parseResizePane("select-window -t @1\n") == null);
    // Missing a dimension.
    try testing.expect(Viewer.parseResizePane("resize-pane -t %7 -x 120\n") == null);
    // Target without the % sigil.
    try testing.expect(Viewer.parseResizePane("resize-pane -t 7 -x 1 -y 1\n") == null);
}

test "queueRelayedPaneCommand rewrites a single-pane resize to client_size" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    // Standard startup leaving a single-pane window @0 with pane %0.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
    });
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(viewer.windowIsSinglePane(0));

    // A pane resize for the sole pane is rewritten to `refresh-client -C`.
    try viewer.queueRelayedPaneCommand("resize-pane -t %0 -x 120 -y 40\n");
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
    try testing.expectEqualStrings("refresh-client -C 120x40\n", cmd);
}

test "takePendingCommand returns null during startup" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    // In startup state setClientSize only stores dims; nothing is queued, so
    // there is nothing to flush (tryFinishStartup sends the stored size).
    try testing.expectEqual(.startup, viewer.state);
    viewer.setClientSize(100, 50);

    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try viewer.takePendingCommand(arena.allocator())) == null);
}

test "setClientSize stores dimensions but does not queue during startup" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    // Viewer is in startup state
    try testing.expectEqual(.startup, viewer.state);
    viewer.setClientSize(100, 50);
    try testing.expectEqual(@as(size.CellCountInt, 100), viewer.client_cols);
    try testing.expectEqual(@as(size.CellCountInt, 50), viewer.client_rows);

    // Queue should still be empty (no command queued during startup)
    try testing.expect(viewer.command_queue.empty());
}

test "setClientSize ignores below-floor dimensions" {
    // ROOTSHELL-TMUX (id=tmux-size-floor): a transient tiny size (an apprt
    // mid-teardown layout pass through the sole-pane resize-pane rewrite)
    // must neither be stored (a resync would re-send it) nor queued — the
    // control client size clamps the server window DOWN for every attached
    // client and a 1x1 sticks until explicitly corrected.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    viewer.setClientSize(100, 50);
    viewer.setClientSize(1, 1); // below both floors
    try testing.expectEqual(@as(size.CellCountInt, 100), viewer.client_cols);
    try testing.expectEqual(@as(size.CellCountInt, 50), viewer.client_rows);

    viewer.setClientSize(Viewer.min_client_cols - 1, 50); // cols below floor
    try testing.expectEqual(@as(size.CellCountInt, 100), viewer.client_cols);
    viewer.setClientSize(100, Viewer.min_client_rows - 1); // rows below floor
    try testing.expectEqual(@as(size.CellCountInt, 50), viewer.client_rows);

    // At the floor is accepted.
    viewer.setClientSize(Viewer.min_client_cols, Viewer.min_client_rows);
    try testing.expectEqual(Viewer.min_client_cols, viewer.client_cols);
    try testing.expectEqual(Viewer.min_client_rows, viewer.client_rows);
}

test "setClientSize coalesces a queued-but-unsent client_size" {
    // ROOTSHELL-TMUX (id=viewer-coalesce-client-size): rapid resizes must
    // not pile up one stale size per step — the pending command is updated
    // in place and the pump sends only the newest size.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    viewer.setClientSize(100, 40);
    viewer.setClientSize(132, 43);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "x" } } },
            .contains_command = "refresh-client -C 132x43",
        },
        .{ .input = .{ .tmux = blockEnd("") } },
    });
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

test "setClientSize does not mutate the in-flight client_size head" {
    // ROOTSHELL-TMUX (id=viewer-coalesce-client-size): once a command's bytes
    // are written, the response FIFO depends on it staying put; later resizes
    // queue behind it (and coalesce with each other).
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    viewer.setClientSize(100, 40);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expectEqualStrings("refresh-client -C 100x40\n", cmd);
    }

    // The first resize appends behind the in-flight head; the second
    // coalesces into that pending entry.
    viewer.setClientSize(120, 42);
    viewer.setClientSize(132, 43);
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());

    // The in-flight response pumps the pending (newest) size.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "refresh-client -C 132x43",
        },
        .{ .input = .{ .tmux = blockEnd("") } },
    });
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

test "setClientSize coalescing preserves enable_pause" {
    // ROOTSHELL-TMUX (id=viewer-coalesce-client-size): the resync rebuild
    // queues its client_size with the pause-after re-enable; coalescing a
    // later resize into it must update dims only, never strip the flag.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueCommands(&.{.{ .client_size = .{
        .cols = 80,
        .rows = 24,
        .enable_pause = true,
    } }});
    viewer.setClientSize(132, 43);

    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
    const entry = viewer.command_queue.first().?;
    try testing.expectEqual(@as(size.CellCountInt, 132), entry.client_size.cols);
    try testing.expectEqual(@as(size.CellCountInt, 43), entry.client_size.rows);
    try testing.expect(entry.client_size.enable_pause);
}

test "queueUserCommand coalesces a per-window size refresh" {
    // ROOTSHELL-TMUX (id=viewer-coalesce-window-refresh): per-window
    // `refresh-client -C @id:WxH` pushes coalesce per window; everything
    // else still appends.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserCommand("refresh-client -C @1:80x24\n");
    try viewer.queueUserCommand("refresh-client -C @1:100x40\n");
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());

    // A different window does NOT coalesce.
    try viewer.queueUserCommand("refresh-client -C @2:80x24\n");
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());

    // Non-size commands never match (even repeated).
    try viewer.queueUserCommand("select-pane -t %0\n");
    try viewer.queueUserCommand("select-pane -t %0\n");
    try testing.expectEqual(@as(usize, 4), viewer.command_queue.len());

    // The @1 entry holds the NEWEST bytes.
    const head = viewer.command_queue.first().?;
    try testing.expectEqualStrings("refresh-client -C @1:100x40\n", head.user);
}

test "queueUserCommand does not coalesce into the in-flight head" {
    // ROOTSHELL-TMUX (id=viewer-coalesce-window-refresh)
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserCommand("refresh-client -C @1:80x24\n");
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expectEqualStrings("refresh-client -C @1:80x24\n", cmd);
    }

    // Queued behind the in-flight head...
    try viewer.queueUserCommand("refresh-client -C @1:100x40\n");
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());
    // ...and a third coalesces into the PENDING entry, not the head.
    try viewer.queueUserCommand("refresh-client -C @1:120x50\n");
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());

    // The in-flight response pumps the pending (newest) bytes.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "refresh-client -C @1:120x50",
        },
        .{ .input = .{ .tmux = blockEnd("") } },
    });
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(!viewer.command_in_flight);
}

test "startup enables pause-after but sends NO client size" {
    // ROOTSHELL-TMUX (id=viewer-startup-pause-only): the first startup command
    // must enable pause-after WITHOUT a `-C` size, so tmux keeps each window at
    // the size it was left at on detach instead of reflowing every app to our
    // grid on attach. The init dims (132x43) must NOT leak into a startup size.
    var viewer = try Viewer.init(testing.io, testing.allocator, 132, 43);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
            .check_command = (struct {
                fn check(_: *Viewer, cmd: []const u8) anyerror!void {
                    // Pause-after only, no `-C`, no dimensions.
                    try testing.expectEqualStrings(
                        "refresh-client -f pause-after=200\n",
                        cmd,
                    );
                }
            }).check,
        },
        // Pause-after response triggers the version query (display-message).
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "post-startup app resize sends a sized refresh-client -C" {
    // After the sizeless startup, the app's first layout reports the real
    // viewport; that MUST go out as a sized `refresh-client -C`, which is what
    // actually drives tmux to (re)size the windows. ROOTSHELL-TMUX
    // (id=viewer-startup-pause-only)
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    viewer.setClientSize(150, 40);
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "x" } } },
            .contains_command = "refresh-client -C 150x40",
        },
        .{ .input = .{ .tmux = blockEnd("") } },
    });
}

test "message notification produces message action" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane + pane_state
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Send a %message notification
        .{
            .input = .{ .tmux = .{ .message = .{
                .text = "Session created session 1",
            } } },
            .contains_tags = &.{.message},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .message) {
                            try testing.expectEqualStrings(
                                "Session created session 1",
                                action.message.text,
                            );
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .exit },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = blockEnd(
                \\$1 @0 1 0 0 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = blockEnd(
                \\$2 @1 1 1 0 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // .windows must be emitted before .command so that
                    // the surface layer sees topology before outgoing
                    // commands trigger further protocol traffic.
                    var windows_idx: ?usize = null;
                    var command_idx: ?usize = null;
                    for (actions, 0..) |action, i| {
                        if (windows_idx == null and action == .windows) windows_idx = i;
                        if (command_idx == null and action == .command) command_idx = i;
                    }
                    try testing.expect(windows_idx != null);
                    try testing.expect(command_idx != null);
                    try testing.expect(windows_idx.? < command_idx.?);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\Hello, world!
            ) },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // Completes pane_visible(1, alternate), triggers pane_state
            .contains_command = "list-panes",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            // pane_state response completes initialization
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // All panes should now be marked as initialized
                    var it = v.panes.iterator();
                    while (it.next()) |kv| {
                        try testing.expect(kv.value_ptr.*.initialized);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No output action forwarded — the viewer's pane terminal
                    // is now authoritative (single-terminal architecture).
                    try testing.expectEqual(0, actions.len);
                    // Viewer processes output into its own pane terminal.
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Output for untracked pane is silently dropped.
                    // No action produced.
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "startup session before block" {
    // Verify that %session-changed arriving before %begin/%end
    // still completes startup correctly.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Session arrives first (reversed order from normal)
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 7,
                .name = "reversed",
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session info should be stored
                    try testing.expectEqual(7, v.session_id);
                    // But we haven't finished startup yet (no block)
                    try testing.expect(v.state == .startup);
                    // No commands should be emitted yet
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Block arrives second — this should complete startup
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should now be in command_queue state
                    try testing.expect(v.state == .command_queue);
                    try testing.expectEqual(7, v.session_id);
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate),
        // pane_state, and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4 capture-pane + 1 pane_state)
                    try testing.expectEqual(5, v.command_queue.len());
                    // Pane 0 was 83x44 before the split. After the
                    // layout change it should be resized to 83x22.
                    const pane0 = v.panes.get(0).?;
                    try testing.expectEqual(83, pane0.terminal.cols);
                    try testing.expectEqual(22, pane0.terminal.rows);
                    // Pane 2 is new — created at 83x21.
                    const pane2 = v.panes.get(2).?;
                    try testing.expectEqual(83, pane2.terminal.cols);
                    try testing.expectEqual(21, pane2.terminal.rows);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "updateColors refreshes existing pane terminal colors live" {
    // A theme change (config reload) must update the colors of panes that
    // ALREADY exist, not just future panes. Before the fix this only updated
    // `self.colors` (consumed at pane creation), so live panes stayed stale
    // until a detach/reattach rebuilt them. ROOTSHELL-TMUX
    // (id=viewer-update-existing-pane-colors)
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup handshake through the first window layout with one pane.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const new_fg: color.RGB = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
                    const new_bg: color.RGB = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc };
                    const new_cursor: color.RGB = .{ .r = 0x77, .g = 0x88, .b = 0x99 };
                    const accent: color.RGB = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
                    try testing.expectEqual(1, v.panes.count());
                    const pane0 = v.panes.get(0).?;
                    // Build a themed palette by tweaking one default entry so we
                    // can prove the palette propagates through changeDefault.
                    var new_palette = pane0.terminal.colors.palette.original;
                    new_palette[5] = accent;
                    v.updateColors(new_fg, new_bg, new_cursor, new_palette);
                    // The existing pane terminal (what the child renderer reads)
                    // picked up the full new theme live (bg/fg/cursor/palette).
                    try testing.expectEqual(new_fg, pane0.terminal.colors.foreground.default.?);
                    try testing.expectEqual(new_bg, pane0.terminal.colors.background.default.?);
                    try testing.expectEqual(new_cursor, pane0.terminal.colors.cursor.default.?);
                    try testing.expectEqual(accent, pane0.terminal.colors.palette.current[5]);
                    // And it was marked dirty so the next frame fully rebuilds.
                    try testing.expect(pane0.terminal.flags.dirty.palette);
                    // Future panes inherit the same colors via self.colors.
                    try testing.expectEqual(new_fg, v.colors.foreground.default.?);
                    try testing.expectEqual(new_bg, v.colors.background.default.?);
                    try testing.expectEqual(new_cursor, v.colors.cursor.default.?);
                    try testing.expectEqual(accent, v.colors.palette.current[5]);
                }
            }).check,
        },
        .{ .input = .{ .tmux = .exit }, .contains_tags = &.{.exit} },
    });
}

test "layout change resizes existing pane without structural change" {
    // When a tmux window is resized (e.g. the terminal emulator is
    // resized), tmux sends a %layout-change with the same pane
    // structure but different dimensions. The viewer must resize the
    // pane's shadow terminal to match.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Initial window: single pane at 83x44
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane0 = v.panes.get(0).?;
                    try testing.expectEqual(83, pane0.terminal.cols);
                    try testing.expectEqual(44, pane0.terminal.rows);
                }
            }).check,
        },
        // Complete capture-pane commands for pane 0, pane_state, and the
        // trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Window resized to 120x50 — same pane, different dimensions
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "acfd,120x50,0,0,0",
                .visible_layout = "acfd,120x50,0,0,0",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still one pane, no new captures queued
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.command_queue.empty());
                    // Terminal dimensions must match the new layout
                    const pane0 = v.panes.get(0).?;
                    try testing.expectEqual(120, pane0.terminal.cols);
                    try testing.expectEqual(50, pane0.terminal.rows);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes.
        // This should NOT return a command action since queue was not empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // Should not contain a command action
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, pane_state, and the
        // trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "session_window_changed queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send session_window_changed - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{ .session_id = 1, .window_id = 2 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "session_window_changed queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send session_window_changed - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{ .session_id = 1, .window_id = 2 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_close queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_close - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_close queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_close - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "refreshWindowList coalesces duplicate list_windows" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Send window_add — queues list_windows
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Send window_close — should NOT add another list_windows (coalesced)
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still exactly 1 list_windows in the queue (coalesced)
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Send session_window_changed — should also be coalesced
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 1,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still exactly 1 list_windows in the queue (coalesced)
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = blockEnd("") } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4] bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = blockEnd(
                \\prompt %
                \\prompt %
            ) },
        },
        // capture-pane pane 0 primary visible
        .{
            .input = .{ .tmux = blockEnd(
                \\prompt %
            ) },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // ROOTSHELL-TMUX (id=alt-screen-fix): the visible capture is
                        // now STASHED, not replayed here — it is applied to the
                        // correct screen by the trailing pane_state once alternate_on
                        // is known. So the active area is still empty at this point.
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = blockEnd(
                \\prompt %
            ) },
        },
        // capture-pane pane 4 primary visible
        .{
            .input = .{ .tmux = blockEnd(
                \\prompt %
            ) },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // ROOTSHELL-TMUX (id=alt-screen-fix): the visible capture is
                        // now STASHED, not replayed here — applied by the trailing
                        // pane_state. So the active area is still empty at this point.
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 4 alternate history (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane pane 4 alternate visible (empty). Completing the
        // capture sequence emits the trailing pane_state command, which MUST
        // be session-scoped (`list-panes -s -t $<id>`) so tmux returns panes
        // for every window in the session, not just the current window —
        // otherwise non-active windows' panes never get switched back to
        // their real screen and stay stranded blank (ROOTSHELL-TMUX). The
        // `$0` confirms the session id was threaded into the command.
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "list-panes -s -t $0",
        },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = blockEnd(
                \\%0;42;0;1;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
            ) },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        // The deferred primary visible is applied to the active
                        // primary screen once pane_state lands (alternate_on=0).
                        // ROOTSHELL-TMUX (id=alt-screen-fix)
                        try testing.expectEqual(ScreenSet.Key.primary, t.screens.active_key);
                        const vis = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(vis);
                        try testing.expectEqualStrings("prompt %", vis);
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        // The deferred primary visible is applied to the active
                        // primary screen once pane_state lands (alternate_on=0).
                        // ROOTSHELL-TMUX (id=alt-screen-fix)
                        try testing.expectEqual(ScreenSet.Key.primary, t.screens.active_key);
                        const vis = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(vis);
                        try testing.expectEqualStrings("prompt %", vis);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change preserves other windows on shared arena" {
    // Validates that the shared windows_arena correctly preserves
    // layout data AND window names for unchanged windows when layoutChanged
    // rebuilds. Names live on the same arena as layouts, so the reset in
    // layoutChanged invalidates them too unless they're carried across.
    // ROOTSHELL-TMUX (id=layout-change-preserve-window-name)
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    // Static storage for the pre-reset name pointers. Comparing CONTENTS alone
    // can't fail reliably: a dangling slice keeps pointing into the arena's
    // retained pages, and whether the reused bytes actually land on the old
    // name depends on allocation alignment (in this two-window fixture the
    // 8-aligned Layout allocations happen to skip the byte-aligned names).
    // The invariant we actually need is that each name was RE-HOMED onto the
    // fresh arena, which the pointer check tests directly and deterministically.
    const Captured = struct {
        var ptr0: usize = 0;
        var ptr1: usize = 0;
    };
    Captured.ptr0 = 0;
    Captured.ptr1 = 0;

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Two windows: @0 with pane 0, @1 with pane 1
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
                \\$0 @1 0 1 0 %1 80 24 b25e,80x24,0,0,1 vim
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.windows.items.len);
                    try testing.expectEqual(0, v.windows.items[0].id);
                    try testing.expectEqual(1, v.windows.items[1].id);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("bash", v.windows.items[0].name);
                    try testing.expectEqualStrings("vim", v.windows.items[1].name);
                    Captured.ptr0 = @intFromPtr(v.windows.items[0].name.ptr);
                    Captured.ptr1 = @intFromPtr(v.windows.items[1].name.ptr);
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 and pane 1
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Now send a layout_change for window @0 that splits it
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 2 windows
                    try testing.expectEqual(2, v.windows.items.len);
                    // Window @0 should now have a vertical split
                    try testing.expect(v.windows.items[0].layout.content == .vertical);
                    // Window @1 should still be a single pane with id 1
                    try testing.expectEqual(1, v.windows.items[1].layout.content.pane);
                    // Pane count should now be 3 (0, 1, 2)
                    try testing.expectEqual(3, v.panes.count());

                    // Both names must survive the arena reset, and must have
                    // been re-homed onto the fresh arena rather than left
                    // pointing at the retained (now reusable) pages. The
                    // pointer check is the load-bearing one; see the comment
                    // at the top of this test.
                    // ROOTSHELL-TMUX (id=layout-change-preserve-window-name)
                    try testing.expectEqualStrings("bash", v.windows.items[0].name);
                    try testing.expectEqualStrings("vim", v.windows.items[1].name);
                    try testing.expect(Captured.ptr0 != 0 and Captured.ptr1 != 0);
                    try testing.expect(
                        @intFromPtr(v.windows.items[0].name.ptr) != Captured.ptr0,
                    );
                    try testing.expect(
                        @intFromPtr(v.windows.items[1].name.ptr) != Captured.ptr1,
                    );

                    // The changed window tracks the size tmux resolved, so the
                    // ensure_window op stops reporting a stale (larger) size
                    // after a foreign client clamps the session.
                    // ROOTSHELL-TMUX (id=layout-change-track-window-size)
                    try testing.expectEqual(83, v.windows.items[0].width);
                    try testing.expectEqual(44, v.windows.items[0].height);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "Action.format preserves normal formatting for command action" {
    // Regression guard: non-output actions should still format
    // their payload contents normally.
    const action: Viewer.Action = .{ .command = "list-windows\n" };

    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try action.format(&builder.writer);
    const result = builder.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, result, "command") != null);
    try testing.expect(std.mem.indexOf(u8, result, "list-windows") != null);
}

test "Action.format handles exit action" {
    const action: Viewer.Action = .exit;

    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try action.format(&builder.writer);
    const result = builder.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, result, "exit") != null);
}

test "window_pane_changed produces focus action" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with two panes
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands (4 per pane × 2 panes = 8),
        // then pane_state and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Send window_pane_changed - should produce .focus action
        .{
            .input = .{ .tmux = .{ .window_pane_changed = .{
                .window_id = 0,
                .pane_id = 1,
            } } },
            .contains_tags = &.{.focus},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 1), v.windows.items[0].active_pane_id);
                    var found = false;
                    for (actions) |action| {
                        if (action == .focus) {
                            try testing.expectEqual(@as(usize, 0), action.focus.window_id);
                            try testing.expectEqual(@as(usize, 1), action.focus.pane_id);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "window_pane_changed for untracked pane refreshes window list" {
    // ROOTSHELL-TMUX (id=viewer-pane-changed-untracked): a
    // %window-pane-changed naming a pane we don't track yet (it raced ahead
    // of the layout refresh) must NOT record the id or emit focus for the
    // ghost pane; it re-queries list-windows instead.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0, then pane_state
        // and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // window_pane_changed for a pane we never tracked: no focus action,
        // active pane untouched, list-windows re-queried.
        .{
            .input = .{ .tmux = .{ .window_pane_changed = .{
                .window_id = 0,
                .pane_id = 99,
            } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 0), v.windows.items[0].active_pane_id);
                    for (actions) |action| try testing.expect(action != .focus);
                }
            }).check,
        },
    });
}

test "forceResync drops buffered pane responses" {
    // ROOTSHELL-TMUX (id=viewer-force-resync-drop-responses): panes survive a
    // live resync, so query replies buffered before the desync must be dropped
    // or they'd flush as stale bytes into the pane app after recovery.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });

    const pane = viewer.panes.get(0).?;
    try pane.responses.append(
        testing.allocator,
        try testing.allocator.dupe(u8, "\x1b[?0u"),
    );

    viewer.forceResync();
    try testing.expect(viewer.isResyncing());
    try testing.expectEqual(@as(usize, 0), pane.responses.items.len);
}

test "forceReset recaptures every pane on the resync rebuild" {
    // ROOTSHELL-TMUX (id=viewer-force-reset): a full reset for a lossy discard
    // re-captures EVERY existing pane (recovering dropped %output) while reusing
    // panes by id (no flicker). syncLayouts honors the per-pane reset_recapture
    // flag and queues capture-pane for the reused pane; the flag is consumed. The
    // reset also re-arms the title subscription so tmux re-pushes current titles.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try driveStartupOneWindow(&viewer);
    try acknowledgeClientSize(&viewer, 80, 24);
    try testing.expect(viewer.panes.contains(0));
    // Startup already issued the title subscription once.
    try testing.expect(viewer.title_subscription_queued);

    viewer.forceReset();
    try testing.expect(viewer.isResyncing());
    try testing.expect(viewer.panes.get(0).?.reset_recapture);
    try testing.expect(!viewer.title_subscription_queued);

    // Probe marker reply → live reset requests topology directly, reusing
    // the already-valid size/version/pause/color metadata.
    const marker_actions = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(marker_actions).?, "list-windows") != null);

    // Same window @0 / pane %0 is reused by id. Only ONE incremental recovery
    // command is queued, and titles remain deferred until this window is ready.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_command = "capture-pane",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.panes.get(0).?.reset_recapture);
                    try testing.expect(v.panes.get(0).?.recovery_pending);
                    try testing.expectEqual(@as(usize, 1), v.command_queue.len());
                    try testing.expect(!v.title_subscription_queued);
                }
            }).check,
        },
    });

    // Four captures + window-scoped state make this window live, then titles
    // are restored. The scheduler leaves no background work for one window.
    var guard: usize = 0;
    while (!viewer.command_queue.empty() or viewer.command_in_flight) {
        _ = viewer.next(.{ .tmux = blockEnd("") });
        guard += 1;
        if (guard > 20) return error.TestDrainStuck;
    }
    try testing.expect(viewer.panes.get(0).?.initialized);
    try testing.expect(!viewer.panes.get(0).?.recovery_pending);
    try testing.expect(viewer.title_subscription_queued);
    try testing.expectEqual(@as(usize, 0), viewer.recovery_jobs.items.len);
}

test "live reset resends a client size newer than the last acknowledgement" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);
    try acknowledgeClientSize(&viewer, 80, 24);

    // Model a rotation/keyboard resize queued immediately before the discard.
    // forceReset drops that unsent command, but retains the newer dimensions.
    viewer.setClientSize(132, 43);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
    try testing.expect(!viewer.command_in_flight);
    viewer.forceReset();
    try testing.expect(viewer.command_queue.empty());

    var actions = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqualStrings(
        "refresh-client -C 132x43 -f pause-after=200\n",
        firstCommandAction(actions).?,
    );

    // The size acknowledgement must precede topology/capture so every pane is
    // rebuilt against tmux's newly resolved geometry.
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "list-windows") != null);
    try testing.expectEqual(@as(size.CellCountInt, 132), viewer.last_applied_client_size.?.cols);
    try testing.expectEqual(@as(size.CellCountInt, 43), viewer.last_applied_client_size.?.rows);
}

test "retry window state completes recovery without another state command" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);

    const pane = viewer.panes.get(1).?;
    pane.initialized = false;
    pane.recovery_pending = true;
    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 1,
        .pane_id = 1,
        .completed = 4,
    });
    viewer.recovery_started = .now(testing.io, .awake);
    try viewer.queueRecoveryCommands(&.{.{ .window_pane_state = 1 }});
    viewer.recovery_queued = .{
        .window_id = 1,
        .pane_id = null,
        .step = 4,
    };
    viewer.command_in_flight = true;

    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    const wake_fn = struct {
        fn wake(_: ?*anyopaque) void {}
    }.wake;
    const osc_post_fn = struct {
        fn post(_: ?*anyopaque, _: Viewer.PaneOscEvent) void {}
    }.post;
    pane.attachRenderer(&render_mutex, &dummy_ctx, wake_fn, &dummy_ctx, osc_post_fn);
    defer pane.detachRenderer();

    const pane_state =
        \\%1;0;0;1;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;23;8,16
    ;

    // Exercise the real pump: the first scoped state times out on the renderer
    // lock and queues two visible retries plus another state command. Clearing
    // recovery_queued for the original completion must not make the scheduler
    // classify that retry suffix as an ordinary interruption and rewind the
    // completed capture boundary.
    render_mutex.lockUncancelable(testing.io);
    var actions = viewer.next(.{ .tmux = blockEnd(pane_state) });
    render_mutex.unlock(testing.io);
    try testing.expectEqual(@as(u3, 4), viewer.recovery_jobs.items[0].completed);
    try testing.expectEqual(@as(usize, 3), viewer.command_queue.len());
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "capture-pane") != null);

    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "capture-pane") != null);
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.startsWith(u8, firstCommandAction(actions).?, "list-panes -t @1 "));
    actions = viewer.next(.{ .tmux = blockEnd(pane_state) });

    try testing.expect(viewer.recovery_jobs.items.len == 0);
    try testing.expect(viewer.recovery_started == null);
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(firstCommandAction(actions) == null);
}

test "recovery color reports do not rewind completed panes in the same window" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    viewer.colors.foreground.default = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    viewer.colors.background.default = .{ .r = 0x44, .g = 0x55, .b = 0x66 };
    try viewer.recovery_jobs.appendSlice(testing.allocator, &.{
        .{ .window_id = 0, .pane_id = 0, .completed = 4 },
        .{ .window_id = 0, .pane_id = 2, .colors_before_capture = true },
    });

    // Pane A is already captured when pane B queues both cold-resume color
    // reports. A second pump while those reports occupy the queue must retain
    // A's completed boundary instead of resetting it to history.
    try viewer.ensureRecoveryCommandQueued();
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());
    try testing.expectEqual(@as(u3, 4), viewer.recovery_jobs.items[0].completed);
    try viewer.ensureRecoveryCommandQueued();
    try testing.expectEqual(@as(u3, 4), viewer.recovery_jobs.items[0].completed);

    var owners = viewer.command_owners.iterator(.forward);
    while (owners.next()) |owner| {
        try testing.expectEqual(Viewer.CommandOwner.recovery, owner.*);
    }
}

test "recovery history lock retry retains scheduler ownership" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    pane.initialized = false;
    pane.recovery_pending = true;
    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 0,
        .pane_id = 0,
    });
    try viewer.queueRecoveryCommands(&.{.{ .pane_history = .{
        .id = 0,
        .screen_key = .primary,
    } }});
    viewer.recovery_queued = .{
        .window_id = 0,
        .pane_id = 0,
        .step = 0,
    };
    viewer.command_in_flight = true;

    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    const wake_fn = struct {
        fn wake(_: ?*anyopaque) void {}
    }.wake;
    const osc_post_fn = struct {
        fn post(_: ?*anyopaque, _: Viewer.PaneOscEvent) void {}
    }.post;
    pane.attachRenderer(&render_mutex, &dummy_ctx, wake_fn, &dummy_ctx, osc_post_fn);
    defer pane.detachRenderer();

    // The scheduler's primary-history result times out on the renderer lock.
    // Its history/visible/state retry suffix must inherit recovery ownership,
    // so the pump preserves step 1 instead of rewinding the job to step 0.
    render_mutex.lockUncancelable(testing.io);
    var actions = viewer.next(.{ .tmux = blockEnd("HISTORY") });
    render_mutex.unlock(testing.io);
    try testing.expectEqual(@as(u3, 1), viewer.recovery_jobs.items[0].completed);
    try testing.expectEqual(@as(usize, 3), viewer.command_queue.len());
    var owners = viewer.command_owners.iterator(.forward);
    while (owners.next()) |owner| {
        try testing.expectEqual(Viewer.CommandOwner.recovery, owner.*);
    }
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "capture-pane") != null);

    // Drain the owned retry suffix. Its session-scoped state intentionally
    // cannot release a recovery pane; after it acks, the scheduler advances
    // directly to the original step 1 visible capture.
    actions = viewer.next(.{ .tmux = blockEnd("HISTORY") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "capture-pane") != null);
    actions = viewer.next(.{ .tmux = blockEnd("VISIBLE") });
    try testing.expect(std.mem.startsWith(u8, firstCommandAction(actions).?, "list-panes -s "));
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expectEqual(@as(u3, 1), viewer.recovery_jobs.items[0].completed);
    try testing.expectEqual(@as(u3, 1), viewer.recovery_queued.?.step);
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "capture-pane") != null);
}

test "incremental pane reports colors before its first recovery capture" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    viewer.colors.foreground.default = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    viewer.colors.background.default = .{ .r = 0x44, .g = 0x55, .b = 0x66 };
    viewer.recovery_new_panes_incrementally = true;

    // Model a split created while another recovery is active. Its color
    // reports must lead the incremental capture sequence, not trail the final
    // pane-state response after an app's query has already gone unanswered.
    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    const split_windows = [_]Viewer.Window{.{
        .id = 0,
        .width = 83,
        .height = 44,
        .layout = try Layout.parse(
            layout_arena.allocator(),
            "83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
        ),
    }};
    try viewer.syncLayouts(&split_windows);
    const pane2 = viewer.panes.get(2).?;
    pane2.clearPendingAttach();

    try testing.expectEqual(@as(usize, 1), viewer.recovery_jobs.items.len);
    try testing.expectEqual(@as(usize, 2), viewer.recovery_jobs.items[0].pane_id);
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());
    try testing.expect(viewer.recovery_queued == null);

    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fg_command = (try viewer.takePendingCommand(arena.allocator())).?;
    try testing.expect(std.mem.indexOf(u8, fg_command, "\\033]10;") != null);
    var actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "\\033]11;") != null);
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "capture-pane") != null);
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "-t %2") != null);
}

test "pane move rewinds partial recovery and invalidates its in-flight capture" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);

    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 0,
        .pane_id = 0,
        .completed = 1,
    });
    viewer.recovery_queued = .{
        .window_id = 0,
        .pane_id = 0,
        .step = 1,
    };

    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    const moved_windows = [_]Viewer.Window{
        .{
            .id = 0,
            .width = 80,
            .height = 24,
            .layout = try Layout.parse(layout_arena.allocator(), "80x24,0,0,1"),
        },
        .{
            .id = 1,
            .width = 80,
            .height = 24,
            .layout = try Layout.parse(layout_arena.allocator(), "80x24,0,0,0"),
        },
    };
    try viewer.syncLayouts(&moved_windows);

    try testing.expectEqual(@as(usize, 1), viewer.recovery_jobs.items[0].window_id);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_jobs.items[0].completed);
    try testing.expect(viewer.recovery_queued.?.preempted);

    // The reply from the old window boundary is drained but not applied or
    // counted. Recovery in @1 must restart at primary history.
    viewer.completeRecoveryCommand(.{ .pane_visible = .{
        .id = 0,
        .screen_key = .primary,
    } });

    try testing.expect(viewer.recovery_queued == null);
    try testing.expectEqual(@as(usize, 1), viewer.recovery_jobs.items[0].window_id);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_jobs.items[0].completed);
    try viewer.ensureRecoveryCommandQueued();
    try testing.expectEqual(@as(usize, 0), viewer.recovery_queued.?.pane_id.?);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_queued.?.step);
}

test "in-flight window state cannot release a newly added recovery pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane0 = viewer.panes.get(0).?;
    pane0.initialized = false;
    pane0.recovery_pending = true;
    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 0,
        .pane_id = 0,
        .completed = 4,
    });
    viewer.recovery_queued = .{
        .window_id = 0,
        .pane_id = null,
        .step = 4,
    };
    viewer.recovery_new_panes_incrementally = true;

    // A split arrives after @0's state command was sent. The new %2 pane is in
    // the response's current layout, but its recovery job has captured nothing.
    var layout_arena: ArenaAllocator = .init(testing.allocator);
    defer layout_arena.deinit();
    const split_windows = [_]Viewer.Window{.{
        .id = 0,
        .width = 83,
        .height = 44,
        .layout = try Layout.parse(
            layout_arena.allocator(),
            "83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
        ),
    }};
    try viewer.syncLayouts(&split_windows);
    const pane2 = viewer.panes.get(2).?;
    pane2.clearPendingAttach();

    try testing.expectEqual(@as(usize, 2), viewer.recovery_jobs.items.len);
    try testing.expect(viewer.paneIncludedInStateCompletion(0, pane0, 0));
    try testing.expect(!viewer.paneIncludedInStateCompletion(2, pane2, 0));

    // Model the old response applying only to %0. %2 must keep the window job
    // alive and become the scheduler's next history capture.
    pane0.initialized = true;
    pane0.recovery_pending = false;
    viewer.completeRecoveryCommand(.{ .window_pane_state = 0 });
    try testing.expect(viewer.recovery_queued == null);
    try testing.expectEqual(@as(usize, 2), viewer.recovery_jobs.items.len);
    try testing.expect(pane2.recovery_pending);
    try testing.expect(!pane2.initialized);

    try viewer.ensureRecoveryCommandQueued();
    try testing.expectEqual(@as(usize, 2), viewer.recovery_queued.?.pane_id.?);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_queued.?.step);
}

test "reprioritizing recovery rewinds a preempted partial pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);

    try viewer.recovery_jobs.appendSlice(testing.allocator, &.{
        .{ .window_id = 0, .pane_id = 0, .completed = 1 },
        .{ .window_id = 1, .pane_id = 1 },
    });
    viewer.recovery_queued = .{
        .window_id = 0,
        .pane_id = 0,
        .step = 1,
    };

    // The visible capture for %0 was already in flight when @1 became active.
    // Its earlier history snapshot cannot be paired with this late reply after
    // @1 recovery, so both pieces are discarded as job progress and %0 must
    // begin again at primary history.
    viewer.prioritizeRecoveryWindow(1);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_jobs.items[0].completed);
    try testing.expect(viewer.recovery_queued.?.preempted);

    viewer.completeRecoveryCommand(.{ .pane_visible = .{
        .id = 0,
        .screen_key = .primary,
    } });
    try testing.expect(viewer.recovery_queued == null);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_jobs.items[0].completed);

    // Once the priority window is gone, the displaced pane restarts with its
    // history command rather than resuming at the stale visible step.
    _ = viewer.recovery_jobs.orderedRemove(1);
    viewer.recovery_priority_window = null;
    try viewer.ensureRecoveryCommandQueued();
    try testing.expectEqual(@as(u3, 0), viewer.recovery_queued.?.step);
    try testing.expectEqual(@as(usize, 0), viewer.recovery_queued.?.pane_id.?);
}

test "ordinary tracked work rewinds an interrupted partial pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);

    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 0,
        .pane_id = 0,
        .completed = 2,
    });
    try viewer.queueRelayedPaneCommand("display-message -p interrupted\n");

    // A user/query/resize/topology command already owns the next command
    // boundary. The pane stays gated during it, so its earlier primary
    // history+visible pair cannot safely be reused afterward.
    try viewer.ensureRecoveryCommandQueued();
    try testing.expect(viewer.recovery_queued == null);
    try testing.expectEqual(@as(u3, 0), viewer.recovery_jobs.items[0].completed);
}

test "continue for a recovering pane does not rewind its partial capture" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    pane.initialized = false;
    pane.recovery_pending = true;
    try viewer.recovery_jobs.append(testing.allocator, .{
        .window_id = 0,
        .pane_id = 0,
        .completed = 2,
    });

    // %pause always needs a continue, but an uninitialized recovery pane does
    // not need a separate pause-recapture batch. The continue is recovery-owned
    // liveness work and must not invalidate the history/visible pair already
    // captured by the scheduler.
    const actions = viewer.next(.{ .tmux = .{ .pause = .{ .pane_id = 0 } } });
    try testing.expectEqual(@as(u3, 2), viewer.recovery_jobs.items[0].completed);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
    try testing.expect(std.mem.startsWith(
        u8,
        firstCommandAction(actions).?,
        "refresh-client -A '%0:continue'",
    ));
}

test "history capture does not expose an intermediate redraw" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    pane.initialized = false;
    const S = struct {
        var wakes: usize = 0;
        fn wake(_: ?*anyopaque) void {
            wakes += 1;
        }
        fn post(_: ?*anyopaque, _: Viewer.PaneOscEvent) void {}
    };
    S.wakes = 0;
    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    pane.attachRenderer(&render_mutex, &dummy_ctx, S.wake, &dummy_ctx, S.post);
    defer pane.detachRenderer();

    try viewer.receivedPaneHistory(.primary, 0, "saved history", .ordinary);
    try testing.expectEqual(@as(usize, 0), S.wakes);

    // Sanity-check the installed callback: only the final state boundary should
    // invoke this in the real capture sequence.
    pane.wake();
    try testing.expectEqual(@as(usize, 1), S.wakes);
}

test "prioritized reset makes the selected window ready before background windows" {
    // ROOTSHELL-TMUX (id=viewer-active-first-recovery): selected-ready latency
    // must not grow with the number/history size of background tabs. Recovery
    // keeps exactly one capture command queued and applies window-scoped state
    // before starting the next window.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);
    try acknowledgeClientSize(&viewer, 80, 24);

    viewer.forceResetPrioritized(1);
    const marker_actions = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(marker_actions).?, "list-windows") != null);

    const topology =
        \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
        \\$0 @1 0 1 0 %1 80 24 b25e,80x24,0,0,1 codex
    ;
    var actions = viewer.next(.{ .tmux = blockEnd(topology) });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "-t %1") != null);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
    try testing.expect(viewer.panes.get(0).?.recovery_pending);
    try testing.expect(viewer.panes.get(1).?.recovery_pending);
    try testing.expect(!viewer.title_subscription_queued);

    // Finish %1's four captures. Every intermediate command stays on %1;
    // the fifth command is state scoped to @1, never the whole session.
    for (0..4) |step| {
        actions = viewer.next(.{ .tmux = blockEnd("") });
        const cmd = firstCommandAction(actions).?;
        if (step < 3) {
            try testing.expect(std.mem.indexOf(u8, cmd, "-t %1") != null);
        } else {
            try testing.expect(std.mem.startsWith(u8, cmd, "list-panes -t @1 "));
        }
        try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
    }

    // Window @1 is now interactive. @0 remains gated until its own complete
    // capture; titles are restored between selected and background recovery.
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "refresh-client -B") != null);
    try testing.expect(viewer.panes.get(1).?.initialized);
    try testing.expect(!viewer.panes.get(1).?.recovery_pending);
    try testing.expect(!viewer.panes.get(0).?.initialized);
    try testing.expect(viewer.panes.get(0).?.recovery_pending);
    try testing.expect(viewer.title_subscription_queued);

    // Once the title refresh acks, background recovery advances one command.
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "-t %0") != null);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
}

test "select-window reprioritizes discard recovery at the next command boundary" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupTwoWindows(&viewer);
    try acknowledgeClientSize(&viewer, 80, 24);

    viewer.forceResetPrioritized(1);
    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    const topology =
        \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
        \\$0 @1 0 1 0 %1 80 24 b25e,80x24,0,0,1 codex
    ;
    var actions = viewer.next(.{ .tmux = blockEnd(topology) });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "-t %1") != null);

    // The active %1 capture is never canceled. The exact Rootshell tab-select
    // command queues behind it and changes the scheduler preference to @0.
    try viewer.queueRelayedPaneCommand("select-window -t @0\n");
    try testing.expectEqual(@as(usize, 2), viewer.command_queue.len());
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expectEqualStrings("select-window -t @0\n", firstCommandAction(actions).?);

    // After select-window acks, recovery jumps to @0 rather than issuing %1's
    // second capture. There is still only one recovery command in the queue.
    actions = viewer.next(.{ .tmux = blockEnd("") });
    try testing.expect(std.mem.indexOf(u8, firstCommandAction(actions).?, "-t %0") != null);
    try testing.expectEqual(@as(usize, 1), viewer.command_queue.len());
}

test "forceResync does NOT recapture a reused pane (wedge regression guard)" {
    // ROOTSHELL-TMUX (id=viewer-force-resync): the wedge recovery PRESERVES and
    // reuses panes with NO recapture (their grids are intact). This guards that
    // the forceReset recapture path does not leak into the wedge path.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try driveStartupOneWindow(&viewer);
    try testing.expect(viewer.panes.contains(0));

    viewer.forceResync();
    try testing.expect(viewer.isResyncing());
    try testing.expect(!viewer.panes.get(0).?.reset_recapture);

    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqual(.command_queue, viewer.state);

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // No capture-pane queued: the pane is reused as-is.
                    var it = v.command_queue.iterator(.forward);
                    while (it.next()) |cmd| switch (cmd.*) {
                        .pane_history, .pane_visible => return error.UnexpectedRecapture,
                        else => {},
                    };
                }
            }).check,
        },
    });
}

test "forceReset resets each pane's live VT parser to ground" {
    // ROOTSHELL-TMUX (id=viewer-force-reset): a discard can truncate %output
    // mid-sequence, stranding the pane's LONG-LIVED parser; forceReset must reset
    // it (and the utf8 decoder) so the first post-recovery %output parses cleanly.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    // Strand the live parser mid-CSI, as a discard-truncated escape would.
    pane.stream.nextSlice("\x1b[1");
    try testing.expect(pane.stream.parser.state != .ground);

    viewer.forceReset();
    try testing.expect(viewer.isResyncing());
    try testing.expect(pane.stream.parser.state == .ground);
    try testing.expect(pane.stream.utf8decoder.state == 0);
}

test "reset requested during an in-flight resync upgrades the rebuild to recapture" {
    // ROOTSHELL-TMUX (id=viewer-force-reset): a discard landing while a cheaper
    // wedge forceResync is already in flight must NOT be lost. forceReset can't
    // run (needs .command_queue), so requestReset records it; the resync's marker
    // handler honors it and upgrades the rebuild into a full recapture.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);
    try acknowledgeClientSize(&viewer, 80, 24);
    try testing.expect(viewer.panes.contains(0));

    // A wedge resync is in flight (would rebuild with NO recapture on its own).
    viewer.forceResync();
    try testing.expect(viewer.isResyncing());
    try testing.expect(!viewer.panes.get(0).?.reset_recapture);

    // Discard mid-resync: forceReset no-ops; requestReset records the intent.
    viewer.requestReset();
    try testing.expect(viewer.reset_pending);

    // The resync marker arrives → honor point flags every pane for recapture.
    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expect(!viewer.reset_pending);
    try testing.expect(viewer.panes.get(0).?.reset_recapture);

    // The upgraded live rebuild reuses metadata and recaptures the pane.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_command = "capture-pane",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.panes.get(0).?.reset_recapture);
                    try testing.expect(v.panes.get(0).?.recovery_pending);
                    try testing.expectEqual(@as(usize, 1), v.command_queue.len());
                }
            }).check,
        },
    });
}

test "forceResync interrupting a reset's captures re-flags stranded panes" {
    // ROOTSHELL-TMUX (id=viewer-force-resync-reflag): a desync landing DURING a
    // reset's own capture stream (common — the reset was itself caused by a
    // lossy link) drops the queued captures via resetCommandPipeline. But
    // syncLayouts already consumed the pane's reset_recapture flag when it
    // queued them, so without the re-flag the follow-up rebuild would reuse the
    // pane WITHOUT recapture, stranding it uninitialized forever (live %output
    // suppressed) — the frozen/blank background-tab bug.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);
    try acknowledgeClientSize(&viewer, 80, 24);

    // A lossy-discard reset, then its rebuild through list-windows: the reused
    // pane's captures are queued and its reset_recapture flag is consumed.
    viewer.forceReset();
    try testing.expect(viewer.isResyncing());
    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqual(.command_queue, viewer.state);
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_command = "capture-pane",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Mid-capture: flag consumed, pane not yet initialized.
                    try testing.expect(!v.panes.get(0).?.reset_recapture);
                    try testing.expect(!v.panes.get(0).?.initialized);
                }
            }).check,
        },
    });

    // A second loss event interrupts the capture stream. The pipeline reset
    // drops the queued captures; the still-uninitialized pane must be
    // re-flagged for recapture (this is the fix; it was stranded before).
    viewer.forceResync();
    try testing.expect(viewer.isResyncing());
    try testing.expect(!viewer.panes.get(0).?.initialized);
    try testing.expect(viewer.panes.get(0).?.reset_recapture);

    // The follow-up rebuild recaptures it...
    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqual(.command_queue, viewer.state);
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.panes.get(0).?.reset_recapture);
                    var it = v.command_queue.iterator(.forward);
                    var has_capture = false;
                    while (it.next()) |cmd| switch (cmd.*) {
                        .pane_history, .pane_visible => has_capture = true,
                        else => {},
                    };
                    try testing.expect(has_capture);
                }
            }).check,
        },
    });

    // ...and once the captures + pane_state land, the pane is live again.
    var guard: usize = 0;
    while (!viewer.command_queue.empty() or viewer.command_in_flight) {
        _ = viewer.next(.{ .tmux = blockEnd("") });
        guard += 1;
        if (guard > 50) return error.TestDrainStuck;
    }
    try testing.expect(viewer.panes.get(0).?.initialized);
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = "post-reset output" } } });
    {
        const pane0: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
        const screen: *Screen = pane0.terminal.screens.active;
        const str = try screen.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(str);
        try testing.expect(std.mem.containsAtLeast(u8, str, 1, "post-reset output"));
    }
}

test "forceResync interrupting a new pane's initial captures re-flags only that pane" {
    // ROOTSHELL-TMUX (id=viewer-force-resync-reflag): steady-state variant — a
    // wedge resync drops a NEW pane's initial captures. The new pane must be
    // re-flagged (else stranded uninitialized); the already-initialized pane
    // keeps the wedge path's reuse-without-recapture (no flicker).
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // Split: new pane %2 appears; its captures are queued; %0 stays initialized.
    _ = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
        .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
        .raw_flags = "*",
    } } });
    try testing.expectEqual(2, viewer.panes.count());
    try testing.expect(viewer.panes.get(0).?.initialized);
    try testing.expect(!viewer.panes.get(2).?.initialized);

    // Desync mid-capture: only the uninitialized pane is re-flagged.
    viewer.forceResync();
    try testing.expect(viewer.isResyncing());
    try testing.expect(viewer.panes.get(2).?.reset_recapture);
    try testing.expect(viewer.panes.get(0).?.initialized);
    try testing.expect(!viewer.panes.get(0).?.reset_recapture);

    // Rebuild: captures are re-queued for %2 only.
    _ = viewer.next(.{ .tmux = blockEnd(Viewer.resync_marker ++ " $0") });
    try testing.expectEqual(.command_queue, viewer.state);
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2] bash") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    var it = v.command_queue.iterator(.forward);
                    var has_capture = false;
                    while (it.next()) |cmd| switch (cmd.*) {
                        .pane_history => |c| {
                            try testing.expectEqual(2, c.id);
                            has_capture = true;
                        },
                        .pane_visible => |c| {
                            try testing.expectEqual(2, c.id);
                            has_capture = true;
                        },
                        else => {},
                    };
                    try testing.expect(has_capture);
                }
            }).check,
        },
    });

    // Drain; %2 initializes.
    var guard: usize = 0;
    while (!viewer.command_queue.empty() or viewer.command_in_flight) {
        _ = viewer.next(.{ .tmux = blockEnd("") });
        guard += 1;
        if (guard > 50) return error.TestDrainStuck;
    }
    try testing.expect(viewer.panes.get(2).?.initialized);
}

test "pane OSC 52 emits a pane_clipboard_write action" {
    // ROOTSHELL-TMUX (id=viewer-clipboard): a -CC pane app that emits OSC 52
    // (relayed raw by tmux in %output — tmux never sets the clipboard itself for
    // a control client) must surface a clipboard write action to the app.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
    });

    // Mark the pane initialized so live %output is processed (capture-pane
    // completion normally does this).
    const pane = viewer.panes.get(0).?;
    pane.initialized = true;

    // tmux octal-escapes control bytes in %output: ESC=\033, BEL=\007.
    // "aGVsbG8=" is base64("hello"); it must reach the action still encoded.
    const actions = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "\\033]52;c;aGVsbG8=\\007",
    } } });

    var found = false;
    for (actions) |action| {
        if (action == .pane_clipboard_write) {
            found = true;
            try testing.expectEqual(@as(u8, 'c'), action.pane_clipboard_write.kind);
            try testing.expectEqualStrings("aGVsbG8=", action.pane_clipboard_write.data);
        }
    }
    try testing.expect(found);
}

test "pane wrapped OSC 9 with 0x9C in body notifies once and prints nothing" {
    // ROOTSHELL-TMUX (id=streamterm-tmux-passthrough): a `tmux;` passthrough
    // whose UTF-8 payload contains 0x9C continuation bytes must reach its real
    // `ESC \`; cutting it early leaked the body tail into the pane grid.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
    });

    const pane = viewer.panes.get(0).?;
    pane.initialized = true;

    const S = struct {
        var count: usize = 0;
        var last_body: []const u8 = "";
        fn post(_: ?*anyopaque, event: Viewer.PaneOscEvent) void {
            switch (event) {
                .notification => |n| {
                    count += 1;
                    last_body = testing.allocator.dupe(u8, n.body) catch @panic("OOM");
                },
                else => {},
            }
        }
        fn wake(_: ?*anyopaque) void {}
    };
    S.count = 0;
    S.last_body = "";
    defer if (S.last_body.len > 0) testing.allocator.free(S.last_body);

    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    pane.attachRenderer(&render_mutex, &dummy_ctx, S.wake, &dummy_ctx, S.post);
    defer pane.detachRenderer();

    const body = "构建完成，共有 3 个远程分支已更新 Ü";
    _ = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = "\\033Ptmux;\\033\\033]9;" ++ body ++ "\\007\\033\\134",
    } } });
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = "OK" } } });

    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqualStrings(body, S.last_body);
    const str = try pane.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("OK", str);
}

test "Action.format handles focus action" {
    const action: Viewer.Action = .{ .focus = .{
        .window_id = 5,
        .pane_id = 12,
    } };

    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    try action.format(&builder.writer);
    const result = builder.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, result, "focus") != null);
}

test "output suppressed for uninitialized panes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive window with single pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane should exist but not be initialized
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(!pane.initialized);
                }
            }).check,
        },
        // Output arrives during capture-pane sequence — should be suppressed
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "premature output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No actions should be emitted — output is suppressed
                    try testing.expectEqual(0, actions.len);
                    // Viewer's terminal should NOT have the premature output
                    const pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.*.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("", str);
                }
            }).check,
        },
        // Complete capture-pane sequence: 4 captures + pane_state
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = blockEnd("") },
            // pane_state completes — pane should now be initialized
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane.initialized);
                }
            }).check,
        },
        // Output after initialization — should be processed by viewer
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "real output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No actions emitted — viewer processes output
                    // internally into the pane terminal.
                    try testing.expectEqual(0, actions.len);
                    // Viewer's terminal should have the output
                    const pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.*.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "real output"));
                }
            }).check,
        },
    });
}

test "output OSC title from active pane produces title action" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    defer {
        var it = viewer.panes.iterator();
        while (it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
    }

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence: 4 captures, pane_state, then the
        // trailing title subscription command.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    try testing.expectEqual(@as(usize, 0), v.windows.items[0].active_pane_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\\033]0;codex spinner\\007",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .title) {
                            try testing.expectEqual(@as(usize, 0), action.title.window_id);
                            try testing.expectEqualStrings("codex spinner", action.title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "output decode drops raw CR and skips CR injected mid-escape" {
    // ROOTSHELL-TMUX (id=control-strip-trailing-cr): the SSH/PTY line driver can
    // inject a raw CR anywhere in a %output payload — between visible bytes, or
    // even inside a `\ooo` escape. tmux escapes every real control byte, so a raw
    // CR is always framing noise. We observe the decode through the OSC-0 title
    // path: `\033]0;<title>\007`. A raw CR mid-title must be dropped (title intact,
    // cursor not snapped to col 0); a CR splitting the leading `\033` escape must
    // be skipped so the ESC still decodes and the OSC is recognized.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    defer {
        var it = viewer.panes.iterator();
        while (it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
    }

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Raw CR injected between "ab" and "cd" inside the title: must be dropped,
        // yielding the title "abcd" (not "ab" truncated, not "ab\rcd").
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\\033]0;ab\rcd\\007",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .title) {
                            try testing.expectEqualStrings("abcd", action.title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
        // CR splitting the leading `\033` escape ("\0" + CR + "33"): must be
        // skipped so ESC decodes and the OSC title "xy" is recognized.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\\0\r33]0;xy\\007",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .title) {
                            try testing.expectEqualStrings("xy", action.title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "window_renamed produces title action" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with single pane
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence (4 captures + pane_state)
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Rename window — should produce .title action
        .{
            .input = .{ .tmux = .{ .window_renamed = .{
                .id = 0,
                .name = "vim",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .title) {
                            try testing.expectEqual(@as(usize, 0), action.title.window_id);
                            try testing.expectEqualStrings("vim", action.title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                    // Window name in viewer state should also be updated
                    try testing.expectEqualStrings("vim", v.windows.items[0].name);
                }
            }).check,
        },
    });
}

test "title dedupe: pane output and subscription emit one title per value" {
    // ROOTSHELL-TMUX (id=viewer-title-dedupe): one OSC title frame arrives via
    // the pane-output fingerprint AND the #T subscription. The second route
    // carries the same value and must not produce a second .title action.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    defer {
        var it = viewer.panes.iterator();
        while (it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
    }

    const countTitles = struct {
        fn count(actions: []const Viewer.Action) usize {
            var n: usize = 0;
            for (actions) |action| {
                if (action == .title) n += 1;
            }
            return n;
        }
    }.count;

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd("$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash") },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Pane output sets the title: one .title action.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\\033]0;spin 1\\007",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 1), countTitles(actions));
                }
            }).check,
        },
        // The subscription reports the same value: no second action.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = control.title_subscription_name,
                .window_id = 0,
                .value = "spin 1",
            } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 0), countTitles(actions));
                }
            }).check,
        },
        // A new value emits again.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = control.title_subscription_name,
                .window_id = 0,
                .value = "spin 2",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 1), countTitles(actions));
                    try testing.expectEqualStrings("spin 2", actions[actions.len - 1].title.name);
                    // A forced re-push must reach the app even when unchanged.
                    v.flagAllPanesForReset();
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = control.title_subscription_name,
                .window_id = 0,
                .value = "spin 2",
            } } },
            .contains_tags = &.{.title},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 1), countTitles(actions));
                }
            }).check,
        },
    });
}

test "session_renamed produces session_title action" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "original",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial window layout
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Rename session — should produce .session_title action
        .{
            .input = .{ .tmux = .{ .session_renamed = .{
                .id = 1,
                .name = "renamed-session",
            } } },
            .contains_tags = &.{.session_title},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .session_title) {
                            try testing.expectEqualStrings("renamed-session", action.session_title.name);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                    // Session name in viewer state should be updated
                    try testing.expectEqualStrings("renamed-session", v.session_name);
                }
            }).check,
        },
    });
}

test "list_windows stores window name" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive list-windows with a named window
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 htop
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqualStrings("htop", v.windows.items[0].name);
                }
            }).check,
        },
    });
}

test "list_windows emits focus action for active window" {
    // Verifies that receivedListWindows emits a .focus action targeting
    // the active window and its current pane from the list-windows output.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .focus },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .focus) {
                            try testing.expectEqual(0, action.focus.window_id);
                            try testing.expectEqual(0, action.focus.pane_id);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "list_windows emits focus for active window in multi-window session" {
    // With two windows, only @0 is active. The focus action should
    // target @0 and its current pane %0, not the inactive @1.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
                \\$0 @1 0 1 0 %1 80 24 b25e,80x24,0,0,1 vim
            ) },
            .contains_tags = &.{ .windows, .focus },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found = false;
                    for (actions) |action| {
                        if (action == .focus) {
                            // Active window is @0 with current pane %0
                            try testing.expectEqual(0, action.focus.window_id);
                            try testing.expectEqual(0, action.focus.pane_id);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "pause notification triggers auto-continue and full pause cycle" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence (4 captures + pane_state) and the
        // trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Pause pane 0 — should set paused=true, emit pane_paused, auto-queue
        // a continue_pane command, AND (because the pane is initialized) queue
        // the recapture batch to recover the output tmux discarded on pause.
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 0 } } },
            .contains_tags = &.{ .pane_paused, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane should be marked paused
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane.paused);
                    // Recapture branch engaged: the pane is parked
                    // uninitialized + capture_pending so live %output is
                    // suppressed during the history replay and a session-wide
                    // pane_state can't re-init other panes mid-recapture.
                    // ROOTSHELL-TMUX (id=pause-after-recover)
                    try testing.expect(!pane.initialized);
                    try testing.expect(pane.capture_pending);
                    // Queue holds the in-flight continue HEAD plus the 5-command
                    // recapture batch (history/visible primary+alt, pane_state):
                    // len is 6, NOT 5 — the in-flight head still counts.
                    try testing.expectEqual(@as(usize, 6), v.command_queue.len());
                    // Action should indicate paused=true
                    var found_paused = false;
                    var found_continue = false;
                    for (actions) |action| {
                        if (action == .pane_paused) {
                            try testing.expectEqual(@as(usize, 0), action.pane_paused.pane_id);
                            try testing.expect(action.pane_paused.paused);
                            found_paused = true;
                        }
                        if (action == .command) {
                            if (std.mem.startsWith(u8, action.command, "refresh-client -A")) {
                                found_continue = true;
                            }
                        }
                    }
                    try testing.expect(found_paused);
                    try testing.expect(found_continue);
                }
            }).check,
        },
        // Receive continue_pane response (no-op), then %continue
        // notification clears the paused state.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .@"continue" = .{ .pane_id = 0 } } },
            .contains_tags = &.{.pane_paused},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane should no longer be paused
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(!pane.paused);
                    // Action should indicate paused=false
                    var found = false;
                    for (actions) |action| {
                        if (action == .pane_paused) {
                            try testing.expectEqual(@as(usize, 0), action.pane_paused.pane_id);
                            try testing.expect(!action.pane_paused.paused);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "pause for unknown pane is ignored" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Pause for unknown pane 99 — should be silently ignored
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 99 } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No pane_paused action should be emitted
                    for (actions) |action| {
                        if (action == .pane_paused) {
                            return error.UnexpectedAction;
                        }
                    }
                }
            }).check,
        },
    });
}

test "two paused panes: one pane's pane_state does not re-initialize the other" {
    // Regression for the cross-pane re-init bug in pause recapture: when two
    // panes pause and each queues its own recapture batch, the FIRST pane's
    // session-wide pane_state (`list-panes -s`, covers every pane) must NOT
    // mark the OTHER still-recapturing pane initialized — that would let live
    // %output interleave before the second pane's history replay and corrupt
    // its screen. The `capture_pending` flag set at pause entry is the guard.
    // ROOTSHELL-TMUX (id=pause-after-recover)
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    const pane_state_content =
        \\%0;42;0;1;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
        \\%4;10;5;1;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
    ;

    try testViewer(&viewer, &.{
        // Standard startup with a 2-pane vertical split (panes %0 and %4).
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 0, .name = "0" } } },
            .contains_command = "refresh-client",
        },
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "display-message" },
        .{ .input = .{ .tmux = blockEnd("3.5a") }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4] bash
            ) },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // Drain the 8 capture responses (4 per pane), the trailing pane_state,
        // and the title subscription so both panes are initialized and the
        // command queue is empty before we pause.
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %0 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %0 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %0 alternate
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %0 alternate
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %4 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %4 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %4 alternate
        .{ .input = .{ .tmux = blockEnd("") }, .contains_command = "list-panes -s -t $0" }, // pv %4 alternate -> pumps pane_state
        .{ .input = .{ .tmux = blockEnd(pane_state_content) } }, // pane_state -> pumps subscribe_titles
        .{
            .input = .{ .tmux = blockEnd("") }, // subscribe_titles ack (drains the queue)
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Both panes initialized, queue drained.
                    try testing.expect(v.panes.getEntry(0).?.value_ptr.*.initialized);
                    try testing.expect(v.panes.getEntry(4).?.value_ptr.*.initialized);
                    try testing.expectEqual(@as(usize, 0), v.command_queue.len());
                }
            }).check,
        },
        // Pause %0: parks %0 uninitialized + capture_pending, leaves %4 alone.
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 0 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const p0 = v.panes.getEntry(0).?.value_ptr.*;
                    const p4 = v.panes.getEntry(4).?.value_ptr.*;
                    try testing.expect(!p0.initialized);
                    try testing.expect(p0.capture_pending);
                    try testing.expect(p4.initialized);
                    try testing.expect(!p4.capture_pending);
                }
            }).check,
        },
        // Pause %4: now both panes are parked + capture_pending.
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 4 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const p4 = v.panes.getEntry(4).?.value_ptr.*;
                    try testing.expect(!p4.initialized);
                    try testing.expect(p4.capture_pending);
                }
            }).check,
        },
        // Drive %0's recapture to completion. Its trailing session-wide
        // pane_state covers BOTH %0 and %4 — but %4 is still capture_pending,
        // so it must stay uninitialized.
        .{ .input = .{ .tmux = blockEnd("") } }, // continue %0 ack
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %0 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %0 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %0 alternate
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %0 alternate
        .{
            .input = .{ .tmux = blockEnd(pane_state_content) }, // %0's pane_state
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // %0 recaptured -> initialized; %4 still mid-recapture -> NOT.
                    try testing.expect(v.panes.getEntry(0).?.value_ptr.*.initialized);
                    try testing.expect(!v.panes.getEntry(4).?.value_ptr.*.initialized);
                }
            }).check,
        },
        // Drive %4's recapture; its own pane_state finally re-initializes it.
        .{ .input = .{ .tmux = blockEnd("") } }, // continue %4 ack
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %4 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %4 primary
        .{ .input = .{ .tmux = blockEnd("") } }, // ph %4 alternate
        .{ .input = .{ .tmux = blockEnd("") } }, // pv %4 alternate
        .{
            .input = .{ .tmux = blockEnd(pane_state_content) }, // %4's pane_state
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.panes.getEntry(4).?.value_ptr.*.initialized);
                }
            }).check,
        },
    });
}

test "pane_mode_changed queues query and updates state on response" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence (4 captures + pane_state) and the
        // trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Pane mode changed notification — should queue display-message query
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } },
            .contains_command = "display-message",
        },
        // Response with copy-mode — should update state and emit action
        .{
            .input = .{ .tmux = blockEnd("copy-mode") },
            .contains_tags = &.{.pane_mode_changed},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane mode should be updated to copy
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(Viewer.PaneMode.copy, pane.mode);
                    // Action should report the mode change
                    var found = false;
                    for (actions) |action| {
                        if (action == .pane_mode_changed) {
                            try testing.expectEqual(@as(usize, 0), action.pane_mode_changed.pane_id);
                            try testing.expectEqual(Viewer.PaneMode.copy, action.pane_mode_changed.mode);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "pane_mode_changed for unknown pane is ignored" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // Pane mode changed for unknown pane 99 — should not queue a command
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 99 } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No command should be queued (no display-message)
                    for (actions) |action| {
                        if (action == .command) {
                            return error.UnexpectedCommand;
                        }
                    }
                }
            }).check,
        },
    });
}

test "pane_mode_changed empty response means normal mode" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        // Receive client_size response, which triggers version query
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane sequence and the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // First, enter copy mode so we have a non-normal state
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("copy-mode") },
            .contains_tags = &.{.pane_mode_changed},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(Viewer.PaneMode.copy, pane.mode);
                }
            }).check,
        },
        // Now exit copy mode — empty response means normal
        .{
            .input = .{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_tags = &.{.pane_mode_changed},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Pane mode should be back to normal
                    const pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(Viewer.PaneMode.normal, pane.mode);
                    // Action should report normal mode
                    var found = false;
                    for (actions) |action| {
                        if (action == .pane_mode_changed) {
                            try testing.expectEqual(@as(usize, 0), action.pane_mode_changed.pane_id);
                            try testing.expectEqual(Viewer.PaneMode.normal, action.pane_mode_changed.mode);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "layout_change mid-capture suppresses output for uninitialized pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup: single-pane layout
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Receive initial layout with one pane (%0)
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 83 44 b7dd,83x44,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture sequence for pane 0: 4 capture-pane + 1 pane_state,
        // then the trailing title subscription.
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    // Pane 0 should be initialized
                    const pane0 = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane0.initialized);
                }
            }).check,
        },
        // Layout change splits into two panes: %0 and %2.
        // This queues capture commands for the new pane %2.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // New pane %2 should NOT be initialized yet
                    const pane2 = v.panes.getEntry(2).?.value_ptr.*;
                    try testing.expect(!pane2.initialized);
                    // Existing pane %0 should still be initialized
                    const pane0 = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expect(pane0.initialized);
                }
            }).check,
        },
        // Output arrives for pane %2 BEFORE its capture completes.
        // It should be suppressed (no actions emitted).
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 2, .data = "premature output" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Output for pane %0 (already initialized) should still work.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "valid output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Viewer processes into its own terminal (no output
                    // action), but the data should be in the terminal.
                    try testing.expectEqual(0, actions.len);
                    const pane0: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane0.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "valid output"));
                }
            }).check,
        },
        // Complete the capture sequence for pane %2:
        // 4 capture-pane responses
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        // pane_state response — this marks all panes as initialized
        .{
            .input = .{ .tmux = blockEnd("") },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane %2 should now be initialized
                    const pane2 = v.panes.getEntry(2).?.value_ptr.*;
                    try testing.expect(pane2.initialized);
                }
            }).check,
        },
        // Now output for pane %2 should be processed normally.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 2, .data = "post-init output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane2: *Viewer.Pane = v.panes.getEntry(2).?.value_ptr.*;
                    const screen: *Screen = pane2.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "post-init output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "pane state alternate_saved cursor applies to primary screen" {
    // When alternate_on=1, the alternate_saved_x/y values represent the
    // cursor position saved from the primary screen on entry to alternate
    // mode. They must be applied to the primary screen, not the alternate
    // screen (which would overwrite the active cursor).
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        // Single pane layout
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // capture-pane pane 0 primary history (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane pane 0 primary visible (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = blockEnd("") } },
        // pane_state: alternate_on=1, cursor at (10,2) on alternate screen,
        // alternate_saved at (5,3) which should go to primary screen.
        //
        // Format: pane_id;cursor_x;cursor_y;cursor_flag;cursor_shape;
        //         cursor_blinking;alternate_on;alternate_saved_x;
        //         alternate_saved_y;insert_flag;wrap_flag;keypad_flag;
        //         keypad_cursor_flag;origin_flag;mouse_all_flag;
        //         mouse_any_flag;mouse_button_flag;mouse_standard_flag;
        //         mouse_utf8_flag;mouse_sgr_flag;focus_flag;
        //         bracketed_paste;scroll_region_upper;scroll_region_lower;
        //         pane_tabs
        .{
            .input = .{ .tmux = blockEnd(
                \\%0;10;2;1;;0;1;5;3;0;1;0;0;0;0;0;0;0;0;0;0;0;0;23;8,16,24,32,40,48,56,64,72,80
            ) },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const t: *Terminal = &pane.terminal;
                    // Terminal should be on alternate screen
                    try testing.expectEqual(ScreenSet.Key.alternate, t.screens.active_key);
                    // Active (alternate) cursor should be at (10, 2)
                    const alt_screen: *Screen = t.screens.get(.alternate).?;
                    try testing.expectEqual(10, alt_screen.cursor.x);
                    try testing.expectEqual(2, alt_screen.cursor.y);
                    // Saved cursor (primary screen) should be at (5, 3)
                    const pri_screen: *Screen = t.screens.get(.primary).?;
                    try testing.expectEqual(5, pri_screen.cursor.x);
                    try testing.expectEqual(3, pri_screen.cursor.y);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "pane state alternate_on keeps the normal-screen scrollback on the primary" {
    // ROOTSHELL-TMUX (id=alt-screen-fix): a pane in its alternate screen has, in
    // tmux: ACTIVE grid = the alt-screen app (captured WITHOUT -a); SAVED grid =
    // the normal screen's last visible row(s) with ZERO history (captured WITH
    // -a). The normal screen's SCROLLBACK stays in the main grid, so the no-`-a`
    // `pane_history` (-S) carries it. The viewer must:
    //   * DISPLAY the alt app on the alternate screen, normal screen on primary;
    //   * keep the normal-screen scrollback on the PRIMARY (real-budget) screen so
    //     it survives the app exiting (`\x1b[?1049l` -> switchScreen(.primary)),
    //     AND the primary keeps a non-zero scrollback budget (no "rubber band").
    // The old code pointer-swapped the two Screen objects, which stranded the
    // scrollback on the 0-budget alternate screen AND made that 0-budget object
    // the live primary — both symptoms this test guards against.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 0, .name = "0" } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        // capture-pane primary history (no -a) = the main grid's HISTORY = the
        // NORMAL screen's scrollback (tmux keeps history in the main grid even
        // while the alt app draws into its visible region).
        .{ .input = .{ .tmux = blockEnd("OLD-HISTORY-LINE") } },
        // capture-pane primary visible (no -a) = the main grid's VISIBLE = the
        // alt-screen app.
        .{ .input = .{ .tmux = blockEnd("VIM") } },
        // capture-pane alternate history (-a) = the saved grid = EMPTY (tmux
        // creates saved_grid with 0 history).
        .{ .input = .{ .tmux = blockEnd("") } },
        // capture-pane alternate visible (-a) = the saved grid's visible = the
        // normal screen's last visible row(s).
        .{ .input = .{ .tmux = blockEnd("SHELL") } },
        // pane_state: alternate_on=1 (this pane is in the alternate screen).
        .{
            .input = .{ .tmux = blockEnd(
                \\%0;10;2;1;;0;1;5;3;0;1;0;0;0;0;0;0;0;0;0;0;0;0;23;8,16,24,32,40,48,56,64,72,80
            ) },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const t: *Terminal = &pane.terminal;
                    // The active screen is the alternate, showing the alt app.
                    try testing.expectEqual(ScreenSet.Key.alternate, t.screens.active_key);
                    {
                        const str = try t.screens.active.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("VIM", str);
                    }
                    const pri = t.screens.get(.primary).?;
                    // The normal/shell screen sits behind it on the primary.
                    {
                        const str = try pri.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("SHELL", str);
                    }
                    // The normal-screen scrollback is on the PRIMARY (the old swap
                    // stranded it on the alternate, where it was lost on app exit).
                    {
                        const str = try pri.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("OLD-HISTORY-LINE", str);
                    }
                    // Rubber-band guard: the live primary is the real
                    // scrollback-bearing screen (non-zero budget) and the alternate
                    // stays the 0-budget ephemeral screen. The old swap inverted
                    // these, so the primary could never accumulate scrollback.
                    try testing.expect(pri.pages.limits.bytes.explicit > 0);
                    try testing.expectEqual(
                        @as(usize, 0),
                        t.screens.get(.alternate).?.pages.limits.bytes.explicit,
                    );
                }
            }).check,
        },
        // The alt-screen app exits: tmux relays its `ESC [?1049l` as live output.
        // In the %output wire format tmux escapes the ESC control byte as the
        // backslash-octal `\033` (a raw 0x1b would be stripped as line-driver
        // noise by receivedOutput). This switches the pane back to the primary.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "\\033[?1049l" } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const t: *Terminal = &pane.terminal;
                    // Back on the primary (normal) screen...
                    try testing.expectEqual(ScreenSet.Key.primary, t.screens.active_key);
                    // ...with the cursor restored to tmux's alternate_saved_x/y
                    // (5,3 from the pane_state line), NOT snapped to (0,0). The
                    // app's exit 1049l runs restoreCursor(), which reads the
                    // saved-cursor slot we seeded. ROOTSHELL-TMUX
                    // (id=alt-screen-cursor-restore)
                    try testing.expectEqual(5, t.screens.active.cursor.x);
                    try testing.expectEqual(3, t.screens.active.cursor.y);
                    // ...with the scrollback history STILL present (the bug lost it).
                    const str = try t.screens.active.dumpStringAlloc(
                        testing.allocator,
                        .{ .history = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("OLD-HISTORY-LINE", str);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

fn testPaneStateMouseModes(
    pane_state: []const u8,
    expected_event: mouse.Event,
    expected_format: mouse.Format,
    expected_normal: bool,
    expected_button: bool,
    expected_any: bool,
) !void {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    defer {
        var it = viewer.panes.iterator();
        while (it.next()) |kv| kv.value_ptr.*.clearPendingAttach();
    }

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "refresh-client",
        },
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = blockEnd("3.5a") },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = blockEnd(
                \\$0 @0 1 0 0 %0 80 24 b25d,80x24,0,0,0 bash
            ) },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = blockEnd(pane_state) },
        },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
    const t: *Terminal = &pane.terminal;

    try testing.expect(!t.modes.get(.mouse_event_x10));
    try testing.expectEqual(expected_normal, t.modes.get(.mouse_event_normal));
    try testing.expectEqual(expected_button, t.modes.get(.mouse_event_button));
    try testing.expectEqual(expected_any, t.modes.get(.mouse_event_any));
    try testing.expect(t.modes.get(.mouse_format_sgr));
    try testing.expect(!t.modes.get(.mouse_format_utf8));
    try testing.expectEqual(expected_event, t.flags.mouse_event);
    try testing.expectEqual(expected_format, t.flags.mouse_format);

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "pane state restores tmux mouse flags" {
    // tmux source defines mouse_any_flag as ALL_MOUSE_MODES, not DECSET
    // 1002. The concrete mutually exclusive modes are standard (1000),
    // button (1002), and all (1003).
    try testPaneStateMouseModes(
        "%0;0;0;1;;0;0;4294967295;4294967295;0;1;0;0;0;0;1;0;1;0;1;0;0;0;23;8,16,24,32,40,48,56,64,72,80",
        .normal,
        .sgr,
        true,
        false,
        false,
    );
    try testPaneStateMouseModes(
        "%0;0;0;1;;0;0;4294967295;4294967295;0;1;0;0;0;0;1;1;0;0;1;0;0;0;23;8,16,24,32,40,48,56,64,72,80",
        .button,
        .sgr,
        false,
        true,
        false,
    );
    try testPaneStateMouseModes(
        "%0;0;0;1;;0;0;4294967295;4294967295;0;1;0;0;0;1;1;0;0;0;1;0;0;0;23;8,16,24,32,40,48,56,64,72,80",
        .any,
        .sgr,
        false,
        false,
        true,
    );
}

// ROOTSHELL-TMUX (id=viewer-user-query): app-issued query command tests.

test "user_query appends missing trailing newline and formats verbatim" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserQuery("list-sessions -F '#{session_id}'", 7);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cmd = (try viewer.takePendingCommand(arena.allocator())).?;
        try testing.expectEqualStrings("list-sessions -F '#{session_id}'\n", cmd);
    }
    // Drain the response so the viewer ends the test idle.
    _ = viewer.next(.{ .tmux = blockEnd("") });
}

test "user_query success delivers command_response with tag and body" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserQuery("list-sessions -F 'x'\n", 42);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = (try viewer.takePendingCommand(arena.allocator())).?;
    }

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = blockEnd("$0 3 1 main\n$1 1 0 alpha") },
            .contains_tags = &.{.command_response},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    _ = v;
                    for (actions) |a| {
                        if (a == .command_response) {
                            try testing.expectEqual(@as(u32, 42), a.command_response.tag);
                            try testing.expect(!a.command_response.is_err);
                            try testing.expectEqualStrings(
                                "$0 3 1 main\n$1 1 0 alpha",
                                a.command_response.body,
                            );
                            return;
                        }
                    }
                    return error.MissingCommandResponse;
                }
            }).check,
        },
    });
    try testing.expect(!viewer.command_in_flight);
    try testing.expect(viewer.command_queue.empty());
}

test "user_query %error delivers is_err response and the pump continues" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // Two queries: the first goes in flight, the second waits behind it.
    try viewer.queueUserQuery("new-session -d -s dup\n", 1);
    try viewer.queueUserQuery("list-sessions\n", 2);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = (try viewer.takePendingCommand(arena.allocator())).?;
    }

    try testViewer(&viewer, &.{
        // %error for the first query: is_err response with the error body,
        // and the pump emits the second queued query (FIFO intact).
        .{
            .input = .{ .tmux = .{ .block_err = testBlock("duplicate session: dup", 1) } },
            .contains_tags = &.{.command_response},
            .contains_command = "list-sessions",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    _ = v;
                    for (actions) |a| {
                        if (a == .command_response) {
                            try testing.expectEqual(@as(u32, 1), a.command_response.tag);
                            try testing.expect(a.command_response.is_err);
                            try testing.expectEqualStrings(
                                "duplicate session: dup",
                                a.command_response.body,
                            );
                            return;
                        }
                    }
                    return error.MissingCommandResponse;
                }
            }).check,
        },
        // Success for the second query.
        .{
            .input = .{ .tmux = blockEnd("$0 main") },
            .contains_tags = &.{.command_response},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    _ = v;
                    for (actions) |a| {
                        if (a == .command_response) {
                            try testing.expectEqual(@as(u32, 2), a.command_response.tag);
                            try testing.expect(!a.command_response.is_err);
                            return;
                        }
                    }
                    return error.MissingCommandResponse;
                }
            }).check,
        },
    });
    try testing.expect(!viewer.command_in_flight);
    try testing.expect(viewer.command_queue.empty());
}

test "pending user queries error back across %session-changed" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // One query in flight (the attach-session itself), one waiting.
    try viewer.queueUserQuery("attach-session -t \"$2\"\n", 10);
    try viewer.queueUserQuery("list-sessions\n", 11);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = (try viewer.takePendingCommand(arena.allocator())).?;
    }

    // tmux switched sessions BEFORE answering the queries (notification-first
    // ordering). Both pending tags must error back, the topology resets, and
    // the rebuild begins with list-windows + the new session identity.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 2, .name = "alpha" } } },
            .contains_tags = &.{ .windows, .command_response, .session_info, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 2), v.session_id);
                    try testing.expectEqualStrings("alpha", v.session_name);
                    var seen_10 = false;
                    var seen_11 = false;
                    for (actions) |a| switch (a) {
                        .command_response => |cr| {
                            try testing.expect(cr.is_err);
                            try testing.expectEqual(@as(usize, 0), cr.body.len);
                            if (cr.tag == 10) seen_10 = true;
                            if (cr.tag == 11) seen_11 = true;
                        },
                        .windows => |w| try testing.expectEqual(@as(usize, 0), w.len),
                        .session_info => |si| {
                            try testing.expectEqual(@as(usize, 2), si.id);
                            try testing.expectEqualStrings("alpha", si.name);
                        },
                        else => {},
                    };
                    try testing.expect(seen_10);
                    try testing.expect(seen_11);
                }
            }).check,
        },
    });
}

test "switch-client normal ordering: %end then %session-changed" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserQuery("attach-session -t \"$2\"\n", 5);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = (try viewer.takePendingCommand(arena.allocator())).?;
    }

    try testViewer(&viewer, &.{
        // The attach-session reply block arrives first: a clean success
        // response, nothing else.
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_tags = &.{.command_response},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    _ = v;
                    for (actions) |a| {
                        if (a == .command_response) {
                            try testing.expectEqual(@as(u32, 5), a.command_response.tag);
                            try testing.expect(!a.command_response.is_err);
                            return;
                        }
                    }
                    return error.MissingCommandResponse;
                }
            }).check,
        },
        // Then %session-changed rebuilds with no pending queries to fail.
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 2, .name = "alpha" } } },
            .contains_tags = &.{ .windows, .session_info, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(usize, 2), v.session_id);
                    for (actions) |a| {
                        if (a == .command_response) return error.UnexpectedResponse;
                    }
                }
            }).check,
        },
        // The new session's list-windows response builds the topology.
        .{
            .input = .{ .tmux = blockEnd("$2 @5 1 0 0 %9 83 44 b7dd,83x44,0,0,9 zsh") },
            .contains_tags = &.{.windows},
        },
    });
}

test "post-switch straggler block self-heals via recover" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    // The attach query is in flight when the notification-first switch
    // arrives; the rebuild leaves list-windows in flight.
    try viewer.queueUserQuery("attach-session -t \"$2\"\n", 20);
    {
        var arena: ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        _ = (try viewer.takePendingCommand(arena.allocator())).?;
    }
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 2, .name = "alpha" } } },
            .contains_command = "list-windows",
        },
        // The straggler attach-session reply (empty body) is mis-consumed as
        // the list-windows response: zero windows (deliberately dropped by the
        // stream handler's empty guard), and the fresh viewer queues its
        // subscribe_titles follow-up. No defunct.
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_command = "refresh-client -B",
        },
        // The REAL list-windows reply is mis-consumed one slot later as the
        // subscribe_titles response (silently discarded). The FIFO is shifted,
        // not broken.
        .{ .input = .{ .tmux = blockEnd("$2 @5 1 0 0 %9 83 44 b7dd,83x44,0,0,9 zsh") } },
        // The subscribe_titles ack then has no command in flight: the viewer
        // flags the desync and asks for a live recover (forceResync) instead
        // of going defunct. The recover rebuilds the topology.
        .{
            .input = .{ .tmux = blockEnd("") },
            .contains_tags = &.{.recover},
        },
    });
    try testing.expect(viewer.state == .command_queue);
}

// ROOTSHELL-TMUX (id=viewer-sessions-changed): dashboard refresh nudges.

test "sessions_changed and other-client churn emit sessions_changed action" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .sessions_changed },
            .contains_tags = &.{.sessions_changed},
        },
        .{
            .input = .{ .tmux = .{ .client_detached = .{ .client = "client-1" } } },
            .contains_tags = &.{.sessions_changed},
        },
        .{
            .input = .{ .tmux = .{ .client_session_changed = .{
                .client = "client-1",
                .session_id = 3,
                .name = "beta",
            } } },
            .contains_tags = &.{.sessions_changed},
        },
    });
}

// ROOTSHELL-TMUX (id=viewer-session-info): attached-session identity.

test "startup emits session_info with id and name" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = blockEnd("") } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 7, .name = "main" } } },
            .contains_tags = &.{ .session_info, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    _ = v;
                    for (actions) |a| {
                        if (a == .session_info) {
                            try testing.expectEqual(@as(usize, 7), a.session_info.id);
                            try testing.expectEqualStrings("main", a.session_info.name);
                            return;
                        }
                    }
                    return error.MissingSessionInfo;
                }
            }).check,
        },
    });
}

test "session rename emits session_title and session_info" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .session_renamed = .{ .id = 1, .name = "renamed" } } },
            .contains_tags = &.{ .session_title, .session_info, .sessions_changed },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("renamed", v.session_name);
                    for (actions) |a| {
                        if (a == .session_info) {
                            try testing.expectEqualStrings("renamed", a.session_info.name);
                        }
                    }
                }
            }).check,
        },
    });
}

// tmux broadcasts %session-renamed to EVERY control client, so a rename of
// another session on the same server must not relabel this gateway (it used
// to, which renamed the wrong session from a second gateway's tab menu).
// ROOTSHELL-TMUX (id=viewer-session-renamed-scope)
test "session rename of another session leaves our identity alone" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);
    try testing.expectEqual(@as(usize, 1), viewer.session_id);

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .session_renamed = .{ .id = 2, .name = "other" } } },
            .contains_tags = &.{.sessions_changed},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Our own name and id are untouched...
                    try testing.expectEqualStrings("test", v.session_name);
                    try testing.expectEqual(@as(usize, 1), v.session_id);
                    // ...and no title/identity action reaches the app.
                    for (actions) |a| {
                        try testing.expect(a != .session_title);
                        try testing.expect(a != .session_info);
                    }
                }
            }).check,
        },
    });
}

test "forceResync yields pending user_query tags" {
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    try viewer.queueUserQuery("list-sessions\n", 30);
    try viewer.queueUserQuery("list-windows -a\n", 31);

    var tags: std.ArrayList(u32) = .empty;
    defer tags.deinit(testing.allocator);
    viewer.forEachPendingQueryTag(&tags, (struct {
        fn cb(list: *std.ArrayList(u32), tag: u32) void {
            list.append(testing.allocator, tag) catch {};
        }
    }).cb);
    try testing.expectEqualSlices(u32, &.{ 30, 31 }, tags.items);

    // forceResync clears the queue (the stream handler errors the tags back
    // to the app first, using the same iteration just exercised above).
    viewer.forceResync();
    try testing.expect(viewer.command_queue.empty());
    try testing.expect(viewer.isResyncing());
}

test "bounded pane lock: contended renderer spills output, flushes on next event" {
    // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock): the control channel must
    // never block indefinitely on a pane renderer mutex. With the mutex held
    // (as a stuck pane renderer would), live %output spills to pending_vt
    // within the bounded budget; the next viewer event flushes it.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    const wake_fn = struct {
        fn wake(_: ?*anyopaque) void {}
    }.wake;
    const osc_post_fn = struct {
        fn post(_: ?*anyopaque, _: Viewer.PaneOscEvent) void {}
    }.post;
    pane.attachRenderer(&render_mutex, &dummy_ctx, wake_fn, &dummy_ctx, osc_post_fn);
    defer pane.detachRenderer();

    // Hold the renderer mutex like a wedged pane renderer.
    render_mutex.lockUncancelable(testing.io);
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = "hello" } } });
    // The write spilled instead of deadlocking.
    try testing.expectEqualStrings("hello", pane.pending_vt.items);
    try testing.expect(!pane.pending_dropped);
    render_mutex.unlock(testing.io);

    // Any subsequent viewer event retries deferred work first, so the spill
    // lands before the new data.
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = " world" } } });
    try testing.expectEqual(@as(usize, 0), pane.pending_vt.items.len);
    try testing.expect(!pane.pending_dropped);
}

test "bounded pane lock: spill overflow drops and queues a visible re-fetch" {
    // ROOTSHELL-TMUX (id=viewer-pane-bounded-lock): when the spill exceeds its
    // cap, the content is dropped and the next lock window re-fetches the
    // pane's visible content from tmux instead of replaying a hole.
    var viewer = try Viewer.init(testing.io, testing.allocator, 80, 24);
    defer viewer.deinit();
    try driveStartupOneWindow(&viewer);

    const pane = viewer.panes.get(0).?;
    var render_mutex: std.Io.Mutex = .init;
    var dummy_ctx: u8 = 0;
    const wake_fn = struct {
        fn wake(_: ?*anyopaque) void {}
    }.wake;
    const osc_post_fn = struct {
        fn post(_: ?*anyopaque, _: Viewer.PaneOscEvent) void {}
    }.post;
    pane.attachRenderer(&render_mutex, &dummy_ctx, wake_fn, &dummy_ctx, osc_post_fn);
    defer pane.detachRenderer();

    const big = try testing.allocator.alloc(u8, 600 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    render_mutex.lockUncancelable(testing.io);
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = big } } });
    try testing.expect(!pane.pending_dropped);
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = big } } });
    // Second spill exceeded PANE_PENDING_VT_MAX: dropped, buffer cleared.
    try testing.expect(pane.pending_dropped);
    try testing.expectEqual(@as(usize, 0), pane.pending_vt.items.len);
    render_mutex.unlock(testing.io);

    // The next event's deferred flush queues the visible re-fetch.
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 0, .data = "y" } } });
    try testing.expect(!pane.pending_dropped);
    var found_visible = false;
    var it = viewer.command_queue.iterator(.forward);
    while (it.next()) |cmd| {
        if (cmd.* == .pane_visible) found_visible = true;
    }
    try testing.expect(found_visible);
}
