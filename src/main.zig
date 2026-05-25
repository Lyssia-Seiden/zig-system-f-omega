const std = @import("std");
const parser = @import("parser.zig");
const tychk = @import("tychk.zig");
const interpreter = @import("interpreter.zig");
const core = @import("core.zig");

pub fn main(init: std.process.Init) !void {
    var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer aa.deinit();
    const gpa = aa.allocator();

    const target = (try init.minimal.args.toSlice(gpa))[1];
    const source = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        init.io,
        target,
        gpa,
        std.Io.Limit.unlimited,
    );

    const buf = try gpa.alloc(u8, 64);
    var stdout = std.Io.File.stdout().writer(init.io, buf);

    const ir = try parser.parse(gpa, source);
    try stdout.interface.print(
        "Program Parses!\nTerm: {f}\n",
        .{ir},
    );
    try stdout.flush();
    const ty: ?*core.Ty = tychk.typeOf(gpa, ir, null) catch null;
    if (ty) |_| {
        try stdout.interface.print("Program Type Checks!!!\n", .{});
        try stdout.flush();
    }
    try interpreter.eval(gpa, ir, null);
    try stdout.interface.print(
        "{f}\n",
        .{ir},
    );
    try stdout.flush();
}
