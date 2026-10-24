// koru/hosted/linux.zig — the hosted/linux provider shim.
//
// Realizes the same extern contract the lifts declare (uk_blkdev_*,
// ukplat_monotonic_clock, koru_spawn_*, koruos_nid_obj_*) over host
// Linux primitives. The lifts do not know which arm they run on —
// these symbols are the seam.
//
//   uk_blkdev_*   → a file-backed block device: $KORU_BLK0 is a disk
//                   image; requests complete synchronously inside
//                   submit_one (pread/pwrite/fsync). The ext2 lift is
//                   byte-identical to the native run.
//   koru_spawn_*  → real isolation: image written to a private /tmp
//                   file, fork+execve, waitpid — a host process, not
//                   a ring-3 child. The `rights` bag is ADVISORY here:
//                   host execve cannot carry a koru bag (seccomp-bpf
//                   is the future mechanism); every spawn says so.
//   koruos_nid_*  → the identity store's PERSISTENT realization:
//                   a flat text file ($KORU_NID_STORE, default
//                   ./nid.store) of `nid foreign key` rows, same
//                   mint convention as native (sha256 "koruos.nid.v1|").
//                   Refusal semantics identical: nid==0 on collision,
//                   key-conflict; -1 on unbound key lookup.
//
// What this arm deliberately does NOT do: no IRQ/park story (requests
// never pend), no preemption (host scheduler owns it), no bag
// enforcement. Those are koru-native's job; hosted exists to prove
// the identity/dispatch layer on honest primitives.

const std = @import("std");

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) c_int;

fn say(comptime f: []const u8, a: anytype) void {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, f ++ "\n", a) catch return;
    _ = fputs(s.ptr, stdout);
}

// ---------------------------------------------------------------- blkdev
// Dev's head is BlkPub — the lift casts the handle to *const BlkPub to
// read capabilities (see ext2 mount). Layout must match koru/native.

const Cap = extern struct {
    sectors: usize,
    ssize: usize,
    mode: c_int,
    max_sectors_per_req: usize,
    ioalign: u16,
};
const BlkPub = extern struct {
    submit_one: ?*anyopaque,
    finish_reqs: ?*anyopaque,
    _data: ?*anyopaque,
    capabilities: Cap,
};
const BlkReq = extern struct {
    operation: c_int,
    start_sector: usize,
    nb_sectors: usize,
    aio_buf: ?*anyopaque,
    cb: ?*const fn (*BlkReq, ?*anyopaque) callconv(.c) void,
    cb_cookie: ?*anyopaque,
    state: c_int,
    result: c_int,
};

const Dev = extern struct {
    pub_: BlkPub,
    fd: c_int,
    open: c_int,
};

var dev: Dev = .{
    .pub_ = .{
        .submit_one = @ptrFromInt(1), // nonzero tokens; the lift reads
        .finish_reqs = @ptrFromInt(1), // capabilities only
        ._data = null,
        .capabilities = .{ .sectors = 0, .ssize = 512, .mode = 0, .max_sectors_per_req = 128, .ioalign = 512 },
    },
    .fd = -1,
    .open = 0,
};

const REQ_FINISHED: c_int = 0;
const STATUS_SUCCESS: c_int = 0x1;

fn openDev() bool {
    if (dev.open != 0) return dev.fd >= 0;
    dev.open = 1;
    const path = std.posix.getenv("KORU_BLK0") orelse {
        say("blkdev: KORU_BLK0 unset — no hosted block device", .{});
        dev.fd = -1;
        return false;
    };
    var pbuf: [4096]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return false;
    dev.fd = std.posix.open(pz, .{ .ACCMODE = .RDWR }, 0) catch |e| {
        say("blkdev: open {s} failed: {s}", .{ path, @errorName(e) });
        dev.fd = -1;
        return false;
    };
    const st = std.posix.fstat(dev.fd) catch {
        std.posix.close(dev.fd);
        dev.fd = -1;
        return false;
    };
    dev.pub_.capabilities.sectors = @intCast(@divTrunc(st.size, 512));
    say("blkdev: {s} sectors={d}", .{ path, dev.pub_.capabilities.sectors });
    return true;
}

