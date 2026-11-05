//! Host oracle test for ext2core.zig: walk an ext2 image through the core and
//! compare every entry with the source directory the image was built from
//! (mke2fs -d). Usage: walk <image> <srcdir>. Prints one line per entry and
//! "WALK PASS n=<entries>" or exits 1 at the first mismatch.
const std = @import("std");
const core = @import("ext2core");

var file: std.fs.File = undefined;
var bs: u32 = 1024;

fn readCb(_: ?*anyopaque, block: u64, buf: [*]u8) callconv(.c) c_int {
    const n = file.preadAll(buf[0..bs], block * bs) catch return core.EIO;
    if (n != bs) return core.EIO;
    return 0;
}

var entries: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("WALK FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn walk(fs: *core.Fs, alloc: std.mem.Allocator, dir_ino: u32, host: std.fs.Dir, path: []const u8) !void {
    var dir: core.Inode = undefined;
    if (core.ext2c_read_inode(fs, dir_ino, &dir) != 0) fail("read_inode {d}", .{dir_ino});
    // Names seen in the image (minus . .. lost+found) must equal the host dir.
    var seen = std.StringHashMap(void).init(alloc);
    var pos: u64 = 0;
    var ent: core.Dirent = undefined;
    while (true) {
        const r = core.ext2c_readdir(fs, &dir, &pos, &ent);
        if (r < 0) fail("readdir {s}: {d}", .{ path, r });
        if (r == 0) break;
        const name = try alloc.dupe(u8, ent.name[0..ent.name_len]);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.eql(u8, path, "") and std.mem.eql(u8, name, "lost+found")) continue;
        try seen.put(name, {});
        var looked: u32 = 0;
        if (core.ext2c_lookup(fs, &dir, name.ptr, name.len, &looked) != 0 or looked != ent.ino) fail("lookup {s}/{s}", .{ path, name });
        var ip: core.Inode = undefined;
        if (core.ext2c_read_inode(fs, ent.ino, &ip) != 0) fail("inode {s}/{s}", .{ path, name });
        const sub = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name });
        entries += 1;
        switch (ip.mode & 0xF000) {
            0x4000 => {
                var hd = try host.openDir(name, .{ .iterate = true });
                defer hd.close();
                std.debug.print("D {s}\n", .{sub});
                try walk(fs, alloc, ent.ino, hd, sub);
            },
            0x8000 => {
                const want = try host.readFileAlloc(alloc, name, 1 << 30);
                if (want.len != ip.size) fail("{s}: size {d} != host {d}", .{ sub, ip.size, want.len });
                const got = try alloc.alloc(u8, want.len + 7);
                // Read in odd-sized chunks to exercise block straddling.
                var off: usize = 0;
                while (off < want.len) {
                    const chunk = @min(want.len - off, 3001);
                    const n = core.ext2c_read(fs, &ip, off, got.ptr + off, chunk);
                    if (n <= 0) fail("{s}: read at {d} -> {d}", .{ sub, off, n });
                    off += @intCast(n);
                }
                if (core.ext2c_read(fs, &ip, ip.size, got.ptr, 7) != 0) fail("{s}: read past EOF", .{sub});
                if (!std.mem.eql(u8, want, got[0..want.len])) fail("{s}: content differs", .{sub});
                std.debug.print("F {s} {d}\n", .{ sub, want.len });
            },
            0xA000 => {
                var hb: [4096]u8 = undefined;
                const want = try host.readLink(name, &hb);
                var gb: [4096]u8 = undefined;
                const n = core.ext2c_readlink(fs, &ip, &gb, gb.len);
                if (n < 0 or !std.mem.eql(u8, want, gb[0..@intCast(n)])) fail("{s}: link target", .{sub});
                std.debug.print("L {s} -> {s}\n", .{ sub, want });
            },
            else => fail("{s}: unexpected mode {o}", .{ sub, ip.mode }),
        }
    }
    var it = host.iterate();
    while (try it.next()) |h| {
        if (!seen.contains(h.name)) fail("{s}/{s} missing in image", .{ path, h.name });
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const args = try std.process.argsAlloc(alloc);
    file = try std.fs.cwd().openFile(args[1], .{});
    var sb: [1024]u8 = undefined;
    _ = try file.preadAll(&sb, 1024);
    var fs: core.Fs = undefined;
    const prc = core.ext2c_probe(&fs, &sb);
    if (prc != 0) {
        std.debug.print("PROBE REFUSED errno={d}\n", .{prc});
        std.process.exit(2);
    }
    bs = fs.block_size;
    fs.ctx = null;
    fs.read = readCb;
    fs.scratch = (try alloc.alloc(u8, bs)).ptr;
    std.debug.print("probe: bs={d} groups={d} inodes={d} incompat=0x{x}\n", .{ fs.block_size, fs.groups, fs.inodes_count, fs.incompat });
    var host = try std.fs.cwd().openDir(args[2], .{ .iterate = true });
    defer host.close();
    try walk(&fs, alloc, 2, host, "");
    std.debug.print("WALK PASS n={d}\n", .{entries});
}
