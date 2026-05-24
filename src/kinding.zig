const std = @import("std");
const core = @import("core.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Ty = core.Ty;
const Kind = core.Kind;
const Binding = core.Binding;
const Allocator = std.mem.Allocator;

pub fn kindOf(gpa: Allocator, ty: *const Ty, ctx: ?*const Ctx) !Kind {
    switch (ty.*) {
        .variable => {
            if ((ctx orelse return error.VarInEmptyCtx).get(ty.variable)) |bind| {
                switch (bind) {
                    .ty_var => return bind.ty_var,
                    else => return error.WrongBind,
                }
            }
            return error.NoVarInCtx;
        },
        .function => {
            if (try kindOf(gpa, ty.function.lhs, ctx) != .proper) return error.ImproperFuncTy;
            if (try kindOf(gpa, ty.function.rhs, ctx) != .proper) return error.ImproperFuncTy;
            return .proper;
        },
        .universal => {
            const new_ctx = Ctx{
                .name = ty.universal.label,
                .binding = .{ .ty_var = ty.universal.kind },
                .pred = ctx,
            };
            return kindOf(gpa, ty.universal.inner, &new_ctx);
        },
        .abs => {
            const new_ctx = Ctx{
                .name = ty.abs.name_hint,
                .binding = .{ .ty_var = ty.abs.kind },
                .pred = ctx,
            };
            const alloc = try gpa.create(Kind);
            alloc.* = try kindOf(gpa, ty.abs.ty, &new_ctx);
            return .{ .operator = .{
                .from = &ty.abs.kind,
                .to = alloc,
            } };
        },
        .app => {
            const lhs_kind = try kindOf(gpa, ty.app.lhs, ctx);
            const rhs_kind = try kindOf(gpa, ty.app.rhs, ctx);

            return switch (lhs_kind) {
                .operator => {
                    if (rhs_kind.eql(lhs_kind.operator.from.*)) {
                        return lhs_kind.operator.to.*;
                    }
                    return error.UnkindParameter;
                },
                else => error.UnkindApplication,
            };
        },
    }
}
