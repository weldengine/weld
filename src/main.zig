const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print(
        "Weld bootstrap OK ({s})\n",
        .{@tagName(builtin.mode)},
    );
    try stdout.interface.flush();
}

test "main module compiles" {
    try std.testing.expect(true);
}