pub export fn uk_blkdev_get(id: c_uint) callconv(.c) ?*anyopaque {
    if (id != 0) return null;
    if (!openDev()) return null;
    return @ptrCast(&dev);
}
pub export fn uk_blkdev_configure(d: ?*anyopaque, conf: ?*const anyopaque) callconv(.c) c_int {
    _ = d;
    _ = conf;
    return 0;
}
const QueueInfo = extern struct { nb_max: u16, nb_min: u16, nb_align: u16, nb_is_power_of_two: c_int };
pub export fn uk_blkdev_queue_get_info(d: ?*anyopaque, queue_id: u16, q_info: ?*QueueInfo) callconv(.c) c_int {
    _ = d;
    if (queue_id != 0 or q_info == null) return -22;
    q_info.?.* = .{ .nb_max = 8, .nb_min = 1, .nb_align = 1, .nb_is_power_of_two = 1 };
    return 0;
}
pub export fn uk_blkdev_queue_configure(d: ?*anyopaque, queue_id: u16, nb_desc: u16, conf: ?*const anyopaque) callconv(.c) c_int {
    _ = d;
    _ = nb_desc;
    _ = conf;
    if (queue_id != 0) return -22;
    return 0;
}
pub export fn uk_blkdev_start(d: ?*anyopaque) callconv(.c) c_int {
    _ = d;
    return 0;
}
pub export fn uk_blkdev_stop(d: ?*anyopaque) callconv(.c) c_int {
    _ = d;
    return 0;
}
pub export fn uk_blkdev_queue_unconfigure(d: ?*anyopaque, queue_id: u16) callconv(.c) c_int {
    _ = d;
    _ = queue_id;
    return 0;
}
pub export fn uk_blkdev_unconfigure(d: ?*anyopaque) callconv(.c) c_int {
    _ = d;
    return 0;
}

// submit_one: the transfer completes inside the call — file I/O never
// pends, so finish_reqs below is the empty answer. Errors land in
// req.result like a device error would.
pub export fn uk_blkdev_queue_submit_one(d: ?*anyopaque, queue_id: u16, req: ?*BlkReq) callconv(.c) c_int {
    _ = d;
    if (queue_id != 0 or req == null) return -22;
    const r = req.?;
    const off = r.start_sector * 512;
    const len = r.nb_sectors * 512;
    var rc: c_int = 0;
    switch (r.operation) {
        0 => { // READ
            const n = std.posix.pread(dev.fd, @as([*]u8, @ptrCast(r.aio_buf.?))[0..len], off) catch blk: {
                rc = -5; // EIO
                break :blk 0;
            };
            if (n != len) rc = -5;
        },
        1 => { // WRITE
            const n = std.posix.pwrite(dev.fd, @as([*]const u8, @ptrCast(r.aio_buf.?))[0..len], off) catch blk: {
                rc = -5;
                break :blk 0;
            };
            if (n != len) rc = -5;
        },
        4 => std.posix.fsync(dev.fd) catch {
            rc = -5;
        },
        else => rc = -22, // EINVAL — unsupported op refuses by code
    }
    r.state = REQ_FINISHED;
    r.result = rc;
    return STATUS_SUCCESS;
}
pub export fn uk_blkdev_queue_finish_reqs(d: ?*anyopaque, queue_id: u16) callconv(.c) c_int {
    _ = d;
    _ = queue_id;
    return 0; // never pending — submit completes inline
}

pub export var _uk_alloc_head: ?*anyopaque = null;

// musl has no memalign; the ext2 lift's staging buffer is the only user.
pub export fn memalign(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    var p: ?*anyopaque = null;
    if (std.c.posix_memalign(&p, alignment, size) != 0) return null;
    return p;
}

// ---------------------------------------------------------------- clock
pub export fn ukplat_monotonic_clock() callconv(.c) u64 {
    const t = std.time.nanoTimestamp();
    return if (t < 0) 0 else @intCast(t);
}

// ---------------------------------------------------------------- spawn
// fork+execve+waitpid — real host processes. The bag is printed but
// not enforced: seccomp-bpf is the future mechanism, so hosted spawns
// say "advisory" rather than pretend enforcement.

var tmp_seq: u32 = 0;

fn stageImage(image: [*]const u8, size: usize) ![:0]u8 {
    const pid = std.os.linux.getpid();
    const p = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "/tmp/koru-child-{d}-{d}", .{ pid, tmp_seq }, 0);
    tmp_seq +%= 1;
    const fd = try std.posix.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o700);
    var w: usize = 0;
    while (w < size) w += try std.posix.write(fd, image[w..size]);
    std.posix.close(fd);
    return p;
}

fn waitStatus(pid: std.posix.pid_t) c_int {
    while (true) {
        const r = std.posix.waitpid(pid, 0);
        if (std.posix.W.IFEXITED(r.status)) return @intCast(std.posix.W.EXITSTATUS(r.status));
        if (std.posix.W.IFSIGNALED(r.status)) return @intCast(128 + std.posix.W.TERMSIG(r.status));
    }
}

fn spawnOne(image: [*]const u8, size: usize) !std.posix.pid_t {
    const path = try stageImage(image, size);
    errdefer std.posix.unlink(path) catch {};
    const pid = try std.posix.fork();
    if (pid == 0) {
        // child: exec the staged image; on failure exit 127 like a shell.
        var argv_buf = [_:null]?[*:0]const u8{ path.ptr, null };
        var envp_buf = [_:null]?[*:0]const u8{};
        const err = std.posix.execveZ(path.ptr, &argv_buf, &envp_buf);
        _ = err catch {};
        std.posix.exit(127);
    }
    return pid;
}

var spawn_said = false;
fn spawnNote(rights: u64) void {
    if (spawn_said) return;
    spawn_said = true;
    say("spawn: hosted — rights bag {x} advisory (seccomp pending); children are real host processes", .{rights});
}

