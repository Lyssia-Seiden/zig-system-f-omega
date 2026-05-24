const std = @import("std");
const core = @import("core.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Ty = core.Ty;
const Binding = core.Binding;
const Allocator = std.mem.Allocator;

pub fn tyShift(ty: *Ty, delta: i64, cutoff: u32) void {
    switch (ty.*) {
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
    switch (ty.*) {
        .variable => {
            if (ty.variable == target) {
                ty.* = value;
                // tyShift(ty, target, 0);
            }
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

pub fn typeOf(gpa: Allocator, term: *const Term, ctx: ?*const Ctx) !*Ty {
    switch (term.*) {
        .variable => {
            if (ctx.?.get(term.variable)) |memo| {
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
                .universal => return error.ApplyingToNonFunction,
            }
        },
        .ty_abs => {
            const new_ctx = Ctx{ .name = term.ty_abs.label, .binding = .ty_var, .pred = ctx };
            const inner_ty = try typeOf(gpa, term.ty_abs.term, &new_ctx);
            const alloc = try gpa.create(Ty);
            alloc.* = Ty{ .universal = .{ .inner = inner_ty, .label = term.ty_abs.label } };
            return alloc;
        },
        .ty_app => {
            const inner_ty = try typeOf(gpa, term.ty_app.term, ctx);
            switch (inner_ty.*) {
                .universal => {
                    var ty = term.ty_app.ty;
                    tyShift(&ty, 1, 0);
                    tySubst(inner_ty.universal.inner, 0, ty);
                    tyShift(&ty, -1, 0);
                    return inner_ty.universal.inner;
                },
                else => return error.ApplyingNonUniversal,
            }
        },
    }
}

test "tychk stlc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const empty_ctx = Ctx{ .name = "_", .binding = .name, .pred = null };

    // λx:α.x  :  α -> α
    {
        var body = Term{ .variable = 0 };
        const id = Term{ .abs = .{
            .name_hint = "x",
            .ty = .{ .variable = 0 },
            .term = &body,
        } };

        const ty = try typeOf(gpa, &id, &empty_ctx);
        try std.testing.expect(ty.* == .function);
        try std.testing.expect(ty.function.lhs.* == .variable);
        try std.testing.expect(ty.function.rhs.* == .variable);
    }

    // y  :  α    (under ctx y:α)
    {
        const y = Term{ .variable = 0 };
        const ctx = Ctx{
            .name = "y",
            .binding = .{ .variable = .{ .variable = 0 } },
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
            .ty = .{ .variable = 0 },
            .term = &body,
        } };
        var y = Term{ .variable = 0 };
        const app = Term{ .app = .{ .lhs = &id, .rhs = &y } };

        const ctx = Ctx{
            .name = "y",
            .binding = .{ .variable = .{ .variable = 0 } },
            .pred = null,
        };
        const ty = try typeOf(gpa, &app, &ctx);
        try std.testing.expect(ty.* == .variable);
    }

    // λx:α.λy:α.x  :  α -> α -> α   (K-ish, single sort)
    {
        var inner_body = Term{ .variable = 1 };
        var inner_abs = Term{ .abs = .{
            .name_hint = "y",
            .ty = .{ .variable = 0 },
            .term = &inner_body,
        } };
        const k = Term{ .abs = .{
            .name_hint = "x",
            .ty = .{ .variable = 0 },
            .term = &inner_abs,
        } };
        const ty = try typeOf(gpa, &k, &empty_ctx);
        try std.testing.expect(ty.* == .function);
        try std.testing.expect(ty.function.lhs.* == .variable);
        try std.testing.expect(ty.function.rhs.* == .function);
        try std.testing.expect(ty.function.rhs.function.lhs.* == .variable);
        try std.testing.expect(ty.function.rhs.function.rhs.* == .variable);
    }

    // y y  :  error.ApplyingToNonFunction   (under ctx y:α)
    {
        var y1 = Term{ .variable = 0 };
        var y2 = Term{ .variable = 0 };
        const app = Term{ .app = .{ .lhs = &y1, .rhs = &y2 } };
        const ctx = Ctx{
            .name = "y",
            .binding = .{ .variable = .{ .variable = 0 } },
            .pred = null,
        };
        try std.testing.expectError(
            error.ApplyingToNonFunction,
            typeOf(gpa, &app, &ctx),
        );
    }
}

test "tychk systemf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const empty_ctx = Ctx{ .name = "_", .binding = .name, .pred = null };

    // Λα.λx:α.x  :  ∀α.α -> α
    {
        var body = Term{ .variable = 0 };
        var inner_abs = Term{ .abs = .{
            .name_hint = "x",
            .ty = .{ .variable = 0 },
            .term = &body,
        } };
        const poly_id = Term{ .ty_abs = .{
            .label = "α",
            .term = &inner_abs,
        } };
        const ty = try typeOf(gpa, &poly_id, &empty_ctx);
        try std.testing.expect(ty.* == .universal);
        try std.testing.expect(ty.universal.inner.* == .function);
        try std.testing.expect(ty.universal.inner.function.lhs.* == .variable);
        try std.testing.expect(ty.universal.inner.function.rhs.* == .variable);
    }

    // (Λα.λx:α.x) [β]  :  β -> β   (under ctx β:ty_var)
    {
        var body = Term{ .variable = 0 };
        var inner_abs = Term{ .abs = .{
            .name_hint = "x",
            .ty = .{ .variable = 0 },
            .term = &body,
        } };
        var poly_id = Term{ .ty_abs = .{
            .label = "α",
            .term = &inner_abs,
        } };
        const ty_app = Term{ .ty_app = .{
            .ty = .{ .variable = 0 },
            .term = &poly_id,
        } };
        const ctx = Ctx{ .name = "β", .binding = .ty_var, .pred = null };
        const ty = try typeOf(gpa, &ty_app, &ctx);
        try std.testing.expect(ty.* == .function);
        try std.testing.expect(ty.function.lhs.* == .variable);
        try std.testing.expect(ty.function.rhs.* == .variable);
    }
}
