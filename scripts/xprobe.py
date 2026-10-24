#!/usr/bin/env python3
# xprobe.py — the hosted gate's X11 witness. Talks libX11.so.6 through
# ctypes (no python-xlib, no xdotool on WSLg): finds the "koru-os" window
# by name, reads two pixels back through XGetImage (the painter's
# composite must be visible on the wire, not just in our buffer), then
# injects a KeyPress+KeyRelease via XSendEvent so the painter's
# koruos/input poll sees a real protocol event.
import ctypes, sys, time
from ctypes import c_void_p, c_ulong, c_uint, c_int, c_char_p, POINTER, byref, Structure

X = ctypes.CDLL("libX11.so.6")
X.XOpenDisplay.restype = c_void_p
X.XOpenDisplay.argtypes = [c_char_p]
X.XDefaultRootWindow.restype = c_ulong
X.XDefaultRootWindow.argtypes = [c_void_p]
X.XQueryTree.argtypes = [c_void_p, c_ulong, POINTER(c_ulong), POINTER(c_ulong),
                         POINTER(POINTER(c_ulong)), POINTER(c_uint)]
X.XFetchName.argtypes = [c_void_p, c_ulong, POINTER(c_char_p)]
X.XFree.argtypes = [c_void_p]
X.XGetImage.restype = c_void_p
X.XGetImage.argtypes = [c_void_p, c_ulong, c_int, c_int, c_uint, c_uint, c_ulong, c_int]
X.XGetPixel.restype = c_ulong
X.XGetPixel.argtypes = [c_void_p, c_int, c_int]
X.XDestroyImage.argtypes = [c_void_p]
X.XKeysymToKeycode.restype = ctypes.c_ubyte
X.XKeysymToKeycode.argtypes = [c_void_p, c_ulong]
X.XSendEvent.argtypes = [c_void_p, c_ulong, c_int, c_ulong, c_void_p]
X.XFlush.argtypes = [c_void_p]

def find_window(d, root, want):
    rr, pr, kids, n = c_ulong(), c_ulong(), POINTER(c_ulong)(), c_uint()
    if X.XQueryTree(d, root, byref(rr), byref(pr), byref(kids), byref(n)) == 0:
        return None
    for i in range(n.value):
        w = kids[i]
        name = c_char_p()
        if X.XFetchName(d, w, byref(name)) and name.value == want.encode():
            X.XFree(kids)
            return w
        sub = find_window(d, w, want)
        if sub:
            X.XFree(kids)
            return sub
    if kids: X.XFree(kids)
    return None

def pixel(d, w, x, y):
    img = X.XGetImage(d, w, x, y, 1, 1, 0xFFFFFFFFFFFFFFFF, 2)  # AllPlanes, ZPixmap
    if not img:
        return None
    p = X.XGetPixel(img, 0, 0)
    X.XDestroyImage(img)
    return p

def send_key(d, w, keycode):
    for etype, mask in ((2, 1), (3, 2)):  # KeyPress/KeyRelease + masks
        ev = (ctypes.c_char * 192)()
        ctypes.c_int.from_address(ctypes.addressof(ev) + 0).value = etype
        c_void_p.from_address(ctypes.addressof(ev) + 24).value = d
        c_ulong.from_address(ctypes.addressof(ev) + 32).value = w     # window
        c_ulong.from_address(ctypes.addressof(ev) + 40).value = w     # root (unused)
        c_uint.from_address(ctypes.addressof(ev) + 84).value = keycode
        ctypes.c_int.from_address(ctypes.addressof(ev) + 88).value = 1  # same_screen
        X.XSendEvent(d, w, 1, mask, ev)
    X.XFlush(d)

def main():
    d = X.XOpenDisplay(None)
    if not d:
        print("xprobe: no display"); sys.exit(1)
    win = None
    for _ in range(50):  # ~10s for the painter to map
        win = find_window(d, X.XDefaultRootWindow(d), "koru-os")
        if win: break
        time.sleep(0.2)
    if not win:
        print("xprobe: koru-os window not found"); sys.exit(1)
    print(f"xprobe: window=0x{win:x}")
    print(f"xprobe: bg@160,60 = 0x{pixel(d, win, 160, 60):06x}")
    print(f"xprobe: fgA@30,30 = 0x{pixel(d, win, 30, 30):06x}")
    kc = X.XKeysymToKeycode(d, 0x71)  # 'a'
    send_key(d, win, kc)
    print(f"xprobe: sent KeyPress+Release keycode={kc}")

main()
