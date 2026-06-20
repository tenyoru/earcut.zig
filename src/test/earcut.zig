const std = @import("std");
const earcut = @import("earcut").earcut;

test "indices-2d" {
    const pts = [_]f64{ 10, 0, 0, 50, 60, 60, 70, 10 };
    const result = try earcut(std.testing.allocator, &pts, null, 2);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 0, 3, 3, 2, 1 }, result);
}

test "indices-3d" {
    const pts = [_]f64{ 10, 0, 0, 0, 50, 0, 60, 60, 0, 70, 10, 0 };
    const result = try earcut(std.testing.allocator, &pts, null, 3);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 0, 3, 3, 2, 1 }, result);
}

test "empty" {
    const result = try earcut(std.testing.allocator, &[_]f64{}, null, 2);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "infinite-loop" {
    const pts = [_]f64{ 1, 2, 2, 2, 1, 2, 1, 1, 1, 2, 4, 1, 5, 1, 3, 2, 4, 2, 4, 1 };
    const result = try earcut(std.testing.allocator, &pts, &[_]u32{5}, 2);
    defer std.testing.allocator.free(result);
}

