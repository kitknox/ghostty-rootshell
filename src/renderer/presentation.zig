//! ROOTSHELL-PRESENT: process-wide gate on GPU presentation. The iOS app
//! revokes it while backgrounded.
//!
//! - The GPU commit and revocation exclude each other (`lockCommit`), so a
//!   frame either commits before revocation or is cancelled uncommitted.
//! - Each frame holds a lease from admission in drawFrame until it completes
//!   or is cancelled; revoking waits (bounded) for those leases so committed
//!   work finishes and presents before the app backgrounds.
const std = @import("std");
const global = @import("../global.zig");

const log = std.log.scoped(.presentation);

var allowed: std.atomic.Value(bool) = .init(true);

/// Spinlock rather than std.Io.Mutex: revocation can run before Ghostty's
/// global state exists, and the critical sections are a flag and a commit.
var commit_locked: std.atomic.Value(bool) = .init(false);

fn acquireCommitLock() void {
    while (commit_locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn releaseCommitLock() void {
    commit_locked.store(false, .release);
}

/// Locks out revocation until `unlockCommit`. Returns whether the frame may
/// commit; if not, the caller cancels it. Call `unlockCommit` either way,
/// right after issuing the commit.
pub fn lockCommit() bool {
    acquireCommitLock();
    return allowed.load(.seq_cst);
}

pub fn unlockCommit() void {
    releaseCommitLock();
}

/// Frames admitted and not yet completed.
var in_flight: std.atomic.Value(u32) = .init(0);

/// Upper bound on how long revocation blocks its caller (the iOS main thread).
const drain_timeout_ms = 250;

/// Admits one frame. On true the caller owes exactly one `endSubmit`, made
/// once the frame has completed and presented, or at once if it never commits.
pub fn beginSubmit() bool {
    // seq_cst pairs with setAllowed: either the revoker sees this frame in
    // flight, or this frame sees the revocation.
    _ = in_flight.fetchAdd(1, .seq_cst);
    if (allowed.load(.seq_cst)) return true;
    endSubmit();
    return false;
}

pub fn endSubmit() void {
    _ = in_flight.fetchSub(1, .seq_cst);
}

/// Once revocation returns, no further commit can happen. It then waits
/// (bounded) for admitted frames to complete or cancel.
pub fn setAllowed(value: bool) void {
    acquireCommitLock();
    allowed.store(value, .seq_cst);
    releaseCommitLock();
    if (value) return;

    var waited_ms: u32 = 0;
    while (in_flight.load(.seq_cst) > 0) : (waited_ms += 1) {
        if (waited_ms >= drain_timeout_ms) {
            log.warn("revoked with {} frame(s) still in flight", .{in_flight.load(.seq_cst)});
            return;
        }
        std.Io.sleep(global.io(), .fromMilliseconds(1), .awake) catch return;
    }
}

pub fn isAllowed() bool {
    return allowed.load(.seq_cst);
}

test "presentation: revocation refuses new frames and leaves no lease behind" {
    const testing = std.testing;
    defer setAllowed(true);

    setAllowed(true);
    try testing.expect(beginSubmit());
    endSubmit();

    setAllowed(false);
    try testing.expect(!isAllowed());
    try testing.expect(!beginSubmit());
    try testing.expectEqual(@as(u32, 0), in_flight.load(.seq_cst));

    setAllowed(true);
    try testing.expect(beginSubmit());
    endSubmit();
    try testing.expectEqual(@as(u32, 0), in_flight.load(.seq_cst));
}

test "presentation: a frame admitted before revocation cannot commit after it" {
    const testing = std.testing;
    defer setAllowed(true);

    setAllowed(true);
    try testing.expect(beginSubmit());

    // Revocation while the frame is still encoding. Simulate completion of the
    // cancel path so the bounded wait sees the lease end.
    const Revoker = struct {
        fn run() void {
            setAllowed(false);
        }
    };
    const thread = try std.Thread.spawn(.{}, Revoker.run, .{});
    while (isAllowed()) std.atomic.spinLoopHint();

    try testing.expect(!lockCommit());
    unlockCommit();
    endSubmit();
    thread.join();
    try testing.expectEqual(@as(u32, 0), in_flight.load(.seq_cst));
}
