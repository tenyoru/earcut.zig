const std = @import("std");

// Zig port of Earcut triangulation algorithm
// Based on https://github.com/mapbox/earcut

const Node = struct {
    i: u32,
    x: f64,
    y: f64,
    prev: ?*Node = null,
    next: ?*Node = null,
    z: i32 = 0,
    prevz: ?*Node = null,
    nextz: ?*Node = null,
    steiner: bool = false,
};


pub fn earcut(
    allocator: std.mem.Allocator,
    data: []const f64,
    hole_indices: ?[]const u32,
    dim: u32,
) ![]u32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const has_holes = hole_indices != null and hole_indices.?.len > 0;
    const outer_len: u32 = if (has_holes) hole_indices.?[0] * dim else @intCast(data.len);

    var outer_node = try linked_list(a, data, 0, outer_len, dim, true);
    var triangles: std.ArrayListUnmanaged(u32) = .empty;

    if (outer_node == null or outer_node.?.next == outer_node.?.prev) {
        return allocator.dupe(u32, triangles.items);
    }

    var min_x: f64 = undefined;
    var min_y: f64 = undefined;
    var inv_size: f64 = undefined;

    if (has_holes) {
        outer_node = try eliminate_holes(a, data, hole_indices.?, outer_node.?, dim);
    }

    // If shape is not too simple, use z-order curve hash
    if (data.len > 80 * dim) {
        min_x = data[0];
        min_y = data[1];
        var max_x = min_x;
        var max_y = min_y;

        var i: u32 = dim;
        while (i < outer_len) : (i += dim) {
            const x = data[i];
            const y = data[i + 1];
            if (x < min_x) min_x = x;
            if (y < min_y) min_y = y;
            if (x > max_x) max_x = x;
            if (y > max_y) max_y = y;
        }

        inv_size = @max(max_x - min_x, max_y - min_y);
        inv_size = if (inv_size != 0) 32767.0 / inv_size else 0;
    }

    try earcut_linked(a, outer_node, &triangles, dim, min_x, min_y, inv_size, 0);

    return allocator.dupe(u32, triangles.items);
}

pub const FlattenResult = struct {
    vertices: []f64,
    holes: []u32,

    pub fn deinit(self: FlattenResult, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.holes);
    }
};

/// Convert a polygon in nested-array form (rings of [x,y] points, as in GeoJSON)
/// into the flat arrays that earcut accepts.
pub fn flatten(allocator: std.mem.Allocator, data: []const []const [2]f64) !FlattenResult {
    var verts: std.ArrayListUnmanaged(f64) = .empty;
    var holes: std.ArrayListUnmanaged(u32) = .empty;
    var prev_len: u32 = 0;
    var hole_index: u32 = 0;

    for (data) |ring| {
        for (ring) |pt| {
            try verts.append(allocator, pt[0]);
            try verts.append(allocator, pt[1]);
        }
        if (prev_len != 0) {
            hole_index += prev_len;
            try holes.append(allocator, hole_index);
        }
        prev_len = @intCast(ring.len);
    }

    return .{
        .vertices = try verts.toOwnedSlice(allocator),
        .holes = try holes.toOwnedSlice(allocator),
    };
}

/// Return the percentage difference between the polygon area and its triangulation area.
/// A value of 0 means a perfect triangulation. Used to verify correctness.
pub fn deviation(
    data: []const f64,
    hole_indices: ?[]const u32,
    dim: u32,
    triangles: []const u32,
) f64 {
    const has_holes = hole_indices != null and hole_indices.?.len > 0;
    const outer_len: u32 = if (has_holes) hole_indices.?[0] * dim else @intCast(data.len);

    var polygon_area = @abs(signed_area(data, 0, outer_len, dim));

    if (has_holes) {
        const holes = hole_indices.?;
        for (holes, 0..) |hole_start, i| {
            const start = hole_start * dim;
            const end: u32 = if (i < holes.len - 1) holes[i + 1] * dim else @intCast(data.len);
            polygon_area -= @abs(signed_area(data, start, end, dim));
        }
    }

    var triangles_area: f64 = 0;
    var i: usize = 0;
    while (i < triangles.len) : (i += 3) {
        const a = triangles[i] * dim;
        const b = triangles[i + 1] * dim;
        const c = triangles[i + 2] * dim;
        triangles_area += @abs(
            (data[a] - data[c]) * (data[b + 1] - data[a + 1]) -
            (data[a] - data[b]) * (data[c + 1] - data[a + 1]),
        );
    }

    if (polygon_area == 0 and triangles_area == 0) return 0;
    return @abs((triangles_area - polygon_area) / polygon_area);
}


