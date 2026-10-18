# plex-shell crates study (everything except plex-os)

Repo: `Cypoe/plex-shell` (private). Pinned SHA: `f34e473fbe77da06c36e6c745d8880f20d99dccc`.
Mirrored file by file through the GitHub connector into `/workspace/plex-shell`. Sizes were checked against the tree. Nothing was pushed or modified upstream.
Written 2026-10-18 (Europe/Berlin, CEST) by the koru-os executor.

Legend:
- **R** = read in source or docs, with the file named.
- **H** = hypothesis or inference, not verified.
- **E** = measured on the box, with the log path.

## 0. Measured baseline (E)

- **Build.** `cargo test --workspace --exclude plex-os --no-run -j4` on rustc 1.99.1 (x86_64 host): exit 0.
  - Two fixes were needed first. (1) Install `pkg-config` and `libssl-dev`, because openssl-sys comes in through reqwest. (2) Mirror `examples/did/vectors.json` and `examples/flow/*`, which the tests pull in with `include_str!`.
  - No source edits.
- **Tests.** Run 2026-10-18 07:43 CEST with `HOME=/tmp/plexhome PLEX_HOME=/tmp/plexhome/.plex cargo test --workspace --exclude plex-os --no-fail-fast -j4 -- --test-threads=2`. Log: `notes/evidence/plex-shell-cargo-test.log`.
  - Result: **108 passed, 1 failed, 0 ignored**. Wall time was about 4 s, with a warm build.
  - The one failure is `plex-daemon/tests/test_plexd.rs::test_doom_capability_integration`. It panics because `shareware.wad` is not found at the hardcoded path `C:\Users\fabi0\repos\isa-physics\plex-doom\ext\shareware.wad`. This is an environment or portability failure, not a logic failure.
  - Per crate (passed):

    | crate | passed | notes |
    |---|---|---|
    | plex-core | 39 | |
    | plex-daemon | 32 | +1 failed |
    | plex-desktop | 9 | |
    | plex-libs | 4 | |
    | plex-net | 15 | |
    | plex-server | 8 | |
    | plex-shell (plexsh) | 1 | |

  - The tests do not bind sockets and do not touch the network (R, grep of `tests/`).
- **Not measured:**
  - No benches.
  - plexd/plexsh/server were not started interactively.
  - No WebView/Qt runs.

## 1. Per-crate overview

| crate | src LOC | all .rs | tests passed | maturity verdict |
|---|---|---|---|---|
| plex-daemon (plexd) | 8300 | 9107 | 32/33 | **Most real product code.** SQLite store, IPC, HTTP, keep-alive, resolver |
| plex-net | 1826 | 2519 | 15/15 | **Most interesting concepts.** Planner and lease tokens are real and small; crypto channel is a toy |
| plex-core | 5626 | 7512 | 39/39 | Mixed. Real: did:key, ports, wire. Decorative: SASOS, multikernel, PCC, "quine crypto" |
| plex-shell (plexsh) | 3334 | 3358 | 1/1 | Real TUI client (ratatui): REPL, inbox, map |
| plex-server | 714 | 918 | 8/8 | Small std-only HTTP plus did:key node identity; many fragments are static HTML |
| plex-desktop | 754 | 906 | 9/9 | **Skeleton or mock.** Good trait shapes, almost no behaviour behind them |
| plex-libs | 451 | 500 | 4/4 | Asset formats (WAD, anim, 8x8 font, colour); optional no_std |

### plex-daemon (`plexd`): the real heart (R unless marked)

**Purpose: a "daemon-first truth" local resolver daemon.**
- Transports:
  - Unix socket `/tmp/plexd.sock` (`PLEXD_SOCKET`).
  - Windows named pipe `\\.\pipe\plexd`.
  - Optional TCP via `PLEXD_PORT`.
  - HTTP on `127.0.0.1:9391` (`bin/plexd.rs`, `http_api.rs`).

**Store (`store.rs`, rusqlite).**
- Tables: sessions, commands, memories, entities, jobs, tasks, epics, records (+tags, links, FTS5), quarantine, record_revisions, trail_items, plus a unique index on landmark `slug`.
- Additive migrations use `ALTER TABLE … ADD COLUMN`, with errors ignored.

**Identity resolution (relevant to NID).**
- `Store::resolve_record_id(needle)` tries an exact id, then a unique prefix match.
  - More than one match returns the error `"ambiguous record id prefix … (n matches)"`.
  - No match returns `None`, which the caps layer turns into `"record not found"`.
  - This is a real identity → binding step with a loud refusal on ambiguity.
