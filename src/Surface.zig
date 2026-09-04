//! Surface represents a single terminal "surface". A terminal surface is
//! a minimal "widget" where the terminal is drawn and responds to events
//! such as keyboard and mouse. Each surface also creates and owns its pty
//! session.
//!
//! The word "surface" is used because it is left to the higher level
//! application runtime to determine if the surface is a window, a tab,
//! a split, a preview pane in a larger window, etc. This struct doesn't care:
//! it just draws and responds to events. The events come from the application
//! runtime so the runtime can determine when and how those are delivered
//! (i.e. with focus, without focus, and so on).
//!
//! ROOTSHELL-TMUX: this upstream-shared file carries fork-owned tmux control-mode
//! hooks (reconcile dispatch, tmux backend selection, pane message routing).
//! Grep "ROOTSHELL-TMUX" here for every hook; the reconcile-op bodies live in
//! Surface_tmux.zig. See docs/tmux-control-mode-fork.md.
const Surface = @This();

const apprt = @import("apprt.zig");
pub const Mailbox = apprt.surface.Mailbox;
pub const Message = apprt.surface.Message;

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global = @import("global.zig");
const oni = @import("oniguruma");
const crash = @import("crash/main.zig");
const unicode = @import("unicode/main.zig");
const rendererpkg = @import("renderer.zig");
const termio = @import("termio.zig");
const font = @import("font/main.zig");
const Command = @import("Command.zig");
const terminal = @import("terminal/main.zig");
const configpkg = @import("config.zig");
const Duration = configpkg.Config.Duration;
const input = @import("input.zig");
const App = @import("App.zig");
const internal_os = @import("os/main.zig");
const inspectorpkg = @import("inspector/main.zig");
const SurfaceMouse = @import("surface_mouse.zig");
const ProcessInfo = @import("pty.zig").ProcessInfo;

const log = std.log.scoped(.surface);

// The renderer implementation to use.
const Renderer = rendererpkg.Renderer;

/// Minimum window size in cells. This is used to prevent the window from
/// being resized to a size that is too small to be useful. These defaults
/// are chosen to match the default size of Mac's Terminal.app, but is
/// otherwise somewhat arbitrary.
pub const min_window_width_cells: u32 = 10;
pub const min_window_height_cells: u32 = 4;

/// The maximum number of key tables that can be active at any
/// given time. `activate_key_table` calls after this are ignored.
const max_active_key_tables = 8;

/// Unique ID used to identify this surface for IPC purposes. It is
/// exposed to the commands running in surfaces as the environment variable
/// GHOSTTY_SURFACE_ID. It must not be zero as zero is used to incicate a null
/// value when communicating an ID over DBus as DBus does not allow null/maybe
/// values.
id: u64,

/// Allocator
alloc: Allocator,

/// The app that this surface is attached to.
app: *App,

/// The windowing system surface and app.
rt_app: *apprt.runtime.App,
rt_surface: *apprt.runtime.Surface,

/// The font structures
font_grid_key: font.SharedGridSet.Key,
font_size: font.face.DesiredSize,
font_metrics: font.Metrics,

/// Coalesces terminal-content notifications at the source. At most one
/// undrained app-mailbox message exists for a surface at a time.
content_change_pending: std.atomic.Value(bool) = .init(false),

/// This keeps track of if the font size was ever modified. If it wasn't,
/// then config reloading will change the font. If it was manually adjusted,
/// we don't change it on config reload since we assume the user wants
/// a specific size.
font_size_adjusted: bool,

/// Runtime bottom inset in framebuffer pixels (e.g. the iOS home-indicator
/// safe-area strip), applied as extra bottom padding so the grid stays
/// top-aligned and shrinks from the bottom. Persisted here so a font/DPI
/// padding recompute can re-apply it. Set via setBottomInset.
bottom_inset_px: u32 = 0,

/// The renderer for this surface.
renderer: Renderer,

/// The render state
renderer_state: rendererpkg.State,

/// The renderer thread manager
renderer_thread: rendererpkg.Thread,

/// The actual thread
renderer_thr: std.Thread,

/// Mouse state.
mouse: Mouse,

/// Keyboard input state.
keyboard: Keyboard,

/// A currently pressed key. This is used so that we can send a keyboard
/// release event when the surface is unfocused. Note that when the surface
/// is refocused, a key press event may not be sent again -- this depends
/// on the apprt (UI framework) in use, but we want to consistently send
/// a release.
///
/// This is only sent when a keypress event results in a key event being
/// sent to the pty. If it is consumed by a keybinding or other action,
/// this is not set.
///
/// Also note the utf8 value is not valid for this event so some unfocused
/// release events may not send exactly the right data within Kitty keyboard
/// events. This seems unspecified in the spec so for now I'm okay with
/// this. Plus, its only for release events where the key text is far
/// less important.
pressed_key: ?input.KeyEvent = null,

/// The hash value of the last keybinding trigger that we performed. This
/// is only set if the last key input matched a keybinding, consumed it,
/// and performed it. This is used to prevent sending release/repeat events
/// for handled bindings.
last_binding_trigger: u64 = 0,

/// The terminal IO handler.
io: termio.Termio,
io_thread: termio.Thread,
io_thr: std.Thread,

/// Terminal inspector
inspector: ?*inspectorpkg.Inspector = null,

/// All our sizing information.
size: rendererpkg.Size,

/// The configuration derived from the main config. We "derive" it so that
/// we don't have a shared pointer hanging around that we need to worry about
/// the lifetime of. This makes updating config at runtime easier.
config: DerivedConfig,

/// The conditional state of the configuration. This can affect
/// how certain configurations take effect such as light/dark mode.
/// This is managed completely by Ghostty core but an apprt action
/// is sent whenever this changes.
config_conditional_state: configpkg.ConditionalState,

/// This is set to true if our IO thread notifies us our child exited.
/// This is used to determine if we need to confirm, hold open, etc.
child_exited: bool = false,

/// We maintain our focus state and assume we're focused by default.
/// If we're not initially focused then apprts can call focusCallback
/// to let us know.
focused: bool = true,

/// Whether this surface may be visible. Unknown visibility is considered
/// visible so reporting remains conservative.
visible: bool = true,

/// Used to determine whether to continuously scroll.
selection_scroll_active: bool = false,

/// True if the surface is in read-only mode. When read-only, no input
/// is sent to the PTY but terminal-level operations like selections,
/// (native) scrolling, and copy keybinds still work. Warn before quit is
/// always enabled in this state.
readonly: bool = false,

/// Used to send notifications that long running commands have finished.
/// Requires that shell integration be active. Should represent a nanosecond
/// precision timestamp. It does not necessarily need to correspond to the
/// actual time, but we must be able to compare two subsequent timestamps to get
/// the wall clock time that has elapsed between timestamps.
command_timer: ?std.Io.Timestamp = null,

/// Search state
search: ?Search = null,

/// Used to rate limit BEL handling.
last_bell_time: ?std.Io.Timestamp = null,

/// The effect of an input event. This can be used by callers to take
/// the appropriate action after an input event. For example, key
/// input can be forwarded to the OS for further processing if it
/// wasn't handled in any way by Ghostty.
pub const InputEffect = enum {
    /// The input was not handled in any way by Ghostty and should be
    /// forwarded to other subsystems (i.e. the OS) for further
    /// processing.
    ignored,

    /// The input was handled and consumed by Ghostty.
    consumed,

    /// The input resulted in a close event for this surface so
    /// the surface, runtime surface, etc. pointers may all be
    /// unsafe to use so exit immediately.
    closed,
};

/// The search state for the surface.
const Search = struct {
    state: terminal.search.Thread,
    thread: std.Thread,

    pub fn deinit(self: *Search) void {
        // Notify the thread to stop
        self.state.stop.notify() catch |err| log.err(
            "error notifying search thread to stop, may stall err={}",
            .{err},
        );

        // Wait for the OS thread to quit
        self.thread.join();

        // Now it is safe to deinit the state
        self.state.deinit();
    }
};

/// Mouse state for the surface.
const Mouse = struct {
    /// The last tracked mouse button state by button.
    click_state: [input.MouseButton.max]input.MouseButtonState = @splat(.release),

    /// The last mods state when the last mouse button (whatever it was) was
    /// pressed or release.
    mods: input.Mods = .{},

    /// Gesture state for text selection.
    selection_gesture: terminal.SelectionGesture = .init,

    /// The last x/y sent for mouse reports.
    event_point: ?terminal.point.Coordinate = null,

    /// The pressure stage for the mouse. This should always be none if
    /// the mouse is not pressed.
    pressure_stage: input.MousePressureStage = .none,

    /// Pending scroll amounts for high-precision scrolls
    pending_scroll_x: f64 = 0,
    pending_scroll_y: f64 = 0,

    /// True if the mouse is hidden
    hidden: bool = false,

    /// True if the mouse position is currently over a link.
    over_link: bool = false,

    /// The last x/y in the cursor position for links. We use this to
    /// only process link hover events when the mouse actually moves cells.
    link_point: ?terminal.point.Coordinate = null,

    /// Return the left-click pin only if it still belongs to the active screen.
    fn activeLeftClickPin(self: *const Mouse, screens: *const terminal.ScreenSet) ?*terminal.Pin {
        return self.selection_gesture.validatedLeftClickPin(screens);
    }
};

/// Keyboard state for the surface.
pub const Keyboard = struct {
    /// The currently active key sequence for the surface. If this is null
    /// then we're not currently in a key sequence.
    sequence_set: ?*const input.Binding.Set = null,

    /// The queued keys when we're in the middle of a sequenced binding.
    /// These are flushed when the sequence is completed and unconsumed or
    /// invalid.
    ///
    /// This is naturally bounded due to the configuration maximum
    /// length of a sequence.
    sequence_queued: std.ArrayListUnmanaged(termio.Message.WriteReq) = .empty,

    /// The stack of tables that is currently active. The first value
    /// in this is the first activated table (NOT the default keybinding set).
    ///
    /// This is bounded by `max_active_key_tables`.
    table_stack: std.ArrayListUnmanaged(struct {
        set: *const input.Binding.Set,
        once: bool,
    }) = .empty,

    /// The last handled binding. This is used to prevent encoding release
    /// events for handled bindings. We only need to keep track of one because
    /// at least at the time of writing this, its impossible for two keys of
    /// a combination to be handled by different bindings before the release
    /// of the prior (namely since you can't bind modifier-only).
    last_trigger: ?u64 = null,
};

/// The configuration that a surface has, this is copied from the main
/// Config struct usually to prevent sharing a single value.
const DerivedConfig = struct {
    arena: ArenaAllocator,

    /// For docs for these, see the associated config they are derived from.
    original_font_size: f32,
    keybind: configpkg.Keybinds,
    abnormal_command_exit_runtime_ms: u32,
    clipboard_read: configpkg.ClipboardAccess,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_trim_trailing_spaces: bool,
    clipboard_paste_protection: bool,
    clipboard_paste_bracketed_safe: bool,
    clipboard_paste_bracketed_safe_newline: bool,
    clipboard_codepoint_map: configpkg.Config.RepeatableClipboardCodepointMap,
    copy_on_select: configpkg.CopyOnSelect,
    right_click_action: configpkg.RightClickAction,
    middle_click_action: configpkg.MiddleClickAction,
    confirm_close_surface: configpkg.ConfirmCloseSurface,
    cursor_click_to_move: bool,
    desktop_notifications: bool,
    font: font.SharedGridSet.DerivedConfig,
    mouse_interval: u64,
    mouse_hide_while_typing: bool,
    mouse_reporting: bool,
    mouse_scroll_multiplier: configpkg.MouseScrollMultiplier,
    mouse_shift_capture: configpkg.MouseShiftCapture,
    fullscreen: configpkg.Fullscreen,
    macos_non_native_fullscreen: configpkg.NonNativeFullscreen,
    macos_option_as_alt: ?input.OptionAsAlt,
    selection_clear_on_copy: bool,
    selection_clear_on_typing: bool,
    selection_word_chars: []const u21,
    vt_kam_allowed: bool,
    wait_after_command: bool,
    window_padding_top: u32,
    window_padding_bottom: u32,
    window_padding_left: u32,
    window_padding_right: u32,
    window_padding_balance: configpkg.Config.WindowPaddingBalance,
    window_height: u32,
    window_width: u32,
    title: ?[:0]const u8,
    title_report: bool,
    links: []DerivedConfig.Link,
    link_osc8: bool,
    link_previews: configpkg.LinkPreviews,
    scroll_to_bottom: configpkg.Config.ScrollToBottom,
    notify_on_command_finish: configpkg.Config.NotifyOnCommandFinish,
    notify_on_command_finish_action: configpkg.Config.NotifyOnCommandFinishAction,
    notify_on_command_finish_after: Duration,
    key_remaps: input.KeyRemapSet,

    const Link = struct {
        regex: oni.Regex,
        action: input.Link.Action,
        highlight: input.Link.Highlight,
    };

    pub fn init(alloc_gpa: Allocator, config: *const configpkg.Config) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Build all of our links
        const links = links: {
            var links: std.ArrayList(DerivedConfig.Link) = .empty;
            defer links.deinit(alloc);
            for (config.link.links.items) |link| {
                var regex = try link.oniRegex();
                errdefer regex.deinit();
                try links.append(alloc, .{
                    .regex = regex,
                    .action = link.action,
                    .highlight = link.highlight,
                });
            }

            break :links try links.toOwnedSlice(alloc);
        };
        errdefer {
            for (links) |*link| link.regex.deinit();
            alloc.free(links);
        }

        return .{
            .original_font_size = config.@"font-size",
            .keybind = try config.keybind.clone(alloc),
            .abnormal_command_exit_runtime_ms = config.@"abnormal-command-exit-runtime",
            .clipboard_read = config.@"clipboard-read",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_trim_trailing_spaces = config.@"clipboard-trim-trailing-spaces",
            .clipboard_paste_protection = config.@"clipboard-paste-protection",
            .clipboard_paste_bracketed_safe = config.@"clipboard-paste-bracketed-safe",
            .clipboard_paste_bracketed_safe_newline = config.@"clipboard-paste-bracketed-safe-newline",
            .clipboard_codepoint_map = try config.@"clipboard-codepoint-map".clone(alloc),
            .copy_on_select = config.@"copy-on-select",
            .right_click_action = config.@"right-click-action",
            .middle_click_action = config.@"middle-click-action",
            .confirm_close_surface = config.@"confirm-close-surface",
            .cursor_click_to_move = config.@"cursor-click-to-move",
            .desktop_notifications = config.@"desktop-notifications",
            .font = try font.SharedGridSet.DerivedConfig.init(alloc, config),
            .mouse_interval = config.@"click-repeat-interval" * 1_000_000, // 500ms
            .mouse_hide_while_typing = config.@"mouse-hide-while-typing",
            .mouse_reporting = config.@"mouse-reporting",
            .mouse_scroll_multiplier = config.@"mouse-scroll-multiplier",
            .mouse_shift_capture = config.@"mouse-shift-capture",
            .fullscreen = config.fullscreen,
            .macos_non_native_fullscreen = config.@"macos-non-native-fullscreen",
            .macos_option_as_alt = config.@"macos-option-as-alt",
            .selection_clear_on_copy = config.@"selection-clear-on-copy",
            .selection_clear_on_typing = config.@"selection-clear-on-typing",
            .selection_word_chars = try alloc.dupe(u21, config.@"selection-word-chars".codepoints),
            .vt_kam_allowed = config.@"vt-kam-allowed",
            .wait_after_command = config.@"wait-after-command",
            .window_padding_top = config.@"window-padding-y".top_left,
            .window_padding_bottom = config.@"window-padding-y".bottom_right,
            .window_padding_left = config.@"window-padding-x".top_left,
            .window_padding_right = config.@"window-padding-x".bottom_right,
            .window_padding_balance = config.@"window-padding-balance",
            .window_height = config.@"window-height",
            .window_width = config.@"window-width",
            .title = config.title,
            .title_report = config.@"title-report",
            .links = links,
            .link_osc8 = config.@"link-osc8",
            .link_previews = config.@"link-previews",
            .scroll_to_bottom = config.@"scroll-to-bottom",
            .notify_on_command_finish = config.@"notify-on-command-finish",
            .notify_on_command_finish_action = config.@"notify-on-command-finish-action",
            .notify_on_command_finish_after = config.@"notify-on-command-finish-after",
            .key_remaps = try config.@"key-remap".clone(alloc),

            // Assignments happen sequentially so we have to do this last
            // so that the memory is captured from allocs above.
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        for (self.links) |*link| link.regex.deinit();
        self.arena.deinit();
    }

    fn scaledPadding(self: *const DerivedConfig, x_dpi: f32, y_dpi: f32) rendererpkg.Padding {
        const padding_top: u32 = padding_top: {
            const padding_top: f32 = @floatFromInt(self.window_padding_top);
            break :padding_top @intFromFloat(@floor(padding_top * y_dpi / 72));
        };
        const padding_bottom: u32 = padding_bottom: {
            const padding_bottom: f32 = @floatFromInt(self.window_padding_bottom);
            break :padding_bottom @intFromFloat(@floor(padding_bottom * y_dpi / 72));
        };
        const padding_left: u32 = padding_left: {
            const padding_left: f32 = @floatFromInt(self.window_padding_left);
            break :padding_left @intFromFloat(@floor(padding_left * x_dpi / 72));
        };
        const padding_right: u32 = padding_right: {
            const padding_right: f32 = @floatFromInt(self.window_padding_right);
            break :padding_right @intFromFloat(@floor(padding_right * x_dpi / 72));
        };

        return .{
            .top = padding_top,
            .bottom = padding_bottom,
            .left = padding_left,
            .right = padding_right,
        };
    }
};

/// Options for surface initialization that select the termio backend.
/// The default (`tmux_backend == null`) uses the platform auto-selection
/// (pipe on iOS/visionOS, exec on PTY-capable platforms, or pipe when
/// `use_external_io` is set). When `tmux_backend` is set, the surface is
/// a tmux control mode pane whose renderer reads from the viewer-owned
/// pane terminal (single-terminal model).
pub const InitOptions = struct {
    initially_visible: bool = true,
    tmux_backend: ?termio.Tmux.Config = null, // ROOTSHELL-TMUX (id=surface-initoptions-backend)
};

/// Create a new surface. This must be called from the main thread. The
/// pointer to the memory for the surface must be provided and must be
/// stable due to interfacing with various callbacks.
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config_original: *const configpkg.Config,
    app: *App,
    rt_app: *apprt.runtime.App,
    rt_surface: *apprt.runtime.Surface,
) !void {
    return self.initWithOptions(alloc, config_original, app, rt_app, rt_surface, .{});
}

/// Full initialization path with explicit backend selection via `opts`.
/// `init` is a convenience wrapper that uses the default auto-selection.
pub fn initWithOptions(
    self: *Surface,
    alloc: Allocator,
    config_original: *const configpkg.Config,
    app: *App,
    rt_app: *apprt.runtime.App,
    rt_surface: *apprt.runtime.Surface,
    opts: InitOptions,
) !void {
    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    var config_: ?configpkg.Config = config_original.changeConditionalState(
        app.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (config_) |*c| c.deinit();

    // We want a config pointer for everything so we get that either
    // based on our conditional state or the original config.
    const config: *const configpkg.Config = if (config_) |*c| config: {
        // We want to preserve our original working directory. We
        // don't need to dupe memory here because termio will derive
        // it. We preserve this so directory inheritance works.
        c.@"working-directory" = config_original.@"working-directory";
        break :config c;
    } else config_original;

    // Get our configuration
    var derived_config = try DerivedConfig.init(alloc, config);
    errdefer derived_config.deinit();

    // Initialize our renderer with our initialized surface.
    try Renderer.surfaceInit(rt_surface);

    // Determine our DPI configurations so we can properly configure
    // font points to pixels and handle other high-DPI scaling factors.
    const content_scale = try rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    log.debug("xscale={} yscale={} xdpi={} ydpi={}", .{
        content_scale.x,
        content_scale.y,
        x_dpi,
        y_dpi,
    });

    // The font size we desire along with the DPI determined for the surface
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = @intFromFloat(x_dpi),
        .ydpi = @intFromFloat(y_dpi),
    };

    // Setup our font group. This will reuse an existing font group if
    // it was already loaded.
    const font_grid_key, const font_grid = try app.font_grid_set.ref(
        &derived_config.font,
        font_size,
    );

    // Build our size struct which has all the sizes we need.
    const size: rendererpkg.Size = size: {
        var size: rendererpkg.Size = .{
            .screen = screen: {
                const surface_size = try rt_surface.getSize();
                break :screen .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
            },

            .cell = font_grid.cellSize(),
            .padding = .{},
        };

        const explicit: rendererpkg.Padding = derived_config.scaledPadding(
            x_dpi,
            y_dpi,
        );
        if (derived_config.window_padding_balance != .false) {
            size.balancePadding(explicit, derived_config.window_padding_balance);
        } else {
            size.padding = explicit;
        }

        break :size size;
    };

    // Create our terminal grid with the initial size
    const app_mailbox: App.Mailbox = .{ .rt_app = rt_app, .mailbox = &app.mailbox };
    var renderer_impl = try Renderer.init(alloc, .{
        .config = try .init(alloc, config),
        .font_grid = font_grid,
        .size = size,
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        .rt_surface = rt_surface,
        .thread = &self.renderer_thread,
        .initially_visible = opts.initially_visible,
    });
    errdefer renderer_impl.deinit();

    // The mutex used to protect our renderer state.
    const mutex = try alloc.create(std.Io.Mutex);
    mutex.* = .init;
    errdefer alloc.destroy(mutex);

    // Create the renderer thread
    var render_thread = try rendererpkg.Thread.init(
        alloc,
        config,
        rt_surface,
        &self.renderer,
        &self.renderer_state,
        app_mailbox,
        opts.initially_visible,
    );
    errdefer render_thread.deinit();

    // Create the IO thread
    var io_thread = try termio.Thread.init(alloc);
    errdefer io_thread.deinit();

    self.* = .{
        .id = id: {
            while (true) {
                const candidate = candidate: {
                    const rng_impl: std.Random.IoSource = .{ .io = global.io() };
                    const rng = rng_impl.interface();
                    break :candidate rng.int(u64);
                };
                if (candidate == 0) continue;
                break :id candidate;
            }
        },
        .alloc = alloc,
        .app = app,
        .rt_app = rt_app,
        .rt_surface = rt_surface,
        .font_grid_key = font_grid_key,
        .font_size = font_size,
        .font_size_adjusted = false,
        .font_metrics = font_grid.metrics,
        .renderer = renderer_impl,
        .renderer_thread = render_thread,
        .renderer_state = .{
            .mutex = mutex,
            .terminal = &self.io.terminal,
        },
        .renderer_thr = undefined,
        .mouse = .{},
        .keyboard = .{},
        .io = undefined,
        .io_thread = io_thread,
        .io_thr = undefined,
        .size = size,
        .config = derived_config,
        .visible = opts.initially_visible,

        // Our conditional state is initialized to the app state. This
        // lets us get the most likely correct color theme and so on.
        .config_conditional_state = app.config_conditional_state,
    };

    // The command we're going to execute
    const command: ?configpkg.Command = command: {
        if (app.first) {
            if (config.@"initial-command") |command| {
                break :command command;
            }
        }
        break :command config.command;
    };

    // Start our IO implementation
    // This separate block ({}) is important because our errdefers must
    // be scoped here to be valid.
    {
        // Initialize our IO mailbox
        var io_mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer io_mailbox.deinit(alloc);

        // Initialize our IO backend based on platform capabilities and configuration.
        // - If use_external_io is true: always use pipe-based I/O
        // - If use_external_io is false (default):
        //   - On iOS (non-Catalyst) and visionOS: use pipe-based I/O (no PTY support)
        //   - On other platforms (macOS, Linux, Catalyst): use PTY-based I/O (exec)
        const use_external_io = if (@hasField(apprt.runtime.Surface, "use_external_io"))
            rt_surface.use_external_io
        else
            false;

        const backend: termio.backend.Backend = if (opts.tmux_backend) |tmux_config| blk: { // ROOTSHELL-TMUX (id=surface-init-backend-select)
            // Tmux control mode pane: route I/O through the parent surface's
            // tmux control connection. The renderer reads from the viewer-owned
            // pane terminal, so this backend allocates no pty/subprocess.
            break :blk .{ .tmux = termio.Tmux.init(tmux_config) };
        } else if (use_external_io) blk: {
            // Explicitly requested pipe-based I/O
            var io_pipe = try termio.Pipe.init(alloc, .{
                .cwd = if (config.@"working-directory") |wd| wd.value() else null,
            });
            errdefer io_pipe.deinit();
            break :blk .{ .pipe = io_pipe };
        } else if (comptime builtin.os.tag == .ios or
            builtin.os.tag == .visionos)
        blk: {
            // iOS (non-Catalyst) and visionOS: auto-fallback to pipes (no PTY support)
            var io_pipe = try termio.Pipe.init(alloc, .{
                .cwd = if (config.@"working-directory") |wd| wd.value() else null,
            });
            errdefer io_pipe.deinit();
            break :blk .{ .pipe = io_pipe };
        } else blk: {
            // PTY-capable platforms: macOS, Linux, Catalyst.
            // Only the exec backend spawns a child, so only it builds the
            // process environment; the pipe/tmux backends above never touch
            // environ and have nothing to free. ROOTSHELL (id=surface-exec-env-scope)
            var env = rt_surface.defaultTermioEnv() catch |err| env: {
                // If an error occurs, we don't want to block surface startup.
                log.warn("error getting env map for surface err={}", .{err});
                break :env global.environMap() catch std.process.Environ.Map.init(alloc);
            };
            errdefer env.deinit();

            // don't leak GHOSTTY_LOG to any subprocesses
            _ = env.orderedRemove("GHOSTTY_LOG");

            var buf: [18]u8 = undefined;
            try env.put(
                "GHOSTTY_SURFACE_ID",
                std.fmt.bufPrint(&buf, "0x{x:0>16}", .{self.id}) catch unreachable,
            );

            var io_exec = try termio.Exec.init(alloc, .{
                .command = command,
                .env = env,
                .env_override = config.env,
                .shell_integration = config.@"shell-integration",
                .shell_integration_features = config.@"shell-integration-features",
                .cursor_blink = config.@"cursor-style-blink",
                .working_directory = if (config.@"working-directory") |wd| wd.value() else null,
                .resources_dir = global.resourcesDir().host(),
                .term = config.term,
                .rt_pre_exec_info = .init(config),
                .rt_post_fork_info = .init(config),
            });
            errdefer io_exec.deinit();
            break :blk .{ .exec = io_exec };
        };

        try termio.Termio.init(&self.io, alloc, .{
            .size = size,
            .full_config = config,
            .config = try termio.Termio.DerivedConfig.init(alloc, config),
            .backend = backend,
            .mailbox = io_mailbox,
            .renderer_state = &self.renderer_state,
            .renderer_wakeup = render_thread.wakeup,
            .renderer_mailbox = render_thread.mailbox,
            .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        });
    }
    // Outside the block, IO has now taken ownership of our temporary state
    // so we can just defer this and not the subcomponents.
    errdefer self.io.deinit();

    // Keep regular terminal visibility queries/reports consistent before its
    // worker starts. The tmux backend applies the same value to its viewer-owned
    // pane terminal while publishing that pointer in threadEnter.
    self.io.terminal.flags.visible = opts.initially_visible;

    // Report initial cell size on surface creation
    _ = try rt_app.performAction(
        .{ .surface = self },
        .cell_size,
        .{ .width = size.cell.width, .height = size.cell.height },
    );

    _ = try rt_app.performAction(
        .{ .surface = self },
        .size_limit,
        .{
            .min_width = size.cell.width * min_window_width_cells,
            .min_height = size.cell.height * min_window_height_cells,
            // No max:
            .max_width = 0,
            .max_height = 0,
        },
    );

    // Call our size callback which handles all our retina setup
    // Note: this shouldn't be necessary and when we clean up the surface
    // init stuff we should get rid of this. But this is required because
    // sizeCallback does retina-aware stuff we don't do here and don't want
    // to duplicate.
    try self.resize(self.size.screen);

    // Give the renderer one more opportunity to finalize any surface
    // setup on the main thread prior to spinning up the rendering thread.
    try renderer_impl.finalizeSurfaceInit(rt_surface);

    // Start our renderer thread
    self.renderer_thr = try std.Thread.spawn(
        .{},
        rendererpkg.Thread.threadMain,
        .{&self.renderer_thread},
    );
    self.renderer_thr.setName(global.io(), "renderer") catch {};

    // Start our IO thread
    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{ &self.io_thread, &self.io },
    );
    self.io_thr.setName(global.io(), "io") catch {};

    // Determine our initial window size if configured. We need to do this
    // quite late in the process because our height/width are in grid dimensions,
    // so we need to know our cell sizes first.
    //
    // Note: it is important to do this after the renderer is setup above.
    // This allows the apprt to fully initialize the surface before we
    // start messing with the window.
    self.recomputeInitialSize() catch |err| {
        // We don't treat this as a fatal error because not setting
        // an initial size shouldn't stop our terminal from working.
        log.warn("unable to set initial window size: {}", .{err});
    };

    if (config.title) |title| {
        _ = try rt_app.performAction(
            .{ .surface = self },
            .set_title,
            .{ .title = title },
        );
    } else if ((comptime builtin.os.tag == .linux) and
        config.@"_xdg-terminal-exec")
    xdg: {
        // For xdg-terminal-exec execution we special-case and set the window
        // title to the command being executed. This allows window managers
        // to set custom styling based on the command being executed.
        const v = command orelse break :xdg;
        const title = v.string(alloc) catch |err| {
            log.warn(
                "error copying command for title, title will not be set err={}",
                .{err},
            );
            break :xdg;
        };
        defer alloc.free(title);
        _ = try rt_app.performAction(
            .{ .surface = self },
            .set_title,
            .{ .title = title },
        );
    } else if (command) |cmd| switch (cmd) {
        // If a user specifies a command it is appropriate to set the title as argv[0]
        // we know in the case of a direct command it has been supplied by the user
        .direct => |cmd_str| if (cmd_str.len != 0) {
            _ = try rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = cmd_str[0] },
            );
        },

        // We won't set the title in the case the shell expands the command
        // as that should typically be used to launch a shell which should
        // set its own titles
        .shell => {},
    };

    // We are no longer the first surface
    app.first = false;
}

