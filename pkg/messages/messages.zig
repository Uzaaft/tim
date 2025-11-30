const std = @import("std");
const zqlite = @import("zqlite");

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

pub const Chat = struct {
    id: i64,
    chat_identifier: []u8,
    display_name: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Chat) void {
        self.allocator.free(self.chat_identifier);
        self.allocator.free(self.display_name);
    }
};

pub const Message = struct {
    text: []u8,
    is_from_me: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.text);
    }
};

fn getDbPath(buf: []u8) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.bufPrintZ(buf, "{s}/Library/Messages/chat.db", .{home}) catch return error.PathTooLong;
}

pub fn getChats(allocator: std.mem.Allocator, chats: *std.ArrayListUnmanaged(Chat)) !void {
    if (getChatsFromDb(allocator, chats)) {
        return;
    } else |_| {}

    getChatsFromAppleScript(allocator, chats) catch {};
}

fn getChatsFromDb(allocator: std.mem.Allocator, chats: *std.ArrayListUnmanaged(Chat)) !void {
    var path_buf: [512]u8 = undefined;
    const db_path = try getDbPath(&path_buf);

    var conn = try zqlite.open(db_path, zqlite.OpenFlags.ReadOnly);
    defer conn.close();

    const query =
        \\SELECT c.ROWID, c.chat_identifier, 
        \\       COALESCE(NULLIF(c.display_name, ''), h.id, c.chat_identifier) as name
        \\FROM chat c
        \\LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        \\LEFT JOIN handle h ON chj.handle_id = h.ROWID
        \\GROUP BY c.ROWID
        \\ORDER BY c.ROWID DESC
        \\LIMIT 100
    ;

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const chat_id = row.int(0);
        const identifier = row.text(1);
        const name_raw = row.text(2);
        const name = if (name_raw.len > 0) name_raw else identifier;

        try chats.append(allocator, .{
            .id = chat_id,
            .chat_identifier = try allocator.dupe(u8, identifier),
            .display_name = try allocator.dupe(u8, name),
            .allocator = allocator,
        });
    }
}

fn getChatsFromAppleScript(allocator: std.mem.Allocator, chats: *std.ArrayListUnmanaged(Chat)) !void {
    var result = try runAppleScript(allocator,
        \\tell application "Messages"
        \\    set output to ""
        \\    repeat with c in chats
        \\        set chatName to id of c
        \\        try
        \\            set p to participants of c
        \\            if (count of p) > 0 then
        \\                set chatName to name of item 1 of p
        \\            end if
        \\        end try
        \\        set output to output & (id of c) & "|" & chatName & linefeed
        \\    end repeat
        \\    return output
        \\end tell
    );
    defer result.deinit();

    if (!result.success) return;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var idx: i64 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, '|');
        const identifier = parts.next() orelse continue;
        const name = parts.rest();

        try chats.append(allocator, .{
            .id = idx,
            .chat_identifier = try allocator.dupe(u8, identifier),
            .display_name = try allocator.dupe(u8, if (name.len > 0) name else identifier),
            .allocator = allocator,
        });
        idx += 1;
    }
}

pub fn getMessages(allocator: std.mem.Allocator, chat_id: i64, chat_identifier: []const u8, msg_list: *std.ArrayListUnmanaged(Message)) !void {
    if (getMessagesFromDb(allocator, chat_id, msg_list)) {
        return;
    } else |_| {}

    getMessagesFromAppleScript(allocator, chat_identifier, msg_list) catch {};
}

fn getMessagesFromDb(allocator: std.mem.Allocator, chat_id: i64, msg_list: *std.ArrayListUnmanaged(Message)) !void {
    var path_buf: [512]u8 = undefined;
    const db_path = try getDbPath(&path_buf);

    var conn = try zqlite.open(db_path, zqlite.OpenFlags.ReadOnly);
    defer conn.close();

    const query =
        \\SELECT m.text, m.is_from_me, m.attributedBody
        \\FROM message m
        \\JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        \\WHERE cmj.chat_id = ?1
        \\ORDER BY m.date DESC
        \\LIMIT 50
    ;

    var rows = try conn.rows(query, .{chat_id});
    defer rows.deinit();

    while (rows.next()) |row| {
        var text: []const u8 = row.text(0);

        if (text.len == 0) {
            const blob_data = row.nullableBlob(2);
            if (blob_data) |bd| {
                if (extractTextFromAttributedBody(bd)) |extracted| {
                    text = extracted;
                }
            }
        }

        if (text.len == 0) continue;

        try msg_list.append(allocator, .{
            .text = try allocator.dupe(u8, text),
            .is_from_me = row.int(1) == 1,
            .allocator = allocator,
        });
    }
}

fn getMessagesFromAppleScript(allocator: std.mem.Allocator, chat_identifier: []const u8, msg_list: *std.ArrayListUnmanaged(Message)) !void {
    const script = try std.fmt.allocPrint(allocator,
        \\tell application "Messages"
        \\    set c to chat id "{s}"
        \\    set output to ""
        \\    set msgItems to messages of c
        \\    set maxCount to count of msgItems
        \\    if maxCount > 50 then set maxCount to 50
        \\    repeat with i from 1 to maxCount
        \\        set m to item i of msgItems
        \\        set fromMe to "0"
        \\        try
        \\            if sender of m is missing value then set fromMe to "1"
        \\        end try
        \\        set msgText to ""
        \\        try
        \\            set msgText to text of m
        \\        end try
        \\        if msgText is not "" then
        \\            set output to output & fromMe & "|" & msgText & linefeed
        \\        end if
        \\    end repeat
        \\    return output
        \\end tell
    , .{chat_identifier});
    defer allocator.free(script);

    var result = try runAppleScript(allocator, script);
    defer result.deinit();

    if (!result.success) return;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, '|');
        const from_me_str = parts.next() orelse continue;
        const text = parts.rest();
        if (text.len == 0) continue;

        try msg_list.append(allocator, .{
            .text = try allocator.dupe(u8, text),
            .is_from_me = std.mem.eql(u8, from_me_str, "1"),
            .allocator = allocator,
        });
    }
}

fn extractTextFromAttributedBody(blob: []const u8) ?[]const u8 {
    const marker = "NSString";
    if (std.mem.indexOf(u8, blob, marker)) |idx| {
        var start = idx + marker.len;
        while (start < blob.len and (blob[start] < 0x20 or blob[start] > 0x7E)) {
            start += 1;
        }
        var end = start;
        while (end < blob.len and blob[end] >= 0x20 and blob[end] <= 0x7E) {
            end += 1;
        }
        if (end > start) {
            return blob[start..end];
        }
    }
    return null;
}

test "extractTextFromAttributedBody" {
    const allocator = std.testing.allocator;
    _ = allocator;
}
