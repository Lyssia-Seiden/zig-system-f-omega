const std = @import("std");
const core = @import("core.zig");
const kinding = @import("kinding.zig");
const interpreter = @import("interpreter.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Ty = core.Ty;
const Kind = core.Kind;
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
        .abs => {
            tyShift(ty.abs.ty, delta, cutoff + 1);
        },
        .app => {
            tyShift(ty.app.lhs, delta, cutoff);
            tyShift(ty.app.rhs, delta, cutoff);
        },
    }
}

/// [target -> value]ty
/// [j -> s]t
pub fn tySubst(gpa: Allocator, ty: *Ty, target: u32, value: Ty) !void {
    // std.debug.print("substituting in {f}\n", .{ty.*});
    switch (ty.*) {
        .variable => {
            if (ty.variable == target) {
                try value.deepCopyInto(gpa, ty);
                // tyShift(ty, target, 0);
            }
        },
        .function => {
            try tySubst(gpa, ty.function.lhs, target, value);
            try tySubst(gpa, ty.function.rhs, target, value);
        },
        .universal => {
            try tySubst(gpa, ty.universal.inner, target + 1, value);
        },
        .abs => {
            try tySubst(gpa, ty.abs.ty, target + 1, value);
        },
        .app => {
            try tySubst(gpa, ty.app.lhs, target, value);
            try tySubst(gpa, ty.app.rhs, target, value);
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
                        tyShift(alloc, term.variable, 0);
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

            // std.debug.print("recursing on {f}\n", .{
            //     core.TermWCtx{ .term = term.abs.term, .ctx = &ctx_new },
            // });
            const rhs = try typeOf(gpa, term.abs.term, &ctx_new);
            // tyShift(rhs, -1, 0);
            // tyShift(term.abs.term, 1, 0);
            res[0] = term.abs.ty;
            res[1] = .{ .function = .{ .lhs = &res[0], .rhs = rhs } };
            return &res[1];
        },
        .app => {
            const lhs_ty = try typeOf(gpa, term.app.lhs, ctx);
            try reduceTy(gpa, lhs_ty);
            const rhs_ty = try typeOf(gpa, term.app.rhs, ctx);
            switch (lhs_ty.*) {
                .function => {
                    const lhs_from = lhs_ty.function.lhs;
                    const lhs_to = lhs_ty.function.rhs;

                    // std.debug.print("{f} ?= {f} in {f} w ctx {f}\n", .{
                    //     lhs_from,
                    //     rhs_ty,
                    //     core.TermWCtx{ .term = term, .ctx = ctx },
                    //     ctx.?,
                    // });

                    // TODO test for equivalence, not just equality
                    if (try rhs_ty.eqv(gpa, lhs_from, ctx)) {
                        return lhs_to;
                    }
                    // return lhs_to;
                    return error.MalformedArgument;
                },
                else => return error.ApplyingToNonFunction,
            }
        },
        .ty_abs => {
            const new_ctx = Ctx{
                .name = term.ty_abs.label,
                .binding = .{ .ty_var = term.ty_abs.kind },
                .pred = ctx,
            };
            // std.debug.print("recursing on {f}\n", .{
            //     core.TermWCtx{ .term = term.ty_abs.term, .ctx = &new_ctx },
            // });
            const inner_ty = try typeOf(gpa, term.ty_abs.term, &new_ctx);
            const alloc = try gpa.create(Ty);
            alloc.* = Ty{ .universal = .{ .inner = inner_ty, .kind = term.ty_abs.kind, .label = term.ty_abs.label } };
            return alloc;
        },
        .ty_app => {
            const inner_ty = try typeOf(gpa, term.ty_app.term, ctx);
            try reduceTy(gpa, inner_ty);
            switch (inner_ty.*) {
                .universal => {
                    const kind = try kinding.kindOf(gpa, &term.ty_app.ty, ctx);
                    // std.debug.print("lhs kind {f} rhs {f}\n", .{ inner_ty.universal.kind, kind });
                    // std.debug.print("lhs ty {f} rhs ty {f}\n", .{ inner_ty, term.ty_app.ty });
                    if (!inner_ty.universal.kind.eql(kind)) return error.UnkindApplicationFrownyFace;
                    var ty = term.ty_app.ty;
                    tyShift(&ty, 1, 0);
                    try tySubst(gpa, inner_ty.universal.inner, 0, ty);
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
        const ctx = Ctx{ .name = "β", .binding = .{ .ty_var = .proper }, .pred = null };
        const ty = try typeOf(gpa, &ty_app, &ctx);
        try std.testing.expect(ty.* == .function);
        try std.testing.expect(ty.function.lhs.* == .variable);
        try std.testing.expect(ty.function.rhs.* == .variable);
    }
}

// Equivalence related functions

fn reduceTyApp(gpa: Allocator, ty: *Ty) !bool {
    switch (ty.*) {
        .app => {
            switch (ty.app.lhs.*) {
                .abs => {
                    tyShift(ty.app.rhs, 1, 0);
                    try tySubst(gpa, ty.app.lhs.abs.ty, 0, ty.app.rhs.*);
                    tyShift(ty.app.rhs, -1, 0);
                    ty.* = ty.app.lhs.abs.ty.*;
                    // gpa.destroy(ty.app.rhs);
                    // gpa.destroy(ty.app.lhs);
                    // gpa.destroy(ty.app.lhs.abs.ty);
                    return true;
                },
                else => return false,
            }
        },
        else => return false,
    }
}

pub fn reduceTy(gpa: Allocator, ty: *Ty) !void {
    // first reduce the lhs, if this is an application
    switch (ty.*) {
        .app => try reduceTy(gpa, ty.app.lhs),
        else => {},
    }
    // apply substitution if possible
    // then repeat
    switch (ty.*) {
        .app => switch (ty.app.lhs.*) {
            .abs => {
                // simplify
                if (try reduceTyApp(gpa, ty)) try reduceTy(gpa, ty);
            },
            else => return,
        },
        else => return,
    }
}

pub fn walkReduceTys(gpa: Allocator, ty: *Ty) !void {
    switch (ty.*) {
        .universal => try walkReduceTys(gpa, ty.universal.inner),
        .function => {
            try walkReduceTys(gpa, ty.function.lhs);
            try walkReduceTys(gpa, ty.function.rhs);
        },
        else => try reduceTy(gpa, ty),
    }
}

pub fn reduceAllTys(gpa: Allocator, term: *Term) !void {
    switch (term.*) {
        .variable => {},
        .abs => {
            try reduceTy(gpa, &term.abs.ty);
            try reduceAllTys(gpa, term.abs.term);
        },
        .app => {
            try reduceAllTys(gpa, term.app.lhs);
            try reduceAllTys(gpa, term.app.rhs);
        },
        .ty_abs => {
            try reduceAllTys(gpa, term.ty_abs.term);
        },
        .ty_app => {
            try reduceTy(gpa, &term.ty_app.ty);
            try reduceAllTys(gpa, term.ty_app.term);
        },
    }
}

pub fn tyShiftVars(term: *Term, delta: i64, cutoff: u32) void {
    switch (term.*) {
        .variable => {
            if (term.variable >= cutoff)
                term.variable = @intCast(@as(i32, @intCast(term.*.variable)) + delta);
        },
        .abs => {
            tyShiftVars(term.abs.term, delta, cutoff + 1);
        },
        .app => {
            tyShiftVars(term.app.lhs, delta, cutoff);
            tyShiftVars(term.app.rhs, delta, cutoff);
        },
        .ty_abs => tyShiftVars(term.ty_abs.term, delta, cutoff + 1),
        .ty_app => {
            tyShiftVars(term.ty_app.term, delta, cutoff);
        },
    }
}