// ROOTSHELL-TMUX BEGIN (id=surface-reconcile-extracted)
// The tmux reconcile-op vocabulary (TmuxReconcileOp, TmuxReconcilePayload) and
// the pure planner functions (planTmuxReconcile / focusTmuxReconcile /
// titleTmuxReconcile + helpers) were extracted to the fork-owned sidecar
// src/Surface_tmux.zig to shrink the tmux footprint in this upstream-shared file.
//
// These two types MUST stay re-exported here: the C ABI path
// `CoreSurface.TmuxReconcile{Op,Payload}` (used by apprt/embedded.zig and
// apprt/action.zig) resolves through `Surface.*`. The planners are called below
// in handleMessage via `tmux_reconcile.planTmuxReconcile(...)` etc.
//
// reapply: if this conflicts on rebase, keep the import + the two pub aliases;
// the bodies live in Surface_tmux.zig. See docs/tmux-control-mode-fork.md.
const tmux_reconcile = @import("Surface_tmux.zig");
pub const TmuxReconcileOp = tmux_reconcile.TmuxReconcileOp;
pub const TmuxReconcilePayload = tmux_reconcile.TmuxReconcilePayload;
// ROOTSHELL-TMUX END (id=surface-reconcile-extracted)

pub fn deinit(self: *Surface) void {
    // Stop search thread
    if (self.search) |*s| s.deinit();

    // Stop rendering thread
    {
        self.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop, may stall err={}", .{err});
        self.renderer_thr.join();

        // We need to become the active rendering thread again
        self.renderer.threadEnter(self.rt_surface) catch unreachable;
    }

    // Stop our IO thread
    {
        self.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop, may stall err={}", .{err});
        self.io_thr.join();
    }

    // On iOS/visionOS, synchronously invalidate the CADisplayLink before
    // we destroy the renderer thread's wakeup mach port. The display link
    // ticks on the main run loop and notifies `thr.draw_now` via a raw
    // pointer; if a queued tick fires after `Thread.deinit` destroys the
    // port, the kernel may have recycled the port name (typically to a
    // libdispatch-guarded port) and the next mach_msg send raises
    // `EXC_GUARD INVALID_OPTIONS`. No-op on other platforms.
    self.renderer.preThreadDeinit();

    // We need to deinit AFTER everything is stopped, since there are
    // shared values between the two threads.
    self.renderer_thread.deinit();
    self.renderer.deinit();
    self.io_thread.deinit();
    self.mouse.selection_gesture.deinit(&self.io.terminal);
    self.io.deinit();

    if (self.inspector) |v| {
        v.deinit(self.alloc);
        self.alloc.destroy(v);
    }

    // Clean up our keyboard state
    for (self.keyboard.sequence_queued.items) |req| req.deinit();
    self.keyboard.sequence_queued.deinit(self.alloc);
    self.keyboard.table_stack.deinit(self.alloc);

    // Clean up our font grid
    self.app.font_grid_set.deref(self.font_grid_key);

    // Clean up our render state
    if (self.renderer_state.preedit) |p| self.alloc.free(p.codepoints);
    self.alloc.destroy(self.renderer_state.mutex);
    self.config.deinit();

    log.info("surface closed id={x}", .{self.id});
}

/// Close this surface. This will trigger the runtime to start the
/// close process, which should ultimately deinitialize this surface.
pub fn close(self: *Surface) void {
    self.rt_surface.close(self.needsConfirmQuit());
}

/// Returns a mailbox that can be used to send messages to this surface.
inline fn surfaceMailbox(self: *Surface) Mailbox {
    return .{
        .surface = self,
        .app = .{ .rt_app = self.rt_app, .mailbox = &self.app.mailbox },
    };
}

/// Queue a message for the IO thread, taking ownership of `msg`.
///
/// We centralize all our logic into this spot so we can intercept
/// messages for example in readonly mode.
fn queueIo(
    self: *Surface,
    msg: termio.Message,
    mutex: termio.Termio.MutexState,
) void {
    // In readonly mode, we don't allow any writes through to the pty.
    if (self.readonly) {
        switch (msg) {
            .write_small,
            .write_stable,
            .write_alloc,
            => {
                msg.deinit();
                return;
            },

            else => {},
        }
    }

    self.io.queueMessage(msg, mutex);
}

/// Forces the surface to render. This is useful for when the surface
/// is in the middle of animation (such as a resize, etc.) or when
/// the render timer is managed manually by the apprt.
pub fn draw(self: *Surface) !void {
    // Renderers are required to support `drawFrame` being called from
    // the main thread, so that they can update contents during resize.
    try self.renderer.drawFrame(true);
}

/// Activate the inspector. This will begin collecting inspection data.
/// This will not affect the GUI. The GUI must use performAction to
/// show/hide the inspector UI.
pub fn activateInspector(self: *Surface) !void {
    if (self.inspector != null) return;

    // Setup the inspector
    const ptr = try self.alloc.create(inspectorpkg.Inspector);
    errdefer self.alloc.destroy(ptr);
    ptr.* = try inspectorpkg.Inspector.init(self.alloc);
    errdefer ptr.deinit(self.alloc);
    self.inspector = ptr;
    errdefer self.inspector = null;

    // Put the inspector onto the render state
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        assert(self.renderer_state.inspector == null);
        self.renderer_state.inspector = self.inspector;
    }

    // Notify our components we have an inspector active
    _ = self.renderer_thread.mailbox.push(global.io(), .{ .inspector = true }, .{ .forever = {} });
    self.queueIo(.{ .inspector = true }, .unlocked);
}

/// Deactivate the inspector and stop collecting any information.
pub fn deactivateInspector(self: *Surface) void {
    const insp = self.inspector orelse return;

    // Remove the inspector from the render state
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        assert(self.renderer_state.inspector != null);
        self.renderer_state.inspector = null;
    }

    // Notify our components we have deactivated inspector
    _ = self.renderer_thread.mailbox.push(global.io(), .{ .inspector = false }, .{ .forever = {} });
    self.queueIo(.{ .inspector = false }, .unlocked);

    // Deinit the inspector
    insp.deinit(self.alloc);
    self.alloc.destroy(insp);
    self.inspector = null;
}

/// True if the surface requires confirmation to quit. This should be called
/// by apprt to determine if the surface should confirm before quitting.
pub fn needsConfirmQuit(self: *Surface) bool {
    // If the surface is in read-only mode, always require confirmation
    if (self.readonly) return true;

    // If the child has exited, then our process is certainly not alive.
    // We check this first to avoid the locking overhead below.
    if (self.child_exited) return false;

    // Check the configuration for confirming close behavior.
    return switch (self.config.confirm_close_surface) {
        .always => true,
        .false => false,
        .true => true: {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            break :true !self.io.terminal.cursorIsAtPrompt();
        },
    };
}

/// Called from a surface IO thread after terminal content changes. This is
/// deliberately nonblocking because callers may hold the renderer mutex.
pub fn queueContentChanged(self: *Surface) void {
    if (!self.app.surfaceContentEventsEnabled()) return;

    if (self.content_change_pending.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .monotonic,
    ) != null) return;

    const mailbox: Mailbox = .{
        .surface = self,
        .app = .{
            .rt_app = self.rt_app,
            .mailbox = &self.app.mailbox,
        },
    };
    if (mailbox.push(.surface_content_changed, .{ .instant = {} }) == 0) {
        self.content_change_pending.store(false, .release);
    }
}

/// Called from the app thread to handle mailbox messages to our specific
/// surface.
pub fn handleMessage(self: *Surface, msg: Message) !void {
    switch (msg) {
        .change_config => |config| try self.updateConfig(config),

        .surface_content_changed => {
            // Clear before dispatch so output arriving during the callback can
            // enqueue the next edge. Re-check the gate because the message may
            // have been queued immediately before detection was disabled.
            self.content_change_pending.store(false, .release);
            if (!self.app.surfaceContentEventsEnabled()) return;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .surface_content_changed,
                {},
            );
        },

        .set_title => |*v| {
            // We ignore the message in case the title was set via config.
            if (self.config.title != null) {
                log.debug("ignoring title change request since static title is set via config", .{});
                return;
            }

            // The ptrCast just gets sliceTo to return the proper type.
            // We know that our title should end in 0.
            const slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(v)), 0);
            log.debug("changing title \"{s}\"", .{slice});
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = slice },
            );
        },

        .report_title => |style| report_title: {
            if (!self.config.title_report) {
                log.info("report_title requested, but disabled via config", .{});
                break :report_title;
            }

            const title: ?[:0]const u8 = self.rt_surface.getTitle();
            const data = switch (style) {
                .csi_21_t => try std.fmt.allocPrint(
                    self.alloc,
                    "\x1b]l{s}\x1b\\",
                    .{title orelse ""},
                ),
            };

            // We always use an allocating message because we don't know
            // the length of the title and this isn't a performance critical
            // path.
            self.queueIo(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = data,
                },
            }, .unlocked);
        },

        .color_change => |change| color_change: {
            // Notify our apprt, but don't send a mode 2031 DSR report
            // because VT sequences were used to change the color.
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .color_change,
                .{
                    .kind = switch (change.target) {
                        .palette => |v| @enumFromInt(v),
                        .dynamic => |dyn| switch (dyn) {
                            .foreground => .foreground,
                            .background => .background,
                            .cursor => .cursor,
                            // Unsupported dynamic color change notification type
                            else => break :color_change,
                        },
                        // Special colors aren't supported for change notification
                        .special => break :color_change,
                    },
                    .r = change.color.r,
                    .g = change.color.g,
                    .b = change.color.b,
                },
            );
        },

        .set_mouse_shape => |shape| {
            log.debug("changing mouse shape: {}", .{shape});
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                shape,
            );
        },

        .clipboard_read => |clipboard| {
            if (self.config.clipboard_read == .deny) {
                log.info("application attempted to read clipboard, but 'clipboard-read' is set to deny", .{});
                return;
            }

            _ = try self.startClipboardRequest(.standard, .{ .osc_52_read = clipboard });
        },

        .clipboard_write => |w| switch (w.req) {
            .small => |v| try self.clipboardWrite(v.data[0..v.len], w.clipboard_type),
            .stable => |v| try self.clipboardWrite(v, w.clipboard_type),
            .alloc => |v| {
                defer v.alloc.free(v.data);
                try self.clipboardWrite(v.data, w.clipboard_type);
            },
        },

        .pwd_change => |w| {
            defer w.deinit();

            var stack = std.heap.stackFallback(256, self.alloc);
            const alloc = stack.get();
            const str = try alloc.dupeZ(u8, w.slice());
            defer alloc.free(str);

            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .pwd,
                .{ .pwd = str },
            );
        },

        .close => self.close(),

        .child_exited => |v| self.childExited(v),

        .desktop_notification => |notification| {
            if (!self.config.desktop_notifications) {
                log.info("application attempted to display a desktop notification, but 'desktop-notifications' is disabled", .{});
                return;
            }

            const title = std.mem.sliceTo(&notification.title, 0);
            const body = std.mem.sliceTo(&notification.body, 0);
            try self.showDesktopNotification(title, body);
        },

        .renderer_health => |health| self.updateRendererHealth(health),

        .scrollbar => |scrollbar| self.updateScrollbar(scrollbar),

        .present_surface => try self.presentSurface(),

        .password_input => |v| try self.passwordInput(v),

        .ring_bell => bell: {
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            if (self.last_bell_time) |last| {
                if (last.durationTo(now).toMilliseconds() < 100) break :bell;
            }
            self.last_bell_time = now;
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .ring_bell,
                {},
            ) catch |err| {
                log.warn("apprt failed to ring bell={}", .{err});
            };
        },

        .progress_report => |v| {
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .progress_report,
                v,
            ) catch |err| {
                log.warn("apprt failed to report progress err={}", .{err});
            };
        },

        .selection_scroll_tick => |active| {
            self.selection_scroll_active = active;
            try self.selectionScrollTick();
        },

        .start_command => {
            self.command_timer = .now(global.io(), .awake);
        },

        .stop_command => |v| timer: {
            const end: std.Io.Timestamp = .now(global.io(), .awake);
            const start = self.command_timer orelse break :timer;
            self.command_timer = null;
            const duration_raw = start.durationTo(end).nanoseconds;
            assert(duration_raw >= 0 and duration_raw <= std.math.maxInt(u64));

            const duration: Duration = .{
                .duration = @as(
                    u64,
                    @intCast(std.math.clamp(start.durationTo(end).nanoseconds, 0, std.math.maxInt(u64))),
                ),
            };
            log.debug("command took {f}", .{duration});

            _ = self.rt_app.performAction(
                .{ .surface = self },
                .command_finished,
                .{
                    .exit_code = v,
                    .duration = duration,
                },
            ) catch |err| {
                log.warn("apprt failed to notify command finish={}", .{err});
            };
        },

        .search_total => |v| {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .search_total,
                .{ .total = v },
            );
        },

        .search_selected => |v| {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .search_selected,
                .{ .selected = v },
            );
        },

        .tmux_topology_changed => |snapshot| { // ROOTSHELL-TMUX (id=surface-arm-topology): plan reconcile -> tmux_reconcile action
            defer snapshot.deinit();
            log.debug("tmux topology changed: {} windows", .{snapshot.windows.len});

            // Plan reconcile ops from the snapshot. The payload is
            // heap-allocated; ownership transfers to the action handler
            // on success, otherwise we clean up here.
            const payload = tmux_reconcile.planTmuxReconcile(
                self.alloc,
                snapshot.windows,
                snapshot.panes,
                snapshot.titles,
            ) catch |err| {
                log.warn("tmux reconcile plan failed: {}", .{err});
                return;
            };
            errdefer payload.deinit();

            // Dispatch to the apprt. On success (callback returns true) the
            // handler OWNS the payload and frees it via
            // ghostty_tmux_reconcile_free after applying the ops. performAction
            // returns the callback's bool: a `false` return means the action was
            // declined / not handled, so ownership did NOT transfer and we must
            // free here. `errdefer` fires only on an ERROR return, not on a
            // `false` value, so without this explicit free the whole payload
            // (ops arena + held pane snapshot-refs) leaks on every reconcile the
            // app declines. ROOTSHELL-TMUX (id=surface-reconcile-free-on-decline)
            if (!try self.rt_app.performAction(
                .{ .surface = self },
                .tmux_reconcile,
                .{ .payload = payload },
            )) payload.deinit();
        },

        .tmux_write_command => |w| { // ROOTSHELL-TMUX (id=surface-arm-write): relay child-pane bytes to parent termio
            // A tmux child pane relayed a command to this (parent) surface.
            // Forward it into our termio mailbox so the parent IO thread
            // writes it to the pty connected to `tmux -CC`.
            //
            // This is the SPSC-safe relay endpoint: the child IO thread
            // posted this message through the app mailbox targeting our
            // surface. We (the app thread) are the only thread calling
            // queueIo, which calls mailbox.send — making the app thread
            // the single producer for this surface's termio mailbox from
            // outside the IO thread.
            //
            // Surface WriteReq.Small holds up to 255 bytes but termio
            // WriteReq.Small holds only 38. Use writeReq() to handle
            // the size decision for the small case; stable and alloc
            // map directly since their layouts are compatible.
            const bytes: []const u8 = switch (w) {
                .small => |v| v.data[0..v.len],
                .stable => |v| v,
                .alloc => |v| v.data,
            };

            // resize-pane / select-pane / select-window are TRACKED commands:
            // route them through the viewer's command queue (via a distinct
            // termio message handled on the IO thread) so their %begin/%end
            // responses don't desync the capture-pane FIFO — an untracked block
            // otherwise mis-matches pane_visible/pane_state and strands a pane
            // on the wrong (scrollback-less) screen on attach. send-keys (typed
            // input / paste) stays on the direct write path below for low
            // keystroke latency: it only fires once a pane is interactive, after
            // the capture sequence, where a stray block is harmless.
            if (!std.mem.startsWith(u8, bytes, "send-keys")) {
                const copy = self.alloc.dupe(u8, bytes) catch null;
                switch (w) {
                    .alloc => |v| v.alloc.free(v.data),
                    else => {},
                }
                if (copy) |c| {
                    self.queueIo(.{ .tmux_pane_command = .{
                        .alloc = self.alloc,
                        .data = c,
                    } }, .unlocked);
                } else {
                    log.warn("tmux pane-command alloc failed, dropping", .{});
                }
                return;
            }

            // ROOTSHELL-TMUX (id=surface-send-keys-untracked): send-keys (typed
            // input / paste / focus reports) go through `.tmux_send_keys` instead
            // of a raw `.write_*`. The IO thread writes them directly (still no
            // command-queue gating — keystroke latency is unchanged) and then
            // records an `.untracked` marker in the viewer's sent-FIFO so the
            // command's %begin/%end ack is matched/swallowed in send-order rather
            // than mis-attributed to an in-flight tracked command (which would
            // desync the response FIFO → garbled list-windows → all tabs pruned).
            // The IO thread records one marker per `\n`-terminated command line
            // (a batched paste carries many lines in one message; see
            // Tmux.queueWrite id=tmux-send-keys-batch). Dupe onto self.alloc
            // (mirrors the .tmux_pane_command branch); the IO thread frees it.
            // Usually a keystroke; can be a full batched paste (~3.1x the
            // pasted bytes), transient and freed after the pty write.
            const sk_copy = self.alloc.dupe(u8, bytes) catch null;
            switch (w) {
                .alloc => |v| v.alloc.free(v.data),
                else => {},
            }
            if (sk_copy) |c| {
                self.queueIo(.{ .tmux_send_keys = .{
                    .alloc = self.alloc,
                    .data = c,
                } }, .unlocked);
            } else {
                log.warn("tmux send-keys alloc failed, dropping", .{});
            }
        },

        .tmux_focus_changed => |fc| { // ROOTSHELL-TMUX (id=surface-arm-focus)
            // A tmux %window-pane-changed notification arrived.
            // Build a minimal reconcile payload with a single
            // set_focus op and dispatch through the existing
            // tmux_reconcile action.
            const payload = tmux_reconcile.focusTmuxReconcile(
                self.alloc,
                fc.window_id,
                fc.pane_id,
            ) catch |err| {
                log.warn("tmux focus reconcile failed: {}", .{err});
                return;
            };
            errdefer payload.deinit();

            // Free on a `false` (declined) return — see id=surface-reconcile-free-on-decline.
            if (!try self.rt_app.performAction(
                .{ .surface = self },
                .tmux_reconcile,
                .{ .payload = payload },
            )) payload.deinit();
        },

        .tmux_title_changed => |tc| { // ROOTSHELL-TMUX (id=surface-arm-title)
            // A tmux %window-renamed or %session-renamed notification
            // arrived. Build a minimal reconcile payload with a single
            // set_tab_title or set_window_title op.
            const payload = tmux_reconcile.titleTmuxReconcile(
                self.alloc,
                tc.tmux_window_id,
                tc.title(),
            ) catch |err| {
                log.warn("tmux title reconcile failed: {}", .{err});
                return;
            };
            errdefer payload.deinit();

            // Free on a `false` (declined) return — see id=surface-reconcile-free-on-decline.
            if (!try self.rt_app.performAction(
                .{ .surface = self },
                .tmux_reconcile,
                .{ .payload = payload },
            )) payload.deinit();
        },

        .tmux_command_response => |resp| { // ROOTSHELL-TMUX (id=surface-arm-command-response)
            // Response to an app-issued tmux query (session dashboard).
            // The callback is synchronous and the body pointer is only
            // borrowed for its duration (the apprt copies what it keeps),
            // so the response can be freed right after dispatch.
            defer resp.deinit();
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .tmux_command_response,
                .{ .tag = resp.tag, .is_err = resp.is_err, .body = resp.body },
            );
        },

        .tmux_sessions_changed => { // ROOTSHELL-TMUX (id=surface-arm-sessions-changed)
            // Session list churn on the tmux server; the apprt refreshes
            // any visible session dashboard.
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .tmux_sessions_changed,
                {},
            );
        },

        .tmux_session_info => |si| { // ROOTSHELL-TMUX (id=surface-arm-session-info)
            // Attached-session identity (startup / switch / rename). The
            // name pointer is borrowed for the callback's duration only.
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .tmux_session_changed,
                .{ .session_id = @intCast(si.session_id), .name = si.name() },
            );
        },
    }
}

fn selectionScrollTick(self: *Surface) !void {
    // If we're no longer active then we don't do anything.
    if (!self.selection_scroll_active) return;

    // If our gesture doesn't want autoscrolling then disable it.
    const was_autoscrolling = self.mouse.selection_gesture.left_drag_autoscroll != .none;
    if (!was_autoscrolling) {
        self.queueIo(
            .{ .selection_scroll = false },
            .unlocked,
        );
        return;
    }

    const pos = try self.rt_surface.getCursorPos();

    // We need our locked state for the remainder
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t: *terminal.Terminal = self.renderer_state.terminal;
    // rootshell(smooth-scroll): convert under the lock so the pixel offset is
    // accounted for in the viewport coordinate used for autoscroll hit-testing.
    const pos_vp = self.posToViewportLocked(pos.x, pos.y);

    const selection = self.mouse.selection_gesture.autoscrollTick(t, .{
        .viewport = pos_vp,
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = SurfaceMouse.isRectangleSelectState(self.mouse.mods),
        .word_boundary_codepoints = self.config.selection_word_chars,
        .geometry = .{
            .columns = @intCast(self.size.grid().columns),
            .cell_width = self.size.cell.width,
            .padding_left = self.size.padding.left,
            .screen_height = self.size.screen.height,
            // rootshell(iOS): keep the bottom autoscroll edge reachable.
            .bottom_autoscroll_threshold = self.bottomAutoscrollThreshold(),
        },
    });

    // rootshell(smooth-scroll): autoscroll jumps the viewport by whole lines,
    // so clear any residual smooth-scroll pixel offset to keep the render aligned.
    self.renderer_state.smooth_scroll_y_px = 0;
    self.renderer_state.smooth_scroll_active = false;

    // If we're no longer autoscrolling for whatever reason, disable it.
    if (self.mouse.selection_gesture.left_drag_autoscroll == .none) {
        self.queueIo(
            .{ .selection_scroll = false },
            .locked,
        );
    }

    // If our left click was invalidated, ignore the result. This isn't
    // strictly necessary but its a nice to have.
    if (self.mouse.selection_gesture.left_click_count == 0) return;

    // We modified our viewport and selection so we need to queue
    // a render.
    try self.setSelection(selection);
    try self.queueRender();
}

fn childExited(self: *Surface, info: apprt.surface.Message.ChildExited) void {
    // Mark our flag that we exited immediately
    self.child_exited = true;

    // If our runtime was below some threshold then we assume that this
    // was an abnormal exit and we show an error message.
    if (info.runtime_ms <= self.config.abnormal_command_exit_runtime_ms) runtime: {
        // On macOS, our exit code detection doesn't work, possibly
        // because of our `login` wrapper. More investigation required.
        if (comptime !builtin.target.os.tag.isDarwin()) {
            // If the exit code is 0 then it was a good exit.
            if (info.exit_code == 0) break :runtime;
        }

        log.warn("abnormal process exit detected, showing error message", .{});

        // Try and show a GUI message. If it returns true, don't do anything else.
        if (self.rt_app.performAction(
            .{ .surface = self },
            .show_child_exited,
            info,
        ) catch |err| gui: {
            log.err("error trying to show native child exited GUI err={}", .{err});
            break :gui false;
        }) return;

        // If a native GUI notification was not shown, update our terminal to
        // note the abnormal exit.
        self.childExitedAbnormally(info) catch |err| {
            log.err("error handling abnormal child exit err={}", .{err});
            return;
        };

        return;
    }

    // We output a message so that the user knows what's going on and
    // doesn't think their terminal just froze. We show this unconditionally
    // on close even if `wait_after_command` is false and the surface closes
    // immediately because if a user does an `undo` to restore a closed
    // surface then they will see this message and know the process has
    // completed.
    terminal: {
        // First try and show a native GUI message.
        if (self.rt_app.performAction(
            .{ .surface = self },
            .show_child_exited,
            info,
        ) catch |err| gui: {
            log.err("error trying to show native child exited GUI err={}", .{err});
            break :gui false;
        }) break :terminal;

        // If the native GUI can't be shown, display a text message in the
        // terminal.
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const t: *terminal.Terminal = self.renderer_state.terminal;
        t.carriageReturn();
        t.linefeed() catch break :terminal;
        t.printString("Process exited. Press any key to close the terminal.") catch
            break :terminal;
        t.modes.set(.cursor_visible, false);

        // We also want to ensure that normal keyboard encoding is on
        // so that we can close the terminal. We close the terminal on
        // any key press that encodes a character.
        t.modes.set(.disable_keyboard, false);
        t.screens.active.kitty_keyboard.set(.set, .disabled);
    }

    // Waiting after command we stop here. The terminal is updated, our
    // state is updated, and now its up to the user to decide what to do.
    if (self.config.wait_after_command) return;

    // If we aren't waiting after the command, then we exit immediately
    // with no confirmation.
    self.close();
}

