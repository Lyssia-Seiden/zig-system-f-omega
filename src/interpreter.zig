const std = @import("std");
const core = @import("core.zig");
const tychk = @import("tychk.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Ty = core.Ty;
const Allocator = std.mem.Allocator;

fn shift(term: *Term, delta: i64, cutoff: u32) void {
    switch (term.*) {
        .variable => {
            if (term.variable >= cutoff)
                term.variable = @intCast(@as(i32, @intCast(term.*.variable)) + delta);
        },
        .abs => {
            shift(term.abs.term, delta, cutoff + 1);
            tychk.tyShift(&term.abs.ty, delta, cutoff);
        },
        .app => {
            shift(term.app.lhs, delta, cutoff);
            shift(term.app.rhs, delta, cutoff);
        },
        .ty_abs => shift(term.ty_abs.term, delta, cutoff + 1),
        .ty_app => {
            shift(term.ty_app.term, delta, cutoff);
            tychk.tyShift(&term.ty_app.ty, delta, cutoff);
        },
    }
}

test "shift" {
    var term = Term{ .variable = 0 };
    shift(&term, 1, 0);
    try std.testing.expectEqual(1, term.variable);
}

/// [target -> value]term
/// [j -> s]t
/// cutoff should be initialized to 0
fn subst(term: *Term, target: u32, value: *const Term, depth: u32) void {
    switch (term.*) {
        .variable => {
            if (term.variable == target) {
                shift(term, depth, 0);
            }
        },
        .abs => subst(term.abs.term, target, value, depth + 1),
        .app => {
            subst(term.app.lhs, target, value, depth);
            subst(term.app.rhs, target, value, depth);
        },
        .ty_abs => subst(term.ty_abs.term, target, value, depth + 1),
        .ty_app => subst(term.ty_app.term, target, value, depth),
    }
}

/// [target -> value]term
/// [j -> s]t
fn tyTermSubst(term: *Term, target: u32, value: Ty, depth: u32) void {
    switch (term.*) {
        .variable => {},
        .abs => {
            var ty = term.abs.ty;
            tychk.tySubst(&ty, target, value);
            tyTermSubst(term.abs.term, target, value, depth + 1);
        },
        .app => {
            tyTermSubst(term.app.lhs, target, value, depth);
            tyTermSubst(term.app.rhs, target, value, depth);
        },
        .ty_abs => tyTermSubst(term.ty_abs.term, target, value, depth + 1),
        .ty_app => {
            var ty = term.ty_app.ty;
            tychk.tySubst(&ty, target, value);
            tyTermSubst(term.ty_app.term, target, value, depth + 1);
        },
    }
}

/// Modifies term in place
/// returns true if something got reduced
/// terms must have been allocated with gpa
pub fn evalStep(gpa: Allocator, term: *Term, ctx: ?*const Ctx) !bool {
    switch (term.*) {
        .variable => return false,
        .abs => return false,
        .app => {
            const lhs = term.app.lhs;
            const rhs = term.app.rhs;

            return switch (lhs.*) {
                .abs => {
                    if (rhs.isVal()) {
                        shift(rhs, 1, 0);
                        lhs.abs.term.print(ctx);
                        subst(lhs.abs.term, 0, rhs, 0);
                        // shift(lhs.abs.term, -1, 0);
                        // lhs.abs.term.print(ctx);
                        // this copy could probably be eliminated
                        term.* = lhs.abs.term.*;
                        gpa.destroy(rhs);
                        gpa.destroy(lhs);
                        gpa.destroy(lhs.abs.term);
                        return true;
                    } else if (lhs.isVal()) {
                        _ = try evalStep(gpa, rhs, ctx);
                        return true;
                    } else {
                        _ = try evalStep(gpa, lhs, ctx);
                        return true;
                    }
                },
                else => false,
            };
        },
        .ty_abs => return false,
        .ty_app => {
            switch (term.ty_app.term.*) {
                .ty_abs => {
                    var ty = term.ty_app.ty;
                    const inner_term = term.ty_app.term;
                    tychk.tyShift(&ty, 1, 0);
                    tyTermSubst(inner_term, 0, ty, 0);
                    tychk.tyShift(&ty, -1, 0);
                    return true;
                },
                else => {
                    _ = try evalStep(gpa, term.ty_app.term, ctx);
                    return true;
                },
            }
        },
    }
}

test "eval step var" {
    const gpa = std.testing.allocator;

    const ref_term = Term{ .variable = 0 };
    const term = try gpa.create(Term);
    term.* = Term{ .variable = 0 };
    _ = try evalStep(
        gpa,
        term,
        &Ctx{ .name = "x", .binding = .name, .pred = null },
    );
    try std.testing.expectEqualDeep(&ref_term, term);
    gpa.destroy(term);
}

pub fn eval(gpa: Allocator, term: *Term, ctx: ?*const Ctx) !void {
    while (try evalStep(gpa, term, ctx)) {}
}

test "eval" {
    const gpa = std.testing.allocator;

    const arg = try gpa.create(Term);
    arg.* = Term{ .variable = 0 };

    const id_body = try gpa.create(Term);
    id_body.* = Term{ .variable = 0 };

    const id = try gpa.create(Term);
    id.* = Term{ .abs = .{ .name_hint = "x", .ty = .{ .variable = 1 }, .term = id_body } };

    const term = try gpa.create(Term);
    term.* = Term{ .app = .{ .lhs = id, .rhs = arg } };

    try eval(
        gpa,
        term,
        &Ctx{
            .name = "y",
            .binding = .name,
            .pred = &Ctx{ .name = "T", .binding = .ty_var, .pred = null },
        },
    );

    try std.testing.expectEqualDeep(&Term{ .variable = 0 }, term);
    gpa.destroy(term);
}
