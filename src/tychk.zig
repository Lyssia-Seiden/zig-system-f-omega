
const std = @import("std");
const core = @import("core.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Ty = core.Ty;
const Binding = core.Binding;
const Allocator = std.mem.Allocator;

pub fn typeOf(gpa: Allocator, term: *const Term, ctx: *const Ctx) !*Ty {
    switch (term.*) {
        .variable => {
            if (ctx.get(term.variable)) |memo| {
                return switch (memo) {
                    .variable => return memo.variable,
                    else => return error.VariableImproperlyTyped,
                };
            } else {
                return error.NoBindingForVar;
            }
        },
        .abs => {
            const ctx_new = Ctx{
                .name = term.abs.name_hint,
                .binding = Binding{.variable = term.abs.ty},
                .pred = ctx,
            };
            const res = try gpa.alloc(Ty, 3);
            res[0] = try typeOf(gpa, term.abs.term, ctx_new);
            res[1] = term.abs.ty;
            res[2] = .{ .function = .{.lhs = term.abs.ty, .rhs = res} };
            return res[2];
        },
        .app => {
            const lhs_ty = try typeOf(gpa, term.app.lhs, ctx);
            const rhs_ty = try typeOf(gpa, term.app.rhs, ctx);
            switch (lhs_ty.*) {
                .function => {
                    const lhs_from = lhs_ty.function.lhs;
                    const lhs_to = lhs_ty.function.rhs;

                    if (rhs_ty.eql(lhs_from)) {
                        return lhs_to;
                    }
                    return error.MalformedArgument;
                },
                .atomic => return error.ApplyingToNonFunction
            }
        }
    }
}