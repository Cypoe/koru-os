// config.h — meson's config.h.in output, frozen for this tree.
// CAGE_HAS_XWAYLAND is set10 in meson (0/1, always defined); the
// arm has no X11 provider, so the value is an honest 0 — XWayland
// clients will refuse at the compositor, not silently degrade.
#define CAGE_HAS_XWAYLAND 0
#define CAGE_VERSION "0.1.5"
