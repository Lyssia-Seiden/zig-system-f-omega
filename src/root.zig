//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

pub const Label: type = u8;
pub const FTy: type = union(enum) {
    ty_variable: Label,
    function: struct {
        from: FTy,
        to: FTy,
    },
    universal: struct {
        label: Label,
        ty: FTy,
    },
};
pub const Term = union(enum) {
    variable: Label,
    abstract: struct {
        name: Label,
        ty: FTy,
        term: Term,
    },
    appliction: struct {
        lhs: Term,
        rhs: Term,
    },
    type_abstraction: struct {
        ty: FTy,
        term: Term,
    },
    type_application: struct {
        term: Term,
        ty: FTy,
    },
};

pub const Context = []const (union(enum) {
    term: struct { label: Label, ty: FTy },
    ty: struct { label: Label },
});
