//! Represents a render target.
//!
//! In this case, an IOSurface-backed MTLTexture.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const IOSurface = macos.iosurface.IOSurface;

const mtl = @import("api.zig");

const log = std.log.scoped(.metal);

/// Options for initializing a Target
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,

    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Pixel format for the MTLTexture
    pixel_format: mtl.MTLPixelFormat,
    /// Tag the SDR surface sRGB instead of Display P3.
    srgb: bool = false,
    /// Storage mode for the MTLTexture
    storage_mode: mtl.MTLResourceOptions.StorageMode,
};

/// The underlying IOSurface.
surface: *IOSurface,

/// The underlying MTLTexture.
texture: objc.Object,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    // When rendering EDR (half-float) we need an extended-range, linear color
    // space so the compositor interprets the buffer's >1.0 values as
    // extended-range light. Otherwise we use Display P3, which gives us
    // "Apple-style" alpha blending, since it seems to be the case that Apple
    // apps like Terminal and TextEdit render text in the display's color space
    // using converted colors, which reduces, but does not fully eliminate
    // blending artifacts.
    const edr = opts.pixel_format == .rgba16float;
    const colorspace = try graphics.ColorSpace.createNamed(
        if (edr) .extendedLinearDisplayP3 else if (opts.srgb) .sRGB else .displayP3,
    );
    defer colorspace.release();

    const surface = try IOSurface.init(.{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
        // EDR uses 64-bit RGBA half-float (8 bytes/element) to match the
        // rgba16float MTLTexture; SDR uses 32-bit BGRA (4 bytes/element).
        .pixel_format = if (edr) .@"64RGBAHalf" else .@"32BGRA",
        .bytes_per_element = if (edr) 8 else 4,
        .colorspace = colorspace,
    });

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();

    // Set our properties
    desc.setProperty("width", @as(c_ulong, @intCast(opts.width)));
    desc.setProperty("height", @as(c_ulong, @intCast(opts.height)));
    desc.setProperty("pixelFormat", @intFromEnum(opts.pixel_format));
    desc.setProperty("usage", mtl.MTLTextureUsage{ .render_target = true });
    desc.setProperty(
        "resourceOptions",
        mtl.MTLResourceOptions{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = opts.storage_mode,
        },
    );

    const id = opts.device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:iosurface:plane:"),
        .{
            desc,
            surface,
            @as(c_ulong, 0),
        },
    ) orelse return error.MetalFailed;

    const texture = objc.Object.fromId(id);

    return .{
        .surface = surface,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    self.surface.deinit();
    self.texture.release();
}

/// ROOTSHELL: give up a target whose surface something else still shows or
/// holds. `deinit` discards the surface's pixels at once; this only drops
/// our references, so the surface lives on until its last user lets go.
pub fn deinitStillInUse(self: *Self) void {
    self.surface.release();
    self.texture.release();
}
