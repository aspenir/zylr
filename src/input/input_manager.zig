const wlroots = @import("wlroots");
const std = @import("std");
const xkb = @import("xkbcommon");

const wayland = @import("wayland");
const wl = wayland.server.wl;

const ServerContext = @import("../server.zig");
const KeyboardContext = @import("keyboard.zig");
const TabletContext = @import("tablet.zig");
const TabletPadContext = @import("tablet_pad.zig");
const TouchContext = @import("touch.zig");
const GestureContext = @import("gesture.zig");
const SwitchContext = @import("switch.zig");

pub fn onNewInput(
    listener: *wl.Listener(*wlroots.InputDevice),
    device: *wlroots.InputDevice,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_input_listener", listener);

    switch (device.type) {
        .keyboard => {
            const keyboard = device.toKeyboard();

            std.log.info("NEW KEYBOARD: {s}", .{
                device.name orelse "unknown",
            });

            wireKeyboard(context, keyboard, false);
        },
        .pointer => {
            std.log.info("NEW POINTER: {s}", .{
                device.name orelse "unknown",
            });

            context.cursor.attachInputDevice(device);

            _ = GestureContext.init(context, device) catch |err| {
                std.log.err("Failed to init gestures: {}", .{err});
            };
        },

        .tablet => {
            std.log.info("NEW TABLET: {s}", .{
                device.name orelse "unknown",
            });

            _ = TabletContext.init(context, device) catch |err| {
                std.log.err("Failed to init tablet: {}", .{err});
            };
        },

        .tablet_pad => {
            std.log.info("NEW TABLET PAD: {s}", .{
                device.name orelse "unknown",
            });

            _ = TabletPadContext.init(context, device) catch |err| {
                std.log.err("Failed to init tablet pad: {}", .{err});
            };
        },

        .touch => {
            std.log.info("NEW TOUCH: {s}", .{
                device.name orelse "unknown",
            });

            _ = TouchContext.init(context, device) catch |err| {
                std.log.err("Failed to init touch: {}", .{err});
            };
        },

        .@"switch" => {
            std.log.info("NEW SWITCH: {s}", .{
                device.name orelse "unknown",
            });

            _ = SwitchContext.init(context, device) catch |err| {
                std.log.err("Failed to init switch: {}", .{err});
            };
        },
    }
}

/// Shared wiring for physical and virtual keyboards. Virtual ones skip
/// keymap/repeat setup: their client uploads its own keymap binding the
/// keysyms it wants to evdev codes, so forcing a layout here scrambles
/// every on-screen keyboard.
pub fn wireKeyboard(
    context: *ServerContext,
    keyboard: *wlroots.Keyboard,
    virtual: bool,
) void {
    if (!virtual) {
        keyboard.setRepeatInfo(25, 600);

        const names = context.xkb_names;

        const keymap = xkb.Keymap.newFromNames(
            context.xkb_context,
            &names,
            .no_flags,
        ) orelse {
            std.log.err("Failed to create XKB keymap", .{});
            return;
        };

        if (!keyboard.setKeymap(keymap)) {
            std.log.err("Failed to set XKB keymap", .{});
            xkb.Keymap.unref(keymap);
            return;
        }

        xkb.Keymap.unref(keymap);

        std.log.info("Keyboard layout set", .{});
    }

    const keyboard_context =
        std.heap.c_allocator.create(KeyboardContext) catch |err| {
            std.log.err("Failed to allocate KeyboardContext: {}", .{err});
            return;
        };

    keyboard_context.* = .{
        .keyboard = keyboard,
        .context = context,
    };

    keyboard_context.key_listener =
        wl.Listener(*wlroots.Keyboard.event.Key).init(KeyboardContext.onKeyboardKey);

    keyboard_context.modifiers_listener =
        wl.Listener(*wlroots.Keyboard).init(KeyboardContext.onKeyboardModifiers);

    keyboard.events.key.add(&keyboard_context.key_listener);
    keyboard.events.modifiers.add(&keyboard_context.modifiers_listener);
    keyboard_context.destroy_listener =
        wl.Listener(*wlroots.InputDevice).init(KeyboardContext.onKeyboardDestroy);
    keyboard.base.events.destroy.add(&keyboard_context.destroy_listener);

    context.keyboards.append(
        std.heap.c_allocator,
        keyboard_context,
    ) catch |err| {
        std.log.err("Failed to add KeyboardContext: {}", .{err});

        keyboard_context.key_listener.link.remove();
        keyboard_context.modifiers_listener.link.remove();
        std.heap.c_allocator.destroy(keyboard_context);

        return;
    };

    // The seat broadcasts ONE keymap to all clients, taken from whichever
    // keyboard was set last. Physical keyboards always claim it (last one
    // wins, as before); virtual ones only claim an empty seat, since an
    // OSK's custom keymap binding its own keysyms to evdev codes would
    // otherwise scramble physical typing (comma/period/Escape resolve to
    // nothing, Shift's modifier index doesn't exist).
    if (!virtual or context.seat.getKeyboard() == null) {
        context.seat.setKeyboard(keyboard);
    }

    context.seat.setCapabilities(
        @bitCast(@as(u32, (1 << 0) | (1 << 1) | (1 << 2))),
    );

    std.log.info("Keyboard attached to seat", .{});
}

/// Virtual keyboard clients inject keystrokes through
/// zwp_virtual_keyboard_manager_v1. Their keys go through the
/// same listeners as physical keyboards, compositor binds included.
pub fn onNewVirtualKeyboard(
    listener: *wl.Listener(*wlroots.VirtualKeyboardV1),
    virtual_keyboard: *wlroots.VirtualKeyboardV1,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_virtual_keyboard_listener", listener);

    std.log.info("NEW VIRTUAL KEYBOARD", .{});

    wireKeyboard(context, &virtual_keyboard.keyboard, true);
}

pub fn onNewVirtualPointer(
    listener: *wl.Listener(*wlroots.VirtualPointerManagerV1.event.NewPointer),
    new_pointer: *wlroots.VirtualPointerManagerV1.event.NewPointer,
) void {
    const context: *ServerContext =
        @fieldParentPtr("new_virtual_pointer_listener", listener);

    std.log.info("NEW VIRTUAL POINTER", .{});

    context.cursor.attachInputDevice(&new_pointer.new_pointer.pointer.base);
}