fn linked_list(
    allocator: std.mem.Allocator,
    data: []const f64,
    start: u32,
    end: u32,
    dim: u32,
    clockwise: bool,
) !?*Node {
    var last: ?*Node = null;
    const signed = signed_area(data, start, end, dim);

    if (clockwise == (signed > 0)) {
        var i = start;
        while (i < end) : (i += dim) {
            last = try insert_node(allocator, i / dim, data[i], data[i + 1], last);
        }
    } else {
        var i = end;
        while (i > start) {
            i -= dim;
            last = try insert_node(allocator, i / dim, data[i], data[i + 1], last);
        }
    }

    if (last != null and equals(last.?, last.?.next.?)) {
        remove_node(last.?);
        last = last.?.next;
    }

    return last;
}

fn earcut_linked(
    allocator: std.mem.Allocator,
    ear_opt: ?*Node,
    triangles: *std.ArrayListUnmanaged(u32),
    dim: u32,
    min_x: f64,
    min_y: f64,
    inv_size: f64,
    pass: u32,
) std.mem.Allocator.Error!void {
    if (ear_opt == null) return;
    var ear = ear_opt.?;

    if (pass == 0 and inv_size != 0) index_curve(ear, min_x, min_y, inv_size);

    var stop = ear;

    while (ear.prev != ear.next) {
        const prev = ear.prev.?;
        const next = ear.next.?;

        const is_ear_val = if (inv_size != 0)
            is_ear_hashed(ear, min_x, min_y, inv_size)
        else
            is_ear(ear);

        if (is_ear_val) {
            try triangles.append(allocator, prev.i);
            try triangles.append(allocator, ear.i);
            try triangles.append(allocator, next.i);

            remove_node(ear);

            ear = next.next.?;
            stop = next.next.?;
            continue;
        }

        ear = next;

        if (ear == stop) {
            if (pass == 0) {
                try earcut_linked(allocator, filter_points(ear, null), triangles, dim, min_x, min_y, inv_size, 1);
            } else if (pass == 1) {
                ear = cure_local_intersections(allocator, filter_points(ear, null).?, triangles);
                try earcut_linked(allocator, ear, triangles, dim, min_x, min_y, inv_size, 2);
            } else if (pass == 2) {
                try split_earcut(allocator, ear, triangles, dim, min_x, min_y, inv_size);
            }
            break;
        }
    }
}

fn is_ear(ear: *Node) bool {
    const a = ear.prev.?;
    const b = ear;
    const c = ear.next.?;

    if (area(a, b, c) >= 0) return false;

    const ax = a.x;
    const bx = b.x;
    const cx = c.x;
    const ay = a.y;
    const by = b.y;
    const cy = c.y;

    const x0 = @min(@min(ax, bx), cx);
    const y0 = @min(@min(ay, by), cy);
    const x1 = @max(@max(ax, bx), cx);
    const y1 = @max(@max(ay, by), cy);

    var p = c.next.?;
    while (p != a) : (p = p.next.?) {
        if (p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 and
            point_in_triangle_except_first(ax, ay, bx, by, cx, cy, p.x, p.y) and
            area(p.prev.?, p, p.next.?) >= 0)
        {
            return false;
        }
    }

    return true;
}

