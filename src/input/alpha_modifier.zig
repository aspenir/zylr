const wlr = @import("wlroots");

const ServerContext = @import("../server.zig");

/// wp_alpha_modifier_v1 global: lets clients negotiate the per-surface
/// opacity protocol instead of round-tripping a framebuffer to fake a fade.
/// The blend itself is a no-op for now — the multipler stays 1.0 because
/// applying it needs the surface's scene buffer, which zylr's view draw
/// path doesn't keep per view.
/// # ponytail: create-only global, real fading once views track scene buffers.
pub fn init(context: *ServerContext) !void {
    _ = try wlr.AlphaModifierV1.create(context.server);
}