/// Called when the child process exited abnormally.
fn childExitedAbnormally(
    self: *Surface,
    info: apprt.surface.Message.ChildExited,
) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build up our command for the error message
    const command = try std.mem.join(alloc, " ", switch (self.io.backend) {
        .exec => |*exec| exec.subprocess.args,
        .pipe => &[_][]const u8{"pipe-shell"},
        .tmux => &[_][]const u8{"tmux"},
    });
    const runtime_str = try std.fmt.allocPrint(alloc, "{d} ms", .{info.runtime_ms});

    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t: *terminal.Terminal = self.renderer_state.terminal;

    // No matter what move the cursor back to the column 0.
    t.carriageReturn();

    // Reset styles
    try t.setAttribute(.{ .unset = {} });

    // If there is data in the viewport, we want to scroll down
    // a little bit and write a horizontal rule before writing
    // our message. This lets the use see the error message the
    // command may have output.
    const viewport_str = try t.plainString(alloc);
    if (viewport_str.len > 0) {
        try t.linefeed();
        for (0..t.cols) |_| try t.print(0x2501);
        t.carriageReturn();
        try t.linefeed();
        try t.linefeed();
    }

    // Output our error message
    try t.setAttribute(.{ .@"8_fg" = .bright_red });
    try t.setAttribute(.{ .bold = {} });
    try t.printString("Ghostty failed to launch the requested command:");
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString(command);
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Runtime: ");
    try t.setAttribute(.{ .@"8_fg" = .red });
    try t.printString(runtime_str);
    try t.setAttribute(.{ .unset = {} });

    // We don't print this on macOS because the exit code is always 0
    // due to the way we launch the process.
    if (comptime !builtin.target.os.tag.isDarwin()) {
        const exit_code_str = try std.fmt.allocPrint(alloc, "{d}", .{info.exit_code});
        t.carriageReturn();
        try t.linefeed();
        try t.printString("Exit Code: ");
        try t.setAttribute(.{ .@"8_fg" = .red });
        try t.printString(exit_code_str);
        try t.setAttribute(.{ .unset = {} });
    }

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Press any key to close the window.");

    // Hide the cursor
    t.modes.set(.cursor_visible, false);
}

/// Called when the terminal detects there is a password input prompt.
fn passwordInput(self: *Surface, v: bool) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // If our password input state is unchanged then we don't
        // waste time doing anything more.
        const old = self.io.terminal.flags.password_input;
        if (old == v) return;

        self.io.terminal.flags.password_input = v;
    }

    // Notify our apprt so it can do whatever it wants.
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .secure_input,
        if (v) .on else .off,
    ) catch |err| {
        // We ignore this error because we don't want to fail this
        // entire operation just because the apprt failed to set
        // the secure input state.
        log.warn("apprt failed to set secure input state err={}", .{err});
    };

    try self.queueRender();
}

fn searchCallback(event: terminal.search.Thread.Event, ud: ?*anyopaque) void {
    // IMPORTANT: This function is run on the SEARCH THREAD! It is NOT SAFE
    // to access anything other than values that never change on the surface.
    // The surface is guaranteed to be valid for the lifetime of the search
    // thread.
    const self: *Surface = @ptrCast(@alignCast(ud.?));
    self.searchCallback_(event) catch |err| {
        log.warn("error in search callback err={}", .{err});
    };
}

fn searchCallback_(
    self: *Surface,
    event: terminal.search.Thread.Event,
) !void {
    // NOTE: This runs on the search thread.

    switch (event) {
        .viewport_matches => |matches_unowned| {
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            const matches = try alloc.dupe(terminal.highlight.Flattened, matches_unowned);
            for (matches) |*m| m.* = try m.clone(alloc);

            _ = self.renderer_thread.mailbox.push(
                global.io(),
                .{ .search_viewport_matches = .{
                    .arena = arena,
                    .matches = matches,
                } },
                .forever,
            );
            try self.renderer_thread.wakeup.notify();
        },

        .selected_match => |selected_| {
            if (selected_) |sel| {
                // Copy the flattened match.
                var arena: ArenaAllocator = .init(self.alloc);
                errdefer arena.deinit();
                const alloc = arena.allocator();
                const match = try sel.highlight.clone(alloc);

                _ = self.renderer_thread.mailbox.push(
                    global.io(),
                    .{ .search_selected_match = .{
                        .arena = arena,
                        .match = match,
                    } },
                    .forever,
                );

                // Send the selected index to the surface mailbox
                _ = self.surfaceMailbox().push(
                    .{ .search_selected = sel.idx },
                    .forever,
                );
            } else {
                // Reset our selected match
                _ = self.renderer_thread.mailbox.push(
                    global.io(),
                    .{ .search_selected_match = null },
                    .forever,
                );

                // Reset the selected index
                _ = self.surfaceMailbox().push(
                    .{ .search_selected = null },
                    .forever,
                );
            }

            try self.renderer_thread.wakeup.notify();
        },

        .total_matches => |total| {
            _ = self.surfaceMailbox().push(
                .{ .search_total = total },
                .forever,
            );
        },

        // When we quit, tell our renderer to reset any search state.
        .quit => {
            _ = self.renderer_thread.mailbox.push(
                global.io(),
                .{ .search_selected_match = null },
                .forever,
            );
            _ = self.renderer_thread.mailbox.push(
                global.io(),
                .{ .search_viewport_matches = .{
                    .arena = .init(self.alloc),
                    .matches = &.{},
                } },
                .forever,
            );
            try self.renderer_thread.wakeup.notify();

            // Reset search totals in the surface
            _ = self.surfaceMailbox().push(
                .{ .search_total = null },
                .forever,
            );
            _ = self.surfaceMailbox().push(
                .{ .search_selected = null },
                .forever,
            );
        },

        // Unhandled, so far.
        .complete => {},
    }
}

/// Call this when modifiers change. This is safe to call even if modifiers
/// match the previous state.
///
/// This is not publicly exported because modifier changes happen implicitly
/// on mouse callbacks, key callbacks, etc.
///
/// The renderer state mutex MUST NOT be held.
fn modsChanged(self: *Surface, mods: input.Mods) void {
    // The only place we keep track of mods currently is on the mouse.
    if (!self.mouse.mods.equal(mods)) {
        // The mouse mods only contain binding modifiers since we don't
        // want caps/num lock or sided modifiers to affect the mouse.
        self.mouse.mods = mods.binding();

        // We also need to update the renderer so it knows if it should
        // highlight links. Additionally, mark the screen as dirty so
        // that the highlight state of all links is properly updated.
        {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            self.renderer_state.mouse.mods = self.mouseModsWithCapture(self.mouse.mods);

            // We use the clear screen dirty flag to force a rebuild of all
            // rows because changing mouse mods can affect the highlight state
            // of a link. If there is no link this seems very wasteful but
            // its really only one frame so it's not so bad.
            self.renderer_state.terminal.flags.dirty.clear = true;
        }

        self.queueRender() catch |err| {
            // Not a big deal if this fails.
            log.warn("failed to notify renderer of mods change err={}", .{err});
        };
    }
}

/// Call this whenever the mouse moves or mods changed. The time
/// at which this is called may matter for the correctness of other
/// mouse events (see cursorPosCallback) but this is shared logic
/// for multiple events.
fn mouseRefreshLinks(
    self: *Surface,
    pos: apprt.CursorPos,
    pos_vp: terminal.point.Coordinate,
    over_link: bool,
) !void {
    // If the position is outside our viewport, do nothing
    if (pos.x < 0 or pos.y < 0) return;

    // Update the last point that we checked for links so we don't
    // recheck if the mouse moves some pixels to the same point.
    self.mouse.link_point = pos_vp;

    // We use an arena for everything below to make things easy to clean up.
    // In the case we don't do any allocs this is very cheap to setup
    // (effectively just struct init).
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Get our link at the current position. This returns null if there
    // isn't a link OR if we shouldn't be showing links for some reason
    // (see further comments for cases).
    const link_: ?apprt.action.MouseOverLink, const preview: bool = link: {
        // If we clicked and our mouse moved cells then we never
        // highlight links until the mouse is unclicked. This follows
        // standard macOS and Linux behavior where a click and drag cancels
        // mouse actions.
        const left_idx = @intFromEnum(input.MouseButton.left);
        if (self.mouse.click_state[left_idx] == .press) click: {
            const pin = self.mouse.activeLeftClickPin(&self.uiTerminalLocked().screens) orelse break :click;
            const click_pt = self.uiTerminalLocked().screens.active.pages.pointFromPin(
                .viewport,
                pin.*,
            ) orelse break :click;

            if (!click_pt.coord().eql(pos_vp)) {
                log.debug("mouse moved while left click held, ignoring link hover", .{});
                break :link .{ null, false };
            }
        }

        const link = (try self.linkAtPos(pos)) orelse break :link .{ null, false };
        defer if (link.url) |u| self.alloc.free(u);
        switch (link.action) {
            .open => {
                // Use the pre-computed URL if available (multi-row extended match),
                // otherwise extract from the selection.
                const str = if (link.url) |u|
                    try alloc.dupeZ(u8, u)
                else
                    try self.uiTerminalLocked().screens.active.selectionString(alloc, .{
                        .sel = link.selection,
                        .trim = false,
                    });
                break :link .{
                    .{ .url = str },
                    self.config.link_previews == .true,
                };
            },

            ._open_osc8 => {
                // Show the URL in the status bar
                const pin = link.selection.start();
                const uri = self.osc8URI(pin) orelse {
                    log.warn("failed to get URI for OSC8 hyperlink", .{});
                    break :link .{ null, false };
                };
                break :link .{
                    .{ .url = try alloc.dupeZ(u8, uri) },
                    self.config.link_previews != .false,
                };
            },
        }
    };

    // If we found a link, setup our internal state and notify the
    // apprt so it can highlight it.
    if (link_) |link| {
        self.renderer_state.mouse.point = pos_vp;
        self.mouse.over_link = true;
        self.renderer_state.terminal.screens.active.dirty.hyperlink_hover = true;
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_shape,
            .pointer,
        );

        if (preview) {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                link,
            );
        }

        try self.queueRender();
        return;
    }

    // No link, if we're previously over a link then we need to clear
    // the over-link apprt state.
    if (over_link) {
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_shape,
            self.io.terminal.mouse_shape,
        );
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_over_link,
            .{ .url = "" },
        );
        try self.queueRender();
        return;
    }
}

/// Called when our renderer health state changes.
fn updateRendererHealth(self: *Surface, health: rendererpkg.Health) void {
    log.warn("renderer health status change status={}", .{health});
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .renderer_health,
        health,
    ) catch |err| {
        log.warn("failed to notify app of renderer health change err={}", .{err});
    };
}

/// Called when the scrollbar state changes.
fn updateScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .scrollbar,
        scrollbar,
    ) catch |err| {
        log.warn("failed to notify app of scrollbar change err={}", .{err});
    };
}

/// This should be called anytime `config_conditional_state` changes
/// so that the apprt can reload the configuration.
fn notifyConfigConditionalState(self: *Surface) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .reload_config,
        .{ .soft = true },
    ) catch |err| {
        log.warn("failed to notify app of config state change err={}", .{err});
    };
}

/// Update our configuration at runtime. This can be called by the apprt
/// to set a surface-specific configuration that differs from the app
/// or other surfaces.
pub fn updateConfig(
    self: *Surface,
    original: *const configpkg.Config,
) !void {
    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    var config_: ?configpkg.Config = original.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (config_) |*c| c.deinit();

    // We want a config pointer for everything so we get that either
    // based on our conditional state or the original config.
    const config: *const configpkg.Config = if (config_) |*c| c else original;

    // Update our new derived config immediately
    const derived = DerivedConfig.init(self.alloc, config) catch |err| {
        // If the derivation fails then we just log and return. We don't
        // hard fail in this case because we don't want to error the surface
        // when config fails we just want to keep using the old config.
        log.err("error updating configuration err={}", .{err});
        return;
    };
    self.config.deinit();
    self.config = derived;

    // If our mouse is hidden but we disabled mouse hiding, then show it again.
    if (!self.config.mouse_hide_while_typing and self.mouse.hidden) {
        self.showMouse();
    }

    // If we are in the middle of a key sequence, clear it.
    self.endKeySequence(.drop, .free);

    // Deactivate all key tables since they may have changed. Importantly,
    // we store pointers into the config as part of our table stack so
    // we can't keep them active across config changes. But this behavior
    // also matches key sequences.
    _ = self.deactivateAllKeyTables() catch |err| {
        log.warn("failed to deactivate key tables err={}", .{err});
    };

    // Before sending any other config changes, we give the renderer a new font
    // grid. We could check to see if there was an actual change to the font,
    // but this is easier and pretty rare so it's not a performance concern.
    //
    // (Calling setFontSize builds and sends a new font grid to the renderer.)
    try self.setFontSize(font_size: {
        // If we have manually adjusted the font size, keep it that way.
        if (self.font_size_adjusted) {
            log.info("font size manually adjusted, preserving previous size on config reload", .{});
            break :font_size self.font_size;
        }

        // If we haven't, then we update to the configured font size.
        // This allows config changes to update the font size. We used to
        // never do this but it was a common source of confusion and people
        // assumed that Ghostty was broken! This logic makes more sense.
        var size = self.font_size;
        size.points = std.math.clamp(config.@"font-size", 1.0, 255.0);
        break :font_size size;
    });

    // We need to store our configs in a heap-allocated pointer so that
    // our messages aren't huge.
    var renderer_message = try rendererpkg.Message.initChangeConfig(self.alloc, config);
    errdefer renderer_message.deinit();
    var termio_config_ptr = try self.alloc.create(termio.Termio.DerivedConfig);
    errdefer self.alloc.destroy(termio_config_ptr);
    termio_config_ptr.* = try termio.Termio.DerivedConfig.init(self.alloc, config);
    errdefer termio_config_ptr.deinit();

    _ = self.renderer_thread.mailbox.push(global.io(), renderer_message, .{ .forever = {} });
    self.queueIo(.{
        .change_config = .{
            .alloc = self.alloc,
            .ptr = termio_config_ptr,
        },
    }, .unlocked);

    // With mailbox messages sent, we have to wake them up so they process it.
    self.queueRender() catch |err| {
        log.warn("failed to notify renderer of config change err={}", .{err});
    };

    // If we have a title set then we update our window to have the
    // newly configured title.
    if (config.title) |title| _ = try self.rt_app.performAction(
        .{ .surface = self },
        .set_title,
        .{ .title = title },
    );

    // Notify the window
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .config_change,
        .{ .config = config },
    );
}

const InitialSizeError = error{
    ContentScaleUnavailable,
    AppActionFailed,
};

/// Recalculate the initial size of the window based on the
/// configuration and invoke the apprt `initial_size` action if
/// necessary.
fn recomputeInitialSize(
    self: *Surface,
) InitialSizeError!void {
    // Both width and height must be set for this to work, as
    // documented on the config options.
    if (self.config.window_height <= 0 or
        self.config.window_width <= 0) return;

    const scale = self.rt_surface.getContentScale() catch
        return error.ContentScaleUnavailable;
    const height = @max(
        self.config.window_height,
        min_window_height_cells,
    ) * self.size.cell.height;
    const width = @max(
        self.config.window_width,
        min_window_width_cells,
    ) * self.size.cell.width;
    const width_f32: f32 = @floatFromInt(width);
    const height_f32: f32 = @floatFromInt(height);

    // The final values are affected by content scale and we need to
    // account for the padding so we get the exact correct grid size.
    const final_width: u32 =
        @as(u32, @intFromFloat(@ceil(width_f32 / scale.x))) +
        self.size.padding.left +
        self.size.padding.right;
    const final_height: u32 =
        @as(u32, @intFromFloat(@ceil(height_f32 / scale.y))) +
        self.size.padding.top +
        self.size.padding.bottom;

    _ = self.rt_app.performAction(
        .{ .surface = self },
        .initial_size,
        .{ .width = final_width, .height = final_height },
    ) catch return error.AppActionFailed;
}

/// Represents text read from the terminal and some metadata about it
/// that is often useful to apprts.
pub const Text = struct {
    /// The text that was read from the terminal.
    text: [:0]const u8,

    /// The viewport information about this text, if it is visible in
    /// the viewport.
    viewport: ?Viewport = null,

    pub const Viewport = struct {
        /// The top-left corner of the selection in pixels within the viewport.
        tl_px_x: f64,
        tl_px_y: f64,

        /// The linear offset of the start of the selection and the length.
        /// This is "linear" in the sense that it is the offset in the
        /// flattened viewport as a single array of text.
        ///
        /// Note: these values are currently wrong if there is a partially
        /// visible selection in the viewport (i.e. the top-left or
        /// bottom-right of the selection is outside the viewport). But the
        /// apprt usecase we have right now doesn't require these to be
        /// correct so... let's fix this later. The wrong values will always
        /// be within the text bounds so we aren't risking an overflow.
        offset_start: u32,
        offset_len: u32,
    };

    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

/// Grab the value of text at the given selection point. Note that the
/// selection structure is used as a way to determine the area of the
/// screen to read from, it doesn't have to match the user's current
/// selection state.
///
/// The returned value contains allocated data and must be deinitialized.
pub fn dumpText(
    self: *Surface,
    alloc: Allocator,
    sel: terminal.Selection,
) !Text {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return try self.dumpTextLocked(alloc, sel);
}

/// Same as `dumpText` but assumes the renderer state mutex is already
/// held.
pub fn dumpTextLocked(
    self: *Surface,
    alloc: Allocator,
    sel: terminal.Selection,
) !Text {
    const t: *terminal.Terminal = self.uiTerminalLocked();
    const screen: *terminal.Screen = t.screens.active;

    // Read out the text
    const text = try screen.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
    });
    errdefer alloc.free(text);

    const smooth_extra_rows: usize = if (self.renderer_state.smooth_scroll_active)
        2
    else
        0;

    // Calculate our viewport info if we can.
    const vp: ?Text.Viewport = viewport: {
        // If our bottom right pin is before the viewport, then we can't
        // possibly have this text be within the viewport.
        const vp_tl_pin = screen.pages.getTopLeft(.viewport);
        const br_pin = sel.bottomRight(screen);
        if (br_pin.before(vp_tl_pin)) break :viewport null;

        // If our top-left pin is after the viewport, then we can't possibly
        // have this text be within the viewport.
        const scrollbar = screen.pages.scrollbar();
        const available_rows = scrollbar.total - scrollbar.offset;
        const viewport_rows = @min(
            @as(usize, screen.pages.rows) + smooth_extra_rows,
            available_rows,
        );
        if (viewport_rows == 0) break :viewport null;
        const vp_br_pin = vp_br_pin: {
            var pin = vp_tl_pin.down(viewport_rows - 1) orelse {
                // I don't think this is possible but I don't want to crash on
                // that assertion so let's just break out...
                log.warn("viewport bottom-right pin not found, bug?", .{});
                break :viewport null;
            };
            pin.x = screen.pages.cols - 1;
            break :vp_br_pin pin;
        };
        const tl_pin = sel.topLeft(screen);
        if (vp_br_pin.before(tl_pin)) break :viewport null;

        // We established that our top-left somewhere before the viewport
        // bottom-right and that our bottom-right is somewhere after
        // the top-left. This means that at least some portion of our
        // selection is within the viewport.

        // Our top-left point. If it doesn't exist in the viewport it must
        // be before and we can return (0,0).
        const tl_pt: terminal.Point = screen.pages.pointFromPin(
            .viewport,
            tl_pin,
        ) orelse tl: {
            if (comptime std.debug.runtime_safety) {
                assert(tl_pin.before(vp_tl_pin));
            }

            break :tl .{ .viewport = .{} };
        };

        // Our bottom-right point. If it doesn't exist in the viewport
        // it must be the bottom-right of the viewport.
        const br_pt = screen.pages.pointFromPin(
            .viewport,
            br_pin,
        ) orelse br: {
            if (comptime std.debug.runtime_safety) {
                assert(vp_br_pin.before(br_pin));
            }

            break :br screen.pages.pointFromPin(
                .viewport,
                vp_br_pin,
            ).?;
        };

        const tl_coord = tl_pt.coord();
        const br_coord = br_pt.coord();

        // Our sizes are all scaled so we need to send the unscaled values back.
        const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };
        const x: f64 = x: {
            // Simple x * cell width gives the left
            var x: f64 = @floatFromInt(tl_coord.x * self.size.cell.width);

            // Add padding
            x += @floatFromInt(self.size.padding.left);

            // Scale
            x /= content_scale.x;

            break :x x;
        };
        const y: f64 = y: {
            // Simple y * cell height gives the top
            var y: f64 = @floatFromInt(tl_coord.y * self.size.cell.height);

            // We want the text baseline
            y += @floatFromInt(self.size.cell.height);
            y -= @floatFromInt(self.font_metrics.cell_baseline);

            // Add padding
            y += @floatFromInt(self.size.padding.top);

            // Smooth scrollback is a render-only translation that moves rows
            // upward by this amount. Selection geometry is viewport UI data, so
            // report the visual position rather than the unshifted grid row.
            y -= @max(0, self.renderer_state.smooth_scroll_y_px);

            // Scale
            y /= content_scale.y;

            break :y y;
        };

        // Utilize viewport sizing to convert to offsets
        const start = tl_coord.y * screen.pages.cols + tl_coord.x;
        const end = br_coord.y * screen.pages.cols + br_coord.x;

        break :viewport .{
            .tl_px_x = x,
            .tl_px_y = y,
            .offset_start = start,
            .offset_len = end - start,
        };
    };

    return .{
        .text = text,
        .viewport = vp,
    };
}

/// Returns true if the terminal has a selection.
pub fn hasSelection(self: *const Surface) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t: *terminal.Terminal = switch (self.io.backend) {
        .tmux => self.renderer_state.terminal,
        else => @constCast(&self.io.terminal),
    };
    return t.screens.active.selection != null;
}

/// Returns the selected text. This is allocated.
pub fn selectionString(self: *Surface, alloc: Allocator) !?[:0]const u8 {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
    const sel = screen.selection orelse return null;
    return try screen.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
    });
}

/// Returns the pwd of the terminal, if any. This is always copied because
/// the pwd can change at any point from termio. If we are calling from the IO
/// thread you should just check the terminal directly.
pub fn pwd(
    self: *const Surface,
    alloc: Allocator,
) Allocator.Error!?[]const u8 {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const terminal_pwd = self.io.terminal.getPwd() orelse return null;
    return try alloc.dupe(u8, terminal_pwd);
}

/// Resolves a relative file path to an absolute path using the terminal's pwd.
fn resolvePathForOpening(
    self: *Surface,
    path: []const u8,
) Allocator.Error!?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) {
        const terminal_pwd = self.io.terminal.getPwd() orelse {
            return null;
        };

        const resolved = try std.fs.path.resolve(self.alloc, &.{ terminal_pwd, path });

        std.Io.Dir.accessAbsolute(global.io(), resolved, .{}) catch {
            self.alloc.free(resolved);
            return null;
        };

        return resolved;
    }

    return null;
}

/// Returns the x/y coordinate of where the IME (Input Method Editor)
/// keyboard should be rendered.
pub fn imePoint(self: *const Surface) apprt.IMEPos {
    self.renderer_state.mutex.lockUncancelable(global.io());
    const cursor = self.renderer_state.terminal.screens.active.cursor;
    const preedit_width: usize = if (self.renderer_state.preedit) |preedit| preedit.width() else 0;
    self.renderer_state.mutex.unlock(global.io());

    // TODO: need to handle when scrolling and the cursor is not
    // in the visible portion of the screen.

    // Our sizes are all scaled so we need to send the unscaled values back.
    const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };

    const x: f64 = x: {
        // Simple x * cell width gives the top-left corner, then add padding offset
        var x: f64 = @floatFromInt(cursor.x * self.size.cell.width + self.size.padding.left);

        // We want the midpoint
        x += @as(f64, @floatFromInt(self.size.cell.width)) / 2;

        // And scale it
        x /= content_scale.x;

        break :x x;
    };

    const y: f64 = y: {
        // Simple y * cell height gives the top-left corner, then add padding offset
        var y: f64 = @floatFromInt(cursor.y * self.size.cell.height + self.size.padding.top);

        // We want the bottom
        y += @floatFromInt(self.size.cell.height);

        // And scale it
        y /= content_scale.y;

        break :y y;
    };

    // Our height for now is always just the cell height because our preedit
    // rendering only renders in a single line.
    const height: f64 = height: {
        var height: f64 = @floatFromInt(self.size.cell.height);
        height /= content_scale.y;
        break :height height;
    };
    const width: f64 = width: {
        var width: f64 = @floatFromInt(preedit_width * self.size.cell.width);

        // Our max width is the remaining screen width after the cursor.
        // We don't have to deal with wrapping because the preedit doesn't
        // wrap right now.
        const screen_width: f64 = @floatFromInt(self.size.terminal().width);
        const x_offset: f64 = @floatFromInt((cursor.x + 1) * self.size.cell.width);
        const max = screen_width - x_offset;
        width = @min(width, max);

        // Note: we don't apply content scale here because it looks like
        // for some reason in macOS its already scaled. I'm not sure why
        // that is so I'm going to just leave this comment here so its known
        // that I left this out on purpose pending more investigation.

        break :width width;
    };

    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
}

fn clipboardWrite(self: *const Surface, data: []const u8, loc: apprt.Clipboard) !void {
    if (self.config.clipboard_write == .deny) {
        log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
        return;
    }

    const dec = std.base64.standard.Decoder;

    // Build buffer
    const size = dec.calcSizeForSlice(data) catch |err| switch (err) {
        error.InvalidPadding => {
            log.info("application sent invalid base64 data for OSC 52", .{});
            return;
        },

        // Should not be reachable but don't want to risk it.
        else => return,
    };
    var buf = try self.alloc.allocSentinel(u8, size, 0);
    defer self.alloc.free(buf);
    buf[buf.len] = 0;

    // Decode
    dec.decode(buf, data) catch |err| switch (err) {
        // Ignore this. It is possible to actually have valid data and
        // get this error, so we allow it.
        error.InvalidPadding => {},

        else => {
            log.info("application sent invalid base64 data for OSC 52", .{});
            return;
        },
    };
    assert(buf[buf.len] == 0);

    // When clipboard-write is "ask" a prompt is displayed to the user asking
    // them to confirm the clipboard access. Each app runtime handles this
    // differently.
    const confirm = self.config.clipboard_write == .ask;
    self.rt_surface.setClipboard(loc, &.{.{
        .mime = "text/plain",
        .data = buf,
    }}, confirm) catch |err| {
        log.err("error setting clipboard string err={}", .{err});
        return;
    };
}