fn is_ear_hashed(ear: *Node, min_x: f64, min_y: f64, inv_size: f64) bool {
    const a = ear.prev.?;
    const b = ear;
    const c = ear.next.?;

    if (area(a, b, c) >= 0) return false;

    const ax = a.x;
    const bx = b.x;
    const cx = c.x;
    const ay = a.y;
    const by = b.y;
    const cy = c.y;

    const x0 = @min(@min(ax, bx), cx);
    const y0 = @min(@min(ay, by), cy);
    const x1 = @max(@max(ax, bx), cx);
    const y1 = @max(@max(ay, by), cy);

    const min_z = z_order(x0, y0, min_x, min_y, inv_size);
    const max_z = z_order(x1, y1, min_x, min_y, inv_size);

    var p = ear.prevz;
    var n = ear.nextz;

    while (p != null and p.?.z >= min_z and n != null and n.?.z <= max_z) {
        if (p.?.x >= x0 and p.?.x <= x1 and p.?.y >= y0 and p.?.y <= y1 and p != a and p != c and
            point_in_triangle_except_first(ax, ay, bx, by, cx, cy, p.?.x, p.?.y) and
            area(p.?.prev.?, p.?, p.?.next.?) >= 0)
        {
            return false;
        }
        p = p.?.prevz;

        if (n.?.x >= x0 and n.?.x <= x1 and n.?.y >= y0 and n.?.y <= y1 and n != a and n != c and
            point_in_triangle_except_first(ax, ay, bx, by, cx, cy, n.?.x, n.?.y) and
            area(n.?.prev.?, n.?, n.?.next.?) >= 0)
        {
            return false;
        }
        n = n.?.nextz;
    }

    while (p != null and p.?.z >= min_z) {
        if (p.?.x >= x0 and p.?.x <= x1 and p.?.y >= y0 and p.?.y <= y1 and p != a and p != c and
            point_in_triangle_except_first(ax, ay, bx, by, cx, cy, p.?.x, p.?.y) and
            area(p.?.prev.?, p.?, p.?.next.?) >= 0)
        {
            return false;
        }
        p = p.?.prevz;
    }

    while (n != null and n.?.z <= max_z) {
        if (n.?.x >= x0 and n.?.x <= x1 and n.?.y >= y0 and n.?.y <= y1 and n != a and n != c and
            point_in_triangle_except_first(ax, ay, bx, by, cx, cy, n.?.x, n.?.y) and
            area(n.?.prev.?, n.?, n.?.next.?) >= 0)
        {
            return false;
        }
        n = n.?.nextz;
    }

    return true;
}

fn cure_local_intersections(allocator: std.mem.Allocator, start_node: *Node, triangles: *std.ArrayListUnmanaged(u32)) *Node {
    var p = start_node;
    var loop_start = start_node;

    while (true) {
        const a = p.prev.?;
        const b = p.next.?.next.?;

        if (!equals(a, b) and intersects(a, p, p.next.?, b) and locally_inside(a, b) and locally_inside(b, a)) {
            triangles.append(allocator, a.i) catch {};
            triangles.append(allocator, p.i) catch {};
            triangles.append(allocator, b.i) catch {};

            remove_node(p);
            remove_node(p.next.?);

            p = b;
            loop_start = b;
        }
        p = p.next.?;
        if (p == loop_start) break;
    }

    return filter_points(p, null).?;
}

fn split_earcut(
    allocator: std.mem.Allocator,
    start: *Node,
    triangles: *std.ArrayListUnmanaged(u32),
    dim: u32,
    min_x: f64,
    min_y: f64,
    inv_size: f64,
) !void {
    var a = start;

    while (true) {
        var b = a.next.?.next.?;
        while (b != a.prev.?) : (b = b.next.?) {
            if (a.i != b.i and is_valid_diagonal(a, b)) {
                var c = try split_polygon(allocator, a, b);

                a = filter_points(a, a.next).?;
                c = filter_points(c, c.next).?;

                try earcut_linked(allocator, a, triangles, dim, min_x, min_y, inv_size, 0);
                try earcut_linked(allocator, c, triangles, dim, min_x, min_y, inv_size, 0);
                return;
            }
        }
        a = a.next.?;
        if (a == start) break;
    }
}

