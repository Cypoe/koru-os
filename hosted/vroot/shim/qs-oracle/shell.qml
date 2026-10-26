// qs-oracle — minimal deterministic Quickshell config for the vroot oracle.
// A solid cyan layer-shell bar across the top edge: real layer-shell
// protocol on real Hyprland, and the color is the pixel oracle —
// the shim's dmabuf readback counts cyan band pixels as proof the shell
// surface was composited by Hyprland, not merely spawned.
import Quickshell
import Quickshell.Wayland
import QtQuick

ShellRoot {
    PanelWindow {
        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: 40
        color: "#00ffff"
        WlrLayershell.layer: WlrLayer.Top
    }
}
