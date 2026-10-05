const std = @import("std");
const http = @import("lib/http.zig");
const testing = std.testing;

/// Shape of an indexFile (档位包 / 全量 resource.json 同构):
/// `{"resource":[{dest, md5, size}, ...]}`.
pub const Resource = struct { dest: []const u8, md5: []const u8, size: u64 };
pub const Resources = struct { resource: []const Resource };

/// Column-oriented view into the caller's arena; borrows, does not own.
pub const Assets = struct {
    dest: [][]const u8,
    md5: [][]const u8,
    size: []u64,
};

/// All fields borrow from the allocator/arena passed to `getManifestFrom`;
/// nothing here needs (or can) be freed individually.
pub const Manifest = struct {
    /// Absolute CDN prefix (trailing '/'); download URL = base_url ++ <encoded dest>.
    base_url: []const u8,
    assets: Assets,
};

/// Percent-encode a path segment(s) so it can be appended to a URL,
/// keeping `/` (and other path chars) intact.
/// e.g. "Wuthering Waves.exe" -> "Wuthering%20Waves.exe"
pub fn encodePathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const c = std.Uri.Component{ .raw = path };
    return std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(c, .formatPath)});
}

/// Fetch an absolute `index_file` URL and turn its `resource[]` into columns.
/// `base_url` is the absolute CDN prefix those files live under.
/// Everything is allocated in `alloc` (caller's arena).
pub fn getManifestFrom(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    index_file: []const u8,
    base_url: []const u8,
) !Manifest {
    const raw = try http.fetchAll(alloc, client, index_file);
    const res = try std.json.parseFromSlice(Resources, alloc, raw, .{ .ignore_unknown_fields = true });

    const list = res.value.resource;
    const dest = try alloc.alloc([]const u8, list.len);
    const md5 = try alloc.alloc([]const u8, list.len);
    const size = try alloc.alloc(u64, list.len);
    for (list, 0..) |item, i| {
        dest[i] = item.dest;
        md5[i] = item.md5;
        size[i] = item.size;
    }

    return .{
        .base_url = base_url,
        .assets = .{ .dest = dest, .md5 = md5, .size = size },
    };
}

test "encodePath" {
    const gpa = testing.allocator;
    const encoded = try encodePathAlloc(gpa, "Wuthering Waves.exe");
    defer gpa.free(encoded);
    try testing.expectEqualStrings("Wuthering%20Waves.exe", encoded);

    const sub = try encodePathAlloc(gpa, "Client/Binaries/Win64/a b#c?.dll");
    defer gpa.free(sub);
    try testing.expectEqualStrings("Client/Binaries/Win64/a%20b%23c%3F.dll", sub);
}

test "getManifestFrom reads an indexFile" {
    // common pack (815 files)
    const index_file = "https://pcdownload-aliyun.aki-game.com/launcher/game/G152/10003/3.7.0/983fc4b836c240319aa3a0fc2c9f8514/common/indexFile.json";
    const base_url = "https://pcdownload-aliyun.aki-game.com/launcher/game/G152/10003/3.7.0/983fc4b836c240319aa3a0fc2c9f8514/zip/";
    const io = testing.io;
    const gpa = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    const man = try getManifestFrom(arena, &client, index_file, base_url);
    try testing.expectEqualStrings(base_url, man.base_url);
    try testing.expectEqual(@as(usize, 815), man.assets.dest.len);
}
