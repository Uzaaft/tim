const std = @import("std");

pub const Error = error{
    ScriptFailed,
    SendFailed,
};

pub const ScriptResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScriptResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

pub fn runAppleScript(allocator: std.mem.Allocator, script: []const u8) !ScriptResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", script },
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .success = result.term.Exited == 0,
        .allocator = allocator,
    };
}
