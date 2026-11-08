// Koru Backend (Pass 2) — thin driver; PROGRAM_AST lives in program_ast.zig
// This file IS the compiler backend - it generates final code at compile-time

const Program = @import("ast").Program;
const ast_json_mod = @import("ast_json");
fn maybeDeinitAst(_: *const Program) void {}

const emitter_helpers = @import("emitter_helpers");
const __koru_std = @import("std");
const log = @import("log");

// Compiler environment lives in the static compiler_env module — re-exported here so
// `@import("root").CompilerEnv` keeps working for existing consumers.
pub const CompilerEnv = @import("compiler_env").CompilerEnv;

// Metacircular Code Generator

const __koru_ast = @import("ast");
comptime { _ = @import("backend_output"); }

const KoruCoordinateResult = extern struct {
    is_error: bool,
    code_ptr: [*]const u8,
    code_len: usize,
    metrics_ptr: [*]const u8,
    metrics_len: usize,
    error_ptr: [*]const u8,
    error_len: usize,
};
extern fn koru_coordinate(
    program_ast: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
) KoruCoordinateResult;

extern fn koru_command_dispatch(
    name: *const anyopaque, // *const []const u8
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
    argv: *const anyopaque, // *const []const []const u8 (Zig slice; cast on the other side)
) void;

extern fn koru_run_pass(
    annotation: *const anyopaque, // *const []const u8
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
    out_program: *?*const __koru_ast.Program,
    ctx: ?*anyopaque, // *CompilerContext, opaque across the unit boundary
) bool;

// Re-export transform dispatcher — Zig-side shim around the extern wrapper
// so existing callers in src/ see an unchanged calling convention.
pub fn process_all_transforms(
    annotation: []const u8,
    program: *const __koru_ast.Program,
    allocator: __koru_std.mem.Allocator,
    ctx: ?*anyopaque,
) !*const __koru_ast.Program {
    var out_program: ?*const __koru_ast.Program = null;
    const ok = koru_run_pass(@ptrCast(&annotation), program, &allocator, &out_program, ctx);
    if (!ok) return error.TransformFailed;
    return out_program orelse return error.TransformFailed;
}

// Helper: Join path segments with dots
const joinPath = struct {
    fn call(path: []const []const u8) []const u8 {
        if (path.len == 0) return "";
        if (path.len == 1) return path[0];
        var total_len: usize = path[0].len;
        var i: usize = 1;
        while (i < path.len) : (i += 1) {
            total_len += 1 + path[i].len;
        }
        var result: [256]u8 = undefined;
        var pos: usize = 0;
        @memcpy(result[pos..pos + path[0].len], path[0]);
        pos += path[0].len;
        i = 1;
        while (i < path.len) : (i += 1) {
            result[pos] = '.';
            pos += 1;
            @memcpy(result[pos..pos + path[i].len], path[i]);
            pos += path[i].len;
        }
        return result[0..pos];
    }
}.call;

// Runtime emitter - calls the coordinate event from compiler.kz
// The visitor emitter handles abstract/impl resolution automatically
const RuntimeEmitter = struct {
    pub fn emit(allocator: __koru_std.mem.Allocator, source_ast: *const Program) ![]const u8 {
        const result = koru_coordinate(source_ast, &allocator);
        if (result.is_error) {
            const e = result.error_ptr[0..result.error_len];
            // A REFUSAL IS NOT A CRASH. The coordinate flow has already reported its
            // diagnostic through the reporter by the time we reach here, so returning
            // an error out of main would make Zig print `error.CompilerCoordinationFailed`
            // plus a return trace naming THIS generated file — a crash report stapled to
            // a correct rejection, and the last thing the author reads. Exit
            // deliberately instead: the status is still non-zero, so koruc's
            // non-zero-exit path still runs the diagnostics summary and still
            // reports the failure. Nothing is swallowed; one misleading rendering of an
            // already-delivered diagnostic is dropped.
            //
            // The coordination echo itself is gated the same way: when the reporter
            // already rendered a diagnostic (`errors.diagnostics_were_printed`), the
            // error-string summary is a vaguer, location-free repeat of it — one
            // refusal, one message. When NO diagnostic was rendered the print stays:
            // a user-authored coordinator override's error string or a
            // diagnostic-free internal failure IS the message.
            const reporter_spoke = @import("errors").diagnostics_were_printed;
            if (!reporter_spoke) {
                __koru_std.debug.print("❌ Compiler coordination error: {s}\n", .{e});
            }
            // The trace stays REACHABLE on request, because for a genuine INTERNAL
            // failure it is the useful output, and suppressing it unconditionally would
            // trade this bug for its mirror — a compiler crash reported as a rejection,
            // which sends the author hunting through correct code. `is_error` is one
            // boolean carrying both meanings, so the choice belongs to whoever is
            // debugging rather than being guessed at here. A kind on the C-ABI result
            // would let the compiler decide for itself; that is the honest version and
            // it is not this change.
            const trace_requested: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_BACKEND_TRACE") catch null;
            defer if (trace_requested) |v| allocator.free(v);
            if (trace_requested != null) return error.CompilerCoordinationFailed;
            if (!reporter_spoke) {
                __koru_std.debug.print("   (set KORU_BACKEND_TRACE=1 for the backend return trace)\n", .{});
            }
            __koru_std.process.exit(1);
        }
        const metrics = result.metrics_ptr[0..result.metrics_len];
        const code = result.code_ptr[0..result.code_len];
        __koru_std.debug.print("🎯 Compiler coordination: {s}\n", .{metrics});
        return code;
    }
};
// AST Dump Helper - observability for compiler pipeline debugging
// Note: This version doesn't serialize to JSON (ast_serializer not available in backend.zig)
// Full JSON dumps are available in backend_output_emitted.zig (dump points 3-7)
fn dumpAST(program_ast: *const Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
    // Check if AST dumping is enabled via environment variable
    const dump_enabled: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) break :blk null;
        break :blk null;
    };
    defer if (dump_enabled) |val| allocator.free(val);

    if (dump_enabled == null) return;  // Not enabled

    __koru_std.debug.print("\n============================================================\n", .{});
    __koru_std.debug.print("AST DUMP: {s}\n", .{stage});
    __koru_std.debug.print("============================================================\n", .{});
    __koru_std.debug.print("Items: {d}\n", .{program_ast.items.len});
    __koru_std.debug.print("Module: {s}\n", .{program_ast.main_module_name});
    __koru_std.debug.print("============================================================\n\n", .{});
}
var koru_budget_mb: usize = 4096;
var koru_budget_fired: bool = false;

