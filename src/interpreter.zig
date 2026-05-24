const std = @import("std");
const core = @import("core.zig");
const Term = core.Term;
const Ctx = core.Ctx;
const Allocator = std.mem.Allocator;

fn shift(term: *Term, delta: i64, cutoff: u32) void {
    switch (term.*) {
        .variable => {
            if (term.variable >= cutoff)
                term.variable = @intCast(@as(i32, @intCast(term.*.variable)) + delta);
        },
        .abs => shift(term.abs.term, delta, cutoff + 1),
        .app => {
            shift(term.app.lhs, delta, cutoff);
            shift(term.app.rhs, delta, cutoff);
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
                        const new_rhs = try evalStep(gpa, rhs, ctx);
                        return new_rhs;
                    } else {
                        const new_lhs = try evalStep(gpa, lhs, ctx);
                        return new_lhs;
                    }
                },
                else => false,
            };
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
    id.* = Term{ .abs = .{ .name_hint = "x", .term = id_body } };

    const term = try gpa.create(Term);
    term.* = Term{ .app = .{ .lhs = id, .rhs = arg } };

    try eval(
        gpa,
        term,
        &Ctx{ .name = "y", .binding = .name, .pred = null },
    );

    try std.testing.expectEqualDeep(&Term{ .variable = 0 }, term);
    gpa.destroy(term);
}
