const std = @import("std");
const agent_mod = @import("agent");
const testing = std.testing;
const fs = std.fs;

const Agent = agent_mod.Agent;
const State = agent_mod.State;
const Status = agent_mod.Status;

test "State JSON serialization" {
    const state = State{ .status = Status.UP, .weight = 80, .maxconn = 1000 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try std.json.stringifyAlloc(arena.allocator(), state, .{});

    try testing.expectEqualStrings("{\"status\":\"UP\",\"weight\":80,\"maxconn\":1000}", json);
}

test "State JSON deserialization" {
    const json =
        \\{"status":"DOWN","weight":50,"maxconn":500}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(State, arena.allocator(), json, .{});
    defer parsed.deinit();

    try testing.expectEqual(Status.DOWN, parsed.value.status);
    try testing.expectEqual(@as(u8, 50), parsed.value.weight.?);
    try testing.expectEqual(@as(u16, 500), parsed.value.maxconn.?);
}

test "Agent setState and getState" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var agent = Agent{
        .allocator = arena.allocator(),
        .state_path = "test_state.json",
    };

    const initial_state = State{ .status = Status.UP, .weight = 75, .maxconn = 1000 };
    agent.setState(initial_state);

    try testing.expectEqual(Status.UP, agent.state.status);
    try testing.expectEqual(@as(u8, 75), agent.state.weight.?);
    try testing.expectEqual(@as(u16, 1000), agent.state.maxconn.?);
}

test "Agent saveState and readState" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const test_file = "test_state_file.json";
    // Clean up any existing test file
    fs.cwd().deleteFile(test_file) catch {};

    var agent = Agent{
        .allocator = arena.allocator(),
        .state_path = test_file,
    };

    const test_state = State{ .status = Status.READY, .weight = 90, .maxconn = 2000 };
    agent.setState(test_state);

    try agent.saveState();

    // Verify file exists
    const file = try fs.cwd().openFile(test_file, .{});
    file.close();

    // Change state
    agent.setState(State{ .status = Status.DOWN });

    // Read state from file
    const read_state = agent.readState() orelse {
        try testing.expect(false); // Should not fail
        unreachable;
    };

    try testing.expectEqual(Status.READY, read_state.status);
    try testing.expectEqual(@as(u8, 90), read_state.weight.?);
    try testing.expectEqual(@as(u16, 2000), read_state.maxconn.?);

    // Clean up
    fs.cwd().deleteFile(test_file) catch {};
}

test "Agent response formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var agent = Agent{
        .allocator = arena.allocator(),
        .state_path = "test_state.json",
    };

    // Test with just status
    agent.setState(State{ .status = Status.UP });
    const resp1 = try agent.formatResponse(arena.allocator());
    defer arena.allocator().free(resp1);
    try testing.expectEqualStrings("UP\n", resp1);

    // Test with status and weight
    agent.setState(State{ .status = Status.DRAIN, .weight = 50 });
    const resp2 = try agent.formatResponse(arena.allocator());
    defer arena.allocator().free(resp2);
    try testing.expectEqualStrings("DRAIN 50%\n", resp2);

    // Test with status, weight and maxconn
    agent.setState(State{ .status = Status.READY, .weight = 75, .maxconn = 1000 });
    const resp3 = try agent.formatResponse(arena.allocator());
    defer arena.allocator().free(resp3);
    try testing.expectEqualStrings("READY 75% maxconn:1000\n", resp3);
}
