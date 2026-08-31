//! Minimal vendored slice of ziggy 0.2.0 (kristoff-it/ziggy, MIT):
//! only the document deserializer, which is all zylr's config needs.
//! The upstream build system targets newer Zig toolchains than ours.

pub const Tokenizer = @import("Tokenizer.zig");
pub const Deserializer = @import("Deserializer.zig");
pub const deserialize = Deserializer.deserialize;
pub const deserializeLeaky = Deserializer.deserializeLeaky;

/// When a Zig container type has a public decl named `ziggy_options` of
/// type `Options(T)`, it can customize (de)serialization behavior.
pub fn Options(T: type) type {
    const std = @import("std");

    return struct {
        /// Fields listed here will not be (de)serialized. If `deserialize`
        /// is null, skipped fields must have a default value.
        skip_fields: []const std.meta.FieldEnum(T) = &.{},

        /// If set, the source location of where this struct was loaded
        /// from in the Ziggy document will be saved in this field.
        /// The field in question must be:
        ///  - present in `skip_fields`
        ///  - of type `ziggy.Tokenizer.Token.Loc`
        loc_field: ?std.meta.FieldEnum(T) = null,

        /// Used by build-time Zig type <> Ziggy Schema compatibility
        /// validation for types that customize (de)serialization.
        ///
        /// - 'any':  The type can match any Ziggy type and, in the
        ///           case of wrapping types ('?', '{:}', '[]'), it
        ///           will also consume child values. This is the
        ///           value of `ziggy.Dynamic`.
        ///
        /// - 'container': Lets you specify compatibily with container
        ///                types. You will need to provide the child
        ///                type of your custom container in order to
        ///                let the algorithm continue validating the
        ///                type.
        ///
        /// - 'none': The default value.
        roles: union(enum) {
            any,
            container: struct {
                dict: ?type = null,
                slice: ?type = null,
                /// The type corresponding to the union itself which you
                /// are expected to be wrapping (use `.any` otherwise).
                @"union": ?type = null,
            },
            none,
        } = .none,

        // The upstream serialize/deserialize override hooks are not
        // vendored (they pull in Serializer.zig/Ast.zig); zylr types
        // don't use ziggy_options.
    };
}

/// Returns `ziggy_options` from T or null if the decl is missing,
/// private, or T is not a container type.
///
/// Will trigger a compile error if `ziggy_options` is not of the
/// right type or any other semantic error is found.
pub inline fn getOptions(T: type) switch (@typeInfo(T)) {
    .@"struct", .@"union", .@"enum" => ?Options(T),
    else => ?void,
} {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {},
        else => return null,
    }

    if (!@hasDecl(T, "ziggy_options")) return null;

    if (@TypeOf(T.ziggy_options) != Options(T)) {
        @compileError(@typeName(T) ++
            ".ziggy_options must be of type ziggy.Options(T)");
    }

    switch (@typeInfo(T)) {
        .@"struct" => {
            const std = @import("std");
            if (T.ziggy_options.loc_field) |lf| {
                @setEvalBranchQuota(10000);
                if (comptime std.mem.findScalar(
                    std.meta.FieldEnum(T),
                    T.ziggy_options.skip_fields,
                    lf,
                ) == null) {
                    @compileError("Loc field '" ++ @tagName(lf) ++ "' must be listed in 'skip_fields'");
                }
            }
        },
        .@"union", .@"enum" => {
            if (T.ziggy_options.skip_fields.len > 0) {
                @compileError("'skip_fields' must be empty in union and enum types");
            }
            if (T.ziggy_options.loc_field != null) {
                @compileError("'loc_field' must be null in union and enum types");
            }
        },
        else => return null,
    }

    return T.ziggy_options;
}

