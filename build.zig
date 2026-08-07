const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gen_unicode = b.addExecutable(.{
        .name = "gen-unicode",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tools/gen-unicode.zig"),
        }),
    });

    const gen_unicode_run = b.addRunArtifact(gen_unicode);
    gen_unicode_run.addDirectoryArg(b.path("tools/data/unicode/18.0.0/"));
    const unicode_generated_zig = gen_unicode_run.addOutputFileArg("unicode_generated.zig");
    const unicode_conformance_zig = gen_unicode_run.addOutputFileArg("unicode_conformance.zig");
    _ = gen_unicode_run.addOutputFileArg("NormalizationTest.txt");
    _ = gen_unicode_run.addOutputFileArg("emoji-test.txt");

    const unicode_generated_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = unicode_generated_zig,
    });

    const unicode_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/unicode.zig"),
    });

    unicode_mod.addImport("unicode_generated", unicode_generated_mod);

    const plat_t = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = if (target.result.os.tag == .linux)
            b.path("src/plat/linux.h")
        else if (target.result.os.tag == .macos or target.result.os.tag == .freebsd)
            b.path("src/plat/macos.h")
        else
            @panic("Not implemented"),
    });

    if (target.result.os.tag == .linux) {
        // TODO:
        plat_t.defineCMacro("_FORTIFY_SOURCE", "0");
    }

    const plat_mod = plat_t.createModule();

    const pq_t = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/pq.h"),
    });

    if (target.result.os.tag == .macos) {
        pq_t.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include/postgresql/" });
    } else if (target.result.os.tag == .linux) {
        pq_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include/postgresql/" });
    } else if (target.result.os.tag == .freebsd) {
        pq_t.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include/" });
    }

    const pq_mod = pq_t.createModule();

    if (target.result.os.tag == .macos) {
        pq_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib/postgresql/" });
    } else if (target.result.os.tag == .linux) {
        pq_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/" });
    } else if (target.result.os.tag == .freebsd) {
        pq_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib/" });
    }

    pq_mod.linkSystemLibrary("pq", .{ .preferred_link_mode = .dynamic });

    const avformat_t = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/avformat.h"),
    });

    if (target.result.os.tag == .macos) {
        avformat_t.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    } else if (target.result.os.tag == .linux) {
        avformat_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    const avformat_mod = avformat_t.createModule();

    if (target.result.os.tag == .macos) {
        avformat_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else if (target.result.os.tag == .linux) {
        avformat_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/" });
    }

    avformat_mod.linkSystemLibrary("avformat", .{
        .use_pkg_config = .no,
    });
    avformat_mod.linkSystemLibrary("avcodec", .{
        .use_pkg_config = .no,
    });
    avformat_mod.linkSystemLibrary("avutil", .{
        .use_pkg_config = .no,
    });

    const swscale_t = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/swscale.h"),
    });

    if (target.result.os.tag == .macos) {
        swscale_t.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    } else if (target.result.os.tag == .linux) {
        swscale_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    const swscale_mod = swscale_t.createModule();

    if (target.result.os.tag == .macos) {
        swscale_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else if (target.result.os.tag == .linux) {
        swscale_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/" });
    }

    swscale_mod.linkSystemLibrary("swscale", .{
        .use_pkg_config = .no,
    });

    const webp_t = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/webp.h"),
    });

    if (target.result.os.tag == .macos) {
        webp_t.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    } else if (target.result.os.tag == .linux) {
        webp_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        webp_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    const webp_mod = webp_t.createModule();

    if (target.result.os.tag == .macos) {
        webp_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else if (target.result.os.tag == .linux) {
        webp_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/" });
    }

    webp_mod.linkSystemLibrary("webpdemux", .{
        .use_pkg_config = .no,
    });
    webp_mod.linkSystemLibrary("webp", .{
        .use_pkg_config = .no,
    });

    const curl_t = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/curl.h"),
    });

    if (target.result.os.tag == .macos) {
        curl_t.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    } else if (target.result.os.tag == .linux) {
        curl_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        curl_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    }

    const curl_mod = curl_t.createModule();

    if (target.result.os.tag == .macos) {
        curl_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else if (target.result.os.tag == .linux) {
        curl_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/" });
    }

    curl_mod.linkSystemLibrary("curl", .{
        .use_pkg_config = .no,
    });

    const mod = b.addModule("distrans", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "plat", .module = plat_mod },
            .{ .name = "pq", .module = pq_mod },
            .{ .name = "avformat", .module = avformat_mod },
            .{ .name = "swscale", .module = swscale_mod },
            .{ .name = "unicode_generated", .module = unicode_generated_mod },
            .{ .name = "unicode", .module = unicode_mod },
            .{ .name = "webp", .module = webp_mod },
            .{ .name = "curl", .module = curl_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "distrans",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "distrans", .module = mod },
                .{ .name = "plat", .module = plat_mod },
            },
        }),
    });

    if (target.result.os.tag == .linux) {
        const systemd_t = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/systemd.h"),
        });

        systemd_t.addSystemIncludePath(.{ .cwd_relative = "/usr/include/" });

        const systemd_mod = systemd_t.createModule();

        systemd_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        systemd_mod.linkSystemLibrary("systemd", .{
            .use_pkg_config = .no,
        });

        mod.addImport("systemd", systemd_mod);
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const unicode_tests_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = unicode_conformance_zig,
    });

    unicode_tests_mod.addImport("unicode", unicode_mod);

    const unicode_tests = b.addTest(.{
        .root_module = unicode_tests_mod,
    });

    const run_unicode_tests = b.addRunArtifact(unicode_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_unicode_tests.step);
}
