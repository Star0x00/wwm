const std = @import("std");
const manifest = @import("manifest.zig");
const download = @import("lib/download.zig");

pub const Stats = struct {
    ok: usize,
    failed: usize,
};

pub const Options = struct {
    out_root: []const u8,
    /// Number of worker tasks (= concurrent downloads).
    concurrency: usize = 8,
};

const Shared = struct {
    io: std.Io,
    client: *std.http.Client,
    man: *const manifest.Manifest,
    out_root: []const u8,
    progress: std.Progress.Node,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    ok: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

/// Downloads every asset in `man` to `opts.out_root`, with `opts.concurrency`
/// workers pulling from a shared work queue. `progress` is the caller-owned
/// parent node (std.Progress.start may only be called once per process).
pub fn downloadAll(
    io: std.Io,
    client: *std.http.Client,
    man: *const manifest.Manifest,
    opts: Options,
    progress: std.Progress.Node,
) !Stats {
    var shared = Shared{
        .io = io,
        .client = client,
        .man = man,
        .out_root = opts.out_root,
        .progress = progress,
    };

    const workers = try std.heap.page_allocator.alloc(std.Io.Future(void), opts.concurrency);
    defer std.heap.page_allocator.free(workers);
    for (workers) |*w| w.* = io.async(worker, .{&shared});
    for (workers) |*w| w.await(io);

    return .{
        .ok = shared.ok.load(.monotonic),
        .failed = shared.failed.load(.monotonic),
    };
}

fn worker(shared: *Shared) void {
    const io = shared.io;

    // Each worker owns its arena; arenas are NOT thread-safe.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.man.assets.dest.len) return;

        defer _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const dest = shared.man.assets.dest[i];

        // One child node per file: shows the name, and `end()` bumps the parent.
        const item = shared.progress.start(dest, 1);
        defer item.end();

        const encoded = manifest.encodePathAlloc(arena, dest) catch {
            _ = shared.failed.fetchAdd(1, .monotonic);
            continue;
        };
        // base_url 自带结尾 '/'，直接拼 dest 即可。
        const url = std.mem.concat(arena, u8, &.{ shared.man.base_url, encoded }) catch {
            _ = shared.failed.fetchAdd(1, .monotonic);
            continue;
        };
        const out = std.fs.path.join(arena, &.{ shared.out_root, dest }) catch {
            _ = shared.failed.fetchAdd(1, .monotonic);
            continue;
        };

        download.downloadRetrying(arena, io, shared.client, url, out, shared.man.assets.size[i]) catch |err| {
            _ = shared.failed.fetchAdd(1, .monotonic);
            std.log.err("asset {d}/{d} {s}: {t}", .{ i + 1, shared.man.assets.dest.len, dest, err });
            continue;
        };
        _ = shared.ok.fetchAdd(1, .monotonic);
    }
}
