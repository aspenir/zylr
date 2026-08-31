const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");

const ServerContext = @import("server.zig");

/// Per lock-surface state: the scene tree holding the surface plus a
/// destroy listener that removes it exactly when wlroots destroys the
/// surface. The pointer is stashed in lock_surface.data.
const LockSurface = struct {
    tree: *wlr.SceneTree,
    destroy_listener: wl.Listener(void),
};
pub const SessionLock = @This();

context: *ServerContext,
manager: *wlr.SessionLockManagerV1,
current_lock: ?*wlr.SessionLockV1 = null,
lock_tree: *wlr.SceneTree,

new_lock_listener: wl.Listener(*wlr.SessionLockV1) = undefined,
new_surface_listener: wl.Listener(*wlr.SessionLockSurfaceV1) = undefined,
unlock_listener: wl.Listener(void) = undefined,
lock_destroy_listener: wl.Listener(void) = undefined,

pub fn init(context: *ServerContext) !void {
    const self = try std.heap.c_allocator.create(SessionLock);
    self.* = .{
        .context = context,
        .manager = try wlr.SessionLockManagerV1.create(context.server),
        .lock_tree = try context.scene.tree.createSceneTree(),
    };

    self.new_lock_listener = wl.Listener(*wlr.SessionLockV1).init(onNewLock);
    self.manager.events.new_lock.add(&self.new_lock_listener);

    self.new_surface_listener = wl.Listener(*wlr.SessionLockSurfaceV1).init(onNewSurface);
    self.unlock_listener = wl.Listener(void).init(onUnlock);
    self.lock_destroy_listener = wl.Listener(void).init(onLockDestroy);

    context.session_lock = self;
}

pub fn deinit(self: *SessionLock) void {
    self.new_lock_listener.link.remove();
    if (self.current_lock) |_| {
        self.detachListeners();
    }
    if (self.current_lock) |lock| {
        self.current_lock = null;
        lock.destroy();
    } else if (self.lock_tree.children.first()) |_| {
        destroyLockSurfaces(self.lock_tree);
    }
    self.lock_tree.node.destroy();
    std.heap.c_allocator.destroy(self);
}

pub fn isLocked(self: *const SessionLock) bool {
    return self.current_lock != null;
}

fn destroyLockSurfaces(lock_tree: *wlr.SceneTree) void {
    while (lock_tree.children.first()) |node| {
        node.destroy();
    }
}

fn detachListeners(self: *SessionLock) void {
    self.new_surface_listener.link.remove();
    self.unlock_listener.link.remove();
    self.lock_destroy_listener.link.remove();
}

fn focusLockSurface(self: *SessionLock, surface: *wlr.Surface) void {
    const context = self.context;
    if (context.keyboards.items.len > 0) {
        const kb = context.keyboards.items[0].keyboard;
        context.seat.keyboardNotifyEnter(
            surface,
            kb.keycodes[0..kb.num_keycodes],
            &kb.modifiers,
        );
    }
    context.seat.pointerNotifyEnter(surface, 0, 0);
}

fn onNewLock(
    listener: *wl.Listener(*wlr.SessionLockV1),
    lock: *wlr.SessionLockV1,
) void {
    const self: *SessionLock = @fieldParentPtr("new_lock_listener", listener);
    const context = self.context;

    if (self.current_lock) |old| {
        self.detachListeners();
        old.destroy();
    }

    self.current_lock = lock;
    context.locked = true;

    context.seat.keyboardNotifyClearFocus();

    lock.events.new_surface.add(&self.new_surface_listener);
    lock.events.unlock.add(&self.unlock_listener);
    lock.events.destroy.add(&self.lock_destroy_listener);

    // Tell the client it's now the lock. Without this, the client's
    // unlock_and_destroy is an INVALID_UNLOCK error and the unlock never
    // completes.
    lock.sendLocked();
}

fn onNewSurface(
    listener: *wl.Listener(*wlr.SessionLockSurfaceV1),
    lock_surface: *wlr.SessionLockSurfaceV1,
) void {
    const self: *SessionLock = @fieldParentPtr("new_surface_listener", listener);

    const output = lock_surface.output;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    output.effectiveResolution(&out_w, &out_h);

    var layout_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    self.context.output_layout.getBox(output, &layout_box);

    const tree = self.lock_tree.createSceneTree() catch return;
    _ = tree.createSceneSubsurfaceTree(lock_surface.surface) catch {
        tree.node.destroy();
        return;
    };
    tree.node.setPosition(layout_box.x, layout_box.y);

    // Track the surface so its scene node is removed exactly when wlroots
    // destroys the surface - never manually, which would leave wlroots
    // touching a freed node (the unlock crash).
    const ls = std.heap.c_allocator.create(LockSurface) catch {
        tree.node.destroy();
        return;
    };
    ls.* = .{
        .tree = tree,
        .destroy_listener = wl.Listener(void).init(onLockSurfaceDestroy),
    };
    lock_surface.data = ls;
    lock_surface.events.destroy.add(&ls.destroy_listener);

    _ = lock_surface.configure(@intCast(out_w), @intCast(out_h));

    self.focusLockSurface(lock_surface.surface);
}

fn onLockSurfaceDestroy(listener: *wl.Listener(void)) void {
    const ls: *LockSurface = @fieldParentPtr("destroy_listener", listener);
    ls.destroy_listener.link.remove();
    ls.tree.node.destroy();
    std.heap.c_allocator.destroy(ls);
}

fn focusPrevious(self: *SessionLock) void {
    const context = self.context;
    if (context.focused_view) |view| {
        if (view.isMapped()) {
            if (context.keyboards.items.len > 0) {
                const keyboard = context.keyboards.items[0].keyboard;
                context.seat.keyboardNotifyEnter(
                    view.surface(),
                    keyboard.keycodes[0..keyboard.num_keycodes],
                    &keyboard.modifiers,
                );
            }
        }
    }
}

fn onUnlock(
    listener: *wl.Listener(void),
) void {
    const self: *SessionLock = @fieldParentPtr("unlock_listener", listener);
    const context = self.context;

    // Detach our per-lock listeners so wlroots' lock_destroy asserts pass
    // (it requires the new_surface/unlock/destroy listener lists to be empty
    // once it tears the lock down). Do NOT call lock.destroy() ourselves:
    // the client's unlock_and_destroy request makes wlroots destroy the lock
    // and every surface right after emitting this signal. Our per-surface
    // destroy listeners then remove their scene nodes, so nothing is freed
    // out from under wlroots.
    self.detachListeners();
    self.current_lock = null;
    context.locked = false;
    self.focusPrevious();
}

fn onLockDestroy(
    listener: *wl.Listener(void),
) void {
    const self: *SessionLock = @fieldParentPtr("lock_destroy_listener", listener);
    const context = self.context;

    // wlroots is destroying the lock (and with it every lock surface), which
    // has already fired each per-surface destroy listener, cleaning up their
    // scene nodes. Just clear our own state and hand focus back.
    self.current_lock = null;
    context.locked = false;
    self.focusPrevious();
}
