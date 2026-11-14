// Access compiler flags via the per-user compiler_env module
const CompilerEnv = @import("compiler_env").CompilerEnv;

pub const panic = if (@import("builtin").mode == .Debug)
    @import("std").debug.FullPanic(@import("std").debug.defaultPanic)
else
    @import("std").debug.simple_panic;


const __koru_bare = struct {
    extern fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) c_int;
    extern fn free(ptr: ?*anyopaque) void;
    fn bareAlloc(_: *anyopaque, len: usize, alignment: @import("std").mem.Alignment, _: usize) ?[*]u8 {
        var p: ?*anyopaque = null;
        const a = @max(alignment.toByteUnits(), @sizeOf(usize));
        if (posix_memalign(&p, a, len) != 0) return null;
        return @ptrCast(p);
    }
    fn bareResize(_: *anyopaque, _: []u8, _: @import("std").mem.Alignment, _: usize, _: usize) bool { return false; }
    fn bareRemap(_: *anyopaque, _: []u8, _: @import("std").mem.Alignment, _: usize, _: usize) ?[*]u8 { return null; }
    fn bareFree(_: *anyopaque, memory: []u8, _: @import("std").mem.Alignment, _: usize) void { free(@ptrCast(memory.ptr)); }
    const vtable = @import("std").mem.Allocator.VTable{ .alloc = bareAlloc, .resize = bareResize, .remap = bareRemap, .free = bareFree };
    const allocator = @import("std").mem.Allocator{ .ptr = undefined, .vtable = &vtable };
};
const __koru_backing = if (@import("builtin").link_libc) @import("std").heap.c_allocator else if (@import("builtin").os.tag == .freestanding and !@import("builtin").cpu.arch.isWasm()) __koru_bare.allocator else @import("std").heap.page_allocator;
var __koru_leak_count: @import("std").atomic.Value(usize) = .init(0);
fn __koru_alloc(ctx: *anyopaque, len: usize, alignment: @import("std").mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    const r = __koru_backing.rawAlloc(len, alignment, ret_addr);
    if (comptime @import("builtin").mode == .Debug) {
        if (r != null) _ = __koru_leak_count.fetchAdd(1, .monotonic);
    }
    return r;
}
fn __koru_resize(ctx: *anyopaque, memory: []u8, alignment: @import("std").mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    return __koru_backing.rawResize(memory, alignment, new_len, ret_addr);
}
fn __koru_remap(ctx: *anyopaque, memory: []u8, alignment: @import("std").mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    return __koru_backing.rawRemap(memory, alignment, new_len, ret_addr);
}
fn __koru_free(ctx: *anyopaque, memory: []u8, alignment: @import("std").mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    __koru_backing.rawFree(memory, alignment, ret_addr);
    if (comptime @import("builtin").mode == .Debug) {
        _ = __koru_leak_count.fetchSub(1, .monotonic);
    }
}
const __koru_vtable = @import("std").mem.Allocator.VTable{ .alloc = __koru_alloc, .resize = __koru_resize, .remap = __koru_remap, .free = __koru_free };
pub fn koru_allocator() @import("std").mem.Allocator {
    return .{ .ptr = undefined, .vtable = &__koru_vtable };
}

pub inline fn __koru_intcast(comptime T: type, x: anytype) T {
    if (comptime (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe))
        return @as(T, @intCast(x));
    const dst = @typeInfo(T);
    const src = @typeInfo(@TypeOf(x));
    if (comptime (dst == .int and src == .int and dst.int.bits == src.int.bits and dst.int.signedness != src.int.signedness))
        return @as(T, @bitCast(x));
    return @as(T, @intCast(x));
}

pub fn koru_leak_check() void {
    if (comptime @import("builtin").mode != .Debug) return;
    if (__koru_leak_count.load(.acquire) == 0) return;
    if (comptime @import("builtin").target.os.tag == .freestanding) {
        if (comptime @import("builtin").cpu.arch == .wasm32 or @import("builtin").cpu.arch == .wasm64) {
            @panic("KORU LEAK CHECK FAILED: the produced program leaked");
        } else {
            const __klc = struct { extern var stdout: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; };
            var __lb: [128]u8 = undefined;
            const __lm = "KORU LEAK CHECK FAILED: allocations still outstanding at end of run: ";
            @memcpy(__lb[0..__lm.len], __lm);
            var __ln: usize = __lm.len;
            var __lv = __koru_leak_count.load(.acquire);
            var __ld: [20]u8 = undefined;
            var __lk: usize = 0;
            while (__lv > 0) : (__lk += 1) { __ld[__lk] = @intCast('0' + __lv % 10); __lv /= 10; }
            for (0..__lk) |__li| { __lb[__ln] = __ld[__lk - 1 - __li]; __ln += 1; }
            __lb[__ln] = '\n'; __ln += 1; __lb[__ln] = 0;
            _ = __klc.fputs(@as([*:0]const u8, @ptrCast(&__lb)), __klc.stdout);
            @trap();
        }
    } else {
        @import("std").debug.print("KORU LEAK CHECK FAILED: the produced program leaked (trace above)\n", .{});
        @import("std").process.exit(1);
    }
}

