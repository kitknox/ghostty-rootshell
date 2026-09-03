//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_file = @import("../lib/compat/file.zig");

const log = std.log.scoped(.io_exec);

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Backend,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// ROOTSHELL-TMUX (id=termio-tmux-mutex): serializes ALL tmux control-mode
/// state on this surface — the viewer, `handler.dcs` while it is `.tmux`,
/// VT-parser-state pokes related to control mode, and the
/// force-unhook/resume/post-exit-drain flags. While the control channel is
/// hooked, `processOutput` parses control bytes under THIS mutex only (not
/// `renderer_state.mutex`), so the control channel's liveness never depends
/// on the gateway renderer or any pane renderer (the attach-wedge fix).
///
/// LOCK ORDER (must never be violated):
///   renderer_state.mutex -> tmux_mutex -> pane renderer mutex
/// i.e. it is legal to take tmux_mutex while holding the renderer mutex and
/// to take a pane's renderer mutex while holding tmux_mutex, but NEVER take
/// renderer_state.mutex while holding tmux_mutex.
tmux_mutex: std.Io.Mutex = .init,

/// ROOTSHELL-TMUX (id=termio-tmux-reset-barrier): an app-requested full reset
/// (`ghostty_surface_tmux_reset`) that has not been executed yet. The API sets
/// this BEFORE queueing the `.tmux_reset` mailbox message; the read thread
/// consumes it (CAS) under tmux_mutex right before parsing hooked control
/// bytes, and the mailbox arm consumes it if the read thread hasn't. This
/// gives the app a call-order guarantee the mailbox alone cannot: any bytes
/// written to the pty AFTER the API call are parsed AFTER the reset, so a
/// foreground replay of known-gapped buffered output is dropped as resync
/// pre-marker noise instead of desyncing the old parser first (the mailbox
/// message and the pipe read otherwise race to tmux_mutex in either order).
tmux_reset_pending: std.atomic.Value(bool) = .init(false),

/// Preferred tmux window for the pending full reset. `maxInt(usize)` means the
/// legacy no-preference behavior. Published before tmux_reset_pending so the
/// read-side reset barrier observes a coherent request.
/// ROOTSHELL-TMUX (id=termio-tmux-reset-priority)
tmux_reset_preferred_window: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.Io.Timestamp = null,

/// State we have for thread enter. This may be null if we don't need
/// to keep track of any state or if its already been freed.
thread_enter_state: ?*ThreadEnterState = null,

