const std = @import("std");

test {
    _ = @import("manifest.zig");
    _ = @import("lib/http.zig");
}