fn eliminate_holes(
    allocator: std.mem.Allocator,
    data: []const f64,
    hole_indices: []const u32,
    outer_node: *Node,
    dim: u32,
) !?*Node {
    var queue: std.ArrayListUnmanaged(*Node) = .empty;
    defer queue.deinit(allocator);

    for (hole_indices, 0..) |hole_start_idx, i| {
        const start = hole_start_idx * dim;
        const end: u32 = if (i < hole_indices.len - 1) hole_indices[i + 1] * dim else @intCast(data.len);
        const list = try linked_list(allocator, data, start, end, dim, false);
        if (list) |l| {
            if (l == l.next) l.steiner = true;
            try queue.append(allocator, get_leftmost(l));
        }
    }

    std.sort.heap(*Node, queue.items, {}, compare_x);

    var result = outer_node;
    for (queue.items) |hole| {
        result = (try eliminate_hole(allocator, hole, result)).?;
    }

    return result;
}

fn compare_x(_: void, a: *Node, b: *Node) bool {
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    const a_slope = (a.next.?.y - a.y) / (a.next.?.x - a.x);
    const b_slope = (b.next.?.y - b.y) / (b.next.?.x - b.x);
    return a_slope < b_slope;
}

fn eliminate_hole(allocator: std.mem.Allocator, hole: *Node, outer_node: *Node) !?*Node {
    const bridge = find_hole_bridge(hole, outer_node) orelse return outer_node;
    const bridge_reverse = try split_polygon(allocator, bridge, hole);

    _ = filter_points(bridge_reverse, bridge_reverse.next);
    return filter_points(bridge, bridge.next);
}

fn find_hole_bridge(hole: *Node, outer_node: *Node) ?*Node {
    var p = outer_node;
    const hx = hole.x;
    const hy = hole.y;
    var qx: f64 = -std.math.inf(f64);
    var m: ?*Node = null;

    if (equals(hole, p)) return p;
    while (true) {
        if (equals(hole, p.next.?)) return p.next.?;
        if (hy <= p.y and hy >= p.next.?.y and p.next.?.y != p.y) {
            const x = p.x + (hy - p.y) * (p.next.?.x - p.x) / (p.next.?.y - p.y);
            if (x <= hx and x > qx) {
                qx = x;
                m = if (p.x < p.next.?.x) p else p.next.?;
                if (x == hx) return m;
            }
        }
        p = p.next.?;
        if (p == outer_node) break;
    }

    if (m == null) return null;

    const stop = m.?;
    const mx = m.?.x;
    const my = m.?.y;
    var tan_min: f64 = std.math.inf(f64);

    p = m.?;
    while (true) {
        if (hx >= p.x and p.x >= mx and hx != p.x and
            point_in_triangle(if (hy < my) hx else qx, hy, mx, my, if (hy < my) qx else hx, hy, p.x, p.y))
        {
            const tan = @abs(hy - p.y) / (hx - p.x);

            if (locally_inside(p, hole) and (tan < tan_min or (tan == tan_min and (p.x > m.?.x or (p.x == m.?.x and sector_contains_sector(m.?, p)))))) {
                m = p;
                tan_min = tan;
            }
        }

        p = p.next.?;
        if (p == stop) break;
    }

    return m;
}

fn sector_contains_sector(m: *Node, p: *Node) bool {
    return area(m.prev.?, m, p.prev.?) < 0 and area(p.next.?, m, m.next.?) < 0;
}

fn index_curve(start: *Node, min_x: f64, min_y: f64, inv_size: f64) void {
    var p = start;

    while (true) {
        if (p.z == 0) p.z = z_order(p.x, p.y, min_x, min_y, inv_size);
        p.prevz = p.prev;
        p.nextz = p.next;
        p = p.next.?;
        if (p == start) break;
    }

    p.prevz.?.nextz = null;
    p.prevz = null;

    sort_linked(p);
}

