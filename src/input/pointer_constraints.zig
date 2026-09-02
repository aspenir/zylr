const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlroots = @import("wlroots");
const std = @import("std");

const ServerContext = @import("../server.zig");
const nd = @import("../view/utils/node_data.zig");

/// Pointer constraints (zwp_pointer_constraints_v1). The 0.20 wlroots
/// module only registers the global and reports new_constraint; the
/// compositor must drive activation and enforce the constraint itself.
const PointerConstraints = @This();

manager: *wlroots.PointerConstraintsV1,
relative_manager: ?*wlroots.RelativePointerManagerV1 = null,
seat: *wlroots.Seat,
context: *ServerContext,
active: ?Active = null,
cursor_hidden: bool = false,
new_constraint_listener: wl.Listener(*wlroots.PointerConstraintV1) = undefined,

/// `origin` is the constrained surface's scene position in layout coords,
/// lifting the surface-local `region` into layout space for clamping.
const Active = struct {
    constraint: *wlroots.PointerConstraintV1,
    origin_x: f64,
    origin_y: f64,
};

/// Per-constraint destroy listener (wlroots signals are not shareable).
const Handle = struct {
    module: *PointerConstraints,
    destroy_listener: wl.Listener(*wlroots.PointerConstraintV1) = undefined,
};

var self: ?*PointerConstraints = null;

pub fn init(server: *wl.Server, seat: *wlroots.Seat, context: *ServerContext) !*PointerConstraints {
    const s = try std.heap.c_allocator.create(PointerConstraints);
    s.* = .{
        .manager = try wlroots.PointerConstraintsV1.create(server),
        .seat = seat,
        .context = context,
        .relative_manager = wlroots.RelativePointerManagerV1.create(server) catch null,
    };
    s.new_constraint_listener = wl.Listener(*wlroots.PointerConstraintV1).init(onNewConstraint);
    s.manager.events.new_constraint.add(&s.new_constraint_listener);
    self = s;
    return s;
}

fn onNewConstraint(listener: *wl.Listener(*wlroots.PointerConstraintV1), constraint: *wlroots.PointerConstraintV1) void {
    const module: *PointerConstraints = @fieldParentPtr("new_constraint_listener", listener);
    const handle = std.heap.c_allocator.create(Handle) catch return;
    handle.module = module;
    handle.destroy_listener = wl.Listener(*wlroots.PointerConstraintV1).init(onConstraintDestroy);
    constraint.events.destroy.add(&handle.destroy_listener);
}

fn onConstraintDestroy(listener: *wl.Listener(*wlroots.PointerConstraintV1), constraint: *wlroots.PointerConstraintV1) void {
    const handle: *Handle = @fieldParentPtr("destroy_listener", listener);
    const module = handle.module;
    if (module.active) |active| {
        if (active.constraint == constraint) {
            module.active = null;
            if (module.cursor_hidden) {
                module.cursor_hidden = false;
                module.context.xcursor_manager.setXcursor(module.context.cursor, "default");
            }
        }
    }
    // Detach before freeing. wlroots emits constraint.events.destroy while
    // it is still rearranging that signal's list; leaving our (about-to-be
    // freed) listener link in it lets the freed Handle's memory corrupt the
    // list / neighboring heap (seen as a wlr_pointer_finish hold_end assert).
    handle.destroy_listener.link.remove();
    std.heap.c_allocator.destroy(handle);
}

/// Re-evaluate the active constraint as the pointer moves. `node` is the
/// scene node under the pointer (null over nothing). Only a pointer over
/// the constrained surface itself activates it; subsurface hits fall
/// through to the parent walk, so constraints on a toplevel stay live
/// only while the toplevel itself receives the hit.
pub fn onPointerFocus(context: *ServerContext, node: ?*wlroots.SceneNode) void {
    const module = self orelse return;
    // Reorder/resize grabs take precedence; the constraint resumes on the
    // next focus pass once the pointer is back over its surface.
    if (context.drag_active or context.resize_active) {
        module.deactivate();
        return;
    }
    var cur = node;
    while (cur) |n| {
        if (n.type == .buffer) {
            if (nd.hitSurface(n)) |surface| {
                if (module.manager.constraintForSurface(surface, module.seat)) |constraint| {
                    var lx: c_int = 0;
                    var ly: c_int = 0;
                    _ = n.coords(&lx, &ly);
                    module.consider(
                        constraint,
                        @as(f64, @floatFromInt(lx)),
                        @as(f64, @floatFromInt(ly)),
                    );
                    return;
                }
            }
        }
        cur = if (n.parent) |parent| &parent.node else null;
    }
    module.deactivate();
}

