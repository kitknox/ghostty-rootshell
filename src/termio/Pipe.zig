const std = @import("std");
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");
const global = @import("../global.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const termio = @import("../termio.zig");
const internal_os = @import("../os/main.zig");
const pty_pkg = @import("../pty.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.termio_pipe);

/// Pipe backend: Uses pipes instead of PTY for platforms where PTY isn't available
/// or when external I/O management is preferred. The external layer (e.g., Swift)
/// manages all I/O through these pipes.
pub const Pipe = @This();

/// Input pipe: Swift → Ghostty (shell output to display)
/// - master_fd: Ghostty reads shell output from here
/// - slave_fd: Swift writes shell output here
master_fd: posix.fd_t,
slave_fd: posix.fd_t,

/// Response pipe: Ghostty → Swift (terminal responses like cursor position)
/// - response_read_fd: Swift reads terminal responses from here
/// - response_write_fd: Ghostty writes terminal responses here
response_read_fd: posix.fd_t,
response_write_fd: posix.fd_t,

/// Current window size (tracked for resize operations)
current_size: pty_pkg.winsize,

/// Atomic quit flag — set by threadExit, checked by the read thread's tight loop.
/// Unlike Exec which kills the subprocess to stop data flow, the Pipe backend's
/// producer (Swift/SSH) isn't stopped during exit. Without this flag, a continuously
/// noisy writer could prevent the read thread from ever reaching poll() to see
/// the quit pipe signal.
quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

pub const Config = struct {
    /// Working directory (optional)
    cwd: ?[]const u8 = null,
};

pub const Options = struct {
    /// Working directory
    cwd: ?[]const u8 = null,
};

pub fn init(alloc: Allocator, opts: Options) !Pipe {
    _ = alloc;
    _ = opts;

    // Create input pipe (Swift → Ghostty)
    const input_fds = try compat_fd.pipe();
    errdefer compat_fd.close(input_fds[0]);
    errdefer compat_fd.close(input_fds[1]);

    const master_fd = input_fds[0]; // Read end
    const slave_fd = input_fds[1]; // Write end

    // Create response pipe (Ghostty → Swift)
    const response_fds = try compat_fd.pipe();
    errdefer compat_fd.close(response_fds[0]);
    errdefer compat_fd.close(response_fds[1]);

    const response_read_fd = response_fds[0]; // Read end (for Swift)
    const response_write_fd = response_fds[1]; // Write end (for Ghostty)

    // Set all pipe ends to non-blocking mode. Zig 0.16 dropped the
    // `posix.fcntl` wrapper, so go through `posix.system` directly and check
    // errno ourselves, the same way `pty.zig` now does.
    for ([_]posix.fd_t{
        master_fd,
        slave_fd,
        response_read_fd,
        response_write_fd,
    }) |fd| try setNonblocking(fd);

    log.info("Pipe: created input pipe (master_fd={}, slave_fd={})", .{ master_fd, slave_fd });
    log.info("Pipe: created response pipe (response_read_fd={}, response_write_fd={})", .{ response_read_fd, response_write_fd });

    return .{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
        .response_read_fd = response_read_fd,
        .response_write_fd = response_write_fd,
        .current_size = .{
            .ws_row = 24,
            .ws_col = 80,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        },
    };
}

/// Set O_NONBLOCK on `fd`. Zig 0.16 removed `std.posix.fcntl`.
fn setNonblocking(fd: posix.fd_t) !void {
    const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (flags == -1) return error.FcntlFailed;
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    return switch (posix.errno(posix.system.fcntl(
        fd,
        posix.F.SETFL,
        @as(usize, @intCast(flags)) | nonblock,
    ))) {
        .SUCCESS => {},
        else => error.FcntlFailed,
    };
}

pub fn deinit(self: *Pipe) void {
    // Close all pipe FDs
    if (self.master_fd >= 0) compat_fd.close(self.master_fd);
    if (self.slave_fd >= 0) compat_fd.close(self.slave_fd);
    if (self.response_read_fd >= 0) compat_fd.close(self.response_read_fd);
    if (self.response_write_fd >= 0) compat_fd.close(self.response_write_fd);
    log.info("Pipe cleaned up", .{});
}

/// Initialize terminal state (called before thread starts)
pub fn initTerminal(self: *Pipe, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
    // Nothing to do - external layer handles shell
}

/// Thread data for this backend
pub const ThreadData = struct {
    /// Reference to the Termio instance (needed for processOutput callback)
    io: *termio.Termio,

    /// Read thread handle
    read_thread: std.Thread,

    /// Write end of the quit pipe — write to this to signal the read thread to exit
    read_thread_pipe: posix.fd_t,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        compat_fd.close(self.read_thread_pipe);
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

/// Called when thread starts
pub fn threadEnter(
    self: *Pipe,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Create a pipe for signaling the read thread to exit.
    // pipe[0] is the read end (for the thread), pipe[1] is the write end (for us).
    const quit_pipe = try internal_os.pipe();
    errdefer compat_fd.close(quit_pipe[0]);
    errdefer compat_fd.close(quit_pipe[1]);

    // Reset quit flag (in case of reuse after a previous session).
    self.quit.store(false, .release);

    // Spawn the read thread — it will read from master_fd on its own thread,
    // freeing the IO event loop thread to drain the termio mailbox concurrently.
    const read_thread = try std.Thread.spawn(
        .{ .stack_size = internal_os.thread_stack_size_small },
        ReadThread.threadMainPosix,
        .{ self.master_fd, io, quit_pipe[0], &self.quit },
    );
    read_thread.setName(global.io(), "io-reader") catch {};

    // Store thread handle and quit pipe write end in ThreadData
    td.backend = .{ .pipe = .{
        .io = io,
        .read_thread = read_thread,
        .read_thread_pipe = quit_pipe[1],
    } };

    log.info("termio thread started with read thread (master_fd={})", .{self.master_fd});
}

/// Called when thread exits
pub fn threadExit(self: *Pipe, td: *termio.Termio.ThreadData) void {
    const pipe_data = &td.backend.pipe;

    // Set the atomic quit flag so the tight read loop exits promptly
    // even if data is still flowing (unlike Exec, we can't kill the producer).
    self.quit.store(true, .release);

    // Also signal via quit pipe to wake the thread if it's blocked in poll().
    // Zig 0.16 dropped the `posix.write` wrapper; go through `posix.system`
    // and check errno directly, the same way `Exec.zig` now does. EPIPE means
    // the read thread already exited, which is fine. Retry EINTR: without the
    // byte the read thread can sit in poll(-1) forever and join() below hangs.
    while (true) {
        switch (posix.errno(posix.system.write(pipe_data.read_thread_pipe, "x", 1))) {
            .SUCCESS, .PIPE => break,
            .INTR => continue,
            else => |err| {
                log.warn(
                    "error writing to read thread quit pipe err=E{s}",
                    .{@tagName(err)},
                );
                break;
            },
        }
    }

    // Wait for the read thread to finish
    pipe_data.read_thread.join();

    log.info("termio thread exited", .{});
}

/// Handle focus changes
pub fn focusGained(
    self: *Pipe,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // Could send focus events to Swift layer via callback if needed
}

/// Handle terminal resize
pub fn resize(
    self: *Pipe,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    // Update tracked size (Swift layer will handle actual resize via setSize callback)
    self.current_size = .{
        .ws_row = @intCast(grid_size.rows),
        .ws_col = @intCast(grid_size.columns),
        .ws_xpixel = @intCast(screen_size.width),
        .ws_ypixel = @intCast(screen_size.height),
    };

    log.info("resized terminal: {}x{}", .{ grid_size.rows, grid_size.columns });
}

/// Queue write to response pipe (terminal responses like cursor position)
/// This is called when Ghostty needs to send data back to the external layer
pub fn queueWrite(
    self: *Pipe,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;

    if (data.len == 0) return;

    // Write terminal responses to the response pipe for Swift to read.
    //
    // Bracketed paste can be a large write on this path. The fd is
    // non-blocking, so the pipe may fill between Swift read-source drains. We
    // must wait for writable and continue instead of returning WouldBlock; if
    // the paste end marker is not delivered, Swift keeps buffering the paste
    // indefinitely waiting for ESC[201~.
    try self.writeAllToResponsePipe(data);

    // Handle linefeed if requested
    if (linefeed) {
        try self.writeAllToResponsePipe("\n");
    }
}

fn writeAllToResponsePipe(self: *Pipe, data: []const u8) !void {
    var total_written: usize = 0;
    var pollfds: [1]posix.pollfd = .{.{
        .fd = self.response_write_fd,
        .events = posix.POLL.OUT,
        .revents = undefined,
    }};

    while (total_written < data.len) {
        const remaining = data[total_written..];
        // `posix.write` is gone in Zig 0.16; use the raw syscall and map errno
        // back onto the two cases this loop cares about.
        const rc = posix.system.write(
            self.response_write_fd,
            remaining.ptr,
            remaining.len,
        );
        const written: usize = switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            .AGAIN => {
                _ = posix.poll(&pollfds, -1) catch |poll_err| {
                    log.warn("response pipe poll failed: {}", .{poll_err});
                    return poll_err;
                };

                if (pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                    log.warn("response pipe closed while waiting for writable", .{});
                    return error.BrokenPipe;
                }

                continue;
            },
            .PIPE => {
                log.warn("response pipe closed while writing", .{});
                return error.BrokenPipe;
            },
            else => |err| {
                log.warn("failed to write to response pipe: E{s}", .{@tagName(err)});
                return error.WriteFailed;
            },
        };

        if (written == 0) {
            log.warn("response pipe closed", .{});
            return error.BrokenPipe;
        }

        total_written += written;
    }
}

/// Handle abnormal child exit
pub fn childExitedAbnormally(
    self: *Pipe,
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
    // External layer (Swift) manages the shell, so we don't handle exits here
}

/// Dedicated read thread for the Pipe backend.
///
/// This runs on a separate OS thread from the IO event loop, reading data from
/// the master_fd (pipe read end) and calling processOutput. This architecture
/// prevents deadlocks that occur when the read callback runs on the same thread
/// as the mailbox consumer — heavy output (e.g., Zellij) can fill the 64-slot
/// mailbox faster than it drains because draining requires the event loop, which
/// is blocked in the read callback.
///
/// Modeled directly on Exec.zig's ReadThread.
pub const ReadThread = struct {
    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t, quit_flag: *std.atomic.Value(bool)) void {
        // Always close our end of the quit pipe when we exit.
        defer compat_fd.close(quit);

        // Set thread name on Darwin (std.Thread.setName can only name the
        // current thread on Darwin, and we have no way to get it from within).
        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-reader".*);
        }

        // Set the fd to non-blocking so we can do a tight read loop and
        // only fall back to poll when data runs out.
        setNonblocking(fd) catch |err| {
            log.warn("read thread failed to set non-blocking err={}", .{err});
            log.warn("this isn't a fatal error, but may cause performance issues", .{});
        };

        // Poll both the data fd and the quit pipe.
        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            // Tight read loop — drain all available data before polling.
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        // Pipe closed or I/O error — graceful exit.
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("io reader exiting", .{});
                            return;
                        },

                        // No more data available, fall through to poll.
                        error.WouldBlock => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            return;
                        },
                    }
                };

                // EOF — pipe closed (Swift side closed slave_fd).
                if (n == 0) break;

                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });

                // Check the quit flag so we exit promptly even with continuous
                // data flowing. Without this, a noisy writer could keep us in
                // the tight loop indefinitely, never reaching poll().
                if (quit_flag.load(.monotonic)) {
                    log.info("read thread saw quit flag in tight loop", .{});
                    return;
                }
            }

            // Block until more data is available or we get a quit signal.
            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };

            // Check quit signal first.
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }

            // Check if the pipe fd was closed (HUP).
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("pipe fd closed, read thread exiting", .{});
                return;
            }
        }
    }
};
