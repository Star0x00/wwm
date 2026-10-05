const std = @import("std");
const testing = std.testing;

pub fn fetchAll(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var body = std.Io.Writer.Allocating.init(alloc);
    errdefer body.deinit();
    _ = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    return body.toOwnedSlice();
}

test "fetch test" {
    const url = "https://prod-cn-alicdn-gamestarter.kurogame.com/launcher/game/G152/10003_Y8xXrXk65DqFHEDgApn3cpK5lfczpFx5/index.json";
    const io = testing.io;
    const gpa = testing.allocator;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const raw = try fetchAll(gpa, &client, url);
    defer gpa.free(raw);
}
