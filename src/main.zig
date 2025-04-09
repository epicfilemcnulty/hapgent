const std = @import("std");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const Status = agent_mod.Status;
const State = agent_mod.State;
const default_state = agent_mod.default_state;
const net = std.net;

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