fn consider(module: *PointerConstraints, constraint: *wlroots.PointerConstraintV1, origin_x: f64, origin_y: f64) void {
    if (module.active) |active| {
        if (active.constraint == constraint) {
            // Still over the constrained surface; windows can move under us.
            module.active = .{ .constraint = constraint, .origin_x = origin_x, .origin_y = origin_y };
            return;
        }
        module.deactivate();
    }
    const r = &constraint.region;
    const local_x = module.context.cursor.x - origin_x;
    const local_y = module.context.cursor.y - origin_y;
    const x1: f64 = @floatFromInt(r.extents.x1);
    const x2: f64 = @floatFromInt(r.extents.x2);
    const y1: f64 = @floatFromInt(r.extents.y1);
    const y2: f64 = @floatFromInt(r.extents.y2);
    if (local_x < x1 or local_x >= x2 or local_y < y1 or local_y >= y2)
        // Over the surface but outside the region: stay inactive until the
        // pointer re-enters.
        return;
    module.active = .{ .constraint = constraint, .origin_x = origin_x, .origin_y = origin_y };
    constraint.sendActivated();
    if (constraint.type == .locked) {
        module.context.cursor.unsetImage();
        module.cursor_hidden = true;
    }
}

fn deactivate(module: *PointerConstraints) void {
    const active = module.active orelse return;
    module.active = null;
    active.constraint.sendDeactivated();
    if (module.cursor_hidden) {
        module.cursor_hidden = false;
        module.context.xcursor_manager.setXcursor(module.context.cursor, "default");
    }
}

pub const RelativeOutcome = union(enum) {
    move: struct { dx: f64, dy: f64 },
    /// Locked: the cursor must not move; feed the delta to relative-pointer
    /// clients instead.
    locked,
};

/// Delta to hand to wlr_cursor_move for a relative motion, or `.locked`
/// when a locked pointer is active. Confinement clamps the layout-space
/// target into the region bbox and expresses it back as a delta.
pub fn relativeMotion(context: *ServerContext, dx: f64, dy: f64) RelativeOutcome {
    const module = self orelse return .{ .move = .{ .dx = dx, .dy = dy } };
    const active = module.active orelse return .{ .move = .{ .dx = dx, .dy = dy } };
    if (context.drag_active or context.resize_active) return .{ .move = .{ .dx = dx, .dy = dy } };
    switch (active.constraint.type) {
        .locked => return .locked,
        .confined => {
            const r = &active.constraint.region;
            const x1 = active.origin_x + @as(f64, @floatFromInt(r.extents.x1));
            const x2 = active.origin_x + @as(f64, @floatFromInt(r.extents.x2)) - 1;
            const y1 = active.origin_y + @as(f64, @floatFromInt(r.extents.y1));
            const y2 = active.origin_y + @as(f64, @floatFromInt(r.extents.y2)) - 1;
            const tx = std.math.clamp(context.cursor.x + dx, x1, x2);
            const ty = std.math.clamp(context.cursor.y + dy, y1, y2);
            return .{ .move = .{ .dx = tx - context.cursor.x, .dy = ty - context.cursor.y } };
        },
    }
}

/// Whether an absolute motion may move the cursor, and the clamped target.
/// Returns false for an active lock so the pointer stays put.
pub fn absoluteMotion(context: *ServerContext, x: *f64, y: *f64) bool {
    const module = self orelse return true;
    const active = module.active orelse return true;
    if (context.drag_active or context.resize_active) return true;
    switch (active.constraint.type) {
        .locked => return false,
        .confined => {
            const r = &active.constraint.region;
            x.* = std.math.clamp(
                x.*,
                active.origin_x + @as(f64, @floatFromInt(r.extents.x1)),
                active.origin_x + @as(f64, @floatFromInt(r.extents.x2)) - 1,
            );
            y.* = std.math.clamp(
                y.*,
                active.origin_y + @as(f64, @floatFromInt(r.extents.y1)),
                active.origin_y + @as(f64, @floatFromInt(r.extents.y2)) - 1,
            );
            return true;
        },
    }
}

/// Forward a locked-pointer motion to relative-pointer clients. The cursor
/// itself must not move.
pub fn sendLockedMotion(_: *ServerContext, time_msec: u32, dx: f64, dy: f64) void {
    const module = self orelse return;
    if (module.relative_manager) |rm| {
        rm.sendRelativeMotion(
            module.seat,
            @as(u64, time_msec) * 1000,
            dx,
            dy,
            dx,
            dy,
        );
    }
}