const BudgetAllocator = struct {
    child: __koru_std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: __koru_std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr);
        if (result == null and !koru_budget_fired) {
            koru_budget_fired = true;
            __koru_std.debug.print("error[KORU174]: compilation exceeded its compile memory budget ({d} MB) — the compiler refused; nothing was miscompiled and nothing ran. Raise the budget with --compile-mem-mb=<mb> or KORU_COMPILE_MEM_MB.\n", .{koru_budget_mb});
            __koru_std.process.exit(1);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: __koru_std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: __koru_std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: __koru_std.mem.Alignment, ret_addr: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }

    fn allocator(self: *BudgetAllocator) __koru_std.mem.Allocator {
        return .{ .ptr = self, .vtable = &__koru_std.mem.Allocator.VTable{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
};
// === KORU BACKEND CODE GENERATOR ===
// This outputs the final Zig code generated by compiler.emit.zig

// koru ships an optimized, byte-identical replacement for
// std/json/Stringify.zig (src/zig_std_patch/Stringify.zig).
// Emitted code reaches it through a --zig-lib-dir overlay: a
// directory of symlinks to zig's real lib dir with just that
// one file swapped. Built lazily under .zig-cache and keyed by
// a marker file containing the real lib dir it mirrors.
// Writes the absolute overlay path into `out` and returns the
// used slice, or null to keep stock std — output bytes are
// identical either way; only speed differs. No allocation is
// returned: the backend's debug leak check would count it.
fn __koruEnsureZigLibOverlay(allocator: __koru_std.mem.Allocator, out: []u8) ?[]const u8 {
    const env_res = __koru_std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "env" },
        .max_output_bytes = 64 * 1024,
    }) catch return null;
    defer allocator.free(env_res.stdout);
    defer allocator.free(env_res.stderr);
    const lib_key = ".lib_dir = \"";
    const lib_at = __koru_std.mem.indexOf(u8, env_res.stdout, lib_key) orelse return null;
    const lib_rest = env_res.stdout[lib_at + lib_key.len ..];
    const lib_end = __koru_std.mem.indexOfScalar(u8, lib_rest, '"') orelse return null;
    const real_lib = lib_rest[0..lib_end];

    // The patch is verified byte-identical against 0.15.2's
    // std.json.Stringify only. On any other zig version the
    // overlay could fail to compile — refuse it and keep stock
    // std rather than break every emitted-program build.
    const ver_key = ".version = \"";
    const ver_at = __koru_std.mem.indexOf(u8, env_res.stdout, ver_key) orelse return null;
    const ver_rest = env_res.stdout[ver_at + ver_key.len ..];
    const ver_end = __koru_std.mem.indexOfScalar(u8, ver_rest, '"') orelse return null;
    if (!__koru_std.mem.eql(u8, ver_rest[0..ver_end], "0.15.2")) return null;

    const overlay_rel = ".zig-cache/koru_lib_overlay";
    const overlay_tmp = ".zig-cache/koru_lib_overlay.tmp";
    const marker_rel = ".zig-cache/koru_lib_overlay/.koru_src";

    // A ready overlay built against this same lib dir is reused as-is.
    if (__koruCwd().readFileAlloc(allocator, marker_rel, 4096) catch null) |marker| {
        defer allocator.free(marker);
        if (__koru_std.mem.eql(u8, marker, real_lib))
            return __koruCwd().realpath(overlay_rel, out) catch null;
    }

    const patch_path = __koru_std.fmt.allocPrint(allocator, "{s}/src/zig_std_patch/Stringify.zig", .{CompilerEnv.koru_home}) catch return null;
    defer allocator.free(patch_path);
    const patch_src = __koruCwd().readFileAlloc(allocator, patch_path, 1 << 20) catch return null;
    defer allocator.free(patch_src);

    __koruCwd().deleteTree(overlay_tmp) catch {};
    __koruCwd().makePath(overlay_tmp) catch return null;
    defer __koruCwd().deleteTree(overlay_tmp) catch {};

    // Mirror every top-level lib entry; std/ is expanded one level
    // deeper so std/json can be swapped piecewise below.
    var lib_dir = __koruCwd().openDir(real_lib, .{ .iterate = true }) catch return null;
    defer lib_dir.close();
    var lib_it = lib_dir.iterate();
    while (lib_it.next() catch return null) |ent| {
        if (__koru_std.mem.eql(u8, ent.name, "std")) continue;
        const target = __koru_std.fmt.allocPrint(allocator, "{s}/{s}", .{ real_lib, ent.name }) catch return null;
        defer allocator.free(target);
        const link = __koru_std.fmt.allocPrint(allocator, "{s}/{s}", .{ overlay_tmp, ent.name }) catch return null;
        defer allocator.free(link);
        __koruCwd().symLink(target, link, .{}) catch return null;
    }

    const std_target = __koru_std.fmt.allocPrint(allocator, "{s}/std", .{real_lib}) catch return null;
    defer allocator.free(std_target);
    __koruCwd().makePath(overlay_tmp ++ "/std") catch return null;
    var std_dir = __koruCwd().openDir(std_target, .{ .iterate = true }) catch return null;
    defer std_dir.close();
    var std_it = std_dir.iterate();
    while (std_it.next() catch return null) |ent| {
        if (__koru_std.mem.eql(u8, ent.name, "json")) continue;
        const target = __koru_std.fmt.allocPrint(allocator, "{s}/std/{s}", .{ real_lib, ent.name }) catch return null;
        defer allocator.free(target);
        const link = __koru_std.fmt.allocPrint(allocator, "{s}/std/{s}", .{ overlay_tmp, ent.name }) catch return null;
        defer allocator.free(link);
        __koruCwd().symLink(target, link, .{}) catch return null;
    }

    const json_target = __koru_std.fmt.allocPrint(allocator, "{s}/json", .{std_target}) catch return null;
    defer allocator.free(json_target);
    __koruCwd().makePath(overlay_tmp ++ "/std/json") catch return null;
    var json_dir = __koruCwd().openDir(json_target, .{ .iterate = true }) catch return null;
    defer json_dir.close();
    var json_it = json_dir.iterate();
    while (json_it.next() catch return null) |ent| {
        if (__koru_std.mem.eql(u8, ent.name, "Stringify.zig")) continue;
        const target = __koru_std.fmt.allocPrint(allocator, "{s}/{s}", .{ json_target, ent.name }) catch return null;
        defer allocator.free(target);
        const link = __koru_std.fmt.allocPrint(allocator, "{s}/std/json/{s}", .{ overlay_tmp, ent.name }) catch return null;
        defer allocator.free(link);
        __koruCwd().symLink(target, link, .{}) catch return null;
    }

    __koruCwd().writeFile(.{ .sub_path = overlay_tmp ++ "/std/json/Stringify.zig", .data = patch_src }) catch return null;
    __koruCwd().writeFile(.{ .sub_path = overlay_tmp ++ "/.koru_src", .data = real_lib }) catch return null;

    // Publish atomically-ish: build under .tmp, then swap in. A
    // stale overlay is deleted first (rename onto a non-empty
    // dir fails on some platforms).
    __koruCwd().deleteTree(overlay_rel) catch {};
    __koruCwd().rename(overlay_tmp, overlay_rel) catch return null;
    return __koruCwd().realpath(overlay_rel, out) catch null;
}

