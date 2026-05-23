//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const std_options: std.Options = .{
    .fmt_max_depth = 127,
};

pub const Label: type = []const u8;
pub const FTy: type = union(enum) {
    variable: Label,
    function: struct {
        from: *const FTy,
        to: *const FTy,
    },
    universal: struct {
        label: Label,
        ty: *const FTy,
        kind: Kind,
    },
    op_abs: struct {
        label: Label,
        kind: Kind,
        ty: *const FTy,
    },
    op_app: struct {
        lhs: *const FTy,
        rhs: *const FTy,
    },

    fn replace(self: FTy, label: Label, ty: FTy) FTy {
        switch (self) {
            .variable => |l| {
                if (std.mem.eql(u8, l, label)) return ty else return self;
            },
            else => return self,
        }
    }

    pub fn format(self: FTy, writer: *std.Io.Writer) !void {
        switch (self) {
            .variable => try writer.print("{s}", .{self.variable}),
            .function => try writer.print("{f} -> {f}", .{ self.function.from, self.function.to }),
            .universal => try writer.print("∀{s}.{f}", .{ self.universal.label, self.universal.ty }),
            .op_abs => try writer.print("λ{s}::{f}.{f}", .{
                self.op_abs.label,
                self.op_abs.kind,
                self.op_abs.ty,
            }),
            .op_app => try writer.print("({f} {f})", .{ self.lhs, self.rhs }),
        }
    }
};
pub const Kind = union(enum) {
    proper,
    operator: struct { lhs: *const Kind, rhs: *const Kind },

    pub fn format(self: FTy, writer: *std.Io.Writer) !void {
        switch (self) {
            .proper => try writer.printAsciiChar('*', .{}),
            .operator => try writer.print("({s} => {s})", .{
                self.operator.lhs,
                self.operator.rhs,
            }),
        }
    }
};
pub const Term = union(enum) {
    variable: Label,
    abs: struct {
        name: Label,
        ty: FTy,
        term: *const Term,
    },
    app: struct {
        lhs: *const Term,
        rhs: *const Term,
    },
    ty_abs: struct {
        label: Label,
        kind: Kind,
        term: *const Term,
    },
    ty_app: struct {
        term: *const Term,
        ty: FTy,
    },

    pub fn format(
        self: Term,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .variable => try writer.print("{s}", .{self.variable}),
            .abs => |t| try writer.print("λ{s}:{f}.({f})", .{ t.name, t.ty, t.term }),
            .app => |t| try writer.print("({f} {f})", .{ t.lhs, t.rhs }),
            .ty_abs => |t| try writer.print("Λ{s}::{f}.({f})", .{ t.label, t.kind, t.term }),
            .ty_app => |t| try writer.print("{f} [{f}]", .{ t.term, t.ty }),
        }
    }
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

pub fn tyReplace(allocator: Allocator, term: Term, target: Label, val: FTy) !Term {
    return switch (term) {
        .variable => term,
        .abs => |t| {
            const recurse_ptr = try allocator.create(Term);
            recurse_ptr.* = try tyReplace(allocator, t.term.*, target, val);
            return Term{ .abs = .{ .name = t.name, .ty = t.ty.replace(target, val), .term = recurse_ptr } };
        },
        .app => |t| {
            const recurse_ptr: []Term = try allocator.alloc(Term, 2);
            recurse_ptr[0] = try tyReplace(allocator, t.lhs.*, target, val);
            recurse_ptr[1] = try tyReplace(allocator, t.rhs.*, target, val);
            return Term{ .app = .{ .lhs = &recurse_ptr[0], .rhs = &recurse_ptr[1] } };
        },
        .ty_abs => |t| {
            if (std.mem.eql(u8, t.label, target))
                return tyReplace(allocator, t.term.*, target, val)
            else {
                const recurse_ptr = try allocator.create(Term);
                recurse_ptr.* = try tyReplace(allocator, t.term.*, target, val);
                return Term{ .ty_abs = .{ .label = t.label, .term = recurse_ptr } };
            }
        },
        .ty_app => |t| {
            const recurse_ptr = try allocator.create(Term);
            recurse_ptr.* = try tyReplace(allocator, t.term.*, target, val);
            return Term{ .ty_app = .{ .term = recurse_ptr, .ty = t.ty.replace(target, val) } };
        },
    };
}

