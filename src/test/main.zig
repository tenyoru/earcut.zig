const std = @import("std");
const earcut = @import("earcut").earcut;

comptime {
    _ = @import("earcut.zig");
}

fn numVal(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
}

fn runFixture(allocator: std.mem.Allocator, json_data: []const u8, expected_triangles: usize) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();

    var verts: std.ArrayListUnmanaged(f64) = .empty;
    defer verts.deinit(allocator);
    var holes: std.ArrayListUnmanaged(u32) = .empty;
    defer holes.deinit(allocator);

    for (parsed.value.array.items, 0..) |ring, i| {
        if (i > 0) try holes.append(allocator, @intCast(verts.items.len / 2));
        for (ring.array.items) |pt| {
            try verts.append(allocator, numVal(pt.array.items[0]));
            try verts.append(allocator, numVal(pt.array.items[1]));
        }
    }

    const hole_slice: ?[]const u32 = if (holes.items.len > 0) holes.items else null;
    const indices = try earcut(allocator, verts.items, hole_slice, 2);
    defer allocator.free(indices);

    try std.testing.expectEqual(expected_triangles * 3, indices.len);
}

test "building" { try runFixture(std.testing.allocator, @embedFile("fixtures/building.json"), 13); }
test "steiner" { try runFixture(std.testing.allocator, @embedFile("fixtures/steiner.json"), 9); }
test "boxy" { try runFixture(std.testing.allocator, @embedFile("fixtures/boxy.json"), 58); }
test "degenerate" { try runFixture(std.testing.allocator, @embedFile("fixtures/degenerate.json"), 0); }
test "empty-square" { try runFixture(std.testing.allocator, @embedFile("fixtures/empty-square.json"), 0); }
test "hourglass" { try runFixture(std.testing.allocator, @embedFile("fixtures/hourglass.json"), 2); }
test "bad-hole" { try runFixture(std.testing.allocator, @embedFile("fixtures/bad-hole.json"), 42); }
test "bad-diagonals" { try runFixture(std.testing.allocator, @embedFile("fixtures/bad-diagonals.json"), 7); }
test "shared-points" { try runFixture(std.testing.allocator, @embedFile("fixtures/shared-points.json"), 4); }
test "collinear-diagonal" { try runFixture(std.testing.allocator, @embedFile("fixtures/collinear-diagonal.json"), 14); }
test "hole-touching-outer" { try runFixture(std.testing.allocator, @embedFile("fixtures/hole-touching-outer.json"), 77); }
test "touching-holes" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching-holes.json"), 57); }
test "touching-holes2" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching-holes2.json"), 10); }
test "touching-holes3" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching-holes3.json"), 82); }
test "touching-holes4" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching-holes4.json"), 55); }
test "touching-holes5" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching-holes5.json"), 133); }
test "touching-holes6" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching-holes6.json"), 3098); }
test "touching2" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching2.json"), 8); }
test "touching3" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching3.json"), 15); }
test "touching4" { try runFixture(std.testing.allocator, @embedFile("fixtures/touching4.json"), 19); }
test "outside-ring" { try runFixture(std.testing.allocator, @embedFile("fixtures/outside-ring.json"), 64); }
test "self-touching" { try runFixture(std.testing.allocator, @embedFile("fixtures/self-touching.json"), 124); }
test "issue16" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue16.json"), 12); }
test "issue17" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue17.json"), 11); }
test "issue29" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue29.json"), 40); }
test "issue34" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue34.json"), 139); }
test "issue35" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue35.json"), 844); }
test "issue45" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue45.json"), 10); }
test "issue52" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue52.json"), 109); }
test "issue83" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue83.json"), 0); }
test "issue107" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue107.json"), 0); }
test "issue111" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue111.json"), 18); }
test "issue119" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue119.json"), 18); }
test "issue131" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue131.json"), 12); }
test "issue142" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue142.json"), 4); }
test "issue149" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue149.json"), 2); }
test "issue186" { try runFixture(std.testing.allocator, @embedFile("fixtures/issue186.json"), 41); }
test "eberly-3" { try runFixture(std.testing.allocator, @embedFile("fixtures/eberly-3.json"), 73); }
test "eberly-6" { try runFixture(std.testing.allocator, @embedFile("fixtures/eberly-6.json"), 1429); }
test "hilbert" { try runFixture(std.testing.allocator, @embedFile("fixtures/hilbert.json"), 1024); }
test "simplified-us-border" { try runFixture(std.testing.allocator, @embedFile("fixtures/simplified-us-border.json"), 120); }
test "infinite-loop-jhl" { try runFixture(std.testing.allocator, @embedFile("fixtures/infinite-loop-jhl.json"), 0); }
test "filtered-bridge-jhl" { try runFixture(std.testing.allocator, @embedFile("fixtures/filtered-bridge-jhl.json"), 25); }
test "dude" { try runFixture(std.testing.allocator, @embedFile("fixtures/dude.json"), 106); }
test "rain" { try runFixture(std.testing.allocator, @embedFile("fixtures/rain.json"), 2681); }
test "water" { try runFixture(std.testing.allocator, @embedFile("fixtures/water.json"), 2482); }
test "water2" { try runFixture(std.testing.allocator, @embedFile("fixtures/water2.json"), 1212); }
test "water3" { try runFixture(std.testing.allocator, @embedFile("fixtures/water3.json"), 197); }
test "water3b" { try runFixture(std.testing.allocator, @embedFile("fixtures/water3b.json"), 25); }
test "water4" { try runFixture(std.testing.allocator, @embedFile("fixtures/water4.json"), 705); }
test "water-huge" { try runFixture(std.testing.allocator, @embedFile("fixtures/water-huge.json"), 5176); }
test "water-huge2" { try runFixture(std.testing.allocator, @embedFile("fixtures/water-huge2.json"), 4462); }
