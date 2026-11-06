---
type: belief
id: frag-the-arg-block-is-a-wire-contract
provenance: koru-os native session — klanker-child writable-fs pass, 2026-11
ts: 2026-11-10
tags: [native, execve, argv, envp, correctness]
---

**argv/envp size is a wire contract, not an implementation budget —
callers ship prompts, configs, and manifests inside it.** The execve
marshal carried a 512-byte blob, 16-entry vector cap, and 128-char
per-string cap — sizes chosen for "reasonable" args. Measured
refusals, in order: klanker's ~11-entry env (LOOP_CMD chain, long
value vars) → E2BIG at i=10; after raising to 2KiB, an argv entry
holding a multi-KB LLM system prompt ("You are a …") blob-filled;
after 8KiB, filled again — the same entry. Linux's real contract is
ARG_MAX ≈ 2 MiB total and MAX_ARG_STRLEN = 128 KiB per string; every
smaller kernel-side guess is a false refusal on legal wire.

- **Marshal scratch lives off the kstack.** `vecbuf` is a static
  128 KiB BSS buffer — execve is not reentrant inside one syscall, so
  shared scratch is safe, and the bound still refuses honestly past
  64 KiB per block.
- **Per-string caps are the wrong axis.** The per-string bound is now
  "what the block holds" — matching Linux, where MAX_ARG_STRLEN is a
  fraction of ARG_MAX, not a separate smaller number.
- **Env accumulates by convention.** `os.environ.setdefault(...)` is
  how apps pass config to their own subprocesses — env vectors grow
  past argv in real workloads; budget accordingly (MAXARGS 16→32).
- **Named evidence:** `MVEC blob-full` lines in the klanker serial
  (i=10, si=0x1fab, head = ASCII "You are ") — the dump that proved a
  prompt rides argv.
