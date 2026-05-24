const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core.zig");
const FTy = core.Ty;
const Term = core.Term;
const Kind = core.Kind;
const Label = core.Label;

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
