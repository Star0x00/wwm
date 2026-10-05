const std = @import("std");
const print = @import("lib/print.zig").print;

pub fn printHelp(io: std.Io) !void {
    const content = (
        \\ usage: wwm <command> [options]
        \\
        \\ command:
        \\   help                       print help
        \\   download --path <dir>      download ww to path
        \\
    );
    try print(io, content);
}
