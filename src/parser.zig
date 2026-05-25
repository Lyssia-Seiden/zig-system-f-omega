const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

const Token = union(enum) {
    ident: []const u8,
    lambda, // λ
    big_lambda, // Λ
    forall, // ∀
    dot, // .
    colon, // :
    double_colon, // ::
    arrow, // ->
    double_arrow, // =>
    proper_type, // *
    open_paren,
    close_paren,
    open_bracket,
    close_bracket,
};

const literals = .{
    // in precedence order
    .{ "λ", .lambda },
    .{ "Λ", .big_lambda },
    .{ "∀", .forall },
    .{ "::", .double_colon },
    .{ "->", .arrow },
    .{ "=>", .double_arrow },
    .{ ":", .colon },
    .{ ".", .dot },
    .{ "*", .proper_type },
    .{ "(", .open_paren },
    .{ ")", .close_paren },
    .{ "[", .open_bracket },
    .{ "]", .close_bracket },
};
fn tokenize(str: []const u8) ![]const Token {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const aa = arena.allocator();

    var list: std.ArrayList(Token) = try .initCapacity(aa, 16);

    var i: u32 = 0;
    outer: while (i < str.len) {
        // literals

        inline for (literals) |literal| {
            if (std.mem.startsWith(u8, str[i..], literal[0])) {
                try list.append(aa, literal[1]);
                i += literal[0].len;
                continue :outer;
            }
        }

        // otherwise this is an ident
        var ident_end = i + 1;
        ident_bounding: while (ident_end < str.len) {
            // there is almost certainly a more efficient way to do this
            inline for (literals) |literal| {
                if (std.mem.startsWith(u8, str[ident_end..], literal[0])) {
                    break :ident_bounding;
                }
            }

            ident_end += 1;
        }
        try list.append(aa, Token{ .ident = str[i..ident_end] });
        i = ident_end;
    }

    return list.toOwnedSlice(aa);
}

const testing = std.testing;

fn expectTokens(input: []const u8, expected: []const Token) !void {
    const actual = try tokenize(input);
    try testing.expectEqualDeep(expected, actual);
}

test "tokenize: empty input" {
    try expectTokens("", &.{});
}

test "tokenize: single identifier" {
    try expectTokens("foo", &.{.{ .ident = "foo" }});
}

test "tokenize: every single-char literal" {
    try expectTokens(".:*()[]", &.{
        .dot,
        .colon,
        .proper_type,
        .open_paren,
        .close_paren,
        .open_bracket,
        .close_bracket,
    });
}

test "tokenize: unicode lambda, big lambda, forall" {
    try expectTokens("λΛ∀", &.{ .lambda, .big_lambda, .forall });
}

test "tokenize: multi-char literals" {
    try expectTokens("->=>::", &.{ .arrow, .double_arrow, .double_colon });
}

test "tokenize: double colon is not two colons" {
    try expectTokens("::", &.{.double_colon});
}

test "tokenize: term-level identity λx.x" {
    try expectTokens("λx.x", &.{
        .lambda,
        .{ .ident = "x" },
        .dot,
        .{ .ident = "x" },
    });
}

test "tokenize: typed abstraction λx:α.x" {
    try expectTokens("λx:α.x", &.{
        .lambda,
        .{ .ident = "x" },
        .colon,
        .{ .ident = "α" },
        .dot,
        .{ .ident = "x" },
    });
}

test "tokenize: type abstraction Λα.x" {
    try expectTokens("Λα.x", &.{
        .big_lambda,
        .{ .ident = "α" },
        .dot,
        .{ .ident = "x" },
    });
}

test "tokenize: universal type ∀α::*.α" {
    try expectTokens("∀α::*.α", &.{
        .forall,
        .{ .ident = "α" },
        .double_colon,
        .proper_type,
        .dot,
        .{ .ident = "α" },
    });
}

test "tokenize: function type α->β" {
    try expectTokens("α->β", &.{
        .{ .ident = "α" },
        .arrow,
        .{ .ident = "β" },
    });
}

test "tokenize: type application f[α]" {
    try expectTokens("f[α]", &.{
        .{ .ident = "f" },
        .open_bracket,
        .{ .ident = "α" },
        .close_bracket,
    });
}

test "tokenize: nested parens (λx.x)" {
    try expectTokens("(λx.x)", &.{
        .open_paren,
        .lambda,
        .{ .ident = "x" },
        .dot,
        .{ .ident = "x" },
        .close_paren,
    });
}

