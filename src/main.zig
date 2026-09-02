const wlroots = @import("wlroots");
const std = @import("std");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.server.wl;

const View = @import("view/view.zig");
const XdgView = @import("view/xdg.zig");
const XwaylandView = @import("view/xwayland.zig");
const LayerView = @import("view/layer.zig");

const KeyboardContext = @import("input/keyboard.zig");
const ServerContext = @import("server.zig");
const NodeData = @import("view/utils/node_data.zig");
const AnimationManager = @import("view/animation.zig");
const XCursor = @import("view/xcursor.zig");
const Cursor = @import("input/cursor.zig");
const Output = @import("output/output.zig");
const InputManager = @import("input/input_manager.zig");
const InputRelay = @import("input/input_relay.zig");
const Spawner = @import("spawner.zig");
const Config = @import("config.zig");
const PointerConstraints = @import("input/pointer_constraints.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// scenefx's gles2 fork; renders the scene graph's rounded corners.
extern fn fx_renderer_create(backend: *wlroots.Backend) ?*wlroots.Renderer;
extern fn fx_renderer_create_with_drm_fd(drm_fd: c_int) ?*wlroots.Renderer;
extern fn wlr_gbm_allocator_create(drm_fd: c_int) ?*wlroots.Allocator;

const build_options = @import("build_options");

const log_level: std.log.Level = switch (build_options.log_level) {
    .err => .err,
    .warn => .warn,
    .info => .info,
    .debug => .debug,
};

var zylr_log_ready = false;
var zylr_log_fd: std.c.fd_t = -1;

/// Route log output to the file named by $ZYLR_LOG, or ~/.zylr.log by
/// default (compositors started by a display manager have no visible
/// stdout). Falls back to stderr when neither is usable.
fn zylrOpenLog() void {
    var path_buf: [4096]u8 = undefined;
    const value: [:0]const u8 = if (std.c.getenv("ZYLR_LOG")) |v|
        std.mem.span(v)
    else if (std.c.getenv("HOME")) |home|
        std.fmt.bufPrintZ(&path_buf, "{s}/.zylr.log", .{std.mem.span(home)}) catch return
    else
        return;
    const fd = std.c.open(value, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    zylr_log_fd = fd;
}

fn zylrLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!zylr_log_ready) {
        zylr_log_ready = true;
        zylrOpenLog();
    }
    if (zylr_log_fd < 0) {
        std.log.defaultLog(message_level, scope, format, args);
        return;
    }
    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[{s}] {s}: ", .{
        @tagName(message_level),
        @tagName(scope),
    }) catch return;
    const rest = std.fmt.bufPrint(buf[prefix.len..], format, args) catch buf[prefix.len..][0..0];
    buf[prefix.len + rest.len] = '\n';
    _ = std.c.write(zylr_log_fd, buf[0 .. prefix.len + rest.len + 1].ptr, prefix.len + rest.len + 1);
    _ = std.c.fsync(zylr_log_fd);
}
pub const std_options: std.Options = .{
    .log_level = log_level,
    .enable_segfault_handler = true,
    .logFn = zylrLogFn,
};

pub const panic = std.debug.FullPanic(zylrPanic);

