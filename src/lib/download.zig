const std = @import("std");

pub const DownloadError = error{
    InvalidUrl,
    BadStatus, // 4xx (except 429)
    ServerError, // 429 / 5xx
    UnsupportedContentEncoding,
    Network, // retryable
    File, // not retryable
    OutOfMemory,
};

pub fn isRetryable(err: DownloadError) bool {
    return switch (err) {
        DownloadError.Network, DownloadError.ServerError => true,
        else => false,
    };
}

pub fn download(
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    dest: []const u8,
    expected_size: u64,
) DownloadError!void {
    // 已存在且大小一致 -> 直接跳过，不发起请求。
    if (std.Io.Dir.cwd().statFile(io, dest, .{})) |st| {
        if (st.size == expected_size) return;
    } else |_| {}

    const uri = std.Uri.parse(url) catch return DownloadError.InvalidUrl;

    var req = client.request(.GET, uri, .{ .redirect_behavior = @fromBackingInt(@intCast(3)) }) catch |err| return net(err);
    defer req.deinit();
    req.sendBodiless() catch |err| return net(err);

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| return net(err);
    if (response.head.status != .ok) return switch (response.head.status.class()) {
        .server_error => DownloadError.ServerError,
        .client_error => if (response.head.status == .too_many_requests) DownloadError.ServerError else DownloadError.BadStatus,
        else => DownloadError.BadStatus,
    };

    if (std.fs.path.dirname(dest)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return DownloadError.File;
    }

    var wbuf: [8 * 1024]u8 = undefined;
    var file = std.Io.Dir.cwd().createFile(io, dest, .{}) catch return DownloadError.File;
    defer file.close(io);
    var fw = file.writer(io, &wbuf);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => alloc.alloc(u8, std.compress.zstd.default_window_len) catch return DownloadError.OutOfMemory,
        .deflate, .gzip => alloc.alloc(u8, std.compress.flate.max_window_len) catch return DownloadError.OutOfMemory,
        .compress => return DownloadError.UnsupportedContentEncoding,
    };
    defer if (decompress_buffer.len != 0) alloc.free(decompress_buffer);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);

    _ = reader.streamRemaining(&fw.interface) catch |err| return net(err);
    fw.interface.flush() catch return DownloadError.File;
}

fn net(err: anyerror) DownloadError {
    return if (err == error.OutOfMemory) DownloadError.OutOfMemory else DownloadError.Network;
}

/// How many times to retry a retryable failure (so up to `max_retries + 1` attempts).
pub const max_retries: u8 = 3;

/// `download` with retries + exponential backoff for retryable errors.
pub fn downloadRetrying(
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    dest: []const u8,
    expected_size: u64,
) DownloadError!void {
    var retries_left: u8 = max_retries;
    while (true) {
        download(alloc, io, client, url, dest, expected_size) catch |err| {
            if (!isRetryable(err) or retries_left == 0) return err;
            retries_left -= 1;
            const attempt = max_retries - retries_left; // 1, 2, 3
            const backoff_ms = 200 * (@as(u64, 1) << @intCast(attempt - 1)); // 200, 400, 800
            std.Io.sleep(io, .fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
            continue;
        };
        return;
    }
}
