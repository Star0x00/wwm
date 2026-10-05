const std = @import("std");

pub fn print(io: std.Io, content: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.writeAll(content);
    try writer.flush();
}
