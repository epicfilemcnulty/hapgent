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
}
