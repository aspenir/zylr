const std = @import("std");
const wlroots = @import("wlroots");

const ServerContext = @import("server.zig");
const font = @import("osd_font.zig");
const Rounding = @import("view/rounding.zig");

const ARGB8888: u32 = 0x34325241;
const pad_x: u32 = 14;
const pad_y: u32 = 10;
const line_gap: u32 = 4;
const toast_ms: u64 = 5000;
const corner_r: u16 = 10;
const max_chars: usize = 46;

const OsdBuffer = extern struct {
    base: wlroots.Buffer,
    pixels: [*]u8,
    size: u32,
    capacity: u32,
};

fn osdDestroy(buffer: *wlroots.Buffer) callconv(.c) void {
    const self: *OsdBuffer = @fieldParentPtr("base", buffer);
    std.heap.c_allocator.free(self.pixels[0..self.capacity]);
    std.heap.c_allocator.destroy(self);
}

fn osdBeginDataPtr(
    buffer: *wlroots.Buffer,
    flags: u32,
    data: **anyopaque,
    format: *u32,
    stride: *usize,
) callconv(.c) bool {
    // The fx renderer reads the card back for texture upload (read flag);
    // own writes during show() are direct. Our RAM is reachable either way.
    if ((flags & (wlroots.Buffer.data_ptr_access_flag.read |
        wlroots.Buffer.data_ptr_access_flag.write)) == 0) return false;
    const self: *OsdBuffer = @fieldParentPtr("base", buffer);
    data.* = @ptrCast(self.pixels);
    format.* = ARGB8888;
    stride.* = @as(usize, @intCast(self.size)) * 4;
    return true;
}

fn osdEndDataPtr(buffer: *wlroots.Buffer) callconv(.c) void {
    _ = buffer;
}

const osd_impl = wlroots.Buffer.Impl{
    .destroy = &osdDestroy,
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = &osdBeginDataPtr,
    .end_data_ptr_access = &osdEndDataPtr,
};

pub fn hide(context: *ServerContext) void {
    if (context.osd_node) |node| {
        node.node.destroy();
        context.osd_node = null;
    }
    if (context.osd_buffer) |buf| {
        buf.drop();
        context.osd_buffer = null;
    }
    context.osd_expiry = 0;
}