fn copySelectionToClipboards(
    self: *Surface,
    sel: terminal.Selection,
    clipboards: []const apprt.Clipboard,
    format: input.Binding.Action.CopyToClipboard,
) !void {
    const t: *terminal.Terminal = self.uiTerminalLocked();
    const screen: *terminal.Screen = t.screens.active;

    // Create an arena to simplify memory management here.
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The options we'll use for all formatting. We'll just override the
    // emit format.
    const opts: terminal.formatter.Options = .{
        .emit = .plain, // We'll override this below
        .unwrap = true,
        .trim = self.config.clipboard_trim_trailing_spaces,
        .codepoint_map = self.config.clipboard_codepoint_map.map.list,
        .background = t.colors.background.get(),
        .foreground = t.colors.foreground.get(),
        .palette = &t.colors.palette.current,
    };

    const ScreenFormatter = terminal.formatter.ScreenFormatter;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    var contents_buf: [2]apprt.ClipboardContent = undefined;
    var contents: std.ArrayList(apprt.ClipboardContent) = .initBuffer(&contents_buf);
    switch (format) {
        .plain => {
            var formatter: ScreenFormatter = .init(screen, opts);
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/plain",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },

        .vt => {
            var formatter: ScreenFormatter = .init(screen, opts: {
                var copy = opts;
                copy.emit = .vt;
                break :opts copy;
            });
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);

            // Note: We don't apply codepoint mappings to VT format since it contains
            // escape sequences that should be preserved as-is
            contents.appendAssumeCapacity(.{
                .mime = "text/plain",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },

        .html => {
            var formatter: ScreenFormatter = .init(screen, opts: {
                var copy = opts;
                copy.emit = .html;
                break :opts copy;
            });
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);

            // Note: We don't apply codepoint mappings to HTML format since HTML
            // has its own character encoding and entity system
            contents.appendAssumeCapacity(.{
                .mime = "text/html",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },

        .mixed => {
            // First, generate plain text with codepoint mappings applied
            var formatter: ScreenFormatter = .init(screen, opts);
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/plain",
                .data = try aw.toOwnedSliceSentinel(0),
            });

            assert(aw.written().len == 0);
            // Second, generate HTML without codepoint mappings
            formatter = .init(screen, opts: {
                var copy = opts;
                copy.emit = .html;

                // We purposely don't emit background/foreground for mixed
                // mode because the HTML contents is often used for rich text
                // input and with trimmed spaces it looks pretty bad.
                copy.background = null;
                copy.foreground = null;

                break :opts copy;
            });
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);

            // Note: We don't apply codepoint mappings to HTML format
            contents.appendAssumeCapacity(.{
                .mime = "text/html",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },
    }

    assert(contents.items.len > 0);
    for (clipboards) |clipboard| self.rt_surface.setClipboard(
        clipboard,
        contents.items,
        false,
    ) catch |err| {
        log.err(
            "error setting clipboard string clipboard={} err={}",
            .{ clipboard, err },
        );
    };
}

/// Set the active selection and notify the apprt on a genuine state
/// transition. All selection mutations route through here rather than
/// `screen.select` directly so the notification fires consistently. To
/// also copy per `copy_on_select`, use `setSelectionAndCopy`.
///
/// This must be called with the renderer mutex held.
///
/// rootshell: kept `pub` (upstream made it private) so the embedded C API
/// `ghostty_surface_set_selection` can route through here and pick up the
/// use-after-free-safe transition + `selection_changed` notification.
pub fn setSelection(self: *Surface, sel_: ?terminal.Selection) !void {
    // Compute the transition before `select` below, which untracks (frees)
    // the previous selection's tracked pins; reading them after would be a
    // use-after-free.
    const prev_ = self.uiTerminalLocked().screens.active.selection;
    const changed = changed: {
        const prev = prev_ orelse break :changed sel_ != null;
        const sel = sel_ orelse break :changed true;
        break :changed !sel.eql(prev);
    };

    try self.uiTerminalLocked().screens.active.select(sel_);

    if (changed) {
        _ = self.rt_app.performAction(
            .{ .surface = self },
            .selection_changed,
            {},
        ) catch |err| {
            log.warn("apprt failed selection_changed notification err={}", .{err});
        };
    }
}

/// Set a selection and, per `copy_on_select`, copy it to the clipboard.
/// For committing selection gestures (mouse release, select-all binding).
///
/// This must be called with the renderer mutex held.
fn setSelectionAndCopy(self: *Surface, sel: terminal.Selection) !void {
    try self.setSelection(sel);

    // If copy on select is false then exit early.
    if (self.config.copy_on_select == .false) return;

    switch (self.config.copy_on_select) {
        .false => unreachable, // handled above with an early exit

        // Both standard and selection clipboards are set.
        .clipboard => try self.copySelectionToClipboards(
            sel,
            &.{ .standard, .selection },
            .mixed,
        ),

        // The selection clipboard is set if supported, otherwise the standard.
        .true => {
            const clipboard: apprt.Clipboard = if (self.rt_surface.supportsClipboard(.selection))
                .selection
            else
                .standard;
            try self.copySelectionToClipboards(
                sel,
                &.{clipboard},
                .mixed,
            );
        },
    }
}

/// Change the cell size for the terminal grid. This can happen as
/// a result of changing the font size at runtime.
fn setCellSize(self: *Surface, size: rendererpkg.CellSize) !void {
    // Update our cell size within our size struct
    self.size.cell = size;
    self.balancePaddingIfNeeded();

    // Notify the terminal
    self.queueIo(.{ .resize = self.size }, .unlocked);

    // Update our terminal default size if necessary.
    self.recomputeInitialSize() catch |err| {
        // We don't treat this as a fatal error because not setting
        // an initial size shouldn't stop our terminal from working.
        log.warn("unable to recompute initial window size: {}", .{err});
    };

    // Notify the window
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .cell_size,
        .{ .width = size.width, .height = size.height },
    );
}

/// Change the font size.
///
/// This can only be called from the main thread.
pub fn setFontSize(self: *Surface, size: font.face.DesiredSize) !void {
    log.debug("set font size size={}", .{size.points});

    // Update our font size so future changes work
    self.font_size = size;

    // We need to build up a new font stack for this font size.
    const font_grid_key, const font_grid = try self.app.font_grid_set.ref(
        &self.config.font,
        self.font_size,
    );
    errdefer self.app.font_grid_set.deref(font_grid_key);

    // Set our cell size
    try self.setCellSize(.{
        .width = font_grid.metrics.cell_width,
        .height = font_grid.metrics.cell_height,
    });

    // Notify our render thread of the new font stack. The renderer
    // MUST accept the new font grid and deref the old.
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .font_grid = .{
            .grid = font_grid,
            .set = &self.app.font_grid_set,
            .old_key = self.font_grid_key,
            .new_key = font_grid_key,
        },
    }, .{ .forever = {} });

    // Once we've sent the key we can replace our key
    self.font_grid_key = font_grid_key;
    self.font_metrics = font_grid.metrics;

    // Schedule render which also drains our mailbox
    self.queueRender() catch unreachable;
}

/// This queues a render operation with the renderer thread. The render
/// isn't guaranteed to happen immediately but it will happen as soon as
/// practical.
pub fn queueRender(self: *Surface) !void {
    try self.renderer_thread.wakeup.notify();
}

/// Terminal used for local UI state such as selection and scrollback reads.
///
/// Tmux pane surfaces render a viewer-owned terminal while their `io.terminal`
/// is only a relay placeholder. Normal surfaces keep upstream behavior.
/// Precondition: the renderer_state mutex must be held.
fn uiTerminalLocked(self: *Surface) *terminal.Terminal {
    return switch (self.io.backend) {
        .tmux => self.renderer_state.terminal,
        else => &self.io.terminal,
    };
}

/// Read-only sibling of `uiTerminalLocked` for `*const Surface` callers,
/// namely the mouse-reporting predicates (`isMouseReporting`,
/// `mouseShiftCapture`, ...). Returns the terminal whose VT state is
/// actually displayed for this surface.
///
/// This matters for mouse reporting: a tmux pane app enabling mouse mode
/// (DECSET 1000/1002/1003/1006) sets `flags.mouse_event`/`mouse_format` on
/// the viewer-owned pane terminal (fed by `%output`), NOT on `io.terminal`,
/// which is an unused relay placeholder for tmux panes. Reading `io.terminal`
/// here would always observe `.none` and silently drop all mouse reports.
///
/// Precondition (tmux only): the renderer_state mutex must be held, since the
/// viewer terminal is mutated by the gateway IO thread under that mutex.
fn uiTerminalLockedConst(self: *const Surface) *const terminal.Terminal {
    return switch (self.io.backend) {
        .tmux => self.renderer_state.terminal,
        else => &self.io.terminal,
    };
}

/// Set a render-only vertical scroll offset in pixels.
pub fn setSmoothScrollOffset(self: *Surface, y_px: f64) !void {
    const offset = if (std.math.isFinite(y_px)) @max(0, y_px) else 0;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        const active = offset > 0;
        if (self.renderer_state.smooth_scroll_y_px == offset and
            self.renderer_state.smooth_scroll_active == active) return;

        self.renderer_state.smooth_scroll_y_px = offset;
        self.renderer_state.smooth_scroll_active = active;
    }

    try self.queueRender();
}

/// Set a render-only signed rubber-band offset in pixels.
pub fn setRubberBandOffset(self: *Surface, y_px: f64) !void {
    const offset = offset: {
        if (!std.math.isFinite(y_px)) break :offset 0;
        const max_abs: f64 = @floatFromInt(self.size.screen.height);
        break :offset @min(@max(y_px, -max_abs), max_abs);
    };
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        if (self.renderer_state.rubber_band_y_px == offset) return;
        self.renderer_state.rubber_band_y_px = offset;
    }

    try self.queueRender();
}

/// Scroll to an absolute row and apply a render-only vertical offset in pixels.
pub fn scrollToRowSmooth(self: *Surface, row: usize, y_px: f64) !void {
    const offset = if (std.math.isFinite(y_px)) @max(0, y_px) else 0;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        const t: *terminal.Terminal = self.renderer_state.terminal;

        // The maximum scrollable top row is the live bottom (the viewport
        // showing the last `len` rows). The iOS scroll bridge encodes the exact
        // bottom as (max_top - 1, one-full-cell offset), and rubber-band
        // overscroll past the bottom keeps sending that. The pixel offset (px)
        // and the cell height share units (both originate from size.cell), so we
        // can recover the requested fractional top row and detect when it lands
        // at or past the live bottom.
        //
        // When it does, treat it as fully bottomed-out: pin the viewport to the
        // active area (the live bottom, which follows new output) with no render
        // offset and smooth scroll inactive. That keeps the reserved bottom
        // inset strip (the iOS home-indicator area) blank instead of flashing
        // the prompt row into it as overscan while the user pushes into the
        // bottom. We scroll to `.active` rather than `.{ .row = max_top }`
        // because PageList.scroll treats `.row = 0` as `.top` (so with no
        // scrollback, max_top == 0 would otherwise pin the top and stop the
        // viewport from following live output). A fractional position strictly
        // above the bottom is genuine scrollback and renders smoothly as before.
        const pre = t.screens.active.pages.scrollbar();
        const max_top: usize = if (pre.total > pre.len) pre.total - pre.len else 0;
        const cell_h: f64 = @floatFromInt(self.size.cell.height);
        const frac: f64 = if (cell_h > 0) offset / cell_h else 0;
        const eff_top: f64 = @as(f64, @floatFromInt(row)) + frac;

        if (eff_top + 1e-6 >= @as(f64, @floatFromInt(max_top))) {
            t.screens.active.scroll(.active);
            self.renderer_state.smooth_scroll_y_px = 0;
            self.renderer_state.smooth_scroll_active = false;
        } else {
            t.screens.active.scroll(.{ .row = row });
            self.renderer_state.smooth_scroll_y_px = offset;
            const scrollbar = t.screens.active.pages.scrollbar();
            self.renderer_state.smooth_scroll_active =
                offset > 0 or scrollbar.offset + scrollbar.len < scrollbar.total;
        }
    }

    try self.queueRender();
}

/// Reserve a bottom inset in framebuffer pixels at the bottom of the surface,
/// e.g. the iOS home-indicator safe-area strip. The inset is applied as extra
/// bottom padding so the terminal grid and the prompt stay where they are while
/// the drawable extends past them; the reserved strip renders blank at rest and
/// is filled by smooth-scroll overscan rows when the viewport is scrolled off
/// the bottom. Only the unbalanced padding path is adjusted, which is the only
/// mode iOS (the sole caller) uses.
pub fn setBottomInset(self: *Surface, px: f64) !void {
    const inset: u32 = if (std.math.isFinite(px))
        @intFromFloat(@min(@max(@round(px), 0), 10000))
    else
        0;
    if (self.bottom_inset_px == inset) return;
    self.bottom_inset_px = inset;

    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.renderer_state.bottom_inset_px = inset;
    }

    if (self.config.window_padding_balance == .false) {
        const content_scale = try self.rt_surface.getContentScale();
        const x_dpi = content_scale.x * font.face.default_dpi;
        const y_dpi = content_scale.y * font.face.default_dpi;
        self.size.padding = self.config.scaledPadding(x_dpi, y_dpi);
        self.size.padding.bottom += inset;
    }

    // Recompute the grid for the new padding and notify the IO thread, then
    // schedule a render so the new overscan count takes effect.
    try self.resize(self.size.screen);
    try self.queueRender();
}

pub fn sizeCallback(self: *Surface, size: apprt.SurfaceSize) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    const new_screen_size: rendererpkg.ScreenSize = .{
        .width = size.width,
        .height = size.height,
    };

    // Update our screen size, but only if it actually changed. And if
    // the screen size didn't change, then our grid size could not have
    // changed, so we just return.
    if (self.size.screen.equals(new_screen_size)) return;

    try self.resize(new_screen_size);
}

fn resize(self: *Surface, size: rendererpkg.ScreenSize) !void {
    // Save our screen size
    self.size.screen = size;
    self.balancePaddingIfNeeded();

    // Recalculate our grid size. Because Ghostty supports fluid resizing,
    // its possible the grid doesn't change at all even if the screen size changes.
    // We have to update the IO thread no matter what because we send
    // pixel-level sizing to the subprocess.
    const grid_size = self.size.grid();
    if (grid_size.columns < 5 and (self.size.padding.left > 0 or self.size.padding.right > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    if (grid_size.rows < 2 and (self.size.padding.top > 0 or self.size.padding.bottom > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }

    // Mail the IO thread
    self.queueIo(.{ .resize = self.size }, .unlocked);
}

/// Recalculate the balanced padding if needed.
fn balancePaddingIfNeeded(self: *Surface) void {
    if (self.config.window_padding_balance == .false) return;
    const content_scale = try self.rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    self.size.balancePadding(self.config.scaledPadding(x_dpi, y_dpi), self.config.window_padding_balance);
}

/// Called to set the preedit state for character input. Preedit is used
/// with dead key states, for example, when typing an accent character.
/// This should be called with null to reset the preedit state.
///
/// The core surface will NOT reset the preedit state on charCallback or
/// keyCallback and we rely completely on the apprt implementation to track
/// the preedit state correctly.
///
/// The preedit input must be UTF-8 encoded.
pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) !void {
    // log.debug("text preeditCallback value={any}", .{preedit_});

    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // We clear our selection when ANY OF:
    // 1. We have an existing preedit
    // 2. We have preedit text
    if (self.renderer_state.preedit != null or
        preedit_ != null)
    {
        if (self.config.selection_clear_on_typing) {
            self.setSelection(null) catch {};
        }
    }

    // We always clear our prior preedit
    if (self.renderer_state.preedit) |p| {
        self.alloc.free(p.codepoints);
        self.renderer_state.preedit = null;
    }

    // Mark preedit dirty flag.
    // ROOTSHELL-TMUX (id=tmux-preedit-dirty): dirty the terminal the renderer
    // actually reads, not io.terminal. For a tmux -CC pane these differ: the
    // renderer reads the gateway-owned viewer pane terminal swapped in via
    // Tmux.threadEnter (io.renderer_state.terminal = vt), while io.terminal is
    // the child surface's own empty terminal that nothing renders. Dirtying
    // io.terminal there never forces a rebuild of the viewer terminal, so the
    // IME preedit overlay (e.g. Korean composition) never drew. For a regular
    // surface renderer_state.terminal == &io.terminal, so this is identical.
    // Safe under renderer_state.mutex (held above), the same mutex the gateway
    // holds when writing the shared viewer terminal (id=tmux-attach-order).
    self.renderer_state.terminal.flags.dirty.preedit = true;

    // If we have no text, we're done. We queue a render in case we cleared
    // a prior preedit (likely).
    const text = preedit_ orelse {
        try self.queueRender();
        return;
    };

    // We convert the UTF-8 text to codepoints.
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();

    // Allocate the codepoints slice
    const Codepoint = rendererpkg.State.Preedit.Codepoint;
    var codepoints: std.ArrayList(Codepoint) = .empty;
    defer codepoints.deinit(self.alloc);
    while (it.nextCodepoint()) |cp| {
        const width: usize = @intCast(unicode.table.get(cp).width);

        // I've never seen a preedit text with a zero-width character. In
        // theory its possible but we can't really handle it right now.
        // Let's just ignore it.
        if (width <= 0) continue;

        try codepoints.append(
            self.alloc,
            .{ .codepoint = cp, .wide = width >= 2 },
        );
    }

    // If we have no codepoints, then we're done.
    if (codepoints.items.len == 0) {
        try self.queueRender();
        return;
    }

    self.renderer_state.preedit = .{
        .codepoints = try codepoints.toOwnedSlice(self.alloc),
    };
    try self.queueRender();
}

/// Returns true if the given key event would trigger a keybinding
/// if it were to be processed. This is useful for determining if
/// a key event should be sent to the terminal or not.
///
/// Note that this function does not check if the binding itself
/// is performable, only if the key event would trigger a binding.
/// If a performable binding is found and the event is not performable,
/// then Ghosty will act as though the binding does not exist.
pub fn keyEventIsBinding(
    self: *Surface,
    event_orig: input.KeyEvent,
) ?input.Binding.Flags {
    // Apply key remappings for consistency with keyCallback
    var event = event_orig;
    if (self.config.key_remaps.isRemapped(event_orig.mods)) {
        event.mods = self.config.key_remaps.apply(event_orig.mods);
    }

    switch (event.action) {
        .release => return null,
        .press, .repeat => {},
    }

    // Look up our entry
    const entry: input.Binding.Set.Entry = entry: {
        // If we're in a sequence, check the sequence set
        if (self.keyboard.sequence_set) |set| {
            break :entry set.getEvent(event) orelse return null;
        }

        // Check active key tables (inner-most to outer-most)
        const table_items = self.keyboard.table_stack.items;
        for (0..table_items.len) |i| {
            const rev_i: usize = table_items.len - 1 - i;
            if (table_items[rev_i].set.getEvent(event)) |entry| {
                break :entry entry;
            }
        }

        // Check the root set
        break :entry self.config.keybind.set.getEvent(event) orelse return null;
    };

    // Return flags based on the
    return switch (entry.value_ptr.*) {
        .leader => .{},
        inline .leaf, .leaf_chained => |v| v.flags,
    };
}

/// Called for any key events. This handles keybindings, encoding and
/// sending to the terminal, etc.
pub fn keyCallback(
    self: *Surface,
    event_orig: input.KeyEvent,
) !InputEffect {
    // log.warn("text keyCallback event={}", .{event_orig});

    // Apply key remappings to transform modifiers before any processing.
    // This allows users to remap modifier keys at the app level.
    var event = event_orig;
    if (self.config.key_remaps.isRemapped(event_orig.mods)) {
        event.mods = self.config.key_remaps.apply(event_orig.mods);
    }

    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Setup our inspector event if we have an inspector.
    var insp_ev: ?inspectorpkg.KeyEvent = if (self.inspector != null) ev: {
        var copy = event;
        copy.utf8 = "";
        if (event.utf8.len > 0) copy.utf8 = try self.alloc.dupe(u8, event.utf8);
        break :ev .{ .event = copy };
    } else null;

    // When we're done processing, we always want to add the event to
    // the inspector.
    defer if (insp_ev) |ev| ev: {
        // We have to check for the inspector again because our keybinding
        // might close it.
        const insp = self.inspector orelse {
            ev.deinit(self.alloc);
            break :ev;
        };

        if (insp.recordKeyEvent(self.alloc, ev)) {
            self.queueRender() catch {};
        } else |err| {
            log.warn("error adding key event to inspector err={}", .{err});
        }
    };

    // Handle keybindings first. We need to handle this on all events
    // (press, repeat, release) because a press may perform a binding but
    // a release should not encode if we consumed the press.
    if (try self.maybeHandleBinding(
        event,
        if (insp_ev) |*ev| ev else null,
    )) |v| return v;
    // If we allow KAM and KAM is enabled then we do nothing.
    if (self.config.vt_kam_allowed) {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.io.terminal.modes.get(.disable_keyboard)) return .consumed;
    }

    // If this input event has text, then we hide the mouse if configured.
    // We only do this on pressed events to avoid hiding the mouse when we
    // change focus due to a keybinding (i.e. switching tabs).
    if (self.config.mouse_hide_while_typing and
        event.action == .press and
        !self.mouse.hidden and
        event.utf8.len > 0)
    {
        self.hideMouse();
    }

    // If our mouse modifiers change we may need to change our
    // link highlight state.
    if (!self.mouse.mods.equal(event.mods)) mouse_mods: {
        // Update our modifiers, this will update mouse mods too
        self.modsChanged(event.mods);

        // We only refresh links if
        // 1. mouse reporting is off
        // OR
        // 2. mouse reporting is on and we are not reporting shift to the terminal
        if (self.io.terminal.flags.mouse_event == .none or
            (self.mouse.mods.shift and !self.mouseShiftCapture(false)) or
            self.mouseLinkModBypass()) // rootshell: bypass mouse capture for link detection with Cmd/Ctrl
        {
            // Refresh our link state
            const pos = self.rt_surface.getCursorPos() catch break :mouse_mods;
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            self.mouseRefreshLinks(
                pos,
                self.posToViewportLocked(pos.x, pos.y),
                self.mouse.over_link,
            ) catch |err| {
                log.warn("failed to refresh links err={}", .{err});
                break :mouse_mods;
            };
        } else if (self.io.terminal.flags.mouse_event != .none and !self.mouse.mods.shift and
            !self.mouseLinkModBypass()) // rootshell: don't clear link state when Cmd/Ctrl held
        {
            // If we have mouse reports on and we don't have shift pressed, we reset state
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                self.io.terminal.mouse_shape,
            );
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                .{ .url = "" },
            );
            try self.queueRender();
        }
    }

    // Process the cursor state logic. This will update the cursor shape if
    // needed, depending on the key state.
    if ((SurfaceMouse{
        .physical_key = event.key,
        .mouse_event = self.io.terminal.flags.mouse_event,
        .mouse_shape = self.io.terminal.mouse_shape,
        .mods = self.mouse.mods,
        .over_link = self.mouse.over_link,
        .hidden = self.mouse.hidden,
    }).keyToMouseShape()) |shape| _ = try self.rt_app.performAction(
        .{ .surface = self },
        .mouse_shape,
        shape,
    );

    // We've processed a key event that produced some data so we want to
    // track the last pressed key.
    self.pressed_key = event: {
        // We need to unset the allocated fields that will become invalid
        var copy = event;
        copy.utf8 = "";

        // If we have a previous pressed key and we're releasing it
        // then we set it to invalid to prevent repeating the release event.
        if (event.action == .release) {
            // if we didn't have a previous event and this is a release
            // event then we just want to set it to null.
            const prev = self.pressed_key orelse break :event null;
            if (prev.key == copy.key) copy.key = .unidentified;
        }

        // If our key is invalid and we have no mods, then we're done!
        // This helps catch the state that we naturally released all keys.
        if (copy.key == .unidentified and copy.mods.empty()) break :event null;

        break :event copy;
    };

    // Encode and send our key. If we didn't encode anything, then we
    // return the effect as ignored.
    if (try self.encodeKey(
        event,
        if (insp_ev) |*ev| ev else null,
    )) |write_req| {
        // If our process is exited and we press a key that results in
        // an encoded value, we close the surface. We want to eventually
        // move this behavior to the apprt probably.
        if (self.child_exited) {
            write_req.deinit();
            self.close();
            return .closed;
        }

        self.queueIo(switch (write_req) {
            .small => |v| .{ .write_small = v },
            .stable => |v| .{ .write_stable = v },
            .alloc => |v| .{ .write_alloc = v },
        }, .unlocked);
    } else {
        // No valid request means that we didn't encode anything.
        return .ignored;
    }

    // If our event is any keypress that isn't a modifier and we generated
    // some data to send to the pty, then we move the viewport down to the
    // bottom. We also clear the selection for any key other then modifiers.
    if (!event.key.modifier()) {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        if (self.config.selection_clear_on_typing or
            event.key == .escape)
        {
            try self.setSelection(null);
        }

        if (self.config.scroll_to_bottom.keystroke) {
            self.io.terminal.scrollViewport(.bottom);
            self.renderer_state.smooth_scroll_y_px = 0;
            self.renderer_state.smooth_scroll_active = false;
        }

        try self.queueRender();
    }

    return .consumed;
}

/// Maybe handles a binding for a given event and if so returns the effect.
/// Returns null if the event is not handled in any way and processing should
/// continue.
fn maybeHandleBinding(
    self: *Surface,
    event: input.KeyEvent,
    insp_ev: ?*inspectorpkg.KeyEvent,
) !?InputEffect {
    switch (event.action) {
        // Release events never trigger a binding but we need to check if
        // we consumed the press event so we don't encode the release.
        .release => {
            if (self.keyboard.last_trigger) |last| {
                if (last == event.bindingHash()) {
                    // We don't reset the last trigger on release because
                    // an apprt may send multiple release events for a single
                    // press event.
                    return .consumed;
                }
            }

            return null;
        },

        // Carry on processing.
        .press, .repeat => {},
    }

    // Find an entry in the keybind set that matches our event.
    const entry: input.Binding.Set.Entry = entry: {
        // Handle key sequences first.
        if (self.keyboard.sequence_set) |set| {
            // Get our entry from the set for the given event.
            if (set.getEvent(event)) |v| break :entry v;

            // No entry found. We need to encode everything up to this
            // point and send to the pty since we're in a sequence.

            // We ignore modifiers so that nested sequences such as
            // ctrl+a>ctrl+b>c work.
            if (event.key.modifier()) return null;

            // If we have a catch-all of ignore, then we special case our
            // invalid sequence handling to ignore it.
            if (self.catchAllIsIgnore()) {
                self.endKeySequence(.drop, .retain);
                return .ignored;
            }

            // Encode everything up to this point
            self.endKeySequence(.flush, .retain);

            return null;
        }

        // No currently active sequence, move on to tables. For tables,
        // we search inner-most table to outer-most. The table stack does
        // NOT include the root set.
        const table_items = self.keyboard.table_stack.items;
        if (table_items.len > 0) {
            for (0..table_items.len) |i| {
                const rev_i: usize = table_items.len - 1 - i;
                const table = table_items[rev_i];
                if (table.set.getEvent(event)) |v| {
                    // If this is a one-shot activation AND its the currently
                    // active table, then we deactivate it after this.
                    // Note: we may want to change the semantics here to
                    // remove this table no matter where it is in the stack,
                    // maybe.
                    if (table.once and i == 0) _ = try self.performBindingAction(
                        .deactivate_key_table,
                    );

                    break :entry v;
                }
            }
        }

        // No table, use our default set
        break :entry self.config.keybind.set.getEvent(event) orelse
            return null;
    };

    // Determine if this entry has an action or if its a leader key.
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        .leader => |set| {
            // Store this event so that we can drain and encode on invalid.
            // We don't need to cap this because it is naturally capped by
            // the config validation.
            if (try self.encodeKey(event, insp_ev)) |req| {
                self.keyboard.sequence_queued.append(self.alloc, req) catch |err| {
                    req.deinit();
                    return err;
                };
            }

            // Setup the next set we'll look at only after all fallible work.
            self.keyboard.sequence_set = set;

            // Start or continue our key sequence
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_sequence,
                .{ .trigger = entry.key_ptr.* },
            ) catch |err| {
                log.warn(
                    "failed to notify app of key sequence err={}",
                    .{err},
                );
            };

            return .consumed;
        },

        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };

    // consumed determines if the input is consumed or if we continue
    // encoding the key (if we have a key to encode).
    const consumed = consumed: {
        // If the consumed flag is explicitly set, then we are consumed.
        if (leaf.flags.consumed) break :consumed true;

        // If the global or all flag is set, we always consume.
        if (leaf.flags.global or leaf.flags.all) break :consumed true;

        break :consumed false;
    };

    // We have an action, so at this point we're handling SOMETHING so
    // we reset the last trigger to null. We only set this if we actually
    // perform an action (below)
    self.keyboard.last_trigger = null;

    // An action also always resets the sequence set.
    self.keyboard.sequence_set = null;

    // Setup our actions
    const actions = leaf.actionsSlice();

    // Attempt to perform the action
    log.debug("key event binding flags={} action={any}", .{
        leaf.flags,
        actions,
    });
    const performed = performed: {
        // If this is a global or all action, then we perform it on
        // the app and it applies to every surface.
        if (leaf.flags.global or leaf.flags.all) {
            self.app.performAllChainedAction(
                self.rt_app,
                actions,
            );

            // "All" actions are always performed since they are global.
            break :performed true;
        }

        // Perform each action. We are performed if ANY of the chained
        // actions perform.
        var performed: bool = false;
        for (actions) |action| {
            if (self.performBindingAction(action)) |v| {
                performed = performed or v;
            } else |err| {
                log.info(
                    "key binding action failed action={t} err={}",
                    .{ action, err },
                );
            }
        }

        break :performed performed;
    };

    if (performed) {
        // If we performed an action and it was a closing action,
        // our "self" pointer is not safe to use anymore so we need to
        // just exit immediately.
        for (actions) |action| if (closingAction(action)) {
            log.debug("key binding is a closing binding, halting key event processing", .{});
            return .closed;
        };

        // If our action was "ignore" then we return the special input
        // effect of "ignored".
        for (actions) |action| if (action == .ignore) {
            // If we're in a sequence, clear it.
            self.endKeySequence(.drop, .retain);

            return .ignored;
        };
    }

    // If we have the performable flag and the action was not performed,
    // then we act as though a binding didn't exist.
    if (leaf.flags.performable and !performed) {
        // If we're in a sequence, we treat this as if we pressed a key
        // that doesn't exist in the sequence. Reset our sequence and flush
        // any queued events.
        self.endKeySequence(.flush, .retain);

        return null;
    }

    // If we consume this event, then we are done. If we don't consume
    // it, we processed the action but we still want to process our
    // encodings, too.
    if (consumed) {
        // If we had queued events, we deinit them since we consumed
        self.endKeySequence(.drop, .retain);

        // Store our last trigger so we don't encode the release event
        self.keyboard.last_trigger = event.bindingHash();

        if (insp_ev) |ev| {
            ev.binding = self.alloc.dupe(
                input.Binding.Action,
                actions,
            ) catch |err| binding: {
                log.warn(
                    "error allocating binding action for inspector err={}",
                    .{err},
                );
                break :binding &.{};
            };
        }
        return .consumed;
    }

    // If we didn't perform OR we didn't consume, then we want to
    // encode any queued events for a sequence.
    self.endKeySequence(.flush, .retain);

    return null;
}

