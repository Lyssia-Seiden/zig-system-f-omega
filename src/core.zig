const std = @import("std");
const util = @import("util.zig");
// ugly aah import graph
const tychk = @import("tychk.zig");

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
    universal: struct { label: []const u8, kind: Kind, inner: *Ty },
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

    pub fn eqv(self: *Ty, gpa: std.mem.Allocator, other: *Ty, ctx: ?*const Ctx) !bool {
        try tychk.reduceTy(gpa, self);
        try tychk.reduceTy(gpa, other);
        if (@intFromEnum(self.*) != @intFromEnum(other.*)) return false;
        switch (self.*) {
            .variable => {
                // std.debug.print("{any}\n", .{ctx.?.get(self.variable).?});
                return self.variable == other.variable;
                // const self_bind = ctx.?.get(self.variable).?;
                // const other_bind = ctx.?.get(other.variable).?;
                // if (@intFromEnum(self_bind) != @intFromEnum(other_bind)) return false;
                // switch (self_bind) {
                //     .ty_var => {
                //         return self_bind.ty_var.eql(ctx.?.get(other.variable).?.ty_var);
                //     },
                //     else => return false, // should always be a ty binding
                // }
            },
            .function => {
                return try self.function.lhs.eqv(gpa, other.function.lhs, ctx) and
                    try self.function.rhs.eqv(gpa, other.function.rhs, ctx);
            },
            .universal => {
                const inner_ctx = Ctx{
                    .name = self.universal.label,
                    .binding = .name,
                    .pred = ctx,
                };
                return self.universal.kind.eql(other.universal.kind) and
                    try self.universal.inner.eqv(
                        gpa,
                        other.universal.inner,
                        &inner_ctx,
                    );
            },
            .abs => {
                const inner_ctx = Ctx{
                    .name = self.abs.name_hint,
                    .binding = .name,
                    .pred = ctx,
                };
                return self.abs.kind.eql(other.abs.kind) and
                    try self.abs.ty.eqv(gpa, other.abs.ty, &inner_ctx);
            },
            .app => {
                return try self.app.lhs.eqv(gpa, other.app.lhs, ctx) and
                    try self.app.rhs.eqv(gpa, other.app.rhs, ctx);
            },
        }
    }

    pub fn deepCopyInto(self: *const Ty, gpa: std.mem.Allocator, dest: *Ty) !void {
        switch (self.*) {
            .variable => dest.* = self.*,
            .function => {
                const alloc = try gpa.alloc(Ty, 2);
                try self.*.function.lhs.deepCopyInto(gpa, &alloc[0]);
                try self.*.function.rhs.deepCopyInto(gpa, &alloc[1]);
                dest.* = .{ .function = .{ .lhs = &alloc[0], .rhs = &alloc[1] } };
            },
            .universal => {
                const alloc = try gpa.alloc(Ty, 1);
                try self.*.universal.inner.deepCopyInto(gpa, &alloc[0]);
                dest.* = .{ .universal = .{
                    .label = self.universal.label,
                    .kind = self.universal.kind,
                    .inner = &alloc[0],
                } };
            },
            .abs => {
                const alloc = try gpa.alloc(Ty, 1);
                try self.*.abs.ty.deepCopyInto(gpa, &alloc[0]);
                dest.* = .{ .abs = .{
                    .name_hint = self.abs.name_hint,
                    .kind = self.abs.kind,
                    .ty = &alloc[0],
                } };
            },
            .app => {
                const alloc = try gpa.alloc(Ty, 2);
                try self.*.app.lhs.deepCopyInto(gpa, &alloc[0]);
                try self.*.app.rhs.deepCopyInto(gpa, &alloc[1]);
                dest.* = .{ .app = .{ .lhs = &alloc[0], .rhs = &alloc[1] } };
            },
        }
    }

    pub fn destroy(self: *const Ty, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .variable => {},
            .function => {
                self.*.function.lhs.destroy(gpa);
                self.*.function.rhs.destroy(gpa);
            },
            .universal => {
                self.*.universal.inner.destroy(gpa);
            },
            .abs => {
                self.*.abs.ty.destroy(gpa);
            },
            .app => {
                self.*.app.lhs.destroy(gpa);
                self.*.app.rhs.destroy(gpa);
            },
        }
        gpa.destroy(self);
    }

    pub fn deinit(self: *const Ty, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .variable => {},
            .function => {
                self.*.function.lhs.destroy(gpa);
                self.*.function.rhs.destroy(gpa);
            },
            .universal => {
                self.*.universal.inner.destroy(gpa);
            },
            .abs => {
                self.*.abs.ty.destroy(gpa);
            },
            .app => {
                self.*.app.lhs.destroy(gpa);
                self.*.app.rhs.destroy(gpa);
            },
        }
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

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .name => try writer.print("name binding", .{}),
            .variable => try writer.print("var of ty {f}", .{self.variable}),
            .ty_var => try writer.print("ty of kind {f}", .{self.ty_var}),
        }
    }
};

pub const Ctx = struct {
    name: []const u8,
    binding: Binding,
    pred: ?*const Ctx,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s} = {f}", .{ self.name, self.binding });
        if (self.pred) |pred|
            try writer.print(" : {f}", .{pred});
    }

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

    pub fn find(self: Ctx, gpa: std.mem.Allocator, binding: Binding) ?u32 {
        if (@intFromEnum(self.binding) != @intFromEnum(binding))
            (self.pred.find(gpa, binding));
        switch (self.binding) {
            .name => return true,
            .variable => return self.binding.variable.eqv(gpa, binding.variable, self),
            .ty_var => return self.binding.ty_var.eql(binding.ty_var),
        }
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
                    if (self.ctx) |c| c.getName(self.term.variable) orelse "?" else "?",
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
                try writer.print("Λ{s}::{f}.{f}", .{
                    self.term.ty_abs.label,
                    self.term.ty_abs.kind,
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
