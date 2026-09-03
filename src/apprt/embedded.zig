//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.
//!
//! ROOTSHELL-TMUX: this upstream-shared file carries the fork's tmux control-mode
//! C ABI (ghostty_tmux_*, ghostty_surface_new_tmux_pane, ghostty_surface_tmux_set_client_size)
//! plus tmux pane surface lifecycle hooks. Grep "ROOTSHELL-TMUX" here for every
//! hook; C-ABI hooks are also tagged FROZEN-ABI because the iOS Swift app
//! depends on their exact shape. See docs/tmux-control-mode-fork.md.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const global = @import("../global.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const build_config = @import("../build_config.zig");
const String = @import("../main_c.zig").String;
// ROOTSHELL-TMUX (id=embedded-tmux-debug-snapshot): privacy-safe scalar snapshot
// of tmux control-mode internals, surfaced to the iOS debug log.
const TmuxDebugSnapshot = @import("../termio/stream_handler.zig").TmuxDebugSnapshot;
// ROOTSHELL-TMUX (id=embedded-tmux-command-with-reply): heap payload type for
// the app-issued query message.
const TmuxQueryCommand = @import("../termio.zig").Message.TmuxQueryCommand;

const log = std.log.scoped(.embedded_window);

pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.c) void,

        /// Callback called to handle an action.
        action: *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool,

        /// Read the clipboard value. Returns true if the clipboard request
        /// was started and complete_clipboard_request may be called with the
        /// given state pointer. Returns false if the clipboard request couldn't
        /// be started (such as when no text is available for a paste request).
        read_clipboard: *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) bool,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The embedder
        /// must call complete_clipboard_request with the given request.
        confirm_read_clipboard: *const fn (
            SurfaceUD,
            [*:0]const u8,
            *apprt.ClipboardRequest,
            apprt.ClipboardRequestType,
        ) callconv(.c) void,

        /// Write the clipboard value.
        write_clipboard: *const fn (
            SurfaceUD,
            c_int,
            [*]const CAPI.ClipboardContent,
            usize,
            bool,
        ) callconv(.c) void,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,
    };

    /// This is the key event sent for ghostty_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        action: input.Action,
        mods: input.Mods,
        consumed_mods: input.Mods,
        keycode: u32,
        text: ?[:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert a libghostty key event into a core key event.
        fn core(self: KeyEvent) ?input.KeyEvent {
            const text: []const u8 = if (self.text) |v| v else "";
            const unshifted_codepoint: u21 = std.math.cast(
                u21,
                self.unshifted_codepoint,
            ) orelse 0;

            // We want to get the physical unmapped key to process keybinds.
            const physical_key = keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;

            // Build our final key event
            return .{
                .action = self.action,
                .key = physical_key,
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }
    };

    core_app: *CoreApp,
    opts: Options,

    /// The keyboard layout keymap. This is lazily initialized on first
    /// use because creating it requires talking to the text input
    /// system (TIS on macOS), and the first such call in a process is
    /// slow (multiple milliseconds). It is only needed once keyboard
    /// events start flowing, at which point the system is warm.
    keymap: ?input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = null,
        };
    }

    pub fn terminate(self: *App) void {
        if (self.keymap) |*v| v.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = event.core() orelse
            return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => true,
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap. If it was never initialized we don't need
        // to do anything since lazy initialization will pick up the
        // current layout.
        if (self.keymap) |*v| try v.reload();
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Lazily initialize the keymap.
        const keymap: *input.Keymap = keymap: {
            if (self.keymap == null) {
                self.keymap = input.Keymap.init() catch |err| {
                    log.warn("error initializing keymap err={}", .{err});
                    return .unknown;
                };
            }

            break :keymap &self.keymap.?;
        };

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(self: *App, opts: Surface.Options) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface
        try surface.init(self, opts);
        errdefer surface.deinit();

        return surface;
    }

    /// Create a new tmux control mode pane surface bound to a parent
    /// (viewer-owner) surface. See `Surface.initTmuxPane`.
    fn newTmuxPaneSurface( // ROOTSHELL-TMUX (id=embedded-new-tmux-pane-fn): builds a tmux pane surface; calls Surface.initTmuxPane
        self: *App,
        opts: Surface.Options,
        parent: *Surface,
        window_id: usize,
        pane_id: usize,
        viewer_terminal: ?*terminal.Terminal,
        viewer_pane: ?*terminal.tmux.Viewer.Pane,
    ) !*Surface {
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        try surface.initTmuxPane(
            self,
            opts,
            parent,
            window_id,
            pane_id,
            viewer_terminal,
            viewer_pane,
        );
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }

    /// Send the given IPC to a running Ghostty. Returns `true` if the action was
    /// able to be performed, `false` otherwise.
    ///
    /// Note that this is a static function. Since this is called from a CLI app (or
    /// some other process that is not Ghostty) there is no full-featured apprt App
    /// to use.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || apprt.ipc.Errors)!bool {
        switch (action) {
            .new_window => return false,
            .new_tab => return false,
            .toggle_quick_terminal => return false,
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = std.enums.fromInt(PlatformTag, tag_int) orelse return error.InvalidEnumTag;
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: [*:0]const u8,

    /// The value of the environment variable.
    value: [*:0]const u8,
};