fn deactivateAllKeyTables(self: *Surface) !bool {
    switch (self.keyboard.table_stack.items.len) {
        // No key table active. This does nothing.
        0 => return false,

        // Clear the entire table stack.
        else => self.keyboard.table_stack.clearAndFree(self.alloc),
    }

    // Notify the UI.
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .key_table,
        .deactivate_all,
    ) catch |err| {
        log.warn(
            "failed to notify app of key table err={}",
            .{err},
        );
    };

    return true;
}

/// This checks if the current keybinding sets have a catch_all binding
/// with `ignore`. This is used to determine some special input cases.
fn catchAllIsIgnore(self: *Surface) bool {
    // Get our catch all
    const entry: input.Binding.Set.Entry = entry: {
        const trigger: input.Binding.Trigger = .{ .key = .catch_all };

        const table_items = self.keyboard.table_stack.items;
        for (0..table_items.len) |i| {
            const rev_i: usize = table_items.len - 1 - i;
            const entry = table_items[rev_i].set.get(trigger) orelse continue;
            break :entry entry;
        }

        break :entry self.config.keybind.set.get(trigger) orelse
            return false;
    };

    // We have a catch-all entry, see if its an ignore
    return switch (entry.value_ptr.*) {
        .leader => false,
        .leaf => |leaf| leaf.action == .ignore,
        .leaf_chained => |leaf| chained: for (leaf.actions.items) |action| {
            if (action == .ignore) break :chained true;
        } else false,
    };
}

const KeySequenceQueued = enum { flush, drop };
const KeySequenceMemory = enum { retain, free };

/// End a key sequence. Safe to call if no key sequence is active.
///
/// Action and mem determine the behavior of the queued inputs up to this
/// point.
fn endKeySequence(
    self: *Surface,
    action: KeySequenceQueued,
    mem: KeySequenceMemory,
) void {
    // Notify apprt key sequence ended
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .key_sequence,
        .end,
    ) catch |err| {
        log.warn(
            "failed to notify app of key sequence end err={}",
            .{err},
        );
    };

    // No matter what we clear our current sequence set. This restores
    // the set we look at to the root set.
    self.keyboard.sequence_set = null;

    // If we have no queued data, there is nothing else to do.
    if (self.keyboard.sequence_queued.items.len == 0) return;

    // Run the proper action first
    switch (action) {
        .flush => for (self.keyboard.sequence_queued.items) |write_req| {
            self.queueIo(switch (write_req) {
                .small => |v| .{ .write_small = v },
                .stable => |v| .{ .write_stable = v },
                .alloc => |v| .{ .write_alloc = v },
            }, .unlocked);
        },

        .drop => for (self.keyboard.sequence_queued.items) |req| req.deinit(),
    }

    // Memory handling of the sequence after the action
    switch (mem) {
        .free => self.keyboard.sequence_queued.clearAndFree(self.alloc),
        .retain => self.keyboard.sequence_queued.clearRetainingCapacity(),
    }
}

/// Encodes the key event into a write request. The write request will
/// always copy or allocate so the caller can safely free the event.
fn encodeKey(
    self: *Surface,
    event: input.KeyEvent,
    insp_ev: ?*inspectorpkg.KeyEvent,
) !?termio.Message.WriteReq {
    const write_req: termio.Message.WriteReq = req: {
        // Build our encoding options, which requires the lock.
        const encoding_opts = self.encodeKeyOpts();

        // Try to write the input into a small array. This fits almost
        // every scenario. Larger situations can happen due to long
        // pre-edits.
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        if (input.key_encode.encode(
            &writer,
            event,
            encoding_opts,
        )) {
            const written = writer.buffered();

            // Special-case: we did nothing.
            if (written.len == 0) return null;

            break :req .{ .small = .{
                .data = data,
                .len = @intCast(written.len),
            } };
        } else |err| switch (err) {
            // Means we need to allocate
            error.WriteFailed => {},
        }

        // We need to allocate. We allocate double the UTF-8 length
        // or double the small array size, whichever is larger. That's
        // a heuristic that should work. The only scenario I know while
        // typing this where we don't have enough space is a long preedit,
        // and in that case the size we need is exactly the UTF-8 length,
        // so the double is being safe.
        var alloc_writer: std.Io.Writer.Allocating = try .initCapacity(
            self.alloc,
            @max(event.utf8.len * 2, data.len * 2),
        );
        defer alloc_writer.deinit();

        try input.key_encode.encode(
            &alloc_writer.writer,
            event,
            encoding_opts,
        );
        break :req .{ .alloc = .{
            .alloc = self.alloc,
            .data = try alloc_writer.toOwnedSlice(),
        } };
    };

    // Copy the encoded data into the inspector event if we have one.
    // We do this before the mailbox because the IO thread could
    // release the memory before we get a chance to copy it.
    if (insp_ev) |ev| pty: {
        const slice = write_req.slice();
        const copy = self.alloc.alloc(u8, slice.len) catch |err| {
            log.warn("error allocating pty data for inspector err={}", .{err});
            break :pty;
        };
        errdefer self.alloc.free(copy);
        @memcpy(copy, slice);
        ev.pty = copy;
    }

    return write_req;
}

fn encodeKeyOpts(self: *const Surface) input.key_encode.Options {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t = &self.io.terminal;

    var opts: input.key_encode.Options = .fromTerminal(t);
    if (comptime builtin.os.tag != .macos) return opts;

    opts.macos_option_as_alt = self.config.macos_option_as_alt orelse detect: {
        // If we don't have alt pressed, it doesn't matter what this
        // config is so we can just say "false" and break out and avoid
        // more expensive checks below.
        if (!self.mouse.mods.alt) break :detect .false;

        // Alt is pressed, we're on macOS. We break some encapsulation
        // here and assume libghostty for ease...
        break :detect self.rt_app.keyboardLayout().detectOptionAsAlt();
    };

    return opts;
}

/// Sends text as-is to the terminal without triggering any keyboard
/// protocol. This will treat the input text as if it was pasted
/// from the clipboard so the same logic will be applied. Namely,
/// if bracketed mode is on this will do a bracketed paste. Otherwise,
/// this will filter newlines to '\r'.
pub fn textCallback(self: *Surface, text: []const u8) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    try self.completeClipboardPaste(text, true);
}

/// Write raw, already-encoded input bytes directly to this surface's IO,
/// bypassing the clipboard-paste path used by `textCallback` (no bracketed-
/// paste framing, no paste-protection filtering). This is the correct entry
/// for pre-encoded terminal byte sequences such as control keys (backspace
/// `0x7f`, arrows, `Ctrl-*`). For a tmux control-mode pane the bytes are
/// relayed verbatim as `send-keys -H` to tmux; for a normal surface they go
/// to the pty. Used by the embedded apprt for tmux pane input, where the apprt
/// has already encoded the key event into terminal bytes.
pub fn sendInput(self: *Surface, data: []const u8) !void {
    if (data.len == 0) return;
    const req = try termio.Message.writeReq(self.alloc, data);
    self.queueIo(req, .unlocked);
}

/// Callback for when the surface is fully visible or not, regardless
/// of focus state. This is used to pause rendering when the surface
/// is not visible, and also re-render when it becomes visible again.
pub fn occlusionCallback(self: *Surface, visible: bool) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Avoid duplicate renderer and visibility reports.
    if (self.visible == visible) return;
    self.visible = visible;

    // Update the terminal state for synchronous queries, then notify the IO
    // thread so it can emit a mode 2033 report when enabled.
    //
    // ROOTSHELL-TMUX (id=tmux-pane-visibility): this is VT state a program
    // reads back via DSR, so it belongs to the terminal the program is
    // actually attached to. For a tmux -CC pane that is the viewer-owned pane
    // terminal, NOT `io.terminal`, which is an empty relay placeholder — the
    // same reason paste options are read from it (id=tmux-pane-paste-terminal).
    self.renderer_state.mutex.lockUncancelable(global.io());
    const vis_term = self.uiTerminalLocked();
    vis_term.flags.visible = visible;
    const report_visibility = vis_term.modes.get(.report_visibility);
    self.renderer_state.mutex.unlock(global.io());
    if (report_visibility) {
        self.queueIo(.{ .visibility_report = .{
            .visible = visible,
            .force = false,
        } }, .unlocked);
    }

    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .visible = visible,
    }, .{ .forever = {} });

    try self.queueRender();
}

/// Synchronously pause this surface's rendering pipeline before iOS
/// suspends the app. Combines:
///
///   1. Pushing `visible: false` to the renderer thread (so subsequent
///      drawFrame calls become no-ops and the IOSDisplayLink is stopped).
///   2. Pushing a `drain_to_idle` ack the renderer signals after both
///      messages have been processed by `drainMailbox`.
///   3. Waiting on that ack with a timeout.
///
/// Returns true if the renderer was confirmed paused within the timeout,
/// false if the wait timed out (in which case iOS may still suspend with
/// renderer work outstanding — try-best-effort, do not block scene-update
/// indefinitely).
///
/// Intended to be called from the main thread by the apprt during its
/// scene-will-resign-active / scene-did-enter-background hooks. The cost
/// of this wait is bounded by the longest in-flight drawFrame plus
/// renderer mailbox processing, typically a few milliseconds.
pub fn drainRendererToIdle(self: *Surface, timeout_ns: u64) bool {
    // Heap-allocate the rendezvous handle so it survives a timeout. If the
    // wait below times out and we return, the renderer thread may still
    // process the drain_to_idle message later and signal the event — using
    // a stack-allocated event would be a use-after-free in that case. The
    // handle is refcounted (2 = main + renderer) so the last-decrementing
    // side frees it.
    const alloc = self.alloc;
    const handle = rendererpkg.DrainHandle.create(alloc) catch {
        // Allocation failure: skip the wait entirely. Backgrounding will
        // still proceed; we just lose the renderer-paused guarantee.
        return false;
    };
    defer handle.release(alloc);

    // visible=false pauses the renderer; the IOSDisplayLink for this
    // surface stops as part of renderer.setVisible(false). Both messages
    // are pushed before we wake the renderer, so they're processed
    // atomically within a single drainMailbox iteration.
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .visible = false,
    }, .{ .forever = {} });
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .drain_to_idle = handle,
    }, .{ .forever = {} });

    // Wake the renderer thread. queueRender returns an error only if the
    // wakeup async is in a bad state; in practice this can't fail at
    // runtime, but if it does we still try to wait briefly so we don't
    // pin Swift forever.
    self.queueRender() catch {};

    handle.event.waitTimeout(global.io(), .{ .duration = .{
        .clock = .awake,
        .raw = .fromNanoseconds(timeout_ns),
    } }) catch return false;
    return true;
}

pub fn focusCallback(self: *Surface, focused: bool) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Always update the app focused surface, otherwise we miss
    // the first surface created.
    if (focused) self.app.focusSurface(self);

    // If our focus state is unchanged we do nothing else.
    if (self.focused == focused) return;
    self.focused = focused;

    // Notify our render thread of the new state
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .focus = focused,
    }, .{ .forever = {} });

    if (!focused) unfocused: {
        // If we lost focus and we have a keypress, then we want to send a key
        // release event for it. Depending on the apprt, this CAN result in
        // duplicate key release events, but that is better than not sending
        // a key release event at all.
        var pressed_key = self.pressed_key orelse break :unfocused;
        self.pressed_key = null;

        // All our actions will be releases
        pressed_key.action = .release;

        // Release the full key first
        if (pressed_key.key != .unidentified) {
            assert(self.keyCallback(pressed_key) catch |err| err: {
                log.warn("error releasing key on focus loss err={}", .{err});
                break :err .ignored;
            } != .closed);
        }

        // Release any modifiers if set
        if (pressed_key.mods.empty()) break :unfocused;

        // This is kind of nasty comptime meta programming but all we're doing
        // here is going through all the modifiers and if they're set, releasing
        // both the left and right sides of the modifier. This may not match
        // the exact input event but it ensures a full reset.
        const keys = &.{ "shift", "ctrl", "alt", "super" };
        const original_key = pressed_key.key;
        inline for (keys) |key| {
            if (@field(pressed_key.mods, key)) {
                @field(pressed_key.mods, key) = false;
                inline for (&.{ "right", "left" }) |side| {
                    const keyname = comptime keyname: {
                        break :keyname if (std.mem.eql(u8, key, "ctrl"))
                            "control"
                        else if (std.mem.eql(u8, key, "super"))
                            "meta"
                        else
                            key;
                    };
                    pressed_key.key = @field(input.Key, keyname ++ "_" ++ side);
                    if (pressed_key.key != original_key) {
                        assert(self.keyCallback(pressed_key) catch |err| err: {
                            log.warn("error releasing key on focus loss err={}", .{err});
                            break :err .ignored;
                        } != .closed);
                    }
                }
            }
        }
    }

    // Schedule render which also drains our mailbox
    try self.queueRender();

    // Whenever our focus changes we unhide the mouse. The mouse will be
    // hidden again if the user starts typing. This helps alleviate some
    // buggy behavior upstream in macOS with the mouse never becoming visible
    // again when tabbing between programs (see #2525).
    self.showMouse();

    // Update the focus state and notify the terminal
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        self.io.terminal.flags.focused = focused;
        self.renderer_state.mutex.unlock(global.io());
        self.queueIo(.{ .focused = focused }, .unlocked);
    }
}

pub fn refreshCallback(self: *Surface) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // The point of this callback is to schedule a render, so do that.
    try self.queueRender();
}

// The amount to scroll. This structure is always normalized so that
// negative is down, left and positive is up, right. Note that INTERNALLY,
// vertical scroll on our terminal uses positive for down (right is not
// supported by our screen since scrollback is only vertical).
const ScrollAmount = struct {
    delta: isize = 0,

    pub fn direction(self: ScrollAmount) enum { down_left, up_right } {
        return if (self.delta < 0) .down_left else .up_right;
    }

    pub fn magnitude(self: ScrollAmount) usize {
        return @abs(self.delta);
    }
};

/// Mouse scroll event. Negative is down, left. Positive is up, right.
///
/// "Natural scrolling" is a macOS term for inverting the scroll direction.
/// This should be handled by the apprt implementation. At this layer,
/// negative is always down, left.
pub fn scrollCallback(
    self: *Surface,
    xoff: f64,
    yoff: f64,
    scroll_mods: input.ScrollMods,
) !void {
    // log.info("SCROLL: xoff={} yoff={} mods={}", .{ xoff, yoff, scroll_mods });

    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    const y: ScrollAmount = if (yoff == 0) .{} else y: {
        // We use cell_size to determine if we have accumulated enough to trigger a scroll
        const cell_size: f64 = @floatFromInt(self.size.cell.height);

        // If we have precision scroll, yoff is the number of pixels to scroll. In non-precision
        // scroll, yoff is the number of wheel ticks. Some mice are capable of reporting fractional
        // wheel ticks, which don't necessarily get reported as precision scrolls. We normalize all
        // scroll events to pixels by multiplying the wheel tick value and the cell size. This means
        // that a wheel tick of 1 results in single scroll event.
        const yoff_adjusted: f64 = if (scroll_mods.precision)
            yoff * self.config.mouse_scroll_multiplier.precision
        else yoff_adjusted: {
            if (comptime builtin.target.os.tag.isDarwin()) {
                // Round out the yoff to an absolute minimum of 1. macos tries to
                // simulate precision scrolling with non precision events by
                // ramping up the magnitude of the offsets as it detects faster
                // scrolling. Single click (very slow) scrolls are reported with a
                // magnitude of 0.1 which would normally require a few clicks
                // before we register an actual scroll event (depending on cell
                // height and the mouse_scroll_multiplier setting).
                const yoff_max: f64 = if (yoff > 0)
                    @max(yoff, 1)
                else
                    @min(yoff, -1);

                break :yoff_adjusted yoff_max * cell_size * self.config.mouse_scroll_multiplier.discrete;
            } else {
                break :yoff_adjusted yoff * cell_size * self.config.mouse_scroll_multiplier.discrete;
            }
        };

        // Add our previously saved pending amount to the offset to get the
        // new offset value. The signs of the pending and yoff should match
        // so that we move further away from zero, but we don't assert
        // this because in theory a user could scroll in the opposite
        // direction and undo a pending scroll.
        const poff: f64 = self.mouse.pending_scroll_y + yoff_adjusted;

        // If the new offset is less than a single unit of scroll, we save
        // the new pending value and do not scroll yet.
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_y = poff;
            break :y .{};
        }

        // We scroll by the number of rows in the offset and save the remainder
        const amount = poff / cell_size;
        assert(@abs(amount) >= 1);
        self.mouse.pending_scroll_y = poff - (amount * cell_size);

        // Round towards zero.
        const delta: isize = @intFromFloat(@trunc(amount));
        assert(@abs(delta) >= 1);

        break :y .{ .delta = delta };
    };

    // For detailed comments see the y calculation above.
    const x: ScrollAmount = if (xoff == 0) .{} else x: {
        if (!scroll_mods.precision) {
            const x_delta_isize: isize = @intFromFloat(@round(xoff));
            break :x .{ .delta = x_delta_isize };
        }

        const poff: f64 = self.mouse.pending_scroll_x + xoff;
        const cell_size: f64 = @floatFromInt(self.size.cell.width);
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_x = poff;
            break :x .{};
        }

        const amount = poff / cell_size;
        assert(@abs(amount) >= 1);
        self.mouse.pending_scroll_x = poff - (amount * cell_size);
        const delta: isize = @intFromFloat(@trunc(amount));
        assert(@abs(delta) >= 1);
        break :x .{ .delta = delta };
    };

    // log.info("SCROLL: delta_y={} delta_x={}", .{ y.delta, x.delta });

    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // If we have an active mouse reporting mode, clear the selection.
        // The selection can occur if the user uses the shift mod key to
        // override mouse grabbing from the window.
        if (self.isMouseReporting()) {
            try self.setSelection(null);
        }

        // If we're in alternate screen with alternate scroll enabled, then
        // we convert to cursor keys. This only happens if we're:
        // (1) alt screen (2) no explicit mouse reporting and (3) alt
        // scroll mode enabled.
        //
        // Read screen/mode state from the UI terminal: for a tmux pane the
        // alt-screen/mouse/alt-scroll/cursor-keys modes live on the
        // viewer-owned terminal, not io.terminal (see uiTerminalLockedConst).
        const ui_term = self.uiTerminalLockedConst();
        if (ui_term.screens.active_key == .alternate and
            ui_term.flags.mouse_event == .none and
            ui_term.modes.get(.mouse_alternate_scroll))
        {
            if (y.delta != 0) {
                // When we send mouse events as cursor keys we always
                // clear the selection.
                try self.setSelection(null);

                const seq = if (ui_term.modes.get(.cursor_keys)) seq: {
                    // cursor key: application mode
                    break :seq switch (y.direction()) {
                        .up_right => "\x1bOA",
                        .down_left => "\x1bOB",
                    };
                } else seq: {
                    // cursor key: normal mode
                    break :seq switch (y.direction()) {
                        .up_right => "\x1b[A",
                        .down_left => "\x1b[B",
                    };
                };
                for (0..y.magnitude()) |_| {
                    self.queueIo(.{ .write_stable = seq }, .locked);
                }
            }

            return;
        }

        // We have mouse events, are not in an alternate scroll buffer,
        // or have alternate scroll disabled. In this case, we just run
        // the normal logic.

        // If we're scrolling up or down, then send a mouse event.
        if (self.isMouseReporting()) {
            for (0..@abs(y.delta)) |_| {
                const pos = try self.rt_surface.getCursorPos();
                self.mouseReport(switch (y.direction()) {
                    .up_right => .four,
                    .down_left => .five,
                }, .press, self.mouse.mods, pos);
            }

            for (0..@abs(x.delta)) |_| {
                const pos = try self.rt_surface.getCursorPos();
                self.mouseReport(switch (x.direction()) {
                    .up_right => .six,
                    .down_left => .seven,
                }, .press, self.mouse.mods, pos);
            }

            // If mouse reporting is on, we do not want to scroll the
            // viewport.
            return;
        }

        if (y.delta != 0) {
            // Modify our viewport, this requires a lock since it affects
            // rendering. We have to switch signs here because our delta
            // is negative down but our viewport is positive down.
            //
            // Use renderer_state.terminal (the DISPLAYED terminal), not
            // io.terminal: for a normal surface they are the same pointer, but
            // for a tmux control-mode pane the renderer is swapped to the
            // viewer-owned pane terminal while io.terminal is an unused dummy.
            // Scrolling io.terminal there would scroll nothing visible. The
            // renderer_state.mutex held here also guards the viewer's writes.
            self.renderer_state.terminal.scrollViewport(.{ .delta = y.delta * -1 });
            self.renderer_state.smooth_scroll_y_px = 0;
            self.renderer_state.smooth_scroll_active = false;
        }
    }

    try self.queueRender();
}

/// This is called when the content scale of the surface changes. The surface
/// can then update any DPI-sensitive state.
pub fn contentScaleCallback(self: *Surface, content_scale: apprt.ContentScale) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Calculate the new DPI
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;

    // Update our font size which is dependent on the DPI
    const size = size: {
        var size = self.font_size;
        size.xdpi = @intFromFloat(x_dpi);
        size.ydpi = @intFromFloat(y_dpi);
        break :size size;
    };

    // If our DPI didn't actually change, save a lot of work by doing nothing.
    if (size.xdpi == self.font_size.xdpi and size.ydpi == self.font_size.ydpi) {
        return;
    }

    try self.setFontSize(size);

    // Update our padding which is dependent on DPI. We only do this for
    // unbalanced padding since balanced padding is not dependent on DPI.
    if (self.config.window_padding_balance == .false) {
        self.size.padding = self.config.scaledPadding(x_dpi, y_dpi);
        // Re-apply the runtime bottom inset (e.g. iOS safe-area) after the
        // DPI-dependent padding recompute so a font/DPI change doesn't drop it.
        self.size.padding.bottom += self.bottom_inset_px;
    }

    // Force a resize event because the change in padding will affect
    // pixel-level changes to the renderer and viewport.
    try self.resize(self.size.screen);
}

/// Returns true if mouse reporting is enabled both in the config and
/// the terminal state.
fn isMouseReporting(self: *const Surface) bool {
    return self.config.mouse_reporting and
        self.uiTerminalLockedConst().flags.mouse_event != .none;
}

pub fn mouseReportingActive(self: *Surface) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return self.isMouseReporting();
}

fn mouseReport(
    self: *Surface,
    button: ?input.MouseButton,
    action: input.MouseAction,
    mods: input.Mods,
    pos: apprt.CursorPos,
) void {
    // Mouse reporting must be enabled by both config and terminal state.
    // Read mouse mode/format from the UI terminal so tmux panes use the
    // viewer-owned terminal's modes (see uiTerminalLockedConst).
    const ui_term = self.uiTerminalLockedConst();
    assert(self.config.mouse_reporting);
    assert(ui_term.flags.mouse_event != .none);

    // Build our encoding options.
    const encoding_opts: input.mouse_encode.Options = opts: {
        // Terminal and size state.
        var opts: input.mouse_encode.Options = .fromTerminal(
            ui_term,
            self.size,
        );

        // Whether any button is pressed at all.
        opts.any_button_pressed = pressed: {
            for (self.mouse.click_state) |state| {
                if (state != .release) break :pressed true;
            }

            break :pressed false;
        };

        // Keep track of our last reported viewport cell for event
        // deduplication.
        opts.last_cell = &self.mouse.event_point;

        break :opts opts;
    };

    var data: termio.Message.WriteReq.Small.Array = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    input.mouse_encode.encode(&writer, .{
        .button = button,
        .action = action,
        .mods = mods,
        .pos = .{
            .x = pos.x,
            .y = pos.y,
        },
    }, encoding_opts) catch |err| switch (err) {
        error.WriteFailed => {
            // This should never happen since mouse events should never
            // be able to overflow the size of our small array. But if it
            // does, let's log it and return. No need to crash upstreams.
            // In the future we may want to fall back to allocation.
            log.warn("failed to encode mouse event err={}", .{err});
            return;
        },
    };
    const written = writer.buffered();
    if (written.len == 0) return;

    self.queueIo(.{ .write_small = .{
        .data = data,
        .len = @intCast(written.len),
    } }, .locked);
}

/// Returns true if the shift modifier is allowed to be captured by modifier
/// events. It is up to the caller to still verify it is a situation in which
/// shift capture makes sense (i.e. left button, mouse click, etc.)
fn mouseShiftCapture(self: *const Surface, lock: bool) bool {
    // Handle our never/always case where we don't need a lock.
    switch (self.config.mouse_shift_capture) {
        .never => return false,
        .always => return true,
        .false, .true => {},
    }

    if (lock) self.renderer_state.mutex.lockUncancelable(global.io());
    defer if (lock) self.renderer_state.mutex.unlock(global.io());

    // If the terminal explicitly requests it then we always allow it
    // since we processed never/always at this point.
    switch (self.uiTerminalLockedConst().flags.mouse_shift_capture) {
        .false => return false,
        .true => return true,
        .null => {},
    }

    // Otherwise, go with the user's preference
    return switch (self.config.mouse_shift_capture) {
        .false => false,
        .true => true,
        .never, .always => unreachable, // handled earlier
    };
}

