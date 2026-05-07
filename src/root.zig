//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const std_options: std.Options = .{
    .fmt_max_depth = 127,
};

pub const Label: type = u64;
pub const FTy: type = union(enum) {
    ty_variable: Label,
    function: struct {
        from: *const FTy,
        to: *const FTy,
    },
    universal: struct {
        label: Label,
        ty: *const FTy,
    },

    fn replace(self: FTy, label: Label, ty: FTy) FTy {
        switch (self) {
            .ty_variable => |l| {
                if (l == label) return ty else return self;
            },
            else => return self,
        }
    }

    pub fn format(self: FTy, writer: *std.io.Writer) !void {
        switch (self) {
            .ty_variable => try writer.print("{}", .{self.ty_variable}),
            .function => try writer.print("{f} -> {f}", .{ self.function.from, self.function.to }),
            .universal => try writer.print("∀{}.{f}", .{ self.universal.label, self.universal.ty }),
        }
    }
};
pub const Term = union(enum) {
    variable: Label,
    abstract: struct {
        name: Label,
        ty: FTy,
        term: *const Term,
    },
    application: struct {
        lhs: *const Term,
        rhs: *const Term,
    },
    type_abstraction: struct {
        label: Label,
        term: *const Term,
    },
    type_application: struct {
        term: *const Term,
        ty: FTy,
    },

    pub fn format(
        self: Term,
        writer: *std.io.Writer,
    ) !void {
        switch (self) {
            .variable => try writer.print("{}", .{self.variable}),
            .abstract => |t| try writer.print("λ{}:{f}.({f})", .{ t.name, t.ty, t.term }),
            .application => |t| try writer.print("({f} {f})", .{ t.lhs, t.rhs }),
            // .type_abstraction => |t| try writer.print("λ{}.({f})", .{ t.label, t.term }),
            .type_abstraction => |t| try writer.print("Λ{}.({f})", .{ t.label, t.term }),
            .type_application => |t| try writer.print("{f} [{f}]", .{ t.term, t.ty }),
        }
    }
};

// pub const Context = []const (union(enum) {
//     term: struct { label: Label, ty: FTy },
//     ty: struct { label: Label },
// });
pub const Context = std.AutoHashMap(Label, union(enum) { term: FTy, ty: struct {} });

pub fn replace(term: Term, target: Label, val: Term) Term {
    return switch (term) {
        .variable => val,
        .abstract => |t| {
            return Term{ .abstract = .{ .name = t.name, .ty = t.ty, .term = &replace(t.term.*, target, val) } };
        },
        .application => |t| {
            return Term{ .application = .{ .lhs = &replace(t.lhs.*, target, val), .rhs = &replace(t.rhs.*, target, val) } };
        },
        .type_abstraction => |t| {
            return Term{ .type_abstraction = .{ .label = t.label, .term = &replace(t.term.*, target, val) } };
        },
        .type_application => |t| {
            return Term{ .type_application = .{ .term = &replace(t.term.*, target, val), .ty = t.ty } };
        },
    };
}

pub fn tyReplace(allocator: Allocator, term: Term, target: Label, val: FTy) !Term {
    return switch (term) {
        .variable => term,
        .abstract => |t| {
            const recurse_ptr = try allocator.create(Term);
            recurse_ptr.* = try tyReplace(allocator, t.term.*, target, val);
            return Term{ .abstract = .{ .name = t.name, .ty = t.ty.replace(target, val), .term = recurse_ptr } };
        },
        .application => |t| {
            const recurse_ptr: []Term = try allocator.alloc(Term, 2);
            recurse_ptr[0] = try tyReplace(allocator, t.lhs.*, target, val);
            recurse_ptr[1] = try tyReplace(allocator, t.rhs.*, target, val);
            return Term{ .application = .{ .lhs = &recurse_ptr[0], .rhs = &recurse_ptr[1] } };
        },
        .type_abstraction => |t| {
            if (t.label == target)
                return tyReplace(allocator, t.term.*, target, val)
            else {
                const recurse_ptr = try allocator.create(Term);
                recurse_ptr.* = try tyReplace(allocator, t.term.*, target, val);
                return Term{ .type_abstraction = .{ .label = t.label, .term = recurse_ptr } };
            }
        },
        .type_application => |t| {
            const recurse_ptr = try allocator.create(Term);
            recurse_ptr.* = try tyReplace(allocator, t.term.*, target, val);
            return Term{ .type_application = .{ .term = recurse_ptr, .ty = t.ty.replace(target, val) } };
        },
    };
}

