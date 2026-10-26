---
type: frag
id: frag-a-wayland-server-never-steals-resource-link
provenance: vroot Hyprland oracle — kv-shim segfaulted in wl_resource_post_event on the second surface commit; gdb showed the frame callback's wl_object.interface as tcache freelist bytes (safe-linking `ptr>>12 ^ next` + key), i.e. posting done to freed memory
ts: 2025-10-26
---

# a-wayland-server-never-steals-resource-link

`wl_resource_get_link()` hands back `resource->link` — the link libwayland
itself uses to chain the resource into `client->wl_resource_list`. Inserting
that link into a compositor-private list is not sharing; it is theft.
`wl_list_insert` rewrites `elm->prev/next` without repairing the old list,
so the client's resource map is corrupted the moment the first
`wl_surface.frame` is queued. Every later `wl_resource_create`/`destroy`
then writes link fixups through dangling neighbors — heap corruption that
surfaces pages later as `post_event` dereferencing a tcache-mangled
`object.interface`. The crash looks like a protocol bug; it is an ownership
bug, two commits removed.

**Ruling**: a compositor tracks pending frame callbacks in its own nodes
(`struct kv_framecb { wl_resource *res; wl_list link; }`, resource
destructor removes+frees). `resource->link` is never compositor state.
Any compositor or broker we write that wraps wayland-server inherits this:
client-owned bookkeeping stays client-owned; the seam between them is the
destructor hook, not the link.

Sibling lesson from the same oracle: aquamarine's wayland backend publishes
an **empty mode list**. Hyprland's `preferred` rule resolves that to
`0x0@60`, fails validation, and disables the output after three retries —
silent from the protocol side, fatal to every commit. An explicit mode
request (`monitor = WAYLAND-1, 1280x800@60, 0x0, 1`) takes the custom-mode
path and the output lives. When a backend can't enumerate modes, the
oracle must name the geometry it wants; `preferred` is a trap.
