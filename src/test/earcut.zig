const std = @import("std");
const earcut = @import("earcut").earcut;
const deviation = @import("earcut").deviation;

test "indices-2d" {
    const pts = [_]f64{ 10, 0, 0, 50, 60, 60, 70, 10 };
    const result = try earcut(std.testing.allocator, &pts, null, 2);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 0, 3, 1, 3, 2 }, result);
}

test "indices-3d" {
    const pts = [_]f64{ 10, 0, 0, 0, 50, 0, 60, 60, 0, 70, 10, 0 };
    const result = try earcut(std.testing.allocator, &pts, null, 3);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 0, 3, 1, 3, 2 }, result);
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

// Regression for collinear-rich outer ring (integer grid, MVT-like) plus multiple holes:
// a hole must never be dropped while filtering collinear runs. Assert full coverage across
// 90-degree rotations (deviation ~0 means no hole lost).
test "block-index-collinear" {
    const allocator = std.testing.allocator;
    const N: i32 = 30;

    var outer: std.ArrayListUnmanaged([2]f64) = .empty;
    defer outer.deinit(allocator);
    {
        var x: i32 = 0;
        while (x <= N) : (x += 1) try outer.append(allocator, .{ @floatFromInt(x), 0 });
        var y: i32 = 1;
        while (y <= N) : (y += 1) try outer.append(allocator, .{ @floatFromInt(N), @floatFromInt(y) });
        x = N - 1;
        while (x >= 0) : (x -= 1) try outer.append(allocator, .{ @floatFromInt(x), @floatFromInt(N) });
        y = N - 1;
        while (y >= 1) : (y -= 1) try outer.append(allocator, .{ 0, @floatFromInt(y) });
    }

    const rect = struct {
        fn make(x0: f64, y0: f64, w: f64, h: f64) [4][2]f64 {
            return .{ .{ x0, y0 }, .{ x0, y0 + h }, .{ x0 + w, y0 + h }, .{ x0 + w, y0 } };
        }
    }.make;
    const hole1 = rect(5, 5, 2, 4);
    const hole2 = rect(2, 23, 1, 1);

    // [xx, xy, yx, yy] for rotations 0, 90, 180, 270 degrees
    const rotations = [_][4]f64{
        .{ 1, 0, 0, 1 },
        .{ 0, -1, 1, 0 },
        .{ -1, 0, 0, -1 },
        .{ 0, 1, -1, 0 },
    };

    const append_ring = struct {
        fn f(al: std.mem.Allocator, v: *std.ArrayListUnmanaged(f64), rot: [4]f64, ring: []const [2]f64) !void {
            for (ring) |p| {
                try v.append(al, rot[0] * p[0] + rot[1] * p[1]);
                try v.append(al, rot[2] * p[0] + rot[3] * p[1]);
            }
        }
    }.f;

    for (rotations) |r| {
        var verts: std.ArrayListUnmanaged(f64) = .empty;
        defer verts.deinit(allocator);
        var holes: std.ArrayListUnmanaged(u32) = .empty;
        defer holes.deinit(allocator);

        try append_ring(allocator, &verts, r, outer.items);
        try holes.append(allocator, @intCast(verts.items.len / 2));
        try append_ring(allocator, &verts, r, &hole1);
        try holes.append(allocator, @intCast(verts.items.len / 2));
        try append_ring(allocator, &verts, r, &hole2);

        const indices = try earcut(allocator, verts.items, holes.items, 2);
        defer allocator.free(indices);

        const err = deviation(verts.items, holes.items, 2, indices);
        try std.testing.expect(err < 1e-9);
    }
}