pub fn reduce(allocator: Allocator, term: Term) !Term {
    std.debug.print("{f}\n", .{term});
    switch (term) {
        .variable => return term,
        .abstract => return term,
        .application => |t| {
            const lhs = t.lhs.*;
            const rhs = t.rhs.*;

            const reduced_lhs = try reduce(allocator, lhs);
            const reduced_rhs = try reduce(allocator, rhs);
            switch (reduced_lhs) {
                .abstract => |left_term| {
                    const name = left_term.name;
                    const inner = left_term.term.*;
                    return replace(inner, name, reduced_rhs);
                },
                else => return term,
            }
        },
        .type_abstraction => return term,
        .type_application => |t| {
            return switch (t.term.*) {
                .type_abstraction => |ta| {
                    return tyReplace(allocator, ta.term.*, ta.label, t.ty);
                },
                else => return term,
            };
        },
    }
}

test "reduce id" {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    const term = Term{ .application = .{ .lhs = &Term{ .abstract = .{ .name = 1, .ty = FTy{ .ty_variable = 2 }, .term = &Term{ .variable = 1 } } }, .rhs = &Term{ .variable = 42 } } };
    std.debug.print("{f}\n", .{term});
    const reduced = try reduce(allocator.allocator(), term);
    std.debug.print("{f}\n", .{reduced});
    const expected = Term{ .variable = 42 };
    try std.testing.expectEqual(@intFromEnum(expected), @intFromEnum(reduced));
    try std.testing.expectEqual(expected.variable, reduced.variable);
}

test "double reduce id" {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    const id = Term{ .abstract = .{
        .name = 1,
        .ty = FTy{ .ty_variable = 2 },
        .term = &Term{ .variable = 1 },
    } };
    const id2 = Term{ .abstract = .{
        .name = 3,
        .ty = FTy{ .ty_variable = 2 },
        .term = &Term{ .variable = 3 },
    } };
    const doubleId = Term{ .application = .{ .lhs = &id, .rhs = &id2 } };
    std.debug.print("double id {f}\n", .{doubleId});
    const reducedIds = try reduce(allocator.allocator(), doubleId);
    std.debug.print("reduced ids {f}\n", .{reducedIds});
    const appliedDoubleId = Term{ .application = .{ .lhs = &doubleId, .rhs = &Term{ .variable = 67 } } };
    std.debug.print("appd double id {f}\n", .{appliedDoubleId});
    const reducedApplication = try reduce(allocator.allocator(), appliedDoubleId);
    std.debug.print("reduced application {f}\n", .{reducedApplication});
    try std.testing.expectEqual(Term{ .variable = 67 }, reducedApplication);
}

/// Find the type for a given term
/// Uses a context to know the type of type variables
pub fn tyReduce(allocator: Allocator, term: *const Term, ctx: *Context) !FTy {
    switch (term.*) {
        .variable => |label| if (ctx.get(label)) |binding| {
            return switch (binding) {
                .term => binding.term,
                .ty => FTy{ .ty_variable = term.variable },
            };
        } else {
            std.debug.print("{f}\n", .{term});
            return error.UnderspecifiedType;
        },
        .abstract => |t| { // use T-Abs
            const alloc = try allocator.alloc(FTy, 2);
            alloc[0] = t.ty;
            try ctx.put(t.name, .{ .term = t.ty });
            alloc[1] = try tyReduce(allocator, t.term, ctx);
            return FTy{ .function = .{ .from = &alloc[0], .to = &alloc[1] } };
        },
        .application => |t| { // use T-App
            const lhs_ty = try tyReduce(allocator, t.lhs, ctx);
            const rhs_ty = try tyReduce(allocator, t.rhs, ctx);
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
        .type_abstraction => |t| {
            try ctx.put(t.label, .{ .ty = .{} });
            return tyReduce(allocator, t.term, ctx);
        },
        .type_application => |t| {
            return switch (t.term.*) {
                .type_abstraction => |t_inner| {
                    const alloc = try allocator.create(Term);
                    alloc.* = try tyReplace(allocator, t_inner.term.*, t_inner.label, t.ty);
                    return try tyReduce(allocator, alloc, ctx);
                },
                else => error.TypeMalformedApp,
            };
        },
    }
}

test "tychk id" {
    const term = Term{ .type_abstraction = .{
        .label = 2,
        .term = &Term{ .abstract = .{
            .name = 1,
            .ty = FTy{ .ty_variable = 2 },
            .term = &Term{ .variable = 1 },
        } },
    } };
    std.debug.print("{f}\n", .{term});
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    const res = try tyReduce(allocator, &term, &gamma);
    std.debug.print("{f}\n", .{res});
    try std.testing.expectEqualDeep(
        FTy{ .function = .{
            .from = &FTy{ .ty_variable = 2 },
            .to = &FTy{ .ty_variable = 2 },
        } },
        res,
    );
}
