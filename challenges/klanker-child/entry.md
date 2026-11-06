---
name: klanker-child
iface: koruos/oracle.klanker
arms: [koru-native]
lane: oracle
needs: [py-cpython-child]
accept: klanker + agents-* deps run under the CPython child; REPL answers, bot-to-bot over unix socket
tier: qemu
status: landed
evidence: V
peer: klanker (~/repos/klanker, MIT, Lolaplex)
provenance: project-owned codebase — no donor diligence needed
---

# klanker-child

klanker — the Lolaplex agent shell — running unmodified inside the
CPython child: `klanker sense`/`klanker prompt` as real subprocesses,
and two children holding bot-to-bot traffic over a unix socket (the
same-kernel shape that needs no AF_INET at all).

## Acceptance — MET (QEMU serial)

`boot_klanker` → `kroot.cpio` module (`scripts/fetch-kroot.sh`:
fetch-pyroot + klanker/agents-* sources flattened into the stdlib dir
— `-S` skips site.py's hook — never committed). Serial:

- `KL hello 3.12.13`, `KL pid 1`, `KL import 0.1.0` — the package
  itself, unmodified, off a 112-entry stdlib listing.
- `KL sense True rc 0` — `klanker sense --json` as a subprocess:
  fork + execve + waitpid + capture pipes, the full selector path.
- `KL prompt True rc 0` — `klanker prompt`, the deterministic answer.
- `KL botsock bot-ping status 0` — fork'd child connects to the
  parent's `/run/bot.sock` listener, minted as a S_IFSOCK ent inside
  the initramfs RAM table (the ONE mutation the RO view allows).
- `KL COMPLETE`, `PY GATE COMPLETE`, status=0.

## Measured gaps (named, honest)

- **`KL thread refused RuntimeError can't start new thread`** — the
  clone-thread shape (`0x7d0f00`) — `clone-threads` stands as the
  rung, now proven by klanker's own demand.
- **`KL chat rc 1` → `Turn error: LLM_BASE_URL required`** — after
  the writable-RAM layer and the marshal-budget rulings below, `chat`'s
  wall is klanker's own provider config (no model endpoint in the
  payload) — the application-provider gap, not a kernel/fs gap.
- `getcwd` returns `/` (the view root is the cwd model); `readlink`
  ENOSYS — survived, named.
- `nr=0x19 readv` refused in the bag → python fell back cleanly.

## Kernel changes the chat path forced (second pass)

- **initramfs writable RAM upper layer** — `Ent.ram` + a generalized
  `mintEnt` (socket node, dir, regular file): `cfMkdir` mints dirs,
  `cfOpen` honors `O_CREAT`/write-intent/`O_TRUNC` on RAM ents,
  `cfWrite` grows malloc'd buffers, `cfOpenKey` admits RAM regular
  files, `chmod`/`utimens` became provider verbs (ext2 writes inode
  mode/timestamps back; `ChildFsOps` extended in all three mirrors).
  RAM unlink/rename stay named ENOSYS gaps — no tombstone pass.
- **xattr family is honest at the kernel tier** — `listxattr`→empty,
  `getxattr`→ENODATA, `setxattr`→ENOTSUP; folded to the fs class so
  `copystat` proceeds. No provider models xattrs — the empty answer
  is literally true of every current view.
- **argv/envp marshal budget is a real contract** — the 512B blob +
  128-char string cap refused klanker's env (LOOP_CMD chain), and
  LLM system prompts ride argv entries (`"You are a …"`, multi-KB):
  marshal now writes into a static 128KiB scratch (`vecbuf`), bounded
  but off the kstack. `MAXARGS` 16→32.
- **a re-primed child slot carries nothing** — `koru_spawn_run` was
  the one slot path missing the `c.* = .{}` reset: a killed-while-
  blocked tenant left a stale `kctx` naming an old continuation on its
  own kstack; a later epoch's `switchInto` resumed it → `#UD rip=3`.
  Full reset (+ defensive `freeChild` for live upd) before reissue.

## Kernel changes this rung forced

- **`childGetdents` pushback** — a fetched record that didn't fit the
  caller's buffer was silently dropped (95th entry vanished →
  `ModuleNotFoundError`). Per-fd one-record hold (`dent_pending`/
  `dent_plen`/`dent_pfd`), cleared on close/reuse.
- **FD_CLOEXEC is real projection state** — `fdcx` beside `fdnb`:
  open/socket/pipe2/eventfd/timerfd/signalfd/epoll_create1/accept4/
  dup3 mint it, `F_GETFD`/`F_SETFD` honor it, dup2/dup clear it, and
  `childExec` discharges flagged projections at the image swap —
  `_posixsubprocess`'s errpipe EOF is the parent's unblock; without
  it every capture_output() deadlocked.
- **`mmap` honors `MAP_FIXED`** — the anon arm bumped `mmap_top` and
  returned success at the wrong VA; musl's PROT_NONE-reserve /
  BSS-tail overlay only checks `== MAP_FAILED` → nondeterministic
  mallocng `a_crash`. Fixed-or-fail now, replaced frames freed, and
  the bump cursor skips live spans. See
  `concepts/frag-fixed-map-address-is-the-contract.md`.
- `pipe2`(293) armed on the pipe arm — CPython's errpipe speaks it
  natively.
- `rdmsr`/EXC dump carries `fs=`+`nr=` — the fault forensics that
  named the loader crash.

## Notes

- klanker is pure CPython ≥3.10; every dependency is a project-owned
  `agents-*` stdlib package — no wheels, no C extensions in the core
  path. `pyratatui` TUI is optional (pty/termios already landed).
- 24/7 bot-to-bot on one kernel is the demo shape: two children, one
  unix socket, zero network — proven here.
