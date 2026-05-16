//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const std_options: std.Options = .{
    .fmt_max_depth = 127,
};

pub const Label: type = []const u8;
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
                if (std.mem.eql(u8, l, label)) return ty else return self;
            },
            else => return self,
        }
    }

    pub fn format(self: FTy, writer: *std.Io.Writer) !void {
        switch (self) {
            .ty_variable => try writer.print("{any}", .{self.ty_variable}),
            .function => try writer.print("{f} -> {f}", .{ self.function.from, self.function.to }),
            .universal => try writer.print("∀{any}.{f}", .{ self.universal.label, self.universal.ty }),
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
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .variable => try writer.print("{any}", .{self.variable}),
            .abstract => |t| try writer.print("λ{any}:{f}.({f})", .{ t.name, t.ty, t.term }),
            .application => |t| try writer.print("({f} {f})", .{ t.lhs, t.rhs }),
            // .type_abstraction => |t| try writer.print("λ{}.({f})", .{ t.label, t.term }),
            .type_abstraction => |t| try writer.print("Λ{any}.({f})", .{ t.label, t.term }),
            .type_application => |t| try writer.print("{f} [{f}]", .{ t.term, t.ty }),
        }
    }
};

pub const Context = std.StringHashMap(union(enum) { term: FTy, ty: struct {} });

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
            if (std.mem.eql(u8, t.label, target))
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
    const term = Term{
        .application = .{
            .lhs = &Term{ .abstract = .{
                .name = &.{1},
                .ty = FTy{ .ty_variable = &.{2} },
                .term = &Term{ .variable = &.{1} },
            } },
            .rhs = &Term{ .variable = &.{42} },
        },
    };
    std.debug.print("{f}\n", .{term});
    const reduced = try reduce(allocator.allocator(), term);
    std.debug.print("{f}\n", .{reduced});
    const expected = Term{ .variable = &.{42} };
    try std.testing.expectEqual(@intFromEnum(expected), @intFromEnum(reduced));
    try std.testing.expectEqual(expected.variable, reduced.variable);
}

test "double reduce id" {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    const id = Term{ .abstract = .{
        .name = &.{1},
        .ty = FTy{ .ty_variable = &.{2} },
        .term = &Term{ .variable = &.{1} },
    } };
    const id2 = Term{ .abstract = .{
        .name = &.{3},
        .ty = FTy{ .ty_variable = &.{2} },
        .term = &Term{ .variable = &.{3} },
    } };
    const doubleId = Term{ .application = .{ .lhs = &id, .rhs = &id2 } };
    std.debug.print("double id {f}\n", .{doubleId});
    const reducedIds = try reduce(allocator.allocator(), doubleId);
    std.debug.print("reduced ids {f}\n", .{reducedIds});
    const appliedDoubleId = Term{ .application = .{ .lhs = &doubleId, .rhs = &Term{ .variable = &.{67} } } };
    std.debug.print("appd double id {f}\n", .{appliedDoubleId});
    const reducedApplication = try reduce(allocator.allocator(), appliedDoubleId);
    std.debug.print("reduced application {f}\n", .{reducedApplication});
    try std.testing.expectEqual(Term{ .variable = &.{67} }, reducedApplication);
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
            const alloc = try allocator.create(FTy);
            alloc.* = try tyReduce(allocator, t.term, ctx);
            return FTy{ .universal = .{
                .label = t.label,
                .ty = alloc,
            } };
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
        .label = &.{2},
        .term = &Term{ .abstract = .{
            .name = &.{1},
            .ty = FTy{ .ty_variable = &.{2} },
            .term = &Term{ .variable = &.{1} },
        } },
    } };
    std.debug.print("{f}\n", .{term});
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    const res = try tyReduce(allocator, &term, &gamma);
    std.debug.print("{f}\n", .{res});
    try std.testing.expectEqualDeep(
        FTy{ .universal = .{
            .label = &.{2},
            .ty = &FTy{ .function = .{
                .from = &FTy{ .ty_variable = &.{2} },
                .to = &FTy{ .ty_variable = &.{2} },
            } },
        } },
        res,
    );
}

test "tychk id app" {
    const term = Term{ .application = .{
        .lhs = &Term{ .abstract = .{
            .name = &.{1},
            .ty = FTy{ .ty_variable = &.{2} },
            .term = &Term{ .variable = &.{1} },
        } },
        .rhs = &Term{
            .variable = &.{42},
        },
    } };
    std.debug.print("{f}\n", .{term});
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    try gamma.put(&.{42}, .{ .term = FTy{ .ty_variable = &.{2} } });
    const res = try tyReduce(allocator, &term, &gamma);
    std.debug.print("{f}\n", .{res});
    try std.testing.expectEqualDeep(
        FTy{ .ty_variable = &.{2} },
        res,
    );
}

