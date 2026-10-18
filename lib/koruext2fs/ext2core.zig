//! koru-os ext2 read path (B7). Freestanding, allocation-free, C ABI.
//! Block I/O is a callback, so the same code runs in the unikernel (ukblkdev
//! via ext2fs_vfs.c) and in host tests (a file-backed reader). No locking here:
//! the caller serialises (ext2fs_vfs.c holds one mutex per mount).
//!
//! Supported: rev 0/1, block size 1/2/4 KiB, any number of groups, direct +
//! single/double/triple indirect blocks, holes, fast and slow symlinks,
//! incompat FILETYPE only (anything else is refused at mount; ro_compat is
//! accepted because this path never writes).

const std = @import("std");

pub const ReadFn = *const fn (ctx: ?*anyopaque, block: u64, buf: [*]u8) callconv(.c) c_int;

pub const EINVAL: c_int = 22;
pub const EIO: c_int = 5;
pub const ENOENT: c_int = 2;
pub const ENOTDIR: c_int = 20;
pub const EOPNOTSUPP: c_int = 95;
pub const EFBIG: c_int = 27;

pub const INCOMPAT_FILETYPE: u32 = 0x0002;

/// Mount state. `scratch` must point at `block_size` bytes owned by the caller
/// (allocated after `ext2c_probe` reports the block size).
pub const Fs = extern struct {
    ctx: ?*anyopaque,
    read: ReadFn,
    scratch: ?[*]u8,
    block_size: u32,
    inodes_count: u32,
    blocks_count: u32,
    free_blocks: u32,
    free_inodes: u32,
    first_data_block: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_size: u32,
    groups: u32,
    rev: u32,
    incompat: u32,
    ro_compat: u32,
};

pub const Inode = extern struct {
    ino: u32,
    mode: u16,
    links: u16,
    uid: u16,
    gid: u16,
    flags: u32,
    size: u64,
    atime: u32,
    ctime: u32,
    mtime: u32,
    blocks512: u32,
    file_acl: u32,
    block: [15]u32,
};

pub const Dirent = extern struct {
    ino: u32,
    file_type: u8, // ext2 file type (0 unknown, 1 reg, 2 dir, 7 symlink, ...)
    name_len: u8,
    name: [256]u8, // NUL-terminated
};

fn le16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn le32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Parse the 1024-byte superblock (disk bytes 1024..2047). Fills `fs` but not
/// ctx/read/scratch. Returns 0 or a positive errno.
pub export fn ext2c_probe(fs: *Fs, sb_ptr: [*]const u8) c_int {
    const sb = sb_ptr[0..1024];
    if (le16(sb, 56) != 0xEF53) return EINVAL;
    const log = le32(sb, 24);
    if (log > 2) return EOPNOTSUPP; // 1, 2, 4 KiB only
    fs.block_size = @as(u32, 1024) << @intCast(log);
    fs.inodes_count = le32(sb, 0);
    fs.blocks_count = le32(sb, 4);
    fs.free_blocks = le32(sb, 12);
    fs.free_inodes = le32(sb, 16);
    fs.first_data_block = le32(sb, 20);
    fs.blocks_per_group = le32(sb, 32);
    fs.inodes_per_group = le32(sb, 40);
    fs.rev = le32(sb, 76);
    if (fs.rev == 0) {
        fs.inode_size = 128;
        fs.incompat = 0;
        fs.ro_compat = 0;
    } else {
        fs.inode_size = le16(sb, 88);
        fs.incompat = le32(sb, 96);
        fs.ro_compat = le32(sb, 100);
    }
    if (fs.blocks_per_group == 0 or fs.inodes_per_group == 0) return EINVAL;
    if (fs.inode_size < 128 or fs.inode_size > fs.block_size or (fs.inode_size & (fs.inode_size - 1)) != 0) return EINVAL;
    if ((fs.incompat & ~INCOMPAT_FILETYPE) != 0) return EOPNOTSUPP;
    if (fs.blocks_count <= fs.first_data_block) return EINVAL;
    fs.groups = (fs.blocks_count - fs.first_data_block + fs.blocks_per_group - 1) / fs.blocks_per_group;
    if (fs.groups == 0 or fs.inodes_count > fs.groups * fs.inodes_per_group) return EINVAL;
    return 0;
}