/// Returns true if the mouse is currently captured by the terminal
/// (i.e. reporting events).
pub fn mouseCaptured(self: *Surface) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return self.config.mouse_reporting and self.uiTerminalLockedConst().flags.mouse_event != .none;
}

/// Called for mouse button press/release events. This will return true
/// if the mouse event was consumed in some way (i.e. the program is capturing
/// mouse events). If the event was not consumed, then false is returned.
pub fn mouseButtonCallback(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) !bool {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // log.debug("mouse action={} button={} mods={}", .{ action, button, mods });

    // If we have an inspector, we always queue a render
    if (self.inspector != null) {
        defer self.queueRender() catch {};
    }

    // Always record our latest mouse state
    self.mouse.click_state[@intCast(@intFromEnum(button))] = action;

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    // Update our modifiers if they changed
    self.modsChanged(mods);

    // This is set to true if the terminal is allowed to capture the shift
    // modifier. Note we can do this more efficiently probably with less
    // locking/unlocking but clicking isn't that frequent enough to be a
    // bottleneck.
    const shift_capture = self.mouseShiftCapture(true);

    // Shift-click continues the previous mouse state if we have a selection.
    // cursorPosCallback will also do a mouse report so we don't need to do any
    // of the logic below.
    if (button == .left and action == .press) {
        // We could do all the conditionals in one but I find it more
        // readable as a human to break this one up.
        if (mods.shift and
            self.mouse.selection_gesture.left_click_count > 0 and
            !shift_capture)
        extend_selection: {
            // We split this conditional out on its own because this is the
            // only one that requires a renderer mutex grab which is VERY
            // expensive because it could block all our threads.
            if (!self.hasSelection()) break :extend_selection;

            // If we are within the interval that the click would register
            // an increment then we do not extend the selection.
            const click_time = self.mouse.selection_gesture.left_click_time orelse
                break :extend_selection;
            const since = click_time.untilNow(global.io(), .awake);
            if (since.toNanoseconds() <= self.config.mouse_interval) {
                // Click interval very short, we may be increasing
                // click counts so we don't extend the selection.
                break :extend_selection;
            }

            const pos = try self.rt_surface.getCursorPos();
            try self.cursorPosCallback(pos, null);
            return true;
        }
    }

    if (button == .left and action == .release) {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // The selection gesture tracks whether a press became a drag by
        // comparing the release cell to the original press cell. Resolve the
        // release position and pin before notifying the gesture so later
        // release handling can query that state.
        const release_pos: ?apprt.CursorPos = self.rt_surface.getCursorPos() catch |err| pos: {
            log.warn("error reading cursor position for mouse release err={}", .{err});
            break :pos null;
        };

        // If we can't map the release position to a cell, pass null so the
        // gesture can conservatively treat the release as having moved away
        // from the pressed cell.
        const release_pin: ?terminal.Pin = if (release_pos) |pos| pin: {
            const release_vp = self.posToViewportLocked(pos.x, pos.y);
            break :pin self.uiTerminalLocked().screens.active.pages.pin(.{ .viewport = .{
                .x = release_vp.x,
                .y = release_vp.y,
            } });
        } else null;
        self.mouse.selection_gesture.release(
            self.renderer_state.terminal,
            .{ .pin = release_pin },
        );

        // Stop selection scrolling when releasing the left mouse button
        // but only when selection scrolling is active.
        if (self.selection_scroll_active) {
            self.queueIo(
                .{ .selection_scroll = false },
                .locked,
            );
        }

        // The selection clipboard is only updated for left-click drag when
        // the left button is released. This is to avoid the clipboard
        // being updated on every mouse move which would be noisy.
        if (self.config.copy_on_select != .false) {
            const prev_ = self.uiTerminalLocked().screens.active.selection;
            if (prev_) |prev| {
                try self.setSelectionAndCopy(terminal.Selection.init(
                    prev.start(),
                    prev.end(),
                    prev.rectangle,
                ));
            }
        }

        // Handle link clicking. We want to do this before we do mouse
        // reporting or any other mouse handling because a successfully
        // clicked link will swallow the event.
        if (self.mouse.over_link and !self.mouse.selection_gesture.left_click_dragged) {
            // We are holding the renderer lock, but this should just be
            // a cached value.
            const pos = release_pos orelse try self.rt_surface.getCursorPos();
            if (self.processLinks(pos)) |processed| {
                if (processed) return true;
            } else |err| {
                log.warn("error processing links err={}", .{err});
            }
        }

        // Handle prompt clicking. If we released our mouse on a prompt
        // and we support some kind of click events, then we need to
        // move to it.
        if (self.maybePromptClick()) |handled| {
            if (handled) return true;
        } else |err| {
            log.warn("error processing prompt click err={}", .{err});
        }
    }

    // Report mouse events if enabled
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.isMouseReporting()) report: {
            // If we have shift-pressed and we aren't allowed to capture it,
            // then we do not do a mouse report.
            if (mods.shift and !shift_capture) break :report;

            // In any other mouse button scenario without shift pressed we
            // clear the selection since the underlying application can handle
            // that in any way (i.e. "scrolling").
            try self.setSelection(null);

            // We also set the left click count to 0 so that if mouse reporting
            // is disabled in the middle of press (before release) we don't
            // suddenly start selecting text.
            self.mouse.selection_gesture.reset(self.renderer_state.terminal);

            const pos = try self.rt_surface.getCursorPos();

            const report_action: input.MouseAction = switch (action) {
                .press => .press,
                .release => .release,
            };

            self.mouseReport(
                button,
                report_action,
                self.mouse.mods,
                pos,
            );

            // If we're doing mouse reporting, we do not support any other
            // selection or highlighting.
            return true;
        }
    }

    // For left button clicks we always record some information for
    // selection/highlighting purposes.
    if (button == .left and action == .press) click: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const t: *terminal.Terminal = self.renderer_state.terminal;
        const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;

        const pos = try self.rt_surface.getCursorPos();
        const pin = pin: {
            const pt_viewport = self.posToViewportLocked(pos.x, pos.y);
            const pin = screen.pages.pin(.{
                .viewport = .{
                    .x = pt_viewport.x,
                    .y = pt_viewport.y,
                },
            }) orelse {
                // Weird... our viewport x/y that we just converted isn't
                // found in our pages. This is probably a bug but we don't
                // want to crash in releases because its harmless. So, we
                // only assert in debug mode.
                if (comptime std.debug.runtime_safety) unreachable;
                break :click;
            };

            break :pin pin;
        };

        var press_selection = try self.mouse.selection_gesture.press(t, .{
            .time = std.Io.Timestamp.now(global.io(), .awake),
            .pin = pin,
            .xpos = pos.x,
            .ypos = pos.y,
            .max_distance = @floatFromInt(self.size.cell.width),
            .repeat_interval = self.config.mouse_interval,
            .word_boundary_codepoints = self.config.selection_word_chars,
            .behaviors = &.{
                .cell,
                .word,
                if (mods.ctrlOrSuper()) .output else .line,
            },
        });

        // The gesture owns the standard single/double/triple-click selection
        // behavior. Surface keeps terminal-surface-specific overrides here.
        switch (self.mouse.selection_gesture.left_click_count) {
            1 => {},

            // Double click on a URL selects the entire URL instead of the
            // standard word selection returned by the gesture.
            2 => {
                // Try link detection without requiring modifier keys.
                if (self.linkAtPin(
                    pin,
                    null,
                )) |result_| {
                    if (result_) |result| {
                        press_selection = result.selection;
                    }
                } else |_| {
                    // Ignore any errors, likely regex errors.
                }
            },

            3 => {},

            // We should be bounded by 1 to 3
            else => unreachable,
        }

        // Use `setSelection` (not `setSelectionAndCopy`) here to avoid
        // touching the selection clipboard: for left mouse clicks we only
        // copy on release.
        if (press_selection) |selection| {
            try self.setSelection(selection);
            try self.queueRender();
        } else if (self.mouse.selection_gesture.left_click_count == 1 and
            self.uiTerminalLocked().screens.active.selection != null)
        {
            try self.setSelection(null);
            try self.queueRender();
        }
    }

    // Middle-click paste source follows copy-on-select: when copy-on-select
    // targets the selection clipboard, middle-click reads from it; when
    // copy-on-select targets the system clipboard, middle-click reads from
    // that instead. Falls back to the standard clipboard on platforms that
    // do not support the selection clipboard.
    if (button == .middle and action == .press) switch (self.config.middle_click_action) {
        .ignore => {},
        .@"primary-paste" => {
            const clipboard: apprt.Clipboard = switch (self.config.copy_on_select) {
                .clipboard => .standard,
                .true, .false => if (self.rt_surface.supportsClipboard(.selection))
                    .selection
                else
                    .standard,
            };
            _ = try self.startClipboardRequest(clipboard, .{ .paste = {} });
        },
    };

    // Right-click down selects word for context menus. If the apprt
    // doesn't implement context menus this can be a bit weird but they
    // are supported by our two main apprts so we always do this. If we
    // want to be careful in the future we can add a function to apprts
    // that let's us know.
    if (button == .right and action == .press) sel: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // Get our viewport pin
        const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
        const pos = try self.rt_surface.getCursorPos();
        const pin = pin: {
            const pt_viewport = self.posToViewportLocked(pos.x, pos.y);
            const pin = screen.pages.pin(.{
                .viewport = .{
                    .x = pt_viewport.x,
                    .y = pt_viewport.y,
                },
            }) orelse {
                if (comptime std.debug.runtime_safety) unreachable;
                break :sel;
            };

            break :pin pin;
        };

        switch (self.config.right_click_action) {
            .ignore => {},
            .@"context-menu" => {
                // If we already have a selection and the selection contains
                // where we clicked then we don't want to modify the selection.
                if (screen.selection) |prev_sel| {
                    if (prev_sel.contains(screen, pin)) break :sel;

                    // The selection doesn't contain our pin, so we create a new
                    // word selection where we clicked.
                }

                // If there is a link at this position, we want to select the
                // link. Otherwise, select the word. For multi-row extended
                // links (link.url != null) the selection spans rows with
                // padding, so fall through to word selection instead.
                const link_sel: ?terminal.Selection = link_sel: {
                    const link = (try self.linkAtPos(pos)) orelse break :link_sel null;
                    defer if (link.url) |u| self.alloc.free(u);
                    if (link.url != null) break :link_sel null;
                    break :link_sel link.selection;
                };
                if (link_sel) |link_selection| {
                    try self.setSelectionAndCopy(link_selection);
                } else {
                    const sel = screen.selectWordOrIPv6(
                        pin,
                        self.config.selection_word_chars,
                    ) orelse break :sel;
                    try self.setSelectionAndCopy(sel);
                }
                try self.queueRender();

                // Don't consume so that we show the context menu in apprt.
                return false;
            },
            .copy => {
                if (screen.selection) |sel| {
                    try self.copySelectionToClipboards(
                        sel,
                        &.{.standard},
                        .mixed,
                    );
                }

                try self.setSelection(null);
                try self.queueRender();
            },
            .@"copy-or-paste" => if (screen.selection) |sel| {
                try self.copySelectionToClipboards(
                    sel,
                    &.{.standard},
                    .mixed,
                );
                try self.setSelection(null);
                try self.queueRender();
            } else {
                // Pasting can trigger a lock grab in complete clipboard
                // request so we need to unlock.
                self.renderer_state.mutex.unlock(global.io());
                defer self.renderer_state.mutex.lockUncancelable(global.io());
                _ = try self.startClipboardRequest(.standard, .paste);

                // We don't need to clear selection because we didn't have
                // one to begin with.
            },
            .paste => {
                // Before we yield the lock, clear our selection if we have
                // one.
                try self.setSelection(null);
                try self.queueRender();

                // Pasting can trigger a lock grab in complete clipboard
                // request so we need to unlock.
                self.renderer_state.mutex.unlock(global.io());
                defer self.renderer_state.mutex.lockUncancelable(global.io());
                _ = try self.startClipboardRequest(.standard, .paste);
            },
        }

        // Consume the event such that the context menu is not displayed.
        return true;
    }

    return false;
}

/// Requires the renderer state mutex is held.
fn maybePromptClick(self: *Surface) !bool {
    const t: *terminal.Terminal = self.renderer_state.terminal;
    const screen: *terminal.Screen = t.screens.active;

    // If our screen doesn't handle any prompt clicks, then we never
    // do anything.
    if (screen.semantic_prompt.click == .none) return false;

    // If cursor-click-to-move is disabled, we don't do any prompt clicking.
    if (!self.config.cursor_click_to_move) return false;

    // If our cursor isn't currently at a prompt then we don't handle
    // prompt clicks because we can't move if we're not in a prompt!
    if (!t.cursorIsAtPrompt()) return false;

    // If the left click moved away from its pressed cell then releasing the
    // mouse completes the drag gesture and we don't do prompt moving.
    if (self.mouse.selection_gesture.left_click_dragged) return false;

    // If we have a selection currently, then releasing the mouse completes
    // the selection and we don't do prompt moving.
    if (screen.selection != null) return false;

    // Get the pin for our mouse click.
    const pos = try self.rt_surface.getCursorPos();
    const pos_vp = self.posToViewportLocked(pos.x, pos.y);
    const click_pin: terminal.Pin = pin: {
        const pin = screen.pages.pin(.{
            .viewport = .{
                .x = pos_vp.x,
                .y = pos_vp.y,
            },
        }) orelse {
            // See mouseButtonCallback for explanation
            if (comptime std.debug.runtime_safety) unreachable;
            return false;
        };

        break :pin pin;
    };

    // Get our cursor's most current prompt.
    const prompt_pin: terminal.Pin = prompt_pin: {
        var it = screen.cursor.page_pin.promptIterator(
            .left_up,
            null,
        );
        break :prompt_pin it.next() orelse {
            // This shouldn't be possible because we asserted we're at
            // a prompt above, so we MUST find some prompt in a left_up search.
            log.warn("cursor is at prompt but no prompt found", .{});
            if (comptime std.debug.runtime_safety) unreachable;
            return false;
        };
    };

    // If our mouse click is before the prompt, we don't move.
    // We DO ALLOW clicks AFTER the prompt, specifically with Kitty's
    // click_events=1 since we rely on the shell to validate out of
    // bounds clicks. This matches Kitty's logic as best I can tell.
    if (click_pin.before(prompt_pin)) return false;

    // At this point we've established:
    // - Screen supports prompt clicks
    // - Cursor is at a prompt
    // - Click is at or below our prompt
    switch (screen.semantic_prompt.click) {
        // Guarded at the start of this function
        .none => unreachable,

        .click_events => |v| {
            // For the event, we always send a left-click press event.
            // This matches what Kitty sends.
            const key: u8, const y: u32 = switch (v) {
                .absolute => .{ 1, pos_vp.y +| 1 },
                .relative => .{ 2, pos_vp.y -| prompt_pin.y +| 1 },
            };
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(
                &data,
                "\x1B[<0;{d};{d}M",
                .{ pos_vp.x + 1, y },
            );

            // Not that noisy since this only happens on prompt clicks.
            log.debug(
                "sending click_events={} event=ESC{s}",
                .{ key, resp[1..] },
            );

            // Ask our IO thread to write the data
            self.queueIo(.{ .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            } }, .locked);
        },

        .cl => {
            const left_arrow = if (t.modes.get(.cursor_keys)) "\x1bOD" else "\x1b[D";
            const right_arrow = if (t.modes.get(.cursor_keys)) "\x1bOC" else "\x1b[C";

            const move = screen.promptClickMove(click_pin);
            for (0..move.left) |_| {
                self.queueIo(
                    .{ .write_stable = left_arrow },
                    .locked,
                );
            }
            for (0..move.right) |_| {
                self.queueIo(
                    .{ .write_stable = right_arrow },
                    .locked,
                );
            }
        },
    }

    return true;
}

const Link = struct {
    action: input.Link.Action,
    selection: terminal.Selection,
    /// Pre-computed URL string for multi-row extended matches.
    /// When non-null, processLinks should use this directly instead of
    /// calling selectionString, because the selection may span multiple
    /// non-wrapped rows where selectionString would insert newlines.
    url: ?[:0]const u8 = null,
};

/// Returns the link at the given cursor position, if any.
///
/// Requires the renderer mutex is held.
fn linkAtPos(
    self: *Surface,
    pos: apprt.CursorPos,
) !?Link {
    // Convert our cursor position to a screen point.
    const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
    const mouse_pin: terminal.Pin = mouse_pin: {
        const point = self.posToViewportLocked(pos.x, pos.y);
        const pin = screen.pages.pin(.{ .viewport = point }) orelse {
            log.warn("failed to get pin for clicked point", .{});
            return null;
        };
        break :mouse_pin pin;
    };

    // Get our comparison mods
    const mouse_mods = self.mouseModsWithCapture(self.mouse.mods);

    // If we have the proper modifiers set then we can check for OSC8 links.
    if (self.config.link_osc8 and
        mouse_mods.equal(input.ctrlOrSuper(.{})))
    hyperlink: {
        const rac = mouse_pin.rowAndCell();
        const cell = rac.cell;
        if (!cell.hyperlink) break :hyperlink;
        const sel = terminal.Selection.init(mouse_pin, mouse_pin, false);
        return .{ .action = ._open_osc8, .selection = sel };
    }

    // Fall back to configured links, then try multi-row extension.
    return try self.linkAtPin(mouse_pin, mouse_mods) orelse
        try self.linkAtPinExtended(mouse_pin, mouse_mods);
}

/// Detects if a link is present at the given pin.
///
/// If mouse mods is null then mouse mod requirements are ignored (all
/// configured links are checked).
///
/// Requires the renderer state mutex is held.
fn linkAtPin(
    self: *Surface,
    mouse_pin: terminal.Pin,
    mouse_mods: ?input.Mods,
) !?Link {
    if (self.config.links.len == 0) return null;

    const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
    const line = screen.selectLine(.{
        .pin = mouse_pin,
        .whitespace = null,
        // Respect semantic prompt boundaries so link/path matching doesn't
        // merge shell prompt content with the text beside it.
        .semantic_prompt_boundary = true,
    }) orelse return null;

    const strmap = try screen.selectionStringMap(self.alloc, .{
        .sel = line,
        .trim = false,
    });
    defer strmap.deinit(self.alloc);

    for (self.config.links) |link| {
        // Skip highlight/mods check when mouse_mods is null (double-click mode)
        if (mouse_mods) |mods| switch (link.highlight) {
            .always, .hover => {},
            .always_mods, .hover_mods => |v| if (!v.equal(mods)) continue,
        };

        var it = strmap.searchIterator(link.regex);
        while (true) {
            var match = (try it.next()) orelse break;
            defer match.deinit();
            const sel = match.selection();
            if (!sel.contains(screen, mouse_pin)) continue;
            return .{
                .action = link.action,
                .selection = sel,
            };
        }
    }

    return null;
}