pub const main_module = struct {
    // >>> FLOW: native_smoke.k:17  ~libs.canvas:window.open()
    pub fn flow0() void {
        const result_0 = koru_libs.koru_canvas.window_open_event.handler(.{ .width = 320, .height = 200, .title = "koru native metal" });
        switch (result_0) {
            // >>> BRANCH: native_smoke.k:35  | err e |>
            .err => |e| {
                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki| { const __kn = @min(__kt.len - 1, __b.len - __ki * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("metal init failed: {s}\n", .{e});
            },
            // >>> BRANCH: native_smoke.k:18  | win w |>
            .win => |w| {
                const result_1 = koru_libs.koru_canvas.window_clear_color_event.handler(.{ .win = w, .r = 0.06, .g = 0.08, .b = 0.14 });
                _ = &result_1;
                const result_2: koru_libs.koru_canvas.frames_event.Output = __koru_proc_0: {
                    const win = (w); _ = &win;
                    const count = (240); _ = &count;
                    
    const __cap_s0 = @as(?i32, count) orelse 2147483647;
    koru_libs.koru_canvas.H.drain_paused = true;
    defer koru_libs.koru_canvas.H.drain_paused = false;
    koru_libs.koru_canvas.live_win = win;
    defer koru_libs.koru_canvas.live_win = null;
    var i: i32 = 0;
    while (i < __cap_s0) : (i += 1) {
        if (win.visible and win.surf == null) _ = koru_libs.koru_canvas.surfEnsure(win);
        koru_libs.koru_canvas.pollInput(win);
        while (koru_libs.koru_canvas.popEvent()) |mev| {
            switch (mev) {
                .key_down => |k| { if (k.code == 53) {                     _ = koru_libs.koru_host.quit_event.handler(.{  });
 } },
                .mouse_down => |m| _ = @TypeOf(m),
                .mouse_up => |m| _ = @TypeOf(m),
                .mouse_move => |m| _ = @TypeOf(m),
                .mouse_drag => |m| _ = @TypeOf(m),
                .scroll => |s| _ = @TypeOf(s),
                .remote_button => |r| _ = @TypeOf(r),
            }
        }
        while (koru_libs.koru_canvas.H.popEvent()) |hev| {
            switch (hev) {
                .tray => |td| _ = @TypeOf(td),
                .menu => |md| _ = @TypeOf(md),
                .hotkey => |hk| _ = @TypeOf(hk),
                .remote_button => |rd| _ = @TypeOf(.{ .button = rd.button, .page = rd.page, .down = rd.down }),
            }
        }
        if (koru_libs.koru_canvas.H.should_quit) break;
        if (!win.visible or win.surf == null) {
            {                     _ = koru_libs.koru_host.quit_event.handler(.{  });
 }
            break;
        }
        const s = win.surf.?;
        koru_libs.koru_canvas.refreshGeom(win);
        koru_libs.koru_canvas.clearBacking(win);
        var __f_s0 = koru_libs.koru_canvas.Frame{
            .win = win,
            .px = win.px,
            .w = win.w,
            .h = win.h,
            .clip = undefined,
            .clip_depth = 0,
            .calls = 0,
            .time = koru_libs.koru_canvas.nowSeconds(),
        };
        if (win.radius > 0) {
            __f_s0.clip[0] = .{ 0, 0, @as(f32, @floatFromInt(win.w)), @as(f32, @floatFromInt(win.h)), win.radius };
            __f_s0.clip_depth = 1;
        }
        { const f = &__f_s0; _ = &f;                     const result_e0_0 = koru_libs.koru_canvas.draw_panel_event.handler(.{ .f = f, .x = 16.0, .y = 16.0, .w = 288.0, .h = 96.0, .radius = 10.0, .r = 0.16, .g = 0.18, .b = 0.26, .a = 1.0, .bw = 2.0, .br = 0.35, .bg = 0.45, .bb = 0.75, .ba = 1.0 });
                    _ = &result_e0_0;
                    const result_e0_1 = koru_libs.koru_canvas.draw_text_event.handler(.{ .f = f, .x = 32.0, .y = 36.0, .size = 16.0, .r = 0.9, .g = 0.92, .b = 0.95, .a = 1.0, .text = "KORU NATIVE" });
                    _ = &result_e0_1;
                    const result_e0_2 = koru_libs.koru_canvas.draw_clip_push_event.handler(.{ .f = f, .x = 16.0, .y = 120.0, .w = 288.0, .h = 64.0 });
                    _ = &result_e0_2;
                    const result_e0_3 = koru_libs.koru_canvas.draw_rect_event.handler(.{ .f = f, .x = 24.0, .y = 128.0, .w = 120.0, .h = 48.0, .r = 0.9, .g = 0.4, .b = 0.2, .a = 1.0 });
                    _ = &result_e0_3;
                    const result_e0_4 = koru_libs.koru_canvas.draw_clip_pop_event.handler(.{ .f = f });
                    _ = &result_e0_4;
                    const result_e0_5 = koru_libs.koru_canvas.window_snap_event.handler(.{ .path = "smoke" });
                    _ = &result_e0_5;
                    _ = koru_libs.koru_canvas.release_frame_event.handler(.{ .f = f });
 }
        koru_libs.koru_canvas.frameCommit(win, s);
        koru_libs.koru_canvas.sleepNs(8_000_000); // ~8ms — the macOS pump's cadence
    }
    break :__koru_proc_0 .{ .done = win };
                };
                _ = &result_2;
                const w2 = result_2.done;
                const result_3 = koru_libs.koru_canvas.window_close_event.handler(.{ .win = w2 });
                _ = &result_3;
                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki| { const __kn = @min(__kt.len - 1, __b.len - __ki * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("native metal: frames done, window closed\n", .{});
            },
        }
    }
    pub fn koru_start_flow() void {
        const result_0 = koru_koru.start_event.handler(.{  });
        const result_0_done = result_0.done;
        _ = &result_0_done;
    }
    pub fn koru_end_flow() void {
        const result_0 = koru_koru.end_event.handler(.{  });
        const result_0_done = result_0.done;
        _ = &result_0_done;
    }
};

pub const koru_libs = struct {
    pub const koru_host = struct {
        pub const TrayActionData = struct {
            tray: i64,
            tag: i64,
            action: []const u8,
        };
        pub const MenuActionData = struct {
            tag: i64,
            action: []const u8,
        };
        pub const HotkeyData = struct {
            key: i64,
            mods: i64,
            down: i64,
        };
        pub const RemoteData = struct {
            button: u32,
            page: u32,
            down: u8,
        };
        pub const HostEvent = union(enum) {
            tray: TrayActionData,
            menu: MenuActionData,
            hotkey: HotkeyData,
            remote_button: RemoteData,
        };
        var ev_buf: [64]HostEvent = undefined;
        var ev_actions: [64][64]u8 = undefined;
        var ev_head: usize = 0;
        var ev_tail: usize = 0;
        fn pushEvent(e: HostEvent, action_src: []const u8) void {
            const next = (ev_tail + 1) % ev_buf.len;
            if (next == ev_head) return;
            const n = @min(action_src.len, ev_actions[0].len);
            @memcpy(ev_actions[ev_tail][0..n], action_src[0..n]);
            var ev = e;
            switch (ev) {
                .tray => |*t| t.action = ev_actions[ev_tail][0..n],
                .menu => |*m| m.action = ev_actions[ev_tail][0..n],
                .hotkey, .remote_button => {},
            }
            ev_buf[ev_tail] = ev;
            ev_tail = next;
        }
        pub fn popEvent() ?HostEvent {
            if (ev_head == ev_tail) return null;
            const e = ev_buf[ev_head];
            ev_head = (ev_head + 1) % ev_buf.len;
            return e;
        }
        pub var should_quit: bool = false;
        pub fn ensureApp() void {}
        pub fn activateRegular() void {}
        pub fn pushRemote(d: RemoteData) void {
            pushEvent(.{ .remote_button = d }, "");
        }
        pub var drain_paused: bool = false;
        pub fn serviceRunLoop() void {}
        extern fn koru_tick() callconv(.c) void;
        extern fn ukplat_monotonic_clock() callconv(.c) u64; // ns, TSC-calibrated
        fn sleepNs(ns: u64) void {
            const t0 = ukplat_monotonic_clock();
            while (ukplat_monotonic_clock() - t0 < ns) {}
        }
        fn hostTick() void {
            koru_tick();
        }
        const HostArms = struct {
            tray: *const fn (TrayActionData) void,
            menu: *const fn (MenuActionData) void,
            hotkey: *const fn (HotkeyData) void,
            remote: *const fn (RemoteData) void,
        };
        var host_arms: ?HostArms = null;
        fn hostDrain() void {
            const arms = host_arms orelse return;
            while (popEvent()) |hev| {
                switch (hev) {
                    .tray => |td| arms.tray(td),
                    .menu => |md| arms.menu(md),
                    .hotkey => |hk| arms.hotkey(hk),
                    .remote_button => |rd| arms.remote(rd),
                }
            }
        }
        pub const quit_event = struct {
            pub const Input = struct {
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: quit  [/Users/larsde/src/oshun/host/index.koru-native.kz:187]
                _ = &__koru_event_input;

                    should_quit = true;

            }
        };
    };
    pub const koru_canvas = struct {
        const std = @import("std");
        const H = koru_libs.koru_host;
        extern fn koruos_surface_open(w: u32, h: u32, title: [*:0]const u8) ?*anyopaque;
        extern fn koruos_surface_present(s: *anyopaque, x: u32, y: u32, w: u32, h: u32) u8;
        extern fn koruos_surface_close(s: *anyopaque) u8;
        extern fn koruos_surface_map(p: ?*anyopaque, out_phys: *u64, out_bytes: *u64) u8;
        const Geom = extern struct { x: u32, y: u32, w: u32, h: u32, sw: u32, sh: u32 };
        extern fn koruos_surface_geom(p: ?*anyopaque, out: *Geom) u8;
        extern fn koru_tick() callconv(.c) void;
        extern fn koru_kbd_poll() callconv(.c) i32;
        extern fn koru_pointer_state(x: *i32, y: *i32, on: *u8, buttons: *u32) callconv(.c) void;
        extern fn koru_wire(s: [*]const u8, n: usize) callconv(.c) void;
        extern fn koru_glyph8(ch: u8, row: u8) callconv(.c) u8;
        extern fn ukplat_monotonic_clock() callconv(.c) u64; // ns
        fn sleepNs(ns: u64) void {
            const t0 = ukplat_monotonic_clock();
            while (ukplat_monotonic_clock() - t0 < ns) {}
        }
        fn nowSeconds() f32 {
            return @floatCast(@as(f64, @floatFromInt(ukplat_monotonic_clock())) / 1.0e9);
        }
        fn packColor(r: f64, g: f64, b: f64) u32 {
            const rc: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, r)) * 255.0));
            const gc: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, g)) * 255.0));
            const bc: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, b)) * 255.0));
            return (rc << 16) | (gc << 8) | bc;
        }
        fn blendInto(dst: *u32, sr: u32, sg: u32, sb: u32, sa: u32) void {
            const inv = 255 - sa;
            const d = dst.*;
            const nr = (sr * sa + ((d >> 16) & 0xFF) * inv) / 255;
            const ng = (sg * sa + ((d >> 8) & 0xFF) * inv) / 255;
            const nb = (sb * sa + (d & 0xFF) * inv) / 255;
            dst.* = (nr << 16) | (ng << 8) | nb;
        }
        pub const KeyData = struct {
            code: u16,
            chars: []const u8 = &.{},
        };
        pub const MouseData = struct {
            x: f64,
            y: f64,
        };
        pub const ScrollData = struct {
            x: f64,
            y: f64,
            dx: f64,
            dy: f64,
        };
        pub const RemoteData = struct {
            button: u32,
            page: u32,
            down: u8,
        };
        const Event = union(enum) {
            key_down: KeyData,
            mouse_down: MouseData,
            mouse_up: MouseData,
            mouse_move: MouseData,
            mouse_drag: MouseData,
            scroll: ScrollData,
            remote_button: RemoteData,
        };
        var ev_buf: [64]Event = undefined;
        var ev_chars: [64][16]u8 = undefined;
        var ev_head: usize = 0;
        var ev_tail: usize = 0;
        fn pushKey(kc: u16, chars: []const u8) void {
            const next = (ev_tail + 1) % ev_buf.len;
            if (next == ev_head) return;
            const n = @min(chars.len, ev_chars[0].len);
            @memcpy(ev_chars[ev_tail][0..n], chars[0..n]);
            ev_buf[ev_tail] = .{ .key_down = .{ .code = kc, .chars = ev_chars[ev_tail][0..n] } };
            ev_tail = next;
        }
        fn pushEvent(e: Event) void {
            if (ev_tail != ev_head) {
                const last = if (ev_tail == 0) ev_buf.len - 1 else ev_tail - 1;
                switch (e) {
                    .mouse_move => if (ev_buf[last] == .mouse_move) {
                        ev_buf[last] = e;
                        return;
                    },
                    .mouse_drag => if (ev_buf[last] == .mouse_drag) {
                        ev_buf[last] = e;
                        return;
                    },
                    else => {},
                }
            }
            const next = (ev_tail + 1) % ev_buf.len;
            if (next != ev_head) {
                ev_buf[ev_tail] = e;
                ev_tail = next;
            }
        }
        fn popEvent() ?Event {
            if (ev_head == ev_tail) return null;
            const e = ev_buf[ev_head];
            ev_head = (ev_head + 1) % ev_buf.len;
            return e;
        }
        var in_has_prev: bool = false;
        var in_prev_x: i32 = 0;
        var in_prev_y: i32 = 0;
        var in_prev_btns: u32 = 0;
        fn pollInput(win: *Window) void {
            while (true) {
                const c = koru_kbd_poll();
                if (c < 0) break;
                var ch: [1]u8 = .{@intCast(c)};
                pushKey(0, ch[0..]); // code 0 — native has no keycode map; chars carry it
            }
            var x: i32 = undefined;
            var y: i32 = undefined;
            var on: u8 = undefined;
            var btns: u32 = undefined;
            koru_pointer_state(&x, &y, &on, &btns);
            if (!in_has_prev) {
                in_prev_x = x;
                in_prev_y = y;
                in_prev_btns = btns;
                in_has_prev = true;
                return;
            }
            const lx = x - win.sx;
            const ly = y - win.sy;
            const inside = on != 0 and lx >= 0 and ly >= 0 and
                @as(u32, @intCast(lx)) < win.w and @as(u32, @intCast(ly)) < win.h;
            const moved = x != in_prev_x or y != in_prev_y;
            const was_down = (in_prev_btns & 1) != 0;
            const is_down = (btns & 1) != 0;
            if (inside) {
                const md = MouseData{ .x = @as(f64, @floatFromInt(lx)), .y = @as(f64, @floatFromInt(ly)) };
                if (is_down and !was_down) {
                    pushEvent(.{ .mouse_down = md });
                } else if (!is_down and was_down) {
                    pushEvent(.{ .mouse_up = md });
                } else if (moved) {
                    pushEvent(if (is_down) .{ .mouse_drag = md } else .{ .mouse_move = md });
                }
            }
            in_prev_x = x;
            in_prev_y = y;
            in_prev_btns = btns;
        }
        pub const Window = struct {
            surf: ?*anyopaque = null, // provider token — null while hidden (overlay)
            px: [*]u32 = undefined,   // backing — identity-mapped phys via surface_map
            w: u32 = 0,
            h: u32 = 0,
            sx: i32 = 0, // scene origin — geom, refreshed per frames iteration
            sy: i32 = 0,
            clear: u32 = 0x001A1A26,  // macOS default 0.1/0.1/0.15 -> 0x00RRGGBB
            visible: bool = true,
            overlay: bool = false,
            radius: f32 = 0, // overlay corner radius — base clip when > 0
            slot: u8 = 0,    // index into win_pool — set by winAlloc
        };
        const MAX_WINDOWS = 16;
        var win_pool: [MAX_WINDOWS]Window = undefined;
        var win_used: [MAX_WINDOWS]bool = .{false} ** MAX_WINDOWS;
        fn winAlloc() ?*Window {
            for (0..MAX_WINDOWS) |i| {
                if (!win_used[i]) {
                    win_used[i] = true;
                    win_pool[i] = .{};
                    win_pool[i].slot = @intCast(i);
                    return &win_pool[i];
                }
            }
            return null;
        }
        fn winFree(w: *Window) void {
            win_used[w.slot] = false;
        }
        pub const Frame = struct {
            win: *Window,
            px: [*]u32,
            w: u32,
            h: u32,
            clip: [16][5]f32, // x0,y0,x1,y1,round — same shape as macOS
            clip_depth: u8 = 0,
            calls: usize = 0, // draw-call count
            time: f32 = 0,
        };
        pub const Size = struct {
            w: f64,
            h: f64,
        };
        fn surfEnsure(win: *Window) bool {
            if (win.surf != null) return true;
            if (win.w == 0 or win.h == 0) return false;
            const p = koruos_surface_open(win.w, win.h, "koru-native".ptr) orelse return false;
            var phys: u64 = 0;
            var bytes: u64 = 0;
            if (koruos_surface_map(p, &phys, &bytes) == 0 or bytes < @as(u64, win.w) * win.h * 4) {
                _ = koruos_surface_close(p);
                return false;
            }
            var g: Geom = undefined;
            if (koruos_surface_geom(p, &g) != 0) {
                win.sx = @intCast(g.x);
                win.sy = @intCast(g.y);
            }
            win.surf = p;
            win.px = @ptrFromInt(@as(usize, @intCast(phys)));
            return true;
        }
        fn surfDrop(win: *Window) void {
            if (win.surf) |s| {
                _ = koruos_surface_close(s);
                win.surf = null;
            }
        }
        fn refreshGeom(win: *Window) void {
            const s = win.surf orelse return;
            var g: Geom = undefined;
            if (koruos_surface_geom(s, &g) != 0) {
                win.sx = @intCast(g.x);
                win.sy = @intCast(g.y);
            }
        }
        fn clearBacking(win: *Window) void {
            const n: usize = @as(usize, @intCast(win.w)) * @as(usize, @intCast(win.h));
            var i: usize = 0;
            while (i < n) : (i += 1) win.px[i] = win.clear;
        }
        fn frameCommit(win: *Window, s: *anyopaque) void {
            _ = koruos_surface_present(s, 0, 0, win.w, win.h);
            koru_tick();
        }
        fn sdRoundBox(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) f32 {
            const cx = (x0 + x1) * 0.5;
            const cy = (y0 + y1) * 0.5;
            const hw = @max(0.0, (x1 - x0) * 0.5 - r);
            const hh = @max(0.0, (y1 - y0) * 0.5 - r);
            const qx = @abs(px - cx) - hw;
            const qy = @abs(py - cy) - hh;
            const ax = @max(qx, 0.0);
            const ay = @max(qy, 0.0);
            return @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0.0) - r;
        }
        fn covOf(d: f32) f32 {
            return @max(0.0, @min(1.0, 0.5 - d));
        }
        fn clipDepth(f: *Frame) usize {
            return @as(usize, @intCast(f.clip_depth));
        }
        fn clipCov(f: *Frame, sx: f32, sy: f32) f32 {
            var cc: f32 = 1.0;
            for (f.clip[0..clipDepth(f)]) |*l| {
                cc = @min(cc, covOf(sdRoundBox(sx, sy, l[0], l[1], l[2], l[3], l[4])));
                if (cc <= 0.0) return 0.0;
            }
            return cc;
        }
        fn pxAt(f: *Frame, x: i32, y: i32) *u32 {
            return &f.px[@as(usize, @intCast(y)) * @as(usize, @intCast(f.w)) + @as(usize, @intCast(x))];
        }
        fn pxBlend(f: *Frame, x: i32, y: i32, sx: f32, sy: f32, sr: u32, sg: u32, sb: u32, sa: u32) void {
            const cc = clipCov(f, sx, sy);
            if (cc <= 0.0) return;
            const a = @min(1.0, cc) * (@as(f32, @floatFromInt(sa)) / 255.0);
            const ai: u32 = @intFromFloat(@round(a * 255.0));
            if (ai == 0) return;
            blendInto(pxAt(f, x, y), sr, sg, sb, ai);
        }
        const Col = struct { r: u32, g: u32, b: u32, a: u32 };
        fn colOf(r: f64, g: f64, b: f64, a: f64) Col {
            const c = packColor(r, g, b);
            const av: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, a)) * 255.0));
            return .{ .r = (c >> 16) & 0xFF, .g = (c >> 8) & 0xFF, .b = c & 0xFF, .a = av };
        }
        fn fillShape(f: *Frame, x: f64, y: f64, w: f64, h: f64, radius: f64, col: Col) void {
            if (col.a == 0 or w <= 0 or h <= 0) return;
            const x0: f32 = @floatCast(x);
            const y0: f32 = @floatCast(y);
            const x1: f32 = @floatCast(x + w);
            const y1: f32 = @floatCast(y + h);
            const rad: f32 = @floatCast(radius);
            const ix0 = @max(0, @floor(@min(x, x + w)));
            const iy0 = @max(0, @floor(@min(y, y + h)));
            const ix1 = @min(@as(f64, @floatFromInt(f.w)), @ceil(@max(x, x + w)));
            const iy1 = @min(@as(f64, @floatFromInt(f.h)), @ceil(@max(y, y + h)));
            var py = iy0;
            while (py < iy1) : (py += 1) {
                var px = ix0;
                while (px < ix1) : (px += 1) {
                    const sx = @as(f32, @floatCast(px)) + 0.5;
                    const sy = @as(f32, @floatCast(py)) + 0.5;
                    const sc = covOf(sdRoundBox(sx, sy, x0, y0, x1, y1, rad));
                    if (sc <= 0.0) continue;
                    const a = sc * (@as(f32, @floatFromInt(col.a)) / 255.0);
                    const ai: u32 = @intFromFloat(@round(@min(1.0, a) * 255.0));
                    if (ai == 0) continue;
                    const cc = clipCov(f, sx, sy);
                    if (cc <= 0.0) continue;
                    const fa = @min(1.0, cc) * (@as(f32, @floatFromInt(ai)) / 255.0);
                    const fi: u32 = @intFromFloat(@round(fa * 255.0));
                    if (fi == 0) continue;
                    blendInto(pxAt(f, @intFromFloat(px), @intFromFloat(py)), col.r, col.g, col.b, fi);
                }
            }
            f.calls += 1;
        }
        fn fillPxRect(f: *Frame, x: f64, y: f64, w: f64, h: f64, col: Col) void {
            if (col.a == 0) return;
            const ix0 = @max(0, @floor(@min(x, x + w)));
            const iy0 = @max(0, @floor(@min(y, y + h)));
            const ix1 = @min(@as(f64, @floatFromInt(f.w)), @ceil(@max(x, x + w)));
            const iy1 = @min(@as(f64, @floatFromInt(f.h)), @ceil(@max(y, y + h)));
            var py = iy0;
            while (py < iy1) : (py += 1) {
                var px = ix0;
                while (px < ix1) : (px += 1) {
                    pxBlend(f, @intFromFloat(px), @intFromFloat(py), @as(f32, @floatCast(px)) + 0.5, @as(f32, @floatCast(py)) + 0.5, col.r, col.g, col.b, col.a);
                }
            }
            f.calls += 1;
        }
        fn textScale(size: f64) u32 {
            return @max(@as(u32, 1), @as(u32, @intFromFloat(@round(size / 8.0))));
        }
        fn textAdvance(sc: u32) f64 {
            return @floatFromInt(9 * sc);
        }
        fn drawGlyph(f: *Frame, gx: f64, gy: f64, sc: u32, ch: u8, col: Col) void {
            const x0 = @floor(gx);
            const y0 = @floor(gy);
            var row: u8 = 0;
            while (row < 8) : (row += 1) {
                const bits = koru_glyph8(ch, row);
                var colb: u8 = 0;
                while (colb < 8) : (colb += 1) {
                    if (((bits >> @as(u3, @intCast(colb))) & 1) != 0) {
                        fillPxRect(f, x0 + @as(f64, @floatFromInt(@as(u32, colb) * sc)), y0 + @as(f64, @floatFromInt(@as(u32, row) * sc)), @as(f64, @floatFromInt(sc)), @as(f64, @floatFromInt(sc)), col);
                    }
                }
            }
        }
        fn drawTextRun(f: *Frame, x: f64, y: f64, size: f64, face: i64, r: f64, g: f64, b: f64, a: f64, text: []const u8) void {
            _ = face; // font.load is undeclared natively — face is always the system face
            const col = colOf(r, g, b, a);
            if (col.a == 0 or text.len == 0) return;
            const sc = textScale(size);
            const adv = textAdvance(sc);
            var pen = x;
            for (text) |ch| {
                if (ch >= 0x20 and ch < 0x7F) {
                    drawGlyph(f, pen, y, sc, ch, col);
                }
                pen += adv;
            }
            f.calls += 1;
        }
        var live_win: ?*Window = null;
        pub const window_open_event = struct {
            pub const Input = struct {
                width: i32,
                height: i32,
                title: []const u8,
            };
            pub const Output = union(enum(u8)) {
                win: *koru_libs.koru_canvas.Window,
                err: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: window.open  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:541]
                const width = __koru_event_input.width;
                const height = __koru_event_input.height;
                const title = __koru_event_input.title;
                _ = &width;
                _ = &height;
                _ = &title;
                _ = &__koru_event_input;

                    _ = &title; // the provider takes a label arg but has no WM to show it
                    if (width <= 0 or height <= 0) return .{ .err = "metal: window.open needs positive dims" };
                    const w = winAlloc() orelse return .{ .err = "metal: window pool exhausted" };
                    w.w = @intCast(width);
                    w.h = @intCast(height);
                    w.visible = true;
                    w.overlay = false;
                    if (!surfEnsure(w)) {
                        winFree(w);
                        return .{ .err = "metal: surface open refused (pool/pmm/display)" };
                    }
                    return .{ .win = w };

            }
        };
        pub const window_snap_event = struct {
            pub const Input = struct {
                path: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: window.snap  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:607]
                const path = __koru_event_input.path;
                _ = &path;
                _ = &__koru_event_input;

                    const win = live_win orelse {
                        // No pump running — say so on the wire rather than guess a window.
                        const msg = "KSNAP none\n";
                        koru_wire(msg.ptr, msg.len);
                        return;
                    };
                    var buf: [3072]u8 = undefined;
                    var n: usize = 0;
                    const put = struct {
                        fn s(b: []u8, i: *usize, t: []const u8) void {
                            @memcpy(b[i.*..][0..t.len], t);
                            i.* += t.len;
                        }
                        fn c(b: []u8, i: *usize, ch: u8) void {
                            b[i.*] = ch;
                            i.* += 1;
                        }
                        fn d(b: []u8, i: *usize, v: u64) void {
                            var tmp: [20]u8 = undefined;
                            var k: usize = tmp.len;
                            var x = v;
                            if (x == 0) {
                                c(b, i, '0');
                                return;
                            }
                            while (x > 0) {
                                k -= 1;
                                tmp[k] = @intCast('0' + x % 10);
                                x /= 10;
                            }
                            s(b, i, tmp[k..]);
                        }
                        fn h(b: []u8, i: *usize, v: u32) void {
                            var sh: u5 = 28;
                            while (true) {
                                const nib: u8 = @intCast((v >> sh) & 0xF);
                                c(b, i, if (nib < 10) '0' + nib else 'a' + nib - 10);
                                if (sh == 0) break;
                                sh -= 4;
                            }
                        }
                    };
                    s2: {
                        put.s(&buf, &n, "KSNAP ");
                        var li: usize = 0;
                        while (li < path.len and li < 24 and n < buf.len - 40) : (li += 1) {
                            const ch = path[li];
                            put.c(&buf, &n, if (ch >= 0x20 and ch < 0x7F) ch else '_');
                        }
                        put.c(&buf, &n, ' ');
                        put.d(&buf, &n, win.w);
                        put.c(&buf, &n, 'x');
                        put.d(&buf, &n, win.h);
                        put.c(&buf, &n, '\n');
                        const s = win.surf orelse break :s2;
                        _ = s;
                        const gw: u32 = 8;
                        const gh: u32 = 6;
                        var gy: u32 = 0;
                        while (gy < gh) : (gy += 1) {
                            var gx: u32 = 0;
                            while (gx < gw) : (gx += 1) {
                                const sx = @min(win.w - 1, (gx * win.w) / gw);
                                const sy = @min(win.h - 1, (gy * win.h) / gh);
                                const px = win.px[@as(usize, @intCast(sy)) * @as(usize, @intCast(win.w)) + @as(usize, @intCast(sx))];
                                if (n > buf.len - 40) break :s2;
                                put.s(&buf, &n, "SNAP ");
                                put.d(&buf, &n, sx);
                                put.c(&buf, &n, ',');
                                put.d(&buf, &n, sy);
                                put.c(&buf, &n, ' ');
                                put.h(&buf, &n, px);
                                put.c(&buf, &n, '\n');
                            }
                        }
                    }
                    koru_wire(buf[0..n].ptr, n);

            }
        };
        pub const window_close_event = struct {
            pub const Input = struct {
                win: *koru_libs.koru_canvas.Window,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: window.close  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:689]
                const win = __koru_event_input.win;
                _ = &win;
                _ = &__koru_event_input;

                    surfDrop(win);
                    winFree(win);

            }
        };
        pub const window_clear_color_event = struct {
            pub const Input = struct {
                win: *koru_libs.koru_canvas.Window,
                r: f32,
                g: f32,
                b: f32,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: window.clear.color  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:696]
                const win = __koru_event_input.win;
                const r = __koru_event_input.r;
                const g = __koru_event_input.g;
                const b = __koru_event_input.b;
                _ = &win;
                _ = &r;
                _ = &g;
                _ = &b;
                _ = &__koru_event_input;

                    win.clear = packColor(@floatCast(r), @floatCast(g), @floatCast(b));

            }
        };
        pub const frames_event = struct {
            pub const Input = struct {
                win: *koru_libs.koru_canvas.Window,
                count: ?i32,
            };
            pub const Output = union(enum(u8)) {
                done: *koru_libs.koru_canvas.Window,
            };
            pub fn handler(__koru_event_input: @This().Input, comptime __H: type) @This().Output {
                const frame = __H.frame;
                _ = &frame;
                const key_down = if (@hasDecl(__H, "key_down")) __H.key_down else struct { fn __koru_noop(_: koru_libs.koru_canvas.KeyData) void {} }.__koru_noop;
                _ = &key_down;
                const mouse_down = if (@hasDecl(__H, "mouse_down")) __H.mouse_down else struct { fn __koru_noop(_: koru_libs.koru_canvas.MouseData) void {} }.__koru_noop;
                _ = &mouse_down;
                const mouse_up = if (@hasDecl(__H, "mouse_up")) __H.mouse_up else struct { fn __koru_noop(_: koru_libs.koru_canvas.MouseData) void {} }.__koru_noop;
                _ = &mouse_up;
                const mouse_move = if (@hasDecl(__H, "mouse_move")) __H.mouse_move else struct { fn __koru_noop(_: koru_libs.koru_canvas.MouseData) void {} }.__koru_noop;
                _ = &mouse_move;
                const mouse_drag = if (@hasDecl(__H, "mouse_drag")) __H.mouse_drag else struct { fn __koru_noop(_: koru_libs.koru_canvas.MouseData) void {} }.__koru_noop;
                _ = &mouse_drag;
                const scroll = if (@hasDecl(__H, "scroll")) __H.scroll else struct { fn __koru_noop(_: koru_libs.koru_canvas.ScrollData) void {} }.__koru_noop;
                _ = &scroll;
                const remote_button = if (@hasDecl(__H, "remote_button")) __H.remote_button else struct { fn __koru_noop(_: koru_libs.koru_canvas.RemoteData) void {} }.__koru_noop;
                _ = &remote_button;
                const tray_action = if (@hasDecl(__H, "tray_action")) __H.tray_action else struct { fn __koru_noop(_: koru_libs.koru_host.TrayActionData) void {} }.__koru_noop;
                _ = &tray_action;
                const menu_action = if (@hasDecl(__H, "menu_action")) __H.menu_action else struct { fn __koru_noop(_: koru_libs.koru_host.MenuActionData) void {} }.__koru_noop;
                _ = &menu_action;
                const hotkey = if (@hasDecl(__H, "hotkey")) __H.hotkey else struct { fn __koru_noop(_: koru_libs.koru_host.HotkeyData) void {} }.__koru_noop;
                _ = &hotkey;
                const close = if (@hasDecl(__H, "close")) __H.close else struct { fn __koru_noop() void {} }.__koru_noop;
                _ = &close;
                // >>> PROC: frames  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:730]
                const win = __koru_event_input.win;
                const count = __koru_event_input.count;
                _ = &win;
                _ = &count;
                _ = &__koru_event_input;

                    const __cap = @as(?i32, count) orelse 2147483647;
                    H.drain_paused = true;
                    defer H.drain_paused = false;
                    live_win = win;
                    defer live_win = null;
                    var i: i32 = 0;
                    while (i < __cap) : (i += 1) {
                        if (win.visible and win.surf == null) _ = surfEnsure(win);
                        pollInput(win);
                        while (popEvent()) |mev| {
                            switch (mev) {
                                .key_down => |k| key_down(k),
                                .mouse_down => |m| mouse_down(m),
                                .mouse_up => |m| mouse_up(m),
                                .mouse_move => |m| mouse_move(m),
                                .mouse_drag => |m| mouse_drag(m),
                                .scroll => |s| scroll(s),
                                .remote_button => |r| remote_button(r),
                            }
                        }
                        while (H.popEvent()) |hev| {
                            switch (hev) {
                                .tray => |td| tray_action(td),
                                .menu => |md| menu_action(md),
                                .hotkey => |hk| hotkey(hk),
                                .remote_button => |rd| remote_button(.{ .button = rd.button, .page = rd.page, .down = rd.down }),
                            }
                        }
                        if (H.should_quit) break;
                        if (!win.visible or win.surf == null) {
                            close();
                            break;
                        }
                        const s = win.surf.?;
                        refreshGeom(win);
                        clearBacking(win);
                        var __f = Frame{
                            .win = win,
                            .px = win.px,
                            .w = win.w,
                            .h = win.h,
                            .clip = undefined,
                            .clip_depth = 0,
                            .calls = 0,
                            .time = nowSeconds(),
                        };
                        if (win.radius > 0) {
                            __f.clip[0] = .{ 0, 0, @as(f32, @floatFromInt(win.w)), @as(f32, @floatFromInt(win.h)), win.radius };
                            __f.clip_depth = 1;
                        }
                        frame(&__f);
                        frameCommit(win, s);
                        sleepNs(8_000_000); // ~8ms — the macOS pump's cadence
                    }
                    return .{ .done = win };

            }
        };
        pub const release_frame_event = struct {
            pub const Input = struct {
                f: *koru_libs.koru_canvas.Frame,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: release.frame  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:791]
                const f = __koru_event_input.f;
                _ = &f;
                _ = &__koru_event_input;
                _ = &f;

            }
        };
        pub const draw_rect_event = struct {
            pub const Input = struct {
                f: *koru_libs.koru_canvas.Frame,
                x: f64,
                y: f64,
                w: f64,
                h: f64,
                r: f64,
                g: f64,
                b: f64,
                a: f64,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: draw.rect  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:800]
                const f = __koru_event_input.f;
                const x = __koru_event_input.x;
                const y = __koru_event_input.y;
                const w = __koru_event_input.w;
                const h = __koru_event_input.h;
                const r = __koru_event_input.r;
                const g = __koru_event_input.g;
                const b = __koru_event_input.b;
                const a = __koru_event_input.a;
                _ = &f;
                _ = &x;
                _ = &y;
                _ = &w;
                _ = &h;
                _ = &r;
                _ = &g;
                _ = &b;
                _ = &a;
                _ = &__koru_event_input;

                    fillShape(f, x, y, w, h, 0, colOf(r, g, b, a));

            }
        };
        pub const draw_panel_event = struct {
            pub const Input = struct {
                f: *koru_libs.koru_canvas.Frame,
                x: f64,
                y: f64,
                w: f64,
                h: f64,
                radius: f64,
                r: f64,
                g: f64,
                b: f64,
                a: f64,
                bw: f64,
                br: f64,
                bg: f64,
                bb: f64,
                ba: f64,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: draw.panel  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:812]
                const f = __koru_event_input.f;
                const x = __koru_event_input.x;
                const y = __koru_event_input.y;
                const w = __koru_event_input.w;
                const h = __koru_event_input.h;
                const radius = __koru_event_input.radius;
                const r = __koru_event_input.r;
                const g = __koru_event_input.g;
                const b = __koru_event_input.b;
                const a = __koru_event_input.a;
                const bw = __koru_event_input.bw;
                const br = __koru_event_input.br;
                const bg = __koru_event_input.bg;
                const bb = __koru_event_input.bb;
                const ba = __koru_event_input.ba;
                _ = &f;
                _ = &x;
                _ = &y;
                _ = &w;
                _ = &h;
                _ = &radius;
                _ = &r;
                _ = &g;
                _ = &b;
                _ = &a;
                _ = &bw;
                _ = &br;
                _ = &bg;
                _ = &bb;
                _ = &ba;
                _ = &__koru_event_input;

                    fillShape(f, x, y, w, h, radius, colOf(r, g, b, a));
                    const bc = colOf(br, bg, bb, ba);
                    if (bc.a == 0 or bw <= 0) return;
                    // Border ring: coverage of the outer shape minus the shape inset by
                    // the border width — the same SDF math, one ring deep.
                    const ix = @min(bw, @min(w, h) * 0.5);
                    const inner_r = @max(0.0, radius - ix);
                    const x0: f32 = @floatCast(x + ix);
                    const y0: f32 = @floatCast(y + ix);
                    const x1: f32 = @floatCast(x + w - ix);
                    const y1: f32 = @floatCast(y + h - ix);
                    const orad: f32 = @floatCast(radius);
                    const irad: f32 = @floatCast(inner_r);
                    const bx0 = @max(0, @floor(x));
                    const by0 = @max(0, @floor(y));
                    const bx1 = @min(@as(f64, @floatFromInt(f.w)), @ceil(x + w));
                    const by1 = @min(@as(f64, @floatFromInt(f.h)), @ceil(y + h));
                    var py = by0;
                    while (py < by1) : (py += 1) {
                        var px = bx0;
                        while (px < bx1) : (px += 1) {
                            const sx = @as(f32, @floatCast(px)) + 0.5;
                            const sy = @as(f32, @floatCast(py)) + 0.5;
                            const xo: f32 = @floatCast(x);
                            const yo: f32 = @floatCast(y);
                            const xw: f32 = @floatCast(x + w);
                            const yh: f32 = @floatCast(y + h);
                            const ring = covOf(sdRoundBox(sx, sy, xo, yo, xw, yh, orad)) -
                                covOf(sdRoundBox(sx, sy, x0, y0, x1, y1, irad));
                            if (ring <= 0.0) continue;
                            const ra = @min(1.0, ring) * (@as(f32, @floatFromInt(bc.a)) / 255.0);
                            const ai: u32 = @intFromFloat(@round(ra * 255.0));
                            if (ai == 0) continue;
                            const cc = clipCov(f, sx, sy);
                            if (cc <= 0.0) continue;
                            const fi: u32 = @intFromFloat(@round(@min(1.0, cc) * (@as(f32, @floatFromInt(ai)) / 255.0) * 255.0));
                            if (fi == 0) continue;
                            blendInto(pxAt(f, @intFromFloat(px), @intFromFloat(py)), bc.r, bc.g, bc.b, fi);
                        }
                    }
                    f.calls += 1;

            }
        };
        pub const draw_clip_push_event = struct {
            pub const Input = struct {
                f: *koru_libs.koru_canvas.Frame,
                x: f64,
                y: f64,
                w: f64,
                h: f64,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: draw.clip.push  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:860]
                const f = __koru_event_input.f;
                const x = __koru_event_input.x;
                const y = __koru_event_input.y;
                const w = __koru_event_input.w;
                const h = __koru_event_input.h;
                _ = &f;
                _ = &x;
                _ = &y;
                _ = &w;
                _ = &h;
                _ = &__koru_event_input;

                    if (clipDepth(f) >= f.clip.len) return;
                    var x0: f32 = @floatCast(x);
                    var y0: f32 = @floatCast(y);
                    var x1: f32 = x0 + @as(f32, @floatCast(w));
                    var y1: f32 = y0 + @as(f32, @floatCast(h));
                    if (f.clip_depth > 0) {
                        const parent = f.clip[f.clip_depth - 1];
                        x0 = @max(x0, parent[0]);
                        y0 = @max(y0, parent[1]);
                        x1 = @min(x1, parent[2]);
                        y1 = @min(y1, parent[3]);
                    }
                    f.clip[f.clip_depth] = .{ x0, y0, x1, y1, 0.0 };
                    f.clip_depth += 1;

            }
        };
        pub const draw_clip_pop_event = struct {
            pub const Input = struct {
                f: *koru_libs.koru_canvas.Frame,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: draw.clip.pop  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:898]
                const f = __koru_event_input.f;
                _ = &f;
                _ = &__koru_event_input;

                    if (f.clip_depth > 0) f.clip_depth -= 1;

            }
        };
        pub const draw_text_event = struct {
            pub const Input = struct {
                f: *koru_libs.koru_canvas.Frame,
                x: f64,
                y: f64,
                size: f64,
                r: f64,
                g: f64,
                b: f64,
                a: f64,
                text: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: draw.text  [/Users/larsde/src/oshun/canvas/index.koru-native.kz:906]
                const f = __koru_event_input.f;
                const x = __koru_event_input.x;
                const y = __koru_event_input.y;
                const size = __koru_event_input.size;
                const r = __koru_event_input.r;
                const g = __koru_event_input.g;
                const b = __koru_event_input.b;
                const a = __koru_event_input.a;
                const text = __koru_event_input.text;
                _ = &f;
                _ = &x;
                _ = &y;
                _ = &size;
                _ = &r;
                _ = &g;
                _ = &b;
                _ = &a;
                _ = &text;
                _ = &__koru_event_input;

                    drawTextRun(f, x, y, size, 0, r, g, b, a, text);

            }
        };
    };
};
pub const koru_koru = struct {
    pub const start_event = struct {
        pub const Input = struct {
        };
        pub const Output = union(enum(u8)) {
            done: struct {
            },
        };
        pub fn handler(__koru_event_input: @This().Input) @This().Output {
            _ = &__koru_event_input;
            return .{ .done = .{} };
        }
    };
    pub const end_event = struct {
        pub const Input = struct {
        };
        pub const Output = union(enum(u8)) {
            done: struct {
            },
        };
        pub fn handler(__koru_event_input: @This().Input) @This().Output {
            _ = &__koru_event_input;
            return .{ .done = .{} };
        }
    };
};
pub fn main() void {
    main_module.koru_start_flow();
    main_module.flow0();
    main_module.koru_end_flow();
    if (comptime @import("builtin").mode == .Debug) koru_leak_check();
}

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