- `get_landmark_by_slug` binds a named slug, unique by index, to a record.
- `record://<short-id>` handles in the caps catalog.

**Shell resolver (`resolver.rs`).**
- Order: builtin → alias (stored as memory, re-resolved recursively) → PATH exact → math/code → question → semantic.
- An entity match returns `grounded` if there is exactly one hit, or `clarify` with candidates if there are several.
- `PLEXD_LOCAL_AGENT_HANDOFF.md` lists this as a hard constraint: "No fake certainty… return candidates… instead of inventing a command". **Realized** in code.

**Quarantine (`store.rs` quarantine_propose/promote/reject).**
- Agents propose; a human promotes.
- Status goes pending → promoted or rejected. A second promote is refused with `"quarantine not pending"`, a one-shot linear transition.
- Weak spot: a missing `proposed_landmark` is skipped silently on promote.

**Revisions.** `push_revision` runs before mutations, giving an append-only history per record.

**Capabilities (`caps.rs`, `http_api.rs`).**
- Catalog plus one-shot invoke over IPC (`caps_list`/`caps_invoke`) and HTTP (`GET /v1/caps`, `POST /v1/caps/invoke`).
- `/.well-known/flow` and `/runtime/scopes/plex.v1` serve a manifest with budget max 100, and the outcomes `found|ambiguous|not_found` declared per capability.
- Budget check: when the caller passes `budget.remaining` and cost exceeds it, the HTTP response is 400 `budget_exhausted`, with cost.used/remaining otherwise.
- Costs are hardcoded (`records.open`=5, everything else 1).
- **Gap:** the declared outcome *branches* are not returned as typed branches. Results are Ok(json) or Err(string).
- **Not realized:** `.flow` text is never parsed in plexd. The flow examples are only checked for the absence of paths (`tests/test_flow_manifest.rs`).

**HTTP hardening (`http_api.rs`).**
- plexd refuses a non-loopback bind unless `PLEXD_HTTP_TOKEN` is set (loud refusal at startup).
- It also rejects non-loopback peers.
- Token is checked via `X-Plex-Token` or Bearer.

**Supervisor (`keepalive.rs`).**
- plexd never serves the app port itself. It spawns `plex-http-server` with `kill_on_drop`, restarts it after a 1 s delay, and counts restarts.
- `KeepAliveSnapshot{up,pid,restarts,last_exit}`. `max_restarts` exists but is 0, meaning unlimited and unused.
- No backoff or health probe.

**Jobs (`runtime.rs`).**
- Spawned processes stream `StreamEvent`s and `cancel_job` uses a oneshot.
- H: event sends use `let _ =`, so a job outlives a disconnected client. That would give headless continuity by accident, not by design.

**Event bus (`event_bus.rs`).**
- tokio broadcast plus `mem://` buffers. Port schemes: stdin/stdout/stderr/file/mem/proc/socket.
- **The name `check_capability` is misleading.** It only checks scheme versus direction; there is no authority. `publish` without "capability" **drops silently**, an anti-pattern for koru-os.

**Sessions.**
- `SessionOpen{cwd,is_ephemeral,project_name}` **always creates** a new session.
- History, memory and entities persist per session in SQLite.
- There is **no reattach/attach request**. plexsh auto-spawns plexd if it is missing (`main.rs` ~712–770).
- This is daemon-first, but not yet a detachable session in the screen/tmux sense.

**Also present (not studied in depth):**
- ai/rag (`query_grounded_ai`)
- scheduler (jobs file)
- snapshot (HTML freeze)
- webview (WebView2 only on Windows; falls back to the OS browser elsewhere)
- maps, the `plex-import-cyberbrain` bin

**Demo/stub arms in `caps.rs`:**
- `silos.rollback` returns canned JSON.
- `kernel.status` shows `CapAddress`.
- `doom.session` has a hardcoded Windows WAD path, which is the measured failure.

### plex-net: the best concepts (R)

**`caps.rs`.**
- `CapabilitySemantic{consumes_linear, consumes_invariant, produces, outcome_branches, relations}`
- `CapabilityDescriptor{id,scope,cost,inputs,outcomes,semantic}`
- `FlowScopeManifest{scope,budget,capabilities}`, the same schema as `examples/flow/scope-*.v1.json`.

