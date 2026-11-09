# COMPOSITOR DESIGN — the contract before the multi-window build

Branch `native/m1-dumb-kms`. Status: design study, pre-build. Every claim
about our code cites the file that proves it; every claim about wlroots /
Hyprland / Mutter / Compiz cites the mechanism by name (sources listed at
the end). Where a mechanism is asserted from knowledge rather than this
session's reading, it says so.

The question this answers: **how do existing compositors structure the
render loop, and which parts of that structure survive translation to a
CPU-2D, single-eDP, dumb-KMS path with no GL, no Wayland, and no client
protocol?**

---

## 0. What we already have (the ground truth this maps onto)

Three display-relevant modules exist today, on two different boot paths:

| module | path | what it is |
|---|---|---|
| `koru/native/comp.zig` | `fullBoot` arm only (`boot.zig:441`) | "nativeCompositor" — z-ordered layer stack (`layers[]`, index = z, `comp.zig:52-64`), per-pixel topmost-wins resolve (`pxAt`, `comp.zig:66-75`), damage→composite→present (`damage`/`composite`, `comp.zig:111-139`), compositor-owned pointer (`feedMotion`/`flush`, `comp.zig:223-248`). Composites **pixel-at-a-time through `koruos_fb_px` into whatever `fb` adopted** — immediate mode, no back buffer. |
| `koru/native/surf.zig` | `fullBoot` arm (exported externs, `boot.zig:66-70`) | `koruos/surface` provider — pool of 8 surfaces, pmm-contiguous backings, `open/fill/px/blit/present/move/geom/map/close`. `present(damage)` hands a scene-space rect to `comp.damage` (`surf.zig:136-146`); `move` damages vacated+destination (`surf.zig:151-159`). This is the wl_surface.commit-shaped seam — already the right abstraction. |
| `koru/native/win.zig` + `cursor.zig` | `shell.run()` path (`shell.zig:39-40`) — the live T590 path | `kwin`: ONE 320x200 window, retained-restore damage (snapshot under-window px, restore on move, `win.zig:173-202`), dmabuf backing when i915 is up / pmm otherwise (`win.zig:220-251`), press-edge-inside drag with grab offset (`win.zig:372-421`), heal stride for console bleed (`win.zig:423-434`). `cursor.zig` owns pointer position + XOR sprite + `compositeSuspend/Resume` bracketing (`cursor.zig:189-199`). |
| `koru/native/i915/kms.zig` | shell commands `kms`/`kmsbuf`/`kflip`/`kdmabuf` | M1 object-model modeset (HW-proven), M2 atomic `flipCommit` = one DSPASURF write applied at next vblank + `vblankWait` polling DEIIR (`kms.zig:653-701`), M3 dmabuf export/import/flip (`kms.zig:738-901`). All HW-confirmed on the T590 per `session/m1-dumb-kms/NOTES.md`. |

**The divergence that matters:** `comp.zig` and `win.zig` are two
compositors that never met. `comp.zig` has the right scene model (z-stack,
damage, pointer) but runs only on the `fullBoot` arm where `user.zig`
syscalls feed it `surf.zig` surfaces; `win.zig` runs on the shell path
where the T590 actually lives, but is a single-window retained-restore
hack. The design below unifies them into ONE compositor core serving both.

---

## 1. The reference model, reduced to mechanisms

### 1.1 wlroots — the reference implementation

Read this session: `types/scene/wlr_scene.c` (master), `wlr_damage_ring.h`
docs, `wlr_scene.h` docs.

**Scene graph.** `wlr_scene` is a tree of nodes — `TREE` (container),
`BUFFER` (a wlr_buffer + src/dst box + opacity + transform), `RECT` (solid
color). Every node carries a `visible` pixman_region32. Compositors do NOT
manually track damage per surface; they mutate nodes and the scene
recomputes.

**Damage flow (verified in source):**

- Mutation (`set_position`, `set_buffer`, enable/disable, restack) →
  `scene_update_region()` walks the update box top-down; each node's
  `visible` region is recomputed as `visible − update_region ∪ new_visible`,
  clipped to its own rect (`wlr_scene.c` ~line 640-660).
- `calculate_visibility` (on by default): each node's **opaque region** is
  subtracted from the `visible` accumulator as the walk descends — a node
  fully covered by opaque nodes above it gets an empty `visible` region and
  is culled from the render list. Occlusion culling is free damage
  reduction.
- `scene_output_damage()` clips damage to the output rect, calls
  `wlr_output_schedule_frame(output)`, and unions into
  `scene_output->damage_ring` + `pending_commit_damage` (`wlr_scene.c`
  ~line 445-460). Damage that doesn't intersect the output is dropped.
