//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core.zig");
const FTy = core.FTy;
const Term = core.Term;
const Kind = core.Kind;
const Label = core.Label;

pub const std_options: std.Options = .{
    .fmt_max_depth = 127,
};

pub const Context = std.StringHashMap(union(enum) { term: FTy, ty: struct {} });

pub fn replace(term: Term, target: Label, val: Term) Term {
    return switch (term) {
        .variable => val,
        .abs => |t| {
            return Term{ .abs = .{ .name = t.name, .ty = t.ty, .term = &replace(t.term.*, target, val) } };
        },
        .app => |t| {
            return Term{ .app = .{ .lhs = &replace(t.lhs.*, target, val), .rhs = &replace(t.rhs.*, target, val) } };
        },
        .ty_abs => |t| {
            return Term{ .ty_abs = .{ .label = t.label, .term = &replace(t.term.*, target, val) } };
        },
        .ty_app => |t| {
            return Term{ .ty_app = .{ .term = &replace(t.term.*, target, val), .ty = t.ty } };
        },
    };
}

pub fn tyReplace(gpa: Allocator, term: Term, target: Label, val: FTy) !Term {
    return switch (term) {
        .variable => term,
        .abs => |t| {
            const recurse_ptr = try gpa.create(Term);
            recurse_ptr.* = try tyReplace(gpa, t.term.*, target, val);
            return Term{ .abs = .{ .name = t.name, .ty = t.ty.replace(target, val), .term = recurse_ptr } };
        },
        .app => |t| {
            const recurse_ptr: []Term = try gpa.alloc(Term, 2);
            recurse_ptr[0] = try tyReplace(gpa, t.lhs.*, target, val);
            recurse_ptr[1] = try tyReplace(gpa, t.rhs.*, target, val);
            return Term{ .app = .{ .lhs = &recurse_ptr[0], .rhs = &recurse_ptr[1] } };
        },
        .ty_abs => |t| {
            if (std.mem.eql(u8, t.label, target))
                return tyReplace(gpa, t.term.*, target, val)
            else {
                const recurse_ptr = try gpa.create(Term);
                recurse_ptr.* = try tyReplace(gpa, t.term.*, target, val);
                return Term{ .ty_abs = .{ .label = t.label, .term = recurse_ptr } };
            }
        },
        .ty_app => |t| {
            const recurse_ptr = try gpa.create(Term);
            recurse_ptr.* = try tyReplace(gpa, t.term.*, target, val);
            return Term{ .ty_app = .{ .term = recurse_ptr, .ty = t.ty.replace(target, val) } };
        },
    };
}

pub fn reduce(gpa: Allocator, term: Term) !Term {
    errdefer std.debug.print("\n{f}\n", .{term});
    switch (term) {
        .variable => return term,
        .abs => return term,
        .app => |t| {
            const lhs = t.lhs.*;
            const rhs = t.rhs.*;

            const reduced_lhs = try reduce(gpa, lhs);
            const reduced_rhs = try reduce(gpa, rhs);
            switch (reduced_lhs) {
                .abs => |left_term| {
                    const name = left_term.name;
                    const inner = left_term.term.*;
                    return replace(inner, name, reduced_rhs);
                },
                else => return term,
            }
        },
        .ty_abs => return term,
        .ty_app => |t| {
            return switch (t.term.*) {
                .ty_abs => |ta| {
                    const replaced = try tyReplace(
                        gpa,
                        ta.term.*,
                        ta.label,
                        t.ty,
                    );
                    return reduce(gpa, replaced);
                },
                else => return term,
            };
        },
    }
}

test "reduce id" {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    const term = Term{
        .app = .{
            .lhs = &Term{ .abs = .{
                .name = &.{1},
                .ty = FTy{ .variable = &.{2} },
                .term = &Term{ .variable = &.{1} },
            } },
            .rhs = &Term{ .variable = &.{42} },
        },
    };
    errdefer std.debug.print("\n{f}\n", .{term});
    const reduced = try reduce(allocator.allocator(), term);
    errdefer std.debug.print("\n{f}\n", .{reduced});
    const expected = Term{ .variable = &.{42} };
    try std.testing.expectEqual(@intFromEnum(expected), @intFromEnum(reduced));
    try std.testing.expectEqual(expected.variable, reduced.variable);
}

test "double reduce id" {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    const id = Term{ .abs = .{
        .name = &.{1},
        .ty = FTy{ .variable = &.{2} },
        .term = &Term{ .variable = &.{1} },
    } };
    const id2 = Term{ .abs = .{
        .name = &.{3},
        .ty = FTy{ .variable = &.{2} },
        .term = &Term{ .variable = &.{3} },
    } };
    const doubleId = Term{ .app = .{ .lhs = &id, .rhs = &id2 } };
    errdefer std.debug.print("\ndouble id {f}\n", .{doubleId});
    const reducedIds = try reduce(allocator.allocator(), doubleId);
    errdefer std.debug.print("\nreduced ids {f}\n", .{reducedIds});
    const appliedDoubleId = Term{ .app = .{ .lhs = &doubleId, .rhs = &Term{ .variable = &.{67} } } };
    errdefer std.debug.print("\nappd double id {f}\n", .{appliedDoubleId});
    const reducedApplication = try reduce(allocator.allocator(), appliedDoubleId);
    errdefer std.debug.print("\nreduced application {f}\n", .{reducedApplication});
    try std.testing.expectEqual(Term{ .variable = &.{67} }, reducedApplication);
}