pub const Surface = struct {
    app: *App,
    platform: Platform,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    inspector: ?*Inspector = null,

    /// For tmux control mode pane surfaces: the heap-allocated relay writer
    /// that routes this pane's input as `send-keys` to the parent
    /// (viewer-owner) surface's mailbox. Owned by this surface, freed in
    /// deinit. Null for non-tmux surfaces.
    tmux_relay_writer: ?*apprt.surface.SurfaceRelayWriter = null, // ROOTSHELL-TMUX (id=embedded-relay-field)

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Whether to use external I/O (pipe-based) instead of PTY.
    use_external_io: bool = false,

    /// Callback for texture frame updates. Called after each frame is rendered
    /// with the IOSurface pointer, width, and height. Used for visionOS curved display.
    /// Signature: fn(userdata, iosurface_ptr, width, height)
    texture_callback: ?*const fn (?*anyopaque, ?*anyopaque, c_ulong, c_ulong) callconv(.c) void = null,
    texture_callback_userdata: ?*anyopaque = null,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: ?[*:0]const u8 = null,

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        ///
        /// This command always run in a shell (e.g. via `/bin/sh -c`),
        /// despite Ghostty allowing directly executed commands via config.
        /// This is a legacy thing and we should probably change it in the
        /// future once we have a concrete use case.
        command: ?[*:0]const u8 = null,

        /// Extra environment variables to set for the surface.
        env_vars: ?[*]EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Use external I/O (pipe-based) instead of PTY. Defaults to false
        /// (prefer PTY). When true, forces pipe-based I/O which is useful for
        /// scenarios like SSH sessions where the I/O is managed externally.
        use_external_io: bool = false,

        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
            .use_external_io = opts.use_external_io,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                var dir = std.Io.Dir.openDirAbsolute(global.io(), wd, .{}) catch |err| {
                    log.warn(
                        "error opening requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };
                defer dir.close(global.io());

                const stat = dir.stat(global.io()) catch |err| {
                    log.warn(
                        "failed to stat requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };

                if (stat.kind != .directory) {
                    log.warn(
                        "requested working directory is not a directory dir={s}",
                        .{wd},
                    );
                    break :wd;
                }

                var wd_val: configpkg.WorkingDirectory = .{ .path = wd };
                if (wd_val.finalize(config.arenaAlloc())) |_| {
                    config.@"working-directory" = wd_val;
                } else |err| {
                    log.warn(
                        "error finalizing working directory config dir={s} err={}",
                        .{ wd_val.path, err },
                    );
                }
            }
        }

        // If we have a command from the options then we set it.
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        if (opts.env_var_count > 0) {
            const alloc = config.arenaAlloc();
            for (opts.env_vars.?[0..opts.env_var_count]) |env_var| {
                const key = std.mem.sliceTo(env_var.key, 0);
                const value = std.mem.sliceTo(env_var.value, 0);
                try config.env.map.put(
                    alloc,
                    try alloc.dupeZ(u8, key),
                    try alloc.dupeZ(u8, value),
                );
            }
        }

        // If we have an initial input then we set it.
        if (opts.initial_input) |c_input| {
            const alloc = config.arenaAlloc();

            // We need to escape the string because the "raw" field
            // expects a Zig string.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try std.zig.stringEscape(
                std.mem.sliceTo(c_input, 0),
                &buf.writer,
            );

            config.input.list.clearRetainingCapacity();
            try config.input.list.append(
                alloc,
                .{ .raw = try buf.toOwnedSliceSentinel(0) },
            );
        }

        // Wait after command
        if (opts.wait_after_command) {
            config.@"wait-after-command" = true;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }
    }

    /// Initialize a tmux control mode pane surface. Unlike `init`, this
    /// spawns no command/pty; it creates a surface whose termio uses the
    /// `tmux` backend, routing input as `send-keys` to the parent
    /// (viewer-owner) surface and rendering from the viewer-owned pane
    /// terminal (single-terminal model).
    pub fn initTmuxPane( // ROOTSHELL-TMUX (id=embedded-init-tmux-pane-fn): tmux-backend surface init + relay writer ownership
        self: *Surface,
        app: *App,
        opts: Options,
        parent: *Surface,
        window_id: usize,
        pane_id: usize,
        viewer_terminal: ?*terminal.Terminal,
        viewer_pane: ?*terminal.tmux.Viewer.Pane,
    ) !void {
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            // Seed from the parent (gateway) size rather than the 800x600
            // placeholder so the pane's initial core resize isn't a narrow
            // grid. ROOTSHELL-TMUX (id=tmux-pane-init-size)
            .size = parent.size,
            .cursor_pos = .{ .x = -1, .y = -1 },
            .use_external_io = false,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config. tmux panes use the default config; there
        // is no command/working-directory since the tmux backend owns no pty.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // Allocate a relay writer bound to the parent (viewer-owner)
        // surface's mailbox. The tmux backend's ControlWriter points into
        // this, so it must outlive the surface; we own it and free it in
        // deinit. The errdefer covers the window before ownership transfer.
        const alloc = app.core_app.alloc;
        const relay = try alloc.create(apprt.surface.SurfaceRelayWriter);
        errdefer alloc.destroy(relay);
        relay.* = .{
            .parent_mailbox = .{
                .surface = &parent.core_surface,
                .app = .{ .rt_app = app, .mailbox = &app.core_app.mailbox },
            },
            .alloc = alloc,
        };

        // Initialize the core surface with a tmux backend.
        try self.core_surface.initWithOptions(
            alloc,
            &config,
            app.core_app,
            app,
            self,
            .{ .tmux_backend = .{
                .pane_id = pane_id,
                .window_id = window_id,
                .control_writer = relay.controlWriter(),
                .viewer_terminal = viewer_terminal,
                .viewer_pane = viewer_pane,
            } },
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }

        // Transfer ownership of the relay writer to the surface; from here
        // it is freed in deinit. No fallible ops follow, so the errdefer
        // above will not run on success (no double free).
        self.tmux_relay_writer = relay;
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();

        // Free the tmux relay writer if this was a tmux pane surface. Safe
        // after core_surface.deinit() since the IO thread (the only user of
        // the control writer) has stopped.
        if (self.tmux_relay_writer) |relay| self.app.core_app.alloc.destroy(relay); // ROOTSHELL-TMUX (id=embedded-relay-deinit)
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => self.app.opts.supports_selection_clipboard,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        const started = self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
        );
        if (!started) {
            alloc.destroy(state_ptr);
            return false;
        }

        return true;
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        const alloc = self.app.core_app.alloc;
        const array = try alloc.alloc(CAPI.ClipboardContent, contents.len);
        defer alloc.free(array);
        for (contents, 0..) |content, i| {
            array[i] = .{
                .mime = content.mime,
                .data = content.data,
            };
        }

        self.app.opts.write_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            array.ptr,
            array.len,
            confirm,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        // There are cases where the platform reports a mouse motion event
        // without the cursor actually moving. For example, on macOS, updating
        // the window title can trigger a phantom mouse-move event at the same
        // coordinates. This can cause the mouse to incorrectly unhide when
        // mouse-hide-while-typing is enabled (commonly seen with TUI apps
        // like Zellij that frequently update the title). To prevent incorrect
        // behavior, we only continue with callback logic if the cursor has
        // actually moved.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1) return;

        self.cursor_pos = pos;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface, context: apprt.surface.NewSurfaceContext) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        const working_directory: ?[*:0]const u8 = wd: {
            if (!apprt.surface.shouldInheritWorkingDirectory(context, &self.app.config)) break :wd null;
            const cwd = self.core_surface.pwd(self.app.core_app.alloc) catch null orelse break :wd null;
            defer self.app.core_app.alloc.free(cwd);
            break :wd self.app.core_app.alloc.dupeZ(u8, cwd) catch null;
        };

        return .{
            .font_size = font_size,
            .working_directory = working_directory,
            .context = context,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        var env = try global.environMap();
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                _ = env.orderedRemove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                _ = env.orderedRemove("__XPC_DYLD_LIBRARY_PATH");
                _ = env.orderedRemove("DYLD_FRAMEWORK_PATH");
                _ = env.orderedRemove("DYLD_INSERT_LIBRARIES");
                _ = env.orderedRemove("DYLD_LIBRARY_PATH");
                _ = env.orderedRemove("LD_LIBRARY_PATH");
                _ = env.orderedRemove("SECURITYSESSIONID");
                _ = env.orderedRemove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            _ = env.orderedRemove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) _ = env.orderedRemove("LANGUAGE");
        }

        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.Io.Timestamp = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.ImGui_DestroyContext(ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render(surface);
            }

            // Render
            cimgui.c.ImGui_Render();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.ImGui_GetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatCast(x));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // For precision scrolling (trackpads), the values are in pixels which
        // scroll way too fast. Scale them down to approximate discrete wheel
        // notches. imgui expects 1.0 to scroll ~5 lines of text.
        const scale: f64 = if (mods.precision) 0.1 else 1.0;
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff * scale),
            @floatCast(yoff * scale),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(prev.durationTo(now).toNanoseconds());
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    /// Terminal used for local UI reads. Tmux pane surfaces render a
    /// viewer-owned terminal while their `io.terminal` is only a relay
    /// placeholder. Normal surfaces keep upstream behavior.
    /// Precondition: the renderer_state mutex must be held.
    fn uiTerminalLocked(surface: *CoreSurface) *terminal.Terminal {
        return switch (surface.io.backend) {
            .tmux => surface.renderer_state.terminal, // ROOTSHELL-TMUX (id=embedded-ui-terminal-arm)
            else => &surface.io.terminal,
        };
    }

    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .consumed_mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.consumed_mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    const SurfaceSize = extern struct {
        columns: u16,
        rows: u16,
        width_px: u32,
        height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    };

    // ghostty_clipboard_content_s
    const ClipboardContent = extern struct {
        mime: [*:0]const u8,
        data: [*:0]const u8,
    };

    // ghostty_text_s
    const Text = extern struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
        text: ?[*:0]const u8,
        text_len: usize,

        pub fn deinit(self: *Text) void {
            if (self.text) |ptr| {
                global.alloc().free(ptr[0..self.text_len :0]);
            }
        }
    };

    // ghostty_point_s
    const Point = extern struct {
        tag: Tag,
        coord_tag: CoordTag,
        x: u32,
        y: u32,

        const Tag = enum(c_int) {
            active = 0,
            viewport = 1,
            screen = 2,
            history = 3,
        };

        const CoordTag = enum(c_int) {
            exact = 0,
            top_left = 1,
            bottom_right = 2,
        };

        fn pin(
            self: Point,
            screen: *const terminal.Screen,
        ) ?terminal.Pin {
            // The core point tag.
            const tag: terminal.point.Tag = switch (self.tag) {
                inline else => |tag| @field(
                    terminal.point.Tag,
                    @tagName(tag),
                ),
            };

            // Clamp our point to the screen bounds. Viewport exact points may
            // target the smooth-scroll overscan rows that are visually rendered
            // just past the integer viewport.
            const clamped_x = @min(self.x, screen.pages.cols -| 1);
            const clamped_y = switch (tag) {
                .viewport => @min(self.y, @as(u32, screen.pages.rows) + 1),
                else => @min(self.y, screen.pages.rows -| 1),
            };

            return switch (self.coord_tag) {
                // Exact coordinates require a specific pin.
                .exact => exact: {
                    const pt_x = std.math.cast(
                        terminal.size.CellCountInt,
                        clamped_x,
                    ) orelse std.math.maxInt(terminal.size.CellCountInt);

                    const pt: terminal.Point = switch (tag) {
                        inline else => |v| @unionInit(
                            terminal.Point,
                            @tagName(v),
                            .{ .x = pt_x, .y = clamped_y },
                        ),
                    };

                    break :exact screen.pages.pin(pt) orelse null;
                },

                .top_left => screen.pages.getTopLeft(tag),

                .bottom_right => screen.pages.getBottomRight(tag),
            };
        }
    };

    // ghostty_selection_s
    const Selection = extern struct {
        tl: Point,
        br: Point,
        rectangle: bool,

        fn core(
            self: Selection,
            screen: *const terminal.Screen,
        ) ?terminal.Selection {
            return .{
                .bounds = .{ .untracked = .{
                    .start = self.tl.pin(screen) orelse return null,
                    .end = self.br.pin(screen) orelse return null,
                } },
                .rectangle = self.rectangle,
            };
        }
    };

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.os.tag.isDarwin()) {
            _ = Darwin;
        }
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        const core_app = try CoreApp.create(global.alloc());
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc().create(App);
        errdefer global.alloc().destroy(app);
        try app.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc().destroy(v);
        core_app.destroy();
    }

    /// Enable or disable coalesced per-surface content-change actions.
    export fn ghostty_app_set_surface_content_events_enabled(
        app: *App,
        enabled: bool,
    ) void {
        app.core_app.setSurfaceContentEventsEnabled(enabled);
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app: *App,
        event: KeyEvent,
    ) bool {
        return app.keyEvent(.app, event.keyEvent()) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_config_key_is_binding(
        config: *Config,
        event: KeyEvent,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return config.keyEventIsBinding(core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v: *App) void {
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return;
        };
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v: *App) void {
        _ = v.performAction(.app, .open_config, .new_window) catch |err| {
            log.err("error reloading config err={}", .{err});
            return;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v: *App,
        config: *const Config,
    ) void {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v: *App) bool {
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v: *App) bool {
        return v.hasGlobalKeybinds();
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v: *App, scheme_raw: c_int) void {
        const scheme = std.enums.fromInt(apprt.ColorScheme, scheme_raw) orelse return;

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*);
    }

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-new-tmux-pane)
    // ghostty_surface_new_tmux_pane is called by the iOS Swift app for each
    // `ensure_pane` reconcile op. Keep the signature stable. reapply: re-add this
    // export inside the CAPI struct. See docs/tmux-control-mode-fork.md.
    /// Create a tmux control mode pane surface. `parent` is the
    /// viewer-owner surface (the one running `tmux -CC`). `viewer_terminal`
    /// and `viewer_pane` are the opaque pointers delivered by an
    /// `ensure_pane` reconcile op (see ghostty_tmux_reconcile_op). The new
    /// surface renders from the viewer's pane terminal and relays input as
    /// `send-keys` to the parent. Returns null on error.
    export fn ghostty_surface_new_tmux_pane(
        app: *App,
        parent: *Surface,
        window_id: usize,
        pane_id: usize,
        viewer_terminal: ?*anyopaque,
        viewer_pane: ?*anyopaque,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        const vt: ?*terminal.Terminal = if (viewer_terminal) |p|
            @ptrCast(@alignCast(p))
        else
            null;
        const vp: ?*terminal.tmux.Viewer.Pane = if (viewer_pane) |p|
            @ptrCast(@alignCast(p))
        else
            null;
        return app.newTmuxPaneSurface(
            opts.*,
            parent,
            window_id,
            pane_id,
            vt,
            vp,
        ) catch |err| {
            log.err("error initializing tmux pane surface err={}", .{err});
            // The child surface failed to create, so its IO thread will never run
            // Tmux.threadEnter -> attachRenderer — which is what normally clears the
            // pane's `pending_attach` en-route flag. Clear it here so the viewer can
            // reap the pane once it leaves the layout, instead of pinning its
            // terminal (captured scrollback) for the process lifetime. Safe from
            // this (app) thread: with no child IO thread there is no attachRenderer
            // to race the atomic store, the gateway reads the flag with acquire, and
            // the in-flight reconcile payload's snapshot-ref still protects the pane
            // pointer until Swift frees the payload. ROOTSHELL-TMUX
            // (id=pending-attach-failure-clear)
            if (vp) |pane| pane.clearPendingAttach();
            return null;
        };
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-new-tmux-pane)

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(
        surface: *Surface,
        source: apprt.surface.NewSurfaceContext,
    ) Surface.Options {
        return surface.newSurfaceOptions(source);
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the surface needs to confirm quitting.
    export fn ghostty_surface_needs_confirm_quit(surface: *Surface) bool {
        return surface.core_surface.needsConfirmQuit();
    }

    /// Returns true if the surface process has exited.
    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    /// Returns true if the surface has a selection.
    export fn ghostty_surface_has_selection(surface: *Surface) bool {
        return surface.core_surface.hasSelection();
    }

    /// Same as ghostty_surface_read_text but reads from the user selection,
    /// if any.
    export fn ghostty_surface_read_selection(
        surface: *Surface,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        // If we don't have a selection, do nothing.
        const t: *terminal.Terminal = uiTerminalLocked(core_surface);
        const core_sel = t.screens.active.selection orelse return false;

        // Read the text from the selection.
        return readTextLocked(surface, core_sel, result);
    }

    /// Read some arbitrary text from the surface.
    ///
    /// This is an expensive operation so it shouldn't be called too
    /// often. We recommend that callers cache the result and throttle
    /// calls to this function.
    export fn ghostty_surface_read_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.core_surface.renderer_state.mutex.unlock(global.io());

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    /// Non-blocking variant of ghostty_surface_read_text for background
    /// scanners: if the renderer state mutex is contended, returns false
    /// immediately with `busy` set to true and `result` untouched, so the
    /// caller can reschedule instead of parking its thread behind a parse
    /// in progress. On an uncontended read, `busy` is false and the return
    /// value matches ghostty_surface_read_text.
    export fn ghostty_surface_try_read_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
        busy: *bool,
    ) bool {
        const mutex = surface.core_surface.renderer_state.mutex;
        if (!mutex.tryLock()) {
            busy.* = true;
            return false;
        }
        defer mutex.unlock(global.io());
        busy.* = false;

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    /// Replace the active user selection with an explicit selection range.
    export fn ghostty_surface_set_selection(
        surface: *Surface,
        sel: Selection,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen = core_surface.renderer_state.terminal.screens.active;
        const core_sel = sel.core(screen) orelse return false;

        core_surface.setSelection(core_sel) catch return false;
        screen.dirty.selection = true;
        core_surface.queueRender() catch return false;

        return true;
    }

    fn readTextLocked(
        surface: *Surface,
        core_sel: terminal.Selection,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;

        // Get our text directly from the core surface.
        const text = core_surface.dumpTextLocked(
            global.alloc(),
            core_sel,
        ) catch |err| {
            log.warn("error reading text err={}", .{err});
            return false;
        };

        const vp: CoreSurface.Text.Viewport = text.viewport orelse .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
        };

        result.* = .{
            .tl_px_x = vp.tl_px_x,
            .tl_px_y = vp.tl_px_y,
            .offset_start = vp.offset_start,
            .offset_len = vp.offset_len,
            .text = text.text.ptr,
            .text_len = text.text.len,
        };

        return true;
    }

    export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void {
        ptr.deinit();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Set a render-only vertical scroll offset in pixels.
    export fn ghostty_surface_set_smooth_scroll_offset(
        surface: *Surface,
        y_px: f64,
    ) void {
        surface.core_surface.setSmoothScrollOffset(y_px) catch |err| {
            log.err("error setting smooth scroll offset err={}", .{err});
        };
    }

    /// Set the HDR brightness-boost gain for this surface. 1.0 = SDR (no
    /// boost); values >1.0 drive the surface above SDR white via the EDR
    /// render path (half-float extended-linear target). Crossing the 1.0
    /// boundary recreates the render target/pipeline on the renderer thread.
    export fn ghostty_surface_set_brightness(surface: *Surface, gain: f32) void {
        const core = &surface.core_surface;
        _ = core.renderer_thread.mailbox.push(
            global.io(),
            .{ .set_brightness = gain },
            .{ .forever = {} },
        );
        core.renderer_thread.wakeup.notify() catch {};
    }

    // ROOTSHELL-REDACT BEGIN FROZEN-ABI (id=embedded-set-redact)
    // ghostty_surface_set_redact replaces this surface's display-only
    // redaction set ("auto redact"): every occurrence of a needle string in
    // the rendered viewport is drawn as a mask codepoint at the original
    // cell widths. Display-only by construction — it masks the renderer's
    // private row copies, so selection, copy, scrollback, search, and text
    // dumps still see the real content.
    //
    // needles: UTF-8, NUL-terminated strings. Fully copied before return;
    // the caller may free them immediately, and every element must be
    // non-NULL. count == 0 (or NULL array) disables redaction and clears
    // any prior needles — the app holds the source of truth and re-sends
    // the full list to re-enable. A set that fails to build falls back to
    // masking ALL text until a valid set arrives (fail closed; only an
    // explicit count == 0 disables). mask_codepoint == 0
    // selects the default U+2022 BULLET; a non-width-1 mask falls back to
    // the default. flags bit0 = case-insensitive matching.
    //
    // The needle strings are never persisted by libghostty; they live only
    // in renderer-thread memory. Call from the same serial queue that
    // calls ghostty_surface_free. Safe to call immediately after
    // ghostty_surface_new; applies within one frame.
    // Keep the signature stable. reapply: re-add this export inside the
    // CAPI struct. The renderer-side implementation is
    // src/renderer/redact.zig.
    export fn ghostty_surface_set_redact(
        surface: *Surface,
        needles: ?[*]const [*:0]const u8,
        count: usize,
        mask_codepoint: u32,
        flags: u32,
    ) void {
        const set: ?renderer.redact.Set = set: {
            const ptr = needles orelse break :set null;
            if (count == 0) break :set null;

            // A failed build must NOT be pushed as null: null means
            // "disable", and silently disabling on an allocation failure
            // would drop existing protection. Keeping the previous set is
            // not enough either — a just-added entry would render in the
            // clear while the app reports it protected. The allocation-
            // free fallback masks ALL text until a valid set arrives:
            // over-masked and obvious beats silently leaked.
            const built = renderer.redact.Set.init(
                global.alloc(),
                ptr[0..count],
                mask_codepoint,
                flags,
            ) catch |err| {
                log.warn("error building redact set, masking everything err={}", .{err});
                break :set renderer.redact.Set.maskAllFallback(global.alloc());
            };
            break :set built orelse {
                log.warn("redact set has no valid needles, masking everything", .{});
                break :set renderer.redact.Set.maskAllFallback(global.alloc());
            };
        };

        const core = &surface.core_surface;
        _ = core.renderer_thread.mailbox.push(
            global.io(),
            .{ .set_redact = set },
            .{ .forever = {} },
        );
        core.renderer_thread.wakeup.notify() catch {};
    }
    // ROOTSHELL-REDACT END FROZEN-ABI (id=embedded-set-redact)

    /// Set the preferred frame-rate range for this surface's render display
    /// link (iOS/visionOS CADisplayLink only; no-op on macOS, whose
    /// CVDisplayLink always follows the display). The power/battery lever:
    /// a lower range lets ProMotion panels idle down and caps GPU presents
    /// during output bursts. Values are clamped to 1...240 and reordered so
    /// min <= preferred <= max; max == 0 resets to the built-in default
    /// (min 60, max 120, preferred 120 — keep in sync with the
    /// default_rate_* constants in IOSDisplayLink.zig). Safe to call from
    /// any thread, any time after surface creation.
    export fn ghostty_surface_set_frame_rate_range(
        surface: *Surface,
        min: u16,
        max: u16,
        preferred: u16,
    ) void {
        const range: renderer.Message.FrameRateRange = range: {
            if (max == 0) break :range .{ .min = 60, .max = 120, .preferred = 120 };
            const max_c = std.math.clamp(max, 1, 240);
            const min_c = std.math.clamp(min, 1, max_c);
            const pref_c = std.math.clamp(
                if (preferred == 0) max_c else preferred,
                min_c,
                max_c,
            );
            break :range .{ .min = min_c, .max = max_c, .preferred = pref_c };
        };

        const core = &surface.core_surface;
        _ = core.renderer_thread.mailbox.push(
            global.io(),
            .{ .set_frame_rate = range },
            .{ .forever = {} },
        );
        core.renderer_thread.wakeup.notify() catch {};
    }

    /// Diagnostics: true if this surface's render display link reports running.
    /// Pairs with ghostty_surface_vsync_last_tick_age_ms to detect a wedged link
    /// (running but not delivering ticks) from the app side. Lockless atomic
    /// read on the app thread — valid even while the render thread is stalled.
    export fn ghostty_surface_vsync_running(surface: *Surface) bool {
        return surface.core_surface.renderer.displayLinkRunning();
    }

    /// Diagnostics: milliseconds since this surface's render display link last
    /// ticked, or -1 if it has never ticked / is unavailable. A large value
    /// while ghostty_surface_vsync_running() is true indicates a wedged link.
    /// iOS/visionOS only; -1 on macOS.
    export fn ghostty_surface_vsync_last_tick_age_ms(surface: *Surface) i64 {
        return surface.core_surface.renderer.displayLinkLastTickAgeMs();
    }

    /// Set a render-only signed rubber-band offset in pixels.
    export fn ghostty_surface_set_rubber_band_offset(
        surface: *Surface,
        y_px: f64,
    ) void {
        surface.core_surface.setRubberBandOffset(y_px) catch |err| {
            log.err("error setting rubber-band offset err={}", .{err});
        };
    }

    /// Scroll to an absolute row and apply a render-only offset in pixels.
    export fn ghostty_surface_scroll_to_row_smooth(
        surface: *Surface,
        row: usize,
        y_px: f64,
    ) void {
        surface.core_surface.scrollToRowSmooth(row, y_px) catch |err| {
            log.err("error setting smooth scroll row err={}", .{err});
        };
    }

    /// Reserve a bottom inset in framebuffer pixels (e.g. the iOS home-indicator
    /// safe-area strip). The grid and prompt stay put; the reserved strip renders
    /// blank at rest and is filled by smooth-scroll overscan rows when scrolled
    /// off the bottom. Pass 0 to clear.
    export fn ghostty_surface_set_bottom_inset(
        surface: *Surface,
        px: f64,
    ) void {
        surface.core_surface.setBottomInset(px) catch |err| {
            log.err("error setting bottom inset err={}", .{err});
        };
    }

    /// Begin a touch selection-handle drag anchored at the fixed (opposite)
    /// endpoint of the current selection. Subsequent ghostty_surface_mouse_pos
    /// calls extend the selection from that endpoint; a left-button release ends
    /// the drag. Returns false if there is no active selection.
    export fn ghostty_surface_selection_handle_drag_begin(
        surface: *Surface,
        dragging_start: bool,
    ) bool {
        return surface.core_surface.beginSelectionHandleDrag(dragging_start);
    }

    /// Report whether each endpoint of the current selection is within the
    /// viewport, so a touch UI can show only the visible endpoint's handle.
    export fn ghostty_surface_selection_viewport_visibility(
        surface: *Surface,
        start_visible: *bool,
        end_visible: *bool,
    ) bool {
        return surface.core_surface.selectionViewportVisibility(start_visible, end_visible);
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface: *Surface) SurfaceSize {
        const grid_size = surface.core_surface.size.grid();
        return .{
            .columns = grid_size.columns,
            .rows = grid_size.rows,
            .width_px = surface.core_surface.size.screen.width,
            .height_px = surface.core_surface.size.screen.height,
            .cell_width_px = surface.core_surface.size.cell.width,
            .cell_height_px = surface.core_surface.size.cell.height,
        };
    }

    /// Returns the PID of the foreground process for the surface PTY.
    export fn ghostty_surface_foreground_pid(surface: *Surface) u64 {
        return surface.core_surface.getProcessInfo(.foreground_pid) orelse 0;
    }

    /// Returns the PTY name for the surface. The returned string must be
    /// freed by the caller via ghostty_string_free.
    export fn ghostty_surface_tty_name(surface: *Surface) String {
        const tty_name = surface.core_surface.getProcessInfo(.tty_name) orelse return .empty;
        const copy = surface.app.core_app.alloc.dupeZ(u8, tty_name) catch |err| {
            log.err("error allocating tty name err={}", .{err});
            return .empty;
        };

        return .fromSlice(copy);
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface: *Surface, scheme_raw: c_int) void {
        const scheme = std.enums.fromInt(apprt.ColorScheme, scheme_raw) orelse return;
        surface.colorSchemeCallback(scheme);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Update the occlusion state of a surface.
    export fn ghostty_surface_set_occlusion(surface: *Surface, visible: bool) void {
        surface.occlusionCallback(visible);
    }

    /// Synchronously pause the surface's renderer before iOS suspends the
    /// app. Intended to be called from the apprt's main-thread scene
    /// transition hooks. Returns true if the renderer was confirmed paused
    /// within `timeout_ns` nanoseconds, false on timeout. See
    /// `Surface.drainRendererToIdle` for full rationale.
    export fn ghostty_surface_drain_renderer_to_idle(
        surface: *Surface,
        timeout_ns: u64,
    ) bool {
        return surface.core_surface.drainRendererToIdle(timeout_ns);
    }

    /// Set a callback that will be called after each frame is rendered.
    /// The callback receives the IOSurface pointer, width, and height.
    /// Used for visionOS curved display to capture rendered frames.
    export fn ghostty_surface_set_texture_callback(
        surface: *Surface,
        callback: ?*const fn (?*anyopaque, ?*anyopaque, c_ulong, c_ulong) callconv(.c) void,
        userdata: ?*anyopaque,
    ) void {
        surface.texture_callback = callback;
        surface.texture_callback_userdata = userdata;
    }

    /// Get the PTY master file descriptor for pipe-based external backend.
    /// Returns -1 if not using pipe backend or if FD is unavailable.
    /// Available on iOS and visionOS platforms.
    export fn ghostty_surface_pty_master_fd(surface: *Surface) c_int {
        // Mac Catalyst is included: it was `.ios` before Zig 0.16 gave it its
        // own OS tag, and rootshell sets `use_external_io` there too, so this
        // must keep returning the real fd for a pipe-backed surface.
        if (comptime builtin.os.tag != .ios and
            builtin.os.tag != .maccatalyst and
            builtin.os.tag != .visionos) return -1;

        // Access the backend through the termio
        switch (surface.core_surface.io.backend) {
            .pipe => |*p| return p.master_fd,
            else => return -1,
        }
    }

    /// Get the response pipe read FD for pipe backend.
    /// Swift should read from this FD to get terminal responses (e.g., cursor position).
    /// Returns -1 if not using pipe backend or if FD is unavailable.
    /// Available on iOS and visionOS platforms.
    export fn ghostty_surface_response_read_fd(surface: *Surface) c_int {
        // Mac Catalyst is included: it was `.ios` before Zig 0.16 gave it its
        // own OS tag, and rootshell sets `use_external_io` there too, so this
        // must keep returning the real fd for a pipe-backed surface.
        if (comptime builtin.os.tag != .ios and
            builtin.os.tag != .maccatalyst and
            builtin.os.tag != .visionos) return -1;

        // Access the backend through the termio
        switch (surface.core_surface.io.backend) {
            .pipe => |*p| return p.response_read_fd,
            else => return -1,
        }
    }

    /// Get the slave FD for writing shell output (pipe backend only).
    /// Returns -1 if not using pipe backend or if pipes not set up.
    /// External layer should write shell output to this FD using standard write() syscall.
    export fn ghostty_surface_get_slave_fd(surface: *Surface) c_int {
        const termio_impl = &surface.core_surface.io;
        return switch (termio_impl.backend) {
            .pipe => |*backend| @intCast(backend.slave_fd),
            else => -1,
        };
    }

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-capi-reconcile)
    // The CTmuxOpTag / CTmuxOp / CTmuxLayoutKind / CTmuxLayoutInfo extern types and
    // the ghostty_tmux_reconcile_* / ghostty_tmux_layout_* exports below are the
    // tmux reconcile C ABI the iOS Swift app consumes (TmuxReconcileDecoder in
    // Core/Tmux/TmuxController.swift). Keep the enum tag values (op 0-8, layout
    // 0-2), the extern struct field order, and the export signatures stable.
    // reapply: re-add this whole block inside the CAPI struct. See
    // docs/tmux-control-mode-fork.md.
    //---------------------------------------------------------------
    // tmux control mode: reconcile op-batch consumer (embedded apprt)
    //
    // The GHOSTTY_ACTION_TMUX_RECONCILE action carries an opaque
    // *CoreSurface.TmuxReconcilePayload. The Swift side walks the op
    // batch via these accessors, applies them to native tabs/splits,
    // and frees the payload with ghostty_tmux_reconcile_free when done.
    // Mirrors the GTK consumer (apprt/gtk application.zig:tmuxReconcile)
    // but adapted to the C boundary.

    const TmuxReconcilePayload = CoreSurface.TmuxReconcilePayload;
    const TmuxLayout = terminal.tmux.Layout;

    const CTmuxOpTag = enum(c_int) {
        sync_begin = 0,
        ensure_window = 1,
        ensure_pane = 2,
        set_layout = 3,
        set_focus = 4,
        prune_absent = 5,
        sync_end = 6,
        set_tab_title = 7,
        set_window_title = 8,
    };

    /// C-flat view of a single reconcile op. Sync with ghostty_tmux_op_s.
    const CTmuxOp = extern struct {
        tag: CTmuxOpTag,
        window_id: usize = 0,
        has_window_id: bool = false,
        pane_id: usize = 0,
        width: usize = 0,
        height: usize = 0,
        /// ensure_pane: *terminal.Terminal (opaque)
        viewer_terminal: ?*anyopaque = null,
        /// ensure_pane: *terminal.tmux.Viewer.Pane (opaque)
        viewer_pane: ?*anyopaque = null,
        /// set_layout: *const terminal.tmux.Layout (opaque, walk via accessors)
        layout: ?*const anyopaque = null,
        /// titles (not NUL-terminated; use title_len)
        title: ?[*]const u8 = null,
        title_len: usize = 0,
        /// prune_absent (sorted)
        window_ids: ?[*]const usize = null,
        window_ids_len: usize = 0,
        pane_ids: ?[*]const usize = null,
        pane_ids_len: usize = 0,
        /// ensure_window: tmux window display index. ROOTSHELL-TMUX
        /// (id=tmux-window-order)
        window_index: usize = 0,
        /// set_layout: the pane id shown fullscreen when the window is zoomed.
        /// Only meaningful when has_zoomed_pane_id is true: `%0` is a real
        /// pane, so 0 cannot double as "not zoomed" (the same reason
        /// window_id carries has_window_id). ROOTSHELL-TMUX (id=tmux-zoom)
        zoomed_pane_id: usize = 0,
        has_zoomed_pane_id: bool = false,
    };

    export fn ghostty_tmux_reconcile_op_count(payload: *TmuxReconcilePayload) usize {
        return payload.ops.len;
    }

    export fn ghostty_tmux_reconcile_op(
        payload: *TmuxReconcilePayload,
        index: usize,
        out: *CTmuxOp,
    ) bool {
        if (index >= payload.ops.len) return false;
        switch (payload.ops[index]) {
            .sync_windows_begin => out.* = .{ .tag = .sync_begin },
            .sync_windows_end => out.* = .{ .tag = .sync_end },
            .ensure_window => |w| out.* = .{
                .tag = .ensure_window,
                .window_id = w.tmux_window_id,
                .has_window_id = true,
                .width = w.width,
                .height = w.height,
                .window_index = w.index,
            },
            .ensure_pane => |p| out.* = .{
                .tag = .ensure_pane,
                .window_id = p.tmux_window_id,
                .has_window_id = true,
                .pane_id = p.pane_id,
                .viewer_terminal = if (p.viewer_terminal) |t| @ptrCast(t) else null,
                .viewer_pane = if (p.viewer_pane) |pp| @ptrCast(pp) else null,
            },
            .set_layout => |s| out.* = .{
                .tag = .set_layout,
                .window_id = s.tmux_window_id,
                .has_window_id = true,
                .layout = @ptrCast(s.layout),
                .zoomed_pane_id = s.zoomed_pane_id orelse 0,
                .has_zoomed_pane_id = s.zoomed_pane_id != null,
            },
            .set_focus => |f| out.* = .{
                .tag = .set_focus,
                .window_id = f.tmux_window_id,
                .has_window_id = true,
                .pane_id = f.pane_id,
            },
            .prune_absent => |pa| out.* = .{
                .tag = .prune_absent,
                .window_ids = pa.window_ids.ptr,
                .window_ids_len = pa.window_ids.len,
                .pane_ids = pa.pane_ids.ptr,
                .pane_ids_len = pa.pane_ids.len,
            },
            .set_tab_title => |t| out.* = .{
                .tag = .set_tab_title,
                .window_id = t.tmux_window_id,
                .has_window_id = true,
                .title = t.title.ptr,
                .title_len = t.title.len,
            },
            .set_window_title => |t| out.* = .{
                .tag = .set_window_title,
                .has_window_id = false,
                .title = t.title.ptr,
                .title_len = t.title.len,
            },
        }
        return true;
    }

    /// Free a reconcile payload. The Swift consumer calls this after it
    /// has applied all ops (the apprt owns the payload once the action
    /// callback returns success; see Surface.handleMessage).
    export fn ghostty_tmux_reconcile_free(payload: *TmuxReconcilePayload) void {
        payload.deinit();
    }

    const CTmuxLayoutKind = enum(c_int) {
        pane = 0,
        horizontal = 1,
        vertical = 2,
    };

    /// C-flat view of a layout node. Sync with ghostty_tmux_layout_info_s.
    const CTmuxLayoutInfo = extern struct {
        kind: CTmuxLayoutKind,
        width: usize = 0,
        height: usize = 0,
        x: usize = 0,
        y: usize = 0,
        /// valid when kind == pane
        pane_id: usize = 0,
        /// valid when kind == horizontal/vertical
        child_count: usize = 0,
    };

    export fn ghostty_tmux_layout_info(layout: *const TmuxLayout, out: *CTmuxLayoutInfo) void {
        switch (layout.content) {
            .pane => |id| out.* = .{
                .kind = .pane,
                .width = layout.width,
                .height = layout.height,
                .x = layout.x,
                .y = layout.y,
                .pane_id = id,
            },
            .horizontal => |ch| out.* = .{
                .kind = .horizontal,
                .width = layout.width,
                .height = layout.height,
                .x = layout.x,
                .y = layout.y,
                .child_count = ch.len,
            },
            .vertical => |ch| out.* = .{
                .kind = .vertical,
                .width = layout.width,
                .height = layout.height,
                .x = layout.x,
                .y = layout.y,
                .child_count = ch.len,
            },
        }
    }

    export fn ghostty_tmux_layout_child(
        layout: *const TmuxLayout,
        index: usize,
    ) ?*const TmuxLayout {
        return switch (layout.content) {
            .pane => null,
            .horizontal, .vertical => |ch| if (index < ch.len) &ch[index] else null,
        };
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-capi-reconcile)

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface: *Surface,
        mods_raw: c_int,
    ) c_int {
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = mods.translation(
            surface.core_surface.config.macos_option_as_alt orelse
                surface.app.keyboardLayout().detectOptionAsAlt(),
        );
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn ghostty_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_surface_key_is_binding(
        surface: *Surface,
        event: KeyEvent,
        c_flags: ?*input.Binding.Flags.C,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        const flags = surface.core_surface.keyEventIsBinding(
            core_event,
        ) orelse return false;
        if (c_flags) |ptr| ptr.* = flags.cval();
        return true;
    }

    /// Send raw text to the terminal. This is treated like a paste
    /// so this isn't useful for sending escape sequences. For that,
    /// individual key input should be used.
    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Write raw, already-encoded input bytes to the surface's IO without the
    /// clipboard-paste framing/filtering that `ghostty_surface_text` applies.
    /// Correct for pre-encoded terminal sequences (control keys like backspace,
    /// escape sequences). For a tmux control-mode pane the bytes are relayed
    /// verbatim as `send-keys` to tmux; otherwise they go to the pty.
    export fn ghostty_surface_send_input(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.core_surface.sendInput(ptr[0..len]) catch |err| {
            log.warn("error sending surface input err={}", .{err});
        };
    }

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-set-client-size)
    // ghostty_surface_tmux_set_client_size is the only client-resize entry point
    // the iOS Swift app has for tmux. Keep the signature stable. reapply: re-add
    // this export inside the CAPI struct. See docs/tmux-control-mode-fork.md.
    /// Set the tmux control-mode client size (in cells) for this surface's
    /// viewer. Posts to the IO thread, which sends `refresh-client -C` to tmux
    /// so the active window's panes are laid out to the given grid. No-op if the
    /// surface isn't a tmux control-mode gateway. Call this with the visible tmux
    /// tab's grid size when it changes (debounced).
    export fn ghostty_surface_tmux_set_client_size(
        surface: *Surface,
        cols: u16,
        rows: u16,
    ) void {
        surface.core_surface.io.queueMessage(.{
            .tmux_set_client_size = .{ .cols = cols, .rows = rows },
        }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-set-client-size)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-detach)
    // ghostty_surface_tmux_detach is the gateway ESC-to-detach entry point the iOS
    // Swift app calls. Keep the signature stable. reapply: re-add this export
    // inside the CAPI struct. See docs/tmux-control-mode-fork.md.
    /// Detach the tmux control-mode client for this surface's viewer, returning
    /// the gateway to its shell while leaving the tmux server/session alive.
    /// Posts to the IO thread, which queues a `detach-client` through the viewer's
    /// command queue. No-op if the surface isn't a tmux control-mode gateway.
    export fn ghostty_surface_tmux_detach(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_detach = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-detach)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-resume)
    // ghostty_surface_tmux_resume re-enters tmux control mode on a surface whose
    // tssh session reattached a still-live `tmux -CC` after the iOS app
    // relaunched. The fresh surface never saw the `ESC P 1000 p` preamble, so the
    // continuing control stream would render as garbage and no reconcile would
    // fire. The iOS app calls this once the restored gateway session is back in
    // the running state. Posts to the IO thread, which synthesizes control-mode
    // entry and drains/rebuilds via the viewer resync path. No-op if a viewer is
    // already active. Keep the signature stable. reapply: re-add this export
    // inside the CAPI struct. See docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_resume(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_resume = null }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-resume)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-resume-prioritized)
    // Cold-resume variant carrying the restored locally selected tmux window.
    // Unlike a follow-up reset message, keeping the preference in the resume
    // mailbox item cannot race the fresh viewer's creation.
    export fn ghostty_surface_tmux_resume_prioritized(surface: *Surface, window_id: usize) void {
        surface.core_surface.io.queueMessage(.{ .tmux_resume = window_id }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-resume-prioritized)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-resume-abort)
    // ghostty_surface_tmux_resume_abort aborts an in-progress resume started by
    // ghostty_surface_tmux_resume. The iOS app calls it from its resume watchdog
    // when no reconcile arrives (tmux died / session expired / the reattached pty
    // is at a bare shell), so the resync probe will never echo back. Tears down
    // the resync viewer and returns the gateway's parser to ground so its shell
    // renders normally. No-op if no viewer is active. Keep the signature stable.
    // reapply: re-add this export inside the CAPI struct. See
    // docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_resume_abort(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_resume_abort = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-resume-abort)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-recover)
    // ghostty_surface_tmux_recover heals a LIVE tmux control-mode gateway whose
    // command/response stream desynced or that lost mid-stream data (the tsshd
    // buffer overflowed while the app was backgrounded). The iOS app calls it
    // from its always-on wedge watchdog (a command stuck in-flight with a growing
    // queue) and on foreground if the gateway looks stalled. Drives a live
    // re-resync (re-probe + list-windows rebuild) WITHOUT tearing down panes.
    // No-op unless a viewer is live in the steady command-queue state — distinct
    // from ghostty_surface_tmux_resume, which only acts when NO viewer exists.
    // Keep the signature stable. reapply: re-add this export inside the CAPI
    // struct. See docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_recover(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_recover = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-recover)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-reset)
    // ghostty_surface_tmux_reset fully RESETS a LIVE tmux control-mode gateway to
    // a consistent state after a LOSSY reconnect: the tsshd server discarded
    // buffered terminal output (back-pressure-free discard mode), which can drop
    // bytes mid-`%output`/control block. Like ghostty_surface_tmux_recover it
    // re-resyncs the command channel WITHOUT tearing down panes, but it ALSO
    // force-recaptures every pane's grid/scrollback and re-arms the title
    // subscription, so the gateway is rebuilt identical to a fresh `tmux -CC
    // attach` plus full content — no duplicated scrollback, no tab flicker. The
    // iOS app calls it when the tssh transport reports a non-recoverable output
    // discard. No-op unless a viewer is live in the steady command-queue state.
    // Keep the signature stable. reapply: re-add this export inside the CAPI
    // struct. See docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_reset(surface: *Surface) void {
        // Set the barrier flag FIRST (id=termio-tmux-reset-barrier): the read
        // thread consumes it before parsing any bytes written after this call,
        // so the reset is ordered ahead of a foreground replay of gapped
        // output. The mailbox message remains the fallback executor when no
        // further bytes arrive to trigger the read-side consume.
        surface.core_surface.io.tmux_reset_preferred_window.store(std.math.maxInt(usize), .release);
        surface.core_surface.io.tmux_reset_pending.store(true, .release);
        surface.core_surface.io.queueMessage(.{ .tmux_reset = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-reset)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-reset-prioritized)
    // Append-only active-first reset ABI. The read-thread barrier consumes the
    // preferred window together with the reset before any gapped replay bytes.
    export fn ghostty_surface_tmux_reset_prioritized(surface: *Surface, window_id: usize) void {
        surface.core_surface.io.tmux_reset_preferred_window.store(window_id, .release);
        surface.core_surface.io.tmux_reset_pending.store(true, .release);
        surface.core_surface.io.queueMessage(.{ .tmux_reset = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-reset-prioritized)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-reprobe)
    // ghostty_surface_tmux_reprobe re-sends the resync probe on a gateway that is
    // ALREADY waiting for its marker, and does nothing else. The iOS app's resync
    // watchdog calls it on a cadence when a resync is overdue: the first probe can
    // be swallowed (the tsshd server discards pending INPUT across a reconnect),
    // and because a resyncing viewer sends nothing on its own, the stall cannot
    // self-heal — the re-send is what recovers it.
    //
    // Distinct from ghostty_surface_tmux_resume, whose no-viewer branch synthesizes
    // control-mode entry: a resume queued by that watchdog and drained AFTER the
    // viewer went away would RESURRECT the gateway over the revealed shell. This
    // entry point is a strict no-op unless a viewer exists and is resyncing, so the
    // app may queue it without tracking in-flight messages.
    // Keep the signature stable. reapply: re-add this export inside the CAPI
    // struct. See docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_reprobe(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_reprobe = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-reprobe)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-flush-deferred)
    // ghostty_surface_tmux_flush_deferred retries tmux pane work deferred by
    // bounded renderer-lock timeouts (spilled %output, deferred resizes,
    // dropped-spill re-fetch) and re-sends a topology snapshot dropped under
    // app-mailbox backpressure. The iOS app calls it on its gateway heartbeat
    // as an idle-session nudge (an active session retries on every inbound
    // event by itself). Cheap and idempotent when nothing is deferred; no-op
    // without a live viewer (except the teardown-snapshot retry). Keep the
    // signature stable. reapply: re-add this export inside the CAPI struct.
    // See docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_flush_deferred(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_flush_deferred = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-flush-deferred)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-force-exit)
    // ghostty_surface_tmux_force_exit forcibly exits control mode LOCALLY on a
    // live gateway when the app's recovery watchdog gives up on a wedge it cannot
    // heal. Equivalent to a `%exit`: tears down the viewer, emits the empty-
    // topology snapshot (the app prunes the projected tabs via the normal
    // reconcile path, which also drops the controller), and returns the parser to
    // ground so the gateway renders its shell. Unlike ghostty_surface_tmux_detach
    // it does not wait for tmux to answer a detach-client, so it works even when
    // tmux/the link is unresponsive. The tmux server/session stays alive. No-op
    // if no viewer is active. Keep the signature stable. reapply: re-add this
    // export inside the CAPI struct. See docs/tmux-control-mode-fork.md.
    export fn ghostty_surface_tmux_force_exit(surface: *Surface) void {
        surface.core_surface.io.queueMessage(.{ .tmux_force_exit = {} }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-force-exit)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-active)
    // ghostty_surface_tmux_active is the iOS Swift app's ESC escape-hatch probe:
    // it lets the app detach (via ghostty_surface_tmux_detach) whenever this
    // surface's core is actually in tmux control mode, even if the app's
    // TmuxController was torn down — so the user can never get trapped in a stuck
    // gateway. Reads an atomic flag the IO thread keeps in sync with the viewer
    // (NOT the viewer pointer itself, which the IO thread can free); a stale value
    // only costs one no-op ESC during teardown. Keep the signature stable.
    // reapply: re-add this export inside the CAPI struct. See
    // docs/tmux-control-mode-fork.md.
    /// Returns true while this surface is a live tmux control-mode gateway.
    export fn ghostty_surface_tmux_active(surface: *Surface) bool {
        return surface.core_surface.io.terminal_stream.handler.tmuxActive();
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-active)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-command)
    // ghostty_surface_tmux_command lets the iOS Swift app hand a pre-formatted
    // tmux control command (e.g. `split-window -h -t %0\n`, `kill-pane -t %1\n`)
    // to the gateway's viewer command queue. Keep the signature stable. reapply:
    // re-add this export inside the CAPI struct. See docs/tmux-control-mode-fork.md.
    /// Queue a raw, newline-terminated tmux command through this surface's viewer
    /// command queue (FIFO-safe, NOT a raw write that would desync the response
    /// FIFO). The bytes are copied; `len` excludes any terminator. Reuses the
    /// `tmux_pane_command` path: posts to the IO thread, which routes through
    /// `tmuxQueuePaneCommand` -> `queueRelayedPaneCommand` and flushes the queue.
    /// No-op if the surface isn't a tmux control-mode gateway. Used by the app to
    /// drive split-window / kill-pane so tmux owns the topology and the resulting
    /// reconcile rebuilds the native splits.
    export fn ghostty_surface_tmux_command(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        const alloc = surface.app.core_app.alloc;
        const copy = alloc.dupe(u8, ptr[0..len]) catch return;
        surface.core_surface.io.queueMessage(.{ .tmux_pane_command = .{
            .alloc = alloc,
            .data = copy,
        } }, .unlocked);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-command)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-command-with-reply)
    // ghostty_surface_tmux_command_with_reply lets the iOS Swift app run a tmux
    // query (e.g. `list-sessions -F ...`, `new-session -d -s x -PF '#{session_id}'`)
    // whose response it needs to read. The block response (or %error body) comes
    // back via the action callback as GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE,
    // correlated by `tag` (app-chosen, echoed verbatim). If the gateway has no
    // viewer or the query is dropped by a viewer reset before tmux answers, an
    // error response with an empty body is delivered instead — the app should
    // still keep its own timeout as the final backstop. Keep the signature
    // stable. reapply: re-add this export inside the CAPI struct. See
    // docs/tmux-control-mode-fork.md.
    /// Queue a raw, newline-terminated tmux command through this surface's
    /// viewer command queue and deliver its response back through the action
    /// callback (GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE) correlated by `tag`.
    /// The bytes are copied.
    export fn ghostty_surface_tmux_command_with_reply(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
        tag: u32,
    ) void {
        const alloc = surface.app.core_app.alloc;
        const copy = alloc.dupe(u8, ptr[0..len]) catch return;
        const payload = alloc.create(TmuxQueryCommand) catch {
            alloc.free(copy);
            return;
        };
        payload.* = .{
            .alloc = alloc,
            .data = copy,
            .tag = tag,
        };
        surface.core_surface.io.queueMessage(
            .{ .tmux_query_command = payload },
            .unlocked,
        );
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-command-with-reply)

    // ROOTSHELL-TMUX BEGIN FROZEN-ABI (id=embedded-tmux-debug-snapshot)
    // ghostty_surface_tmux_debug_snapshot fills a privacy-safe scalar snapshot of
    // this gateway's tmux control-mode internals (viewer/parser state, command
    // queue + sent-FIFO depths, in-flight command kind, pending pane responses,
    // ages) for the iOS debug log. Lockless atomic read on the app thread (NO
    // IO-thread hop), so it stays valid even when control mode is protocol-stalled
    // — the exact case it exists to diagnose. Returns false (and zero-fills `out`)
    // when the surface isn't a live tmux gateway. The first call enables the cheap
    // IO-thread mirror refresh. The `ghostty_tmux_debug_snapshot_s` layout is
    // FROZEN: only append fields and bump `abi_version`; keep it byte-for-byte in
    // sync with include/ghostty.h. reapply: re-add this export inside the CAPI
    // struct plus the TmuxDebugSnapshot extern struct in stream_handler.zig. See
    // docs/tmux-control-mode-fork.md.
    /// Fill `out` with a privacy-safe snapshot of this surface's tmux
    /// control-mode internals. Returns true if filled (live tmux gateway),
    /// false if not (and `out` is zeroed).
    export fn ghostty_surface_tmux_debug_snapshot(
        surface: *Surface,
        out: *TmuxDebugSnapshot,
    ) bool {
        return surface.core_surface.io.terminal_stream.handler.tmuxDebugSnapshot(out);
    }
    // ROOTSHELL-TMUX END FROZEN-ABI (id=embedded-tmux-debug-snapshot)

    /// Set the preedit text for the surface. This is used for IME
    /// composition. If the length is 0, then the preedit text is cleared.
    export fn ghostty_surface_preedit(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.preeditCallback(if (len == 0) null else ptr[0..len]);
    }

    /// Returns true if the surface currently has mouse capturing
    /// enabled.
    export fn ghostty_surface_mouse_captured(surface: *Surface) bool {
        return surface.core_surface.mouseCaptured();
    }

    /// Returns whether cursor key application mode (DECCKM) is active.
    /// When true, arrow keys should send SS3 sequences (\x1bOA, etc.)
    /// When false, arrow keys should send CSI sequences (\x1b[A, etc.)
    export fn ghostty_surface_cursor_key_mode(surface: *Surface) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        return core_surface.renderer_state.terminal.modes.get(.cursor_keys);
    }

    /// Returns the total number of rows in the primary screen (including scrollback).
    /// This is a cheap check (single field read) useful for change detection.
    export fn ghostty_surface_total_rows(surface: *Surface) usize {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        // Use the DISPLAYED terminal (renderer_state.terminal), not io.terminal:
        // for a tmux control-mode pane the rendered terminal is the viewer-owned
        // pane terminal (which holds the scrollback), while io.terminal is an
        // empty dummy. Reading io.terminal here makes the iPad touch-scroll path
        // see zero scrollback rows and refuse to scroll into history. Same pointer
        // for a normal surface. Held under renderer_state.mutex (the viewer writes
        // the pane terminal under the same mutex).
        const screen = core_surface.renderer_state.terminal.screens.get(.primary) orelse return 0;
        return screen.pages.total_rows;
    }

    /// Returns the displayed terminal's primary-screen scrollbar state.
    /// This targets the viewer-owned terminal for tmux panes, avoiding the
    /// dummy `io.terminal` offset used by the relay backend.
    export fn ghostty_surface_display_scrollbar(
        surface: *Surface,
        out: *terminal.Scrollbar.C,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen = uiTerminalLocked(core_surface).screens.get(.primary) orelse return false;
        const scrollbar = screen.pages.scrollbar();
        if (scrollbar.total <= scrollbar.len) return false;

        out.* = scrollbar.cval();
        return true;
    }

    /// Dump the entire primary screen (including scrollback) as ANSI-styled text.
    /// Always reads from the primary screen (not alternate), so scrollback is captured
    /// even when an alternate-screen app like vim is active. Uses unwrap mode so
    /// soft-wrapped lines are joined and re-wrap naturally at any terminal width.
    /// Palette colors are emitted as indices (38;5;N) so they adapt to theme changes.
    /// Returns null if the screen is empty. Caller must free with ghostty_surface_free_dump.
    export fn ghostty_surface_dump_primary_screen(
        surface: *Surface,
        out_len: *usize,
    ) ?[*]const u8 {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const t: *terminal.Terminal = uiTerminalLocked(core_surface);
        const screen = t.screens.get(.primary) orelse return null;
        _ = screen.pages.getBottomRight(.screen) orelse return null;

        const tl_active = screen.pages.getTopLeft(.active);
        const br_active = screen.pages.getBottomRight(.active) orelse return null;

        // Adjust the scrollback/active boundary so it doesn't split a
        // soft-wrapped line. If the last scrollback row has wrap=true,
        // the first active row is a continuation. Walk the boundary
        // forward (into the active area) until we find a row that is
        // NOT a wrap continuation, keeping the full wrapped line in the
        // scrollback pass to preserve unwrap continuity.
        var adjusted_tl_active = tl_active;
        var boundary_offset: usize = 0;
        while (true) {
            const above = adjusted_tl_active.up(1) orelse break;
            if (!above.rowAndCell().row.wrap) break;
            // Row above has wrap=true, so adjusted_tl_active is a
            // continuation. Move it forward past this row.
            adjusted_tl_active = adjusted_tl_active.down(1) orelse break;
            boundary_offset += 1;
        }

        var aw: std.Io.Writer.Allocating = .init(global.alloc());

        const fmt_opts: terminal.formatter.Options = .{
            .emit = .vt,
            .unwrap = true,
            .trim = false,
            .palette = &t.colors.palette.current,
        };

        // Phase 1: Dump scrollback (everything above the adjusted active
        // boundary). We check if there's a row above the boundary; if so,
        // scrollback exists and we dump it separately.
        const has_scrollback = adjusted_tl_active.up(1) != null;
        if (has_scrollback) {
            const tl_screen = screen.pages.getTopLeft(.screen);
            var br_scrollback = adjusted_tl_active.up(1).?;
            br_scrollback.x = screen.pages.cols - 1;

            var scrollback_fmt: terminal.formatter.ScreenFormatter = .init(screen, fmt_opts);
            scrollback_fmt.content = .{
                .selection = terminal.Selection.init(tl_screen, br_scrollback, false),
            };
            scrollback_fmt.format(&aw.writer) catch {
                aw.deinit();
                return null;
            };

            // Emit LF × rows to push scrollback content into the
            // scrollback buffer. Unlike SU (which scrolls regardless of
            // cursor position and can inject blank rows into history),
            // LF first moves the cursor down through existing blank rows
            // without scrolling, then only scrolls when it reaches the
            // bottom margin — so only actual content enters scrollback.
            for (0..screen.pages.rows) |_| {
                aw.writer.writeByte('\n') catch {
                    aw.deinit();
                    return null;
                };
            }
        }

        // Phase 2: Emit active area on a clean viewport.
        // Reset SGR, home the cursor, then clear from home before writing
        // active content. The earlier scrollback replay may leave wider
        // historical rows in the viewport; clearing here prevents shorter
        // active rows (for example prompts) from drawing over stale cells.
        aw.writer.writeAll("\x1b[0m\x1b[H\x1b[J") catch {
            aw.deinit();
            return null;
        };

        var active_fmt: terminal.formatter.ScreenFormatter = .init(screen, fmt_opts);
        active_fmt.content = .{
            .selection = terminal.Selection.init(adjusted_tl_active, br_active, false),
        };
        active_fmt.format(&aw.writer) catch {
            aw.deinit();
            return null;
        };

        // Erase from cursor to end of display (ED 0). This clears any
        // remaining viewport rows below the active content, adapting
        // correctly to any terminal size on restore.
        // Reset SGR first so the erase uses default background color.
        aw.writer.writeAll("\x1b[0m\x1b[J") catch {
            aw.deinit();
            return null;
        };

        // Position cursor within the active area. Adjust for any rows
        // that were moved from the active area into the scrollback pass
        // due to wrap continuation boundary adjustment.
        const cursor = screen.cursor;
        const cursor_y: usize = cursor.y;
        const adjusted_y = if (cursor_y >= boundary_offset)
            cursor_y - boundary_offset
        else
            0;
        aw.writer.print("\x1b[{d};{d}H", .{ adjusted_y + 1, @as(usize, cursor.x) + 1 }) catch {
            aw.deinit();
            return null;
        };

        const text = aw.toOwnedSliceSentinel(0) catch {
            aw.deinit();
            return null;
        };

        if (text.len == 0) {
            global.alloc().free(text);
            return null;
        }

        out_len.* = text.len;
        return text.ptr;
    }

    /// Dump the alternate screen active viewport as ANSI-styled text.
    /// Returns null if the alternate screen is not initialized (no TUI app
    /// has ever switched to it) or if it is empty. Uses unwrap=false to
    /// preserve TUI layout (cursor-addressed apps like vim, htop, etc.).
    /// Caller must free with ghostty_surface_free_dump.
    export fn ghostty_surface_dump_alternate_screen(
        surface: *Surface,
        out_len: *usize,
    ) ?[*]const u8 {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const t: *terminal.Terminal = uiTerminalLocked(core_surface);
        const screen = t.screens.get(.alternate) orelse return null;
        const br_active = screen.pages.getBottomRight(.active) orelse return null;
        const tl_active = screen.pages.getTopLeft(.active);

        var aw: std.Io.Writer.Allocating = .init(global.alloc());

        const fmt_opts: terminal.formatter.Options = .{
            .emit = .vt,
            .unwrap = false,
            .trim = false,
            .palette = &t.colors.palette.current,
        };

        // Home cursor, then emit the active viewport.
        aw.writer.writeAll("\x1b[H") catch {
            aw.deinit();
            return null;
        };

        var active_fmt: terminal.formatter.ScreenFormatter = .init(screen, fmt_opts);
        active_fmt.content = .{
            .selection = terminal.Selection.init(tl_active, br_active, false),
        };
        active_fmt.format(&aw.writer) catch {
            aw.deinit();
            return null;
        };

        // Reset SGR and erase from cursor to end of display.
        aw.writer.writeAll("\x1b[0m\x1b[J") catch {
            aw.deinit();
            return null;
        };

        // Position cursor.
        const cursor = screen.cursor;
        aw.writer.print("\x1b[{d};{d}H", .{ @as(usize, cursor.y) + 1, @as(usize, cursor.x) + 1 }) catch {
            aw.deinit();
            return null;
        };

        const text = aw.toOwnedSliceSentinel(0) catch {
            aw.deinit();
            return null;
        };

        if (text.len == 0) {
            global.alloc().free(text);
            return null;
        }

        out_len.* = text.len;
        return text.ptr;
    }

    /// Returns true if the terminal's alternate screen is currently active
    /// (e.g., a TUI app like vim/helix is running). Used by the iOS app to
    /// detect which screen was active before app eviction so it can switch
    /// to alternate before reconnect output arrives, protecting primary scrollback.
    export fn ghostty_surface_is_alternate_active(surface: *Surface) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        return uiTerminalLocked(core_surface).screens.active_key == .alternate;
    }

    /// Non-blocking variant of ghostty_surface_is_alternate_active for
    /// background scanners: returns false without writing `out` when the
    /// renderer state mutex is contended, true with `out` filled otherwise.
    export fn ghostty_surface_try_is_alternate_active(
        surface: *Surface,
        out: *bool,
    ) bool {
        const core_surface = &surface.core_surface;
        const mutex = core_surface.renderer_state.mutex;
        if (!mutex.tryLock()) return false;
        defer mutex.unlock(global.io());
        out.* = uiTerminalLocked(core_surface).screens.active_key == .alternate;
        return true;
    }

    /// Free text returned by ghostty_surface_dump_primary_screen.
    export fn ghostty_surface_free_dump(
        ptr: [*]const u8,
        len: usize,
    ) void {
        global.alloc().free(ptr[0..len :0]);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) bool {
        return surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface: *Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) void {
        surface.cursorPosCallback(
            x,
            y,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface: *Surface,
        stage_raw: u32,
        pressure: f64,
    ) void {
        const stage = std.enums.fromInt(input.MousePressureStage, stage_raw) orelse return;
        surface.mousePressureCallback(stage, pressure);
    }

    export fn ghostty_surface_ime_point(
        surface: *Surface,
        x: *f64,
        y: *f64,
        width: *f64,
        height: *f64,
    ) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
        width.* = pos.width;
        height.* = pos.height;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: apprt.action.SplitDirection) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr: *Surface,
        direction: apprt.action.ResizeSplit.Direction,
        amount: u16,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr: *Surface) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        return ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={f} err={}", .{ action, err });
            return false;
        };
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        ptr.completeClipboardRequest(
            std.mem.sliceTo(str, 0),
            state,
            confirmed,
        );
    }

    export fn ghostty_surface_inspector(ptr: *Surface) ?*Inspector {
        return ptr.initInspector() catch |err| {
            log.err("error initializing inspector err={}", .{err});
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr: *Surface) void {
        ptr.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {
        ptr.updateSize(w, h);
    }

    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {
        ptr.updateContentScale(x, y);
    }

    export fn ghostty_inspector_mouse_button(
        ptr: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        ptr.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {
        ptr.cursorPosCallback(x, y);
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr: *Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        ptr.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_inspector_key(
        ptr: *Inspector,
        action: input.Action,
        key: input.Key,
        c_mods: c_int,
    ) void {
        ptr.keyCallback(
            action,
            key,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(c_mods))),
            )),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return;
        };
    }

    export fn ghostty_inspector_text(
        ptr: *Inspector,
        str: [*:0]const u8,
    ) void {
        ptr.textCallback(std.mem.sliceTo(str, 0));
    }

    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {
        ptr.focusCallback(focused);
    }

    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    /// Note: This is disabled for App Store builds (-Dappstore=true) as
    /// CGS functions are private APIs that Apple rejects.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS and Mac Catalyst
        if (comptime builtin.target.os.tag != .macos and
            builtin.target.os.tag != .maccatalyst) return;

        // Disabled for App Store builds - CGS functions are private APIs
        if (comptime build_config.appstore) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // Darwin-only C APIs.
    const Darwin = struct {
        export fn ghostty_surface_set_display_id(ptr: *Surface, display_id: u32) void {
            const surface = &ptr.core_surface;
            _ = surface.renderer_thread.mailbox.push(
                global.io(),
                .{ .macos_display_id = display_id },
                .{ .forever = {} },
            );
            surface.renderer_thread.wakeup.notify() catch {};
        }

        /// This returns a CTFontRef that should be used for quicklook
        /// highlighted text. This is always the primary font in use
        /// regardless of the selected text. If coretext is not in use
        /// then this will return nothing.
        export fn ghostty_surface_quicklook_font(ptr: *Surface) ?*anyopaque {
            // For non-CoreText we just return null.
            if (comptime font.options.backend != .coretext) {
                return null;
            }

            // We'll need content scale so fail early if we can't get it.
            const content_scale = ptr.getContentScale() catch return null;

            // Get the shared font grid. We acquire a read lock to
            // read the font face. It should not be deferred since
            // we're loading the primary face.
            const grid = ptr.core_surface.renderer.font_grid;
            grid.lock.lockSharedUncancelable(global.io());
            defer grid.lock.unlockShared(global.io());

            const collection = &grid.resolver.collection;
            const face = collection.getFace(.{}) catch return null;

            // We need to unscale the content scale. We apply the
            // content scale to our font stack because we are rendering
            // at 1x but callers of this should be using scaled or apply
            // scale themselves.
            const size: f32 = size: {
                const num = face.font.copyAttribute(.size) orelse
                    break :size 12;
                defer num.release();
                var v: f32 = 12;
                _ = num.getValue(.float, &v);
                break :size v;
            };

            const copy = face.font.copyWithAttributes(
                size / content_scale.y,
                null,
                null,
            ) catch return null;

            return copy;
        }

        /// This returns the selected word for quicklook. This will populate
        /// the buffer with the word under the cursor and the selection
        /// info so that quicklook can be rendered.
        ///
        /// This does not modify the selection active on the surface (if any).
        export fn ghostty_surface_quicklook_word(
            ptr: *Surface,
            result: *Text,
        ) bool {
            const surface = &ptr.core_surface;
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());

            // Get our word selection
            const sel = sel: {
                const screen: *terminal.Screen = surface.renderer_state.terminal.screens.active;
                const pos = try ptr.getCursorPos();
                const pt_viewport = surface.posToViewport(pos.x, pos.y);
                const pin = screen.pages.pin(.{
                    .viewport = .{
                        .x = pt_viewport.x,
                        .y = pt_viewport.y,
                    },
                }) orelse {
                    if (comptime std.debug.runtime_safety) unreachable;
                    return false;
                };
                break :sel screen.selectWordOrIPv6(
                    pin,
                    surface.config.selection_word_chars,
                ) orelse return false;
            };

            // Read the selection
            return readTextLocked(ptr, sel, result);
        }

        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {
            return ptr.initMetal(.fromId(device));
        }

        export fn ghostty_inspector_metal_render(
            ptr: *Inspector,
            command_buffer: objc.c.id,
            descriptor: objc.c.id,
        ) void {
            return ptr.renderMetal(
                .fromId(command_buffer),
                .fromId(descriptor),
            ) catch |err| {
                log.err("error rendering inspector err={}", .{err});
                return;
            };
        }

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
        }
    };
};
