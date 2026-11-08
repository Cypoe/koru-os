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
    // >>> FLOW: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:13  ~koruos.fb:info()
    pub fn flow0() void {
        const result_0 = koru_koruos.koru_fb.info_event.handler(.{  });
        switch (result_0) {
            // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:14  | ok i |>
            .ok => |i| {
                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki| { const __kn = @min(__kt.len - 1, __b.len - __ki * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("fb: {d}x{d} pitch={d} bpp={d}\n", .{i.width, i.height, i.pitch, i.bpp});
                const result_1 = koru_koruos.koru_fb.fill_event.handler(.{ .x = 0, .y = 0, .w = i.width, .h = i.height / 3, .color = 0x00FF0000 });
                _ = &result_1;
                switch (result_1) {
                    // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:16  | ok |>
                    .ok => {
                        const result_2 = koru_koruos.koru_fb.fill_event.handler(.{ .x = 0, .y = i.height / 3, .w = i.width, .h = i.height / 3, .color = 0x0000FF00 });
                        _ = &result_2;
                        switch (result_2) {
                            // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:17  | ok |>
                            .ok => {
                                const result_3 = koru_koruos.koru_fb.fill_event.handler(.{ .x = 0, .y = 2 * i.height / 3, .w = i.width, .h = i.height - 2 * i.height / 3, .color = 0x000000FF });
                                _ = &result_3;
                                switch (result_3) {
                                    // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:18  | ok |>
                                    .ok => {
                                        const result_4 = koru_koruos.koru_fb.present_event.handler(.{ .x = 0, .y = 0, .w = i.width, .h = i.height });
                                        _ = &result_4;
                                        switch (result_4) {
                                            // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:19  | ok |>
                                            .ok => {
                                                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki_0| { const __kn = @min(__kt.len - 1, __b.len - __ki_0 * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki_0 * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("FB COMPLETE\n", .{});
                                            },
                                            // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:20  | absent m |>
                                            .absent => |m| {
                                                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki_1| { const __kn = @min(__kt.len - 1, __b.len - __ki_1 * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki_1 * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("FAIL present: {s}\n", .{m});
                                            },
                                        }
                                    },
                                    // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:21  | absent m |>
                                    .absent => |m| {
                                        (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki_2| { const __kn = @min(__kt.len - 1, __b.len - __ki_2 * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki_2 * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("FAIL fill3: {s}\n", .{m});
                                    },
                                }
                            },
                            // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:22  | absent m |>
                            .absent => |m| {
                                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki_3| { const __kn = @min(__kt.len - 1, __b.len - __ki_3 * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki_3 * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("FAIL fill2: {s}\n", .{m});
                            },
                        }
                    },
                    // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:23  | absent m |>
                    .absent => |m| {
                        (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki_4| { const __kn = @min(__kt.len - 1, __b.len - __ki_4 * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki_4 * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("FAIL fill1: {s}\n", .{m});
                    },
                }
            },
            // >>> BRANCH: /Users/larsde/src/koru-os-m1/koru/fb/tests/boot_fb.k:24  | absent m |>
            .absent => |m| {
                (struct { fn __kout(__fd: i32, __b: []const u8) void { if (@import("builtin").os.tag == .freestanding) { const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; var __kt: [4096]u8 = undefined; for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki| { const __kn = @min(__kt.len - 1, __b.len - __ki * (__kt.len - 1)); @memcpy(__kt[0..__kn], __b[__ki * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; @import("std").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), if (__fd == 2) __kc.stderr else __kc.stdout)); } } else if (@import("builtin").os.tag == .windows) { const __wh = @import("std").os.windows.GetStdHandle(if (__fd == 2) @import("std").os.windows.STD_ERROR_HANDLE else @import("std").os.windows.STD_OUTPUT_HANDLE) catch return; @import("std").mem.doNotOptimizeAway(@import("std").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); } else { @import("std").mem.doNotOptimizeAway(@import("std").posix.write(__fd, __b) catch @as(usize, 0)); } } fn __kw(comptime __f: []const u8, __a: anytype) void { var __kb: [65536]u8 = undefined; const __ks = @import("std").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); } }).__kw("fb absent: {s}\n", .{m});
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

pub const koru_koruos = struct {
    pub const koru_fb = struct {
        const Info = extern struct { width: u32, height: u32, pitch: u32, bpp: u32 };
        extern fn koruos_fb_info(out: *Info) u8;
        extern fn koruos_fb_px(x: u32, y: u32, color: u32) u8;
        extern fn koruos_fb_fill(x: u32, y: u32, w: u32, h: u32, color: u32) u8;
        extern fn koruos_fb_present(x: u32, y: u32, w: u32, h: u32) u8;
        pub const info_event = struct {
            pub const Input = struct {
            };
            pub const Output = union(enum(u8)) {
                ok: struct {
                    width: u32,
                    height: u32,
                    pitch: u32,
                    bpp: u32,
                },
                absent: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: info  [/Users/larsde/src/koru-os-m1/koru/fb/index.kz:38]
                _ = &__koru_event_input;

                    var i = Info{ .width = 0, .height = 0, .pitch = 0, .bpp = 0 };
                    if (koruos_fb_info(&i) == 0) return .{ .absent = "no framebuffer (no mb2 tag 8, or not bpp-32 direct color)" };
                    return .{ .ok = .{ .width = i.width, .height = i.height, .pitch = i.pitch, .bpp = i.bpp } };

            }
        };
        pub const fill_event = struct {
            pub const Input = struct {
                x: u32,
                y: u32,
                w: u32,
                h: u32,
                color: u32,
            };
            pub const Output = union(enum(u8)) {
                ok: struct {
                },
                absent: []const u8,
            };
            pub inline fn handler(__koru_event_input: @This().Input) @This().Output {
                return __koru_handler_impl(__koru_event_input.x, __koru_event_input.y, __koru_event_input.w, __koru_event_input.h, __koru_event_input.color);
            }
            fn __koru_handler_impl(__koru_p_0: u32, __koru_p_1: u32, __koru_p_2: u32, __koru_p_3: u32, __koru_p_4: u32) @This().Output {
                const __koru_event_input: @This().Input = .{ .x = __koru_p_0, .y = __koru_p_1, .w = __koru_p_2, .h = __koru_p_3, .color = __koru_p_4 };
                // >>> PROC: fill  [/Users/larsde/src/koru-os-m1/koru/fb/index.kz:48]
                const x = __koru_event_input.x;
                const y = __koru_event_input.y;
                const w = __koru_event_input.w;
                const h = __koru_event_input.h;
                const color = __koru_event_input.color;
                _ = &x;
                _ = &y;
                _ = &w;
                _ = &h;
                _ = &color;
                _ = &__koru_event_input;

                    if (koruos_fb_fill(x, y, w, h, color) == 0) return .{ .absent = "no framebuffer" };
                    return .{ .ok = .{} };

            }
        };
        pub const present_event = struct {
            pub const Input = struct {
                x: u32,
                y: u32,
                w: u32,
                h: u32,
            };
            pub const Output = union(enum(u8)) {
                ok: struct {
                },
                absent: []const u8,
            };
            pub inline fn handler(__koru_event_input: @This().Input) @This().Output {
                return __koru_handler_impl(__koru_event_input.x, __koru_event_input.y, __koru_event_input.w, __koru_event_input.h);
            }
            fn __koru_handler_impl(__koru_p_0: u32, __koru_p_1: u32, __koru_p_2: u32, __koru_p_3: u32) @This().Output {
                const __koru_event_input: @This().Input = .{ .x = __koru_p_0, .y = __koru_p_1, .w = __koru_p_2, .h = __koru_p_3 };
                // >>> PROC: present  [/Users/larsde/src/koru-os-m1/koru/fb/index.kz:69]
                const x = __koru_event_input.x;
                const y = __koru_event_input.y;
                const w = __koru_event_input.w;
                const h = __koru_event_input.h;
                _ = &x;
                _ = &y;
                _ = &w;
                _ = &h;
                _ = &__koru_event_input;

                    if (koruos_fb_present(x, y, w, h) == 0) return .{ .absent = "no framebuffer" };
                    return .{ .ok = .{} };

            }
        };
    };
};
pub const koru_std = struct {
    pub const koru_spec = struct {
        const std = @import("std");
        const ast = @import("ast");
        pub const FieldValue = union(enum) {
            string_val: []const u8,
            int_val: i64,
            float_val: f64,
            bool_val: bool,
            string_array: []const []const u8,
        };
        pub const NamedField = struct {
            name: []const u8,
            value: FieldValue,
        };
        pub const DispatchResult = struct {
            branch: []const u8,
            fields: []const NamedField, // Direct typed field values
        };
        pub const DispatchFn = *const fn (*const ast.Invocation, *DispatchResult) anyerror!void;
        pub const CostFn = *const fn ([]const u8) u64;
        pub const ObligationsArrayFn = *const fn ([]const u8) []const []const u8; // tor -> []obligations
        pub const DischargeEventFn = *const fn ([]const u8) ?[]const u8; // obligation -> tor name
        pub const CreateSpec = struct {
            obligation_module: []const u8, // e.g., "sqlite3"
            obligation_name: []const u8, // e.g., "opened"
            field_name: []const u8, // which output field holds the handle ID
            resource_type: []const u8, // e.g., "Connection"
            branch: ?[]const u8 = null,
        };
        pub const DischargeSpec = struct {
            obligation_module: []const u8, // e.g., "sqlite3"
            obligation_name: []const u8, // e.g., "opened"
            arg_name: []const u8, // which input arg carries the handle ID
        };
        pub const CreatesSpecFn = *const fn ([]const u8) []const CreateSpec; // tor -> []CreateSpec
        pub const DischargesSpecFn = *const fn ([]const u8) []const DischargeSpec; // tor -> []DischargeSpec
        pub const BranchField = struct {
            name: []const u8,
            type_name: []const u8,
            is_optional: bool = false,
        };
        pub const BranchSpec = struct {
            name: []const u8,
            fields: []const BranchField,
            is_optional: bool = false,
        };
        pub const InputFieldSpec = struct {
            name: []const u8,
            type_name: []const u8,
            is_optional: bool = false,
            phantom: ?[]const u8 = null,
        };
        pub const ScopeEvent = struct {
            name: []const u8,
            cost: u64, // Budget cost for this tor
            creates_obligations: []const []const u8, // Legacy: just obligation names
            discharges_obligations: []const []const u8, // Legacy: just obligation names
            creates_specs: []const CreateSpec, // Full specs with field names
            discharges_specs: []const DischargeSpec, // Full specs with arg names
            branches: []const BranchSpec = &.{}, // Branch specs for shape validation
            input_fields: []const InputFieldSpec = &.{}, // Input/argument vocabulary
            doc: []const u8 = "", // Declaration prose — what the verb IS, rendered beside its signature
            dispatcher: DispatchFn,
        };
        pub const ScopeDescriptor = struct {
            name: []const u8,
            events: []const ScopeEvent,
        };
        pub const BranchesLookupFn = *const fn ([]const u8) []const BranchSpec;
        pub const EventsLookupFn = *const fn () []const []const u8;
        pub const InputLookupFn = *const fn ([]const u8) ?[]const InputFieldSpec;
        pub const DocLookupFn = *const fn ([]const u8) []const u8;
        pub const Site = struct {
            prov: []const u8, // declaring site: module logical name, or the file for program-level sites
            source: []const u8, // the raw `source` block text — the consumer owns the payload's grammar
            flow: *const ast.Flow, // the site itself — consumers read named args (e.g. `iface: <expr>`) off it
            file: []const u8,
            line: usize,
        };
        pub fn siteArg(fl: *const ast.Flow, comptime name: []const u8) ?[]const u8 {
            for (fl.inv().args) |arg| {
                if (std.mem.eql(u8, arg.name, name)) return arg.value;
            }
            return null;
        }
        fn siteMatch(fl: *const ast.Flow, qualifier: []const u8, tor_name: []const u8) ?[]const u8 {
            const mq = fl.inv().path.module_qualifier orelse return null;
            if (!std.mem.eql(u8, mq, qualifier)) return null;
            if (fl.inv().path.segments.len != 1) return null;
            if (!std.mem.eql(u8, fl.inv().path.segments[0], tor_name)) return null;
            for (fl.inv().args) |arg| {
                if (std.mem.eql(u8, arg.name, "source")) return arg.value;
            }
            return null;
        }
        pub fn sites(
            program: *const ast.Program,
            al: std.mem.Allocator,
            qualifier: []const u8,
            tor_name: []const u8,
        ) []Site {
            var out = std.ArrayListUnmanaged(Site){};
            for (program.items) |item| {
                if (item != .module_decl) continue;
                const prov = item.module_decl.logical_name;
                for (item.module_decl.items) |*mi| {
                    if (mi.* != .flow) continue;
                    const src = siteMatch(&mi.flow, qualifier, tor_name) orelse continue;
                    out.append(al, .{ .prov = prov, .source = src, .flow = &mi.flow, .file = mi.flow.location.file, .line = mi.flow.location.line }) catch return out.items;
                }
            }
            for (program.items) |*item| {
                if (item.* != .flow) continue;
                const src = siteMatch(&item.flow, qualifier, tor_name) orelse continue;
                out.append(al, .{ .prov = item.flow.location.file, .source = src, .flow = &item.flow, .file = item.flow.location.file, .line = item.flow.location.line }) catch return out.items;
            }
            return out.items;
        }
        pub const spec_revision_event = struct {
            pub const Input = struct {
            };
            pub const Output = []const u8;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: spec.revision  [/Users/larsde/src/koru-cypoe/koru_std/spec.kz:31]
                _ = &__koru_event_input;

                    return "std/spec:0";

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