**`pathfinder.rs`.**
- A* over a state that is a sorted `Vec<String>` of type tokens.
- Linear tokens are removed on use; invariant tokens persist; every outcome branch is explored.
- Unreachable returns None, which is an explicit refusal upstream.
- **Counting wall, concretely:** a set state cannot represent "2× token", so multiplicity is lost.

**`node.rs` (`PlexPeerNode::execute_flow`).**
- A hop loop with budget accounting. A handler returns the branch name, and linear tokens are consumed after the hop.
- Explicit errors: "Budget exhausted at…", "Target tokens unreachable".

**`intent.rs`.**
- Pipeline: pathfind → ORCA gap search → backend select → route pricing → `ResolvedSystemPipeline{is_resolved}`.

**`gap_resolver.rs`.**
- Finds missing types, then runs optional PCC `MicroProofChecker::verify` before a splice.
- The checker is a toy rule interpreter over strings (axioms plus MP), not a logical kernel (`plex-core/src/pcc.rs`).

**`mesh.rs`.**
- `CapToken`/`UCANLease{issuer DID, audience, scope, verbs, attenuation_path, expiration, signature_hex}`, ed25519-signed.
- `PlexMeshNode::authorize_execution` returns explicit Errs for audience mismatch, invalid/expired token, verb not granted, and path-prefix attenuation violation.
- The errors are tested (`test_production_stress_matrix.rs`, passed E).
- **Missing:** a delegation proof chain, and revocation other than expiry (a lease is time-bounded authority).

**`stream.rs`.**
- `CausalClock` (a vector clock: tick/merge/happens_before).
- `StreamContinuation<S,I,O>` (alias `KoruContinuation`) with history.

**`route_pricing.rs`.** Discount, decay, congestion and quarantine. It does **not** match the whitepaper formula `exp(-λ·usage)`.

**`orca_bridge.rs`.** A hardcoded bootstrap registry with evidence fields (license, author_did, sha256, proof_net).

**`secure_channel.rs`, a toy that must not be mined:**
- `establish(local, remote: &KeyPair)` takes the peer's *secret* KeyPair.
- The ratchet is a SHA chain, and "QuineCipher" is a **repeating 32-byte XOR** (`plex-core/src/crypto/quine_crypto.rs::mask`). There is no AEAD.

**`cgi.rs` / `board_client.rs`.**
- CGI dispatch for the lolaplex-board PHP mediator: `op_check_cap`, `op_pathfind`, `op_execute_flow`.
- The DID helper ops return 410.
- `flow_manifest_from_rows` turns stored cap-grant rows into a manifest.

### plex-core (R)

**Real and reusable:**
- `crypto/did.rs`: W3C did:key Ed25519, compatible with the PHP sodium board. The golden vectors in `examples/did/vectors.json` are verified by a test (E, passed).
- `phi_identity.rs`: ΦID = alsoKnownAs derived from the DID. Its own comment is honest: "no seed-requiring ZK verifier".
- `ports.rs`: a URI-scheme `Port` trait (`mem`, `file`, `ntfs`, `pipe`, `ring`, stdio). An unknown scheme is a loud `Unsupported` error, and `PortMeta` exists.
- `wire.rs`: a `.plex` binary codec with a 76 B header.
- `tagged_word.rs`: 3 tag bits plus a 61-bit payload.

**Decorative or asserted:**
- `unikernel.rs` "SASOS" and `multikernel.rs` "hypervisor" are hosted structs.
  - `delegate_capability` copies, with no count and no revoke.
  - Checkpoint/rollback touches metadata only (see `plex-os-study.md`).
- `pcc.rs` is a string rule checker. "Proof-carrying code" is asserted.
- `quine_crypto.rs` is XOR, so "forward secrecy" is asserted and actually false.
- `hardware/cuda`, `lowerings/*`, `math/ordinal_factor`, `apt`, `futamura` are research or demo code with tests that check their own outputs.

**Counting wall (R):**
- `ports.rs` keeps a global `MEM_REGISTRY: HashMap<String, Arc<Mutex<Vec<u8>>>>`. Shared mutable regions are reached by **name**, and lifetime is the Arc refcount.
- There is no revocation or epoch. Whoever knows the name gets the region. This is exactly the problem koru-os has to solve.

### plex-shell (`plexsh`) (R)

