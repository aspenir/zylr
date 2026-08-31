const std = @import("std");
const ServerContext = @import("server.zig");
pub fn launchProgram(
    context: *ServerContext,
    environ_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) void {
    std.log.info("Launching {s}", .{argv[0]});
    const session_env = .{
        .{ "WAYLAND_DISPLAY", context.wayland_socket },
        .{ "DISPLAY", std.mem.span(context.xwayland.?.display_name) },
        .{ "XDG_SESSION_TYPE", "wayland" },
        .{ "XDG_CURRENT_DESKTOP", "zylr" },
        // Prefer the native Wayland backend over XWayland (CSD/shadow
        // mismatches are an X11-only problem; on Wayland zylr forces
        // server-side decorations).
        .{ "MOZ_ENABLE_WAYLAND", "1" },
        .{ "ELECTRON_OZONE_PLATFORM_HINT", "auto" },
    };
    inline for (session_env) |entry| {
        context.environ_map.put(entry[0], entry[1]) catch |err| {
            std.log.err("Failed to set {s}: {}", .{ entry[0], err });
            return;
        };
    }

    // Ground truth: what did the child actually inherit? Appends to
    // /tmp/zylr_xw.log so it survives the desktop-file launch.
    const env_line = std.fmt.allocPrint(
        std.heap.c_allocator,
        "LAUNCH {s} WAYLAND_DISPLAY={s} DISPLAY={s} MOZ_ENABLE_WAYLAND={s} XDG_SESSION_TYPE={s}\n",
        .{
            argv[0],
            context.environ_map.get("WAYLAND_DISPLAY") orelse "<unset>",
            context.environ_map.get("DISPLAY") orelse "<unset>",
            context.environ_map.get("MOZ_ENABLE_WAYLAND") orelse "<unset>",
            context.environ_map.get("XDG_SESSION_TYPE") orelse "<unset>",
        },
    ) catch return;
    defer std.heap.c_allocator.free(env_line);
    std.log.info("LAUNCH: {s}", .{env_line});
    const ef = std.c.fopen("/tmp/zylr_xw.log", "a") orelse return;
    _ = std.c.fwrite(env_line.ptr, 1, env_line.len, ef);
    _ = std.c.fclose(ef);
    const child = std.process.spawn(context.io, .{
        .argv = argv,
        .environ_map = environ_map,
    }) catch |err| {
        std.log.err("Failed to launch {s}: {}", .{ argv[0], err });
        return;
    };

    _ = child;
}
// TODO: remove
pub fn launchFuzzel(context: *ServerContext) void {
    launchProgram(context, context.environ_map, &.{"fuzzel"});
}

/// Vars that D-Bus/systemd activation consumers need to see.
pub const session_vars = [_][:0]const u8{
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_TYPE",
};

/// Publish `values` (parallel to session_vars; null = drop the var) into
/// the systemd user manager and the D-Bus activation environment. Apps
/// started through D-Bus/systemd never see our process env - without
/// this they inherit whichever login session set the vars last (e.g.
/// mango's socket when zylr runs nested).
pub fn updateActivationEnv(
    context: *ServerContext,
    values: anytype,
) void {
    var import_argv: [2 + session_vars.len][]const u8 = undefined;
    import_argv[0] = "dbus-update-activation-environment";
    import_argv[1] = "--systemd";
    var n_imports: usize = 2;

    // dbus-update only imports vars PRESENT in the child env; vars that
    // were unset before zylr must be dropped explicitly afterwards.
    var unset_argv: [3 + session_vars.len][]const u8 = undefined;
    unset_argv[0] = "systemctl";
    unset_argv[1] = "--user";
    unset_argv[2] = "unset-environment";
    var n_unsets: usize = 3;

    inline for (session_vars, 0..) |name, i| {
        if (@as(?[]const u8, values[i])) |v| {
            context.environ_map.put(name, v) catch return;
            import_argv[n_imports] = name;
            n_imports += 1;
        } else {
            _ = context.environ_map.orderedRemove(name);
            unset_argv[n_unsets] = name;
            n_unsets += 1;
        }
    }

    if (n_imports > 2) {
        // --systemd covers both the bus activation env and the systemd
        // manager in one go.
        launchProgram(context, context.environ_map, import_argv[0..n_imports]);
    }
    if (n_unsets > 3) {
        launchProgram(context, context.environ_map, unset_argv[0..n_unsets]);
    }
}
