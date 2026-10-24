---
type: belief
id: frag-vroot-jail-membrane
provenance: koru-os hosted session — vendored rootfs desktop path, 2026-10
ts: 2026-10-24
tags: [hosted, vroot, wayland, webview, userns, compositor]
---

The hosted desktop path runs **vendored userspace** — an Arch rootfs
(`~/kvroot`, built by `scripts/mk-vroot.sh` from `hosted/vroot/Dockerfile`)
entered via `unshare -Urmpf` + chroot. Same kernel, real packages; no
root, no daemon-side bridging. What the jail membrane actually permits,
measured on WSL2:

- **Foreign-tmpfs binds are refused.** `/mnt/wslg` and `/dev` bind-mounts
  fail inside a userns ("wrong fs type"); plain dirs on ext4 bind fine.
  Sockets therefore ride a host-side relay (`vroot-relay.py`) into
  rootfs-visible paths.
- **Relays must preserve SCM_RIGHTS.** Wayland passes keymap and
  shm-pool fds as ancillary data; a `recv`/`send` byte-pump silently
  drops them (measured: `wl_keyboard.keymap` arrives "object expected
  fd"). `sendmsg`/`recvmsg` with the ancillary array, or nothing works.
- **`mknod` is EPERM in the userns.** `/dev` is a fresh tmpfs + devpts;
  null/full are symlinks to an empty file (open/read-EOF/write-discard
  — the common semantics), and random/urandom/zero are host-fed fifos.
- **`/dev/urandom` must never return EOF.** A fake urandom backed by an
  empty file sent WebKit's entropy init into a 100%-CPU read loop for
  seconds — measured, strace-pinned.
- **`hostexec` envp is empty — and stays that way.** Ambient env is a
  leak channel; entry scripts resolve their own PATH and home
  (`/usr/sbin` for chroot, `getent passwd` for HOME). The seam is right;
  the scripts were wrong.
- **Compositor-class backends need dmabuf or a seat.** Aquamarine
  (Hyprland 0.56) demands `zwp_linux_dmabuf_v1` on the wayland backend —
  WSLg runs software, advertises no dmabuf, has no `/dev/dri`: measured
  refusal, gate-pinned as an oracle row (`vroot-hyprland`). Real
  Hyprland on the hosted arm needs a dmabuf-advertising parent or moves
  to the native/DRM arm. Weston nested on `wl_shm` needs neither and is
  the honest compositor here — two-level compositing proven
  (foot → nested weston → WSLg).

Held consequence: "vendored" means **the rootfs is environment state,
not a build artifact** — `hosted/vroot/` carries the recipe
(Dockerfile, jail scripts, kvview shim), `mk-vroot.sh` rebuilds it, and
the gate probes for it. Missing oracle = failure, same as a missing X
server.