pub fn reduce(allocator: Allocator, term: Term) !Term {
    errdefer std.debug.print("\n{f}\n", .{term});
    switch (term) {
        .variable => return term,
        .abs => return term,
        .app => |t| {
            const lhs = t.lhs.*;
            const rhs = t.rhs.*;

            const reduced_lhs = try reduce(allocator, lhs);
            const reduced_rhs = try reduce(allocator, rhs);
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
pub fn tyReduce(allocator: Allocator, term: *const Term, ctx: *Context) !FTy {
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
            const alloc = try allocator.alloc(FTy, 2);
            alloc[0] = t.ty;
            try ctx.put(t.name, .{ .term = t.ty });
            alloc[1] = try tyReduce(allocator, t.term, ctx);
            return FTy{ .function = .{ .from = &alloc[0], .to = &alloc[1] } };
        },
        .app => |t| { // use T-App
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
        .ty_abs => |t| {
            try ctx.put(t.label, .{ .ty = .{} });
            const alloc = try allocator.create(FTy);
            alloc.* = try tyReduce(allocator, t.term, ctx);
            return FTy{ .universal = .{
                .label = t.label,
                .ty = alloc,
            } };
        },
        .ty_app => |t| {
            return switch (t.term.*) {
                .ty_abs => |t_inner| {
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
    const res = try tyReduce(allocator, &term, &gamma);
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
    const res = try tyReduce(allocator, &term, &gamma);
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

fn parseLabel(allocator: Allocator, str: *std.unicode.Utf8Iterator, term: std.unicode.Utf8View) ![]const u8 {
    // init to one word of cap
    var label: std.ArrayList(u8) = try .initCapacity(allocator, 8);
    while (str.nextCodepointSlice()) |sl| {
        if (term.bytes.len > 0 and
            std.mem.startsWith(u8, str.bytes[str.i - 1 ..], term.bytes))
        {
            var term_iter = term.iterator();
            _ = term_iter.nextCodepoint();
            while (term_iter.nextCodepoint()) |_| {
                _ = str.nextCodepoint();
            }
            break;
        }
        try label.appendSlice(allocator, sl);
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
                std.unicode.Utf8View.initUnchecked(term),
            );
            errdefer std.debug.print(
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

    try WhyIsZigLikeThis.chk(alloc, "a", "", "");
}

// parse type
// either {label}, {label->label}, or {forall label, recurse}
fn parseTy(
    allocator: Allocator,
    str: *std.unicode.Utf8Iterator,
    term: []const u8,
) !*const FTy {
    errdefer std.debug.print("\nparsing {s} until {s}\n", .{ str.bytes[str.i..], term });
    const forall = "∀";
    if (std.mem.startsWith(u8, str.bytes[str.i..], forall)) {
        // discard ∀
        _ = str.nextCodepoint();
        const label = try parseLabel(allocator, str, std.unicode.Utf8View.initUnchecked("."));
        const rhs = try parseTy(allocator, str, term);
        const alloc = try allocator.create(FTy);
        alloc.* = FTy{ .universal = .{
            .label = label,
            .ty = rhs,
        } };
        return alloc;
    }

    const first_term = try (std.mem.indexOfPos(
        u8,
        str.bytes[str.i..],
        0,
        term,
    ) orelse error.NoTerm) + str.i;
    const maybe_first_arrow = std.mem.indexOfPos(
        u8,
        str.bytes[str.i..first_term],
        0,
        "->",
    );
    if (maybe_first_arrow) |_| {
        const alloc = try allocator.create(FTy);
        const lhs = try parseTy(allocator, str, "->");
        const rhs = try parseTy(allocator, str, term);
        alloc.* = FTy{ .function = .{ .from = lhs, .to = rhs } };
        return alloc;
    }

    // else its a type variable
    const alloc = try allocator.create(FTy);
    alloc.* = FTy{ .variable = try parseLabel(allocator, str, std.unicode.Utf8View.initUnchecked(term)) };
    return alloc;
}

test "test type parsing var" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    var str = ((try std.unicode.Utf8View.init("a.")).iterator());
    try std.testing.expectEqualDeep(
        &FTy{ .variable = "a" },
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
    errdefer std.debug.print("\n{f}\n", .{res});
    try std.testing.expectEqualDeep(
        &FTy{ .function = .{
            .from = &FTy{ .variable = "a" },
            .to = &FTy{ .variable = "b" },
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
            .ty = &FTy{ .variable = "b" },
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
                .from = &FTy{ .variable = "a" },
                .to = &FTy{ .variable = "b" },
            } },
        } },
        parseTy(
            allocator,
            &str,
            ".",
        ),
    );
}

pub fn parse(gpa: Allocator, str: *std.unicode.Utf8Iterator) !*const Term {
    std.debug.print("parsing {s}\n", .{str.bytes[str.i..]});
    const lambda = 'λ';
    const big_lambda = 'Λ';

    const char_sl = str.peek(1);
    if (char_sl.len == 0) return error.OutOfChars;
    const char: u21 = try std.unicode.utf8Decode(char_sl);

    const maybe_last_space = std.mem.lastIndexOfScalar(
        u8,
        str.bytes[str.i..],
        ' ',
    );
    if (maybe_last_space) |offset_last_space| {
        const last_space = offset_last_space + str.i;
        // this is an application of some sort

        // term application
        const lhs_view = std.unicode.Utf8View.initUnchecked(str.bytes[str.i..last_space]);
        var lhs_iter = lhs_view.iterator();
        const lhs = try parse(gpa, &lhs_iter);
        while (str.i <= last_space) _ = str.nextCodepoint();
        const rhs = try parse(gpa, str);
        const alloc = try gpa.create(Term);
        alloc.* = Term{ .app = .{
            .lhs = lhs,
            .rhs = rhs,
        } };
        return alloc;
    }

    return switch (char) {
        '(' => {
            std.debug.print("parens!", .{});
            const closing_idx = (std.mem.lastIndexOfScalar(
                u8,
                str.bytes[str.i..],
                ')',
            ) orelse {
                std.debug.print("no closing {s}\n", .{str.bytes[str.i..]});
                return error.NoClosingParen;
            });

            const inner = std.unicode.Utf8View.initUnchecked(
                str.bytes[str.i + 1 .. str.i + closing_idx],
            );
            std.debug.print("inner {s}\n", .{inner.bytes});

            var inner_iter = inner.iterator();
            const res = parse(gpa, &inner_iter);
            // exhaust outer iter
            var iter = inner.iterator();
            while (iter.nextCodepoint()) |_| _ = str.nextCodepoint();
            _ = str.nextCodepoint();
            return res;
        },
        lambda => {
            _ = str.nextCodepoint();
            const label = try parseLabel(
                gpa,
                str,
                std.unicode.Utf8View.initUnchecked(":"),
            );
            const ty = try parseTy(gpa, str, ".");
            const term = try parse(gpa, str);
            const alloc = try gpa.create(Term);
            alloc.* = Term{ .abs = .{
                .name = label,
                .ty = ty.*,
                .term = term,
            } };
            return alloc;
        },
        big_lambda => {
            _ = str.nextCodepoint();
            // return parse(gpa, str);
            return error.TODOBigLambda;
        },
        else => {

            // this is just a variable
            const label = try parseLabel(
                gpa,
                str,
                std.unicode.Utf8View.initUnchecked(""),
            );
            const alloc = try gpa.create(Term);
            alloc.* = Term{ .variable = label };
            return alloc;
        },
    };
}

fn chk_parse(dba: Allocator, expected: Term, str: []const u8) !void {
    var iter = (try std.unicode.Utf8View.init(str)).iterator();
    const parsed = try parse(dba, &iter);
    errdefer std.debug.print("\n{f} != {f}\n", .{ expected, parsed });
    try std.testing.expectEqualDeep(
        &expected,
        parsed,
    );
}

test "term parsing" {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dba.allocator();

    try chk_parse(allocator, Term{ .variable = "c" }, "c");

    try chk_parse(allocator, Term{ .variable = "ccccccccc" }, "ccccccccc");

    try chk_parse(
        allocator,
        Term{ .abs = .{
            .name = "abcdefgh",
            .ty = FTy{ .variable = "bbbbbbbb" },
            .term = &Term{ .variable = "c" },
        } },
        "λabcdefgh:bbbbbbbb.c",
    );

    try chk_parse(
        allocator,
        Term{ .abs = .{
            .name = "abcdefgh",
            .ty = FTy{ .variable = "bbbbbbbb" },
            .term = &Term{ .abs = .{
                .name = "12345678",
                .ty = FTy{ .variable = "bbbbbbbb" },
                .term = &Term{ .variable = "c" },
            } },
        } },
        "λabcdefgh:bbbbbbbb.λ12345678:bbbbbbbb.c",
    );

    try chk_parse(
        allocator,
        Term{ .app = .{
            .lhs = &Term{ .variable = "a" },
            .rhs = &Term{ .variable = "b" },
        } },
        "a b",
    );

    try chk_parse(
        allocator,
        Term{ .app = .{
            .lhs = &Term{ .abs = .{
                .name = "a",
                .ty = FTy{ .variable = "t" },
                .term = &Term{ .variable = "a" },
            } },
            .rhs = &Term{ .variable = "b" },
        } },
        "(λa:t.a) b",
    );

    try chk_parse(
        allocator,
        Term{ .app = .{
            .lhs = &Term{ .abs = .{
                .name = "a",
                .ty = FTy{ .variable = "t" },
                .term = &Term{ .variable = "a" },
            } },
            .rhs = &Term{ .variable = "b" },
        } },
        "λa:t.a b",
    );

    try chk_parse(
        allocator,
        Term{ .app = .{
            .lhs = &Term{ .app = .{
                .lhs = &Term{ .variable = "a" },
                .rhs = &Term{ .variable = "b" },
            } },
            .rhs = &Term{ .variable = "c" },
        } },
        "a b c",
    );

    try chk_parse(
        allocator,
        Term{ .app = .{
            .lhs = &Term{ .app = .{
                .lhs = &Term{ .variable = "a" },
                .rhs = &Term{ .variable = "b" },
            } },
            .rhs = &Term{ .variable = "c" },
        } },
        "(a b) c",
    );

    try chk_parse(
        allocator,
        Term{ .app = .{
            .lhs = &Term{ .variable = "a" },
            .rhs = &Term{ .app = .{
                .lhs = &Term{ .variable = "b" },
                .rhs = &Term{ .variable = "c" },
            } },
        } },
        "a (b c)",
    );
}
