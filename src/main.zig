const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("Weld engine — Phase -1 / S0 bootstrap\n", .{});
    try stdout.flush();
}

test "main module compiles" {
    try std.testing.expect(true);
}
