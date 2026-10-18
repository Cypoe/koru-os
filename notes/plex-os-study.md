# plex-os study (for koru-os)

- **Repo:** `Cypoe/plex-shell` (private), branch `master`
- **Pinned commit:** `f34e473fbe77da06c36e6c745d8880f20d99dccc` (2026-09-01 16:20 CEST, "Add board CGI client path and trim plex-net identity scope.")
- **Last commit touching `crates/plex-os`:** `99754698da` (2026-08-26 23:24 CEST, "multikernel layout, dynamic tiered unified memory + doom as guest application"). Almost all of plex-os landed on one evening: 14 commits on 2026-08-25, from 19:34 to 22:58 CEST.
- **isar-proofs (public):** `Cypoe/isar-proofs` @ `b9534379573d8371dfc7b59d310b647942b9043b` (default branch HEAD at clone time, committed 2026-09-28. The API says it was pushed 2026-10-16, so other branches may be newer.)
- **Study date:** 2026-10-18, roughly 04:40–05:00 CEST, on the box.
- **Access path:** `gh` is not logged in on the box, so I couldn't do a git clone. Files were read through the GitHub connector at the pinned SHA and mirrored to `/workspace/plex-shell/` (this is a partial mirror, see the deviations section). isar-proofs was cloned to `/workspace/isar-proofs`.

## Coverage legend
- **R** = read fully
- **H** = header/summary level (front-matter, headings, theorem statements)
- **E** = enumerated only (file listed with size, contents not read)