fn __koruCwd() __koru_std.fs.Dir {
    return __koru_std.fs.cwd();
}
pub fn main() !void {
    // Compiler environment: per-invocation flags/lang/paths from
    // `compiler_env.json` (written beside this backend by the frontend).
    // Same channel as program.ast.json — nothing per-invocation is baked
    // into this binary, so one backend serves every flag combination.
    // Must load before ANY CompilerEnv read below (budget block first).
    CompilerEnv.load() catch |err| {
        __koru_std.debug.print("❌ Backend: cannot load compiler_env.json: {s}\n", .{@errorName(err)});
        return err;
    };
    // Budget: --compile-mem-mb=<mb> flag wins, then KORU_COMPILE_MEM_MB,
    // else 4096 MB. The flag is read per-invocation from CompilerEnv.flags,
    // so a regression test can pin a tiny budget without touching env.
    koru_budget_mb = blk: {
        // koruc bakes flags WITHOUT the leading dashes (`compile-mem-mb=8`);
        // match both spellings so a hand-run backend sees the same budget.
        const flag_pfx = "compile-mem-mb=";
        for (CompilerEnv.flags) |f| {
            const bare = if (__koru_std.mem.startsWith(u8, f, "--"))
                f[2..]
            else
                f;
            if (__koru_std.mem.startsWith(u8, bare, flag_pfx)) {
                if (__koru_std.fmt.parseInt(usize, bare[flag_pfx.len..], 10)) |v| {
                    if (v >= 1) break :blk v;
                } else |_| {}
            }
        }
        if (__koru_std.process.getEnvVarOwned(__koru_std.heap.page_allocator, "KORU_COMPILE_MEM_MB")) |v| {
            defer __koru_std.heap.page_allocator.free(v);
            if (__koru_std.fmt.parseInt(usize, v, 10)) |parsed| {
                if (parsed >= 1) break :blk parsed;
            } else |_| {}
        } else |_| {}
        break :blk 4096;
    };
    var gpa = __koru_std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){};
    // The ceiling itself is a plain field (settable post-construction),
    // not a Config field — Config carries only the enable flag.
    gpa.requested_memory_limit = koru_budget_mb * 1024 * 1024;
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            __koru_std.debug.print("Memory leak detected\n", .{});
        }
    }
    var budget = BudgetAllocator{ .child = gpa.allocator() };
    const allocator = budget.allocator();

    // Arena allocator for compilation phase - all compiler passes, code generation, etc.
    var compile_arena = __koru_std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();
    const compile_allocator = compile_arena.allocator();

    // Get the output filename from argv (passed from koruc)
    const args = try __koru_std.process.argsAlloc(allocator);
    defer __koru_std.process.argsFree(allocator, args);

    // Default output names.
    // JS-target spike: --lang=js writes output_emitted.js instead of .zig.
    // CompilerEnv.lang is read per-invocation from compiler_env.json and
    // re-exported as `pub const CompilerEnv` at the top of this backend.
    const emitted_file = if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js"))
        "output_emitted.js"
    else if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs"))
        "output_emitted.cs"
    else if (__koru_std.mem.eql(u8, CompilerEnv.lang, "c"))
        "output_emitted.c"
    else
        "output_emitted.zig";
    const seed_ast: *Program = blk: {
        const ast_file = __koru_std.fs.cwd().openFile("program.ast.json", .{}) catch |err| {
            __koru_std.debug.print("❌ Backend: cannot open program.ast.json: {s}\n", .{@errorName(err)});
            return err;
        };
        defer ast_file.close();
        const ast_json_bytes = try ast_file.readToEndAlloc(compile_allocator, 256 * 1024 * 1024);
        const p = try compile_allocator.create(Program);
        p.* = try ast_json_mod.deserialize(compile_allocator, ast_json_bytes);
        break :blk p;
    };
    // Check for CLI commands in argv
    // Note: backend_output is already imported at file scope
    if (args.len > 1) {
        if (__koru_std.mem.eql(u8, args[1], "deps")) {
            __koru_std.debug.print("🔧 Running command: deps\n", .{});
            const cmd_name: []const u8 = "deps";
            const argv_slice: []const []const u8 = args[2..];
            koru_command_dispatch(@ptrCast(&cmd_name), seed_ast, &allocator, @ptrCast(&argv_slice));
            // Command marks channel: handlers commit verdicts through
            // emitter_helpers.commitCommandMark; the flush names the
            // artifact <entry-stem>.marks. Per-invocation identity
            // rides CompilerEnv (loaded from compiler_env.json), so
            // backend.zig stays byte-identical across programs.
            const __marks_stem = __koru_std.fs.path.stem(CompilerEnv.entry_file);
            emitter_helpers.flushCommandMarks(allocator, __marks_stem) catch |fmerr| {
                __koru_std.debug.print("❌ command marks flush failed: {s}\n", .{@errorName(fmerr)});
                return fmerr;
            };
            if (emitter_helpers.command_exit_code) |cx| __koru_std.process.exit(cx);
            return;
        }
        if (__koru_std.mem.eql(u8, args[1], "claims")) {
            __koru_std.debug.print("🔧 Running command: claims\n", .{});
            const cmd_name: []const u8 = "claims";
            const argv_slice: []const []const u8 = args[2..];
            koru_command_dispatch(@ptrCast(&cmd_name), seed_ast, &allocator, @ptrCast(&argv_slice));
            // Command marks channel: handlers commit verdicts through
            // emitter_helpers.commitCommandMark; the flush names the
            // artifact <entry-stem>.marks. Per-invocation identity
            // rides CompilerEnv (loaded from compiler_env.json), so
            // backend.zig stays byte-identical across programs.
            const __marks_stem = __koru_std.fs.path.stem(CompilerEnv.entry_file);
            emitter_helpers.flushCommandMarks(allocator, __marks_stem) catch |fmerr| {
                __koru_std.debug.print("❌ command marks flush failed: {s}\n", .{@errorName(fmerr)});
                return fmerr;
            };
            if (emitter_helpers.command_exit_code) |cx| __koru_std.process.exit(cx);
            return;
        }
        if (__koru_std.mem.eql(u8, args[1], "assumes")) {
            __koru_std.debug.print("🔧 Running command: assumes\n", .{});
            const cmd_name: []const u8 = "assumes";
            const argv_slice: []const []const u8 = args[2..];
            koru_command_dispatch(@ptrCast(&cmd_name), seed_ast, &allocator, @ptrCast(&argv_slice));
            // Command marks channel: handlers commit verdicts through
            // emitter_helpers.commitCommandMark; the flush names the
            // artifact <entry-stem>.marks. Per-invocation identity
            // rides CompilerEnv (loaded from compiler_env.json), so
            // backend.zig stays byte-identical across programs.
            const __marks_stem = __koru_std.fs.path.stem(CompilerEnv.entry_file);
            emitter_helpers.flushCommandMarks(allocator, __marks_stem) catch |fmerr| {
                __koru_std.debug.print("❌ command marks flush failed: {s}\n", .{@errorName(fmerr)});
                return fmerr;
            };
            if (emitter_helpers.command_exit_code) |cx| __koru_std.process.exit(cx);
            return;
        }
        if (__koru_std.mem.eql(u8, args[1], "realize")) {
            __koru_std.debug.print("🔧 Running command: realize\n", .{});
            const cmd_name: []const u8 = "realize";
            const argv_slice: []const []const u8 = args[2..];
            koru_command_dispatch(@ptrCast(&cmd_name), seed_ast, &allocator, @ptrCast(&argv_slice));
            // Command marks channel: handlers commit verdicts through
            // emitter_helpers.commitCommandMark; the flush names the
            // artifact <entry-stem>.marks. Per-invocation identity
            // rides CompilerEnv (loaded from compiler_env.json), so
            // backend.zig stays byte-identical across programs.
            const __marks_stem = __koru_std.fs.path.stem(CompilerEnv.entry_file);
            emitter_helpers.flushCommandMarks(allocator, __marks_stem) catch |fmerr| {
                __koru_std.debug.print("❌ command marks flush failed: {s}\n", .{@errorName(fmerr)});
                return fmerr;
            };
            if (emitter_helpers.command_exit_code) |cx| __koru_std.process.exit(cx);
            return;
        }
    }
    // NOTE: args[1] is the output exe name when called from frontend,
    // but when running backend directly, args[1] might be the input Koru source file.
    // Detect this case and default to "a.out" instead of overwriting the source!
    const output_exe = if (args.len > 1 and
        !__koru_std.mem.endsWith(u8, args[1], ".kgpu") and
        !__koru_std.mem.endsWith(u8, args[1], ".kjs") and
        !__koru_std.mem.endsWith(u8, args[1], ".kz") and
        !__koru_std.mem.endsWith(u8, args[1], ".kc") and
        !__koru_std.mem.endsWith(u8, args[1], ".k")) args[1] else "a.out";

    // Apply compiler passes
    // Each pass takes PROGRAM_AST pointer and current AST pointer
    // Returns same pointer if no changes, or new heap-allocated AST if optimized
    const current_ast: *const Program = seed_ast;

    // DUMP POINT 1: Original AST at backend entry
    dumpAST(seed_ast, "1-backend-start", compile_allocator);

    // More passes can go here...

    const final_ast = current_ast;
    defer maybeDeinitAst(final_ast);

    // DUMP POINT 2: Final AST before emission (after all backend transforms)
    dumpAST(final_ast, "2-pre-emit", compile_allocator);

    // Generate code from AST (possibly fused)
    const generated_code = try RuntimeEmitter.emit(compile_allocator, final_ast);

    // DEBUG: Check generated_code before file write
    log.debug("\n[MAIN DEBUG] Before file write:\n", .{});
    log.debug("[MAIN DEBUG]   generated_code.len = {d}\n", .{generated_code.len});
    log.debug("[MAIN DEBUG]   generated_code.ptr = {*}\n", .{generated_code.ptr});
    log.debug("[MAIN DEBUG]   emitted_file = {s}\n", .{emitted_file});
    log.debug("[MAIN DEBUG]   emitted_file.ptr = {*}\n", .{emitted_file.ptr});
    log.debug("[MAIN DEBUG]   First 50 bytes: ", .{});
    for (generated_code[0..@min(50, generated_code.len)]) |byte| {
        if (byte >= 32 and byte < 127) {
            log.debug("{c}", .{byte});
        } else {
            log.debug("[{d}]", .{byte});
        }
    }
    log.debug("\n\n", .{});

    // Write the generated code to a file
    const file = try __koru_std.fs.cwd().createFile(emitted_file, .{});
    defer file.close();
    try file.writeAll(generated_code);

    // Report what we generated
    const stdout = __koru_std.fs.File.stdout();
    var buf: [512]u8 = undefined;
    const msg = try __koru_std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, generated_code.len});
    try stdout.writeAll(msg);

    // JS-target spike: the JS path stops here. node runs output_emitted.js
    // directly — there is no Stage D (`zig build` of the emitted output) and
    // no a.out. Gated on CompilerEnv.lang so the Zig path below is untouched.
    // Same for the C lane: ccomp is the Stage-D oracle, invoked by the
    // regression check — koruc's job ends at output_emitted.c.
    if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js") or
        __koru_std.mem.eql(u8, CompilerEnv.lang, "c")) return;

    // --deep-check: the koruc-level verdict is almost final — every
    // pass ran, emission succeeded, output_emitted.zig is on disk.
    // Stage D is native codegen, not a verdict input; a fuzzer
    // scoring on -c cannot see the refusals that live above this
    // line (check-flow runs post-transform, backend-only).
    //
    // What a bare return here skips is the last witness: that the
    // emission is a parseable program, not text. Fuzz splices land
    // Koru-shaped lines inside `proc|zig` bodies and record fields,
    // and both paste verbatim into the Zig — a green verdict on
    // emission `zig ast-check` refuses (challenge-031 gp_2_pass).
    // "Emitted" is not the verdict; "emitted valid" is. The full
    // stage-D build stays skipped; only the parse is witnessed.
    if (CompilerEnv.hasFlag("deep-check")) {
        const emitted_z = try compile_allocator.dupeZ(u8, generated_code);
        const emit_tree = __koru_std.zig.Ast.parse(compile_allocator, emitted_z, .zig) catch |perr| {
            __koru_std.debug.print("error[KORU207]: emission validation itself failed ({s}) — output_emitted.zig could not be parsed\n", .{@errorName(perr)});
            __koru_std.process.exit(1);
        };
        if (emit_tree.errors.len != 0) {
            var aw: __koru_std.Io.Writer.Allocating = .init(compile_allocator);
            for (emit_tree.errors) |perr| {
                if (perr.is_note) continue;
                const loc = emit_tree.tokenLocation(0, perr.token);
                emit_tree.renderError(perr, &aw.writer) catch {};
                __koru_std.debug.print("error[KORU207]: {s}:{d}:{d}: emitted Zig does not parse — {s}\n", .{ emitted_file, loc.line + 1, loc.column + 1, aw.written() });
                aw.clearRetainingCapacity();
            }
            __koru_std.process.exit(1);
        }
        return;
    }

    // K# vertical: the cs path's Stage D is the .NET SDK. dotnet 9 has
    // no file-based `dotnet run x.cs`, so a minimal csproj IS the
    // driver — the same role build_output.zig plays on the Zig path.
    // The SDK names the apphost after AssemblyName — a bare NAME, no
    // separators — so output_exe splits into dir/basename: the
    // apphost lands at exactly the path koruc was asked for.
    if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs")) {
        const cs_out_dir = __koru_std.fs.path.dirname(output_exe) orelse ".";
        const cs_assembly = __koru_std.fs.path.basename(output_exe);
        const csproj_text = __koru_std.fmt.allocPrint(allocator,
            "<Project Sdk=\"Microsoft.NET.Sdk\">\n" ++
            "  <PropertyGroup>\n" ++
            "    <OutputType>Exe</OutputType>\n" ++
            "    <TargetFramework>net8.0</TargetFramework>\n" ++
            "    <ImplicitUsings>disable</ImplicitUsings>\n" ++
            "    <Nullable>disable</Nullable>\n" ++
            "    <AssemblyName>{s}</AssemblyName>\n" ++
            "    <WarningLevel>0</WarningLevel>\n" ++
            "    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n" ++
            "  </PropertyGroup>\n" ++
            "  <ItemGroup>\n" ++
            "    <Compile Include=\"output_emitted.cs\" />\n" ++
            "  </ItemGroup>\n" ++
            "</Project>\n", .{cs_assembly}) catch |err| {
            __koru_std.debug.print("✗ csproj generation failed: {}\n", .{err});
            __koru_std.process.exit(1);
        };
        defer allocator.free(csproj_text);
        const csproj_file = try __koru_std.fs.cwd().createFile("koru.csproj", .{});
        try csproj_file.writeAll(csproj_text);
        // Close BEFORE spawning dotnet: on Windows a file held
        // open by this process refuses the child's open
        // (MSB4025, "being used by another process"); POSIX
        // tolerated the shared handle.
        csproj_file.close();

        const cs_result = __koru_std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "dotnet", "build", "koru.csproj", "-o", cs_out_dir, "--nologo", "-v:q" },
            .max_output_bytes = 10 * 1024 * 1024,
        }) catch |err| {
            const msg3 = try __koru_std.fmt.bufPrint(&buf, "✗ dotnet build failed to launch: {} — is the .NET SDK on PATH?\n", .{err});
            try __koru_std.fs.File.stderr().writeAll(msg3);
            __koru_std.process.exit(1);
        };
        defer allocator.free(cs_result.stdout);
        defer allocator.free(cs_result.stderr);
        switch (cs_result.term) {
            .Exited => |exit_code| if (exit_code == 0) {
                const msg3 = try __koru_std.fmt.bufPrint(&buf, "✓ Compiled to {s} (dotnet build)\n", .{output_exe});
                try stdout.writeAll(msg3);
            } else {
                try stdout.writeAll("✗ dotnet build failed\n");
                if (cs_result.stderr.len > 0) {
                    try __koru_std.fs.File.stderr().writeAll(cs_result.stderr);
                }
                if (cs_result.stdout.len > 0) {
                    try __koru_std.fs.File.stderr().writeAll(cs_result.stdout);
                }
                __koru_std.process.exit(1);
            },
            else => {
                try stdout.writeAll("✗ dotnet build ended abnormally\n");
                __koru_std.process.exit(1);
            },
        }
        return;
    }

    // Now compile the emitted code
    // Check for cross-compilation target from build:config;
    // KORU_BACKEND_TARGET fills the gap for hosts whose glibc
    // predates zig's native baseline — a program's declared
    // target always wins.
    const env_target = __koru_std.process.getEnvVarOwned(allocator, "KORU_BACKEND_TARGET") catch null;
    defer if (env_target) |t| allocator.free(t);
    const build_target = emitter_helpers.getBuildConfig("target") orelse env_target;

    // --zig-lib-dir overlay: koru's optimized-but-byte-identical
    // std/json/Stringify.zig for every @import("std") the emitted
    // program makes. null → stock std; identical output, slower.
    var zig_lib_buf: [4096]u8 = undefined;
    const zig_lib_overlay = __koruEnsureZigLibOverlay(allocator, &zig_lib_buf);
    if (zig_lib_overlay == null) {
        const owarn = __koru_std.fs.File.stderr();
        try owarn.writeAll("note: koru zig-lib overlay unavailable — building emitted program against stock zig std\n");
    }

    // First check if build_output.zig exists (has user build requirements)
    const has_build_output = blk: {
        __koru_std.fs.cwd().access("build_output.zig", .{}) catch break :blk false;
        break :blk true;
    };

    if (has_build_output) {
        // Use zig build with build_output.zig (includes user dependencies)
        var bo_argv: [9][]const u8 = undefined;
        bo_argv[0] = "zig";
        bo_argv[1] = "build";
        bo_argv[2] = "--build-file";
        bo_argv[3] = "build_output.zig";
        var bo_argc: usize = 4;
        if (zig_lib_overlay) |ov| {
            bo_argv[bo_argc] = "--zig-lib-dir"; bo_argc += 1;
            bo_argv[bo_argc] = ov; bo_argc += 1;
        }
        var opt_buf: [24]u8 = undefined;
        // Output Debug by default; --release=<mode> or -O <Mode> opts
        // into a release build. Passed as -Doptimize so
        // build_output.zig's standardOptimizeOption honors it.
        const out_opt = if (CompilerEnv.hasFlag("debug")) "Debug" else if (CompilerEnv.hasFlag("release=fast")) "ReleaseFast" else if (CompilerEnv.hasFlag("release=safe")) "ReleaseSafe" else if (CompilerEnv.hasFlag("release=small")) "ReleaseSmall" else "Debug";
        bo_argv[bo_argc] = __koru_std.fmt.bufPrint(&opt_buf, "-Doptimize={s}", .{out_opt}) catch "-Doptimize=Debug";
        bo_argc += 1;
        var dt_buf: [128]u8 = undefined;
        if (build_target) |t| {
            bo_argv[bo_argc] = __koru_std.fmt.bufPrint(&dt_buf, "-Dtarget={s}", .{t}) catch "-Dtarget=native";
            bo_argc += 1;
        }
        const result = __koru_std.process.Child.run(.{
            .allocator = allocator,
            .argv = bo_argv[0..bo_argc],
            .max_output_bytes = 10 * 1024 * 1024,
        }) catch |err| {
            const stderr = __koru_std.fs.File.stderr();
            var err_buf: [512]u8 = undefined;
            const err_msg = try __koru_std.fmt.bufPrint(&err_buf, "✗ zig build failed: {}\n", .{err});
            try stderr.writeAll(err_msg);
            __koru_std.process.exit(1);
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const stdout2 = __koru_std.fs.File.stdout();
        var buf2: [512]u8 = undefined;
        // Full Term union — a bare `.Exited` access panics when the zig
        // build was signal-killed (OOM killer under memory pressure),
        // and that panic reads as a compiler crash.
        switch (result.term) {
            .Exited => |exit_code| if (exit_code == 0) {
                // Copy from zig-out/bin/output to the requested output name.
                //
                // Zig names a wasm executable `output.wasm`; every other
                // target produces a bare `output`. Looking only for the bare
                // name made a SUCCESSFUL cross-compile report failure —
                // "Failed to copy output: error.FileNotFound" with a perfectly
                // good .wasm sitting in zig-out/bin the whole time.
                //
                // Only the SOURCE name varies. The destination stays exactly
                // what was asked for: a wasm host is handed the bytes, and
                // neither WebAssembly.compile nor the test harness cares what
                // the file on disk is called.
                // Windows targets likewise produce `output.exe`, and
                // copyFile does no suffix search — the same silent
                // FileNotFound the wasm comment above names.
                const is_wasm = if (build_target) |t| __koru_std.mem.indexOf(u8, t, "wasm") != null else false;
                const wants_exe = if (build_target) |t| __koru_std.mem.indexOf(u8, t, "windows") != null else @import("builtin").os.tag == .windows;
                const zig_artifact = if (is_wasm) "zig-out/bin/output.wasm" else if (wants_exe) "zig-out/bin/output.exe" else "zig-out/bin/output";
                __koru_std.fs.cwd().copyFile(zig_artifact, __koru_std.fs.cwd(), output_exe, .{}) catch |copy_err| {
                    const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Failed to copy output: {}\n", .{copy_err});
                    try __koru_std.fs.File.stderr().writeAll(msg2);
                    __koru_std.process.exit(1);
                };
                // The mode rides the success line — a silent Debug
                // default is how a benchmark ends up timing a
                // bounds-checked binary without knowing it.
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✓ Compiled to {s} ({s})\n", .{ output_exe, out_opt });
                try stdout2.writeAll(msg2);
            } else {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
                try stdout2.writeAll(msg2);
                if (result.stderr.len > 0) {
                    try __koru_std.fs.File.stderr().writeAll("Error: ");
                    try __koru_std.fs.File.stderr().writeAll(result.stderr);
                    try __koru_std.fs.File.stderr().writeAll("\n");
                }
                __koru_std.process.exit(1);
            },
            .Signal => |sig| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ zig build was killed by signal {d} — ended from outside, before it could finish. This usually means the machine ran out of memory, or something killed it externally. Check memory and load, then rerun. The source program was never judged.\n", .{sig});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            },
            .Stopped => |sig| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ zig build was stopped by signal {d} and never resumed — resume or kill it, then rerun\n", .{sig});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            },
            .Unknown => |status| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ zig build ended in an unknown state (status {d}) — rerun; if it repeats, the machine is the suspect\n", .{status});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            },
        }
    } else {
        // Fall back to direct zig build-exe (no user dependencies)
        var emit_path_buf: [256]u8 = undefined;
        const emit_path = try __koru_std.fmt.bufPrint(&emit_path_buf, "-femit-bin={s}", .{output_exe});
        const debug = CompilerEnv.hasFlag("debug");
        const release_fast = CompilerEnv.hasFlag("release=fast");
        const release_safe = CompilerEnv.hasFlag("release=safe");
        const release_small = CompilerEnv.hasFlag("release=small");
        const exe_opt = if (debug) "Debug" else if (release_fast) "ReleaseFast" else if (release_safe) "ReleaseSafe" else if (release_small) "ReleaseSmall" else "Debug";
        // `Source`-typed fields emit `__koru_ast.Source` references into
        // output_emitted.zig. When the emitted text uses them, the ast
        // module (plus its errors and glob_pattern_matcher deps) must be
        // mapped via --dep/-M — the bare build-exe path has no build file
        // to do it. Positional and -M main-module spellings conflict, so
        // the module cluster takes the explicit -Mroot= form.
        const needs_ast_module = __koru_std.mem.indexOf(u8, generated_code, "__koru_ast.") != null;
        var exe_argv: [24][]const u8 = undefined;
        var exe_argc: usize = 0;
        exe_argv[exe_argc] = "zig"; exe_argc += 1;
        exe_argv[exe_argc] = "build-exe"; exe_argc += 1;
        // koru_allocator() backs onto std.heap.c_allocator (real libc
        // malloc/free) -- needs libc linked on this direct build-exe path too.
        exe_argv[exe_argc] = "-lc"; exe_argc += 1;
        if (build_target) |t| {
            exe_argv[exe_argc] = "-target"; exe_argc += 1;
            exe_argv[exe_argc] = t; exe_argc += 1;
        }
        // stage2_x86_64 — zig's default backend for x86_64 Debug
        // targets — refuses @call(.always_tail) outright, and no
        // -mcpu selection changes that (measured 2026-10-21:
        // baseline, x86_64_v2/v3, znver3, skylake all refuse
        // identically). The flat-segment emitter's whole
        // mechanism is always_tail, so any program carrying one
        // must compile under LLVM. Programs without tail calls
        // keep the faster stage2 backend.
        if (__koru_std.mem.indexOf(u8, generated_code, "@call(.always_tail") != null) {
            exe_argv[exe_argc] = "-fllvm"; exe_argc += 1;
        }
        exe_argv[exe_argc] = "-O"; exe_argc += 1;
        // The OUTPUT binary defaults to Debug: safety checks (bounds,
        // overflow, unreachable) stay on, which is the mode the test suite
        // should judge. The earlier ReleaseFast default was a benchmark
        // optimization that leaked into every output and hid UB.
        // `--release=<mode>` or `-O <Mode>` opts into a release build;
        // `--debug` stays an explicit Debug and wins over release flags.
        exe_argv[exe_argc] = exe_opt; exe_argc += 1;
        exe_argv[exe_argc] = emit_path; exe_argc += 1;
        if (zig_lib_overlay) |ov| {
            exe_argv[exe_argc] = "--zig-lib-dir"; exe_argc += 1;
            exe_argv[exe_argc] = ov; exe_argc += 1;
        }
        var ast_path_buf: [1024]u8 = undefined;
        var errors_path_buf: [1024]u8 = undefined;
        var gpm_path_buf: [1024]u8 = undefined;
        var root_mod_buf: [512]u8 = undefined;
        var ast_mod_buf: [1088]u8 = undefined;
        var errors_mod_buf: [1088]u8 = undefined;
        var gpm_mod_buf: [1088]u8 = undefined;
        if (needs_ast_module) {
            const ast_path = try __koru_std.fmt.bufPrint(&ast_path_buf, "{s}/src/ast.zig", .{CompilerEnv.koru_home});
            const errors_path = try __koru_std.fmt.bufPrint(&errors_path_buf, "{s}/src/errors.zig", .{CompilerEnv.koru_home});
            const gpm_path = try __koru_std.fmt.bufPrint(&gpm_path_buf, "{s}/src/glob_pattern_matcher.zig", .{CompilerEnv.koru_home});
            exe_argv[exe_argc] = "--dep"; exe_argc += 1;
            exe_argv[exe_argc] = "ast"; exe_argc += 1;
            exe_argv[exe_argc] = try __koru_std.fmt.bufPrint(&root_mod_buf, "-Mroot={s}", .{emitted_file}); exe_argc += 1;
            exe_argv[exe_argc] = "--dep"; exe_argc += 1;
            exe_argv[exe_argc] = "errors"; exe_argc += 1;
            exe_argv[exe_argc] = "--dep"; exe_argc += 1;
            exe_argv[exe_argc] = "glob_pattern_matcher"; exe_argc += 1;
            exe_argv[exe_argc] = try __koru_std.fmt.bufPrint(&ast_mod_buf, "-Mast={s}", .{ast_path}); exe_argc += 1;
            exe_argv[exe_argc] = try __koru_std.fmt.bufPrint(&errors_mod_buf, "-Merrors={s}", .{errors_path}); exe_argc += 1;
            exe_argv[exe_argc] = try __koru_std.fmt.bufPrint(&gpm_mod_buf, "-Mglob_pattern_matcher={s}", .{gpm_path}); exe_argc += 1;
        } else {
            exe_argv[exe_argc] = emitted_file; exe_argc += 1;
        }
        const result = __koru_std.process.Child.run(.{
            .allocator = allocator,
            .argv = exe_argv[0..exe_argc],
            .max_output_bytes = 10 * 1024 * 1024,
        }) catch |err| {
            const stderr = __koru_std.fs.File.stderr();
            var err_buf: [512]u8 = undefined;
            const err_msg = try __koru_std.fmt.bufPrint(&err_buf, "✗ zig build-exe failed: {}\n", .{err});
            try stderr.writeAll(err_msg);
            __koru_std.process.exit(1);
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const stdout2 = __koru_std.fs.File.stdout();
        var buf2: [512]u8 = undefined;
        // Full Term union — same contract as the build-file path above.
        switch (result.term) {
            .Exited => |exit_code| if (exit_code == 0) {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✓ Compiled to {s} ({s})\n", .{ output_exe, exe_opt });
                try stdout2.writeAll(msg2);
            } else {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
                try stdout2.writeAll(msg2);
                if (result.stderr.len > 0) {
                    try __koru_std.fs.File.stderr().writeAll("Error: ");
                    try __koru_std.fs.File.stderr().writeAll(result.stderr);
                    try __koru_std.fs.File.stderr().writeAll("\n");
                }
                __koru_std.process.exit(1);
            },
            .Signal => |sig| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ zig build-exe was killed by signal {d} — ended from outside, before it could finish. This usually means the machine ran out of memory, or something killed it externally. Check memory and load, then rerun. The source program was never judged.\n", .{sig});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            },
            .Stopped => |sig| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ zig build-exe was stopped by signal {d} and never resumed — resume or kill it, then rerun\n", .{sig});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            },
            .Unknown => |status| {
                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ zig build-exe ended in an unknown state (status {d}) — rerun; if it repeats, the machine is the suspect\n", .{status});
                try __koru_std.fs.File.stderr().writeAll(msg2);
                __koru_std.process.exit(1);
            },
        }
    }
}