/// The state we need to keep around only until we enter the IO
/// thread. Then we can throw it all away.
const ThreadEnterState = struct {
    arena: ArenaAllocator,

    /// Initial input to send to the subprocess after starting. This
    /// memory is freed once the subprocess start is attempted, even
    /// if it fails, because Exec only starts once.
    input: configpkg.io.RepeatableReadableIO,

    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        // If we have no input then we have no thread enter state
        if (config.input.list.items.len == 0) return null;

        // Create our arena allocator
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Allocate our ThreadEnterState
        const ptr = try arena_alloc.create(ThreadEnterState);

        // Copy the input from the config
        const input = try config.input.cloneParsed(arena_alloc);

        // Return the initialized state
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }

    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }

    /// Prepare the inputs for use. Allocations happen on the arena.
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();

        var inputs: std.ArrayList(Input) = try .initCapacity(
            alloc,
            self.input.list.items.len,
        );
        errdefer for (inputs.items) |item| item.deinit();

        for (self.input.list.items) |item| {
            inputs.appendAssumeCapacity(switch (item) {
                .raw => |v| .{ .string = v },
                .path => |path| file: {
                    const f = std.Io.Dir.cwd().openFile(
                        global.io(),
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };

                    break :file .{ .file = f };
                },
            });
        }

        return inputs.items;
    }

    const Input = union(enum) {
        string: []const u8,
        file: std.Io.File,

        fn deinit(self: Input) void {
            switch (self) {
                .string => {},
                .file => |f| f.close(global.io()),
            }
        }
    };
};

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    enquiry_response: []const u8,
    tmux_control_mode: bool, // ROOTSHELL-TMUX (id=termio-derived-config): plumbs tmux-control-mode into DerivedConfig
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .tmux_control_mode = config.@"tmux-control-mode", // ROOTSHELL-TMUX (id=termio-derived-init)
            .conditional_state = config._conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(global.io(), alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback_bytes = opts.full_config.@"scrollback-limit-bytes".optional(),
            .max_scrollback_lines = opts.full_config.@"scrollback-limit-lines".optional(),
            .default_modes = default_modes,
            .default_cursor_style = opts.config.cursor_style,
            .default_cursor_blink = opts.config.cursor_blink,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .init(opts.config.palette),
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = .allWithTempDir(global.tmpDirPath()),
        };
    });
    errdefer term.deinit(alloc);

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    backend.initTerminal(&term);

    // Create our stream handler. This points to memory in self so it
    // isn't safe to use until self.* is set.
    const handler: StreamHandler = .{
        .alloc = alloc,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .tmux_control_mode = opts.config.tmux_control_mode, // ROOTSHELL-TMUX (id=termio-stream-config)
        .enquiry_response = opts.config.enquiry_response,
        // Seed from config so the CSI ?996n reply is correct before the first
        // changeConfig (id=streamhandler-inline-reports).
        .color_scheme_is_dark = opts.config.conditional_state.theme == .dark,
    };

    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = handler,
        }),
        .thread_enter_state = thread_enter_state,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Always free our thread enter state when we're done.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;
    defer if (inputs) |items| {
        for (items) |input| input.deinit();
    };

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);

    // If we have inputs, then queue them all up.
    for (inputs orelse &.{}) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| {
            const contents = compat_file.readToEndAlloc(
                f,
                self.alloc,
                10 * 1024 * 1024, // 10 MiB max
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            };
            defer self.alloc.free(contents);

            self.queueWrite(data, contents, false) catch |err| {
                log.warn("failed to queue input file err={}", .{err});
                return error.InputFailed;
            };
        },
    };
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    // ROOTSHELL-TMUX (id=termio-tmux-mutex): handler.changeConfig reaches the
    // tmux viewer (teardown-on-disable, updateColors, command-queue pump),
    // which is serialized by tmux_mutex (renderer -> tmux lock order). The
    // unlocked-io flag keeps its sends on the bounded no-unlock paths —
    // unlocking/relocking the renderer mutex while holding tmux_mutex would
    // violate the lock order (id=streamhandler-unlocked-io).
    if (comptime StreamHandler.tmux_enabled) {
        self.tmux_mutex.lockUncancelable(global.io());
        defer self.tmux_mutex.unlock(global.io());
        self.terminal_stream.handler.tmux_unlocked_io = true;
        defer self.terminal_stream.handler.tmux_unlocked_io = false;
        self.terminal_stream.handler.changeConfig(&self.config);
    } else {
        self.terminal_stream.handler.changeConfig(&self.config);
    }
    td.backend.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette.
    self.terminal.colors.palette.changeDefault(config.palette);
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // ROOTSHELL-TMUX (id=termio-tmux-pane-theme): a tmux pane renders from the
    // gateway-owned viewer_terminal (threadEnter swaps renderer_state.terminal
    // to it), not self.terminal, so mirror the theme colors there too. Safe
    // under renderer_state.mutex (held above) = this pane's renderer_mutex.
    if (self.backend == .tmux) {
        if (self.backend.tmux.viewer_terminal) |vt| {
            vt.colors.palette.changeDefault(config.palette);
            vt.flags.dirty.palette = true;
            vt.colors.background.default = config.background.toTerminalRGB();
            vt.colors.foreground.default = config.foreground.toTerminalRGB();
            vt.colors.cursor.default = cursor: {
                const color = config.cursor_color orelse break :cursor null;
                break :cursor color.toTerminalRGB() orelse break :cursor null;
            };
        }
    }

    // Set the image limits
    self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    self.size = size;
    const grid_size = size.grid();

    // Update the size of our pty.
    try self.backend.resize(grid_size, size.terminal());

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            .{
                .cols = grid_size.columns,
                .rows = grid_size.rows,
                .cell_size_px = .{
                    .width = self.size.cell.width,
                    .height = self.size.cell.height,
                },
            },
        );

        // For a tmux -CC pane child surface, also forward our exact cell pixel
        // size onto the viewer-owned pane terminal (the one the gateway renders
        // and dispatches images into). The gateway only sizes that terminal in
        // cells, so without this its pixel geometry stays zero and auto-sized
        // iTerm2 images (imgcat) collapse to a 0x0 placement. Done under the
        // renderer mutex (this critical section), which is the pane's renderer
        // mutex. ROOTSHELL-TMUX (id=tmux-pane-pixel-geometry)
        if (self.backend == .tmux) self.backend.tmux.updateViewerPaneCell(
            self.size.cell.width,
            self.size.cell.height,
        );

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }

    // Mail the renderer so that it can update the GPU and re-render
    _ = self.renderer_mailbox.push(global.io(), .{ .resize = size }, .{ .forever = {} });
    self.renderer_wakeup.notify() catch {};
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Clear all Kitty graphics state for this screen. This copies
            // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
            // didn't spend time researching whether it only deletes Kitty
            // graphics that are placed above the cursor or if it deletes
            // all of them. We delete all of them for now but if this behavior
            // isn't fully correct we should fix this later.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.io(),
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        // TODO: fix this
        // self.terminal.markSemanticPrompt(.command);
        // assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.scrollViewport(scroll);
    self.renderer_state.smooth_scroll_y_px = 0;
    self.renderer_state.smooth_scroll_active = false;
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
        self.renderer_state.smooth_scroll_y_px = 0;
        self.renderer_state.smooth_scroll_active = false;
    }

    try self.renderer_wakeup.notify();
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock(global.io());

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // ROOTSHELL-TMUX (id=termio-tmux-process-output): while the tmux control
    // channel is hooked, parse control bytes under tmux_mutex ONLY so the
    // channel's liveness never depends on the gateway renderer mutex or any
    // pane renderer. The helper consumes the control-mode prefix (and the
    // post-force-exit drain) and returns any remainder that must go through
    // the normal locked path (bytes after a clean unhook boundary). The
    // enter/done byte stamps bracket the WHOLE chunk so a block anywhere in
    // either path shows up as done lagging enter with an aging enter stamp.
    if (comptime StreamHandler.tmux_enabled) {
        const h = &self.terminal_stream.handler;
        h.tmuxDbgReadEnter(buf.len);
        defer h.tmuxDbgReadDone(buf.len);

        const rest = self.processOutputTmuxPrefix(buf) orelse return;

        var messaged = false;
        {
            h.tmuxDbgReadSite(.awaiting_gateway_lock, 0);
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            // ROOTSHELL-TMUX (id=termio-tmux-mutex): the unhooked parse may
            // HOOK the control channel mid-chunk (`ESC P 1000 p`) and then run
            // viewer code, so it must also hold tmux_mutex (renderer -> tmux
            // order). Uncontended cost for ordinary surfaces is one
            // lock/unlock per chunk. The unlocked-io flag forces all mailbox
            // writers onto bounded no-unlock sends: the slow paths' renderer
            // unlock/relock while holding tmux_mutex would violate the lock
            // order (ABBA against any renderer -> tmux taker). ROOTSHELL-TMUX
            // (id=streamhandler-unlocked-io)
            self.tmux_mutex.lockUncancelable(global.io());
            defer self.tmux_mutex.unlock(global.io());
            h.tmux_unlocked_io = true;
            defer h.tmux_unlocked_io = false;
            // ROOTSHELL-TMUX (id=streamhandler-parse-liveness): this block is
            // the only unlocked-io context that holds the renderer mutex.
            // Mark it (and expose tmux_mutex) so the send helpers can fall
            // back to the upstream release-and-wait slow path on a full
            // queue while the channel is not hooked, instead of burning
            // bounded retries with the renderer mutex held — the consumers
            // that would drain the queues need that mutex, so the bounded
            // waits can never succeed and the main thread starves.
            h.tmux_renderer_held = true;
            defer h.tmux_renderer_held = false;
            h.tmux_mutex = &self.tmux_mutex;
            defer h.tmux_mutex = null;
            h.tmuxDbgReadSite(.parsing, 0);
            self.processOutputLocked(rest);
            // With the flag set, messageWriter routed its wake signal to the
            // fork-only atomic (upstream's termio_messaged check inside
            // processOutputLocked sees false), so consume it here and notify
            // below, outside the locks.
            messaged = h.tmux_termio_messaged.swap(false, .monotonic);
        }
        if (messaged) self.mailbox.notify();
        return;
    }

    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.processOutputLocked(buf);
}