/// Attempts to detect a link that spans multiple non-soft-wrapped rows
/// within a logical column window (e.g., a tmux pane). This is called
/// as a fallback when the standard `linkAtPin` finds no match.
///
/// When terminal multiplexers use explicit cursor positioning, URLs that
/// wrap at pane boundaries are split across physical rows without the
/// `row.wrap` flag. This method detects the column window (bounded by
/// box-drawing dividers or terminal edges), concatenates text from
/// adjacent rows within the window, and searches for URL matches.
///
/// Requires the renderer state mutex is held.
fn linkAtPinExtended(
    self: *Surface,
    mouse_pin: terminal.Pin,
    mouse_mods: ?input.Mods,
) !?Link {
    const link_ext = terminal.link_extend;

    if (self.config.links.len == 0) return null;

    // Don't extend for soft-wrapped rows (standard path handles them).
    const mouse_row = mouse_pin.rowAndCell().row;
    if (mouse_row.wrap or mouse_row.wrap_continuation) return null;

    // Detect column window at mouse position.
    const all_cells = mouse_pin.cells(.all);
    const cols = mouse_pin.node.cols();
    const window = link_ext.detectColumnWindow(all_cells, mouse_pin.x, cols);

    // Don't try extension if mouse is on a divider.
    if (link_ext.isVerticalDivider(all_cells[mouse_pin.x].codepoint())) return null;

    // Collect row pins: upward + current + downward (stack-allocated buffer).
    var row_pins_buf: [link_ext.max_extend_rows * 2 + 1]terminal.Pin = undefined;
    var row_count: usize = 0;
    var mouse_row_idx: usize = 0;

    // Go up from mouse row to find the top of the potential URL.
    // Only include rows above whose content fills the column window
    // to the right boundary — this indicates the text wrapped from
    // that row to the next. A row like "/tmp/url.sh" that doesn't
    // fill the pane width is NOT a continuation source.
    {
        var up_pins: [link_ext.max_extend_rows]terminal.Pin = undefined;
        var up_count: usize = 0;
        var it = mouse_pin.rowIterator(.left_up, null);
        _ = it.next(); // skip self
        while (up_count < link_ext.max_extend_rows) {
            const p = it.next() orelse break;
            const p_row = p.rowAndCell().row;
            // Stop at soft-wrap boundaries (different wrapping context).
            if (p_row.wrap or p_row.wrap_continuation) break;
            const p_cells = p.cells(.all);
            const pw = link_ext.detectColumnWindow(p_cells, window.left, cols);
            if (pw.left != window.left or pw.right != window.right) break;
            // Only include this row if its content fills the window to
            // the right boundary (meaning it wrapped to the next row).
            var last_content_x: ?terminal.size.CellCountInt = null;
            {
                var x = pw.right;
                while (true) {
                    const cp = p_cells[x].codepoint();
                    if (cp != 0 and cp != ' ') {
                        last_content_x = x;
                        break;
                    }
                    if (x == pw.left) break;
                    x -= 1;
                }
            }
            if (last_content_x == null or last_content_x.? < pw.right) break;
            up_pins[up_count] = p;
            up_count += 1;
        }
        // Add in reverse order (top to bottom).
        var i = up_count;
        while (i > 0) {
            i -= 1;
            row_pins_buf[row_count] = up_pins[i];
            row_count += 1;
        }
    }

    // Current (mouse) row.
    mouse_row_idx = row_count;
    row_pins_buf[row_count] = mouse_pin;
    row_count += 1;

    // Go down from mouse row. Only extend if the previous row's content
    // fills the window to the right boundary (indicating it wrapped).
    {
        var it = mouse_pin.rowIterator(.right_down, null);
        _ = it.next(); // skip self

        // Check if the previous row (initially the mouse row) fills the window.
        var prev_cells = all_cells;
        var prev_window = window;

        var down_count: usize = 0;
        while (down_count < link_ext.max_extend_rows) : (down_count += 1) {
            // Only extend if previous row fills the window to the right edge.
            var prev_last_x: ?terminal.size.CellCountInt = null;
            {
                var x = prev_window.right;
                while (true) {
                    const cp = prev_cells[x].codepoint();
                    if (cp != 0 and cp != ' ') {
                        prev_last_x = x;
                        break;
                    }
                    if (x == prev_window.left) break;
                    x -= 1;
                }
            }
            if (prev_last_x == null or prev_last_x.? < prev_window.right) break;

            const p = it.next() orelse break;
            const p_row = p.rowAndCell().row;
            // Stop at any soft-wrap boundary to avoid mixing contexts.
            if (p_row.wrap or p_row.wrap_continuation) break;
            const p_cells = p.cells(.all);
            const pw = link_ext.detectColumnWindow(p_cells, window.left, cols);
            if (pw.left != window.left or pw.right != window.right) break;
            row_pins_buf[row_count] = p;
            row_count += 1;

            prev_cells = p_cells;
            prev_window = pw;
        }
    }

    // Need more than one row for multi-row extension.
    if (row_count <= 1) return null;

    const row_pins = row_pins_buf[0..row_count];

    // Build concatenated text and pin map from all rows within the window.
    var text_buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer text_buf.deinit();
    var pin_map: std.ArrayListUnmanaged(terminal.Pin) = .empty;
    defer pin_map.deinit(self.alloc);

    // Track the exact byte offset of the mouse cell (not the whole row).
    var mouse_cell_byte: ?usize = null;

    for (row_pins, 0..) |rp, idx| {
        // Write cells within the column window (grapheme-aware).
        const r_cells = rp.cells(.all);
        const end_col: usize = @min(@as(usize, window.right) + 1, @as(usize, cols));
        var x: usize = window.left;
        while (x < end_col) : (x += 1) {
            const cell = &r_cells[x];
            const cp = cell.codepoint();
            if (cp == 0) continue;

            // Record byte offset of the exact mouse cell.
            if (idx == mouse_row_idx and x == mouse_pin.x) {
                mouse_cell_byte = text_buf.writer.buffered().len;
            }

            var byte_len: usize = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            try text_buf.writer.print("{u}", .{cp});

            // Include grapheme cluster codepoints if present.
            if (cell.hasGrapheme()) {
                var grapheme_pin = rp;
                grapheme_pin.x = @intCast(x);
                if (grapheme_pin.grapheme(cell)) |graphemes| {
                    for (graphemes) |gcp| {
                        byte_len += std.unicode.utf8CodepointSequenceLength(gcp) catch continue;
                        try text_buf.writer.print("{u}", .{gcp});
                    }
                }
            }

            var cell_pin = rp;
            cell_pin.x = @intCast(x);
            try pin_map.appendNTimes(self.alloc, cell_pin, byte_len);
        }
    }

    const text = text_buf.writer.buffered();
    if (text.len == 0) return null;
    const mouse_byte = mouse_cell_byte orelse return null;

    // Search using the same strategy as the renderer: find a regex match
    // on a single row that ends at that row's right boundary, then extend
    // forward across continuation rows and verify the extended match covers
    // the mouse position.
    //
    // Try each collected row as a potential anchor (not just the first),
    // because unrelated full-width rows may have been collected above the
    // real URL start.

    // Build per-row byte boundaries in the concatenated text.
    var row_byte_ends: [link_ext.max_extend_rows * 2 + 1]usize = undefined;
    {
        var byte_pos: usize = 0;
        for (row_pins, 0..) |rp, idx| {
            const r_cells = rp.cells(.all);
            const end_col: usize = @min(@as(usize, window.right) + 1, @as(usize, cols));
            var rx: usize = window.left;
            while (rx < end_col) : (rx += 1) {
                const cell = &r_cells[rx];
                const cp = cell.codepoint();
                if (cp == 0) continue;
                byte_pos += std.unicode.utf8CodepointSequenceLength(cp) catch continue;
                if (cell.hasGrapheme()) {
                    var gp = rp;
                    gp.x = @intCast(rx);
                    if (gp.grapheme(cell)) |graphemes| {
                        for (graphemes) |gcp| {
                            byte_pos += std.unicode.utf8CodepointSequenceLength(gcp) catch continue;
                        }
                    }
                }
            }
            row_byte_ends[idx] = byte_pos;
        }
    }

    for (self.config.links) |*cfg_link| {
        if (mouse_mods) |mods| switch (cfg_link.highlight) {
            .always, .hover => {},
            .always_mods, .hover_mods => |v| if (!v.equal(mods)) continue,
        };

        // Try each row as a potential anchor for the match.
        for (0..row_count) |anchor_idx| {
            const anchor_start: usize = if (anchor_idx == 0) 0 else row_byte_ends[anchor_idx - 1];
            const anchor_end: usize = row_byte_ends[anchor_idx];
            if (anchor_start >= anchor_end) continue;
            const anchor_text = text[anchor_start..anchor_end];

            // Search for a regex match within this single row's text.
            var search_offset: usize = 0;
            while (search_offset < anchor_text.len) {
                var region = cfg_link.regex.search(
                    anchor_text[search_offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();

                const m_start = anchor_start + search_offset + @as(usize, @intCast(region.starts()[0]));
                const m_end_anchor = anchor_start + search_offset + @as(usize, @intCast(region.ends()[0]));
                defer search_offset += @as(usize, @intCast(region.ends()[0]));

                // The match must end at this row's boundary (fills the row).
                if (m_end_anchor < anchor_end) continue;

                // Only extend scheme-based URLs (https://, ftp://, etc.),
                // NOT file path matches. The path branches of the URL regex
                // are too broad (allow spaces, bare relatives) and would
                // stitch unrelated text across rows.
                if (!terminal.link_extend.hasUrlScheme(text[m_start..m_end_anchor])) continue;

                // Extend: re-run the regex on the full text from this match start.
                var full_region = cfg_link.regex.search(
                    text[m_start..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => continue,
                    else => return err,
                };
                defer full_region.deinit();

                // Must start at position 0 (same match).
                if (full_region.starts()[0] != 0) continue;

                const full_m_end = m_start + @as(usize, @intCast(full_region.ends()[0]));

                // Must actually extend beyond the anchor row.
                if (full_m_end <= m_end_anchor) continue;

                // The mouse cell must be within the match (cell-precise).
                if (mouse_byte < m_start or mouse_byte >= full_m_end) continue;

                // Bounds check the pin map.
                if (full_m_end > pin_map.items.len or m_start >= pin_map.items.len) continue;

                const url = try self.alloc.dupeZ(u8, text[m_start..full_m_end]);
                const sel_start_pin = pin_map.items[m_start];
                const sel_end_pin = pin_map.items[full_m_end - 1];

                return .{
                    .action = cfg_link.action,
                    .selection = terminal.Selection.init(sel_start_pin, sel_end_pin, false),
                    .url = url,
                };
            }
        }
    }

    return null;
}

/// This returns the mouse mods to consider for link highlighting or
/// other purposes taking into account when shift is pressed for releasing
/// the mouse from capture.
///
/// The renderer state mutex must be held.
fn mouseModsWithCapture(self: *Surface, mods: input.Mods) input.Mods {
    // In any of these scenarios, whatever mods are set (even shift)
    // are preserved.
    if (self.uiTerminalLockedConst().flags.mouse_event == .none) return mods;
    if (!mods.shift) return mods;
    if (self.mouseShiftCapture(false)) return mods;

    // We have mouse capture, shift set, and we're not allowed to capture
    // shift, so we can clear shift.
    var final = mods;
    final.shift = false;
    return final;
}

/// Returns true if the current mouse modifiers include the link hover
/// modifier (Cmd on macOS, Ctrl on Linux). When true, link detection
/// should proceed even when mouse reporting is active, since:
/// - On macOS: Super is not encoded in the xterm mouse protocol
/// - On Linux: Link detection and mouse reporting are independent
///
// rootshell: allow link detection when Cmd/Ctrl held inside mouse-tracking apps (e.g. tmux)
fn mouseLinkModBypass(self: *const Surface) bool {
    return self.mouse.mods.ctrlOrSuper();
}

/// Attempt to invoke the action of any link that is under the
/// given position.
///
/// Requires the renderer state mutex is held.
fn processLinks(self: *Surface, pos: apprt.CursorPos) !bool {
    const link = try self.linkAtPos(pos) orelse return false;
    defer if (link.url) |u| self.alloc.free(u);
    switch (link.action) {
        .open => {
            // Use the pre-computed URL if available (multi-row extended match),
            // otherwise extract from the selection as before.
            const str = link.url orelse try self.uiTerminalLocked().screens.active.selectionString(self.alloc, .{
                .sel = link.selection,
                .trim = false,
            });
            defer if (link.url == null) self.alloc.free(str);

            const resolved_path = try self.resolvePathForOpening(str);
            defer if (resolved_path) |p| self.alloc.free(p);

            const url_to_open = resolved_path orelse str;
            try self.openUrl(.{ .kind = .unknown, .url = url_to_open });
        },

        ._open_osc8 => {
            const uri = self.osc8URI(link.selection.start()) orelse {
                log.warn("failed to get URI for OSC8 hyperlink", .{});
                return false;
            };
            try self.openUrl(.{ .kind = .osc8, .url = uri });
        },
    }

    return true;
}

fn openUrl(
    self: *Surface,
    action: apprt.action.OpenUrl,
) !void {
    // If the apprt handles it then we're done.
    if (try self.rt_app.performAction(
        .{ .surface = self },
        .open_url,
        action,
    )) return;

    // apprt didn't handle it, fallback to our simple cross-platform
    // URL opener. We log a warning because we want well-behaved
    // apprts to handle this themselves.
    log.warn("apprt did not handle open URL action, falling back to default opener", .{});
    try internal_os.open(
        action.kind,
        action.url,
    );
}

/// Return the URI for an OSC8 hyperlink at the given position or null
/// if there is no hyperlink.
fn osc8URI(self: *Surface, pin: terminal.Pin) ?[]const u8 {
    _ = self;
    const page = pin.node.page();
    const cell = pin.rowAndCell().cell;
    const link_id = page.lookupHyperlink(cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, link_id);
    return entry.uri.slice(page.memory);
}

pub fn mousePressureCallback(
    self: *Surface,
    stage: input.MousePressureStage,
    pressure: f64,
) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // We don't currently use the pressure value for anything. In the
    // future, we could report this to applications using new mouse
    // events or utilize it for some custom UI.
    _ = pressure;

    // If the pressure stage is the same as what we already have do nothing
    if (self.mouse.pressure_stage == stage) return;

    // Update our pressure stage.
    self.mouse.pressure_stage = stage;

    // A deep press is pressure-sensitive pointer input, such as macOS force
    // click / deep click on a trackpad, that occurs while the left mouse
    // button is already down. Treat it as the platform text-selection
    // affordance: select the pressed word, then consume the active gesture so
    // further cursor motion doesn't drag the selection.
    const left_idx = @intFromEnum(input.MouseButton.left);
    if (self.mouse.click_state[left_idx] == .press and
        stage == .deep)
    select: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        const sel = self.mouse.selection_gesture.deepPress(
            self.renderer_state.terminal,
            .{ .word_boundary_codepoints = self.config.selection_word_chars },
        );

        // Deep press consumes the active drag gesture, so stop any pending
        // selection autoscroll timer that may have been started by the drag.
        if (self.selection_scroll_active) {
            self.queueIo(
                .{ .selection_scroll = false },
                .locked,
            );
        }

        try self.setSelection(sel orelse break :select);
        try self.queueRender();
    }
}

/// Cursor position callback.
///
/// Send negative x or y values to indicate the cursor is outside the
/// viewport. The magnitude of the negative values are meaningless;
/// they are only used to indicate the cursor is outside the viewport.
/// It's important to do this to ensure hover states are cleared.
///
/// The mods parameter is optional because some apprts do not provide
/// modifier information on cursor position events. If mods is null then
/// we'll use the last known mods. This is usually accurate since mod events
/// will trigger key press events but on some platforms we don't get them.
/// For example, on macOS, unfocused surfaces don't receive key events but
/// do receive mouse events so we have to rely on updated mods.
pub fn cursorPosCallback(
    self: *Surface,
    pos: apprt.CursorPos,
    mods: ?input.Mods,
) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // log.debug("cursor pos x={} y={} mods={?}", .{ pos.x, pos.y, mods });

    // If the position is negative, it is outside our viewport and
    // we need to clear any hover states.
    if (pos.x < 0 or pos.y < 0) {
        // Reset our hyperlink state
        self.mouse.link_point = null;
        if (self.mouse.over_link) {
            self.mouse.over_link = false;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                self.io.terminal.mouse_shape,
            );
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                .{ .url = "" },
            );
            try self.queueRender();
        }

        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // No mouse point so we don't highlight links
        self.renderer_state.mouse.point = null;

        // Mark the link's row as dirty, but continue with updating the
        // mouse state below so we can scroll when our position is negative.
        self.renderer_state.terminal.screens.active.dirty.hyperlink_hover = true;
    }

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    // Update our modifiers if they changed
    if (mods) |v| self.modsChanged(v);

    // We always reset the over link status because it will be reprocessed
    // below. But we need the old value to know if we need to undo mouse
    // shape changes.
    const over_link = self.mouse.over_link;
    self.mouse.over_link = false;

    // We are reading/writing state for the remainder
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // Update our mouse state. We set this to null initially because we only
    // want to set it when we're not selecting or doing any other mouse
    // event.
    self.renderer_state.mouse.point = null;

    // The mouse position in the viewport. Computed under the renderer lock so
    // the smooth-scroll pixel offset is accounted for (rootshell smooth scroll).
    const pos_vp = self.posToViewportLocked(pos.x, pos.y);

    // If we have an inspector, we need to always record position information
    if (self.inspector) |insp| {
        insp.mouse.last_xpos = pos.x;
        insp.mouse.last_ypos = pos.y;

        const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
        insp.mouse.last_point = screen.pages.pin(.{ .viewport = .{
            .x = pos_vp.x,
            .y = pos_vp.y,
        } });
        try self.queueRender();
    }

    // Handle link hovering
    // We refresh links when
    // 1. we were previously over a link
    // OR
    // 2. the cursor position has changed (either we have no previous state, or the state has
    //    changed)
    // AND
    // 1. mouse reporting is off
    // OR
    // 2. mouse reporting is on and we are not reporting shift to the terminal
    if ((over_link or
        self.mouse.link_point == null or
        (self.mouse.link_point != null and !self.mouse.link_point.?.eql(pos_vp))) and
        (self.uiTerminalLockedConst().flags.mouse_event == .none or
            (self.mouse.mods.shift and !self.mouseShiftCapture(false)) or
            self.mouseLinkModBypass())) // rootshell: bypass mouse capture for link detection with Cmd/Ctrl
    {
        // If we were previously over a link, we always update. We do this so that if the text
        // changed underneath us, even if the mouse didn't move, we update the URL hints and state
        try self.mouseRefreshLinks(pos, pos_vp, over_link);
    }

    // Do a mouse report
    if (self.isMouseReporting()) report: {
        // Shift overrides mouse "grabbing" in the window, taken from Kitty.
        // This only applies if there is a mouse button pressed so that
        // movement reports are not affected.
        if (self.mouse.mods.shift and !self.mouseShiftCapture(false)) {
            for (self.mouse.click_state) |state| {
                if (state != .release) break :report;
            }
        }

        // We use the first mouse button we find pressed in order to report
        // since the spec (afaict) does not say...
        const button: ?input.MouseButton = button: for (self.mouse.click_state, 0..) |state, i| {
            if (state == .press)
                break :button @enumFromInt(i);
        } else null;

        self.mouseReport(button, .motion, self.mouse.mods, pos);

        // If we're doing mouse motion tracking, we do not support text
        // selection.
        return;
    }

    // Handle cursor position for text selection
    if (self.mouse.click_state[@intFromEnum(input.MouseButton.left)] == .press) select: {
        // Left click pressed but count zero can happen if mouse reporting is on.
        // In this scenario, we mark the click state because we need that to
        // properly make some mouse reports, but we don't keep track of the
        // count because we don't want to handle selection.
        if (self.mouse.selection_gesture.left_click_count == 0) break :select;

        // If our left-click pin no longer belongs to the active screen then we
        // don't process this. We don't invalidate our pin or mouse state
        // because if the same screen switches back then we can continue our
        // selection.
        const t: *terminal.Terminal = self.renderer_state.terminal;
        if (self.mouse.activeLeftClickPin(&t.screens) == null) break :select;

        // All roads lead to requiring a re-render at this point.
        try self.queueRender();

        // Convert to points
        const screen: *terminal.Screen = t.screens.active;
        const pin = screen.pages.pin(.{
            .viewport = .{
                .x = pos_vp.x,
                .y = pos_vp.y,
            },
        }) orelse {
            if (comptime std.debug.runtime_safety) unreachable;
            return;
        };

        // Perform our drag behavior in our gesture handler.
        const drag_selection = self.mouse.selection_gesture.drag(t, .{
            .pin = pin,
            .xpos = pos.x,
            .ypos = pos.y,
            .rectangle = SurfaceMouse.isRectangleSelectState(self.mouse.mods),
            .word_boundary_codepoints = self.config.selection_word_chars,
            .geometry = .{
                .columns = @intCast(self.size.grid().columns),
                .cell_width = self.size.cell.width,
                .padding_left = self.size.padding.left,
                .screen_height = self.size.screen.height,
                // rootshell(iOS): keep the bottom autoscroll edge reachable.
                .bottom_autoscroll_threshold = self.bottomAutoscrollThreshold(),
            },
        });

        // Update our autoscroll timer based on the gesture state
        switch (self.mouse.selection_gesture.left_drag_autoscroll) {
            .none => if (self.selection_scroll_active) {
                self.queueIo(
                    .{ .selection_scroll = false },
                    .locked,
                );
            },
            .up, .down => if (!self.selection_scroll_active) {
                self.queueIo(
                    .{ .selection_scroll = true },
                    .locked,
                );
            },
        }

        // Update our selection based on the gesture state
        try self.setSelection(drag_selection);
    }
}

/// Call to notify Ghostty that the color scheme for the terminal has
/// changed.
pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };

    // If our scheme didn't change, then we don't do anything.
    if (self.config_conditional_state.theme == new_scheme) return;

    // Setup our conditional state which has the current color theme.
    self.config_conditional_state.theme = new_scheme;
    self.notifyConfigConditionalState();

    // If mode 2031 is on, then we report the change live.
    self.queueIo(.{ .color_scheme_report = .{ .force = false } }, .unlocked);
}

fn posToViewportWithSmoothOffset(
    self: Surface,
    xpos: f64,
    ypos: f64,
    smooth_scroll_y_px: f64,
    smooth_scroll_active: bool,
) terminal.point.Coordinate {
    const grid = self.size.grid();
    const smooth_offset = @max(0, smooth_scroll_y_px);
    const screen_height: f64 = @floatFromInt(self.size.screen.height);
    const apply_smooth_offset = smooth_scroll_active and ypos >= 0 and ypos < screen_height;

    const terminal_x = xpos - @as(f64, @floatFromInt(self.size.padding.left));
    const terminal_y = ypos +
        (if (apply_smooth_offset) smooth_offset else 0) -
        @as(f64, @floatFromInt(self.size.padding.top));
    const cell_width: f64 = @floatFromInt(self.size.cell.width);
    const cell_height: f64 = @floatFromInt(self.size.cell.height);

    const col: terminal.size.CellCountInt = col: {
        const raw: terminal.size.CellCountInt = @intFromFloat(
            @max(0, terminal_x) / cell_width,
        );
        break :col @min(raw, grid.columns - 1);
    };
    const row: u32 = row: {
        const raw: u32 = @intFromFloat(@max(0, terminal_y) / cell_height);
        const max_row: u32 = if (apply_smooth_offset)
            @as(u32, grid.rows) + 1
        else
            @as(u32, grid.rows) - 1;
        break :row @min(raw, max_row);
    };

    return .{ .x = col, .y = row };
}

/// Converts a surface coordinate to a viewport cell while accounting for
/// render-only smooth scrollback translation.
///
/// Precondition: the renderer_state mutex must be held.
/// rootshell(iOS): the y position (in surface pixels) at or above which a
/// downward selection autoscroll should trigger. Derived from the true grid
/// bottom (top padding + rows * cell height) minus a small slop scaled by the
/// display. The grid bottom is used instead of `size.screen.height` because the
/// latter overshoots the drawable grid by the bottom padding / reserved inset /
/// row-rounding leftover. The slop makes the bottom edge reachable on
/// iOS / Mac Catalyst (where the OS caps the reported pointer y ~1 logical point
/// short of the drawable bottom) while staying far enough inside a row that
/// selecting the last line on desktop does not spuriously auto-scroll.
fn bottomAutoscrollThreshold(self: *const Surface) f64 {
    const grid_size = self.size.grid();
    const grid_bottom: f32 = @as(f32, @floatFromInt(self.size.padding.top)) +
        @as(f32, @floatFromInt(grid_size.rows)) *
            @as(f32, @floatFromInt(self.size.cell.height));
    const scale_y: f32 = (self.rt_surface.getContentScale() catch
        .{ .x = 1, .y = 1 }).y;
    const bottom_slop: f32 = 2 * scale_y;
    return @floatCast(grid_bottom - bottom_slop);
}

/// rootshell(iOS touch selection): begin a drag from a selection handle.
/// Seeds the selection gesture (upstream's `SelectionGesture` model) with a
/// single-click anchor at the endpoint OPPOSITE the dragged handle so that
/// subsequent `cursorPosCallback` drags extend the selection from the fixed end.
pub fn beginSelectionHandleDrag(self: *Surface, dragging_start: bool) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    const t: *terminal.Terminal = self.renderer_state.terminal;
    const screen: *terminal.Screen = t.screens.active;
    const sel = screen.selection orelse return false;

    // Keep the endpoint opposite the dragged handle fixed. The handles are
    // placed in SCREEN order (the leading handle sits at the selection's
    // top-left, the trailing handle at its bottom-right), so we must anchor by
    // topLeft/bottomRight too — sel.start()/end() are storage order and would
    // anchor at the wrong (or the same) endpoint for a reverse-ordered
    // selection, collapsing the drag.
    const fixed_pin = if (dragging_start)
        sel.bottomRight(screen)
    else
        sel.topLeft(screen);
    const tracked = screen.pages.trackPin(fixed_pin) catch return false;

    // Seed the gesture as if a single left click landed on the fixed endpoint.
    // Replace any previous gesture anchor first (untrack its tracked pin).
    const gesture = &self.mouse.selection_gesture;
    if (gesture.left_click_pin) |prev| {
        if (t.screens.get(gesture.left_click_screen)) |s| s.pages.untrackPin(prev);
    }
    gesture.left_click_pin = tracked;
    gesture.left_click_screen = t.screens.active_key;
    gesture.left_click_screen_generation = t.screens.generation(t.screens.active_key);
    gesture.left_click_count = 1;
    gesture.left_click_behavior = .cell;
    gesture.left_click_time = null;
    gesture.left_click_dragged = false;
    gesture.left_drag_autoscroll = .none;
    self.mouse.click_state[@intCast(@intFromEnum(input.MouseButton.left))] = .press;

    // Anchor the click-x at the outer edge of the fixed cell so that cell stays
    // included for the natural drag direction: right edge when the fixed point is
    // the selection's bottom-right (dragging the leading handle), left edge when
    // it is the top-left (dragging the trailing handle). (pin.x equals the grid
    // column on the active full-width screen.)
    const cell_w: u32 = self.size.cell.width;
    const edge: u32 = if (dragging_start) cell_w -| 1 else 0;
    gesture.left_click_xpos = @floatFromInt(
        self.size.padding.left + @as(u32, fixed_pin.x) * cell_w + edge,
    );
    gesture.left_click_ypos = 0;

    return true;
}

/// Report whether each endpoint of the current selection currently falls within
/// the viewport. This lets a touch UI show only the handle(s) for the visible
/// endpoint(s) of a selection that spans more than one screen (the geometry from
/// read_selection clamps off-screen endpoints to the viewport edge and so can't
/// distinguish them on its own). Returns false if there is no active selection.
pub fn selectionViewportVisibility(
    self: *Surface,
    start_visible: *bool,
    end_visible: *bool,
) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    const screen = self.uiTerminalLocked().screens.active;
    const sel = screen.selection orelse return false;

    // pointFromPin(.viewport, ...) returns null when the pin is outside the
    // viewport (above or below) — exactly the case where read_selection clamps
    // that endpoint to the viewport edge.
    start_visible.* = screen.pages.pointFromPin(.viewport, sel.topLeft(screen)) != null;
    end_visible.* = screen.pages.pointFromPin(.viewport, sel.bottomRight(screen)) != null;

    return true;
}

fn posToViewportLocked(self: Surface, xpos: f64, ypos: f64) terminal.point.Coordinate {
    return self.posToViewportWithSmoothOffset(
        xpos,
        ypos,
        self.renderer_state.smooth_scroll_y_px,
        self.renderer_state.smooth_scroll_active,
    );
}

pub fn posToViewport(self: Surface, xpos: f64, ypos: f64) terminal.point.Coordinate {
    return self.posToViewportWithSmoothOffset(xpos, ypos, 0, false);
}

/// Scroll to the bottom of the viewport.
///
/// Precondition: the render_state mutex must be held.
fn scrollToBottom(self: *Surface) !void {
    // Target the DISPLAYED terminal (renderer_state.terminal) so this works for
    // tmux control-mode panes, whose rendered terminal is the viewer-owned pane
    // terminal rather than io.terminal. Same pointer for normal surfaces.
    self.renderer_state.terminal.scrollViewport(.{ .bottom = {} });
    self.renderer_state.smooth_scroll_y_px = 0;
    self.renderer_state.smooth_scroll_active = false;
    try self.queueRender();
}

fn hideMouse(self: *Surface) void {
    if (self.mouse.hidden) return;
    self.mouse.hidden = true;
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .mouse_visibility,
        .hidden,
    ) catch |err| {
        log.warn("apprt failed to set mouse visibility err={}", .{err});
    };
}

fn showMouse(self: *Surface) void {
    if (!self.mouse.hidden) return;
    self.mouse.hidden = false;
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .mouse_visibility,
        .visible,
    ) catch |err| {
        log.warn("apprt failed to set mouse visibility err={}", .{err});
    };
}

