const xkb = @import("xkbcommon");

fn hex_color(hex: u32) [4]f32 {
    return [4]f32{
        @as(f32, @floatFromInt((hex >> 24) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(hex & 0xff)) / 255.0,
    };
}

pub const log_level = .err;
pub const borderpx = 1;  // window border width in pixels
pub export const rootcolor = hex_color(0x1d252fff);
pub export const bordercolor = hex_color(0x27323fff);
pub export const focuscolor = hex_color(0x717a77ff);
pub export const urgentcolor = hex_color(0x7eb6f6ff);

pub const repeatRate = 20;
pub const repeatDelay = 200;

// keyboard
pub const xkbRules: xkb.RuleNames = .{
    // can specify fields: rules, model, layout, variant, options
    // example:
    //   .options = "ctrl:nocaps",
    .layout = "us",
    .variant = "dvorak",
    .options = "ctrl:nocaps,altwin:swap_lalt_lwin",
    .rules = null,
    .model = null,
};
