const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const net = std.net;

pub const Status = enum {
    UP,
    DOWN,
    READY,
    DRAIN,
    FAIL,
    MAINT,
    STOPPED,
};

pub const State = struct {
    status: Status,
    weight: ?u8 = null,
    maxconn: ?u16 = null,

    pub fn jsonStringify(self: State, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("status");
        try jws.write(@tagName(self.status));
        if (self.weight) |weight| {
            try jws.objectField("weight");
            try jws.write(weight);
        }
        if (self.maxconn) |maxconn| {
            try jws.objectField("maxconn");
            try jws.write(maxconn);
        }
        try jws.endObject();
    }
};

pub const default_state = State{ .status = Status.MAINT, .weight = null, .maxconn = null };

pub const Agent = struct {
    state: State = default_state,
    mutex: Mutex = .{},
    allocator: Allocator,
    state_path: []const u8,

    pub fn reportState(self: Agent) void {
        std.debug.print("Current state: status={s}, weight={?d}, maxconn={?d}\n", .{ @tagName(self.state.status), self.state.weight, self.state.maxconn });
    }

    pub fn setState(self: *Agent, s: State) void {
        self.mutex.lock();
        self.state = s;
        self.mutex.unlock();
    }

    pub fn readState(self: Agent) ?State {
        // 512 bytes should be more than enough
        // for the JSON-string representation of our state, so
        // it's hardcoded here in stone.
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.state_path, 512) catch |err| {
            std.log.err("Failed to read state file: {}", .{err});
            return null;
        };
        defer self.allocator.free(data);
        const s = std.json.parseFromSlice(State, self.allocator, data, .{ .allocate = .alloc_always }) catch |err| {
            std.log.err("Failed to parse state file: {}", .{err});
            return null;
        };
        return s.value;
    }

    pub fn saveState(self: *Agent) !void {
        self.mutex.lock();
        const state_copy = self.state;
        self.mutex.unlock();

        const file = try std.fs.cwd().createFile(self.state_path, .{ .mode = 0o644 });
        defer file.close();

        const state_json = try std.json.stringifyAlloc(self.allocator, state_copy, .{ .whitespace = .indent_2 });
        defer self.allocator.free(state_json);

        try file.writeAll(state_json);
        std.debug.print("State saved to {s} file.\n", .{self.state_path});
    }

    pub fn sigHup(self: *Agent) void {
        const s = self.readState() orelse default_state;
        self.setState(s);
        self.reportState();
    }

    pub fn handleConnection(self: *Agent, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        self.mutex.lock();
        defer self.mutex.unlock();
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        response.writer().print("{s}", .{@tagName(self.state.status)}) catch |err| {
            std.log.err("Failed to format response: {}", .{err});
            return;
        };

        if (self.state.weight) |weight| {
            response.writer().print(" {d}%", .{weight}) catch |err| {
                std.log.err("Failed to format response: {}", .{err});
                return;
            };
        }

        if (self.state.maxconn) |maxconn| {
            response.writer().print(" maxconn:{d}", .{maxconn}) catch |err| {
                std.log.err("Failed to format response: {}", .{err});
                return;
            };
        }

        response.writer().print("\n", .{}) catch |err| {
            std.log.err("Failed to format response: {}", .{err});
            return;
        };

        conn.stream.writeAll(response.items) catch |err| {
            std.log.err("Failed to write response: {}", .{err});
        };
    }

    // Helper function for testing the response formatting
    pub fn formatResponse(self: *Agent, allocator: Allocator) ![]u8 {
        var response = std.ArrayList(u8).init(allocator);
        errdefer response.deinit();

        try response.writer().print("{s}", .{@tagName(self.state.status)});

        if (self.state.weight) |weight| {
            try response.writer().print(" {d}%", .{weight});
        }

        if (self.state.maxconn) |maxconn| {
            try response.writer().print(" maxconn:{d}", .{maxconn});
        }

        try response.writer().print("\n", .{});

        return response.toOwnedSlice();
    }
};
