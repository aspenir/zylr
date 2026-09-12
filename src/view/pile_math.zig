const std = @import("std");

/// Pure pile partition math: share fractions -> (top fraction, height
/// fraction) for the member at `idx`. Kept free of wlroots/server imports so
/// the geometry is runnable by `zig test src/view/pile_math.zig`.
pub const PileOffsets = struct { top_frac: f32, share_frac: f32 };

pub fn pileMemberOffsets(shares: []const f32, idx: usize) PileOffsets {
    var before: f32 = 0;
    if (idx < shares.len) {
        for (shares[0..idx]) |s| before += s;
    }
    const sh = if (idx < shares.len) shares[idx] else 0;
    return .{ .top_frac = before, .share_frac = sh };
}

test "pileMemberOffsets partitions shares" {
    const shares = [_]f32{ 0.5, 0.3, 0.2 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), pileMemberOffsets(&shares, 0).top_frac, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pileMemberOffsets(&shares, 0).share_frac, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pileMemberOffsets(&shares, 1).top_frac, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), pileMemberOffsets(&shares, 2).top_frac, 1e-6);
    // Equal shares fill the column without overlap.
    const eq = [_]f32{ 0.5, 0.5 };
    const a = pileMemberOffsets(&eq, 0);
    const b = pileMemberOffsets(&eq, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), a.share_frac, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), b.top_frac, 1e-6);
}
