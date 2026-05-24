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
    atomic,
    function: struct { lhs: *Ty, rhs: *Ty },

    pub fn format(self: Ty, writer: *std.Io.Writer) !void {
        switch (self) {
            .atomic => try writer.print("α", .{}),
            .function => try writer.print(
                "{f} -> {f}",
                .{ self.function.lhs, self.function.rhs },
            ),
        }
    }

    pub fn eql(self: Ty, other: Ty) bool {
        switch (self) {
            .atomic => switch (other) {
                .atomic => true,
                .function => false,
            },
            .function => {
                switch (other) {
                    .atomic => false,
                    .function => {
                        const lhs = self.function.lhs.*;
                        const rhs = self.function.rhs.*;

                        return lhs.eql(other.function.lhs.*) and rhs.eql(other.function.rhs.*);
                    },
                }
            },
        }
    }
};

pub const Binding = union(enum) {
    name,
    variable: Ty,
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
        .ty = .atomic,
        .term = &inner,
    } };
    std.debug.print("{f}", .{TermWCtx{ .term = &id, .ctx = null }});
}