test "tokenize: kinded type abstraction λα::*=>α" {
    try expectTokens("λα::*=>α", &.{
        .lambda,
        .{ .ident = "α" },
        .double_colon,
        .proper_type,
        .double_arrow,
        .{ .ident = "α" },
    });
}

test "tokenize: identifier butted against literal" {
    try expectTokens("foo->bar", &.{
        .{ .ident = "foo" },
        .arrow,
        .{ .ident = "bar" },
    });
}

fn parseTokens(gpa: Allocator, tokens: []const Token, ctx: ?*const core.Ctx) !struct { *core.Term, usize } {
    switch (tokens[0]) {
        .ident => {
            var i: u32 = 0;
            var walking_ctx = ctx;
            while (walking_ctx) |c| {
                if (std.mem.eql(u8, tokens[0].ident, c.name) and c.binding == .variable) {
                    // in the club totally de brujinizing it
                    const alloc = try gpa.create(core.Term);
                    alloc.* = core.Term{ .variable = i };
                    return .{ alloc, 1 };
                }
                walking_ctx = c.pred;
                i += 1;
            }
            return error.UnknownVariable;
        },
        .lambda => {
            _ = try parseTy(gpa, tokens[1..], ctx);
            return error.TODO;
        },
        .big_lambda => {
            return error.TODO;
        },
        .open_paren => {
            return error.TODO;
        },
        else => return error.InvalidToken,
    }
}

fn parseTy(gpa: Allocator, tokens: []const Token, ctx: ?*const core.Ctx) !struct { *core.Ty, usize } {
    switch (tokens[0]) {
        .ident => {
            var i: u32 = 0;
            var walking_ctx = ctx;
            while (walking_ctx) |c| {
                if (std.mem.eql(u8, tokens[0].ident, c.name) and c.binding == .ty_var) {
                    // in the club totally de brujinizing it
                    const alloc = try gpa.create(core.Term);
                    alloc.* = core.Term{ .variable = i };
                    return .{ alloc, 1 };
                }
                walking_ctx = c.pred;
                i += 1;
            }
            return error.UnknownVariable;
        },
        .lambda => {
            if (tokens[1] != .ident) return error.MalformedLamba;
            const ident = tokens[1].ident;
            if (tokens[2] != .double_colon) return error.MalformedLamba;
            const kind, const dot_offset = try parseKind(
                gpa,
                tokens[3..],
                ctx,
            );
            if (tokens[3 + dot_offset] != .dot) return error.MalformedLambda;
            const inner_ctx = core.Ctx{
                .name = ident,
                .binding = .{ .ty_var = kind },
                .pred = ctx,
            };
            const inner, const end_offset = try parseTy(
                gpa,
                tokens[3 + dot_offset + 1 ..],
                inner_ctx,
            );

            const alloc = try gpa.create(core.Ty);
            alloc.* = .{ .abs = .{
                .name_hint = ident,
                .kind = kind,
                .ty = inner,
            } };
            return .{ alloc, 3 + dot_offset + end_offset };
        },
        .forall => {
            if (tokens[1] != .ident) return error.MalformedLamba;
            const ident = tokens[1].ident;
            if (tokens[2] != .double_colon) return error.MalformedLamba;
            const kind, const dot_offset = try parseKind(
                gpa,
                tokens[3..],
                ctx,
            );
            if (tokens[3 + dot_offset] != .dot) return error.MalformedLambda;
            const inner_ctx = core.Ctx{
                .name = ident,
                .binding = .{ .ty_var = kind },
                .pred = ctx,
            };
            const inner, const end_offset = try parseTy(
                gpa,
                tokens[3 + dot_offset + 1 ..],
                inner_ctx,
            );

            const alloc = try gpa.create(core.Ty);
            alloc.* = .{ .universal = .{
                .label = ident,
                .kind = kind,
                .inner = inner,
            } };
            return .{ alloc, 3 + dot_offset + end_offset };
        },
        .open_paren => {
            return error.TODO;
        },
        else => return error.MalformedType,
    }
}

