//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

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
            .function => try writer.print("{f} -> {f}", .{self.function.from, self.function.to}),
            .universal => try writer.print("∀{}.{f}", .{self.universal.label, self.universal.ty}),
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
            .application => |t| try writer.print("({f} {f})", .{t.lhs, t.rhs}),
            .type_abstraction => |t| try writer.print("λ{}.({f})", .{t.label, t.term}),
            .type_application => |t| try writer.print("{f} [{f}]", .{t.term, t.ty}),
        }
    }
};

pub const Context = []const (union(enum) {
    term: struct { label: Label, ty: FTy },
    ty: struct { label: Label },
});

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

pub fn tyReplace(term: Term, target: Label, val: FTy) Term {
    return switch (term) {
        .variable => term,
        .abstract => |t| {
            return Term{ .abstract = .{ .name = t.name, .ty = t.ty.replace(target, val), .term = &tyReplace(t.term.*, target, val) } };
        },
        .application => |t| {
            return Term{ .application = .{ .lhs = &tyReplace(t.lhs.*, target, val), .rhs = &tyReplace(t.rhs.*, target, val) } };
        },
        .type_abstraction => |t| {
            if (t.label == target)
                return tyReplace(t.term.*, target, val)
            else
                return Term{ .type_abstraction = .{ .label = t.label, .term = &tyReplace(t.term.*, target, val) } };
        },
        .type_application => |t| {
            return Term{ .type_application = .{ .term = &tyReplace(t.term.*, target, val), .ty = t.ty.replace(target, val) } };
        },
    };
}

pub fn reduce(term: Term) Term {
    std.debug.print("{f}\n", .{term});
    switch (term) {
        .variable => return term,
        .abstract => return term,
        .application => |t| {
            const lhs = t.lhs.*;
            const rhs = t.rhs.*;

            const reduced_lhs = reduce(lhs);
            const reduced_rhs = reduce(rhs);
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
                    return tyReplace(ta.term.*, ta.label, t.ty);
                },
                else => return term,
            };
        },
    }
}

test "reduce id" {
    const term = Term{ .application = .{ .lhs = &Term{ .abstract = .{ .name = 1, .ty = FTy{ .ty_variable = 2 }, .term = &Term{ .variable = 1 } } }, .rhs = &Term{ .variable = 42 } } };
    std.debug.print("{f}\n", .{term});
    const reduced = reduce(term);
    std.debug.print("{f}\n", .{reduced});
    const expected = Term{ .variable = 42 };
    try std.testing.expectEqual(@intFromEnum(expected), @intFromEnum(reduced));
    try std.testing.expectEqual(expected.variable, reduced.variable);
}

test "double reduce id" {
    const id = Term{ .abstract = .{ .name = 1, .ty = FTy{ .ty_variable = 2 }, .term = &Term{ .variable = 1 } } };
    const id2 = Term{ .abstract = .{ .name = 3, .ty = FTy{ .ty_variable = 2 }, .term = &Term{ .variable = 3 } } };
    const doubleId = Term{ .application = .{ .lhs = &id, .rhs = &id2 } };
    std.debug.print("double id {f}\n", .{doubleId});
    const reducedIds = reduce(doubleId);
    std.debug.print("reduced ids {f}\n", .{reducedIds});
    const appliedDoubleId = Term{ .application = .{ .lhs = &doubleId, .rhs = &Term{ .variable = 67 } } };
    std.debug.print("appd double id {f}\n", .{appliedDoubleId});
    const reducedApplication = reduce(appliedDoubleId);
    std.debug.print("reduced application {f}\n", .{reducedApplication});
}
