//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;
const presentation = @import("../presentation.zig");

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;

/// The underlying CALayer
layer: objc.Object,

pub fn init() !IOSurfaceLayer {
    // The layer returned by `[CALayer layer]` is autoreleased, which means
    // that at the end of the current autorelease pool it will be deallocated
    // if it isn't retained, so we retain it here manually an extra time.
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();

    // The layer gravity is set to top-left so that the contents aren't
    // stretched during resize operations before a new frame has been drawn.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });

    return .{ .layer = layer };
}

pub fn release(self: *IOSurfaceLayer) void {
    // The layer may be retained by the view after we release our reference.
    // Clear the callback first so that a later display pass can't access the
    // renderer that owned this wrapper after it has been freed.
    self.setDisplayCallback(null, null);
    self.layer.release();
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Makes sure to do so on the main thread to avoid visual artifacts.
pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();

    // Retain the layer to ensure it survives until the callback runs.
    // This is necessary because the block may be dispatched asynchronously,
    // and the IOSurfaceLayer could be deallocated before the callback executes.
    // We release in the callback after we're done with it.
    _ = self.layer.retain();

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
    }, &setSurfaceCallback);

    // We check if we're on the main thread and run the block directly if so.
    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        setSurfaceCallback(&block);
    } else {
        // NOTE: The block will be copied when we pass it to dispatch_async,
        //       and then automatically be deallocated by the objc runtime
        //       once it's executed.

        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Does not ensure this happens on the main thread.
pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface) void {
    self.layer.setProperty("contents", surface);
}

/// Sets the layer's `preferredDynamicRange` (the modern per-layer EDR control,
/// iOS/macOS 26+) to `.high` when `high` is true, else `.standard`. Always on
/// the main thread.
///
/// This is per-layer (unlike the deprecated screen-wide
/// `wantsExtendedDynamicRangeContent`), and we only ever call it for a VISIBLE,
/// actively-presenting surface, so the CALayer mutation can't strand an
/// uncommitted transaction on a parked render thread.
pub fn setPreferredDynamicRange(self: IOSurfaceLayer, high: bool) void {
    // preferredDynamicRange + its CADynamicRange constants only exist on the
    // 2025 OS releases ("26"+). The accessors resolve the constants at runtime
    // (dlsym) and return null on older systems, so bail rather than touch the
    // property at all (both the constant read and the setter selector are
    // unsafe there).
    const value: *anyopaque = (if (high)
        macos.animation.caDynamicRangeHigh()
    else
        macos.animation.caDynamicRangeStandard()) orelse return;

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        self.layer.setProperty("preferredDynamicRange", value);
        return;
    }

    // Retain the layer so it survives until the async block runs; released in
    // the callback.
    _ = self.layer.retain();

    var block = SetDynamicRangeBlock.init(.{
        .layer = self.layer.value,
        .value = value,
    }, &setDynamicRangeCallback);

    // dispatch_async copies the block; the objc runtime frees the copy after it
    // runs, so the stack `block` going out of scope here is fine.
    macos.dispatch.dispatch_async(
        @ptrCast(macos.dispatch.queue.getMain()),
        @ptrCast(&block),
    );
}

const SetDynamicRangeBlock = objc.Block(struct {
    layer: objc.c.id,
    value: *anyopaque,
}, .{}, void);

fn setDynamicRangeCallback(
    block: *const SetDynamicRangeBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    defer layer.release();
    layer.setProperty("preferredDynamicRange", block.value);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
}, .{}, void);

fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    defer layer.release();
    const surface: *IOSurface = block.surface;

    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();

    // ROOTSHELL-PRESENT: this runs later on main; presentation may have been
    // revoked since the frame completed.
    if (!presentation.isAllowed()) return;

    // We check to see if the surface is the appropriate size for
    // the layer, if it's not then we discard it. This is because
    // asynchronously drawn frames can sometimes finish just after
    // a synchronously drawn frame during a resize, and if we don't
    // discard the improperly sized surface it creates jank.
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = @intFromFloat(bounds.size.width * scale);
    const height: usize = @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }

    layer.setProperty("contents", surface);
}

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    // Disable all animations for this layer by returning null for all actions.
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}
