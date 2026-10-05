const std = @import("std");
const lib = @import("lib/lib.zig");
const cli = @import("cli.zig");
const manifest = @import("manifest.zig");
const batch = @import("batch.zig");
const data = @import("endpoints");

/// 要下载的 pack（完整 UHD 档 = common + uhd）。
const Pack = struct {
    index_file: []const u8,
    base_url: []const u8,
};

/// 3.7+ 资源档位：common 是基础本体，uhd 是 UHD 画质增量。
const packs = [_]Pack{
    .{ .index_file = data.resource_packs.common.index_file, .base_url = data.resource_packs.common.base_url },
    .{ .index_file = data.resource_packs.uhd.index_file, .base_url = data.resource_packs.uhd.base_url },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator(); // owned by the runtime, don't deinit

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const args = try init.minimal.args.toSlice(alloc);

    if (args.len < 2 or std.mem.eql(u8, args[1], "help")) {
        return cli.printHelp(io);
    }

    if (std.mem.eql(u8, args[1], "download")) {
        const path = try parsePath(init, alloc, args);
        std.log.info("Download will start.", .{});

        // 先把所有 pack 的清单取全，算出总文件数，这样能用一个 progress root。
        var mans: [packs.len]manifest.Manifest = undefined;
        var total: usize = 0;
        for (packs, 0..) |pack, i| {
            mans[i] = try manifest.getManifestFrom(alloc, &client, pack.index_file, pack.base_url);
            total += mans[i].assets.dest.len;
        }

        // std.Progress.start 每进程只能调一次，所以 root 只在这里建。
        var progress = std.Progress.start(io, .{
            .root_name = "wwm",
            .estimated_total_items = total,
        });
        defer progress.end();

        var stats = batch.Stats{ .ok = 0, .failed = 0 };
        for (&mans) |*man| {
            const s = try batch.downloadAll(io, &client, man, .{ .out_root = path }, progress);
            stats.ok += s.ok;
            stats.failed += s.failed;
        }
        std.log.info("done: {d} ok, {d} failed", .{ stats.ok, stats.failed });
        return;
    }

    try lib.print(io, "unknown command; use 'wwm help'\n");
    return error.UnknownCommand;
}

/// `wwm download` -> default under $HOME; `wwm download --path <dir>` -> given.
fn parsePath(init: std.process.Init, alloc: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
    if (args.len == 2) {
        const home = init.environ_map.get("HOME") orelse return error.NoHome;
        return std.fs.path.join(alloc, &.{ home, "Games", "WutheringWaves" });
    }
    if (args.len == 4 and std.mem.eql(u8, args[2], "--path")) {
        return args[3];
    }
    try lib.print(init.io, "usage: wwm download [--path <dir>]\n");
    return error.InvalidArgs;
}
