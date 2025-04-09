const std = @import("std");

const target: std.Target.Query = .{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
    .abi = .musl,
};

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "hapgent",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(target),
        .optimize = .ReleaseSmall,
    });
    b.installArtifact(exe);

    // Tests
    const agent_mod = b.addModule("agent", .{
        .root_source_file = b.path("src/agent.zig"),
    });
    
    const test_step = b.step("test", "Run hapgent tests");
    
    const agent_tests = b.addTest(.{
        .root_source_file = b.path("tests/agent.zig"),
        .target = b.resolveTargetQuery(target),
    });
    agent_tests.root_module.addImport("agent", agent_mod);
    
    const run_agent_tests = b.addRunArtifact(agent_tests);
    test_step.dependOn(&run_agent_tests.step);
}
