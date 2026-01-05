const std = @import("std");
const assert = std.debug.assert;
const StructField = std.builtin.Type.StructField;

const OffsetField = struct {
    bit_offset: usize,
    field: StructField,
};

fn countFlatStructFields(comptime T: type) usize {
    const info = @typeInfo(T);
    if (info == .@"struct" and info.@"struct".layout != .@"packed") {
        var n = 0;
        inline for (info.@"struct".fields) |field| {
            n += countFlatStructFields(field.type);
        }
        return n;
    } else {
        return 1;
    }
}

fn fillFlatStructFields(comptime T: type, fields: []OffsetField, start_offset: usize) usize {
    var i = 0;
    for (@typeInfo(T).@"struct".fields) |field| {
        const bit_offset = start_offset + @bitOffsetOf(T, field.name);
        const info = @typeInfo(field.type);
        if (info == .@"struct" and info.@"struct".layout != .@"packed") {
            const n = fillFlatStructFields(field.type, fields[i..], bit_offset);
            i += n;
        } else {
            fields[i] = .{ .bit_offset = bit_offset, .field = field };
            i += 1;
        }
    }
    return i;
}

fn flatStructFields(comptime T: type) [countFlatStructFields(T)]OffsetField {
    const n = countFlatStructFields(T);
    var fields: [n]OffsetField = undefined;
    const result = fillFlatStructFields(T, &fields, 0);
    assert(n == result);
    return fields;
}

pub fn ensureEquivalentAbi(comptime New: type, comptime Orig: type) void {
    const new_fields = @typeInfo(New).@"struct".fields;
    const orig_fields = @typeInfo(Orig).@"struct".fields;
    if (new_fields.len != orig_fields.len) {
        @compileError(std.fmt.comptimePrint(
                "{} has {} field{s}, should have {} to match {}",
                .{ New, new_fields.len, if (new_fields.len == 1) "" else "s", orig_fields.len, Orig },
        ));
    }

    inline for (new_fields, orig_fields, 0..) |nf, of, i| {
        if (!std.mem.eql(u8, nf.name, of.name))
            @compileError(std.fmt.comptimePrint(
                    "Field at index {d} name mismatch: {}.{s} vs. {}.{s}",
                    .{i, New, nf.name, Orig, of.name},
            ));
        const new_bits = @bitSizeOf(nf.type);
        const orig_bits = @bitSizeOf(of.type);
        if (new_bits != orig_bits)
            @compileError(std.fmt.comptimePrint(
                    "{}.{s} has bit size {}, should be {} to match {}.{s}: {}",
                    .{New, nf.name, new_bits, orig_bits, Orig, of.name, of.type},
            ));

        const new_ofs = @bitOffsetOf(New, nf.name);
        const orig_ofs = @bitOffsetOf(Orig, of.name);
        if (new_ofs != orig_ofs)
            @compileError(std.fmt.comptimePrint(
                    "{}.{s} is at bit offset {}, should be {} to match {}.{s}",
                    .{New, nf.name, new_ofs, orig_ofs, Orig, of.name},
            ));
    }

    const new_size = @sizeOf(New);
    const orig_size = @sizeOf(Orig);
    if (new_size != orig_size)
        @compileError(std.fmt.comptimePrint(
                "{} is size {}, should be {} to match {}",
                .{ New, new_size, orig_size, Orig },
        ));

    const new_align = @alignOf(New);
    const orig_align = @alignOf(Orig);
    if (new_align != orig_align)
        @compileError(std.fmt.comptimePrint(
                "{} has alignment {}, should be {} to match {}",
                .{ New, new_align, orig_align, Orig },
        ));
}

