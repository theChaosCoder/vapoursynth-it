const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(b.path("vendor/vapoursynth"));

    const lib = b.addLibrary(.{
        .name = "zit",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // ---- Unit tests -------------------------------------------------------
    // On Linux we explicitly pin the test target to `x86_64-linux-gnu` so
    // that Zig links against its bundled glibc startup files. The system
    // crt1.o on some recent distros (e.g. CachyOS glibc 16.1.1) emits
    // `.sframe` relocations that Zig's LLD does not yet understand, which
    // breaks `zig build test` for native-host targets. The shared library
    // build is unaffected (no crt linkage).
    const host_tag = builtin.os.tag;
    const test_target = if (host_tag == .linux)
        b.resolveTargetQuery(std.Target.Query.parse(
            .{ .arch_os_abi = "x86_64-linux-gnu" },
        ) catch unreachable)
    else
        target;

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = test_target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addIncludePath(b.path("vendor/vapoursynth"));

    const unit_tests = b.addTest(.{ .root_module = tests_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ---- Cross-compile convenience targets -------------------------------
    // `zig build cross` produces release artifacts for the five supported
    // (OS, arch) tuples. Each target is installed under `zig-out/<name>/`.
    const cross_step = b.step("cross", "Build release artifacts for Linux/macOS/Windows (x86_64 + ARM64)");

    const cross_targets = .{
        .{ .name = "linux-x86_64", .triple = "x86_64-linux-gnu" },
        .{ .name = "linux-aarch64", .triple = "aarch64-linux-gnu" },
        .{ .name = "macos-x86_64", .triple = "x86_64-macos" },
        .{ .name = "macos-aarch64", .triple = "aarch64-macos" },
        .{ .name = "windows-x86_64", .triple = "x86_64-windows-gnu" },
    };

    inline for (cross_targets) |t| {
        const cross_target = b.resolveTargetQuery(
            std.Target.Query.parse(.{ .arch_os_abi = t.triple }) catch unreachable,
        );
        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/plugin.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        cross_mod.addIncludePath(b.path("vendor/vapoursynth"));

        const cross_lib = b.addLibrary(.{
            .name = "zit",
            .linkage = .dynamic,
            .root_module = cross_mod,
        });

        const install = b.addInstallArtifact(cross_lib, .{
            .dest_dir = .{ .override = .{ .custom = t.name } },
        });
        cross_step.dependOn(&install.step);
    }
}