- `wlr_scene_output_needs_frame()` = `output->needs_frame` OR
  `pending_commit_damage` non-empty OR gamma change (~line 2240).
- `wlr_scene_output_commit()` → `build_state()` constructs a **render
  list**: nodes whose `visible` region intersects the damage box, in
  top-to-bottom order (~line 1964-2030). Per entry it first tries
  **direct scanout** (a lone fullscreen buffer can bypass compositing
  entirely, ~line 2080+), then renders each node's texture/rect clipped to
  `render_region = node->visible ∩ damage` (~line 1503-1560). Only damaged
  pixels are touched.
- Commit hands a `wlr_output_state` (with the rendered buffer) to
  `wlr_output_commit_state` → DRM backend atomic commit → **pageflip
  applied at next vblank**; `frame_done` signals fire after.
- `wlr_damage_ring`: per-swapchain-buffer damage accumulator.
  `damage_ring_add` unions buffer-local damage into `current`;
  `rotate_buffer(buffer, damage)` returns the accumulated damage the
  passed buffer needs redrawn — i.e. "what differs between the buffer
  about to be painted and what it last showed" — and rotates the ring.
  This is what makes N-buffer swapchains correct: each buffer remembers
  it is stale exactly where the scene changed while it wasn't front.

**Timing model:** repaint is demand-driven (`schedule_frame` → `needs_frame`
→ frame event → render → commit). The DRM backend's pageflip handler fires
on the vblank IRQ and re-arms `needs_frame`. Presentation is
vblank-locked by construction: the CPU renders into a non-scanned buffer
and the hardware flips at vblank; there is no tear window because the
scanned buffer is never written.

### 1.2 Hyprland — animation/focus model (in-house reference exists)

We have a real Hyprland render on Unikraft in
`koru-desktop/session/m5-m9port` (accept runs `m9-accept1/2`,
`shot.ppm` = rendered desktop, foot window #242424 over #111111
wallpaper). Mechanism names verified this session via source/wiki:

- **Per-monitor damage region**: `CMonitor::m_damage` (CRegion/pixman);
  every mutation funnels through `CMonitor::addDamage(box|region)` which
  unions and calls `scheduleFrame(AQ_SCHEDULE_DAMAGE)` (`src/output/
  Monitor.cpp`). `CHyprRenderer::damageBox/damageWindow/damageSurface/
  damageRegion/damageMonitor` are the emitters (`src/render/Renderer.cpp`).
- **Render scheduling**: `CMonitorFrameScheduler`
  (`src/output/MonitorFrameScheduler.cpp`) aligns render start to vblank
  via explicit sync; if the render misses the frame deadline it renders
  immediately and commits at the next `onPresented` (`m_pendingThird`).
  `m_pendingFrame` re-arms frames scheduled mid-render. Damage forces
  `m_forceFullFrames = 2` on config/state changes — a bounded
  full-redraw escape hatch, not the default.