test "tychk forall" {
    const simple_term = Term{ .type_abstraction = .{
        .label = &.{1},
        .term = &Term{ .variable = &.{2} },
    } };
    std.debug.print("{f}\n", .{simple_term});

    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();
    var gamma = Context.init(allocator);
    try gamma.put(&.{2}, .{ .term = FTy{ .ty_variable = &.{3} } });

    try std.testing.expectEqualDeep(
        FTy{ .universal = .{ .label = &.{1}, .ty = &FTy{ .ty_variable = &.{3} } } },
        tyReduce(allocator, &simple_term, &gamma),
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

fn parseLabel(allocator: Allocator, str: *std.unicode.Utf8Iterator, term: []const u8) ![]const u8 {
    // init to one word of cap
    var label: std.ArrayList(u8) = try .initCapacity(allocator, 8);
    defer label.deinit(allocator);
    while (str.nextCodepointSlice()) |sl| {
        if (std.mem.startsWith(u8, str.bytes[str.i - 1..], term)) break;
        try label.appendSlice(allocator, sl);
    }
    for (0..term.len - 1) |_| { // we assume the terminator is byte valid
        _ = str.nextCodepoint();
    }
    return try label.toOwnedSlice(allocator);
}

test "parse label" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();

    const WhyIsZigLikeThis = struct {
        fn chk(
            allocator: Allocator,
            lbl: []const u8,
            term: []const u8,
            tail: []const u8,
        ) !void {
            const cons = try std.mem.concat(allocator, u8, &.{ lbl, term, tail });
            var uni_v = try std.unicode.Utf8View.init(cons);
            var iter = uni_v.iterator();
            const res = try parseLabel(
                allocator,
                &iter,
                term,
            );
            std.debug.print(
                "expected {s} actual {s} from {s} tail is {s}\n",
                .{ lbl, res, cons, iter.bytes[iter.i..] },
            );
            std.testing.expectEqualDeep(lbl, res) catch |err| {
                return err;
            };
            try std.testing.expectEqualDeep(tail, iter.bytes[iter.i..]);
        }
    };

    try WhyIsZigLikeThis.chk(alloc, "a", ".", "b");
    try WhyIsZigLikeThis.chk(alloc, "b", ".", "b");
    try WhyIsZigLikeThis.chk(alloc, "aaaaaaaaaaaa", ".", "b");
    try WhyIsZigLikeThis.chk(alloc, "aaaaaaaaaaaa", ".", "bbbbb");
    try WhyIsZigLikeThis.chk(alloc, "arhyiglabsdluighbh", ".", "bbbbb");
    try WhyIsZigLikeThis.chk(alloc, "1", ".", "bbbbb");
    try WhyIsZigLikeThis.chk(alloc, "145678765", ".", "bbbbb");
    try WhyIsZigLikeThis.chk(alloc, "14^&*@(678765", ".", "bbbbb");

    try WhyIsZigLikeThis.chk(alloc, "a", "->", "b");
    try WhyIsZigLikeThis.chk(alloc, "b", "->", "b");
    try WhyIsZigLikeThis.chk(alloc, "aaaaaaaaaaaa", "->", "b");
    try WhyIsZigLikeThis.chk(alloc, "aaaaaaaaaaaa", "->", "bbbbb");
    try WhyIsZigLikeThis.chk(alloc, "a-", "->", "b");
    try WhyIsZigLikeThis.chk(alloc, "b-", "->", "b");
    try WhyIsZigLikeThis.chk(alloc, "a>", "->", "b");
    try WhyIsZigLikeThis.chk(alloc, "b>", "->", "b");
}

// parse type
// either {label}, {label->label}, or {forall label, recurse}
fn parseTy(
    allocator: Allocator,
    str: *std.unicode.Utf8Iterator,
    term: []const u8,
) !*const FTy {
    const forall = "∀";

    const first_term = try (std.mem.indexOfPos(
        u8,
        str.bytes,
        0,
        term,
    ) orelse error.NoTerm);
    const maybe_first_forall = std.mem.indexOfPos(
        u8,
        str.bytes[str.i..first_term],
        0,
        forall,
    );
    const maybe_first_arrow = std.mem.indexOfPos(
        u8,
        str.bytes[str.i..first_term],
        0,
        "->",
    );
    std.debug.print("arr {any} {s}\n", .{ maybe_first_arrow, str.bytes[str.i..] });
    if (maybe_first_arrow) |_| {
        const alloc = try allocator.create(FTy);
        const lhs = try parseTy(allocator, str, "->");
        std.debug.print("arr {s}\n", .{str.bytes[str.i..]});
        try std.testing.expect(false);
        const rhs = try parseTy(allocator, str, term);
        alloc.* = FTy{ .function = .{ .from = lhs, .to = rhs } };
        return alloc;
    }
    if (maybe_first_forall) |first_forall| {
        // if this is a universal type, it should start with forall
        // and if it has forall, it should be universal
        try std.testing.expect(false);
        if (first_forall > 0) {
            return error.InvalidCharTyName;
        }
        _ = str.nextCodepoint();
        const label = try parseLabel(allocator, str, ".");
        const rhs = try parseTy(allocator, str, term);
        const alloc = try allocator.create(FTy);
        alloc.* = FTy{ .universal = .{
            .label = label,
            .ty = rhs,
        } };
        return alloc;
    }
    // else its a type variable
    const alloc = try allocator.create(FTy);
    alloc.* = FTy{ .ty_variable = try parseLabel(allocator, str, term) };
    std.debug.print("var {s} term {s}\n", .{ alloc.*.ty_variable, term });
    return alloc;
}

test "test type parsing var" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    var str = ((try std.unicode.Utf8View.init("a.")).iterator());
    try std.testing.expectEqualDeep(
        &FTy{ .ty_variable = "a" },
        parseTy(
            allocator,
            &str,
            ".",
        ),
    );
}

