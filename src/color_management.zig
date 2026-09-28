const wayland = @import("wayland");
const wl = wayland.server.wl;
const wp = wayland.server.wp;
const wlr = @import("wlroots");

const ServerContext = @import("server.zig");

/// wlroots keeps the option pointers, so these must outlive the call.
const render_intents = [_]wp.ColorManagerV1.RenderIntent{
    .perceptual,
    .relative,
    .saturation,
    .absolute,
};

/// scenefx's renderer reports no named color spaces (the gles2 fork leaves
/// the query empty), and empty lists make clients drop their own image
/// descriptions - Chromium then logs "Unable to set image primaries" and
/// renders untagged sRGB, so no transform ever runs. Declare what we can
/// accept and convert: wide-gamut primaries compressed to the output's
/// sRGB, SDR transfer functions only (the panel is SDR; PQ/HLG arrive with
/// an HDR output).
/// # ponytail: fixed lists, derive from output caps when scenefx reports them.
const primaries = [_]wp.ColorManagerV1.Primaries{
    .srgb,
    .display_p3,
    .dci_p3,
    .bt2020,
};

/// NOT `.srgb`: wlroots aborts the whole compositor on
/// `options->transfer_functions[i] != ..._TRANSFER_FUNCTION_SRGB`
/// (wlr_color_management_v1.c:968). `ext_srgb` is the protocol's sRGB
/// entry point; `parametric` covers plain TF power.
const transfer_functions = [_]wp.ColorManagerV1.TransferFunction{
    .ext_srgb,
    .gamma22,
};

/// color-management-v1 + color-representation-v1: lets CLM-aware clients
/// negotiate image descriptions (primaries / transfer function /
/// luminance) and bind surfaces to one. scenefx's scene color manager runs
/// the transforms; the representation manager maps descriptions onto what
/// this renderer can actually output. Both globals live for the whole
/// session, so nothing needs to own or free them.
/// The wlroots call, separate from init so the protocol smoke test can run
/// the exact options zylr ships instead of a copy that can drift.
pub fn createOn(server: *wl.Server) !*wlr.ColorManagerV1 {
    // v2 is the ceiling this wlroots allows (COLOR_MANAGEMENT_V1_VERSION);
    // `parametric` is the only feature flag it accepts at that version.
    // Hardware-gamut ICC and the v3+ set_* fields assert out, and the
    // transfer function list may not name `srgb`.
    const features = wlr.ColorManagerV1.Features{ .parametric = true };
    return wlr.ColorManagerV1.create(server, 2, .{
        .features = features,
        .render_intents = &render_intents,
        .transfer_functions = &transfer_functions,
        .primaries = &primaries,
    });
}

pub fn init(context: *ServerContext) !void {
    const manager = try createOn(context.server);
    context.scene.setColorManagerV1(manager);
    _ = try wlr.ColorRepresentationManagerV1.createWithRenderer(context.server, 1, context.renderer);
}
