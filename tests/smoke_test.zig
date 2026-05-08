const std = @import("std");

test "smoke" {
    try std.testing.expectEqual(@as(i32, 2), 1 + 1);
}
