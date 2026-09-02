const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Wayland Scanner setup
    const scanner = Scanner.create(b, .{});
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("xdg_wm_base", 3);
    scanner.addSystemProtocol("unstable/tablet/tablet-unstable-v2.xml");
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.addSystemProtocol("staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml");
    scanner.generate("ext_foreign_toplevel_list_v1", 1);
    scanner.addSystemProtocol("staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml");
    scanner.generate("ext_image_copy_capture_manager_v1", 1);
    scanner.addSystemProtocol("staging/ext-image-capture-source/ext-image-capture-source-v1.xml");
    scanner.generate("ext_output_image_capture_source_manager_v1", 1);
    scanner.generate("ext_foreign_toplevel_image_capture_source_manager_v1", 1);
    scanner.addCustomProtocol(.{
        .cwd_relative = "/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml",
    });
    // Not in the system wayland-protocols package; wlroots vendors this
    // exact copy in its own protocol/ dir.
    scanner.addCustomProtocol(.{
        .cwd_relative = "protocols/virtual-keyboard-unstable-v1.xml",
    });
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.addCustomProtocol(.{
        .cwd_relative = "/usr/share/wlr-protocols/unstable/wlr-output-power-management-unstable-v1.xml",
    });
    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);

    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.addSystemProtocol("staging/ext-idle-notify/ext-idle-notify-v1.xml");
    scanner.generate("ext_idle_notifier_v1", 2);
    scanner.addSystemProtocol("unstable/idle-inhibit/idle-inhibit-unstable-v1.xml");
    scanner.generate("zwp_idle_inhibit_manager_v1", 1);

    const wayland_mod = b.createModule(.{
        .root_source_file = scanner.result,
    });

    // 2. Fetch dependencies
    const wlroots_dep = b.dependency("wlroots", .{});
    const pixman_dep = b.dependency("pixman", .{}); // <--- Fetch pixman dependency

    const wlroots_mod = wlroots_dep.module("wlroots");
    const pixman_mod = pixman_dep.module("pixman"); // <--- Extract pixman module

    // Connect dependencies into wlroots module
    wlroots_mod.addImport("wayland", wayland_mod);
    wlroots_mod.addImport("pixman", pixman_mod); // <--- Satisfies @import("pixman") in wlroots
    wlroots_mod.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "/usr/include/wlroots-0.20" } });
    wlroots_mod.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "/usr/include/pixman-1" } });

    // 3. Main Executable
    const log_level = b.option(std.log.Level, "log", "Log level (err, warn, info, debug)") orelse .info;
    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    // Keep in sync with build.zig.zon's .version.
    options.addOption([]const u8, "version", "0.1.0");

    const exe = b.addExecutable(.{
        .name = "zylr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    const xkbcommon = b.lazyDependency("xkbcommon", .{}) orelse return;

    exe.root_module.addImport(
        "xkbcommon",
        xkbcommon.module("xkbcommon"),
    );

    // Attach imports to executable
    wlroots_mod.addImport(
        "xkbcommon",
        xkbcommon.module("xkbcommon"),
    );

    // Vendored minimal ziggy deserializer (upstream build targets newer
    // Zig); see vendor/ziggy/root.zig.
    exe.root_module.addImport("ziggy", b.createModule(.{
        .root_source_file = b.path("vendor/ziggy/root.zig"),
    }));

    exe.root_module.addImport("wlroots", wlroots_mod);
    exe.root_module.addImport("wayland", wayland_mod);
    exe.root_module.addImport("pixman", pixman_mod);
    exe.root_module.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "/usr/include/wlroots-0.20" } });
    exe.root_module.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "/usr/include/scenefx-0.5" } });
    exe.root_module.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "/usr/include/pixman-1" } });

    // Link C libraries. scenefx-0.5 is wlroots 0.20's scene-graph fork
    // (rounded corners, blur, shadows); it must be linked BEFORE wlroots
    // so its wlr_scene_* implementations interpose over wlroots' (mango
    // links both the same way).
    exe.root_module.linkSystemLibrary("scenefx-0.5", .{});
    exe.root_module.linkSystemLibrary("wlroots-0.20", .{});
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("libinput", .{});
    exe.root_module.linkSystemLibrary("xcb", .{});
    // systemd.pc doesn't exist (distro ships libsystemd.pc), and the pkg-config
    // probe silently drops the lib if the name doesn't resolve.
    exe.root_module.linkSystemLibrary("libsystemd", .{});
    exe.root_module.addCMacro("_GNU_SOURCE", "1");
    exe.root_module.link_libc = true;


    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the compositor");
    run_step.dependOn(&run_cmd.step);
}