pub fn ensureEquivalentAbiFlat(comptime New: type, comptime Orig: type) void {
    const new_fields = flatStructFields(New);
    const orig_fields = flatStructFields(Orig);
    if (new_fields.len != orig_fields.len)
        @compileError(std.fmt.comptimePrint(
                "{} has {} field{s}, should have {} to match {}",
                .{ New, new_fields.len, if (new_fields.len == 1) "" else "s", orig_fields.len, Orig },
        ));

    inline for (new_fields, orig_fields, 0..) |nf, of, i| {
        if (!std.mem.eql(u8, nf.field.name, of.field.name))
            @compileError(std.fmt.comptimePrint(
                    "Field at index {d} name mismatch: {}.{s} vs. {}.{s}",
                    .{i, New, nf.field.name, Orig, of.field.name},
            ));
        const new_bits = @bitSizeOf(nf.field.type);
        const orig_bits = @bitSizeOf(of.field.type);
        if (new_bits != orig_bits)
            @compileError(std.fmt.comptimePrint(
                    "{}.{s} has bit size {}, should be {} to match {}.{s}: {}",
                    .{New, nf.field.name, new_bits, orig_bits, Orig, of.field.name, of.field.type},
            ));

        const new_ofs = nf.bit_offset;
        const orig_ofs = of.bit_offset;
        if (new_ofs != orig_ofs)
            @compileError(std.fmt.comptimePrint(
                    "{}.{s} is at bit offset {}, should be {} to match {}.{s}",
                    .{New, nf.field.name, new_ofs, orig_ofs, Orig, of.field.name},
            ));
    }

    const new_size = @sizeOf(New);
    const orig_size = @sizeOf(Orig);
    if (new_size != orig_size)
        @compileError(std.fmt.comptimePrint(
                "{} is size {}, should be {} to match {}",
                .{ New, new_size, orig_size, Orig },
        ));

    const new_align = @alignOf(New);
    const orig_align = @alignOf(Orig);
    if (new_align != orig_align)
        @compileError(std.fmt.comptimePrint(
                "{} has alignment {}, should be {} to match {}",
                .{ New, new_align, orig_align, Orig },
        ));
}

fn camelFromSnake(dest: []u8, src: []const u8) []u8 {
    var cap_next = true;
    var i: usize = 0;
    for (src) |c| {
        if (c == '_') {
            cap_next = true;
            continue;
        } else {
            dest[i] = if (cap_next) std.ascii.toUpper(c) else c;
            i += 1;
        }
        cap_next = false;
    }
    return dest[0..i];
}

pub fn checkEnum(comptime New: type, comptime Old: type, comptime Namespace: type, comptime prefix: []const u8) void {
    switch (@typeInfo(New)) {
        .@"enum" => |info| {
            const Tag = info.tag_type;
            if (!std.meta.eql(@typeInfo(Tag), @typeInfo(Old)))
                @compileError(std.fmt.comptimePrint(
                    "Tag type {} for enum {} doesn't match {}",
                    .{ Tag, New, Old },
                ));
            for (info.fields) |field| {
                const name = field.name;
                var camel_buf: [name.len]u8 = undefined;
                // _ = std.ascii.upperString(&upper_name, name);
                const camel = camelFromSnake(&camel_buf, name);
                const field_value = field.value;
                const macro_name = prefix ++ camel;
                const macro_value = @field(Namespace, macro_name);
                if (macro_value != field_value) {
                    @compileError(std.fmt.comptimePrint(
                        "Macro {s} has value {} but field {}.{s} has value {}",
                        .{
                            macro_name,
                            macro_value,
                            New,
                            name,
                            field_value,
                        },
                    ));
                }
            }
        },
        else => @compileError("checkEnum only works on enums"),
    }
}

pub fn checkBitField(comptime T: type, comptime Namespace: type, comptime prefix: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout != .@"packed")
                @compileError("checkBitField only works on packed structs");
            for (info.fields) |field| {
                if (field.type != bool)
                    continue;
                const name = field.name;
                var upper_name: [name.len]u8 = undefined;
                _ = std.ascii.upperString(&upper_name, name);
                const macro_name = prefix ++ upper_name;
                const macro_value = @field(Namespace, macro_name);
                var base = T{};
                @field(base, name) = true;
                const field_value: info.backing_integer.? = @bitCast(base);
                if (macro_value != field_value) {
                    @compileError(std.fmt.comptimePrint(
                        "Macro {s} has value {} but field {}.{s} has value {}",
                        .{
                            macro_name,
                            macro_value,
                            T,
                            name,
                            field_value,
                        },
                    ));
                }
            }
        },
        else => @compileError("checkBitField only works on structs"),
    }
}
