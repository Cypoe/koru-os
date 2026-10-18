const std = @import("std");
const silo = @import("silo.zig");
const t = std.testing;

const linux_like = [_][]const u8{ "linux.sys.openat", "linux.ioctl.DRM_IOCTL_AUTH_MAGIC", "fs.read", "", "blk.readx", "BLK.READ" };

fn isRefused(o: silo.Outcome, r: silo.Reason) bool {
    return switch (o) { .refused => |x| x == r, else => false };
}

test "DS0-1 empty manifest refuses every driver row and every other identity" {
    var m = try silo.Membrane.init(t.allocator, 7, .{ .silo = "empty0", .exports = &.{} });
    defer m.deinit();
    const h = try m.mint();
    for (silo.driver_rows) |id| try t.expect(isRefused(try m.call(h, id), .not_in_manifest));
    for (linux_like) |id| try t.expect(isRefused(try m.call(h, id), .not_a_driver_row));
    try t.expectEqual(silo.driver_rows.len + linux_like.len, m.refusals);
    // Every refusal is logged, one line each, naming identity and silo.
    try t.expectEqual(m.refusals, std.mem.count(u8, m.log.items, "\n"));
    try t.expect(std.mem.indexOf(u8, m.log.items, "refused: kms.atomic silo=empty0 reason=not_in_manifest") != null);
}

test "DS0-2 manifest may only name driver rows" {
    try t.expectError(error.NotADriverRow, silo.Membrane.init(t.allocator, 1, .{ .silo = "bad", .exports = &.{ "blk.read", "linux.sys.mount" } }));
}

test "DS0-3 listed row dispatches, unlisted driver row is refused" {
    var m = try silo.Membrane.init(t.allocator, 2, .{ .silo = "blk0", .exports = &.{ "blk.info", "blk.read" } });
    defer m.deinit();
    const h = try m.mint();
    try t.expectEqualStrings("blk.read", (try m.call(h, "blk.read")).dispatched);
    try t.expect(isRefused(try m.call(h, "blk.write"), .not_in_manifest));
}

test "DS0-4 forged handles are refused" {
    var m = try silo.Membrane.init(t.allocator, 3, .{ .silo = "blk0", .exports = &.{"blk.read"} });
    defer m.deinit();
    const h = try m.mint();
    var f = h; f.tag ^= 1;                        try t.expect(isRefused(try m.call(f, "blk.read"), .forged_handle));
    f = h; f.slot = 1;                            try t.expect(isRefused(try m.call(f, "blk.read"), .forged_handle));
    f = h; f.generation += 1;                     try t.expect(isRefused(try m.call(f, "blk.read"), .forged_handle));
    f = h; f.epoch += 1;                          try t.expect(isRefused(try m.call(f, "blk.read"), .forged_handle));
    f = h; f.slot = 9999;                         try t.expect(isRefused(try m.call(f, "blk.read"), .forged_handle));
    f = h; f.silo_id = 4;                         try t.expect(isRefused(try m.call(f, "blk.read"), .wrong_silo));
    // 100k random handles for this silo: none may pass.
    var prng = std.Random.DefaultPrng.init(0xD50);
    const r = prng.random();
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const g = silo.Handle{ .silo_id = 3, .slot = r.uintLessThan(u32, 64), .generation = r.int(u32) % 4, .epoch = 1, .tag = r.int(u64) };
        switch (try m.call(g, "blk.read")) { .dispatched => return error.ForgeryAccepted, .refused => {} }
    }
    // The genuine handle still works.
    try t.expectEqualStrings("blk.read", (try m.call(h, "blk.read")).dispatched);
}

test "DS0-5 silo restart revokes old handles (refused as revoked, not hung)" {
    var m = try silo.Membrane.init(t.allocator, 5, .{ .silo = "gpu0", .exports = &.{"kms.getresources"} });
    defer m.deinit();
    const old = try m.mint();
    m.restart();
    try t.expect(isRefused(try m.call(old, "kms.getresources"), .revoked));
    const new = try m.mint();
    try t.expect(new.epoch == old.epoch + 1);
    try t.expectEqualStrings("kms.getresources", (try m.call(new, "kms.getresources")).dispatched);
}