fn sort_linked(list_start: *Node) void {
    var in_size: u32 = 1;
    var head: ?*Node = list_start;

    while (true) {
        var p = head;
        head = null;
        var list: ?*Node = null;
        var tail: ?*Node = null;
        var num_merges: u32 = 0;

        while (p != null) {
            num_merges += 1;
            var q = p;
            var p_size: u32 = 0;
            var i: u32 = 0;
            while (i < in_size) : (i += 1) {
                p_size += 1;
                q = q.?.nextz;
                if (q == null) break;
            }
            var q_size = in_size;

            while (p_size > 0 or (q_size > 0 and q != null)) {
                var e: ?*Node = null;

                if (p_size != 0 and (q_size == 0 or q == null or p.?.z <= q.?.z)) {
                    e = p;
                    p = p.?.nextz;
                    p_size -= 1;
                } else {
                    e = q;
                    q = q.?.nextz;
                    q_size -= 1;
                }

                if (tail != null) {
                    tail.?.nextz = e;
                } else {
                    list = e;
                }

                e.?.prevz = tail;
                tail = e;
            }

            p = q;
        }

        tail.?.nextz = null;
        head = list;
        in_size *= 2;

        if (num_merges <= 1) break;
    }
}

fn z_order(x_val: f64, y_val: f64, min_x: f64, min_y: f64, inv_size: f64) i32 {
    var x: i32 = @intFromFloat((x_val - min_x) * inv_size);
    var y: i32 = @intFromFloat((y_val - min_y) * inv_size);

    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;

    y = (y | (y << 8)) & 0x00FF00FF;
    y = (y | (y << 4)) & 0x0F0F0F0F;
    y = (y | (y << 2)) & 0x33333333;
    y = (y | (y << 1)) & 0x55555555;

    return x | (y << 1);
}

fn get_leftmost(start: *Node) *Node {
    var p = start;
    var leftmost = start;

    while (true) {
        if (p.x < leftmost.x or (p.x == leftmost.x and p.y < leftmost.y)) {
            leftmost = p;
        }
        p = p.next.?;
        if (p == start) break;
    }

    return leftmost;
}

fn point_in_triangle(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, px: f64, py: f64) bool {
    return (cx - px) * (ay - py) >= (ax - px) * (cy - py) and
        (ax - px) * (by - py) >= (bx - px) * (ay - py) and
        (bx - px) * (cy - py) >= (cx - px) * (by - py);
}

fn point_in_triangle_except_first(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, px: f64, py: f64) bool {
    return !(ax == px and ay == py) and point_in_triangle(ax, ay, bx, by, cx, cy, px, py);
}

fn is_valid_diagonal(a: *Node, b: *Node) bool {
    return a.next.?.i != b.i and a.prev.?.i != b.i and !intersects_polygon(a, b) and
        (locally_inside(a, b) and locally_inside(b, a) and middle_inside(a, b) and
            (area(a.prev.?, a, b.prev.?) != 0 or area(a, b.prev.?, b) != 0) or
            equals(a, b) and area(a.prev.?, a, a.next.?) > 0 and area(b.prev.?, b, b.next.?) > 0);
}

fn area(p: *Node, q: *Node, r: *Node) f64 {
    return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
}

fn equals(p1: *Node, p2: *Node) bool {
    return p1.x == p2.x and p1.y == p2.y;
}

fn intersects(p1: *Node, q1: *Node, p2: *Node, q2: *Node) bool {
    const o1 = sign(area(p1, q1, p2));
    const o2 = sign(area(p1, q1, q2));
    const o3 = sign(area(p2, q2, p1));
    const o4 = sign(area(p2, q2, q1));

    if (o1 != o2 and o3 != o4) return true;

    if (o1 == 0 and on_segment(p1, p2, q1)) return true;
    if (o2 == 0 and on_segment(p1, q2, q1)) return true;
    if (o3 == 0 and on_segment(p2, p1, q2)) return true;
    if (o4 == 0 and on_segment(p2, q1, q2)) return true;

    return false;
}

