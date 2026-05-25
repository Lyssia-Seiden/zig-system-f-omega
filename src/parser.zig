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
    space,
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
    .{ " ", .space },
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
            if (tokens[1] != .ident) return error.MalformedLambda;
            const ident = tokens[1].ident;
            if (tokens[2] != .colon) return error.MalformedLambda;
            const ty, const ty_offset = try parseTy(
                gpa,
                tokens[3..],
                ctx,
            );
            defer gpa.destroy(ty);

            if (tokens[3 + ty_offset] != .dot) return error.MalformedLambda;
            const inner_ctx = core.Ctx{
                .name = ident,
                .binding = .{ .variable = ty.* },
                .pred = ctx,
            };
            const inner, const inner_offset = try parseTokens(
                gpa,
                tokens[3 + ty_offset + 1 ..],
                &inner_ctx,
            );

            const alloc = try gpa.create(core.Term);
            alloc.* = .{ .abs = .{
                .name_hint = ident,
                .ty = ty.*,
                .term = inner,
            } };
            return .{ alloc, 3 + ty_offset + 1 + inner_offset };
        },
        .big_lambda => {
            if (tokens[1] != .ident) return error.MalformedBigLambda;
            const ident = tokens[1].ident;
            if (tokens[2] != .double_colon) return error.MalformedBigLambda;
            const kind, const kind_offset = try parseKind(
                gpa,
                tokens[3..],
                ctx,
            );
            defer gpa.destroy(kind);

            if (tokens[3 + kind_offset] != .dot) return error.MalformedBigLambda;
            const inner_ctx = core.Ctx{
                .name = ident,
                .binding = .{ .ty_var = kind.* },
                .pred = ctx,
            };
            const inner, const inner_offset = try parseTokens(
                gpa,
                tokens[3 + kind_offset + 1 ..],
                &inner_ctx,
            );

            const alloc = try gpa.create(core.Term);
            alloc.* = .{ .ty_abs = .{
                .label = ident,
                .kind = kind.*,
                .term = inner,
            } };
            return .{ alloc, 3 + kind_offset + 1 + inner_offset };
        },
        .open_paren => {
            var closing_idx: usize = 1;
            var maybe_space_idx: ?usize = null;
            var paren_count: i32 = 0;
            while (!(paren_count == 0 and tokens[closing_idx] == .close_paren)) {
                if (tokens[closing_idx] == .open_paren) paren_count += 1;
                if (tokens[closing_idx] == .close_paren) paren_count -= 1;
                if (tokens[closing_idx] == .space and paren_count == 0)
                    maybe_space_idx = closing_idx;
                closing_idx += 1;
                if (closing_idx == tokens.len) return error.NoClosingParen;
            }
            if (maybe_space_idx) |space_idx| {
                const lhs, _ = try parseTokens(
                    gpa,
                    tokens[1..space_idx],
                    ctx,
                );
                if (tokens[space_idx + 1] == .open_bracket) {
                    if (tokens[closing_idx - 1] != .close_bracket) return error.MalformedTyApp;
                    const rhs, _ = try parseTy(
                        gpa,
                        tokens[space_idx + 2 .. closing_idx - 1],
                        ctx,
                    );
                    defer gpa.destroy(rhs);

                    const alloc = try gpa.create(core.Term);
                    alloc.* = .{ .ty_app = .{ .term = lhs, .ty = rhs.* } };
                    return .{ alloc, closing_idx + 1 };
                } else {
                    const rhs, _ = try parseTokens(
                        gpa,
                        tokens[space_idx + 1 .. closing_idx],
                        ctx,
                    );

                    const alloc = try gpa.create(core.Term);
                    alloc.* = .{ .app = .{ .lhs = lhs, .rhs = rhs } };
                    return .{ alloc, closing_idx + 1 };
                }
            }
            return error.InvalidParens;
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
                    const alloc = try gpa.create(core.Ty);
                    alloc.* = core.Ty{ .variable = i };
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
            defer gpa.destroy(kind);
            if (tokens[3 + dot_offset] != .dot) return error.MalformedLambda;
            const inner_ctx = core.Ctx{
                .name = ident,
                .binding = .{ .ty_var = kind.* },
                .pred = ctx,
            };
            const inner, const end_offset = try parseTy(
                gpa,
                tokens[3 + dot_offset + 1 ..],
                &inner_ctx,
            );

            const alloc = try gpa.create(core.Ty);
            alloc.* = .{ .abs = .{
                .name_hint = ident,
                .kind = kind.*,
                .ty = inner,
            } };
            return .{ alloc, 4 + dot_offset + end_offset };
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
            defer gpa.destroy(kind);
            if (tokens[3 + dot_offset] != .dot) return error.MalformedLambda;
            const inner_ctx = core.Ctx{
                .name = ident,
                .binding = .{ .ty_var = kind.* },
                .pred = ctx,
            };
            const inner, const end_offset = try parseTy(
                gpa,
                tokens[3 + dot_offset + 1 ..],
                &inner_ctx,
            );

            const alloc = try gpa.create(core.Ty);
            alloc.* = .{ .universal = .{
                .label = ident,
                .kind = kind.*,
                .inner = inner,
            } };
            return .{ alloc, 4 + dot_offset + end_offset };
        },
        .open_paren => {
            var closing_idx: usize = 1;
            var maybe_space_idx: ?usize = null;
            var maybe_arrow_idx: ?usize = null;
            var paren_count: i32 = 0;
            while (!(paren_count == 0 and tokens[closing_idx] == .close_paren)) {
                if (tokens[closing_idx] == .open_paren) paren_count += 1;
                if (tokens[closing_idx] == .close_paren) paren_count -= 1;
                if (tokens[closing_idx] == .space and paren_count == 0)
                    maybe_space_idx = closing_idx;
                if (tokens[closing_idx] == .arrow and paren_count == 0)
                    maybe_arrow_idx = closing_idx;
                closing_idx += 1;
                if (closing_idx == tokens.len) return error.NoClosingParen;
            }
            if (maybe_arrow_idx) |arrow_idx| {
                // function type
                const lhs, _ = try parseTy(gpa, tokens[1..arrow_idx], ctx);
                const rhs, _ = try parseTy(gpa, tokens[arrow_idx + 1 .. closing_idx], ctx);

                const alloc = try gpa.create(core.Ty);
                alloc.* = .{ .function = .{ .lhs = lhs, .rhs = rhs } };
                return .{ alloc, closing_idx + 1 };
            }
            if (maybe_space_idx) |space_idx| {
                // application type
                const lhs, _ = try parseTy(gpa, tokens[1..space_idx], ctx);
                const rhs, _ = try parseTy(gpa, tokens[space_idx + 1 .. closing_idx], ctx);

                const alloc = try gpa.create(core.Ty);
                alloc.* = .{ .app = .{ .lhs = lhs, .rhs = rhs } };
                return .{ alloc, closing_idx + 1 };
            }
            return error.InvalidParens;
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

            const lhs, _ = try parseKind(gpa, tokens[1..arrow_idx], ctx);
            const rhs, _ = try parseKind(gpa, tokens[arrow_idx..closing_idx], ctx);

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

test "parseTy: function type (α->β)" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const outer = core.Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const ctx = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = &outer,
    };
    const tokens = try tokenize("(α->β)");
    const ty, const consumed = try parseTy(gpa, tokens, &ctx);
    try testing.expect(ty.* == .function);
    try testing.expect(ty.function.lhs.* == .variable);
    try testing.expectEqual(@as(u32, 0), ty.function.lhs.variable);
    try testing.expect(ty.function.rhs.* == .variable);
    try testing.expectEqual(@as(u32, 1), ty.function.rhs.variable);
    try testing.expectEqual(tokens.len, consumed);
}