fn zylrPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.log.err("PANIC: {s}", .{msg});
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    const version = build_options.version;
    const args: []const [*:0]const u8 = init.minimal.args.vector;
    for (args[1..]) |arg| {
        const s = std.mem.span(arg);
        if (std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-v")) {
            std.debug.print("zylr {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h")) {
            std.debug.print("zylr {s}\n\nUsage: zylr [options]\n\n  -h, --help      show this help\n  -v, --version   print version\n", .{version});
            return;
        }
    }

    const server = wl.Server.create() catch |err| {
        std.log.err("failed to create Wayland server: {}", .{err});
        return err;
    };
    const loop = server.getEventLoop();

    _ = try wl.EventLoop.addSignal(loop, *wl.Server, 2, onSignal, server);
    _ = try wl.EventLoop.addSignal(loop, *wl.Server, 15, onSignal, server);

    if (std.c.getenv("WAYLAND_DISPLAY") != null) {
        std.log.info("nested Wayland detected (WAYLAND_DISPLAY set), forcing WLR_BACKENDS=wayland", .{});
        _ = setenv("WLR_BACKENDS", "wayland", 1);
    }
    if (std.c.getenv("WLR_BACKENDS")) |v| {
        std.log.info("WLR_BACKENDS={s}", .{std.mem.span(v)});
    } else {
        std.log.info("WLR_BACKENDS not set", .{});
    }
    if (std.c.getenv("WAYLAND_DISPLAY")) |v| {
        std.log.info("WAYLAND_DISPLAY={s}", .{std.mem.span(v)});
    } else {
        std.log.info("WAYLAND_DISPLAY not set", .{});
    }
    var session: ?*wlroots.Session = null;
    const backend = wlroots.Backend.autocreate(loop, &session) catch |err| {
        std.log.err("backend autocreate failed (try WLR_BACKENDS=wayland for nested): {}", .{err});
        return err;
    };
    // scenefx's renderer: a gles2 fork that draws the scene graph's
    // rounded corners (wlr_scene_rect_set_corner_radii etc.).
    // The fx renderer is DMABUF-only, so backends without a DRM fd
    // (X11, for headless dev runs) get a render node for EGL plus the
    // matching GBM allocator.
    var drm_fd = wlroots.Backend.getDrmFd(backend);
    var renderer = if (drm_fd >= 0) fx_renderer_create(backend) else null;
    var allocator: ?*wlroots.Allocator = if (drm_fd >= 0) try wlroots.Allocator.autocreate(backend, renderer.?) else null;
    if (renderer == null) {
        drm_fd = std.posix.openatZ(std.posix.AT.FDCWD, "/dev/dri/renderD128", .{ .ACCMODE = .RDWR }, 0) catch -1;
        renderer = if (drm_fd >= 0) fx_renderer_create_with_drm_fd(drm_fd) else null;
        allocator = if (drm_fd >= 0) wlr_gbm_allocator_create(drm_fd) else null;
    }
    const r_renderer = renderer orelse return error.RendererCreateFailed;
    const r_allocator = allocator orelse return error.AllocatorCreateFailed;

    try r_renderer.initServer(server);

    _ = try wlroots.Shm.createWithRenderer(server, 1, r_renderer);
    const compositor = try wlroots.Compositor.create(server, 6, r_renderer);
    _ = try wlroots.Subcompositor.create(server);
    _ = try wlroots.DataDeviceManager.create(server);
    _ = try wlroots.PrimarySelectionDeviceManagerV1.create(server);

    const xdg_shell = try wlroots.XdgShell.create(server, 6);

    const layer_shell = try wlroots.LayerShellV1.create(server, 5);

    // Required by HiDPI clients (Firefox, Zen) to render at fractional
    // scales and viewport-scale their buffers instead of overflowing.
    _ = try wlroots.Viewporter.create(server);
    _ = try wlroots.FractionalScaleManagerV1.create(server, 1);

    // xdg-decoration-v1: serve server-side decorations so GTK/Qt don't
    // draw client-side titlebars on top of zylr's own tiling borders.
    const xdg_decoration_manager =
        try wlroots.XdgDecorationManagerV1.create(server);

    const scene = try wlroots.Scene.create();

    // gamma-control-v1 (wlsunset/night light). The scene applies the
    // LUT itself when a client sets one; we just own the global.
    const gamma_control_manager =
        try wlroots.GammaControlManagerV1.create(server);
    scene.setGammaControlManagerV1(gamma_control_manager);

    const output_layout = try wlroots.OutputLayout.create(server);

    _ = try scene.attachOutputLayout(output_layout);

    const output_manager = try wlroots.OutputManagerV1.create(server);

    const tablet_manager = try wlroots.TabletManagerV2.create(server);

    const pointer_gestures = try wlroots.PointerGesturesV1.create(server);

    const screencopy_manager = try wlroots.ScreencopyManagerV1.create(server);

    const toplevel_manager = try wlroots.ForeignToplevelManagerV1.create(server);

    // eager (lazy=false): spawn Xwayland at startup. Lazy mode only
    // starts Xwayland when the first X11 client connects, which failed
    // to spawn in headless runs and adds first-window latency on DRM.
    const xwayland = try wlroots.Xwayland.create(server, compositor, true);

    _ = try wlroots.XdgOutputManagerV1.create(server, output_layout);

    // ext-* protocols for the modern xdg-desktop-portal-wlr:
    // foreign toplevel list, image copy capture, and image capture
    // sources for outputs and toplevels.
    _ = try wlroots.ExtForeignToplevelListV1.create(server, 1);
    _ = try wlroots.ExtImageCopyCaptureManagerV1.create(server, 1);
    _ = try wlroots.ExtOutputImageCaptureSourceManagerV1.create(server, 1);
    _ = try wlroots.ExtForeignToplevelImageCaptureSourceManagerV1.create(server, 1);

    const cursor = try wlroots.Cursor.create();
    cursor.attachOutputLayout(output_layout);

    var xcursor_manager = XCursor.create(null, 24) orelse return error.XCursorManagerCreateFailed;

    const seat = try wlroots.Seat.create(server, "seat0");

    const xkb_context =
        xkb.Context.new(.no_flags) orelse
        return error.XkbContextCreateFailed;

    var socket_name_buf: [11]u8 = undefined;

    const socket_name =
        try server.addSocketAuto(&socket_name_buf);

    std.log.info(
        "Compositor running on WAYLAND_DISPLAY={s}",
        .{socket_name},
    );

    // Remember the parent session's values: when zylr exits (typically
    // nested inside mango) the activation environments must be restored,
    // or D-Bus/systemd-launched apps keep aiming at zylr's dead socket.
    var saved_vars: [Spawner.session_vars.len]?[:0]const u8 = @splat(null);
    for (Spawner.session_vars, 0..) |name, i| {
        if (std.c.getenv(name)) |v| {
            saved_vars[i] = std.heap.c_allocator.dupeZ(u8, std.mem.span(v)) catch null;
        }
    }

    _ = setenv("WAYLAND_DISPLAY", socket_name.ptr, 1);
    _ = setenv("DISPLAY", xwayland.display_name, 1);
    std.log.info("XWayland DISPLAY={s}", .{xwayland.display_name});
    _ = setenv("XDG_SESSION_TYPE", "wayland", 1);
    _ = setenv("XDG_CURRENT_DESKTOP", "zylr", 1);
    // Every child of this session (terminals, autostart scripts, window
    // managers, launchers) inherits this process env. Prefer native
    // Wayland backends so X11 apps don't fall into XWayland's CSD.
    _ = setenv("MOZ_ENABLE_WAYLAND", "1", 1);
    _ = setenv("ELECTRON_OZONE_PLATFORM_HINT", "auto", 1);

    var context = ServerContext{
        .scene = scene,
        .output_layout = output_layout,
        .backend = backend,
        .allocator = r_allocator,
        .renderer = r_renderer,
        .xdg_shell = xdg_shell,
        .layer_shell = layer_shell,
        .seat = seat,
        .xkb_context = xkb_context,
        .cursor = cursor,
        .xcursor_manager = &xcursor_manager,
        .io = init.io,
        .environ_map = init.environ_map,
        .session = session,
        .server = server,
        .tablet_manager = tablet_manager,
        .pointer_gestures = pointer_gestures,
        .screencopy_manager = screencopy_manager,
        .toplevel_manager = toplevel_manager,
        .xwayland = xwayland,
        .wayland_socket = socket_name,
    };

    // Layer trees in fixed render order: background (wallpaper) < bottom
    // < views < top (bars) < overlay (launchers). Windows are raised
    // only within the views tree, so bars and wallpapers keep their
    // protocol-defined stacking regardless of launch order.
    context.background_tree = try scene.tree.createSceneTree();
    context.bottom_tree = try scene.tree.createSceneTree();
    context.views_tree = try scene.tree.createSceneTree();
    context.top_tree = try scene.tree.createSceneTree();
    context.overlay_tree = try scene.tree.createSceneTree();
    context.fullscreen_tree = try scene.tree.createSceneTree();

    // Input-method relay (zwp_input_method_v2 / zwp_text_input_v3): feeds
    // on-screen keyboards like squeekboard. Must be wired before clients
    // connect so the globals exist; relay_ptr is module-global.
    _ = try InputRelay.init(server, seat, &context);

    // Pointer constraints (zwp_pointer_constraints_v1): lets games confine
    // or lock the cursor. Enforced in cursor.zig's motion paths.
    _ = try PointerConstraints.init(server, seat, &context);

    context.animation_timer = try wl.EventLoop.addTimer(
        loop,
        *ServerContext,
        AnimationManager.onTimerTick,
        &context,
    );

    context.request_set_selection_listener = wl.Listener(
        *wlroots.Seat.event.RequestSetSelection,
    ).init(ServerContext.onRequestSetSelection);
    seat.events.request_set_selection.add(&context.request_set_selection_listener);
    context.request_set_primary_selection_listener = wl.Listener(
        *wlroots.Seat.event.RequestSetPrimarySelection,
    ).init(ServerContext.onRequestSetPrimarySelection);
    seat.events.request_set_primary_selection.add(
        &context.request_set_primary_selection_listener,
    );

    context.new_output_listener = wl.Listener(*wlroots.Output).init(Output.onNewOutput);
    backend.events.new_output.add(&context.new_output_listener);

    context.new_xdg_toplevel_listener =
        wl.Listener(*wlroots.XdgToplevel).init(XdgView.onNewXdgTopLevel);

    context.xdg_shell.events.new_toplevel.add(
        &context.new_xdg_toplevel_listener,
    );

    context.xdg_decoration_manager = xdg_decoration_manager;
    context.new_decoration_listener =
        wl.Listener(*wlroots.XdgToplevelDecorationV1).init(XdgView.onNewXdgDecoration);
    xdg_decoration_manager.events.new_toplevel_decoration.add(
        &context.new_decoration_listener,
    );

    xwayland.setSeat(seat);
    context.new_xwayland_surface_listener =
        wl.Listener(*wlroots.XwaylandSurface).init(XwaylandView.onNewXwaylandSurface);
    xwayland.events.new_surface.add(
        &context.new_xwayland_surface_listener,
    );

    context.new_input_listener =
        wl.Listener(*wlroots.InputDevice).init(InputManager.onNewInput);

    backend.events.new_input.add(&context.new_input_listener);

    // Virtual keyboard clients inject keystrokes through
    // zwp_virtual_keyboard_manager_v1.
    const virtual_keyboards = try wlroots.VirtualKeyboardManagerV1.create(server);
    context.new_virtual_keyboard_listener =
        wl.Listener(*wlroots.VirtualKeyboardV1).init(InputManager.onNewVirtualKeyboard);
    virtual_keyboards.events.new_virtual_keyboard.add(
        &context.new_virtual_keyboard_listener,
    );

    // wlr-virtual-pointer-unstable-v1.
    const virtual_pointers = try wlroots.VirtualPointerManagerV1.create(server);
    context.new_virtual_pointer_listener =
        wl.Listener(*wlroots.VirtualPointerManagerV1.event.NewPointer).init(InputManager.onNewVirtualPointer);
    virtual_pointers.events.new_virtual_pointer.add(
        &context.new_virtual_pointer_listener,
    );

    context.output_manager = output_manager;
    context.manager_apply_listener =
        wl.Listener(*wlroots.OutputConfigurationV1).init(Output.onManagerApply);
    context.manager_test_listener =
        wl.Listener(*wlroots.OutputConfigurationV1).init(Output.onManagerTest);
    output_manager.events.apply.add(&context.manager_apply_listener);
    output_manager.events.@"test".add(&context.manager_test_listener);

    context.cursor_motion_listener =
        wl.Listener(*wlroots.Pointer.event.Motion).init(Cursor.onCursorMotion);

    context.cursor_motion_absolute_listener =
        wl.Listener(*wlroots.Pointer.event.MotionAbsolute).init(Cursor.onCursorMotionAbsolute);

    context.cursor_button_listener =
        wl.Listener(*wlroots.Pointer.event.Button).init(Cursor.onCursorButton);

    context.cursor_axis_listener =
        wl.Listener(*wlroots.Pointer.event.Axis).init(Cursor.onCursorAxis);

    context.cursor_frame_listener =
        wl.Listener(*wlroots.Cursor).init(Cursor.onCursorFrame);

    cursor.events.motion.add(&context.cursor_motion_listener);
    cursor.events.motion_absolute.add(&context.cursor_motion_absolute_listener);
    cursor.events.button.add(&context.cursor_button_listener);
    cursor.events.axis.add(&context.cursor_axis_listener);
    cursor.events.frame.add(&context.cursor_frame_listener);

    context.new_layer_surface_listener =
        wl.Listener(*wlroots.LayerSurfaceV1).init(LayerView.onNewLayerSurface);

    context.layer_shell.events.new_surface.add(
        &context.new_layer_surface_listener,
    );

    // Config: ~/.config/zylr/config.ziggy, defaults when missing/malformed.
    // Deliberately leaked: the bind table and XKB names are read on every
    // keypress/attach for the life of the session.
    const loaded_config = Config.load(init.io, std.heap.c_allocator, true);
    context.applyConfig(loaded_config);
    @import("view/blur.zig").applyConfig(&context);

    _ = @import("session_lock.zig").SessionLock.init(&context) catch |err| {
        std.log.err("session lock init failed: {}", .{err});
    };

    _ = @import("idle.zig").Idle.init(&context, loop) catch |err| {
        std.log.err("idle init failed: {}", .{err});
    };

    @import("suspend.zig").SuspendContext.init(&context);

    try backend.start();

    std.log.info("Backend started; entering Wayland event loop", .{});

    // Publish session vars to the D-Bus/systemd activation environments:
    // apps launched through them never see our process env, so without
    // this they inherit whatever login session set the vars last.
    Spawner.updateActivationEnv(&context, .{
        socket_name,
        std.mem.span(xwayland.display_name),
        "zylr",
        "wayland",
    });

    // Launch the user's autostart commands from config.
    for (loaded_config.cfg.autostart) |cmd| {
        Spawner.launchProgram(&context, context.environ_map, &.{cmd});
    }

    // launchFuzzel(context.io);

    server.run();

    context.new_output_listener.link.remove();
    context.manager_apply_listener.link.remove();
    context.manager_test_listener.link.remove();
    context.new_xdg_toplevel_listener.link.remove();
    context.new_decoration_listener.link.remove();
    context.new_layer_surface_listener.link.remove();
    context.new_xwayland_surface_listener.link.remove();
    context.new_input_listener.link.remove();
    context.cursor_motion_listener.link.remove();
    context.cursor_motion_absolute_listener.link.remove();
    context.cursor_button_listener.link.remove();
    context.cursor_axis_listener.link.remove();
    context.cursor_frame_listener.link.remove();

    // Detach every remaining wlroots signal listener BEFORE the display
    // is destroyed: wlr_xdg_shell / wlr_output_finish assert on leftover
    // listeners (new_toplevel, output frame). The display destroy then
    // fires surface-destroy handlers (removeView) which still touch
    // context.views/animation_x, so it must run before those lists are
    // freed. With `defer server.destroy()` the display was destroyed
    // last, after animation_x.deinit(), so removeView read freed memory
    // -> GP fault -> compositor died on window close / session exit.
    for (context.output_contexts.items) |output_ctx| {
        if (!output_ctx.destroyed) {
            output_ctx.frame_listener.link.remove();
            output_ctx.destroy_listener.link.remove();
        }
    }
    for (context.keyboards.items) |keyboard_context| {
        keyboard_context.key_listener.link.remove();
        keyboard_context.modifiers_listener.link.remove();
    }
    // Detach gesture listeners that survived to shutdown: wlroots asserts
    // the pointer signal lists are empty at finish time, and the device
    // destroy signal may not fire for every pointer before the display is
    // torn down.
    for (context.gesture_contexts.items) |gc| {
        if (!gc.freed) gc.deinit();
    }
    context.gesture_contexts.clearRetainingCapacity();
    // wlroots asserts on manager destruction with this listener attached.
    context.new_virtual_keyboard_listener.link.remove();
    context.new_virtual_pointer_listener.link.remove();
    // wlroots asserts on seat destroy with this listener attached.
    context.request_set_selection_listener.link.remove();
    context.request_set_primary_selection_listener.link.remove();

    // Hand the activation environments back to the parent session
    // before zylr's socket disappears.
    Spawner.updateActivationEnv(&context, saved_vars);

    server.destroy();

    for (context.output_contexts.items) |output_ctx| {
        std.heap.c_allocator.destroy(output_ctx);
    }
    context.output_contexts.clearRetainingCapacity();
    context.output_contexts.deinit(std.heap.c_allocator);
    if (context.animation_timer) |timer| {
        timer.remove();
    }
    context.animation_x.deinit(std.heap.c_allocator);
    context.animation_w.deinit(std.heap.c_allocator);
    context.views.deinit(std.heap.c_allocator);
    context.focus_history.deinit(std.heap.c_allocator);
    context.layers.deinit(std.heap.c_allocator);
    for (context.keyboards.items) |keyboard_context| {
        std.heap.c_allocator.destroy(keyboard_context);
    }
    context.keyboards.clearRetainingCapacity();
    context.keyboards.deinit(std.heap.c_allocator);
    context.gesture_contexts.deinit(std.heap.c_allocator);
}

fn onSignal(signal: c_int, display: *wl.Server) c_int {
    _ = signal;
    display.terminate();
    return 0;
}

test {
    _ = @import("input/gesture.zig");
    _ = Config;
}