test "test type parsing func" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    var str = ((try std.unicode.Utf8View.init("a->b.")).iterator());
    const res = try parseTy(
            allocator,
            &str,
            ".",
        );
    std.debug.print("{f}\n", .{res});
    try std.testing.expectEqualDeep(
        &FTy{ .function = .{
            .from = &FTy{ .ty_variable = "a" },
            .to = &FTy{ .ty_variable = "b" },
        } },
        res,
    );
}

test "test type parsing univ" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    var str = ((try std.unicode.Utf8View.init("∀a.b.")).iterator());
    try std.testing.expectEqualDeep(
        &FTy{ .universal = .{
            .label = "a",
            .ty = &FTy{ .ty_variable = "b" },
        } },
        parseTy(
            allocator,
            &str,
            ".",
        ),
    );
}

test "test type parsing complex" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    var str = ((try std.unicode.Utf8View.init("∀a.a->b.")).iterator());
    try std.testing.expectEqualDeep(
        &FTy{ .universal = .{
            .label = "a",
            .ty = &FTy{ .function = .{
                .from = &FTy{ .ty_variable = "a" },
                .to = &FTy{ .ty_variable = "b" },
            } },
        } },
        parseTy(
            allocator,
            &str,
            ".",
        ),
    );
}

const ParseState = union(enum) {
    Start,
    Abs,
    TyAbs,
};

pub fn parse(gpa: Allocator, state: ParseState, str: *std.unicode.Utf8Iterator) !*const Term {
    const lambda = 'λ';
    const big_lambda = 'Λ';

    switch (state) {
        .Start => {
            const char = str.nextCodepoint() orelse return error.OutOfChars;

            return switch (char) {
                lambda => return parse(gpa, .Abs, str),
                big_lambda => return parse(gpa, .TyAbs, str),
                else => {
                    str.i -= 1;
                    // const maybe_last_space = std.mem.lastIndexOfScalar(u8, str.bytes, ' ');
                    // if (maybe_last_space) |last_space| {
                    //     // this is an application of some sort

                    // }
                    // this is just a term
                    const label = try parseLabel(gpa, str, &.{});
                    const alloc = try gpa.create(Term);
                    alloc.* = Term{ .variable = label };
                    return alloc;
                },
            };
        },
        .Abs => {
            const label = try parseLabel(gpa, str, &.{':'});
            const ty = try parseTy(gpa, str, ".");
            const term = try parse(gpa, .Start, str);
            const alloc = try gpa.create(Term);
            alloc.* = Term{ .abstract = .{
                .name = label,
                .ty = ty.*,
                .term = term,
            } };
            return alloc;
        },
        else => return error.TODO,
    }
    return error.Fallthrough;
}

test "parsing" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    const str = "λaaaaaaa:aaaaaaa.c";
    var iter = (try std.unicode.Utf8View.init(str)).iterator();
    const parsed = try parse(allocator, .Start, &iter);
    std.debug.print("{f}\n", .{parsed});
}

// test "parsing2" {
//     var dba: std.heap.DebugAllocator(.{}) = .init;
//     const allocator = dba.allocator();

//     var str = (try std.unicode.Utf8View.init("λaaaaaaa:aaaaaaa.c")).iterator();
//     const parsed = try parse(allocator, .Start, &str);
//     std.debug.print("{f}\n", .{parsed});
// }