test "parseTy: nested function type (α->(β->γ))" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const c2 = core.Ctx{
        .name = "γ",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const c1 = core.Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = &c2,
    };
    const ctx = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = &c1,
    };
    const tokens = try tokenize("(α->(β->γ))");
    const ty, _ = try parseTy(gpa, tokens, &ctx);
    try testing.expect(ty.* == .function);
    try testing.expect(ty.function.rhs.* == .function);
}

test "parseTy: type application (f α)" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const k_from: core.Kind = .proper;
    const k_to: core.Kind = .proper;
    const k_op = core.Kind{ .operator = .{ .from = &k_from, .to = &k_to } };

    const outer = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const ctx = core.Ctx{
        .name = "f",
        .binding = .{ .ty_var = k_op },
        .pred = &outer,
    };
    const tokens = try tokenize("(f α)");
    const ty, const consumed = try parseTy(gpa, tokens, &ctx);
    try testing.expect(ty.* == .app);
    try testing.expect(ty.app.lhs.* == .variable);
    try testing.expectEqual(@as(u32, 0), ty.app.lhs.variable);
    try testing.expect(ty.app.rhs.* == .variable);
    try testing.expectEqual(@as(u32, 1), ty.app.rhs.variable);
    try testing.expectEqual(tokens.len, consumed);
}

