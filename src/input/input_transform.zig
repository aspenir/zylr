const wl = @import("wayland").server.wl;
const wlroots = @import("wlroots");

pub const Point = struct { ox: f64, oy: f64 };

/// Map a normalized touch/tablet position (0..1 of the physical panel,
/// which is in the output's UNTRANFORMED coordinate space) into logical
/// scene coordinates by applying the inverse output transform.
///
/// wlroots input events report positions in the panel's native (physical)
/// orientation, while the scene works in the post-transform logical space,
/// so a rotated output swaps and/or mirrors the axes. effectiveResolution
/// handles the dimension swap + scale; it does NOT reorient the point.
pub fn toLogical(
    output: *wlroots.Output,
    x: f64,
    y: f64,
) Point {
    var ow: c_int = 0;
    var oh: c_int = 0;
    output.effectiveResolution(&ow, &oh);

    // Same convention as wlr_cursor's apply_output_transform: these map the
    // normalized physical point into the logical layout space.
    const lx: f64 = switch (output.transform) {
        .@"90" => 1 - y,
        .@"180" => 1 - x,
        .@"270" => y,
        else => x,
    };
    const ly: f64 = switch (output.transform) {
        .@"90" => x,
        .@"180" => 1 - y,
        .@"270" => 1 - x,
        else => y,
    };

    return .{
        .ox = lx * @as(f64, @floatFromInt(ow)),
        .oy = ly * @as(f64, @floatFromInt(oh)),
    };
}
