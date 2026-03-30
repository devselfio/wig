const std = @import("std");
const skel = @import("src/skel.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_string = @import("build.zig.zon").version;
    const semver = std.SemanticVersion.parse(version_string) catch @panic("build.zig.zon: invalid .version");
    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", semver);

    const toupee_dep = b.dependency("toupee", .{ .target = target, .optimize = optimize });
    const comb_dep = b.dependency("comb", .{ .target = target, .optimize = optimize });
    const zjot_dep = b.dependency("zjot", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("wig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "toupee", .module = toupee_dep.module("toupee") },
            .{ .name = "comb", .module = comb_dep.module("comb") },
            .{ .name = "zjot", .module = zjot_dep.module("zjot") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "wig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wig", .module = mod },
                .{ .name = "options", .module = build_options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the wig CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const skel_step = b.step("skel", "Rebuild src/skel/*.tar from skel/<term>/ when sources are newer");
    skel_step.makeFn = skelStepMake;
}

fn skelStepMake(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    const b = step.owner;
    const gpa = options.gpa;
    const root = b.build_root.path orelse {
        std.log.err("skel: build root path unavailable", .{});
        return error.MakeFailed;
    };
    for (skel.terms) |term| {
        skel.repack(gpa, root, term) catch |err| {
            std.log.err("skel repack '{s}': {s}", .{ term, @errorName(err) });
            return error.MakeFailed;
        };
    }
}