test "parseTy: nested type application ((f α) β)" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const k_from: core.Kind = .proper;
    const k_to: core.Kind = .proper;
    const k_inner = core.Kind{ .operator = .{ .from = &k_from, .to = &k_to } };
    const k_f = core.Kind{ .operator = .{ .from = &k_from, .to = &k_inner } };

    const c2 = core.Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const c1 = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = &c2,
    };
    const ctx = core.Ctx{
        .name = "f",
        .binding = .{ .ty_var = k_f },
        .pred = &c1,
    };
    const tokens = try tokenize("((f α) β)");
    const ty, _ = try parseTy(gpa, tokens, &ctx);
    try testing.expect(ty.* == .app);
    try testing.expect(ty.app.lhs.* == .app);
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

test "parseTokens: bound ident resolves to de Bruijn variable" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const ctx = core.Ctx{
        .name = "x",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = null,
    };
    const tokens = try tokenize("x");
    const term, const consumed = try parseTokens(gpa, tokens, &ctx);
    try testing.expect(term.* == .variable);
    try testing.expectEqual(@as(u32, 0), term.variable);
    try testing.expectEqual(@as(usize, 1), consumed);
}

test "parseTokens: ident skips non-variable bindings" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // β is a type variable, x is a term variable — looking up x walks past β
    const outer = core.Ctx{
        .name = "x",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = null,
    };
    const inner = core.Ctx{
        .name = "β",
        .binding = .{ .ty_var = .proper },
        .pred = &outer,
    };
    const tokens = try tokenize("x");
    const term, _ = try parseTokens(gpa, tokens, &inner);
    try testing.expect(term.* == .variable);
    try testing.expectEqual(@as(u32, 1), term.variable);
}

test "parseTokens error: unbound ident" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize("x");
    try testing.expectError(error.UnknownVariable, parseTokens(gpa, tokens, null));
}

test "parseTokens: term abstraction λx:α.x" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const ctx = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const tokens = try tokenize("λx:α.x");
    const term, const consumed = try parseTokens(gpa, tokens, &ctx);
    try testing.expect(term.* == .abs);
    try testing.expectEqualStrings("x", term.abs.name_hint);
    try testing.expect(term.abs.ty == .variable);
    try testing.expectEqual(@as(u32, 0), term.abs.ty.variable);
    try testing.expect(term.abs.term.* == .variable);
    try testing.expectEqual(@as(u32, 0), term.abs.term.variable);
    try testing.expectEqual(tokens.len, consumed);
}

test "parseTokens: term abstraction body uses extended context" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    // outer y:α; inside λx:α. body x is index 0, y is index 1.
    const outer = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const ctx = core.Ctx{
        .name = "y",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = &outer,
    };
    const tokens = try tokenize("λx:α.x");
    const term, _ = try parseTokens(gpa, tokens, &ctx);
    try testing.expect(term.* == .abs);
    try testing.expectEqual(@as(u32, 0), term.abs.term.variable);
}

test "parseTokens: term application (f x)" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const outer = core.Ctx{
        .name = "x",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = null,
    };
    const ctx = core.Ctx{
        .name = "f",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = &outer,
    };
    const tokens = try tokenize("(f x)");
    const term, const consumed = try parseTokens(gpa, tokens, &ctx);
    try testing.expect(term.* == .app);
    try testing.expect(term.app.lhs.* == .variable);
    try testing.expectEqual(@as(u32, 0), term.app.lhs.variable);
    try testing.expect(term.app.rhs.* == .variable);
    try testing.expectEqual(@as(u32, 1), term.app.rhs.variable);
    try testing.expectEqual(tokens.len, consumed);
}

test "parseTokens: nested term application ((f x) y)" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const c2 = core.Ctx{
        .name = "y",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = null,
    };
    const c1 = core.Ctx{
        .name = "x",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = &c2,
    };
    const ctx = core.Ctx{
        .name = "f",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = &c1,
    };
    const tokens = try tokenize("((f x) y)");
    const term, _ = try parseTokens(gpa, tokens, &ctx);
    try testing.expect(term.* == .app);
    try testing.expect(term.app.lhs.* == .app);
}

test "parseTokens: term-level type application (f [α])" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const gpa = arena.allocator();

    const outer = core.Ctx{
        .name = "α",
        .binding = .{ .ty_var = .proper },
        .pred = null,
    };
    const ctx = core.Ctx{
        .name = "f",
        .binding = .{ .variable = .{ .variable = 0 } },
        .pred = &outer,
    };
    const tokens = try tokenize("(f [α])");
    const term, const consumed = try parseTokens(gpa, tokens, &ctx);
    try testing.expect(term.* == .ty_app);
    try testing.expect(term.ty_app.term.* == .variable);
    try testing.expectEqual(@as(u32, 0), term.ty_app.term.variable);
    try testing.expect(term.ty_app.ty == .variable);
    try testing.expectEqual(@as(u32, 1), term.ty_app.ty.variable);
    try testing.expectEqual(tokens.len, consumed);
}
