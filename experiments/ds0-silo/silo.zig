//! DS0: driver-silo contract and refusal harness (DESIGN-0001 §0.6, R-SILO-2..4).
//!
//! Minimal host code, not yet Koru. It models the membrane between a client and a
//! driver silo:
//!   - a manifest with a closed export list drawn from the driver row set;
//!   - handles minted only by the membrane: slot index + generation + epoch + a
//!     keyed tag, so a handle cannot be fabricated from its visible fields;
//!   - every call is either dispatched or refused, and every refusal is logged
//!     as `refused: <identity> silo=<id> reason=<reason>`.
//! Nothing here touches a device. That comes in DS1/DS2.
const std = @import("std");

/// The driver row set: the only identities a driver silo may ever export.
pub const driver_rows = [_][]const u8{
    "blk.info",           "blk.read",          "blk.write",       "blk.flush",
    "net.tx",             "net.rx",            "net.link",        "kms.version",
    "kms.getcap",         "kms.getresources",  "kms.getconnector", "kms.getencoder",
    "kms.getcrtc",        "kms.create_dumb",   "kms.map_dumb",    "kms.destroy_dumb",
    "kms.addfb2",         "kms.rmfb",          "kms.setcrtc",     "kms.page_flip",
    "kms.atomic",         "kms.gem_close",     "kms.prime_export", "kms.event",
    "input.caps",         "input.name",        "input.grab",      "input.event",
};

pub fn inDriverRowSet(identity: []const u8) bool {
    for (driver_rows) |r| if (std.mem.eql(u8, r, identity)) return true;
    return false;
}

pub const Reason = enum { not_in_manifest, not_a_driver_row, forged_handle, revoked, wrong_silo };

pub const Manifest = struct {
    silo: []const u8,
    exports: []const []const u8,

    /// A manifest may only name driver rows (R-SILO-2). Checked at load time.
    pub fn validate(self: Manifest) error{NotADriverRow}!void {
        for (self.exports) |e| if (!inDriverRowSet(e)) return error.NotADriverRow;
    }
    fn exports_(self: Manifest, identity: []const u8) bool {
        for (self.exports) |e| if (std.mem.eql(u8, e, identity)) return true;
        return false;
    }
};

/// What a client holds. All fields are visible to the client; `tag` binds them
/// to a key only the membrane knows.
pub const Handle = struct { silo_id: u32, slot: u32, generation: u32, epoch: u32, tag: u64 };

pub const Outcome = union(enum) { dispatched: []const u8, refused: Reason };

pub const Membrane = struct {
    const max_slots = 64;
    silo_id: u32,
    manifest: Manifest,
    epoch: u32 = 1,
    key: [32]u8,
    live: [max_slots]bool = [_]bool{false} ** max_slots,
    gens: [max_slots]u32 = [_]u32{0} ** max_slots,
    log: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    refusals: usize = 0,

    pub fn init(gpa: std.mem.Allocator, silo_id: u32, manifest: Manifest) !Membrane {
        try manifest.validate();
        var key: [32]u8 = undefined;
        std.crypto.random.bytes(&key);
        return .{ .silo_id = silo_id, .manifest = manifest, .key = key, .log = .empty, .gpa = gpa };
    }
    pub fn deinit(self: *Membrane) void { self.log.deinit(self.gpa); }

    fn tagFor(self: *const Membrane, silo_id: u32, slot: u32, gen: u32, epoch: u32) u64 {
        var msg: [16]u8 = undefined;
        std.mem.writeInt(u32, msg[0..4], silo_id, .little);
        std.mem.writeInt(u32, msg[4..8], slot, .little);
        std.mem.writeInt(u32, msg[8..12], gen, .little);
        std.mem.writeInt(u32, msg[12..16], epoch, .little);
        var out: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&out, &msg, &self.key);
        return std.mem.readInt(u64, out[0..8], .little);
    }

    pub fn mint(self: *Membrane) !Handle {
        for (&self.live, 0..) |*l, i| if (!l.*) {
            l.* = true;
            self.gens[i] +%= 1;
            const s: u32 = @intCast(i);
            return .{ .silo_id = self.silo_id, .slot = s, .generation = self.gens[i], .epoch = self.epoch,
                      .tag = self.tagFor(self.silo_id, s, self.gens[i], self.epoch) };
        };
        return error.NoFreeSlot;
    }

    /// Silo restart (R-SILO-4): bump the epoch, drop every slot.
    pub fn restart(self: *Membrane) void {
        self.epoch +%= 1;
        @memset(&self.live, false);
    }

    fn refuse(self: *Membrane, identity: []const u8, r: Reason) !Outcome {
        self.refusals += 1;
        try self.log.writer(self.gpa).print("refused: {s} silo={s} reason={s}\n", .{ identity, self.manifest.silo, @tagName(r) });
        return .{ .refused = r };
    }

    pub fn call(self: *Membrane, h: Handle, identity: []const u8) !Outcome {
        if (h.silo_id != self.silo_id) return self.refuse(identity, .wrong_silo);
        if (h.slot >= max_slots or h.tag != self.tagFor(h.silo_id, h.slot, h.generation, h.epoch))
            return self.refuse(identity, .forged_handle);
        // Authentic, but from an earlier epoch or a released slot: revoked, not hung.
        if (h.epoch != self.epoch or !self.live[h.slot] or self.gens[h.slot] != h.generation)
            return self.refuse(identity, .revoked);
        if (!inDriverRowSet(identity)) return self.refuse(identity, .not_a_driver_row);
        if (!self.manifest.exports_(identity)) return self.refuse(identity, .not_in_manifest);
        return .{ .dispatched = identity };
    }
};
