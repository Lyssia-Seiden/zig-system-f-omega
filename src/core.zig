const std = @import("std");
const util = @import("util.zig");

pub const Term = union(enum) {
    variable: u32,
    abs: struct { name_hint: []const u8, ty: Ty, term: *Term },
    app: struct { lhs: *Term, rhs: *Term },
    ty_abs: struct { label: []const u8, kind: Kind = .proper, term: *Term },
    ty_app: struct { ty: Ty, term: *Term },

    pub fn isVal(self: Term) bool {
        return switch (self) {
            .abs, .variable, .ty_abs => true,
            else => false,
        };
    }

    pub fn print(self: *Term, ctx: ?*const Ctx) void {
        std.debug.print("{f}\n", .{TermWCtx{ .term = self, .ctx = ctx }});
    }

    pub fn format(
        self: *const Term,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "{f}",
            .{TermWCtx{ .term = self, .ctx = null }},
        );
    }
};

pub const Ty = union(enum) {
    variable: u32,
    function: struct { lhs: *Ty, rhs: *Ty },
    universal: struct { label: []const u8, kind: Kind = .proper, inner: *Ty },
    abs: struct { name_hint: []const u8, kind: Kind, ty: *Ty },
    app: struct { lhs: *Ty, rhs: *Ty },

    pub fn format(self: Ty, writer: *std.Io.Writer) !void {
        switch (self) {
            .variable => try writer.print("{}", .{self.variable}),
            .function => try writer.print(
                "({f} -> {f})",
                .{ self.function.lhs, self.function.rhs },
            ),
            .universal => try writer.print(
                "∀{s}::{f}.{f}",
                .{ self.universal.label, self.universal.kind, self.universal.inner },
            ),
            .abs => try writer.print(
                "λ{s}::{f}.{f}",
                .{ self.abs.name_hint, self.abs.kind, self.abs.ty },
            ),
            .app => try writer.print(
                "({f} {f})",
                .{ self.app.lhs, self.app.rhs },
            ),
        }
    }

    pub fn eql(self: Ty, other: Ty) bool {
        return util.deepEql(self, other);
    }
};

pub const Kind = union(enum) {
    proper,
    operator: struct { from: *const Kind, to: *const Kind },

    pub fn format(self: Kind, writer: *std.Io.Writer) !void {
        switch (self) {
            .proper => try writer.print("*", .{}),
            .operator => try writer.print("({f} => {f})", .{ self.operator.from, self.operator.to }),
        }
    }

    pub fn eql(self: Kind, other: Kind) bool {
        return switch (self) {
            .proper => switch (other) {
                .proper => true,
                else => false,
            },
            .operator => switch (other) {
                .operator => self.operator.from.eql(other.operator.from.*) and
                    self.operator.to.eql(other.operator.to.*),
                else => false,
            },
        };
    }
};

pub const Binding = union(enum) {
    name,
    variable: Ty,
    ty_var: Kind,
};

pub const Ctx = struct {
    name: []const u8,
    binding: Binding,
    pred: ?*const Ctx,

    pub fn head(self: Ctx) Ctx {
        return if (self.pred) |next| head(next.*) else self;
    }

    pub fn get(self: Ctx, i: u32) ?Binding {
        if (i == 0) return self.binding;
        if (self.pred) |p| return p.get(i - 1);
        return null;
    }

    pub fn getName(self: Ctx, i: u32) ?[]const u8 {
        if (i == 0) return self.name;
        if (self.pred) |p| return p.getName(i - 1);
        return null;
    }
};

pub const TermWCtx = struct {
    term: *const Term,
    ctx: ?*const Ctx,

    pub fn format(self: TermWCtx, writer: *std.Io.Writer) !void {
        switch (self.term.*) {
            // TODO handle de brujin niceties
            .variable => try writer.print(
                "{s}/{}",
                .{
                    if (self.ctx) |c| c.getName(self.term.variable) orelse "unknown" else "unknown",
                    self.term.variable,
                },
            ),
            .abs => {
                const inner_ctx = Ctx{
                    .name = self.term.abs.name_hint,
                    .binding = .{ .variable = self.term.abs.ty },
                    .pred = self.ctx,
                };
                try writer.print(
                    "λ{s}:{f}.{f}",
                    .{
                        self.term.abs.name_hint,
                        self.term.abs.ty,
                        TermWCtx{ .term = self.term.abs.term, .ctx = &inner_ctx },
                    },
                );
            },
            .app => try writer.print("({f} {f})", .{
                TermWCtx{ .term = self.term.app.lhs, .ctx = self.ctx },
                TermWCtx{ .term = self.term.app.rhs, .ctx = self.ctx },
            }),
            .ty_abs => {
                const inner_ctx = Ctx{
                    .name = self.term.ty_abs.label,
                    .binding = .{ .ty_var = self.term.ty_abs.kind },
                    .pred = self.ctx,
                };
                try writer.print("Λ{s}.{f}", .{
                    self.term.ty_abs.label,
                    TermWCtx{
                        .term = self.term.ty_abs.term,
                        .ctx = &inner_ctx,
                    },
                });
            },
            .ty_app => try writer.print("({f} [{f}])", .{
                TermWCtx{ .term = self.term.ty_app.term, .ctx = self.ctx },
                self.term.ty_app.ty,
            }),
        }
    }
};

test "term printing" {
    var inner = Term{ .variable = 0 };
    var id = Term{ .abs = .{
        .name_hint = "x",
        .ty = .{ .variable = 1 },
        .term = &inner,
    } };
    std.debug.print("{f}", .{TermWCtx{ .term = &id, .ctx = null }});
}
