const std = @import("std");
const Builder = std.build.Builder;
const gnorp = @import("libs/gnorp/build.zig");

const title = "wireworld";
const version = "v0.0.1";
const this_dir = thisDir();

pub fn build(b: *Builder) !void {
    const build_mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "build_prefix", if (build_mode == .Debug) (this_dir ++ "/src/") else "");
    exe_options.addOption([]const u8, "content_dir", this_dir ++ "/testdata");
    exe_options.addOption([:0]const u8, "title", title);
    exe_options.addOption([:0]const u8, "version", version);

    const exe = b.addExecutable(title, this_dir ++ "/src/main.zig");
    exe.addOptions("build_options", exe_options);
    exe.setBuildMode(build_mode);
    exe.setTarget(target);
    exe.install();
    try link(b, exe);

    const run_cmd = exe.run();
    const run_step = b.step("run", "run program");
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        for (args) |argv|
            try run_cmd.argv.append(.{ .bytes = try b.allocator.dupe(u8, argv) });
    }

    const tests = b.addTest(this_dir ++ "/src/main.zig");
    tests.setBuildMode(build_mode);
    tests.setTarget(target);
    tests.addOptions("build_options", exe_options);
    try link(b, tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}

fn link(b: *std.build.Builder, exe: *std.build.LibExeObjStep) !void {
    try gnorp.link(b, exe);
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