/// Perform a binding action. A binding is a keybinding. This function
/// must be called from the GUI thread.
///
/// This function returns true if the binding action was performed. This
/// may return false if the binding action is not supported or if the
/// binding action would do nothing (i.e. previous tab with no tabs).
///
/// NOTE: At the time of writing this comment, only previous/next tab
/// will ever return false. We can expand this in the future if it becomes
/// useful. We did previous/next tab so we could implement #498.
pub fn performBindingAction(self: *Surface, action: input.Binding.Action) !bool {
    // Forward app-scoped actions to the app. Some app-scoped actions are
    // special-cased here because they do some special things when performed
    // from the surface.
    if (action.scoped(.app)) |app_action| {
        switch (app_action) {
            .new_window => try self.app.newWindow(
                self.rt_app,
                .{ .parent = self },
            ),

            // Undo and redo both support both surface and app targeting.
            // If we are triggering on a surface then we perform the
            // action with the surface target.
            .undo => return try self.rt_app.performAction(
                .{ .surface = self },
                .undo,
                {},
            ),

            .redo => return try self.rt_app.performAction(
                .{ .surface = self },
                .redo,
                {},
            ),

            else => try self.app.performAction(
                self.rt_app,
                action.scoped(.app).?,
            ),
        }
        return true;
    }

    switch (action.scoped(.surface).?) {
        .csi, .esc => |data| {
            // We need to send the CSI/ESC sequence as a single write request.
            // If you split it across two then the shell can interpret it
            // as two literals.
            var buf: [128]u8 = undefined;
            const full_data = switch (action) {
                .csi => try std.fmt.bufPrint(&buf, "\x1b[{s}", .{data}),
                .esc => try std.fmt.bufPrint(&buf, "\x1b{s}", .{data}),
                else => unreachable,
            };
            self.queueIo(try termio.Message.writeReq(
                self.alloc,
                full_data,
            ), .unlocked);

            // CSI/ESC triggers a scroll.
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
            }
        },

        .text => |data| {
            var stack = std.heap.stackFallback(256, self.alloc);
            const alloc = stack.get();
            const buf = try alloc.alloc(u8, data.len);
            defer alloc.free(buf);
            const text = configpkg.string.parse(buf, data) catch |err| {
                log.warn(
                    "error parsing text binding text={s} err={}",
                    .{ data, err },
                );
                return true;
            };
            self.queueIo(try termio.Message.writeReq(
                self.alloc,
                text,
            ), .unlocked);

            // Text triggers a scroll.
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
            }
        },

        .cursor_key => |ck| {
            // We send a different sequence depending on if we're
            // in cursor keys mode. We're in "normal" mode if cursor
            // keys mode is NOT set.
            const normal = normal: {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());

                // With the lock held, we must scroll to the bottom.
                // We always scroll to the bottom for these inputs.
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };

                break :normal !self.io.terminal.modes.get(.cursor_keys);
            };

            if (normal) {
                self.queueIo(.{ .write_stable = ck.normal }, .unlocked);
            } else {
                self.queueIo(.{ .write_stable = ck.application }, .unlocked);
            }
        },

        .reset => {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            self.renderer_state.terminal.fullReset();
            self.renderer_state.smooth_scroll_y_px = 0;
            self.renderer_state.smooth_scroll_active = false;
        },

        .start_search => {
            // To save resources, we don't actually start a search here,
            // we just notify the apprt. The real thread will start when
            // the first needles are set.
            return try self.rt_app.performAction(
                .{ .surface = self },
                .start_search,
                .{ .needle = "" },
            );
        },

        .search_selection => {
            const selection = try self.selectionString(self.alloc) orelse return false;
            defer self.alloc.free(selection);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .start_search,
                .{ .needle = selection },
            );
        },

        .end_search => {
            // We only return that this was performed if we actually
            // stopped a search, but we also send the apprt end_search so
            // that GUIs can clean up stale stuff.
            const performed = self.search != null;

            if (self.search) |*s| {
                s.deinit();
                self.search = null;
            }

            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .end_search,
                {},
            );

            return performed;
        },

        .search => |text| search: {
            const s: *Search = if (self.search) |*s| s else init: {
                // If we're stopping the search and we had no prior search,
                // then there is nothing to do.
                if (text.len == 0) return false;

                // We need to assign directly to self.search because we need
                // a stable pointer back to the thread state.
                self.search = .{
                    .state = try .init(self.alloc, .{
                        .mutex = self.renderer_state.mutex,
                        .terminal = self.renderer_state.terminal,
                        .event_cb = &searchCallback,
                        .event_userdata = self,
                    }),
                    .thread = undefined,
                };
                const s: *Search = &self.search.?;
                errdefer s.state.deinit();

                s.thread = try .spawn(
                    .{},
                    terminal.search.Thread.threadMain,
                    .{&s.state},
                );
                s.thread.setName(global.io(), "search") catch {};

                break :init s;
            };

            // Zero-length text means stop searching.
            if (text.len == 0) {
                s.deinit();
                self.search = null;
                break :search;
            }

            _ = s.state.mailbox.push(
                global.io(),
                .{ .change_needle = try .init(
                    self.alloc,
                    text,
                ) },
                .forever,
            );
            s.state.wakeup.notify() catch {};
        },

        .navigate_search => |nav| {
            const s: *Search = if (self.search) |*s| s else return false;
            _ = s.state.mailbox.push(
                global.io(),
                .{ .select = switch (nav) {
                    .next => .next,
                    .previous => .prev,
                } },
                .forever,
            );
            s.state.wakeup.notify() catch {};
        },

        .copy_to_clipboard => |format| {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());

            const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
            if (screen.selection) |sel| {
                try self.copySelectionToClipboards(
                    sel,
                    &.{.standard},
                    format,
                );

                // Clear the selection if configured to do so.
                if (self.config.selection_clear_on_copy) {
                    if (self.setSelection(null)) {
                        self.queueRender() catch |err| {
                            log.warn("failed to queue render after clear selection err={}", .{err});
                        };
                    } else |err| {
                        log.warn("failed to clear selection after copy err={}", .{err});
                    }
                }

                return true;
            }

            return false;
        },

        .copy_url_to_clipboard => {
            // If the mouse isn't over a link, nothing we can do.
            if (!self.mouse.over_link) return false;
            const pos = try self.rt_surface.getCursorPos();

            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            if (try self.linkAtPos(pos)) |link_info| {
                defer if (link_info.url) |u| self.alloc.free(u);
                const url_text = switch (link_info.action) {
                    .open => url_text: {
                        // Use pre-computed URL for multi-row matches,
                        // otherwise extract from selection.
                        if (link_info.url) |u| {
                            break :url_text try self.alloc.dupeZ(u8, u);
                        }
                        break :url_text (self.uiTerminalLocked().screens.active.selectionString(self.alloc, .{
                            .sel = link_info.selection,
                            .trim = self.config.clipboard_trim_trailing_spaces,
                        })) catch |err| {
                            log.err("error reading url string err={}", .{err});
                            return false;
                        };
                    },

                    ._open_osc8 => url_text: {
                        // For OSC8 links, get the URI directly from hyperlink data
                        const uri = self.osc8URI(link_info.selection.start()) orelse {
                            log.warn("failed to get URI for OSC8 hyperlink", .{});
                            return false;
                        };
                        break :url_text try self.alloc.dupeZ(u8, uri);
                    },
                };
                defer self.alloc.free(url_text);

                self.rt_surface.setClipboard(.standard, &.{.{
                    .mime = "text/plain",
                    .data = url_text,
                }}, false) catch |err| {
                    log.err("error copying url to clipboard err={}", .{err});
                    return false;
                };

                return true;
            }

            return false;
        },

        .copy_title_to_clipboard => return try self.rt_app.performAction(
            .{ .surface = self },
            .copy_title_to_clipboard,
            {},
        ),

        .paste_from_clipboard => return try self.startClipboardRequest(
            .standard,
            .{ .paste = {} },
        ),

        .paste_from_selection => return try self.startClipboardRequest(
            .selection,
            .{ .paste = {} },
        ),

        .increase_font_size => |delta| {
            // Max delta is somewhat arbitrary.
            const clamped_delta = @max(0, @min(255, delta));

            log.debug("increase font size={}", .{clamped_delta});

            // Max point size is somewhat arbitrary.
            var size = self.font_size;
            size.points = @min(size.points + clamped_delta, 255);
            try self.setFontSize(size);

            // Mark that we manually adjusted the font size
            self.font_size_adjusted = true;
        },

        .decrease_font_size => |delta| {
            // Max delta is somewhat arbitrary.
            const clamped_delta = @max(0, @min(255, delta));

            log.debug("decrease font size={}", .{clamped_delta});

            var size = self.font_size;
            size.points = @max(1, size.points - clamped_delta);
            try self.setFontSize(size);

            // Mark that we manually adjusted the font size
            self.font_size_adjusted = true;
        },

        .reset_font_size => {
            log.debug("reset font size", .{});

            var size = self.font_size;
            size.points = self.config.original_font_size;
            try self.setFontSize(size);

            // Reset font size also resets the manual adjustment state
            self.font_size_adjusted = false;
        },

        .set_font_size => |points| {
            log.debug("set font size={d}", .{points});

            var size = self.font_size;
            size.points = std.math.clamp(points, 1.0, 255.0);
            try self.setFontSize(size);

            // Mark that we manually adjusted the font size
            self.font_size_adjusted = true;
        },

        .prompt_surface_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            .surface,
        ),

        .prompt_tab_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            .tab,
        ),

        .prompt_window_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            .window,
        ),

        .set_surface_title => |v| {
            const title = try self.alloc.dupeZ(u8, v);
            defer self.alloc.free(title);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = title },
            );
        },

        .set_tab_title => |v| {
            const title = try self.alloc.dupeZ(u8, v);
            defer self.alloc.free(title);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .set_tab_title,
                .{ .title = title },
            );
        },

        .set_window_title => |v| {
            const title = try self.alloc.dupeZ(u8, v);
            defer self.alloc.free(title);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .set_window_title,
                .{ .title = title },
            );
        },

        .clear_screen => {
            // This is a duplicate of some of the logic in termio.clearScreen
            // but we need to do this here so we can know the answer before
            // we send the message. If the currently active screen is on the
            // alternate screen then clear screen does nothing so we want to
            // return false so the keybind can be unconsumed.
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                if (self.io.terminal.screens.active_key == .alternate) return false;
            }

            self.queueIo(.{
                .clear_screen = .{ .history = true },
            }, .unlocked);
        },

        .scroll_to_top => {
            self.queueIo(.{
                .scroll_viewport = .{ .top = {} },
            }, .unlocked);
        },

        .scroll_to_bottom => {
            self.queueIo(.{
                .scroll_viewport = .{ .bottom = {} },
            }, .unlocked);
        },

        .scroll_to_row => |n| {
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                const t: *terminal.Terminal = self.renderer_state.terminal;
                t.screens.active.scroll(.{ .row = n });
                self.renderer_state.smooth_scroll_y_px = 0;
                self.renderer_state.smooth_scroll_active = false;
            }

            try self.queueRender();
        },

        .scroll_to_selection => {
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
                const sel = screen.selection orelse return false;
                const tl = sel.topLeft(screen);
                screen.scroll(.{ .pin = tl });
                self.renderer_state.smooth_scroll_y_px = 0;
                self.renderer_state.smooth_scroll_active = false;
            }

            try self.queueRender();
        },

        .scroll_page_up => {
            const rows: isize = @intCast(self.size.grid().rows);
            self.queueIo(.{
                .scroll_viewport = .{ .delta = -1 * rows },
            }, .unlocked);
        },

        .scroll_page_down => {
            const rows: isize = @intCast(self.size.grid().rows);
            self.queueIo(.{
                .scroll_viewport = .{ .delta = rows },
            }, .unlocked);
        },

        .scroll_page_fractional => |fraction| {
            const rows: f32 = @floatFromInt(self.size.grid().rows);
            const delta: isize = @intFromFloat(@trunc(fraction * rows));
            self.queueIo(.{
                .scroll_viewport = .{ .delta = delta },
            }, .unlocked);
        },

        .scroll_page_lines => |lines| {
            self.queueIo(.{
                .scroll_viewport = .{ .delta = lines },
            }, .unlocked);
        },

        .jump_to_prompt => |delta| {
            self.queueIo(.{
                .jump_to_prompt = @intCast(delta),
            }, .unlocked);
        },

        .write_screen_file => |v| try self.writeScreenFile(
            .screen,
            v,
        ),

        .write_scrollback_file => |v| try self.writeScreenFile(
            .history,
            v,
        ),

        .write_selection_file => |v| try self.writeScreenFile(
            .selection,
            v,
        ),

        .new_tab => return try self.rt_app.performAction(
            .{ .surface = self },
            .new_tab,
            {},
        ),

        .close_tab => |v| return try self.rt_app.performAction(
            .{ .surface = self },
            .close_tab,
            switch (v) {
                .this => .this,
                .other => .other,
                .right => .right,
            },
        ),

        inline .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        => |v, tag| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_tab,
            switch (tag) {
                .previous_tab => .previous,
                .next_tab => .next,
                .last_tab => .last,
                .goto_tab => @enumFromInt(v),
                else => comptime unreachable,
            },
        ),

        .move_tab => |position| return try self.rt_app.performAction(
            .{ .surface = self },
            .move_tab,
            .{ .amount = position },
        ),

        .move_tab_to_new_window => return try self.rt_app.performAction(
            .{ .surface = self },
            .move_tab_to_new_window,
            {},
        ),

        .new_split => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .new_split,
            switch (direction) {
                .right => .right,
                .left => .left,
                .down => .down,
                .up => .up,
                .auto => if (self.size.screen.width > self.size.screen.height)
                    .right
                else
                    .down,
            },
        ),

        .goto_split => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_split,
            switch (direction) {
                inline else => |tag| @field(
                    apprt.action.GotoSplit,
                    @tagName(tag),
                ),
            },
        ),

        .goto_window => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_window,
            switch (direction) {
                .previous => .previous,
                .next => .next,
            },
        ),

        .resize_split => |value| return try self.rt_app.performAction(
            .{ .surface = self },
            .resize_split,
            .{
                .amount = value[1],
                .direction = switch (value[0]) {
                    inline else => |tag| @field(
                        apprt.action.ResizeSplit.Direction,
                        @tagName(tag),
                    ),
                },
            },
        ),

        .equalize_splits => return try self.rt_app.performAction(
            .{ .surface = self },
            .equalize_splits,
            {},
        ),

        .toggle_split_zoom => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_split_zoom,
            {},
        ),

        .toggle_readonly => {
            self.readonly = !self.readonly;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .readonly,
                if (self.readonly) .on else .off,
            );
            return true;
        },

        .reset_window_size => return try self.rt_app.performAction(
            .{ .surface = self },
            .reset_window_size,
            {},
        ),

        .toggle_maximize => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_maximize,
            {},
        ),

        .toggle_fullscreen => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_fullscreen,
            switch (self.config.macos_non_native_fullscreen) {
                .false => .native,
                .true => .macos_non_native,
                .@"visible-menu" => .macos_non_native_visible_menu,
                .@"padded-notch" => .macos_non_native_padded_notch,
            },
        ),

        .toggle_window_decorations => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_window_decorations,
            {},
        ),

        .toggle_tab_overview => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_tab_overview,
            {},
        ),

        .toggle_window_float_on_top => return try self.rt_app.performAction(
            .{ .surface = self },
            .float_window,
            .toggle,
        ),

        .toggle_secure_input => return try self.rt_app.performAction(
            .{ .surface = self },
            .secure_input,
            .toggle,
        ),

        .toggle_mouse_reporting => {
            self.config.mouse_reporting = !self.config.mouse_reporting;
            log.debug("mouse reporting toggled: {}", .{self.config.mouse_reporting});
        },

        .toggle_command_palette => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_command_palette,
            {},
        ),

        .toggle_background_opacity => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_background_opacity,
            {},
        ),

        .show_on_screen_keyboard => return try self.rt_app.performAction(
            .{ .surface = self },
            .show_on_screen_keyboard,
            {},
        ),

        .select_all => {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());

            const sel = self.uiTerminalLocked().screens.active.selectAll();
            if (sel) |s| {
                try self.setSelectionAndCopy(s);
                try self.queueRender();
            }
        },

        .inspector => |mode| return try self.rt_app.performAction(
            .{ .surface = self },
            .inspector,
            switch (mode) {
                inline else => |tag| @field(
                    apprt.action.Inspector,
                    @tagName(tag),
                ),
            },
        ),

        .close_surface => self.close(),

        .close_window => return try self.rt_app.performAction(
            .{ .surface = self },
            .close_window,
            {},
        ),

        inline .activate_key_table,
        .activate_key_table_once,
        => |name, tag| {
            // Look up the table in our config
            const set = self.config.keybind.tables.getPtr(name) orelse {
                log.debug("key table not found: {s}", .{name});
                return false;
            };

            // If this is the same table as is currently active, then
            // do nothing.
            if (self.keyboard.table_stack.items.len > 0) {
                const items = self.keyboard.table_stack.items;
                const active = items[items.len - 1].set;
                if (active == set) {
                    log.debug("ignoring duplicate activate table: {s}", .{name});
                    return false;
                }
            }

            // If we're already at the max, ignore it.
            if (self.keyboard.table_stack.items.len >= max_active_key_tables) {
                log.info(
                    "ignoring activate table, max depth reached: {s}",
                    .{name},
                );
                return false;
            }

            // Add the table to the stack.
            try self.keyboard.table_stack.append(self.alloc, .{
                .set = set,
                .once = tag == .activate_key_table_once,
            });

            // Notify the UI.
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_table,
                .{ .activate = name },
            ) catch |err| {
                log.warn(
                    "failed to notify app of key table err={}",
                    .{err},
                );
            };

            log.debug("key table activated: {s}", .{name});
        },

        .deactivate_key_table => {
            switch (self.keyboard.table_stack.items.len) {
                // No key table active. This does nothing.
                0 => return false,

                // Final key table active, clear our state.
                1 => self.keyboard.table_stack.clearAndFree(self.alloc),

                // Restore the prior key table. We don't free any memory in
                // this case because we assume it will be freed later when
                // we finish our key table.
                else => _ = self.keyboard.table_stack.pop(),
            }

            // Notify the UI.
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_table,
                .deactivate,
            ) catch |err| {
                log.warn(
                    "failed to notify app of key table err={}",
                    .{err},
                );
            };
        },

        .deactivate_all_key_tables => {
            return try self.deactivateAllKeyTables();
        },

        .end_key_sequence => {
            // End the key sequence and flush queued keys to the terminal,
            // but don't encode the key that triggered this action. This
            // will do that because leaf keys (keys with bindings) aren't
            // in the queued encoding list.
            self.endKeySequence(.flush, .retain);
        },

        .crash => |location| switch (location) {
            .main => @panic("crash binding action, crashing intentionally"),

            .render => {
                _ = self.renderer_thread.mailbox.push(global.io(), .{ .crash = {} }, .{ .forever = {} });
                self.queueRender() catch |err| {
                    // Not a big deal if this fails.
                    log.warn("failed to notify renderer of crash message err={}", .{err});
                };
            },

            .io => self.queueIo(.{ .crash = {} }, .unlocked),
        },

        .adjust_selection => |direction| {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());

            const screen: *terminal.Screen = self.uiTerminalLocked().screens.active;
            const sel = if (screen.selection) |*sel| sel else {
                // If we don't have a selection we do not perform this
                // action, allowing the keybind to fall through to the
                // terminal.
                return false;
            };
            sel.adjust(screen, switch (direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
                .page_up => .page_up,
                .page_down => .page_down,
                .home => .home,
                .end => .end,
                .beginning_of_line => .beginning_of_line,
                .end_of_line => .end_of_line,
            });

            // If the selection endpoint is outside of the current viewpoint,
            // scroll it in to view. Note we always specifically use sel.end
            // because that is what adjust modifies.
            scroll: {
                const viewport_tl = screen.pages.getTopLeft(.viewport);
                const viewport_br = screen.pages.getBottomRight(.viewport).?;
                if (sel.end().isBetween(viewport_tl, viewport_br))
                    break :scroll;

                // Our end point is not within the viewport. If the end
                // point is after the br then we need to adjust the end so
                // that it is at the bottom right of the viewport.
                const target = if (sel.end().before(viewport_tl))
                    sel.end()
                else
                    sel.end().up(screen.pages.rows - 1) orelse sel.end();

                screen.scroll(.{ .pin = target });
            }

            // Queue a render so its shown
            screen.dirty.selection = true;
            try self.queueRender();
        },
    }

    return true;
}

/// Returns true if performing the given action result in closing
/// the surface. This is used to determine if our self pointer is
/// still valid after performing some binding action.
fn closingAction(action: input.Binding.Action) bool {
    return switch (action) {
        .close_surface,
        .close_window,
        .close_tab,
        => true,

        else => false,
    };
}

/// The portion of the screen to write for writeScreenFile.
const WriteScreenLoc = enum {
    screen, // Full screen
    history, // History (scrollback)
    selection, // Selected text
};

fn writeScreenFile(
    self: *Surface,
    loc: WriteScreenLoc,
    write_screen: input.Binding.Action.WriteScreen,
) !void {
    // Create a temporary directory to store our scrollback.
    var tmp_dir = try internal_os.TempDir.init();
    var retain_tmp_dir = false;
    defer if (retain_tmp_dir) tmp_dir.close(.retain) else tmp_dir.deinit();

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    const filename = try std.fmt.bufPrint(
        &filename_buf,
        "{s}.{s}",
        .{
            @tagName(loc),
            switch (write_screen.emit) {
                .plain, .vt => "txt",
                .html => "html",
            },
        },
    );

    // Open our scrollback file
    var file = try tmp_dir.dir.createFile(
        global.io(),
        filename,
        switch (builtin.os.tag) {
            .windows => .{},
            else => .{ .permissions = .fromMode(0o600) },
        },
    );
    defer file.close(global.io());

    // Screen.dumpString writes byte-by-byte, so buffer it
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(global.io(), &buf);
    var buf_writer = &file_writer.interface;

    // Write the scrollback contents. This requires a lock.
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        const t: *terminal.Terminal = self.uiTerminalLocked();
        const screen: *terminal.Screen = t.screens.active;

        // We only dump history if we have history. We still keep
        // the file and write the empty file to the pty so that this
        // command always works on the primary screen.
        const pages = &screen.pages;
        const sel_: ?terminal.Selection = switch (loc) {
            .history => history: {
                // We do not support this for alternate screens
                // because they don't have scrollback anyways.
                if (t.screens.active_key == .alternate) {
                    break :history null;
                }

                break :history terminal.Selection.init(
                    pages.getTopLeft(.history),
                    pages.getBottomRight(.history) orelse
                        break :history null,
                    false,
                );
            },

            .screen => screen: {
                break :screen terminal.Selection.init(
                    pages.getTopLeft(.screen),
                    pages.getBottomRight(.screen) orelse
                        break :screen null,
                    false,
                );
            },

            .selection => screen.selection,
        };

        const sel = sel_ orelse {
            // If we have no selection we have no data so we do nothing.
            return;
        };

        const ScreenFormatter = terminal.formatter.ScreenFormatter;
        var formatter: ScreenFormatter = .init(screen, .{
            .emit = switch (write_screen.emit) {
                .plain => .plain,
                .vt => .vt,
                .html => .html,
            },
            .unwrap = true,
            .trim = false,
            .background = t.colors.background.get(),
            .foreground = t.colors.foreground.get(),
            .palette = &t.colors.palette.current,
        });
        formatter.content = .{ .selection = sel.ordered(
            screen,
            .forward,
        ) };
        try formatter.format(buf_writer);
    }
    try buf_writer.flush();

    // Get the final path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(
        global.io(),
        filename,
        &path_buf,
    )];

    switch (write_screen.action) {
        .copy => {
            const pathZ = try self.alloc.dupeZ(u8, path);
            defer self.alloc.free(pathZ);
            try self.rt_surface.setClipboard(.standard, &.{.{
                .mime = "text/plain",
                .data = pathZ,
            }}, false);
        },
        .open => try self.openUrl(.{
            .kind = switch (write_screen.emit) {
                .plain, .vt => .text,
                .html => .html,
            },
            .url = path,
        }),
        .paste => self.queueIo(try termio.Message.writeReq(
            self.alloc,
            path,
        ), .unlocked),
    }

    // The action accepted the path, so retain the file for its consumer.
    retain_tmp_dir = true;
}

/// Call this to complete a clipboard request sent to apprt. This should
/// only be called once for each request. The data is immediately copied so
/// it is safe to free the data after this call.
///
/// If `confirmed` is true then any clipboard confirmation prompts are skipped:
///
///   - For "regular" pasting this means that unsafe pastes are allowed. Unsafe
///     data is defined as data that contains newlines, though this definition
///     may change later to detect other scenarios.
///
///   - For OSC 52 reads and writes no prompt is shown to the user if
///     `confirmed` is true.
///
/// If `confirmed` is false then this may return either an UnsafePaste or
/// UnauthorizedPaste error, depending on the type of clipboard request.
pub fn completeClipboardRequest(
    self: *Surface,
    req: apprt.ClipboardRequest,
    data: [:0]const u8,
    confirmed: bool,
) !void {
    switch (req) {
        .paste => try self.completeClipboardPaste(data, confirmed),

        .osc_52_read => |clipboard| try self.completeClipboardReadOSC52(
            data,
            clipboard,
            confirmed,
        ),

        .osc_52_write => |clipboard| try self.rt_surface.setClipboard(clipboard, &.{.{
            .mime = "text/plain",
            .data = data,
        }}, !confirmed),
    }
}

/// This starts a clipboard request, with some basic validation. For example,
/// an OSC 52 request is not actually requested if OSC 52 is disabled.
///
/// Returns true if the request was started, false if it was not (e.g., clipboard
/// doesn't contain text for paste requests). This allows performable keybinds
/// to pass through when the action cannot be performed.
fn startClipboardRequest(
    self: *Surface,
    loc: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !bool {
    switch (req) {
        .paste => {}, // always allowed
        .osc_52_read => if (self.config.clipboard_read == .deny) {
            log.info(
                "application attempted to read clipboard, but 'clipboard-read' is set to deny",
                .{},
            );
            return false;
        },

        // No clipboard write code paths travel through this function
        .osc_52_write => unreachable,
    }

    return try self.rt_surface.clipboardRequest(loc, req);
}

fn completeClipboardPaste(
    self: *Surface,
    data: []const u8,
    allow_unsafe: bool,
) !void {
    if (data.len == 0) return;

    const encode_opts: input.paste.Options = encode_opts: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        // Read paste options (notably bracketed-paste mode) from the terminal
        // the renderer actually displays, NOT `&self.io.terminal`. For a normal
        // surface these are the same. For a tmux -CC pane they DIVERGE: the
        // child surface's `io.terminal` is an empty, unused terminal — the pane's
        // real VT state (fed from tmux `%output`, including the app's
        // `\x1b[?2004h`/`l`) lives in the viewer-owned terminal that
        // `Tmux.threadEnter` swaps into `renderer_state.terminal`. Reading
        // `io.terminal` here always saw bracketed_paste=false, so every paste
        // into a tmux pane went UN-bracketed and multi-line pastes executed.
        // This mirrors iTerm2, whose `pasteHelperShouldBracket` reads its own
        // per-pane screen mode. Safe under the held renderer mutex, which also
        // guards the viewer pane terminal. ROOTSHELL-TMUX (id=tmux-pane-paste-terminal)
        var opts: input.paste.Options = .fromTerminal(self.renderer_state.terminal);
        opts.bracketed_safe_newline = self.config.clipboard_paste_bracketed_safe_newline;

        // If we have paste protection enabled, we detect unsafe pastes and return
        // an error. The error approach allows apprt to attempt to complete the paste
        // before falling back to requesting confirmation.
        //
        // We do not do this for bracketed pastes because bracketed pastes are
        // by definition safe since they're framed.
        const unsafe = unsafe: {
            // If we've disabled paste protection then we always allow the paste.
            if (!self.config.clipboard_paste_protection) break :unsafe false;

            // If we're allowed to paste unsafe data then we always allow the paste.
            // This is set during confirmation usually.
            if (allow_unsafe) break :unsafe false;

            if (opts.bracketed) {
                // If we're bracketed and the paste contains and ending
                // bracket then something naughty might be going on and we
                // never trust it.
                if (std.mem.indexOf(u8, data, "\x1B[201~") != null) break :unsafe true;

                // If we are bracketed and configured to trust that then the
                // paste is not unsafe.
                if (self.config.clipboard_paste_bracketed_safe) break :unsafe false;
            }

            break :unsafe !input.paste.isSafe(data);
        };

        if (unsafe) {
            log.info("potentially unsafe paste detected, rejecting until confirmation", .{});
            return error.UnsafePaste;
        }

        // With the lock held, we must scroll to the bottom.
        // We always scroll to the bottom for these inputs.
        self.scrollToBottom() catch |err| {
            log.warn("error scrolling to bottom err={}", .{err});
        };

        break :encode_opts opts;
    };

    // Encode the data. In most cases this doesn't require any
    // copies, so we optimize for that case.
    var data_duped: ?[]u8 = null;
    const vecs = input.paste.encode(data, encode_opts) catch |err| switch (err) {
        error.MutableRequired => vecs: {
            const buf: []u8 = try self.alloc.dupe(u8, data);
            errdefer self.alloc.free(buf);
            data_duped = buf;
            break :vecs input.paste.encode(buf, encode_opts);
        },
    };
    defer if (data_duped) |v| {
        // This code path means the data did require a copy and mutation.
        // We must free it.
        self.alloc.free(v);
    };

    // ROOTSHELL-TMUX BEGIN (id=surface-paste-atomic)
    // For a tmux pane, ship the whole paste (bracket prefix + body + suffix)
    // as ONE termio message. The upstream three-vec loop below queues three
    // independent messages; under mailbox backpressure a bracket marker can
    // be dropped separately from the body, tearing the bracketed paste apart
    // at the remote app (a lost ESC[201~ strands it inside an open paste).
    // One message keeps delivery all-or-nothing, and the tmux backend batches
    // the resulting send-keys lines into one relay write (Tmux.queueWrite).
    // reapply: keep this branch above the upstream vec loop; the helper lives
    // in the fork-owned Surface_tmux.zig sidecar.
    if (self.io.backend == .tmux) {
        if (try tmux_reconcile.combinePasteVecs(self.alloc, vecs)) |buf| {
            self.queueIo(.{ .write_alloc = .{
                .alloc = self.alloc,
                .data = buf,
            } }, .unlocked);
        }
        return;
    }
    // ROOTSHELL-TMUX END (id=surface-paste-atomic)

    for (vecs) |vec| if (vec.len > 0) {
        self.queueIo(try termio.Message.writeReq(
            self.alloc,
            vec,
        ), .unlocked);
    };
}

fn completeClipboardReadOSC52(
    self: *Surface,
    data: []const u8,
    clipboard_type: apprt.Clipboard,
    confirmed: bool,
) !void {
    // We should never get here if clipboard-read is set to deny
    assert(self.config.clipboard_read != .deny);

    // If clipboard-read is set to ask and we haven't confirmed with the user,
    // do that now
    if (self.config.clipboard_read == .ask and !confirmed) {
        return error.UnauthorizedPaste;
    }

    // Even if the clipboard data is empty we reply, since presumably
    // the client app is expecting a reply. We first allocate our buffer.
    // This must hold the base64 encoded data PLUS the OSC code surrounding it.
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(data.len);
    const buf = try self.alloc.alloc(u8, size + 9); // const for OSC
    errdefer self.alloc.free(buf);

    const kind: u8 = switch (clipboard_type) {
        .standard => 'c',
        .selection => 's',
        .primary => 'p',
    };

    // Wrap our data with the OSC code
    const prefix = try std.fmt.bufPrint(buf, "\x1b]52;{c};", .{kind});
    assert(prefix.len == 7);
    buf[buf.len - 2] = '\x1b';
    buf[buf.len - 1] = '\\';

    // Do the base64 encoding
    const encoded = enc.encode(buf[prefix.len..], data);
    assert(encoded.len == size);

    self.queueIo(.{ .write_alloc = .{
        .alloc = self.alloc,
        .data = buf,
    } }, .unlocked);
}

fn showDesktopNotification(self: *Surface, title: [:0]const u8, body: [:0]const u8) !void {
    // Wyhash is used to hash the contents of the desktop notification to limit
    // how fast identical notifications can be sent sequentially.
    const hash_algorithm = std.hash.Wyhash;

    const now: std.Io.Timestamp = .now(global.io(), .awake);

    // Set a limit of one desktop notification per second so that the OS
    // doesn't kill us when we run out of resources.
    if (self.app.last_notification_time) |last| {
        if (last.durationTo(now).toSeconds() < 1) {
            log.warn("rate limiting desktop notifications", .{});
            return;
        }
    }

    const new_digest = d: {
        var hash = hash_algorithm.init(0);
        hash.update(title);
        hash.update(body);
        break :d hash.final();
    };

    // Set a limit of one notification per five seconds for desktop
    // notifications with identical content.
    if (self.app.last_notification_time) |last| {
        if (self.app.last_notification_digest == new_digest) {
            if (last.durationTo(now).toSeconds() < 5) {
                log.warn("suppressing identical desktop notification", .{});
                return;
            }
        }
    }

    self.app.last_notification_time = now;
    self.app.last_notification_digest = new_digest;
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .desktop_notification,
        .{
            .title = title,
            .body = body,
        },
    );
}

fn crashThreadState(self: *Surface) crash.sentry.ThreadState {
    return .{
        .type = .main,
        .surface = self,
    };
}

/// Tell the surface to present itself to the user. This may involve raising the
/// window and switching tabs.
fn presentSurface(self: *Surface) !void {
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .present_terminal,
        {},
    );
}

/// Get information about the process(es) running within the surface. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Surface, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.io.getProcessInfo(info);
}

test "queueIo frees allocated writes in readonly mode" {
    const testing = std.testing;

    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.readonly = true;

    // queueIo must free allocated writes in read-only mode.
    const data = try testing.allocator.dupe(u8, "\x1b]lGhostty\x1b\\");
    surface.queueIo(.{ .write_alloc = .{
        .alloc = testing.allocator,
        .data = data,
    } }, .unlocked);
}
