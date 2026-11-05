// Hand-written for the koru-native arm: wayland+headless backends and
// the pixman renderer only. Every HAS_* is a meson boolean rendered as
// a #define-or-absent — absent reads 0 in the #if guards, so we write
// the honest zeros out to keep the grep table legible.
#ifndef WLR_CONFIG_H
#define WLR_CONFIG_H

// #define WLR_HAS_DRM_BACKEND — no DRM device nodes exist on this arm
// #define WLR_HAS_LIBINPUT_BACKEND — no evdev device tree either
// #define WLR_HAS_X11_BACKEND — X11 is not an arm
// #define WLR_HAS_GLES2_RENDERER — no EGL/GLES stack carried
// #define WLR_HAS_VULKAN_RENDERER — no vulkan stack carried
// #define WLR_HAS_GBM_ALLOCATOR — no gbm without DRM
// #define WLR_HAS_XWAYLAND — xwayland needs the x11 backend

#endif
