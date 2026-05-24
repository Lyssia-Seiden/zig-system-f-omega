const std = @import("std");

const Term = union(enum) {
    variable: u32,
    abs: struct { name_hint: []const u8, term: *const Term },
    app: struct { lhs: *const Term, rhs: *const Term },
};

const Ty = union(enum) {};

const Ctx = struct {
    name: []const u8,
    binding: union(enum) {
        name,
    },
    pred: ?*const Ctx,

    pub fn head(self: Ctx) Ctx {
        return if (self.pred) |next| head(next.*) else self;
    }
};

const TermWCtx = struct {
    term: *const Term,
    ctx: ?*const Ctx,

    pub fn format(self: TermWCtx, writer: *std.Io.Writer) !void {
        switch (self.term.*) {
            // TODO handle de brujin niceties
            .variable => try writer.print("{s}", .{self.ctx.?.name}),
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
    const id = Term{ .abs = .{
        .name_hint = "x",
        .term = &Term{ .variable = 0 },
    } };
    std.debug.print("{f}", .{TermWCtx{.term = &id, .ctx = null}});
}
