const std = @import("std");

pub const Term = union(enum) {
    variable: u32,
    abs: struct { name_hint: []const u8, ty: Ty, term: *Term },
    app: struct { lhs: *Term, rhs: *Term },

    pub fn isVal(self: Term) bool {
        return switch (self) {
            .abs, .variable => true,
            else => false,
        };
    }

    pub fn print(self: *Term, ctx: ?*const Ctx) void {
        std.debug.print("{f}\n", .{TermWCtx{ .term = self, .ctx = ctx }});
    }
};

pub const Ty = union(enum) {
    variable: u32,
    function: struct { lhs: *const Ty, rhs: *const Ty },
    universal: struct { label: []const u8, inner: *const Ty },

    pub fn format(self: Ty, writer: *std.Io.Writer) !void {
        switch (self) {
            .variable => try writer.print("α", .{}),
            .function => try writer.print(
                "{f} -> {f}",
                .{ self.function.lhs, self.function.rhs },
            ),
            .universal => try writer.print(
                "∀{s}.{f}",
                .{ self.universal.label, self.universal.inner },
            ),
        }
    }

    pub fn eql(self: Ty, other: Ty) bool {
        return switch (self) {
            .variable => switch (other) {
                .variable => true,
                else => false,
            },
            .function => {
                return switch (other) {
                    .function => {
                        const lhs = self.function.lhs.*;
                        const rhs = self.function.rhs.*;

                        return lhs.eql(other.function.lhs.*) and rhs.eql(other.function.rhs.*);
                    },
                    else => false,
                };
            },
            .universal => {
                return switch (other) {
                    .universal => self.universal.inner.eql(other.universal.inner) and
                        std.mem.eql(u8, self.universal.label, other.universal.label),
                    else => false,
                };
            },
        };
    }
};

pub const Binding = union(enum) {
    name,
    variable: Ty,
    ty_var,
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
};

pub const TermWCtx = struct {
    term: *Term,
    ctx: ?*const Ctx,

    pub fn format(self: TermWCtx, writer: *std.Io.Writer) !void {
        switch (self.term.*) {
            // TODO handle de brujin niceties
            .variable => try writer.print("{s}/{}", .{ self.ctx.?.name, self.term.variable }),
            .abs => try writer.print(
                "λ{s}:{f}.{f}",
                .{
                    self.term.abs.name_hint,
                    self.term.abs.ty,
                    TermWCtx{ .term = self.term.abs.term, .ctx = &Ctx{
                        .name = self.term.abs.name_hint,
                        .binding = .name,
                        .pred = self.ctx,
                    } },
                },
            ),
            .app => try writer.print("{f} {f}", .{
                TermWCtx{ .term = self.term.app.lhs, .ctx = self.ctx },
                TermWCtx{ .term = self.term.app.rhs, .ctx = self.ctx },
            }),
        }
    }
};

test "term printing" {
    var inner = Term{ .variable = 0 };
    var id = Term{ .abs = .{
        .name_hint = "x",
        .ty = .variable,
        .term = &inner,
    } };
    std.debug.print("{f}", .{TermWCtx{ .term = &id, .ctx = null }});
}
