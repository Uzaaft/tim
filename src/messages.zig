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

pub fn sendMessage(allocator: std.mem.Allocator, recipient: []const u8, text: []const u8) !void {
    const escaped = try escapeForAppleScript(allocator, text);
    defer allocator.free(escaped);

    const script = try std.fmt.allocPrint(allocator,
        \\tell application "Messages"
        \\    send "{s}" to buddy "{s}"
        \\end tell
    , .{ escaped, recipient });
    defer allocator.free(script);

    var result = try runAppleScript(allocator, script);
    defer result.deinit();

    if (!result.success) return Error.SendFailed;
}

pub fn isMessagesRunning(allocator: std.mem.Allocator) !bool {
    const script =
        \\tell application "System Events"
        \\    return (name of processes) contains "Messages"
        \\end tell
    ;

    var result = try runAppleScript(allocator, script);
    defer result.deinit();

    if (!result.success) return false;
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\n\r"), "true");
}

pub fn launchMessages(allocator: std.mem.Allocator) !void {
    var result = try runAppleScript(allocator,
        \\tell application "Messages"
        \\    activate
        \\end tell
    );
    defer result.deinit();
}
pub fn chatIds(allocator: std.mem.Allocator, ids: *std.ArrayListUnmanaged([]u8)) !void {
    var result = try runAppleScript(allocator,
        \\tell application "Messages"
        \\    set chatList to {}
        \\    repeat with c in chats
        \\        set end of chatList to id of c
        \\    end repeat
        \\    set AppleScript's text item delimiters to linefeed
        \\    return chatList as text
        \\end tell
    );
    defer result.deinit();

    if (!result.success) return;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
}
