const std = @import("std");
const core = @import("core.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Ty = core.Ty;
const Binding = core.Binding;
const Allocator = std.mem.Allocator;

pub fn tyShift(ty: *Ty, delta: i32, cutoff: u32) !void {
    switch (ty) {
        .variable => {
            if (ty.variable >= cutoff)
                ty.variable = @intCast(@as(i32, @intCast(ty.variable)) + delta);
        },
        .function => {
            tyShift(ty.function.lhs, delta, cutoff);
            tyShift(ty.function.rhs, delta, cutoff);
        },
        .universal => {
            tyShift(ty.universal.inner, delta, cutoff + 1);
        },
    }
}

/// [target -> value]ty
/// [j -> s]t
pub fn tySubst(ty: *Ty, target: u32, value: Ty) void {
    switch (ty) {
        .variable => {
            if (ty.variable == target) ty.* = value;
        },
        .function => {
            tySubst(ty.function.lhs, target, value);
            tySubst(ty.function.rhs, target, value);
        },
        .universal => {
            tySubst(ty.universal.inner, target + 1, value);
        },
    }
}

pub fn typeOf(gpa: Allocator, term: *const Term, ctx: *const Ctx) !*Ty {
    switch (term.*) {
        .variable => {
            if (ctx.get(term.variable)) |memo| {
                return switch (memo) {
                    .variable => {
                        const alloc = try gpa.create(Ty);
                        alloc.* = memo.variable;
                        return alloc;
                    },
                    else => return error.VariableImproperlyTyped,
                };
            } else {
                return error.NoBindingForVar;
            }
        },
        .abs => {
            const ctx_new = Ctx{
                .name = term.abs.name_hint,
                .binding = Binding{ .variable = term.abs.ty },
                .pred = ctx,
            };
            const res = try gpa.alloc(Ty, 2);
            const rhs = try typeOf(gpa, term.abs.term, &ctx_new);
            res[0] = term.abs.ty;
            res[1] = .{ .function = .{ .lhs = &res[0], .rhs = rhs } };
            return &res[1];
        },
        .app => {
            const lhs_ty = try typeOf(gpa, term.app.lhs, ctx);
            const rhs_ty = try typeOf(gpa, term.app.rhs, ctx);
            switch (lhs_ty.*) {
                .function => {
                    const lhs_from = lhs_ty.function.lhs;
                    const lhs_to = lhs_ty.function.rhs;

                    if (rhs_ty.eql(lhs_from.*)) {
                        return lhs_to;
                    }
                    return error.MalformedArgument;
                },
                .variable => return error.ApplyingToNonFunction,
            }
        },
    }
}

test "tychk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const empty_ctx = Ctx{ .name = "_", .binding = .name, .pred = null };

    // λx:α.x  :  α -> α
    {
        var body = Term{ .variable = 0 };
        var id = Term{ .abs = .{
            .name_hint = "x",
            .ty = .variable,
            .term = &body,
        } };

        const ty = try typeOf(gpa, &id, &empty_ctx);
        try std.testing.expect(ty.* == .function);
        try std.testing.expect(ty.function.lhs.* == .variable);
        try std.testing.expect(ty.function.rhs.* == .variable);
    }

    // y  :  α    (under ctx y:α)
    {
        var y = Term{ .variable = 0 };
        const ctx = Ctx{
            .name = "y",
            .binding = .{ .variable = .variable },
            .pred = null,
        };
        const ty = try typeOf(gpa, &y, &ctx);
        try std.testing.expect(ty.* == .variable);
    }

    // (λx:α.x) y  :  α    (under ctx y:α)
    {
        var body = Term{ .variable = 0 };
        var id = Term{ .abs = .{
            .name_hint = "x",
            .ty = .variable,
            .term = &body,
        } };
        var y = Term{ .variable = 0 };
        var app = Term{ .app = .{ .lhs = &id, .rhs = &y } };

        const ctx = Ctx{
            .name = "y",
            .binding = .{ .variable = .variable },
            .pred = null,
        };
        const ty = try typeOf(gpa, &app, &ctx);
        try std.testing.expect(ty.* == .variable);
    }
}
