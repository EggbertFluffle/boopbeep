const std = @import("std");

const cross_compile_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
};

pub fn build_for_target(b: *std.Build, target: std.Build.ResolvedTarget, strip: bool) void {
    const arch = target.query.cpu_arch;
    const os = target.query.os_tag;

    const target_name = blk: {
        if (arch == null or os == null) {
            break :blk "boopbeep";
        }

        break :blk std.fmt.allocPrint(std.heap.page_allocator, "boopbeep-{s}-{s}", .{
            switch (arch.?) {
                .aarch64 => "aarch64",
                .x86_64 => "x86",
                .arm => "arm",
                else => "arch",
            },
            switch (os.?) {
                .windows => "windows",
                .linux => "linux",
                .macos => "macos",
                else => "os",
            },
        }) catch "boopbeep";
    };

    const miniaudio_dep = b.dependency("miniaudio", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = .Debug,
    });
    translate_c.addIncludePath(miniaudio_dep.path("."));

    const c_module = translate_c.createModule();
    c_module.link_libc = true;

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .strip = strip,
        .imports = &.{
            .{ .name = "c", .module = c_module },
        },
    });

    root_mod.addCSourceFile(.{
        .file = miniaudio_dep.path("miniaudio.c"),
        .flags = &.{
            "-fno-sanitize=undefined",
        },
    });
    root_mod.addIncludePath(miniaudio_dep.path("."));

    const exe = b.addExecutable(.{
        .name = target_name,
        .root_module = root_mod,
    });

    b.installArtifact(exe);
}

pub fn build(b: *std.Build) void {
    const cross_compile = b.option(bool, "cross_compile", "Do cross compilation for all platforms") orelse false;
    const strip = b.option(bool, "strip", "Strip debug information from the produced binaries") orelse false;

    if (cross_compile) {
        for (cross_compile_targets) |target_query| {
            build_for_target(b, b.resolveTargetQuery(target_query), strip);
        }
    } else {
        const target = b.standardTargetOptions(.{});
        build_for_target(b, target, strip);
    }
}