/// ROOTSHELL-TMUX (id=termio-tmux-process-output): consume the tmux
/// control-mode prefix of `buf` under tmux_mutex only (no renderer mutex):
///
///   1. If a post-force-exit drain is active, discard bytes until the real
///      `%exit` + ST boundary (bounded by budget/deadline) so the swallowed
///      control backlog doesn't paint raw garbage into the revealed shell.
///   2. If the control channel is hooked (`dcs.state == .tmux`), feed bytes
///      one at a time to the stream. Every byte in this state is a `dcs_put`
///      (the fork's parse table pins `dcs_passthrough`), so no handler action
///      can touch the gateway terminal — the renderer mutex is not needed.
///      Pane writes nest pane renderer mutexes under tmux_mutex (lock order).
///   3. On the unhook boundary (clean `%exit`, `.broken`, force-unhook), stop
///      and return the remainder for the normal renderer-locked path.
///
/// Returns null when the chunk was fully consumed.
fn processOutputTmuxPrefix(self: *Termio, buf: []const u8) ?[]const u8 {
    const h = &self.terminal_stream.handler;
    var rem: []const u8 = buf;
    while (true) {
        h.tmuxDbgReadSite(.awaiting_gateway_lock, 0);
        self.tmux_mutex.lockUncancelable(global.io());
        h.tmuxDbgReadSite(.parsing, 0);

        // Post-force-exit drain: swallow the wedged control backlog up to the
        // %exit + ST boundary (or budget/deadline) before normal processing.
        rem = h.tmuxPostExitDrainFeed(rem);
        if (rem.len == 0) {
            h.tmuxDbgReadSite(.idle, 0);
            self.tmux_mutex.unlock(global.io());
            return null;
        }

        if (!h.tmuxControlHooked()) {
            h.tmuxDbgReadSite(.idle, 0);
            self.tmux_mutex.unlock(global.io());
            return rem;
        }

        // Consume a pending app-requested reset BEFORE parsing new bytes, so
        // the reset happens-before any byte written after the API call —
        // regardless of whether the `.tmux_reset` mailbox message has been
        // drained yet. Same lock environment as the mailbox arm (tmux_mutex +
        // unlocked-io). If tmuxForceReset force-exits (probe drop), the loop
        // below sees the unhook and re-enters the drain path. The plain load
        // keeps the per-chunk hot path free of an atomic RMW.
        // ROOTSHELL-TMUX (id=termio-tmux-reset-barrier)
        if (self.tmux_reset_pending.load(.monotonic) and
            self.tmux_reset_pending.cmpxchgStrong(true, false, .acquire, .monotonic) == null)
        {
            h.tmux_unlocked_io = true;
            const preferred_raw = self.tmux_reset_preferred_window.load(.acquire);
            h.tmuxForceReset(if (preferred_raw == std.math.maxInt(usize)) null else preferred_raw);
            h.tmux_unlocked_io = false;
        }

        // Hooked: parse byte-at-a-time under tmux_mutex only. The flag makes
        // messageWriter/surfaceMessageWriter use bounded no-mutex sends (the
        // renderer-mutex unlock/relock slow path would be UB here).
        h.tmux_unlocked_io = true;
        var i: usize = 0;
        while (i < rem.len and h.tmuxControlHooked()) : (i += 1) {
            self.terminal_stream.next(rem[i]);
        }
        h.tmux_unlocked_io = false;
        const messaged = if (comptime StreamHandler.tmux_enabled)
            h.tmux_termio_messaged.swap(false, .monotonic)
        else
            false;
        h.tmuxDbgReadSite(.idle, 0);
        self.tmux_mutex.unlock(global.io());

        // Wake the termio thread outside the lock if the parse queued
        // messages (mirrors processOutputLocked's termio_messaged handling).
        if (messaged) self.mailbox.notify();

        if (i >= rem.len) return null;
        rem = rem[i..];
        // Unhooked mid-chunk: loop re-checks the drain (a force-exit can have
        // armed it) and hooked state; normally it returns the remainder.
    }
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = std.Io.Timestamp.now(global.io(), .awake);
    cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (last.durationTo(now).toMilliseconds() <= 500) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(global.io(), .{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }

    // Terminal content changed on this exact surface. The surface-level
    // pending bit makes this O(1) and coalesces bursts before the app drains.
    self.surface_mailbox.contentChanged();

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}

/// Sends a DSR response for the current color scheme to the pty.
pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const scheme: terminalpkg.device_status.ColorScheme = switch (self.config.conditional_state.theme) {
        .light => .light,
        .dark => .dark,
    };

    var buf: [terminalpkg.device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeColorSchemeReport(&writer, scheme);
    try self.queueWrite(td, writer.buffered(), false);
}

/// Sends a visibility report to the pty. Unforced reports are only sent while
/// DEC mode 2033 is enabled.
pub fn visibilityReport(
    self: *Termio,
    td: *ThreadData,
    visible: bool,
    force: bool,
) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    if (!force and !self.renderer_state.terminal.modes.get(.report_visibility)) {
        return;
    }

    var buf: [terminalpkg.device_status.max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeVisibilityReport(
        &writer,
        if (visible) .potentially_visible else .not_visible,
    );
    try self.queueWrite(td, writer.buffered(), false);
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}