| Area | Coverage |
|---|---|
| Repo tree (350 entries, all paths and sizes) | E (full list in `/workspace/plex-tree.txt`) |
| `README.md`, `Cargo.toml`, `.cargo/config.toml`, `targets/i686-unknown-none.json` | R |
| `crates/plex-os/**` (all 15 source files, linker.ld, build.rs, Cargo.toml) | R. main, sasos_alloc, exo, multiboot, doom, repl and ports/mod read fully. cyberboot, term, framebuffer, keyboard, display, audio, pit, serial skimmed but compiled and exercised |
| `scripts/run_qemu.py`, `build_doom.py`, `test_doom_serial.py` | R |
| `scripts/doom_platform/**` (28 files) | i_main R, plex_guest.h R, doom.ld R, libc_shim H (function list, malloc/open/read R), i_system H, i_video H, include/* E |
| Whitepaper `docs/1_whitepaper/00`, `06`, `07`, `08` | R |
| Whitepaper `01`–`05`, `09`, `10` | H |
| `docs/concepts/ISAR_CLOS_CAPABILITY_KERNEL.md`, `docs/4_origins_and_archaeology/02_ISAR_PROOFS_BLUEPRINT.md`, `docs/2_architecture_manual/00`, `07` | R |
| `docs/concepts/MEMORY_ARCHITECTURE.md`, `docs/README.md`, `benchmarks/STATUS.md` | H |
| `plex-core/src/unikernel.rs` (CapAddress, UPageRing, DirectMemoryDescriptor), `kernel.rs`, `lib.rs` | R |
| `plex-core/src/multikernel.rs` | R (delegate/checkpoint/rollback), H (domain table) |
| `plex-net/src/caps.rs` | R |
| `plex-daemon/src/caps.rs` | H (grep plus the `kernel.status`/`silos.*`/`doom.*` arms) |
| `plex-core/src/ports.rs`, `plex-desktop/src/silos/runtime.rs` | H (grep only) |
| Other plex-core/net/daemon/server/shell/desktop sources, `PLEXUS_UNIFIED_THESIS.md`, `WHITEPAPER_AUTOMATIC_SYSTEMS_PROGRAMMING.md`, `ARCHEOLOGY.md`, `koruflow-semantic-capability-protocol.md`, historical-context docs | E |
| isar-proofs `src/ISAR/Kernel.lean` | H (definitions and theorem list); grep across all 55 `.lean` files for SASOS, CapAddress, capability, sorry and axiom |

---

## 1. What the repo actually is

`plex-shell` is mostly not an OS. Its README calls it a "personal cognition control plane": `plexd` (SQLite record store, HTTP on 127.0.0.1:9391, scheduler, MCP adapter), `plexsh` (TUI REPL, inbox, map), a WebView shell, and the PLEXUS theory corpus. It's a Rust workspace with 8 crates:

| Crate | Role (from code and docs) |
|---|---|
| `plex-core` | Hosted `std` library. Holds the 4-carrier matrices (`kernel.rs`), **`CapAddress`/`UPageRing`/`DirectMemoryDescriptor`/`SubstrateKernel` (`unikernel.rs`)**, `MultikernelHypervisor` (`multikernel.rs`), ports, Futamura, quotient, wasm/cuda lowerings, did:key and Φ identity |
| `plex-net` | Planner, DID-signed `CapToken`, `BoardClient`, route pricing (renamed from "trampelpfad" in the pinned commit) |
| `plex-daemon` | `plexd`, the control plane: records, RPC, capability catalog, keep-alive for plex-server |
| `plex-server` | The process that calls `listen()`. Hypermedia node that announces to lolaplex-board |
| `plex-shell` | `plexsh` TUI |
| `plex-desktop` | Desktop shell host: compositor stub, overlay, Qt/webview projections, silos |
| `plex-libs` | Formats: anim, font, color, WAD |
| **`plex-os`** | **The only bare-metal crate. `no_std`, zero dependencies, about 2.9 k lines of Rust. It does not depend on plex-core.** |

"plexus" and "PLEXUS" are the brand for the theory and substrate (whitepaper corpus `Lolaplex/plexus`). "plex-os" is the bare-metal crate.

## 2. plex-os: boot path and structure (read and measured)

- **Boot:** Multiboot **1** header (`0x1BADB002`, flags 3) in `.boot`, loaded by `qemu -kernel` at 1 MiB (`linker.ld`). `_start` runs `cli`, saves EAX/EBX, sets up a 64 KiB stack, sets the CR0/CR4 SSE bits and calls `kernel_main(magic, mbi)`. **There is no GDT reload, no IDT, no paging, and interrupts stay off.** It runs in flat 32-bit protected mode in ring 0, exactly as the loader left it.
- **`kernel_main`:** parses multiboot (mem_upper becomes the arena size; module 0 is doom.bin and module 1 is the WAD), initialises COM1, clears VGA, plays `plexus_boot.anim`, does `sasos_allocate(1024)`, prints the REPL prompt, then **polls** COM1 and the PS/2 port in a busy loop.
- **Real build target:** `i686-unknown-linux-musl` on **stable** Rust, with `.cargo/config.toml` rustflags `link-self-contained=no`, the custom linker script, static relocation and SSE disabled. This is what `run_qemu.py` and `test_doom_serial.py` use. `targets/i686-unknown-none.json` (custom target spec, rust-lld, panic=abort) exists, but nothing in the scripts I read uses it. It would need nightly and `-Zbuild-std`. So "the i686-unknown-none target" is aspirational, and the working build is a musl triple used as a freestanding carrier. Both are 32-bit i686, KolibriOS class.
- **REPL commands:** `help, cpu, mmap, mem, ports, gop, audio, exo, carriers, anim demo|boot, doom, eval <SKI…>`. `cpu` (CPUID) and `mem` (allocator counters) are live. **`mmap`, `ports`, `gop`, `audio`, `exo` and `carriers` print fixed text.** For example `exo` prints "Aperture 3: [Guest Unikernel] 0x1000_0000 - Capability-Bounded Sandboxing", but nothing enforces it, and `HardwareAperture` in `exo.rs` is never consulted.
- **`term.rs`:** a `no_std` SKI/BWC combinator arena with Turner bracket abstraction and a normal-order reducer (step cap 100). The label "Confluent in N steps" is printed text. It does not check confluence.

### MEASURED: build (box, 2026-10-18 ~04:43 CEST)
Toolchain: rustup stable **rustc 1.99.1** plus target `i686-unknown-linux-musl`, installed under `~/.cargo`. Command: `cargo build --target i686-unknown-linux-musl -p plex-os --release`. It built with 41 warnings (mostly `static mut` references).

`size -A target/i686-unknown-linux-musl/release/plex-os`:

| section | bytes |
|---|---|
| .boot | 61 |
| **.text** | **21,153** |
| .rodata | 847,609 (of which `boot.anim` include_str = 816,702) |
| .data | 40 |
| .bss | 67,831 (64 KiB stack + REPL history) |
| **ELF file** | **873,480** (sha256 `2e9eab85…947ada`) |

**About the "~20 KB" claim:** the **code** is about 20.7 KiB (.text = 21,153 B). The **image** is not 20 KB. 96 % of the file is the embedded 817 KB ASCII-art `boot.anim`, which `include_str!` keeps in because the `anim boot` command references it. Without that asset (and without plexus_boot/demo anim) the image would be roughly 33 KB. That is arithmetic from the section table, not a build I ran.

### MEASURED: boot (QEMU 10.0, TCG, `qemu-system-i386 -kernel … -m 256M -display none -serial stdio -no-reboot`)
- First `plex-os> ` prompt on serial at **1.51 s** wall time after launch, including the boot animation (one run, TCG, not KVM).
- `cpu` → `Vendor: GenuineIntel  Features: TSC SSE SSE2 SSE3`
- `mem` → `Allocated: 1024 bytes | Free: 222 MB` (arena 0x0200_0000 up to the multiboot mem_upper limit for 256M)
- `eval (K I) S -> I (1 step)`, `eval S K K x -> x (2 steps)`, `(B W) (K I)` unchanged (already a normal form, since B is under-applied)
- `doom` without modules → `[PLEXUS] DOOM modules missing. Boot with -initrd doom.bin,shareware.wad` (a loud refusal, good)
- Full log: `evidence/plexos-serial.log`. Harness: `evidence/boot_plexos.py`.

### MEASURED: DOOM guest (box, ~04:47–04:50 CEST)
- Inputs: id-Software/DOOM `linuxdoom-1.10` @ `a77dfb96cb91780ca334d0d4cfd86957558007e0`, and shareware `doom1.wad` v1.9 (md5 `f0cefca49926d00903cf57551d901abe`, the official shareware hash). Toolchain: Debian clang/lld/llvm 19.
- `build_doom.py` built **`doom.bin` = 342,160 bytes** (flat binary linked at 0x1000_0000). The whole build took about 4 s.
- Boot: `qemu-system-i386 -kernel plex-os -initrd doom.bin,shareware.wad -m 512M -vga std -display none -serial stdio`. I typed `doom` and drove the menu with the QEMU monitor `sendkey`.
- Serial shows the full linuxdoom init: `DOOM Shareware Startup v1.10 … W_Init … adding ./doom1.wad … Shareware! … R_Init … P_Init … I_Init … [PLEX] SFX/music silent (QEMU SB16 DMA stalls vCPU; deferred) … ST_Init`. Then it repeats `Demo is from a different game version!`, because v1.10 code is playing v1.9 WAD demos. That is expected with this WAD and harmless.
- Screendumps (`evidence/doom-serial.log.shot*.png`, `evidence/doom-play.log.shot4.png`): the title screen renders (VGA mode 13h, 320×200, PLAYPAL colours). The menu responds to PS/2 keys. After 4× Enter I was **in-game on E1M1 with the HUD showing** (shot4). This confirms "playable in QEMU" as far as rendering, input and the game loop go. **Sound is disabled by design. I did not test exit-to-REPL.**
- **Portability snag I found:** `scripts/doom_platform/include/doomdef.h` hard-codes `#include "W:/src/DOOM/linuxdoom-1.10/doomdef.h"` (a Windows path). `build_doom.py` and `plex-daemon` caps also default to `C:\Users\fabi0\...` paths. I worked around it without editing source by symlinking `include/W:/src/DOOM/linuxdoom-1.10` to the checkout.

### How the "DOOM Linux port + shims" works (read)
- It's a **source-level port, not Linux ABI emulation.** linuxdoom's `i_main/i_video/i_sound/i_system/i_net.c` are replaced by `*_plexus.c`. `libc_shim.c` (about 60 functions) plus stub POSIX headers supply a freestanding mini-libc:
  - a 2 MiB **bump `malloc`, with `free` as a no-op**
  - `open()` succeeds only for the WAD path and `read()` copies from the in-memory WAD
  - `printf` goes to COM1
  - `exit` jumps to the kernel's `reentry_fn`
  - DOOM's zone is a static 6 MiB array
- The guest drives hardware directly: PIT ports 0x40–0x43, VGA 0xA0000 and DAC, PS/2 0x60. It runs in **ring 0, in the same physical address space as the kernel, with no protection**.
- Kernel→guest ABI: `PlexGuestBoot { wad_ptr, wad_size, reentry_fn, fps_cap, dma_ptr, dma_size }`, passed in EAX by `call 0x1000_0000`. The guest snapshots the struct before wiping its own BSS, because the BSS may overlap kernel memory. Exit restores the saved kernel ESP and does `ret`. This is effectively a hand-rolled one-row ABI contract, which is the seed of a NID row.

## 3. Memory and capability model: claims vs code

| Concept | Whitepaper claim (ch.06 / glossary) | Where it lives in code | What the code does |
|---|---|---|---|
| SASOS | "SASOS = DirectMemoryDescriptor × UPageRing × CapAddress", lean4_status "verified" against `Kernel.lean` | plex-os: `sasos_alloc.rs`; plex-core: `unikernel.rs` | **plex-os:** one global **CAS bump allocator** (32 B alignment, plus 4 KiB `allocate_arena`), **no free**, physical addresses with paging off. **plex-core:** hosted structs |
| `CapAddress` | Flat typed capability coordinates replacing paths | `plex-core/src/unikernel.rs` (hosted, `std`, serde). **Not in plex-os.** | An enum {Ring, Snapshot, Capability{cap_id:String}, Port{scheme,identifier}, Tensor} plus `to_uri()`. `SubstrateKernel` keeps a `HashMap<CapAddress,u64>`. `bind_address` silently overwrites. `resolve_address` returns `Option` (unbound gives None). **It's a name→offset table: forgeable strings, no rights, no holders, no revocation** |
| `UPageRing` / `UPageFrame` | Lock-free, 64 B aligned, "sub-50 ns IPC" | `plex-core/src/unikernel.rs` | `UPageFrame` really is `#[repr(C, align(64))]`. The ring's `try_push` takes `&mut self` (exclusive), so it is not concurrent, and `ports.rs` wraps it in `Arc<Mutex<UPageRing>>`. `try_pop` hands out a reference to a slot the producer can later overwrite. **"Lock-free" and "sub-50 ns" are unmeasured and not structurally true as used.** No UPageRing exists in plex-os |
| `DirectMemoryDescriptor` | Part of the SASOS triple | plex-core | `{base_ptr, page_count, page_size=4096, is_direct_mapped}` record. Nothing is mapped |
| Capability tokens instead of rings | ch.06 | `multikernel.rs` | `TensorSubgraph.capabilities: Vec<String>`. `delegate_capability(from,to,cap)` checks that `from` holds it, then **copies** it into `to` (set semantics, source keeps it, no count). **No revoke.** `checkpoint_silo` records metadata (timestamp hard-coded to 1000). `rollback_silo` returns that metadata and restores no memory. plexd `silos.rollback` returns canned JSON |
| Linear vs shared | (not in the whitepaper) | `plex-net/src/caps.rs` `CapabilitySemantic { consumes_linear, consumes_invariant, produces, outcome_branches }` | A real distinction between **linear** (consumed once) and **invariant** (freely shared) inputs at the flow-manifest level. **There is nothing in between, such as counted or fractional.** |
| Isolation of guest silos | "Capability-Bounded Sandboxing" (`exo` text) | plex-os `doom.rs` | No paging and no segments. The guest is linked at a fixed physical address and runs in ring 0. Isolation is zero |

**Net:** the SASOS/CapAddress vocabulary has three layers: whitepaper prose, a hosted Rust data model in plex-core, and the bare-metal plex-os. **plex-os implements none of CapAddress, UPageRing or DirectMemoryDescriptor.** Its "SASOS" is literally "paging off, one bump arena, everyone shares physical memory".

## 4. isar-proofs link: what "verified" actually covers

- `isar-proofs/src/ISAR/Kernel.lean` (H): **SKI and a symbolic ISAR term calculus** (`SK`, `ITerm` with norm/konst/dup/swap/comp/sₛ), the encoding SK→ITerm with step simulation, and **genuine confluence via parallel reduction** (`ParStep_diamond`, `IRed_confluence`, `isar_fragment_confluence`, `isar_fragment_unique_normal_forms`). That is real, checked mathematics about combinator rewriting.
- **grep across all 55 `.lean` files: no `SASOS`, `CapAddress`, `UPageRing`, `DirectMemoryDescriptor`, capability, region, refcount or revocation.** So ch.06's front-matter (`lean4_file: Kernel.lean`, `lean4_status: verified`, node `SASOS = DirectMemoryDescriptor × UPageRing × CapAddress`) is **not backed by the Lean file**. The verified object is confluence of the term calculus, not the OS substrate. The same holds for ch.07 (`TRSView.lean`): it proves encode/decode round-trips and an observational equivalence, with **no route-pricing formula**. Ch.08 (`TensorSemantics.lean`) has **no density or "inverse complexity" statement**.
- "0 sorry" is literally true as far as grep shows: "sorry" appears only in comments. But **there are explicit `axiom`s**: `ISAR_UAT`, `KernelAddressLimit`, `continuousRealizationLimit`, `kernelAddressEmbedding(_coe)`, `topological_extension_bijection` (ISARApproximation), `quantityToNat/natQuantity/…_inverse` (QuantityKernel), and `exp_exp_not_holonomic`. The files document these honestly. The whitepaper's "0 sorry, mathematical certainty" omits them.
- Glossary: "All 91 core substrate invariants … formally verified with zero-failure test execution." The 91 are **`cargo test` tests** (arch manual ch.07), not formal proofs. I did not run them.
- Internal inconsistency in the carrier names: glossary {Identity, Rotation, Annihilation, Scaling} over F₂. REPL `carriers` {Identity, Symmetric, Admissible, Retraction}. Concept doc {Invariant, Rewrite, Adjacency, State}. `kernel.rs` multiplies **mod 4**, not mod 2.
- The ISAR_PROOFS_BLUEPRINT doc says "28 theorem modules". It lists 22, and the repo has 39 files in `src/ISAR/` (55 `.lean` in total).

**Evidence grading for koru-os:** the strongest evidence in this ecosystem is Kernel.lean confluence (verified) and the plex-os/DOOM boots (now reproduced here). Everything about SASOS performance, alignment benefits, lock-freedom, "verified SASOS", the inverse complexity law and route-pricing theorems is **asserted**.

## 5. Whitepaper map

| Ch | Title | Lean file named | Coverage | What is actually there |
|---|---|---|---|---|
| 00 | Abstract & Glossary | — | R | Vision. "verified (0 sorry)". 91 tests framed as verification |
| 01 | 4-Carrier Tensor Algebra U(I,R,A,S) | ISARMatrices.lean | H | I²=I, nilpotence of the product |
| 02 | Gauge invariance K1≅P K2 | ISARMatrices.lean | H | P⁻¹P=I and conjugation, "proven by rfl" (plausible, not checked) |
| 03 | Confluence & PCC | Kernel.lean | H | Church–Rosser (backed by Kernel.lean). PCC micro-checker signature only |
| 04 | Generalized APT inversion | ViewUnification.lean | H | Triad (Pres, O, Realize), naturality |
| 05 | Futamura square | Futamura.lean | H | The 3 projections as equations |
| **06** | **SASOS substrate kernel** | Kernel.lean (mismatch) | **R** | Diagram, CapAddress enum, 64 B alignment, "sub-50 ns". **Nothing on sharing, refcounts or revocation** |
| **07** | **Confluent metric space & routing** | TRSView.lean (mismatch) | **R** | Kay late binding. Address = "coordinate in metric hypergraph". Route cost `Base·e^(−λ·usage)`. Church–Rosser read as "every path (ring://, mesh://, snapshot://) converges to the same NF". **Nothing on revocation, sharing semantics or counting.** The code renamed trampelpfad → route pricing on 2026-09-01, but the doc wasn't updated |
| 08 | Holographic elastic memory | TensorSemantics.lean (mismatch) | R | Inverse complexity law (assertion). Not about N holders of one region |
| 09 | Nibble bootstrap & Ackermann | BytecodeView.lean | H | 16 self-delimiting opcodes, N↔V_ω |
| 10 | Observational lenses & personas | ViewIndependence.lean | H | Bidirectional lenses, no master AST |

## 6. The counting wall: what plex has to say

Neither the whitepaper nor plex-os solves "N protection domains share one region and we need to know when the last one lets go". The plex code **avoids the wall instead of climbing it**:
1. **plex-os:** the bump allocator never frees, there's no protection, and every silo sees all memory. With no release and no domains, nothing needs counting.
2. **plex-core:** capabilities are `String`s in a `Vec` per domain. Delegation copies them (duplication is free), and there is no revoke. This gives "invariant/shared" semantics for everything, so again no count.
3. **plex-net:** `consumes_linear` vs `consumes_invariant` is the honest binary, linear (exactly one holder, consumed) or invariant (unbounded sharing). This is the same dichotomy phantom/typestate gives you. The counted middle is exactly what's missing.
4. Ch.07's confluence argument ("all paths reach the same NF") is about **value identity**, which makes duplication semantically safe for **immutable** data. That suggests a principled half-answer for koru-os: **regions that are immutable or snapshot-addressed (`Snapshot{epoch, proof_hash}`) can be shared without counting, because they have no last-holder obligation, only GC or epoch reclamation.** Counting is only needed for **mutable or revocable** regions, and there plex offers nothing. The realistic designs remain counted or revocable caps on the store side (seL4-style CNode derivation trees, or epoch/generation revocation as in CHERI and Capsicum lineages). This is my inference, not a plex claim.

## 7. Most useful for koru-os

1. **A working, reproducible i686 bare-metal arm that is small and honest about what it is.** It's about 21 KB of code, Multiboot 1, boots under `qemu -kernel` in about 1.5 s TCG with serial-REPL control, all measured here. It's a cheap realization target for "substrate arm: bare i686", and a shared address-space class with KolibriOS. The harnesses in `evidence/` make it CI-able (serial plus monitor screendump).
2. **`PlexGuestBoot` is a one-row NID/ABI contract in miniature.** Kernel and guest agree on a C struct, a fixed load address, a register convention (EAX) and a re-entry symbol. koru-os can generalise this into correspondence rows (identity `guest.boot/v1` → binding {layout, load addr, calling convention}), and refuse loudly when unbound. plex-os already does this for missing modules ("DOOM modules missing…").
3. **The DOOM shim pattern is the right model for "Linux shims, not the point".** It's a source-level libc projection (about 60 symbols) onto substrate services (WAD-as-file, serial-as-stdout, reentry-as-exit), not syscall emulation. In koru-os terms, each shimmed libc symbol is a NID row whose binding differs per arm, and unshimmed symbols should be link-time refusals, not runtime `-1`.
4. **Keep the evidence classes apart.** Kernel.lean confluence is real and can anchor koru's "same function identity, different substrate" story at the term level. The SASOS/CapAddress layer has **no** formal backing yet. The correspondence table in our earlier notes (Kernel.lean = canonical identity of `CapAddress`) is **wrong as stated** and needs fixing: CapAddress is a hosted Rust enum in plex-core, verified by nothing.
5. **`CapAddress` is a usable NID shape, but it isn't a capability.** `Port{scheme, identifier}` / `Capability{cap_id}` is a good identity form. koru-os should keep it as the identity column and put authority (unforgeable, typestate/linear handles) and binding (offset, arm-specific) in separate columns. `resolve → Option` is the right refusal hook. `bind` must not silently overwrite. The linear/invariant split from `plex-net` maps directly onto koru phantom handles and pinpoints the counted middle as the open research item.

## 8. Deviations and caveats in my reproduction
- **Partial mirror, not a clone.** `/workspace/plex-shell` holds only what I fetched. Root `Cargo.toml` was **reduced to `members = ["crates/plex-os"]`** so it could build without the other crates. Release-profile settings are unchanged.
- A few fetched header files differ from the tree sizes by 1–3 bytes (`fcntl.h`, `stdio.h`, `stdlib.h`, `values.h`), most likely trailing-whitespace or CRLF normalisation by the fetch. I hand-retyped `build.rs` (983 vs 984 B, same content). Both builds succeeded.
- I used rustc 1.99.1 stable, which is newer than whatever Fabian used. Section sizes may differ slightly from his builds.
- Every boot was TCG, not KVM. Timings are single runs on a shared box and are indicative only.
- `cargo test --workspace` was not run, and the 91-test claim is unverified. The embedded-DOOM variant (`cfg(embed_doom)`) was not built (it would grow the ELF by about 4.5 MB). I used `-initrd` modules instead.
- Nothing was pushed or modified on any remote.

## Files
- `evidence/boot_plexos.py`, `evidence/plexos-serial.log`: base boot and REPL session
- `evidence/boot_doom.py`, `evidence/boot_doom_play.py`, `evidence/doom-serial.log`, `evidence/doom-play.log`, `evidence/*.png`: DOOM guest
- Mirror: `/workspace/plex-shell` (build output under `target/i686-unknown-linux-musl/release/plex-os`, `build/doom/doom.bin`)
