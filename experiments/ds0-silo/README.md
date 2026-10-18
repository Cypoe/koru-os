# DS0: driver-silo contract and refusal harness

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


---

## DS0 in a unikernel, as a Koru lift (2026-10-18, about 19:45 CEST)

**Result: PASS under TCG (M), 3 of 3 runs. The compile gates pass (M).**

The lift is `koru/silo/index.kz` (module `koruos/silo`). Handle phantom states:

```
mint → <minted!>   bind <!minted> → <bound!> | refused <minted!>
call <!bound> → dispatched <bound!> | revoked <revoked!> | refused <revoked!>
release <!minted|!bound>    discard <!revoked>    open → <open!>, close <!open>
```

At run time, `bind` refuses rows outside the driver row set or the manifest. `bind` and
`call` refuse forged handles (the HMAC-SHA256 tag no longer matches) and stale ones
(epoch mismatch → `revoked`). The silo key is read with `rdrand`.

| check | result | evidence |
|---|---|---|
| `boot_silo.k` in a Unikraft 0.21.0 image: empty manifest refuses 3 of 3 (2 `not_in_manifest`, 1 `not_a_driver_row`); a bad manifest is refused at open; a listed row dispatches; a tampered handle is `forged_handle`; after `restart` an old handle is `revoked` | serial output equals `expected.txt`, 3 of 3 runs | `evidence/image-serial-tcg-*.log`, `image-run-tcg-*.txt` |
| image / Koru archive size | 181,120 B / 32,336 B | `evidence/image-sizes.txt` |
| QEMU wall time, launch to exit, TCG | 0.256 / 0.253 / 0.256 s | `evidence/image-run-tcg-*.txt` |
| build (`build-image.sh`: koruc ×2, zig, kraft) | 24 s wall | `evidence/image-build.log` |
| compile gates | `call` on an unbound handle, `call` after `revoked`, and `bind` twice are all rejected with KORU030 | `evidence/koru-compile-gates.log` |

**Finding: leaks are auto-discharged, not rejected.** I wrote "handle never released"
and "silo never closed" as negatives, but both compile. `koruc` auto-discharges an
obligation that has exactly one disposal: it inserts `release` and `close` itself, as
`output_emitted.zig` shows. That matches the koru-libs `blk` README ("Auto-discharge
failed (multiple disposal options or no disposal event)"). They are kept as
`autodischarge_*.k`, and the gate checks that the emitted call is present. Two caveats:
- In `autodischarge_handle_release.k` the inserted `release(h)` comes **after**
  `close(silo)`. That is harmless here, because `release` does not touch the silo, but
  it is an ordering hazard for any disposal that does.
- If a leak must be a hard error, the state needs two disposal options (the `blk`
  pattern).

The `tamper` tor is test-only. It corrupts the tag so that the run-time forgery check
is exercised from Koru, where a well-typed program cannot fabricate a handle.

Run: `build-image.sh <koru-libs> <workdir>`, then `run-image.sh <workdir>/koruos/silo/tests/.unikraft/build/koru_qemu-x86_64 <out>`, then `check-negatives.sh <workdir>`.
