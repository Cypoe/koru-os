// koru/hosted/freebsd.zig — the hosted/freebsd provider shim: the
// Capsicum arm. Sketch, not coverage — it exists to test whether
// koru's rights model is Linux-shaped or honest.
//
// Same extern contract and shared machinery as linux.zig (common.zig);
// the difference is the spawn seam, where the bag actually enforces:
//
//   the staged child image is opened ONCE in the parent, its fd is
//   narrowed with cap_rights_limit to CAP_READ|CAP_FEXECVE|CAP_FSTAT,
//   then pdfork → cap_enter → fexecve(fd). After cap_enter the child
//   is in capability mode: no path namespace, no open(2), no
//   exec-by-name — its whole world is inherited descriptors, and the
//   image fd is its grant. That's a REAL bag, not linux's advisory
//   print: an image that isn't executable-by-capability fails at
//   fexecve, and nothing in the child can reach outside the bag by
//   naming a path.
//
// The honest mapping note this sketch exists to surface: koru's
// `rights` u64 is an NR bitmask over the spawn seam's syscall numbers
// (bit 1 = say, bit 60 = spawn-side grant) — per-OPERATION grants.
// cap_rights_t is per-DESCRIPTOR rights (CAP_READ/CAP_FEXECVE on a
// specific fd). These are different axes: a NR bag answers "which
// calls may you make", a Capsicum bag answers "which objects may you
// touch and how". The nid-scoped grant-object design (bag v2) is the
// Capsicum axis — this shim already enforces that shape: the image
// fd's narrowed rights ARE a per-object grant. The NR bits that have
// no descriptor analogue (say=NR1 today maps to nothing here; the
// child's stdout is inherited write access) are reported as unmapped
// rather than silently granted.
//
// CAPRIGHT encoding from sys/capsicum.h: cap_rights_t is two u64
// words; word i is (1<<(57+i)) | bitmask. Bits used here (index 0):
// CAP_READ=0x1, CAP_FEXECVE=0x80, CAP_FSTAT=0x80000.

const std = @import("std");
const common = @import("common.zig");

comptime {
    // see linux.zig — pulls in common's shared extern surface.
    _ = common;
}

extern fn cap_enter() c_int;
extern fn cap_rights_limit(fd: c_int, rights: *const cap_rights_t) c_int;
extern fn pdfork(pdfork_pd: *c_int, flags: c_int) c_int;
extern fn fexecve(fd: c_int, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;

const cap_rights_t = extern struct { cr_rights: [2]u64 };

fn rightsOf(w0: u64) cap_rights_t {
    // word i carries its index bit (1<<(57+i)); index-1 word is present
    // but empty — the shape __cap_rights_init produces.
    return .{ .cr_rights = .{ (@as(u64, 1) << 57) | w0, @as(u64, 1) << 58 } };
}

const CAP_READ: u64 = 0x1;
const CAP_FEXECVE: u64 = 0x80;
const CAP_FSTAT: u64 = 0x80000;

// The whole child bag: the image descriptor, read+stat+exec only.
const CHILD_IMAGE_RIGHTS = CAP_READ | CAP_FEXECVE | CAP_FSTAT;

var spawn_said = false;
fn spawnNote(rights: u64) void {
    if (spawn_said) return;
    spawn_said = true;
    common.say("spawn: hosted/freebsd — Capsicum enforced: image fd narrowed to CAP_READ|CAP_FEXECVE|CAP_FSTAT, child in cap mode; NR bag {x} has no syscall-number analogue (unmapped bits reported, not granted)", .{rights});
}

// pdfork returns the pid like fork and fills pd with the parent's
// process descriptor — the descriptor is the cap-mode handle (pdkill,
// pdgetpid); reaping still goes through waitpid on the pid.
fn spawnOne(image: [*]const u8, size: usize) !std.posix.pid_t {
    const path = try common.stageImage(image, size);
    errdefer std.posix.unlink(path) catch {};
    // the image is a capability, not a path: open it now, exec by fd.
    const imgfd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0o700);
    errdefer std.posix.close(imgfd);
    var pd: c_int = -1;
    const pid = pdfork(&pd, 0);
    if (pid < 0) return error.PdforkFailed;
    if (pid == 0) {
        // child — narrow the image fd, enter capability mode, exec it.
        const r = rightsOf(CHILD_IMAGE_RIGHTS);
        if (cap_rights_limit(imgfd, &r) != 0) std.posix.exit(126);
        if (cap_enter() != 0) std.posix.exit(126);
        var argv_buf = [_:null]?[*:0]const u8{ "koru-child", null };
        var envp_buf = [_:null]?[*:0]const u8{};
        _ = fexecve(imgfd, &argv_buf, &envp_buf);
        std.posix.exit(127);
    }
    std.posix.close(imgfd);
    return pid;
}

pub export fn koru_spawn_elf(image: [*]const u8, size: usize, rights: u64) callconv(.c) c_int {
    spawnNote(rights);
    const pid = spawnOne(image, size) catch |e| {
        common.say("spawn: stage/pdfork failed: {s}", .{@errorName(e)});
        return -1;
    };
    return common.waitStatus(pid);
}

pub export fn koru_spawn_run(imgs: [*]const [*]const u8, sizes: [*]const usize, rights: [*]const u64, n: usize) callconv(.c) c_int {
    spawnNote(rights[0]);
    var pids: [8]std.posix.pid_t = undefined;
    var spawned: usize = 0;
    defer {
        var i: usize = 0;
        while (i < spawned) : (i += 1) _ = common.waitStatus(pids[i]);
    }
    var i: usize = 0;
    while (i < n and i < pids.len) : (i += 1) {
        pids[i] = spawnOne(imgs[i], sizes[i]) catch {
            common.say("spawn: roster child {d} failed", .{i});
            spawned = i + 1;
            return -1;
        };
        spawned = i + 1;
    }
    if (n > pids.len) return -1;
    var last: c_int = 0;
    i = 0;
    while (i < spawned) : (i += 1) last = common.waitStatus(pids[i]);
    spawned = 0;
    return last;
}
