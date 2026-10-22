//! Wrap a Shadertoy-style fragment shader and print the result: the same
//! transformation the daemon applies before compiling (see
//! `core/shadertoy.zig`).
//!
//! Meant for validation, e.g.
//!
//!     zig build shadertoy-wrap -- tools/fixtures/minimal.frag > /tmp/wrapped.frag
//!     glslangValidator /tmp/wrapped.frag
//!
//! Run by its build step, never installed.

const std = @import("std");
const iohelp = @import("core/io_helper.zig");
const shadertoy = @import("core/shadertoy.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    const args = init.args.vector;
    if (args.len != 2) {
        std.debug.print("usage: shadertoy-wrap <shader.frag>\n", .{});
        return error.InvalidArguments;
    }

    const path = std.mem.span(args[1]);
    const raw = try iohelp.readFileAlloc(allocator, path, 8 << 20);
    defer allocator.free(raw);

    const wrapped = try shadertoy.wrap(allocator, raw);
    defer allocator.free(wrapped);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(iohelp.io(), &stdout_buf);
    const w = &stdout_writer.interface;
    try w.writeAll(wrapped);
    try w.flush();
}
