//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
pub const Thread = @This();

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// The number of milliseconds to coalesce certain messages like resize for.
    /// Not all message types are coalesced.
    const min_ms = 25;

    resize: ?renderer.Size = null,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    self.stop.deinit();
    self.loop.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    // Call child function so we can use errors...
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});

        // Use an arena to simplify memory management below
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // If there is an error, we replace our terminal screen with
        // the error message. It might be better in the future to send
        // the error to the surface thread and let the apprt deal with it
        // in some way but this works for now. Without this, the user would
        // just see a blank terminal window.
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const t = io.renderer_state.terminal;

        // Hide the cursor
        t.modes.set(.cursor_visible, false);

        // This is weird but just ensures that no matter what our underlying
        // implementation we have the errors below. For example, Windows doesn't
        // have "OpenptyFailed".
        const Err = @TypeOf(err) || error{
            OpenptyFailed,
            InputNotFound,
            InputFailed,
        };

        switch (@as(Err, @errorCast(err))) {
            error.OpenptyFailed => {
                const str =
                    \\Your system cannot allocate any more pty devices.
                    \\
                    \\Ghostty requires a pty device to launch a new terminal.
                    \\This error is usually due to having too many terminal
                    \\windows open or having another program that is using too
                    \\many pty devices.
                    \\
                    \\Please free up some pty devices and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            error.InputNotFound,
            error.InputFailed,
            => {
                const str =
                    \\A configured `input` path was not found, was not readable,
                    \\was too large, or the underlying pty failed to accept
                    \\the write.
                    \\
                    \\Ghostty can't continue since it can't guarantee that
                    \\initial terminal state will be as desired. Please review
                    \\the value of `input` in your configuration file and
                    \\ensure that all the path values exist and are readable.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            else => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\error starting IO thread: {}
                    \\
                    \\The underlying shell or command was unable to be started.
                    \\This error is usually due to exhausting a system resource.
                    \\If this looks like a bug, please report it.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{err},
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
        }
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Get the mailbox. This must be an SPSC mailbox for threading.
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
        // else => return error.TermioUnsupportedMailbox,
    };

    // This is the data sent to xev callbacks. We want a pointer to both
    // ourselves and the thread data so we can thread that through (pun intended).
    var cb: CallbackData = .{ .self = self, .io = io };

    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed. The thread data is created
    // on the stack here so that it has a stable pointer throughout the
    // lifetime of the thread.
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);

    // Start the async handlers.
    mailbox.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;
    const data = &cb.data;

    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }

    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var redraw: bool = false;
    while (mailbox.pop(global.io())) |message| {
        // If we have a message we always redraw
        redraw = true;

        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
            .visibility_report => |v| try io.visibilityReport(
                data,
                v.visible,
                v.force,
            ),
            .crash => @panic("crash request, crashing intentionally"),
            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try io.changeConfig(data, config.ptr);
            },
            .inspector => |v| self.flags.has_inspector = v,
            .resize => |v| self.handleResize(cb, v),
            .size_report => |v| try io.sizeReport(data, v),
            .clear_screen => |v| try io.clearScreen(data, v.history),
            .scroll_viewport => |v| io.scrollViewport(v),
            .selection_scroll => |v| {
                if (v) {
                    self.startScrollTimer(cb);
                } else {
                    self.stopScrollTimer();
                }
            },
            .jump_to_prompt => |v| try io.jumpToPrompt(v),
            .tmux_set_client_size => |v| { // ROOTSHELL-TMUX (id=thread-set-client-size)
                // Hold tmux_mutex (NOT the renderer mutex) around the arm: it
                // touches viewer state only, and the control channel must stay
                // independent of the renderer (id=termio-tmux-mutex). The
                // unlocked-io flag makes messageWriter use bounded no-mutex
                // sends instead of the renderer unlock/relock slow path.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxSetClientSize(v.cols, v.rows);
            },
            .tmux_pane_command => |v| { // ROOTSHELL-TMUX (id=thread-pane-command)
                // Same locking rationale as .tmux_set_client_size.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                defer v.alloc.free(v.data);
                io.terminal_stream.handler.tmuxQueuePaneCommand(v.data);
            },
            .tmux_query_command => |v| { // ROOTSHELL-TMUX (id=thread-query-command)
                // Same locking rationale as .tmux_set_client_size.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                defer {
                    v.alloc.free(v.data);
                    v.alloc.destroy(v);
                }
                io.terminal_stream.handler.tmuxQueueQueryCommand(v.data, v.tag);
            },
            .tmux_send_keys => |v| { // ROOTSHELL-TMUX (id=thread-send-keys)
                // Record the `.untracked` marker BEFORE writing, under
                // tmux_mutex, then write OUTSIDE the lock:
                //
                //  - Marker-before-write closes the parse race: the control
                //    parse runs under tmux_mutex (not the renderer mutex) and
                //    mutexes are not fair, so write-then-record could let a
                //    busy read thread parse the command's %begin/%end ack
                //    before the marker exists (FIFO desync). The ack can only
                //    arrive after the write, so recording first is always
                //    safe.
                //  - Marker ORDER still equals pty write order: all gateway
                //    writes happen on this thread in drain order, and markers
                //    are recorded in the same order.
                //  - The write stays outside tmux_mutex because the pipe
                //    backend's queueWrite can block on a full response pipe;
                //    holding the lock there would wedge the read path behind
                //    a blocked write.
                //
                // A failed write after recording leaves stray markers (one
                // per unwritten command line); the block-mismatch self-heal
                // recovers, and a queueWrite error aborts the IO thread
                // anyway. ROOTSHELL-TMUX (id=thread-tmux-write-record-atomic)
                defer v.alloc.free(v.data);
                // One marker per command line: a batched payload carries
                // several `\n`-terminated send-keys lines and tmux acks EACH
                // line with one %begin/%end block. Hex bodies cannot contain
                // a literal '\n' (0x0A encodes as "0A"), so the newline count
                // is exactly the line count.
                const line_count = std.mem.count(u8, v.data, "\n");
                {
                    io.tmux_mutex.lockUncancelable(global.io());
                    defer io.tmux_mutex.unlock(global.io());
                    io.terminal_stream.handler.recordTmuxUntrackedSend(@max(1, line_count));
                }
                io.queueWrite(data, v.data, self.flags.linefeed_mode) catch |err| {
                    // The marker above is now stale (nothing was written, so
                    // no ack will consume it) and the drain loop does NOT
                    // abort on errors — a later block would be misclassified
                    // against it. A live resync resets the sent-FIFO and the
                    // command pipeline cleanly.
                    log.warn("tmux send-keys write failed err={}; forcing resync", .{err});
                    io.tmux_mutex.lockUncancelable(global.io());
                    defer io.tmux_mutex.unlock(global.io());
                    io.terminal_stream.handler.tmux_unlocked_io = true;
                    defer io.terminal_stream.handler.tmux_unlocked_io = false;
                    io.terminal_stream.handler.tmuxForceResync();
                };
            },
            .tmux_track_command => |v| { // ROOTSHELL-TMUX (id=thread-track-command)
                // Record the `.tracked` marker before writing (same
                // rationale as send-keys; id=thread-tmux-write-record-atomic).
                defer v.alloc.free(v.data);
                {
                    io.tmux_mutex.lockUncancelable(global.io());
                    defer io.tmux_mutex.unlock(global.io());
                    io.terminal_stream.handler.recordTmuxTrackedSend();
                }
                io.queueWrite(data, v.data, self.flags.linefeed_mode) catch |err| {
                    // Same stale-marker rationale as send-keys above.
                    log.warn("tmux tracked-command write failed err={}; forcing resync", .{err});
                    io.tmux_mutex.lockUncancelable(global.io());
                    defer io.tmux_mutex.unlock(global.io());
                    io.terminal_stream.handler.tmux_unlocked_io = true;
                    defer io.terminal_stream.handler.tmux_unlocked_io = false;
                    io.terminal_stream.handler.tmuxForceResync();
                };
            },
            .tmux_detach => { // ROOTSHELL-TMUX (id=thread-detach)
                // Same locking rationale as .tmux_set_client_size.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxDetach();
            },
            .tmux_resume => |preferred_window| { // ROOTSHELL-TMUX (id=thread-resume)
                // Hold the renderer mutex around the whole arm, exactly like the
                // read path's unhooked branch: the `.enter` dispatch mutates the
                // gateway terminal (prints the gateway menu) and messageWriter's
                // queue-full path requires the mutex be locked. drainMailbox does
                // NOT hold it (each Termio handler locks it itself), so we must.
                // tmux_mutex nests inside (renderer -> tmux order) because the
                // arm mutates viewer/dcs state (id=termio-tmux-mutex).
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                // Bounded sends while tmux_mutex is held (lock-order rule;
                // id=streamhandler-unlocked-io).
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                if (io.terminal_stream.handler.tmuxResumeShouldEnter(preferred_window)) {
                    // First resume: synthesize control-mode entry. Feeding
                    // `ESC P 1000 p` drives the VT parser into DCS passthrough and
                    // fires the `.enter` dispatch, which creates the viewer (in
                    // resync) and writes the first probe, exactly as a real hook.
                    io.terminal_stream.nextSlice("\x1bP1000p");
                } else {
                    // A viewer already exists: this is a probe RETRY (the app
                    // re-sends until a reconcile arrives). Re-write the probe.
                    io.terminal_stream.handler.tmuxResumeResendProbe();
                }
            },
            .tmux_resume_abort => { // ROOTSHELL-TMUX (id=thread-resume-abort)
                // Same locking rationale as `.tmux_resume`: tearing down the
                // viewer / resetting the parser touches state the renderer reads,
                // and the viewer/dcs/parser pokes need tmux_mutex (renderer ->
                // tmux order).
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                // Bounded sends while tmux_mutex is held (lock-order rule;
                // id=streamhandler-unlocked-io).
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxResumeAbort();
                // Force the VT parser out of DCS passthrough back to ground so
                // the gateway's shell output renders normally; on abort there may
                // be no further bytes to trigger dcsConsumeGroundRequest.
                io.terminal_stream.parser.state = .ground;
            },
            .tmux_flush_deferred => { // ROOTSHELL-TMUX (id=termio-msg-flush-deferred)
                // Heartbeat nudge: retry deferred pane writes / re-send a
                // dropped topology snapshot. Viewer state only — tmux_mutex
                // with the unlocked-io flag, same as .tmux_set_client_size.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxFlushDeferred();
            },
            .tmux_recover => { // ROOTSHELL-TMUX (id=thread-recover)
                // forceResync resets the viewer command pipeline and realigns
                // the control parser — viewer/dcs state only, serialized by
                // tmux_mutex (id=termio-tmux-mutex); the unlocked-io flag makes
                // its messageWriter sends use the bounded no-mutex path. Stay
                // in DCS passthrough — unlike abort, the channel keeps running.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxForceResync();
            },
            .tmux_reprobe => { // ROOTSHELL-TMUX (id=thread-reprobe)
                // Re-send the resync probe ONLY. tmuxResumeResendProbe touches
                // viewer/dcs state and does bounded messageWriter sends, so it
                // needs tmux_mutex (id=termio-tmux-mutex) + the unlocked-io flag,
                // exactly like `.tmux_recover`. It self-guards on a live viewer in
                // `.resync`, so a message draining after the gateway is gone is a
                // plain no-op — unlike `.tmux_resume`, whose no-viewer branch would
                // re-enter control mode. Stay in DCS passthrough.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxResumeResendProbe();
            },
            .tmux_reset => { // ROOTSHELL-TMUX (id=thread-reset)
                // forceReset does everything forceResync does (command pipeline +
                // parser realign — viewer/dcs state only) PLUS flags every pane for
                // recapture; the pane GRID itself is only rewritten LATER when the
                // capture replies arrive on the locked read path, so like
                // `.tmux_recover` this needs only tmux_mutex (id=termio-tmux-mutex)
                // + the unlocked-io flag for its bounded messageWriter sends. Stay
                // in DCS passthrough — the channel keeps running.
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                // Fallback executor for the reset barrier: the read thread may
                // have already consumed the flag (reset-before-parse ordering);
                // in that case this message is a no-op instead of a double
                // reset. ROOTSHELL-TMUX (id=termio-tmux-reset-barrier)
                if (io.tmux_reset_pending.cmpxchgStrong(
                    true,
                    false,
                    .acquire,
                    .monotonic,
                ) == null) {
                    io.terminal_stream.handler.tmux_unlocked_io = true;
                    defer io.terminal_stream.handler.tmux_unlocked_io = false;
                    const preferred_raw = io.tmux_reset_preferred_window.load(.acquire);
                    io.terminal_stream.handler.tmuxForceReset(
                        if (preferred_raw == std.math.maxInt(usize)) null else preferred_raw,
                    );
                }
            },
            .tmux_force_exit => { // ROOTSHELL-TMUX (id=thread-force-exit)
                // Same locking rationale as `.tmux_resume_abort`: tearing down the
                // viewer + emitting the empty-topology snapshot touches state the
                // renderer reads, uses messageWriter, and pokes the VT parser
                // (renderer -> tmux order).
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                io.tmux_mutex.lockUncancelable(global.io());
                defer io.tmux_mutex.unlock(global.io());
                // Bounded sends while tmux_mutex is held (lock-order rule;
                // id=streamhandler-unlocked-io).
                io.terminal_stream.handler.tmux_unlocked_io = true;
                defer io.terminal_stream.handler.tmux_unlocked_io = false;
                io.terminal_stream.handler.tmuxForceExit();
                // Force the VT parser out of DCS passthrough back to ground so the
                // gateway's shell output renders normally (same as resume_abort);
                // there may be no further bytes to trigger dcsConsumeGroundRequest.
                io.terminal_stream.parser.state = .ground;
            },
            .start_synchronized_output => self.startSynchronizedOutput(cb),
            .linefeed_mode => |v| self.flags.linefeed_mode = v,
            .focused => |v| try io.focusGained(data, v),
            .write_small => |v| try io.queueWrite(
                data,
                v.data[0..v.len],
                self.flags.linefeed_mode,
            ),
            .write_stable => |v| try io.queueWrite(
                data,
                v,
                self.flags.linefeed_mode,
            ),
            .write_alloc => |v| {
                defer v.alloc.free(v.data);
                try io.queueWrite(
                    data,
                    v.data,
                    self.flags.linefeed_mode,
                );
            },
        }
    }

    // Trigger a redraw after we've drained so we don't waste cyces
    // messaging a redraw.
    if (redraw) {
        try io.renderer_wakeup.notify();
    }
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;

    // If the timer is already active we just return. In the future we want
    // to reset the timer up to a maximum wait time but for now this ensures
    // relatively smooth resizing.
    if (self.coalesce_c.state() == .active) return;

    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        cb.io.resize(&cb.data, v) catch |err| {
            log.warn("error during resize err={}", .{err});
        };
    }

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}