fn readBlock(fs: *Fs, block: u64) c_int {
    if (block == 0 or block >= fs.blocks_count) return EIO;
    return fs.read(fs.ctx, block, fs.scratch.?);
}

pub export fn ext2c_read_inode(fs: *Fs, ino: u32, out: *Inode) c_int {
    if (ino == 0 or ino > fs.inodes_count) return EINVAL;
    const group = (ino - 1) / fs.inodes_per_group;
    const index = (ino - 1) % fs.inodes_per_group;
    // Group descriptor table starts in the block after the superblock's block.
    const gdt = @as(u64, fs.first_data_block) + 1;
    const per_block = fs.block_size / 32;
    var rc = readBlock(fs, gdt + group / per_block);
    if (rc != 0) return rc;
    const s = fs.scratch.?[0..fs.block_size];
    const gd_off = (group % per_block) * 32;
    const itable = le32(s, gd_off + 8);
    const byte = @as(u64, index) * fs.inode_size;
    rc = readBlock(fs, itable + byte / fs.block_size);
    if (rc != 0) return rc;
    const off: usize = @intCast(byte % fs.block_size);
    const r = s[off .. off + 128];
    out.ino = ino;
    out.mode = le16(r, 0);
    out.uid = le16(r, 2);
    out.size = le32(r, 4);
    out.atime = le32(r, 8);
    out.ctime = le32(r, 12);
    out.mtime = le32(r, 16);
    out.gid = le16(r, 24);
    out.links = le16(r, 26);
    out.blocks512 = le32(r, 28);
    out.flags = le32(r, 32);
    out.file_acl = le32(r, 104);
    // Regular files: i_size_high (LARGE_FILE). Directories keep it as dir_acl.
    if ((out.mode & 0xF000) == 0x8000) out.size |= @as(u64, le32(r, 108)) << 32;
    for (0..15) |i| out.block[i] = le32(r, 40 + 4 * i);
    return 0;
}

/// Logical → physical block. *out = 0 means a hole.
pub export fn ext2c_bmap(fs: *Fs, ip: *const Inode, lblk: u64, out: *u64) c_int {
    const ppb: u64 = fs.block_size / 4;
    var l = lblk;
    if (l < 12) {
        out.* = ip.block[@intCast(l)];
        return 0;
    }
    l -= 12;
    var depth: u32 = 0;
    var span: u64 = 1;
    var root: u32 = 0;
    if (l < ppb) {
        depth = 1;
        root = ip.block[12];
    } else {
        l -= ppb;
        if (l < ppb * ppb) {
            depth = 2;
            root = ip.block[13];
            span = ppb;
        } else {
            l -= ppb * ppb;
            if (l >= ppb * ppb * ppb) return EFBIG;
            depth = 3;
            root = ip.block[14];
            span = ppb * ppb;
        }
    }
    var cur: u64 = root;
    while (depth > 0) : (depth -= 1) {
        if (cur == 0) {
            out.* = 0;
            return 0;
        }
        const rc = readBlock(fs, cur);
        if (rc != 0) return rc;
        const idx = l / span;
        l %= span;
        span = if (span > 1) span / ppb else 1;
        cur = le32(fs.scratch.?[0..fs.block_size], @intCast(idx * 4));
    }
    out.* = cur;
    return 0;
}