/// Find the type for a given term
/// Uses a context to know the type of type variables
pub fn typeOf(gpa: Allocator, term: *const Term, ctx: *Context) !FTy {
    switch (term.*) {
        .variable => |label| if (ctx.get(label)) |binding| {
            return switch (binding) {
                .term => binding.term,
                .ty => FTy{ .variable = term.variable },
            };
        } else {
            errdefer std.debug.print("\n{f}\n", .{term});
            return error.UnderspecifiedType;
        },
        .abs => |t| { // use T-Abs
            const alloc = try gpa.alloc(FTy, 2);
            alloc[0] = t.ty;
            try ctx.put(t.name, .{ .term = t.ty });
            alloc[1] = try typeOf(gpa, t.term, ctx);
            return FTy{ .function = .{ .from = &alloc[0], .to = &alloc[1] } };
        },
        .app => |t| { // use T-App
            const lhs_ty = try typeOf(gpa, t.lhs, ctx);
            const rhs_ty = try typeOf(gpa, t.rhs, ctx);
            switch (lhs_ty) {
                .function => |lhs_f| {
                    if (std.meta.eql(lhs_f.from.*, rhs_ty)) {
                        return lhs_f.to.*;
                    } else {
                        return error.MalformedArgument;
                    }
                },
                else => return error.NonfunctionApplied,
            }
        },
        .ty_abs => |t| {
            try ctx.put(t.label, .{ .ty = .{} });
            const alloc = try gpa.create(FTy);
            alloc.* = try typeOf(gpa, t.term, ctx);
            return FTy{ .universal = .{
                .label = t.label,
                .ty = alloc,
            } };
        },
        .ty_app => |t| {
            return switch (t.term.*) {
                .ty_abs => |t_inner| {
                    const alloc = try gpa.create(Term);
                    alloc.* = try tyReplace(gpa, t_inner.term.*, t_inner.label, t.ty);
                    return try typeOf(gpa, alloc, ctx);
                },
                else => error.TypeMalformedApp,
            };
        },
    }
}

test "tychk id" {
    const term = Term{ .ty_abs = .{
        .label = &.{2},
        .term = &Term{ .abs = .{
            .name = &.{1},
            .ty = FTy{ .variable = &.{2} },
            .term = &Term{ .variable = &.{1} },
        } },
    } };
    errdefer std.debug.print("\n{f}\n", .{term});
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    const res = try typeOf(allocator, &term, &gamma);
    errdefer std.debug.print("\n{f}\n", .{res});
    try std.testing.expectEqualDeep(
        FTy{ .universal = .{
            .label = &.{2},
            .ty = &FTy{ .function = .{
                .from = &FTy{ .variable = &.{2} },
                .to = &FTy{ .variable = &.{2} },
            } },
        } },
        res,
    );
}

test "tychk id app" {
    const term = Term{ .app = .{
        .lhs = &Term{ .abs = .{
            .name = &.{1},
            .ty = FTy{ .variable = &.{2} },
            .term = &Term{ .variable = &.{1} },
        } },
        .rhs = &Term{
            .variable = &.{42},
        },
    } };
    errdefer std.debug.print("\n{f}\n", .{term});
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    try gamma.put(&.{42}, .{ .term = FTy{ .variable = &.{2} } });
    const res = try typeOf(allocator, &term, &gamma);
    errdefer std.debug.print("\n{f}\n", .{res});
    try std.testing.expectEqualDeep(
        FTy{ .variable = &.{2} },
        res,
    );
}

test "tychk forall" {
    const simple_term = Term{ .ty_abs = .{
        .label = &.{1},
        .term = &Term{ .variable = &.{2} },
    } };
    errdefer std.debug.print("\n{f}\n", .{simple_term});

    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    try gamma.put(&.{2}, .{ .term = FTy{ .variable = &.{3} } });

    try std.testing.expectEqualDeep(
        FTy{ .universal = .{ .label = &.{1}, .ty = &FTy{ .variable = &.{3} } } },
        typeOf(allocator, &simple_term, &gamma),
    );
}

// fn strToLabel(str: []const u8) Label {
//     if (str.len < 8) {
//         const buf_size = 67;
//         var buf: [buf_size]u8 = &.{0} ** buf_size;
//         var fba: std.heap.FixedBufferAllocator = .init(&buf);
//         var aa: std.heap.ArenaAllocator = .init(fba.allocator());
//         defer aa.deinit();
//         const zeros: []const u8 = &(.{0} ** 8);
//         const zext = std.mem.concat(
//             aa.allocator(),
//             u8,
//             &.{ str, zeros[0..(8 - str.len)] },
//         ) catch unreachable;
//         return std.mem.bytesToValue(Label, zext);
//     }
//     return std.mem.bytesToValue(Label, str[0..8]);
// }

// test "test strToLabel" {
//     try std.testing.expectEqual(0, strToLabel(""));
//     try std.testing.expectEqual(0x61, strToLabel("a"));
//     try std.testing.expectEqual(0x61616161, strToLabel("aaaa"));
//     try std.testing.expectEqual(0x6161616161616161, strToLabel("aaaaaaaa"));
//     try std.testing.expectEqual(0x6261626162616261, strToLabel("abababab"));
//     try std.testing.expectEqual(0x6161616161616161, strToLabel("aaaaaaaaa"));
// }