fn on_segment(p: *Node, q: *Node, r: *Node) bool {
    return q.x <= @max(p.x, r.x) and q.x >= @min(p.x, r.x) and
        q.y <= @max(p.y, r.y) and q.y >= @min(p.y, r.y);
}

fn sign(num: f64) i32 {
    if (num > 0) return 1;
    if (num < 0) return -1;
    return 0;
}

fn intersects_polygon(a: *Node, b: *Node) bool {
    var p = a;

    while (true) {
        if (p.i != a.i and p.next.?.i != a.i and p.i != b.i and p.next.?.i != b.i and
            intersects(p, p.next.?, a, b))
        {
            return true;
        }
        p = p.next.?;
        if (p == a) break;
    }

    return false;
}

fn locally_inside(a: *Node, b: *Node) bool {
    if (area(a.prev.?, a, a.next.?) < 0) {
        return area(a, b, a.next.?) >= 0 and area(a, a.prev.?, b) >= 0;
    } else {
        return area(a, b, a.prev.?) < 0 or area(a, a.next.?, b) < 0;
    }
}

fn middle_inside(a: *Node, b: *Node) bool {
    var p = a;
    var inside = false;
    const px = (a.x + b.x) / 2.0;
    const py = (a.y + b.y) / 2.0;

    while (true) {
        if (((p.y > py) != (p.next.?.y > py)) and p.next.?.y != p.y and
            (px < (p.next.?.x - p.x) * (py - p.y) / (p.next.?.y - p.y) + p.x))
        {
            inside = !inside;
        }
        p = p.next.?;
        if (p == a) break;
    }

    return inside;
}

fn split_polygon(allocator: std.mem.Allocator, a: *Node, b: *Node) !*Node {
    const a2 = try create_node(allocator, a.i, a.x, a.y);
    const b2 = try create_node(allocator, b.i, b.x, b.y);
    const an = a.next.?;
    const bp = b.prev.?;

    a.next = b;
    b.prev = a;

    a2.next = an;
    an.prev = a2;

    b2.next = a2;
    a2.prev = b2;

    bp.next = b2;
    b2.prev = bp;

    return b2;
}


fn insert_node(allocator: std.mem.Allocator, i: u32, x: f64, y: f64, last: ?*Node) !*Node {
    const p = try create_node(allocator, i, x, y);

    if (last == null) {
        p.prev = p;
        p.next = p;
    } else {
        p.next = last.?.next;
        p.prev = last;
        last.?.next.?.prev = p;
        last.?.next = p;
    }

    return p;
}

fn remove_node(p: *Node) void {
    p.next.?.prev = p.prev;
    p.prev.?.next = p.next;

    if (p.prevz) |pz| pz.nextz = p.nextz;
    if (p.nextz) |nz| nz.prevz = p.prevz;
}

fn create_node(allocator: std.mem.Allocator, i: u32, x: f64, y: f64) !*Node {
    const node = try allocator.create(Node);
    node.* = Node{
        .i = i,
        .x = x,
        .y = y,
    };
    return node;
}

fn filter_points(start_opt: ?*Node, end_opt: ?*Node) ?*Node {
    if (start_opt == null) return null;
    const start = start_opt.?;
    var end = end_opt orelse start;

    var p = start;
    var again = true;

    while (again or p != end) {
        again = false;

        if (!p.steiner and (equals(p, p.next.?) or area(p.prev.?, p, p.next.?) == 0)) {
            remove_node(p);
            p = p.prev.?;
            end = p;
            if (p == p.next) break;
            again = true;
        } else {
            p = p.next.?;
        }
    }

    return end;
}

fn signed_area(data: []const f64, start: u32, end: u32, dim: u32) f64 {
    var sum: f64 = 0;
    var i = start;
    var j = end - dim;

    while (i < end) : (i += dim) {
        sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1]);
        j = i;
    }

    return sum;
}

