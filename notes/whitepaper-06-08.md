# Whitepaper ch.06 and ch.08: what they claim, and what koru-os takes (2026-10-19)

Source: `Cypoe/plex-shell` @ `f34e473fbe77da06c36e6c745d8880f20d99dccc`, read through GitHub
2026-10-19 about 18:40 CEST:

- `docs/1_whitepaper/06_SASOS_SUBSTRATE_KERNEL.md`
- `docs/1_whitepaper/08_HOLOGRAPHIC_ELASTIC_MEMORY.md`

ch.07 (`07_CONFLUENT_METRIC_SPACE_AND_ROUTING.md`) was not re-read; the earlier study's map
(`notes/plex-os-study.md` §5) stands. Decisions are recorded in DESIGN-0001 §2.3, §4.1, §6.4,
§8.5, §8.7, §11.5 and §12 (Q1, Q2, Q24, Q38).

## ch.06: SASOS substrate kernel

- **Front matter (quoted):** `lean4_file: "isar-proofs/src/ISAR/Kernel.lean"`,
  `lean4_status: "verified"`, with the nodes
  - `SASOS = DirectMemoryDescriptor × UPageRing × CapAddress`;
  - `CapAddress : {Ring, Snapshot, Capability, Port, Tensor}`.
- **§2** gives the `CapAddress` enum:
  - `Ring{ring_id, offset}`;
  - `Snapshot{epoch, proof_hash}`;
  - `Capability{cap_id: String}`;
  - `Port{scheme, identifier}`;
  - `Tensor{field_name, node_id}`.
- **§3** claims `#[repr(C, align(64))]` frames and "sub-50ns inter-process messaging" through
  `UPageRing` atomics.

**Grading:**

- **The Lean status is aspirational.** `Kernel.lean` proves SKI/ISAR confluence, and a grep of
  all 55 `.lean` files finds no `CapAddress` or SASOS (`notes/plex-os-study.md` §4).
- **The alignment is real in code (V); the rest is C.** "Lock-free" and "sub-50 ns" have no
  receipts: `try_push` takes `&mut self` and sits behind a `Mutex` (study §3).
- **Nothing in ch.06 covers sharing, refcounts or revocation.**

**What koru-os takes from ch.06:** `CapAddress` as the shape of the canonical identity column.
Authority and binding go in separate columns. The correspondence table is DESIGN-0001 §8.7.

## ch.08: holographic elastic memory

- **Front matter (quoted):** `lean4_file: "isar-proofs/src/ISAR/TensorSemantics.lean"`,
  `lean4_status: "verified"`, with the nodes
  - `U(i, s, a, r)`;
  - `Steps_reduction ∝ 1 / Density(U) => O(1) Tensor Contraction` ("Inverse Complexity Law").

**Grading:**

- The law is an assertion; the study found the named Lean file does not back it (study §5).
- **ch.08 is about associative lookup, not about N holders of one region. It is not the
  counting wall.** It maps to DESIGN-0001 §9 (rung B, after a clear-text rung A).

## Counting wall

Fabian, 2026-10-19: "Zähl Mauer wir hier schon beantwortet haben." The design answer is
DESIGN-0001 §8.5:

- Redell-style indirection;
- an epoch per store-held slot;
- leases;
- epoch plus quiescence for reclamation;
- no N-holder count for revocation.

It is closed at the design level (D). Measurement (M) against the three specimens (§6.3) is
still owed, as a spike in the SASOS ascent (§11.5).