- Thin client, ratatui/crossterm.
- `connect_daemon()`: TCP if `PLEXD_PORT` is set, otherwise the named pipe or Unix socket. If no daemon is found it spawns `./plexd` and retries (1.5 s timeout).
- `inbox.rs` (1040 LOC): record inbox with list/search/open/snapshot/add over plexd IPC.
- `map.rs`: fixed-coordinate map viewer ("author-owned pins, no force layout").
- `bin/plex-demo.rs` plus the `demos/` bins.
- Only one unit test. In practice the TUI is tested through plexd.

### plex-server (R)

- `HypermediaRouter::handle_request(path,query)`, a pure function that is easy to test (8 router tests passed, E).
- A std-only TCP HTTP server with one 4 KB read per request. It is not robust.
- `identity.rs`: node did:key from `~/.plex/node.seed` (load-or-create). The seed is written with default permissions (H: likely world-readable under umask 022).
- `announce_to_board` and `poll_board_mail` talk to lolaplex-board.
- Many routes are static HTML fragments: routes, apt, futamura, silos, kernel.
- `/api/users/<id>` echoes the id unescaped into JSON. It is a mock.
- Arch manual 00 says this is the only process that calls `listen()`. **This does not hold:** plexd also listens on 9391, and on the socket or pipe (`bin/plexd.rs`, `http_api.rs`).

### plex-desktop (R)

**Traits:**
- `DesktopProjection{show,hide,toggle,is_visible,set_context,dispatch_prompt}`
- `CompositorBridge{attach_surface,detach_surface,list_active_surfaces}`
- Implementations: `WebViewProjection` (HTML over plex-server), `QtProjection` (socket), `GenericCompositorBridge`.

**Silos (`silos/runtime.rs`):**
- `launch_silo` hands out a **mock PID** (4000+n).
- `update_silo` claims in a doc comment to "health probe… otherwise rolls back", but it only overwrites unconditionally.
- `rollback_silo` refuses unknown snapshots loudly; everything else is bookkeeping.

**Other:**
- `detach_surface` on an unknown id returns Ok, a silent no-op.
- `SelectionContext::mock`.
- The 9 tests check that bookkeeping.
- Value: **only the trait shapes**, the seam between headless core and projection.

### plex-libs (R)

- WAD reader, anim stream, 8x8 font, colour/pixel formats; optional no_std.
- Small, clean, not relevant to koru-os beyond being a donor for a framebuffer console.

## 2. Doc claims: realized vs asserted

| claim (source) | status | evidence |
|---|---|---|
| "No fake certainty": return candidates on ambiguity (PLEXD_LOCAL_AGENT_HANDOFF) | **realized** in resolver and `resolve_record_id` | R; refusal path **untested** (no test hits ambiguous/clarify) |
| "Daemon-first truth; clients disposable projections" (handoff, decision 002, GUI_REQUIREMENTS) | **largely realized** for plexsh/HTTP clients; desktop projections are stubs | R |
| Quarantine: human-in-the-loop write boundary (GUI_REQUIREMENTS, flow-quarantine.flow) | **realized** (propose/promote/reject, one-shot) | R, promote tested (E passed) |
| Non-loopback HTTP needs a token (GOAL slice 5) | **realized** (startup refusal) | R |
| KoruFlow: capability/shape/budget/obligation closure, "no dishonest fallback" (koruflow-semantic-capability-protocol) | **partial**. Manifest served; single-step budget check in plexd; multi-hop budget plus linear consumption only in plex-net `execute_flow` (in-process); `.flow` parser **missing**; phantom obligations **missing**; typed branches **missing** | R; plex-net flow tests passed (E) |
| `found/ambiguous/not_found` outcome vocabulary | declared in the manifest; implemented as Ok/Err strings | R |
| UCAN-style attenuated capabilities | **realized minimally** (signature, expiry, verb, path prefix); no delegation chain, no revocation | R + E (escalation tests passed) |
| plex-server is the only listener (arch manual 00) | **wrong** (plexd also listens) | R |
| Atomic silo update with health probe and rollback | **asserted** (mock) | R |
| SASOS / capability addressing / multikernel (whitepaper, unikernel.rs) | **asserted** (hosted structs, copy delegation) | R |
| Forward secrecy, secure channel (secure_channel.rs) | **asserted and false** (XOR, peer secret key) | R |
| PCC proof checking | **toy** (string rules) | R |
| Route pricing `exp(-λ·usage)` (whitepaper ch.07) | **diverges** (different formula) | R |

## 3. koru-os fit and mining targets

