const std = @import("std");
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

    pub fn replace(self: FTy, label: Label, ty: FTy) FTy {
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
            .op_app => try writer.print("({f} {f})", .{ self.op_app.lhs, self.op_app.rhs }),
        }
    }
};
pub const Kind = union(enum) {
    proper,
    operator: struct { lhs: *const Kind, rhs: *const Kind },

    pub fn format(self: Kind, writer: *std.Io.Writer) !void {
        switch (self) {
            .proper => try writer.printAsciiChar('*', .{}),
            .operator => try writer.print("({f} => {f})", .{
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

