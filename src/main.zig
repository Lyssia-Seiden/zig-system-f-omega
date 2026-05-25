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

    const ir = try parser.parse(gpa, source);
    const ty: ?*core.Ty = tychk.typeOf(gpa, ir, null) catch null;
    if (ty) |_| {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Program Type Checks!\n");
    }
    try interpreter.eval(gpa, ir, null);
    const buf = try gpa.alloc(u8, 64);
    var stdout = std.Io.File.stdout().writer(init.io, buf);
    try stdout.interface.print(
        "{f}\n",
        .{core.TermWCtx{ .term = ir, .ctx = null }},
    );
    try stdout.flush();
}
