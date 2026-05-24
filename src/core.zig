const std = @import("std");

pub const Term = union(enum) {
    variable: u32,
    abs: struct { name_hint: []const u8, term: *Term },
    app: struct { lhs: *Term, rhs: *Term },

    pub fn isVal(self: Term) bool {
        return switch (self) {
            .abs, .variable => true,
            else => false,
        };
    }

    pub fn print(self: *Term, ctx: ?*const Ctx) void {
        std.debug.print("{f}\n", .{TermWCtx{.term = self, .ctx = ctx}});
    }
};

pub const Ty = union(enum) {};

pub const Ctx = struct {
    name: []const u8,
    binding: union(enum) {
        name,
    },
    pred: ?*const Ctx,

    pub fn head(self: Ctx) Ctx {
        return if (self.pred) |next| head(next.*) else self;
    }
};

pub const TermWCtx = struct {
    term: *Term,
    ctx: ?*const Ctx,

    pub fn format(self: TermWCtx, writer: *std.Io.Writer) !void {
        switch (self.term.*) {
            // TODO handle de brujin niceties
            .variable => try writer.print("{s}/{}", .{self.ctx.?.name, self.term.variable}),
            .abs => try writer.print(
                "λ{s}.{f}",
                .{
                    self.term.abs.name_hint,
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
        .term = &inner,
    } };
    std.debug.print("{f}", .{TermWCtx{ .term = &id, .ctx = null }});
}
