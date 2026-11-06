---
type: belief
id: frag-fixed-map-address-is-the-contract
provenance: koru-os native session — klanker-child, 2026-11
ts: 2026-11-10
tags: [native, mmap, map_fixed, elf, correctness]
---

**An `mmap` that returns success at an unrequested address is a lie —
MAP_FIXED's VA is the contract, not a hint.** The anon mmap arm
ignored `addr` and `MAP_FIXED` entirely: every anonymous map bump-
allocated from `mmap_top` and returned success. musl's `map_library`
reserves a span PROT_NONE, MAP_FIXEDs each PT_LOAD on top, and
MAP_FIXED-anons the BSS tail — it checks only `== MAP_FAILED`. Our
"successful" wrong address left the real BSS VA on read-only reserved
pages while the zeroed pages leaked elsewhere: mallocng metadata
corruption surfacing nondeterministically as `a_crash()`/wild-pointer
faults inside `free()`, measured in the fork+exec'd subprocess where
the bump cursor had drifted.

- **FIXED means fixed-or-fail.** Validate the window bounds, free the
  frames already mapped there (same accounting as munmap), map fresh —
  a refused or misplaced fixed map is honest; a relocated one is not.
- **The bump cursor must not collide with fixed maps.** The arena
  advances past any live span before claiming, else a later bump lands
  inside a fixed reservation — the same aliasing class, deferred.
- **The mask pattern generalizes.** Any syscall whose return value
  carries an address the caller will dereference must either honor the
  requested address or fail loudly — PROT_NONE-as-read-only zero pages
  made this bug legible only through second-order corruption, the
  worst kind to bisect (serial evidence: two different fault sites in
  ld-musl's malloc/free paths across two boots).