/// Read up to `len` bytes at `off` into `buf`. Returns bytes read (>= 0) or -errno.
pub export fn ext2c_read(fs: *Fs, ip: *const Inode, off: u64, buf: [*]u8, len: u64) i64 {
    if (off >= ip.size) return 0;
    const total: u64 = @min(len, ip.size - off);
    var done: u64 = 0;
    while (done < total) {
        const pos = off + done;
        const lblk = pos / fs.block_size;
        const in_blk = pos % fs.block_size;
        const n = @min(total - done, fs.block_size - in_blk);
        var pblk: u64 = 0;
        var rc = ext2c_bmap(fs, ip, lblk, &pblk);
        if (rc != 0) return -@as(i64, rc);
        if (pblk == 0) {
            @memset(buf[@intCast(done)..@intCast(done + n)], 0);
        } else {
            rc = readBlock(fs, pblk);
            if (rc != 0) return -@as(i64, rc);
            @memcpy(buf[@intCast(done)..@intCast(done + n)], fs.scratch.?[@intCast(in_blk)..@intCast(in_blk + n)]);
        }
        done += n;
    }
    return @intCast(done);
}

/// Next live directory entry at byte position *pos (advanced past it).
/// Returns 1 with `out` filled, 0 at the end, or -errno.
pub export fn ext2c_readdir(fs: *Fs, dir: *const Inode, pos: *u64, out: *Dirent) c_int {
    if ((dir.mode & 0xF000) != 0x4000) return -ENOTDIR;
    while (pos.* < dir.size) {
        const lblk = pos.* / fs.block_size;
        const in_blk: usize = @intCast(pos.* % fs.block_size);
        var pblk: u64 = 0;
        var rc = ext2c_bmap(fs, dir, lblk, &pblk);
        if (rc != 0) return -rc;
        if (pblk == 0) return -EIO; // directories have no holes
        rc = readBlock(fs, pblk);
        if (rc != 0) return -rc;
        const s = fs.scratch.?[0..fs.block_size];
        if (in_blk + 8 > fs.block_size) return -EIO;
        const ino = le32(s, in_blk);
        const rec_len = le16(s, in_blk + 4);
        const name_len: usize = if ((fs.incompat & INCOMPAT_FILETYPE) != 0) s[in_blk + 6] else le16(s, in_blk + 6) & 0xFF;
        if (rec_len < 8 or (rec_len & 3) != 0 or in_blk + rec_len > fs.block_size or 8 + name_len > rec_len) return -EIO;
        pos.* += rec_len;
        if (ino == 0) continue;
        out.ino = ino;
        out.file_type = if ((fs.incompat & INCOMPAT_FILETYPE) != 0) s[in_blk + 7] else 0;
        out.name_len = @intCast(name_len);
        @memcpy(out.name[0..name_len], s[in_blk + 8 .. in_blk + 8 + name_len]);
        out.name[name_len] = 0;
        return 1;
    }
    return 0;
}

pub export fn ext2c_lookup(fs: *Fs, dir: *const Inode, name: [*]const u8, name_len: usize, out_ino: *u32) c_int {
    var pos: u64 = 0;
    var ent: Dirent = undefined;
    while (true) {
        const r = ext2c_readdir(fs, dir, &pos, &ent);
        if (r < 0) return -r;
        if (r == 0) return ENOENT;
        if (ent.name_len == name_len and std.mem.eql(u8, ent.name[0..name_len], name[0..name_len])) {
            out_ino.* = ent.ino;
            return 0;
        }
    }
}

/// Symlink target into buf (no NUL). Returns length or -errno.
pub export fn ext2c_readlink(fs: *Fs, ip: *const Inode, buf: [*]u8, cap: u64) i64 {
    if ((ip.mode & 0xF000) != 0xA000) return -EINVAL;
    const n: u64 = @min(ip.size, cap);
    // Fast symlink: target stored in i_block when it fits and no data block
    // is accounted (blocks512 counts only the EA block then).
    const ea: u32 = if (ip.file_acl != 0) fs.block_size / 512 else 0;
    if (ip.size < 60 and ip.blocks512 == ea) {
        const raw: [*]const u8 = @ptrCast(&ip.block);
        @memcpy(buf[0..@intCast(n)], raw[0..@intCast(n)]);
        return @intCast(n);
    }
    return ext2c_read(fs, ip, 0, buf, n);
}
