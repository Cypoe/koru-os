-- M9 probe config for Hyprland 0.56 on koru-os (TCG, llvmpipe): logs to stdout, no
-- animations/blur/shadows (software rendering), no logo, no update/ANR dialogs.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.config({
    debug = { enable_stdout_logs = true, disable_logs = false },
    animations = { enabled = false },
    decoration = { blur = { enabled = false }, shadow = { enabled = false }, rounding = 0 },
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
})
