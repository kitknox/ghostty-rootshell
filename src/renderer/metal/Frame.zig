//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");

const mtl = @import("api.zig");
const Renderer = @import("../generic.zig").Renderer(Metal);
const Metal = @import("../Metal.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;
const presentation = @import("../presentation.zig");

const log = std.log.scoped(.metal);

/// Options for beginning a frame.
pub const Options = struct {
    /// MTLCommandQueue
    queue: objc.Object,
};

/// MTLCommandBuffer
buffer: objc.Object,

block: CompletionBlock.Context,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    const buffer = opts.queue.msgSend(
        objc.Object,
        objc.sel("commandBuffer"),
        .{},
    );

    // Create our block to register for completion updates.
    // The block is deallocated by the objC runtime on success.
    const block = CompletionBlock.init(
        .{
            .renderer = renderer,
            .target = target,
            .sync = false,
        },
        &bufferCompleted,
    );

    return .{ .buffer = buffer, .block = block };
}

/// This is the block type used for the addCompletedHandler callback.
const CompletionBlock = objc.Block(struct {
    renderer: *Renderer,
    target: *Target,
    sync: bool,
}, .{
    objc.c.id, // MTLCommandBuffer
}, void);

fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const buffer = objc.Object.fromId(buffer_id);

    // Get our command buffer status to pass back to the generic renderer.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    // If the frame is healthy, present it. ROOTSHELL-PRESENT: unless a
    // revocation timed out waiting on this frame.
    if (health == .healthy and presentation.isAllowed()) {
        // Call texture callback if registered (for visionOS curved display)
        // This allows Swift to access the IOSurface before it's presented
        if (block.renderer.api.rt_surface.texture_callback) |callback| {
            callback(
                block.renderer.api.rt_surface.texture_callback_userdata,
                @ptrCast(block.target.surface),
                @intCast(block.target.width),
                @intCast(block.target.height),
            );
        }

        block.renderer.api.present(
            block.target.*,
            block.sync,
        ) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
    }

    block.renderer.frameCompleted(health);
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .command_buffer = self.buffer,
    });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
pub inline fn complete(self: *Self, sync: bool) void {
    // ROOTSHELL-PRESENT: the commit is exclusive with revocation. Revoked
    // since admission: drop the encoded buffer uncommitted, so no GPU work.
    if (!presentation.lockCommit()) {
        presentation.unlockCommit();
        self.block.renderer.frameCancelled();
        return;
    }

    // If we don't need to complete synchronously,
    // we add our block as a completion handler.
    //
    // It will be copied when we add the handler, and then the
    // copy will be deallocated by the objc runtime on success.
    if (!sync) {
        self.buffer.msgSend(
            void,
            objc.sel("addCompletedHandler:"),
            .{&self.block},
        );
    }

    self.buffer.msgSend(void, objc.sel("commit"), .{});
    presentation.unlockCommit();

    // If we need to complete synchronously, we wait until
    // the buffer is completed and invoke the block directly.
    if (sync) {
        self.buffer.msgSend(void, "waitUntilCompleted", .{});
        self.block.sync = true;
        CompletionBlock.invoke(&self.block, .{self.buffer.value});
    }
}
