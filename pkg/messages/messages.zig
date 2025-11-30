const std = @import("std");

pub const Error = error{
    DatabaseError,
    SendFailed,
    ScriptFailed,
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

fn runAppleScript(allocator: std.mem.Allocator, script: []const u8) !ScriptResult {
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

pub fn getChatCount(allocator: std.mem.Allocator) !usize {
    var result = try runAppleScript(allocator,
        \\tell application "Messages"
        \\    return count of chats
        \\end tell
    );
    defer result.deinit();

    if (!result.success) return 0;
    return std.fmt.parseInt(usize, std.mem.trim(u8, result.stdout, " \t\n\r"), 10) catch 0;
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

pub fn getChatName(allocator: std.mem.Allocator, chat_id: []const u8) ![]u8 {
    const script = try std.fmt.allocPrint(allocator,
        \\tell application "Messages"
        \\    set c to chat id "{s}"
        \\    return name of c
        \\end tell
    , .{chat_id});
    defer allocator.free(script);

    var result = try runAppleScript(allocator, script);
    defer result.deinit();

    if (!result.success) return allocator.dupe(u8, "<unknown>");
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\n\r"));
}

pub fn sendToChat(allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8) !void {
    const escaped = try escapeForAppleScript(allocator, text);
    defer allocator.free(escaped);

    const script = try std.fmt.allocPrint(allocator,
        \\tell application "Messages"
        \\    set c to chat id "{s}"
        \\    send "{s}" to c
        \\end tell
    , .{ chat_id, escaped });
    defer allocator.free(script);

    var result = try runAppleScript(allocator, script);
    defer result.deinit();

    if (!result.success) return Error.SendFailed;
}

fn escapeForAppleScript(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.ArrayListUnmanaged(u8) = .empty;
    errdefer escaped.deinit(allocator);

    for (text) |c| {
        switch (c) {
            '"' => try escaped.appendSlice(allocator, "\\\""),
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            '\r' => try escaped.appendSlice(allocator, "\\r"),
            '\t' => try escaped.appendSlice(allocator, "\\t"),
            else => try escaped.append(allocator, c),
        }
    }

    return escaped.toOwnedSlice(allocator);
}

test "escapeForAppleScript" {
    const allocator = std.testing.allocator;
    const escaped = try escapeForAppleScript(allocator, "Hello \"World\"\nNew line");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Hello \\\"World\\\"\\nNew line", escaped);
}
