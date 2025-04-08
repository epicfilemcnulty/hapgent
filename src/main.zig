const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const net = std.net;

const Status = enum {
    UP,
    DOWN,
    READY,
    DRAIN,
    FAIL,
    MAINT,
    STOPPED,
};

const State = struct {
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

const default_state = State{ .status = Status.MAINT, .weight = null, .maxconn = null };

const Agent = struct {
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
};

var agent: Agent = .{ .allocator = undefined, .state_path = undefined };

fn handleSignals(signal: i32) callconv(.C) void {
    switch (signal) {
        std.posix.SIG.HUP => {
            std.debug.print("Got SIGHUP, re-reading state file...\n", .{});
            agent.sigHup();
        },
        std.posix.SIG.USR1 => {
            std.debug.print("Got SIGUSR1, changing status to UP...\n", .{});
            var s = agent.state;
            s.status = Status.UP;
            agent.setState(s);
            agent.saveState() catch |err| {
                std.log.err("Failed to save state file: {}", .{err});
            };
            agent.reportState();
        },
        std.posix.SIG.USR2 => {
            std.debug.print("Got SIGUSR2, changing status to DOWN...\n", .{});
            var s = agent.state;
            s.status = Status.DOWN;
            agent.setState(s);
            agent.saveState() catch |err| {
                std.log.err("Failed to save state file: {}", .{err});
            };
            agent.reportState();
        },
        else => {},
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    agent.allocator = allocator;
    agent.state_path = std.posix.getenv("HAPGENT_STATE_FILE") orelse "/etc/hapgent/state.json";

    agent.sigHup();

    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignals },
        .mask = std.posix.empty_sigset,
        .flags = std.posix.SA.RESTART,
    };

    std.posix.sigaction(std.posix.SIG.USR1, &sa, null);
    std.posix.sigaction(std.posix.SIG.USR2, &sa, null);
    std.posix.sigaction(std.posix.SIG.HUP, &sa, null);

    const ip = std.posix.getenv("HAPGENT_IP") orelse "0.0.0.0";
    const port = std.posix.getenv("HAPGENT_PORT") orelse "9777";

    const port_number = try std.fmt.parseInt(u16, port, 10);
    const address = try net.Address.parseIp(ip, port_number);

    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Server listening on {s}:{d}\n", .{ ip, port_number });

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, Agent.handleConnection, .{ &agent, conn });
        thread.detach();
    }
}