fn parseKind(gpa: Allocator, tokens: []const Token, ctx: ?*const core.Ctx) !struct { *core.Kind, usize } {
    switch (tokens[0]) {
        .proper_type => {
            const alloc = try gpa.create(core.Kind);
            alloc.* = .proper;
            return .{ alloc, 1 };
        },
        .open_paren => {
            var closing_idx: usize = 1;
            var arrow_idx: usize = 1;
            var paren_count: i32 = 0;
            while (paren_count == 0 and tokens[closing_idx] == .close_paren) {
                if (tokens[closing_idx] == .open_paren) paren_count += 1;
                if (tokens[closing_idx] == .close_paren) paren_count -= 1;
                if (tokens[closing_idx] == .double_arrow and paren_count == 0)
                    arrow_idx = closing_idx;
                closing_idx += 1;
            }

            const lhs = try parseKind(gpa, tokens[1..arrow_idx], ctx);
            const rhs = try parseKind(gpa, tokens[arrow_idx..closing_idx], ctx);

            const alloc = try gpa.create(core.Kind);
            alloc.* = .{ .operator = .{
                .from = lhs,
                .to = rhs,
            } };
            return .{ alloc, closing_idx };
        },
        else => return error.MalformedKind,
    }
}

fn arenaAlloc() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "parseKind: proper type" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("*");
    const kind, const consumed = try parseKind(gpa, tokens, null);
    try testing.expect(kind.* == .proper);
    try testing.expectEqual(@as(usize, 1), consumed);
}

test "parseKind: only consumes a single token" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // trailing tokens should be left alone for the caller
    const tokens = try tokenize("*.");
    const kind, const consumed = try parseKind(gpa, tokens, null);
    try testing.expect(kind.* == .proper);
    try testing.expectEqual(@as(usize, 1), consumed);
}

test "parseKind error: lone ident is not a kind" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("α");
    try testing.expectError(error.MalformedKind, parseKind(gpa, tokens, null));
}

test "parseKind error: dot is not a kind" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize(".");
    try testing.expectError(error.MalformedKind, parseKind(gpa, tokens, null));
}

test "parseTy error: paren branch is TODO" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("(α)");
    try testing.expectError(error.TODO, parseTy(gpa, tokens, null));
}

test "parseTy error: leading dot is malformed" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize(".");
    try testing.expectError(error.MalformedType, parseTy(gpa, tokens, null));
}

test "parseTy error: leading arrow is malformed" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("->");
    try testing.expectError(error.MalformedType, parseTy(gpa, tokens, null));
}

test "parseTy: bound ident resolves to de Bruijn variable" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const ctx = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const tokens = try tokenize("α");
    const ty, const consumed = try parseTy(gpa, tokens, &ctx);
    try testing.expect(ty.* == .variable);
    try testing.expectEqual(@as(u32, 0), ty.variable);
    try testing.expectEqual(@as(usize, 1), consumed);
}

test "parseTy: ident skips non-ty_var bindings" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // α is a term variable, β is a type variable — looking up β should
    // walk past α and assign the next de Bruijn index
    const outer = core.Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const inner = core.Ctx{
        .name = "α",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = &outer,
    };
    const tokens = try tokenize("β");
    const ty, _ = try parseTy(gpa, tokens, &inner);
    try testing.expect(ty.* == .variable);
    try testing.expectEqual(@as(u32, 1), ty.variable);
}

test "parseTy error: unbound ident" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("α");
    try testing.expectError(error.UnknownVariable, parseTy(gpa, tokens, null));
}

test "parseTy: type-level identity λα::*.α" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("λα::*.α");
    const ty, const consumed = try parseTy(gpa, tokens, null);
    try testing.expect(ty.* == .abs);
    try testing.expectEqualStrings("α", ty.abs.name_hint);
    try testing.expect(ty.abs.kind == .proper);
    try testing.expect(ty.abs.ty.* == .variable);
    try testing.expectEqual(@as(u32, 0), ty.abs.ty.variable);
    try testing.expectEqual(tokens.len, consumed);
}

test "parseTy: universal ∀α::*.α" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("∀α::*.α");
    const ty, const consumed = try parseTy(gpa, tokens, null);
    try testing.expect(ty.* == .universal);
    try testing.expectEqualStrings("α", ty.universal.label);
    try testing.expect(ty.universal.kind == .proper);
    try testing.expect(ty.universal.inner.* == .variable);
    try testing.expectEqual(@as(u32, 0), ty.universal.inner.variable);
    try testing.expectEqual(tokens.len, consumed);
}

test "parseTy: lambda body uses extended context" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // outer β::* is bound; inside λα::*. the body α refers to the inner binder
    // (index 0) and β would be index 1 — verify the bound α resolves to 0.
    const ctx = core.Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const tokens = try tokenize("λα::*.α");
    const ty, _ = try parseTy(gpa, tokens, &ctx);
    try testing.expect(ty.* == .abs);
    try testing.expectEqual(@as(u32, 0), ty.abs.ty.variable);
}
