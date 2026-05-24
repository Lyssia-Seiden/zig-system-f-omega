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

const testing = std.testing;

fn arenaAlloc() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "kinding: variable lookup yields its bound kind" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const ctx = Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const ty = Ty{ .variable = 0 };
    const kind = try kindOf(gpa, &ty, &ctx);
    try testing.expect(kind == .proper);
}

test "kinding: variable lookup yields higher kind" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const k_from: Kind = .proper;
    const k_to: Kind = .proper;
    const k_op = Kind{ .operator = .{ .from = &k_from, .to = &k_to } };

    const ctx = Ctx{
        .name = "F",
        .binding = .{ .ty_var = k_op },
        .pred = null,
    };
    const ty = Ty{ .variable = 0 };
    const kind = try kindOf(gpa, &ty, &ctx);
    try testing.expect(kind == .operator);
    try testing.expect(kind.operator.from.* == .proper);
    try testing.expect(kind.operator.to.* == .proper);
}

test "kinding: function with proper operands is proper" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const ctx = Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    var lhs = Ty{ .variable = 0 };
    var rhs = Ty{ .variable = 0 };
    const ty = Ty{ .function = .{ .lhs = &lhs, .rhs = &rhs } };
    const kind = try kindOf(gpa, &ty, &ctx);
    try testing.expect(kind == .proper);
}

test "kinding: universal type" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // ∀α::*. α -> α
    var lhs = Ty{ .variable = 0 };
    var rhs = Ty{ .variable = 0 };
    var fn_ty = Ty{ .function = .{ .lhs = &lhs, .rhs = &rhs } };
    const ty = Ty{ .universal = .{
        .label = "α",
        .kind = .proper,
        .inner = &fn_ty,
    } };
    const kind = try kindOf(gpa, &ty, null);
    try testing.expect(kind == .proper);
}

test "kinding: type-level identity has kind * => *" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // λα::*. α
    var body = Ty{ .variable = 0 };
    const ty = Ty{ .abs = .{
        .name_hint = "α",
        .kind = .proper,
        .ty = &body,
    } };
    const kind = try kindOf(gpa, &ty, null);
    try testing.expect(kind == .operator);
    try testing.expect(kind.operator.from.* == .proper);
    try testing.expect(kind.operator.to.* == .proper);
}

test "kinding: nested type-level lambda has kind * => * => *" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // λα::*. λβ::*. α -> β
    var fn_lhs = Ty{ .variable = 1 }; // α (outer)
    var fn_rhs = Ty{ .variable = 0 }; // β (inner)
    var fn_ty = Ty{ .function = .{ .lhs = &fn_lhs, .rhs = &fn_rhs } };
    var inner_abs = Ty{ .abs = .{
        .name_hint = "β",
        .kind = .proper,
        .ty = &fn_ty,
    } };
    const ty = Ty{ .abs = .{
        .name_hint = "α",
        .kind = .proper,
        .ty = &inner_abs,
    } };
    const kind = try kindOf(gpa, &ty, null);
    try testing.expect(kind == .operator);
    try testing.expect(kind.operator.from.* == .proper);
    try testing.expect(kind.operator.to.* == .operator);
    try testing.expect(kind.operator.to.operator.from.* == .proper);
    try testing.expect(kind.operator.to.operator.to.* == .proper);
}

test "kinding: type application of identity operator" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // (λα::*. α) β   where β::*    →   *
    const ctx = Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    var body = Ty{ .variable = 0 };
    var op = Ty{ .abs = .{ .name_hint = "α", .kind = .proper, .ty = &body } };
    var arg = Ty{ .variable = 0 };
    const ty = Ty{ .app = .{ .lhs = &op, .rhs = &arg } };
    const kind = try kindOf(gpa, &ty, &ctx);
    try testing.expect(kind == .proper);
}

test "kinding: type-level lambda taking a type operator" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // λF::(* => *). F   →   (* => *) => (* => *)
    const k_from: Kind = .proper;
    const k_to: Kind = .proper;
    const k_op = Kind{ .operator = .{ .from = &k_from, .to = &k_to } };

    var body = Ty{ .variable = 0 };
    const ty = Ty{ .abs = .{
        .name_hint = "F",
        .kind = k_op,
        .ty = &body,
    } };
    const kind = try kindOf(gpa, &ty, null);
    try testing.expect(kind == .operator);
    try testing.expect(kind.operator.from.* == .operator);
    try testing.expect(kind.operator.from.operator.from.* == .proper);
    try testing.expect(kind.operator.from.operator.to.* == .proper);
    try testing.expect(kind.operator.to.* == .operator);
}

test "kinding: applying a higher-kinded operator to a proper type" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // (λF::(* => *). F) G   where G::(* => *)   →   * => *
    const k_from: Kind = .proper;
    const k_to: Kind = .proper;
    const k_op = Kind{ .operator = .{ .from = &k_from, .to = &k_to } };

    var body = Ty{ .variable = 0 };
    var op = Ty{ .abs = .{ .name_hint = "F", .kind = k_op, .ty = &body } };
    var arg = Ty{ .variable = 0 };
    const ty = Ty{ .app = .{ .lhs = &op, .rhs = &arg } };

    const ctx = Ctx{
        .name = "G",
        .binding = .{ .ty_var = k_op },
        .pred = null,
    };
    const kind = try kindOf(gpa, &ty, &ctx);
    try testing.expect(kind == .operator);
    try testing.expect(kind.operator.from.* == .proper);
    try testing.expect(kind.operator.to.* == .proper);
}

test "kinding error: function with non-proper operand" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // (λα::*.α) -> α   where the lhs is * => *, not *
    var op_body = Ty{ .variable = 0 };
    var op = Ty{ .abs = .{ .name_hint = "α", .kind = .proper, .ty = &op_body } };
    var rhs = Ty{ .variable = 0 };
    const ty = Ty{ .function = .{ .lhs = &op, .rhs = &rhs } };
    const ctx = Ctx{
        .name = "γ",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    try testing.expectError(error.ImproperFuncTy, kindOf(gpa, &ty, &ctx));
}

test "kinding error: applying a non-operator type" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // α β   where both α, β :: *
    const inner_ctx = Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const ctx = Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = &inner_ctx,
    };
    var lhs = Ty{ .variable = 0 };
    var rhs = Ty{ .variable = 1 };
    const ty = Ty{ .app = .{ .lhs = &lhs, .rhs = &rhs } };
    try testing.expectError(error.UnkindApplication, kindOf(gpa, &ty, &ctx));
}

test "kinding error: argument kind mismatch" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // (λF::(* => *). F) β   where β::*   →   error
    const k_from: Kind = .proper;
    const k_to: Kind = .proper;
    const k_op = Kind{ .operator = .{ .from = &k_from, .to = &k_to } };

    var body = Ty{ .variable = 0 };
    var op = Ty{ .abs = .{ .name_hint = "F", .kind = k_op, .ty = &body } };
    var arg = Ty{ .variable = 0 };
    const ty = Ty{ .app = .{ .lhs = &op, .rhs = &arg } };

    const ctx = Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    try testing.expectError(error.UnkindParameter, kindOf(gpa, &ty, &ctx));
}
