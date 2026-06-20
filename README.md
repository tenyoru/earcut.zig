# earcut.zig

Zig port of [mapbox/earcut](https://github.com/mapbox/earcut) — a fast polygon triangulation algorithm. Takes a flat vertex array and returns triangle indices. Supports concave polygons and holes.

## Install

```sh
zig fetch --save https://github.com/tenyoru/earcut.zig/archive/refs/heads/main.tar.gz
```

`build.zig`:

```zig
const earcut = b.dependency("earcut", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("earcut", earcut.module("earcut"));
```

## Usage

```zig
const earcut = @import("earcut");

const indices = try earcut.earcut(allocator, &vertices, null, 2);
// with holes:
const indices = try earcut.earcut(allocator, &vertices, &hole_indices, 2);
```

## Credits

Algorithm by [Mapbox](https://github.com/mapbox/earcut) (ISC License).