- **Focus model**: `input:follow_mouse` modes 0–4 (0=none, 1=always,
  2=detached keyboard/pointer focus, 3=separate, 4=border-crossing-only —
  PR #2135), `input:mouse_refocus`, click-to-focus on button press,
  `CCompositor::focusWindow` raises+focuses. **Drag is layout-neutral**:
  `IHyprLayout::onBeginDragWindow/onMouseMove/onEndDragWindow` — the input
  manager owns `currentlyDraggedWindow` + drag offset and asks the *layout*
  where the window goes; tiling vs floating is a layout decision, drag
  mechanics are not (`src/layout/` interfaces; `onEndDragWindow` damages
  the window and refocuses it). Dragging suppresses focus-follows-mouse
  (PR #1879: pointer updates to clients are skipped while dragging).

### 1.3 Mutter — damage + vblank (skimmed)

- Clutter's paint path: `redraw_clip`/`queued_redraw_clip` +
  `PAINT_DAMAGE_REGION` mode repaints only the damage region; enabling
  damage painting **disables buffer age** (verified: mutter commit
  "clutter/stage-cogl: Fix painting the redraw clip with the damage
  region" — the two mechanisms are mutually exclusive).
- `ClutterFrameClock`: per-stage-view (per-CRTC) frame clocks rescheduled
  off presentation-time feedback, not a fixed timer; `record_flip_time`
  stores last KMS submission; `compute_max_render_time` = refresh interval
  × 0.875 (or measured estimate) — render must finish inside the budget or
  the frame drops. Each CRTC gets its own clock so a 144Hz panel doesn't
  wait on a 60Hz one (irrelevant for us — one output — but the
  *presentation-feedback-driven* clock is the transferable idea).

### 1.4 Compiz — damage (skimmed)

DamageScreen plugin: a per-screen damage region accumulated across
plugins; plugins wrap `preparePaintScreen`/`paintScreen`/`donePaintScreen`
and push damage; the core subtracts/clears per frame. vblank sync via
`GLX_SGI_video_sync` — partial swap synced to vblank, the ancestor of
everyone else's pageflip discipline. Historical interest mostly; the
transferable bit is "damage is a first-class region object the whole
pipeline reads," which wlroots/Hyprland both kept.

### 1.5 The mechanism inventory (what a compositor actually is)

Every reference reduces to the same six mechanisms:

1. **Scene graph** — nodes with geometry + content + stacking; mutation
   marks damage. (wlroots tree; Hyprland window/decor layers;
   Compiz window+frame plugins.)
2. **Damage tracking** — union of changed scene-space rects per frame;
   per-buffer stale tracking for swapchains; occlusion culling as a
   damage reducer.
3. **Render** — walk visible nodes back-to-front (painter's order),
   clip each to the damage region, write into a *non-scanned* buffer.
4. **Present** — atomic handoff of the finished buffer to the scanout at
   vblank (pageflip); never write the scanned buffer.
5. **Input** — pointer position/buttons from device; hit-test against
   scene top-down; click-to-focus + raise; drag = grab offset + motion +
   layout-neutral move; keyboard focus routed to the focused node.
6. **Buffer/surface lifetime** — producer-owned backing, refs/handles,
   compositor never copies client pixels (wlroots wlr_buffer;
   dma-buf refs — our M3 export table is already this).

---

## 2. Mapping onto our path

### 2.1 What applies DIRECTLY

| compositor mechanism | our equivalent | verdict |
|---|---|---|
| Scene nodes {geometry, content, z} | `comp.zig` layer stack (`layers[]`, index=z) + `surf.zig` pool | **have it** — needs window objects (chrome+focus) around the layer |
| Damage = union of changed rects | `comp.damage(x,y,w,h)` already composites only the given scene rect | **have it** — needs a rect-list accumulator so N damages per tick coalesce before paint |
| Occlusion culling | `comp.pxAt` resolves topmost per pixel; a fully-covered layer wastes paint | **adapt** — cheap version: skip layers whose rect ∩ damage is empty; full opaque-region subtraction is a later refinement |
| Per-buffer damage ring (swapchain correctness) | nothing yet — `fb.generation()` is the only staleness guard | **build in MC-2** — two accumulators, one per scene buffer (see §3.3) |
| Retained-mode surface backings | `surf.zig` pmm backings; `win.zig` dmabuf/pmm backing | **have it** — extend backing kinds to dmabuf for GTT residency |
| Producer→display decoupling | M3 `dmabufCreate/Map/Import/Unref` token table | **have it** — the compositor seam is already dma-buf-shaped |
| Atomic commit at vblank | `kms.flipCommit` (DSPASURF write) + `vblankWait` (DEIIR poll) | **have it, HW-proven** — needs a frame loop around it |
| Click-to-focus + raise + drag | `win.zig` press-edge drag + grab offset; `comp.zig` z-stack | **have the parts** — needs N windows + focus state |
| Layout-neutral drag (Hyprland `onMouseMove`→layout) | nothing — `win.zig` moves the window itself | **build** — drag emits "move request" to a placement authority; default policy = free-float |
| Cursor as topmost layer, never painted over | `cursor.compositeSuspend/Resume` XOR bracket | **have it** — keep; the cursor stays ABOVE the scene, composited last |

### 2.2 What needs ADAPTATION for CPU-2D (no GL)

- **Render pass → rect-list rasterizer.** wlroots emits
  `wlr_render_pass_add_texture/rect` into an GLES pass; we emit "for each
  visible layer top-down, for each damage rect, copy rows" — the CPU
  equivalent. No shaders, no FBOs, no blend modes: **XRGB8888 opaque
  only** (comp.zig's existing ruling, `comp.zig:29` — the seam carries no
  alpha). Alpha, transforms, scaling, rotation: all out (non-goals §5).
- **Texture upload/dmabuf import → CPU map blit.** wlroots imports client
  dma-bufs as textures; our "import" is `dmabufMap` → identity CPU pointer
  → row-copy into the scene buffer. GPU-side zero-copy doesn't exist on
  this path and isn't needed at 1080p CPU speed for window-count damage.
- **Frame clock → shell tick + vblank poll.** Mutter's
  presentation-feedback clock becomes: damage pending → composite →
  flipCommit → `vblankWait`-style DEIIR poll gates the NEXT composite
  (can't paint back buffer while previous flip still pending — actually
  CAN with 2 buffers + 1-deep pipeline; spec in §3.3). No IRQ context —
  `consoleMode` has IF=0, polling is the only honest door (same
  constraint `kms.vblankWait` already lives with).
- **wl_surface.commit damage → `present(x,y,w,h)`** — already the exact
  shape (`surf.zig:136`: "damage is surface-local; the compositor works
  in scene coords"). Buffer-age damage hints (`wlr_buffer` age) have no
  analog — our producers repaint whole backings or track their own
  damage; the compositor trusts the damage rect it's given plus its own
  scene-state damage.
- **Direct scanout** — wlroots' biggest optimization (fullscreen client
  buffer bypasses compositing). Our analog exists and is trivial: a
  fullscreen opaque layer IS the scanout candidate — but only via the
  dumb-flip path, and only when it's the sole visible layer. Defer;
  name it, don't build it (MC-2 note).

### 2.3 What we DELIBERATELY SKIP (and why it's safe to skip)

- **Scene tree / transforms.** wlroots' TREE nodes exist for nested
  coordinate transforms, rotations, fractional scaling. Single eDP, no
  rotation, integer coords → a FLAT layer list is the honest structure.
  If a second output or transform ever arrives, the flat list becomes a
  tree then — the node abstraction (§4) doesn't preclude it.
- **libinput/evdev, libxkbcommon, wlroots backend abstraction.** We have
  PS/2 aux (`mouse.zig` ring) + 8042 kbd (`kbd.zig`); input events are
  already `InEv{kind,code,pressed,dx,dy}` (`kbd.zig:288-294`). No keymap —
  scancode→char is `kbd.pollChar`'s job today; keyboard FOCUS routing is
  compositor work, keymap is not.
- **Sub-pixel text, font shaping, GPU text.** `text.zig`'s 8x8 font is
  diagnostics-grade; CmdView text (MC-3) uses the same font honestly
  labeled. SDF/shaping is an oshun problem, not a compositor problem.
- **VRR, tearing modes, multi-plane overlay.** `planes[1]` sprite plane
  exists in the object model unwired (`NOTES.md` honest-limits) — cursor
  on a hardware plane is a later rung; the XOR sprite is correct today.
- **Xwayland, xdg-shell, layer-shell, input-method, DRM leases, DPMS
  beyond panel.on.** No clients exist that need them; the non-goal list
  (§5) makes this contractual, not incidental.

---

## 3. The architecture

### 3.1 One compositor core, two front-ends

```
                    ┌─────────────────────────────────────┐
   shell path:      │  win.zig windows (kwin→kwin2)        │
   (T590 live)  ───►│                                     │
                    │         SCENE CORE                  │
   fullBoot path:   │  layer stack + damage + focus +     │
   user.zig syscalls│  pointer + present seam             │
   → surf.zig ─────►│  (evolved comp.zig)                 │
                    └──────────────┬──────────────────────┘
                                   │ present(damage_rects)
                    ┌──────────────┴──────────────────────┐
                    │  PRESENT BACKENDS                   │
                    │  A: immediate — paint into fb       │
                    │     scanout surface (LFB/dumb,      │
                    │     pre-'kms' compatible)           │
                    │  B: flip — composite into back dumb,│
                    │     kms.flipCommit at vblank        │
                    └─────────────────────────────────────┘
```

The present seam is deliberately the same shape `surf.present` already
uses: **the compositor hands damage, the backend decides pixels**. Backend
A is what comp.zig does today (works on GRUB/EFI fb AND post-`kms` dumb —
`win.zig` proved both); Backend B is what makes it tear-free. Choosing B
is a device-up condition (`kms.device().up`), never a silent fallback —
the same "named, not hidden" discipline as `win.zig`'s backing-kind
marker (`win.zig:229-231`).

### 3.2 The scene core (what gets built)

Evolve `comp.zig` into the core — it already owns the right invariants:

- **Layer** = `{buf, pitch, x, y, w, h, z, kind, owner}` — flat list,
  index order = z (comp.zig's existing ruling). `kind` distinguishes
  `root` (console/wallpaper), `window` (client+chrome), `overlay`
  (cursor is NOT a layer — it's the pointer, drawn last by the cursor
  module).
- **Window** = a layer plus compositor state: `{focus, dragging, grab_dx,
  grab_dy, titlebar rect, content rect}`. Chrome (titlebar/border) is
  painted INTO the window backing by its producer (kwin's existing
  approach, `win.zig:143-150`) — the compositor doesn't draw decorations,
  it routes input by them. This keeps "window" = "a surface with chrome
  and focus," which is exactly the layout-neutral unit §4 needs.
- **Damage accumulator** = bounded rect list (cap ~32; union-merge on
  insert, clip-to-scene; overflow → whole-scene damage, the honest
  degenerate). Every mutation — surface present, move, attach, detach,
  window drag step, console scroll — unions its scene-space rect(s).
  Once per tick: composite ALL accumulated damage top-down, clear.
  This replaces both `win.zig`'s snapshot/restore AND comp.zig's
  immediate per-call repaint with one coalesced pass — **this is the
  flicker fix**: today every `comp.damage` call paints immediately and
  kwin's heal stride re-blits on a timer; coalesced damage means one
  correct repaint per tick, and revealed regions repaint from retained
  backings instead of snapshots.
- **The root layer problem (the real flicker/occlusion cause).** Today
  console text renders DIRECTLY into the scanout buffer via
  `koruos_fb_px`/`text.zig` — there is no retained root backing, so any
  window covering console text destroys it (kwin's "named loss",
  `win.zig:15-20`, heal stride `win.zig:53`). Fix: the console becomes a
  **root layer with its own backing buffer** — `text.zig` renders into
  it, console scroll/damage unions into the accumulator like any other
  layer. Window moves then reveal true console pixels, not a snapshot.
  This is what every real compositor has (the "desktop"/root window) and
  it's the difference between "window floats over scanout" and
  "window floats over a scene."
- **Focus**: `focused` = topmost window under last click OR explicit
  raise. Click = press EDGE (not level — `win.zig:387-390`'s proven
  rule) inside a window's content rect → focus+raise; inside titlebar →
  focus+raise+arm drag; outside all windows → focus=root (console
  keeps keyboard). Drag = grab offset + motion → move request to
  placement authority (§4) → damage vacated+dest (comp.move's proven
  shape, `comp.zig:171-189`). Keyboard: `kbd.pollChar` events route to
  focused window's input queue; unfocused → shell/console as today.
  v1 ships click-to-focus only; follow_mouse is a named later option
  (Hyprland's 0-4 modes are the reference, we take mode "click" = their
  click-to-focus baseline).

### 3.3 Presentation timing — the two-stage plan

**MC-a (immediate mode, default until 'kms' runs):** composite damage
into `fb.scanout()` directly — exactly comp.zig's current behavior,
extended to coalesced damage + N layers. Works pre-'kms' on the GRUB/EFI
LFB and post-'kms' on the dumb buffer. Tear risk exists (scanned buffer
is written live) but damage rects are small; name it, don't hide it.
`fb.generation()` gating (`win.zig:30-35`) stays — a modeset/flip
repoints the surface and the scene re-targets.

**MC-b (flip mode, post-'kms'):** two full-screen scene dumb buffers
(front=scanout, back=render target), each with a damage accumulator:

```
per tick:
  acc_pending ∪= scene_damage_this_tick        // union into BOTH bufs' accs
  back = non-scanout buffer
  repaint_region = acc[back]                   // everything stale in back
  composite layers top-down clipped to repaint_region into back.map
  acc[back].clear()
  kms.flipCommit(back.handle)                  // DSPASURF write → vblank
  // back is now front at next vblank; old front becomes back,
  // its acc keeps accumulating — it IS stale there by definition
```

The per-buffer accumulator IS wlroots' `wlr_damage_ring` reduced to 2
buffers: every scene damage unions into both accumulators; each is
cleared only when its buffer is painted. Buffer B alternates, so each
repaint covers ~2 frames of accumulated damage — correct by
construction, no history needed. N-buffer generalization is the same
loop (acc[i] per buffer).

Frame pacing: `flipCommit` arms the flip; the display engine applies it
at next vblank — CPU can immediately start compositing into the OTHER
back buffer (now free) without waiting, giving 1-frame pipeline depth.
`vblankWait` is called on a stride (e.g., once per N ticks or on
commit-result need) to drain DEIIR and keep the event path honest —
the flip itself doesn't need the wait to be correct, the wait is the
oracle that vblanks are arriving (NOTES.md M2 discipline). Tear-free
by construction: scanout reads front while CPU writes back — the
property every reference compositor buys with a swapchain, we buy with
two dumbs.

**Costs, named:** two 1920×1080×32 dumbs ≈ 16.6MB contiguous EACH
(2025 pmm frames, first-fit scan — `pmm.zig:161-185` warns ">a few MiB
of contiguous is the wrong question"). Mitigation: allocate both at
compositor init BEFORE window backings fragment RAM; raise `MAX_DUMBS`
(currently 4, `kms.zig:104`) and `MAX_DMABUFS` (4, `kms.zig:738`) — a
compositor with 2 scene buffers + console root + N windows exceeds 4
handles trivially. Window backings stay small (320×200-class); pmm
fallback exists for QEMU/pre-'kms'.

### 3.4 Input routing

Single drain point per tick (shell.zig:39-40 already loops
`cursor.tick(); win.tick();`):

```
mouse.pop() events → scene.pointer {x,y,buttons}   // cursor.zig keeps
                                                  // sprite+position today;
                                                  // scene reads pos()
per tick:
  if press_edge: hit = topmost_window_at(pointer) → focus/raise/arm-drag
  if drag_active: move_request(window, pointer - grab) → damage
  if release: drop
  kbd.pollChar → focused_window.input or shell line (v1: shell keeps
                 keys unless a window is focused AND declares key intake)
```

`cursor.zig` stays the device-side sprite (XOR, suspend/resume bracket —
`cursor.zig:189-199`); the scene owns pointer *semantics* (position is
already shared via `cursor.pos()`, `cursor.zig:178-180`). comp.zig's
parallel pointer (`feedMotion`, `comp.zig:223-236`) folds into the same
model — ONE pointer owner, cursor.zig renders it. This unification is
MC-a work item zero.

---

## 4. The layout-neutral abstraction (extensibility contract)

This is the part that must be right BEFORE the multi-window build,
because retrofitting it is the rework the brief warns about.

**Window ≠ position.** A `Window` owns pixels+chrome+focus; it does NOT
own x/y policy. Position changes flow through a **placement authority**:

```c
// the only verbs the input/drag path may call:
place_request(win, x, y)   // → placement.decide(win, x, y) → win.set_pos
```

v1's placement authority is `float_policy`: clamp to scene, free
position (what win.zig does today). A tiling policy later implements the
SAME `decide` — drag still works (Hyprland proves this: drag asks the
layout, layout answers; `IHyprLayout::onMouseMove` is layout code, the
drag mechanics are input-manager code). Terminals later = windows whose
producer is a cell-grid text renderer — the compositor never knows.

**Surface ≠ window.** `surf.zig`'s koruos/surface contract
(open/fill/px/blit/present/move/geom/map/close) stays the client seam —
a "window" in the scene-core sense is optional chrome around it. A bare
surface (no titlebar) is a valid layer; a window is a surface + focus +
chrome-in-backing. This mirrors wlroots (wlr_surface → scene_buffer node
→ compositor adds decoration nodes) without needing the tree.

**Input routing is scene-coord hit-testing, not window-list scanning.**
`topmost_at(x,y)` walks layers top-down — works identically whether the
layer is a kwin window, a surf.zig client, or an oshun CmdView surface.
Focus is a pointer to a layer, not an index into a WM registry.

**Content is producer-owned, always.** The compositor composites; it
never authors client pixels. CmdView (MC-3), console text, kwin's
painter — all producers into backings. This is the custody law applied
to pixels: the ledger (who owns this buffer) is the allocator/refs, not
a compositor-side copy.

---

## 5. EXPLICIT NON-GOALS

Contractual, not incidental. The architecture ADMITS these later; it
does not ship them now:

- **No Wayland protocol.** No wl_surface/wl_pointer/wl_keyboard wire
  protocol, no client library, no socket. The `koruos/surface` extern
  seam + `user.zig` syscall path IS the client contract. Wayland-shaped
  semantics (commit=damage, buffer=retained backing, seat=focus) are
  already internalized — the wire is not.
- **No OpenGL/GPU rendering.** CPU-2D XRGB8888 only. No shaders, no
  EGL/GL, no GPU texture upload, no hardware planes beyond what M1-M3
  already proved (dumb scanout + optional sprite plane later). If a
  feature needs GL it does not exist on this arm.
- **No tiling-layout-first.** Free-floating placement is the v1 policy.
  Tiling is a `place_request` policy module that lands later without
  compositor rework (§4). We do not build layout before windows exist.
- **No terminal emulation.** No PTY, no terminfo, no cell-grid terminal
  widget. Text content arrives via the 8x8 font (diagnostics-grade,
  honestly labeled) or later via oshun's term component — the compositor
  composites whatever backing it's handed.
- Also out: multi-monitor, alpha/transparency, animations (Hyprland's
  frame scheduler is the reference when they arrive — damage already
  supports per-frame invalidation), direct scanout of client buffers
  (the degenerate fullscreen case is noted, not built), keyboard
  layouts/keymaps beyond scancode→char.

---

## 6. Koru-native divergences (Omni SCENE.md alignment)

The compositor is where three Omni laws become physical. Named, not
aspirational:

- **Derived, never authored** → the scene enumerates what exists. There
  is no window registry someone maintains — layers appear because a
  surface opened (`surf.zig` pool / `win.zig` toggle), disappear because
  it closed. comp.zig already does this (`attach`/`detach`,
  `comp.zig:145-216`); the multi-window build must NOT grow a parallel
  WM-side window list. Window chrome (focused/unfocused titlebar) is
  DERIVED from focus state at paint time, not stored per-window.
- **Custody** → buffer ownership is refs-counted producer-side
  (`dmabufUnref` at refs=0, `kms.zig:807-821`; `pmm.freeBlock` on
  close, `surf.zig:190`). The compositor holds pointers into producer
  backings during composite and NOTHING after — no copy, no cache, no
  "compositor-owned pixels." Damage accumulators are the only
  compositor-side scene state besides geometry/z/focus.
- **Attention / fog-line** → focus IS the attention axis. Click
  stamps attention (raise+focus); occlusion culling (a fully-covered
  layer's damage doesn't reach the panel) is the fog-line at compositor
  scale — an occluded window's updates are invisible BY CONSTRUCTION,
  which is also the power-saving property. `last_seen`-style attention
  timestamps on windows are a later omni integration point — the scene
  core exposes focus/raise events a custody layer can stamp; it does
  not implement decay (that's omni's bridge, not the display server).
- **Scene = prompt = enforcement** (Omni law 1, echoed in desktop
  SCENE.md "derived surfaces") → the CmdView backend (MC-3) is the
  proof: an oshun solver's render-command stream paints a window
  without the compositor knowing layout, widgets, or markup. The
  compositor's contract with content is "damaged backing + scene rect" —
  everything above that is derived.

---

## 7. Milestone plan

Ordered by dependency and by what each stage proves. Each has a falsing
oracle (the session's discipline: name what would prove it wrong).

### MC-1 — "scene": damage-tracked multi-window compositor (flicker fix + z-order/focus)

**Scope:** evolve comp.zig into the scene core; unify pointer ownership;
N windows on the shell path; root console layer; coalesced damage;
immediate-mode present (backend A).

Work items:
1. Scene core module (comp.zig evolution or `scene.zig` extraction —
   decide at build time; comp.zig's layer/z/damage skeleton is the
   base): flat layer list, bounded damage-rect accumulator, one
   composite pass per tick.
2. Root layer: console backing buffer; `text.zig` renders into it
   instead of fb directly; console scroll unions damage. (Kills the
   occlusion loss that forces kwin's heal stride.)
3. Window objects: win.zig's single-window logic → N windows, each
   {backing, scene rect, z, focus, drag state}. Chrome stays
   producer-painted; `content_rect`/`titlebar_rect` declared for
   hit-test routing.
4. Focus: press-edge hit-test top-down → focus+raise; titlebar drag;
   outside → root focus. Keyboard routing stub (focused window gets
   keys; v1 windows may declare no key intake → shell keeps them).
5. Pointer unification: cursor.zig keeps sprite+position;
   comp.zig's feedMotion pointer folds into scene.pointer; ONE owner.
6. Present backend A: composite damage into fb.scanout() (works
   pre-'kms' LFB and post-'kms' dumb — `win.zig`'s dual-path precedent).

**Proves:** 2+ draggable windows with correct z-order and occlusion —
move A off B reveals B's real pixels (not a snapshot); console text
survives being covered; no heal stride, no flicker on drag.
**Oracle:** QEMU screendump/serial markers + T590 panel; `KORU scene:`
markers per composite (damage rect count, layers painted) on UDP.

### MC-2 — "flip": vblank-synced presentation

**Scope:** present backend B — double-buffered scene + atomic flip per
frame.

Work items:
1. Two scene dumbs via `kms.dumbCreate` (early alloc, before window
   backings); raise MAX_DUMBS/MAX_DMABUFS.
2. Per-buffer damage accumulators (§3.3); composite into back clipped
   to its accumulator; `flipCommit`; DEIIR drain on stride.
3. `fb.rebase`/`fb.generation()` discipline extended: scanout follows
   `gdev.scanout`; scene re-targets on modeset (win.zig rescan pattern
   generalized to whole-scene repaint — modeset = whole damage).
4. Console root layer renders into... decision point: root backing
   stays pmm (it's a layer, composited like others) — only the SCENE
   buffers are dumbs. Console is content, not scanout.

**Proves:** tear-free motion (drag window across a text region at 60Hz
— no partial-frame tear line); flip cadence markers (`kms:vblank` +
`scene:flip` on UDP); damage accumulator correctness (frame N's back
buffer shows exactly the union of last-2-frames damage repainted).
**Oracle:** T590 panel video/eyeball + UDP marker stream; QEMU can't
exercise i915 (same HW-only constraint as M1-M3 — honest bound).

### MC-3 — "oshun": CmdView backend

**Scope:** first real application content — an oshun component tree's
CmdView stream painted into a window backing.

Work items:
1. CmdView rasterizer (CPU): kinds RECT(1)/TEXT(3)/IMAGE(4)/
   SCISSOR(5,6)/BORDER(2)/CUSTOM(9) → XRGB8888 rows into a window
   backing. Corner radius → filled-rect approximation v1 (named);
   borders → edge strokes; text → text.zig font at fs-scaled cell or
   honest nearest-size (named choice at build); image → blit via
   `surf_blit`-shaped row copy; ud (eid) → hit-region side table for
   input routing.
2. A demo window: minimal oshun markup → `clay:each`/`nativelayout`
   CmdView drain → rasterize → present damage. Producer-owned: the
   window backing is written by the CmdView consumer, compositor just
   composites.
3. Input: CmdView `ud` rects → click hit-test routes to element ids —
   the compositor's `topmost_at` returns the window; the WINDOW's own
   hit-map (from ud rects) resolves the element. Compositor stays
   layout-agnostic; interactivity is producer-side.

**Proves:** "derived never authored" at chrome scale — solver output
becomes pixels with zero compositor knowledge of layout; the
layout-neutrality contract (§4) demonstrated by a real second content
type (after console+kwin).
**Oracle:** screendump vs CmdView stream diff (same gate discipline as
nativelayout's CAND==REF); T590 panel.

### Explicitly NOT in this plan

Wayland wire, GL/GPU, tiling policy, terminal, animations, multi-output,
direct scanout, hardware cursor plane — all §5 non-goals; each names
its admission rung if revisited.

---

## 8. Source register

Local (read this session):
- `koru/native/comp.zig` (full), `surf.zig` (full), `win.zig` (full),
  `cursor.zig` (full), `fb.zig` (full), `text.zig` (full),
  `i915/kms.zig` (full), `shell.zig` (full), `boot.zig:330-465`,
  `kbd.zig:280-354`, `mouse.zig:140-200`, `pmm.zig:140-199`,
  `mmio.zig:1-53`, `koru/surface/index.kz`,
  `session/m1-dumb-kms/NOTES.md` (M1-M4+kwin sections).
- In-house Hyprland render: `koru-desktop/session/m5-m9port/NOTES.md`,
  `runs/m9-accept*/shot.ppm` (rendered desktop evidence).
- Omni/oshun charters: `omni/SCENE.md`, `oshun/SCENE.md`,
  `oshun/clay/index.kz:434-539` (CmdView contract),
  `oshun/clay/NATIVE_SOLVER_BRIEF.md`.

External (fetched/searched this session):
- wlroots `types/scene/wlr_scene.c` (master, gitlab.freedesktop.org) —
  scene_update_region, scene_node_update_iterator, scene_output_damage,
  render_list construction, direct-scanout attempt, wlr_scene_output_commit;
  `wlr_damage_ring.h` / `wlr_scene.h` docs (wlroots.pages.freedesktop.org);
  deepwiki scene-graph overview (secondary).
- Hyprland `src/output/Monitor.cpp` (addDamage/scheduleFrame),
  `src/output/MonitorFrameScheduler.cpp` (onSyncFired/onPresented),
  `src/output/Monitor.hpp` (m_pendingFrame/m_renderingActive),
  `src/render/Renderer.cpp` damageBox family (via commit patch +
  directory listing), wiki Configuring-Hyprland input options,
  PR #2135 (follow_mouse modes), PR #1879 + commit a45fc64 (drag focus
  lock), `IHyprLayout::onEndDragWindow` (layout-neutral drag).
- Mutter: commits-list archives — clutter-frame-clock (per-view clocks,
  record_flip_time, SYNC_DELAY_FALLBACK_FRACTION), stage-cogl damage
  clip fix (damage painting disables buffer age).
- Compiz: launchpad XDamageReport merge (XDamageSubtract per-frame
  repair accounting), compiz-devel paintScreen wrap chain (historical).

Unverified-by-reading (asserted from knowledge, flagged): wlroots
`wlr_output`'s DRM pageflip handler internals (the scene side was read;
the backend side was not); Hyprland `CInputManager::handleMouseButton`
focus-on-press internals (focus model verified via config surface +
drag-focus-lock commits, not the full handler); Compiz DamageScreen
plugin source (mechanism known from mailing-list level only).