1. **Identity → correspondence → binding with loud refusal.**
   - Donor: `resolve_record_id` (exact → unique prefix → ambiguous error → not_found) plus the landmark slug index plus the resolver's `grounded/clarify`.
   - KoruFlow's `resolve(ref) -> found | ambiguous | not_found` with server-side equality assertions (`imdb:… ~ tmdb:… ~ local:…`) **is** the NID correspondence row, written as a protocol.
   - koru-os requirement: make the three outcomes typed branches, not error strings. Never let a binding happen through a silent fallback (counter-examples: `EventBus::publish`, `detach_surface`, missing landmark on promote).
2. **Linear/invariant capabilities.**
   - Donor: plex-net `CapabilitySemantic` plus pathfinder plus `execute_flow`. This maps directly onto Koru phantom obligations (`stream!` / `!stream`) and onto `std/runtime` scope descriptors.
   - The KoruFlow doc already names std/runtime as the source. The plex-net structs are a runtime-side shadow of what Koru generates at compile time.
   - Projection: std/runtime descriptor → `FlowScopeManifest`. The pathfinder becomes an offline planner or checker over that descriptor.
3. **Authority, leases, revocation.**
   - `UCANLease` gives DID-signed, attenuated authority with expiry. Revocation is only time-based.
   - Mining: token format and checks for std/foreign/std/bridge across machine boundaries. Add a delegation chain and an epoch/revocation list.
4. **Session and headless shell model.**
   - plexd as the single truth, with plexsh/HTTP/WebView/Qt as disposable projections (decision 002) and auto-spawn of the daemon.
   - **Missing for koru-os:** session reattach (an `attach(session_id)` request), and explicit job lifetime independent of the client.
   - The `DesktopProjection` and `CompositorBridge` traits are good seam names for detachable views.
5. **Supervisor/lifecycle.**
   - `keepalive.rs` is a minimal one-child supervisor with an observable snapshot (up/pid/restarts/last_exit) and an env kill switch.
   - Mining for std/supervisor: the snapshot shape and the "plexd does not listen; the child listens" separation.
   - Add backoff, a max-restart policy (the field exists, unused), a health probe, and a tree rather than a single child.
6. **Counting wall.**
   - Two concrete specimens:
     - (a) pathfinder set state loses multiplicity;
     - (b) the `MEM_REGISTRY` name → `Arc<Mutex<Vec<u8>>>` holds a shared mutable region with a refcount lifetime and no revocation.
   - Plus `multikernel::delegate_capability` (copy, no count).
   - Good test cases for whatever koru-os does instead: a multiset or counted state, and region handles with an epoch.
7. **std/store.**
   - The plexd store pattern (append-only revisions before each mutation, quarantine staging, FTS, `record://` handles, additive migrations) is a usable template for std/store's "record + revision + staging" semantics.
8. **Do not mine:** quine_crypto/secure_channel, pcc, SASOS/multikernel/unikernel, route-pricing numbers, plex-desktop silo runtime.

## 4. Doc aspirations worth turning into koru-os requirements (proposal)

- **R-NID-1:** every reference resolution has exactly the outcomes found / ambiguous(candidates) / not_found(ref), as typed branches. Never guess (KoruFlow §Reference resolution, handoff "no fake certainty").
- **R-NID-2:** equality between external ids is a server-side, provenanced assertion row. Clients never infer it (KoruFlow §5).
- **R-HONEST-1:** "No dishonest fallback". An unsupported target, relation or adapter gives an explicit unavailable/unsupported outcome (KoruFlow law 6).
- **R-BUDGET-1:** budget exhaustion is a normal branch, not a crash (KoruFlow law 3; partly realized in plex-net node.rs).
- **R-OBL-1:** the runtime enforces the same phantom obligations as the compiler (KoruFlow law 4), and linear tokens are consumed exactly once (plex-net). Counting is open: the state must be a multiset.
- **R-SESS-1:** daemon-first truth. Views are disposable projections over the same API (decision 002). Add explicit attach/detach and client-independent job lifetime (not yet in plexd).
- **R-WRITE-1:** agent writes go through quarantine, and only a principal with promote authority binds them (GUI_REQUIREMENTS C).
- **R-NET-1:** a non-loopback surface is refused without a credential (GOAL slice 5, realized).
- **R-SUP-1:** a supervisor exposes an observable snapshot, and the supervised child is the only listener (keepalive.rs; arch manual 00 claims this, but the code violates it, which should be fixed).
- **R-REVOKE-1:** open decision (KoruFlow "how capability revocation… are represented"). Leases with expiry are the minimum. Epoch/revocation is a koru-os research item at the counting wall.
