// koru/hosted/linux.zig — the hosted/linux provider shim.
//
// Shared machinery (file-backed uk_blkdev_*, ukplat clock, persistent
// nid store, staging/reap helpers) lives in common.zig; this file owns
// the spawn seam for Linux: fork+execve+waitpid — real host processes,
// not a ring-3 child. The `rights` bag is ADVISORY here: execve cannot
// carry a koru bag (seccomp-bpf is the future mechanism), and the
// spawn says so rather than pretend enforcement. hosted/freebsd.zig is
// the sibling where the bag actually bites (Capsicum).

const std = @import("std");
const common = @import("common.zig");

comptime {
    // referencing common triggers its container analysis — the export
    // force-block at the bottom of common.zig emits the shared externs.
    _ = common;
}

// ---------------------------------------------------------------- spawn
fn spawnOne(image: [*]const u8, size: usize) !std.posix.pid_t {
    const path = try common.stageImage(image, size);
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
    common.say("spawn: hosted/linux — rights bag {x} advisory (seccomp pending); children are real host processes", .{rights});
}

pub export fn koru_spawn_elf(image: [*]const u8, size: usize, rights: u64) callconv(.c) c_int {
    spawnNote(rights);
    const pid = spawnOne(image, size) catch |e| {
        common.say("spawn: stage/fork failed: {s}", .{@errorName(e)});
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
    spawned = 0; // all waited — disarm the defer drain
    return last;
}