pub export fn koru_spawn_elf(image: [*]const u8, size: usize, rights: u64) callconv(.c) c_int {
    spawnNote(rights);
    const pid = spawnOne(image, size) catch |e| {
        say("spawn: stage/fork failed: {s}", .{@errorName(e)});
        return -1;
    };
    const st = waitStatus(pid);
    return st;
}

pub export fn koru_spawn_run(imgs: [*]const [*]const u8, sizes: [*]const usize, rights: [*]const u64, n: usize) callconv(.c) c_int {
    spawnNote(rights[0]);
    var pids: [8]std.posix.pid_t = undefined;
    var spawned: usize = 0;
    defer {
        var i: usize = 0;
        while (i < spawned) : (i += 1) _ = waitStatus(pids[i]);
    }
    var i: usize = 0;
    while (i < n and i < pids.len) : (i += 1) {
        pids[i] = spawnOne(imgs[i], sizes[i]) catch {
            say("spawn: roster child {d} failed", .{i});
            // drain the rest in defer; report failure via negative status
            spawned = i + 1;
            return -1;
        };
        spawned = i + 1;
    }
    if (n > pids.len) return -1;
    var last: c_int = 0;
    i = 0;
    while (i < spawned) : (i += 1) last = waitStatus(pids[i]);
    spawned = 0; // all waited — disarm the defer drain
    return last;
}

// ---------------------------------------------------------------- nid store
// Persistent realization: $KORU_NID_STORE (default ./nid.store) holds
// rows "nid_hex key_hex foreign". Loaded lazily into an arena; pin
// appends + flushes. Same mint + refusal semantics as native.

const ObjPin = struct { nid: u64, key: u64, foreign: []u8 };
var nid_arena: ?std.heap.ArenaAllocator = null;
var nid_rows: std.ArrayListUnmanaged(ObjPin) = .{};
var nid_loaded = false;

fn nidAlloc() std.mem.Allocator {
    if (nid_arena == null) nid_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return nid_arena.?.allocator();
}

fn nidPath() [:0]const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
        var path: ?[:0]const u8 = null;
    };
    if (S.path == null) {
        const p = std.posix.getenv("KORU_NID_STORE") orelse "./nid.store";
        S.path = std.fmt.bufPrintZ(&S.buf, "{s}", .{p}) catch "./nid.store";
    }
    return S.path.?;
}

fn nidLoad() void {
    if (nid_loaded) return;
    nid_loaded = true;
    const a = nidAlloc();
    const f = std.fs.cwd().openFileZ(nidPath(), .{}) catch return; // absent = empty store
    defer f.close();
    const body = f.readToEndAlloc(a, 1 << 24) catch return;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |line| {
        var f2 = std.mem.tokenizeScalar(u8, line, ' ');
        const nids = f2.next() orelse continue;
        const keys = f2.next() orelse continue;
        const foreign = f2.rest();
        const nid = std.fmt.parseInt(u64, nids, 16) catch continue;
        const key = std.fmt.parseInt(u64, keys, 16) catch continue;
        if (foreign.len == 0) continue;
        const fd = a.dupe(u8, std.mem.trim(u8, foreign, " \r")) catch continue;
        nid_rows.append(a, .{ .nid = nid, .key = key, .foreign = fd }) catch continue;
    }
}

fn nidHash(foreign: []const u8) u64 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("koruos.nid.v1|");
    h.update(foreign);
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.mem.readInt(u64, d[0..8], .big);
}

fn nidFlush(nid: u64, key: u64, foreign: []const u8) void {
    const f = std.fs.cwd().createFile(nidPath(), .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    var b: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&b, "{x} {x} {s}\n", .{ nid, key, foreign }) catch return;
    f.writeAll(line) catch {};
}

pub export fn koruos_nid_obj_pin(foreign_ptr: [*:0]const u8, key: u64) callconv(.c) u64 {
    nidLoad();
    const foreign = std.mem.span(foreign_ptr);
    const nid = nidHash(foreign);
    for (nid_rows.items) |p| {
        if (p.nid != nid) continue;
        if (std.mem.eql(u8, p.foreign, foreign)) {
            if (p.key != key) {
                say("pin refused: foreign={s} nid binds a different key (held={x} asked={x})", .{ foreign, p.key, key });
                return 0;
            }
            return nid; // idempotent: same object, same identity
        }
        say("pin refused: nid collision foreign={s} nid={x}", .{ foreign, nid });
        return 0;
    }
    const a = nidAlloc();
    const fd = a.dupe(u8, foreign) catch return 0;
    nid_rows.append(a, .{ .nid = nid, .key = key, .foreign = fd }) catch return 0;
    nidFlush(nid, key, foreign);
    say("pin: foreign={s} nid={x} key={x}", .{ foreign, nid, key });
    return nid;
}

pub export fn koruos_nid_obj_key(nid: u64) callconv(.c) i64 {
    nidLoad();
    for (nid_rows.items) |p| {
        if (p.nid == nid) return @bitCast(p.key);
    }
    return -1;
}
