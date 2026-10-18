# DS0: driver-silo contract and refusal harness (host model)

**Result: 5 of 5 tests pass (M, `evidence/zig-test.log`, Zig 0.15.2, 2026-10-18 CEST).**
This is **host code in Zig**, not yet Koru, and it does not yet run inside a Unikraft
image. It fixes the semantics that the in-image silo and the Koru lift must keep.

Model (DESIGN-0001 §0.6):
- **Manifest.** The silo name plus a closed export list. Loading fails if any entry is
  outside the driver row set (`blk.*`, `net.*`, `kms.*`, `input.*`).
- **Membrane.** The membrane mints every handle. A handle is `{silo_id, slot, generation,
  epoch, tag}`, where `tag` is an HMAC-SHA256 truncated to 64 bits over the other fields,
  keyed with a per-membrane random key. A client cannot construct a valid handle from the
  fields it can see.
- **Calls.** Every call ends as `dispatched` or `refused`. Every refusal appends one line,
  `refused: <identity> silo=<name> reason=<reason>`. The reasons are `wrong_silo`,
  `forged_handle`, `revoked`, `not_a_driver_row` and `not_in_manifest`.
- **Restart.** A restart bumps the epoch and drops all slots. An authentic old handle is
  then refused as `revoked`, so the client gets an answer instead of hanging.

| test | checks |
|---|---|
| DS0-1 | empty manifest: all 28 driver rows refused as `not_in_manifest`, and 6 non-driver identities as `not_a_driver_row`; one log line per refusal |
| DS0-2 | a manifest naming `linux.sys.mount` is rejected at load |
| DS0-3 | a listed row dispatches; an unlisted driver row is refused |
| DS0-4 | single-field forgeries (tag, slot, generation, epoch, out-of-range slot, wrong silo) and 100,000 random handles are all refused; the genuine handle still works |
| DS0-5 | after a restart the old handle is `revoked` and a new one works |

Not done: running inside a Unikraft image (DESIGN DS0 says "boots"), handle release,
the Koru lift (phantom states for mint → live → revoked), and rung-2 isolation. A 64-bit
tag is a model choice, not a security argument.

Run: `zig test silo_test.zig`