pub fn show(context: *ServerContext, lines: []const []const u8) void {
    hide(context);
    const tree = context.osd_tree orelse return;

    // The scene maps 1 buffer px to 1 logical px, then scales up by the
    // output scale; a native-size card would be bilinear-upscaled and blurry.
    // Render the card at the output's pixel density and tell the buffer node
    // its logical box, so glyphs land 1:1 on device pixels.
    const out_scale: f32 = if (context.output) |o| @max(o.scale, 1.0) else 1.0;
    const ss: u32 = @intFromFloat(@max(@ceil(out_scale), 1.0));

    var max_len: usize = 1;
    for (lines) |l| max_len = @max(max_len, @min(l.len, max_chars));

    const lw: u32 = @intCast(pad_x * 2 + @as(u32, @intCast(max_len)) * font.glyph_width);
    const lh: u32 = @intCast(
        pad_y * 2 +
            @as(u32, @intCast(lines.len)) * font.glyph_height +
            @as(u32, @intCast(lines.len -| 1)) * line_gap,
    );
    const width: u32 = lw * ss;
    const height: u32 = lh * ss;
    const capacity: u32 = width * height;
    const pixel_bytes = @as(usize, @intCast(capacity)) * 4;

    const osd_buf = std.heap.c_allocator.create(OsdBuffer) catch return;
    const px = std.heap.c_allocator.alloc(u8, pixel_bytes) catch {
        std.heap.c_allocator.destroy(osd_buf);
        return;
    };

    osd_buf.* = .{
        .base = undefined,
        .pixels = px.ptr,
        .size = width,
        .capacity = capacity,
    };
    wlroots.Buffer.init(&osd_buf.base, &osd_impl, @intCast(width), @intCast(height));

    // Background fill
    {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const off = @as(usize, @intCast(y)) * @as(usize, @intCast(width)) * 4 + @as(usize, @intCast(x)) * 4;
                px[off + 0] = 0x18; // B
                px[off + 1] = 0x1c; // G
                px[off + 2] = 0x16; // R
                px[off + 3] = 0xFF; // A
            }
        }
    }

    // Text glyphs: pre-AA alpha masks blended over the card background.
    for (lines, 0..) |line, i| {
        const ty: u32 = @intCast(pad_y + @as(u32, @intCast(i)) * (font.glyph_height + line_gap));
        for (line[0..@min(line.len, max_chars)], 0..) |ch, j| {
            if (ch < font.first_char or ch > font.last_char) continue;
            const glyph = font.glyphs[ch - font.first_char];
            for (0..font.glyph_width) |c| {
                for (0..font.glyph_height) |r| {
                    const a: u32 = glyph[c * font.glyph_height + r];
                    if (a == 0) continue;
                    // white text over the card channels: base + (a*(255-base))/255
                    const gx = (pad_x + @as(u32, @intCast(j)) * font.glyph_width + @as(u32, @intCast(c))) * ss;
                    const gy = (ty + @as(u32, @intCast(r))) * ss;
                    const b_ = 0x18 + @divTrunc(a * (255 - 0x18), 255);
                    const g_ = 0x1c + @divTrunc(a * (255 - 0x1c), 255);
                    const r_ = 0x16 + @divTrunc(a * (255 - 0x16), 255);
                    var sy: u32 = 0;
                    while (sy < ss) : (sy += 1) {
                        var sx: u32 = 0;
                        while (sx < ss) : (sx += 1) {
                            const off = @as(usize, @intCast(gy + sy)) * @as(usize, @intCast(width)) * 4 + @as(usize, @intCast(gx + sx)) * 4;
                            px[off + 0] = @intCast(b_);
                            px[off + 1] = @intCast(g_);
                            px[off + 2] = @intCast(r_);
                            px[off + 3] = 0xFF;
                        }
                    }
                }
            }
        }
    }

    const buf_ptr: *wlroots.Buffer = &osd_buf.base;
    const node = tree.createSceneBuffer(buf_ptr) catch {
        osd_buf.base.drop();
        return;
    };
    // Render the ss-scaled card into its logical-size box.
    node.setDestSize(@intCast(lw), @intCast(lh));
    Rounding.setBufferCorners(node, corner_r);

    const area = context.usable_area;
    const bw: c_int = @intCast(lw);
    const bh: c_int = @intCast(lh);
    const pos_x: c_int = area.x + @max(0, @divTrunc(area.width -| bw, 2));
    const pos_y: c_int = area.y + @max(0, area.height -| bh) -| 24;
    node.node.setPosition(pos_x, pos_y);

    context.osd_buffer = buf_ptr;
    context.osd_node = node;
    context.osd_expiry = context.nowMs() + toast_ms;
}

pub fn onFrame(context: *ServerContext) void {
    if (context.osd_expiry != 0 and context.nowMs() > context.osd_expiry) hide(context);
}

pub fn inspect(context: *ServerContext) void {
    const view = context.focused_view orelse return;
    const title = std.mem.span(view.title());
    const cls = std.mem.span(view.appId());
    var rule_line_buf: [max_chars]u8 = undefined;
    const rule_line: []const u8 = if (view.rule_note.len > 0) blk: {
        const prefix = "rule: ";
        if (prefix.len + view.rule_note.len <= rule_line_buf.len) {
            @memcpy(rule_line_buf[0..prefix.len], prefix);
            @memcpy(rule_line_buf[prefix.len .. prefix.len + view.rule_note.len], view.rule_note);
            break :blk rule_line_buf[0 .. prefix.len + view.rule_note.len];
        }
        const clipped = view.rule_note[0 .. max_chars - prefix.len];
        @memcpy(rule_line_buf[0..prefix.len], prefix);
        @memcpy(rule_line_buf[prefix.len..], clipped);
        break :blk &rule_line_buf;
    } else "rule: none";
    const lines = [_][]const u8{
        title[0..@min(title.len, max_chars)],
        cls[0..@min(cls.len, max_chars)],
        rule_line[0..@min(rule_line.len, max_chars)],
    };
    show(context, &lines);
}
