// Koru Comptime Backend Handlers
// Handlers for [comptime] annotated modules, available during backend compilation

const __koru_std = @import("std");
const __koru_ast = @import("ast");
const log = @import("log");
const __koru_emitter_helpers = @import("emitter_helpers");

// AST Dump Helper - observability for compiler pipeline debugging.
// Structural continuation-tree walk gated by KORU_DUMP_AST. Self-contained
// on __koru_ast types (no serializer needed at Stage-C), so it renders the
// POST-TRANSFORM tree the emitter actually consumes — taps, comprehensions,
// [with], auto-discharge. Each `| branch bind => NODE` line names the node
// kind and its identity; [TAP] marks tap-inserted invocations.
fn koruDumpPath(path: __koru_ast.DottedPath) void {
    if (path.module_qualifier) |mq| __koru_std.debug.print("{s}:", .{mq});
    for (path.segments, 0..) |seg, i| {
        if (i > 0) __koru_std.debug.print(".", .{});
        __koru_std.debug.print("{s}", .{seg});
    }
}
fn koruDumpCont(cont: *const __koru_ast.Continuation, depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) __koru_std.debug.print("  ", .{});
    __koru_std.debug.print("| {s}", .{cont.branch});
    if (cont.binding) |b| __koru_std.debug.print(" {s}", .{b});
    if (cont.is_transformed_subtree) __koru_std.debug.print(" [XFORMED-SUBTREE]", .{});
    if (cont.node) |n| {
        switch (n) {
            .invocation => |inv| {
                __koru_std.debug.print(" => INVOKE ", .{});
                koruDumpPath(inv.path);
                if (inv.return_binding) |rb| __koru_std.debug.print(": {s}", .{rb});
                if (inv.inserted_by_tap) __koru_std.debug.print("  [TAP]", .{});
                if (inv.annotations.len > 0) {
                    __koru_std.debug.print("  ANN[", .{});
                    for (inv.annotations) |a| __koru_std.debug.print("{s} ", .{a});
                    __koru_std.debug.print("]", .{});
                }
                if (inv.inline_body != null) __koru_std.debug.print("  [INLINE_BODY]", .{});
            },
            .branch_constructor => |bc| {
                if (bc.is_bare_return) {
                    __koru_std.debug.print(" => RETURN", .{});
                } else {
                    __koru_std.debug.print(" => CTOR .{s}", .{bc.branch_name});
                }
            },
            .terminal => __koru_std.debug.print(" => _", .{}),
            .label_with_invocation => |lwi| {
                __koru_std.debug.print(" => LABEL {s} ", .{lwi.label});
                koruDumpPath(lwi.invocation.path);
                if (lwi.invocation.inserted_by_tap) __koru_std.debug.print("  [TAP]", .{});
            },
            .metatype_binding => |mb| {
                __koru_std.debug.print(" => METATYPE {s}", .{mb.metatype});
                if (mb.inserted_by_tap) __koru_std.debug.print("  [TAP]", .{});
            },
            else => __koru_std.debug.print(" => <node>", .{}),
        }
    } else {
        __koru_std.debug.print(" => (empty)", .{});
    }
    __koru_std.debug.print("\n", .{});
    for (cont.continuations) |*child| koruDumpCont(child, depth + 1);
}
fn dumpAST(program_ast: *const __koru_ast.Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
    const dump_enabled: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) break :blk null;
        break :blk null;
    };
    defer if (dump_enabled) |val| allocator.free(val);
    if (dump_enabled == null) return;  // Not enabled

    __koru_std.debug.print("\n============================================================\n", .{});
    __koru_std.debug.print("AST DUMP: {s}  (items={d}, module={s})\n", .{ stage, program_ast.items.len, program_ast.main_module_name });
    __koru_std.debug.print("============================================================\n", .{});
    for (program_ast.items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                __koru_std.debug.print("FLOW ", .{});
                if (f.body.node) |n| {
                    if (n == .invocation) koruDumpPath(n.invocation.path);
                }
                __koru_std.debug.print("\n", .{});
                koruDumpCont(&f.body, 1);
            },
            else => {},
        }
    }
    __koru_std.debug.print("============================================================\n\n", .{});
}
// Access compiler flags via the per-user compiler_env module
pub const CompilerEnv = @import("compiler_env").CompilerEnv;

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
};

pub const koru_std = struct {
    pub const koru_compiler = struct {
        // Compiler system dependencies
        const std = @import("std");
        const ast = @import("ast");
        const Program = ast.Program;
        const Item = ast.Item;
        const Source = ast.Source;
        const Allocator = std.mem.Allocator;
        // Compiler backend build requirements are defined below via requires
        // Simplified Koru Compiler Library
        // A working implementation that can actually be injected and used
        // ============================================================
        // BUILD REQUIREMENTS - Self-documenting build dependencies
        // ============================================================
        // Modules declare their build requirements for backend.zig compilation.
        // The frontend collects these during compilation and generates build.zig.
        //
        // Usage:
        //   compiler:requires {
        //     exe.linkSystemLibrary("sqlite3");
        //   }
        //
        // The declarations themselves live in compiler.directives.kz.
        // Core compiler modules needed for backend compilation
        // This replaces the manual temp_build.zig generation in run_regression.sh
        // ============================================================
        // COMPILER FLAGS - Self-documenting feature flags
        // ============================================================
        // Modules declare their compiler flags with inline documentation.
        // The frontend collects these during --help to build flag documentation.
        //
        // Usage:
        //   compiler:flag.declare {
        //     "name": "fusion",
        //     "description": "Enable tor fusion optimization",
        //     "type": "boolean"
        //   }
        //
        // [norun] annotation prevents auto-execution - --help reads from AST instead.
        // This makes help metacircular - discovered by parsing, not hardcoded!
        // ============================================================
        // IMPORT PATH ALIASES - what the program says about where it lives
        // ============================================================
        // A program declares its own import aliases, in itself. In pure `.k` there is no
        // tilde — this is a Koru feature, not a host-embedding one:
        //
        //   std/compiler:paths {
        //       domain: ./test_lib/domain
        //       toolkit: {{ flag:target }}/toolkit
        //   }
        //
        // A host-embedding file (`.kz`, `.kjs`, …) writes the same block as
        // `std/compiler:paths { .. }`. Diagnostics render whichever spelling the file
        // being compiled actually uses.
        //
        // One `alias: path` per line. `{{ ENTRY }}`, `{{ KORU_HOME }}` and
        // `{{ flag:name }}` interpolate; a flag with no value supplied is refused at the
        // declaration rather than resolved into whatever happens to be on disk.
        //
        // [norun] for the same reason as flag.declare: the declaration never executes.
        // Unlike flag.declare it is not harvested after the parse either — the frontend
        // reads it DURING the parse, because parse and import resolution are one pass and
        // an alias has to exist before the import that uses it is read. That is why this
        // only has effect in the entry file, above its first use.
        // ============================================================
        // COMPILER COMMANDS - User-definable CLI commands
        // ============================================================
        // Modules can declare CLI commands that run instead of normal compilation.
        // Commands have full AST access and run in the backend compilation phase.
        //
        // Usage (in your module, e.g. package.kz):
        //   import std/compiler
        //
        //   std/compiler:command.declare {
        //     "name": "i",
        //     "alias": "install",
        //     "description": "Install npm packages from requires.npm declarations"
        //   }
        //
        //   [comptime|command]pub tor install { program, allocator, argv: []string }
        //   proc install { /* full AST access - walk program for requires.npm, etc. */ }
        //
        // Invoke: koruc main.kz install [args...]  (or the alias: koruc main.kz i)
        //
        // Commands appear in --help under "Commands:"; [norun] prevents auto-execution.
        // ============================================================
        // COMPILER COORDINATION - User-overridable compilation pipeline
        // ============================================================
        // The compiler coordinator (user-overridable)
        // Abstract: Users can override with std/compiler:coordinate = ...
        // Default implementation of the compiler coordinator
        // Users who don't override get this standard pipeline
        // Composable pipeline segments - users can mix and match!
        // Helper: Create CompilerContext from ast and allocator
        // Comptime interpreter fold: partial evaluation of [comptime] flows whose
        // head tor has a pure-Koru bare-return impl. The interpreter (comptime_eval)
        // evaluates the head at Stage C and rewrites the flow to its runtime residue
        // with the folded value spliced in. Failure is LOUD: an unfoldable foldable
        // flow is a compile error carrying the evaluator's diagnostic, never a silent
        // pass-through. See docs/comptime_core_ast_inventory.md.
        // Elaboration segment: resolve names, expand templates, fold comptime — the AST
        // arrives as written and leaves in the core form the later segments validate and
        // emit. Abstract, can be overridden.
        //
        // NOT the frontend: `koruc` (src/main.zig) is the frontend, and it parses and
        // validates before any of this runs. This segment is the first phase of the
        // BACKEND compiler, which is why it can see resolved names at all.
        // `desugar-chains()` runs TWICE, and the second run is the point. The first sits
        // left of every transform stage, so it only ever sees AUTHOR-written arms; a
        // branch a transform synthesizes later — which is every std/store arm — is minted
        // after the thread has gone home and could never offer its payload at any arity.
        // Re-entry is safe because the fill is idempotent: `isOpenThreadSlot`
        // (ast_transform.zig:1232) returns false for any slot already carrying an
        // argument, so the second run can only fill what the first could not see.
        // Analysis segment: Validation passes (abstract, can be overridden)
        // Tap transformation segment: Insert tap invocations into AST
        // This converts taps from emission-time code injection to AST nodes,
        // enabling the optimizer to see and optimize them (zero-cost abstraction!)
        // (abstract, can be overridden)
        // Test generation segment: Generates Zig test blocks from test declarations
        // Runs AFTER analysis (purity is propagated) but BEFORE optimization
        // This uses the SAME emitter as emission - no hand-rolled code generation!
        // Test generation implementation
        // Finds test invocations in AST and generates Zig test blocks
        // Helper: Check if an invocation is calling the test tor
        const isTestInvocation = struct {
            fn call(inv: *const @import("ast").Invocation) bool {
                // Check if path is "test" from std.testing
                if (inv.path.segments.len == 1 and std.mem.eql(u8, inv.path.segments[0], "test")) {
                    return true;
                }
                // Could also check for module-qualified: std_testing:test
                if (inv.path.module_qualifier) |mq| {
                    if (std.mem.indexOf(u8, mq, "testing") != null and
                        inv.path.segments.len == 1 and
                        std.mem.eql(u8, inv.path.segments[0], "test"))
                    {
                        return true;
                    }
                }
                return false;
            }
        }.call;
        // Helper: Process a test flow and generate Zig test block
        // Uses the REAL emitter infrastructure - not hand-rolled code!
        const processTestFlow = struct {
            fn call(flow: *const @import("ast").Flow, program: *const @import("ast").Program, allocator: std.mem.Allocator) ?@import("ast").Item {
                const ast_mod = @import("ast");
                const ast_functional = @import("ast_functional");
                const parser_impl = @import("parser");
                const emitter_helpers = @import("emitter_helpers");
                // Suppress unused import warnings (these are used in nested functions)
                _ = &ast_functional;
                // Get test name from invocation args (first arg named "expr")
                var test_name: []const u8 = "unnamed test";
                for (flow.inv().args) |arg| {
                    if (std.mem.eql(u8, arg.name, "expr")) {
                        test_name = arg.value;
                        break;
                    }
                }
                // Get source body from invocation args - stored in source_value field
                var source_text: []const u8 = "";
                var source_ptr: ?*const ast_mod.Source = null;
                for (flow.inv().args) |arg| {
                    if (arg.source_value) |src| {
                        source_text = src.text;
                        source_ptr = src;
                        break;
                    }
                }
                if (source_text.len == 0) {
                    log.verbose("[TEST-GEN] Warning: No source body found for test '{s}'\n", .{test_name});
                    return null;
                }
                log.verbose("[TEST-GEN] Processing test '{s}' with {d} bytes of source\n", .{test_name, source_text.len});
                // Parse the source body
                // The test body has no file of its own. It inherits the ENCLOSING file's
                // DIALECT — and only the dialect. A `.k` is pure Koru with no ``; the
                // invented "__test__.kz" told the parser this was host-embedded, so every
                // line of the body parsed as HOST TEXT, nothing was collected, and the
                // emitted test block came out EMPTY — a pass with zero assertions in it
                // (395_002, 395_009).
                //
                // The synthetic NAME is kept deliberately. A filename answers two
                // questions in Parser.init — the dialect (parser.zig:707) and the MODULE
                // NAME (parser.zig:696-705) — and handing it the real path fixes the
                // first while silently renaming the module, which took 395_005 and
                // 395_010 red. Same disease as std/runtime:parse.source, seen from the
                // other side: one parameter, two questions. So: synthetic name for the
                // module, real extension for the dialect, set after init because is_k is
                // read during parse and never during init.
                //
                // Ruled by Lars 2026-08-07: "use the same extension and semantics as the
                // original file... Writing `` inside a `.k`-file makes no sense, that is
                // literally the actual rule."
                var parser = parser_impl.Parser.init(allocator, source_text, "__test__.kz", &[_][]const u8{}, null) catch {
                    log.verbose("[TEST-GEN] Failed to init parser for test '{s}'\n", .{test_name});
                    return null;
                };
                if (source_ptr) |sp| parser.is_k = std.mem.endsWith(u8, sp.location.file, ".k");
                defer parser.deinit();
                var parse_result = parser.parse() catch {
                    log.verbose("[TEST-GEN] Failed to parse source for test '{s}'\n", .{test_name});
                    return null;
                };
                defer parse_result.deinit();
                // Clone parsed items to owned memory (survive parser deinit)
                var mocks = std.ArrayList(ast_mod.Item).initCapacity(allocator, 8) catch unreachable;
                var test_flows = std.ArrayList(ast_mod.Item).initCapacity(allocator, 8) catch unreachable;
                for (parse_result.source_file.items) |*parsed_item| {
                    switch (parsed_item.*) {
                        .immediate_impl => {
                            // This is a mock! Clone it
                            const cloned = ast_functional.cloneItem(allocator, parsed_item) catch continue;
                            mocks.append(allocator, cloned) catch {};
                        },
                        .flow => {
                            // This is a test flow - clone it
                            const cloned = ast_functional.cloneItem(allocator, parsed_item) catch continue;
                            test_flows.append(allocator, cloned) catch {};
                        },
                        else => {},
                    }
                }
                log.verbose("[TEST-GEN] Parsed {d} mocks and {d} flows\n", .{mocks.items.len, test_flows.items.len});
                // Validate mock shapes via testing module
                if (source_ptr) |src| {
                    const backend_output = @import("backend_output_emitted.zig");
                    const validation_result = backend_output.koru_std.koru_testing.validate_mocks_event.handler(.{
                        .program = program,
                        .mocks = mocks.items,
                        .source = src,
                        .allocator = allocator,
                    });
                    if (validation_result == .failed) {
                        @panic(validation_result.failed);
                    }
                }
                // Build mock lookup map (tor path -> branch constructor)
                var mock_map = std.StringHashMap(ast_mod.BranchConstructor).init(allocator);
                for (mocks.items) |mock_item| {
                    if (mock_item == .immediate_impl) {
                        const sf = mock_item.immediate_impl;
                        // Build tor path string
                        var path_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
                        for (sf.event_path.segments, 0..) |seg, i| {
                            if (i > 0) path_buf.append(allocator, '.') catch {};
                            path_buf.appendSlice(allocator, seg) catch {};
                        }
                        mock_map.put(path_buf.items, sf.value) catch {};
                    }
                }
                // Walk test flows and check purity
                var impure_events = std.ArrayList([]const u8).initCapacity(allocator, 8) catch unreachable;
                for (test_flows.items) |flow_item| {
                    if (flow_item == .flow) {
                        walkFlowForPurity(&flow_item.flow, &mock_map, &impure_events, program.items, allocator);
                    }
                }
                // If there are impure tors without mocks, error. One line, names
                // comma-separated — kept byte-identical to the transform-pass twin in
                // koru_std/testing.kz so which producer fired is never something a
                // reader (or a pinned regression) has to know.
                if (impure_events.items.len > 0) {
                    var err_msg = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                    err_msg.appendSlice(allocator, "Test '") catch {};
                    err_msg.appendSlice(allocator, test_name) catch {};
                    err_msg.appendSlice(allocator, "' has impure events without mocks: ") catch {};
                    for (impure_events.items, 0..) |event_path, i| {
                        if (i > 0) err_msg.appendSlice(allocator, ", ") catch {};
                        err_msg.appendSlice(allocator, event_path) catch {};
                    }
                    @panic(err_msg.items);
                }
                // Now emit the test using REAL emitter infrastructure
                // Growable: generated test code has no natural size ceiling.
                var code_emitter = emitter_helpers.CodeEmitter.initGrowable(allocator, 16 * 1024) catch return null;
                // Set up emission context
                var emit_ctx = emitter_helpers.EmissionContext{
                    .allocator = allocator,
                    .indent_level = 1,  // Inside test block
                    .ast_items = program.items,
                    .main_module_name = "input",
                    .is_sync = true,
                };
                code_emitter.indent_level = 1;
                // Emit each test flow, substituting mocks
                var mock_counter: usize = 0;
                for (test_flows.items) |flow_item| {
                    if (flow_item == .flow) {
                        emitFlowWithMocks(&code_emitter, &emit_ctx, &flow_item.flow, &mock_map, &mock_counter) catch {};
                    }
                }
                const flow_code = code_emitter.getOutput();
                // Build final test block
                const test_code = std.fmt.allocPrint(
                    allocator,
                    \\test "{s}" {{
                    \\{s}}}
                    ,
                    .{ test_name, flow_code }
                ) catch return null;
                return ast_mod.Item{
                    .inline_code = ast_mod.InlineCode{
                        .code = test_code,
                        .location = flow.location,
                        .module = allocator.dupe(u8, flow.module) catch "",
                    }
                };
            }
        }.call;
        // Helper: Walk a flow checking for impure tors without mocks
        const walkFlowForPurity = struct {
            fn call(
                flow_to_walk: *const @import("ast").Flow,
                mocks: *const std.StringHashMap(@import("ast").BranchConstructor),
                impure_list: *std.ArrayList([]const u8),
                all_items: []const @import("ast").Item,
                allocator: std.mem.Allocator,
            ) void {
                const emitter_helpers = @import("emitter_helpers");
                // Get invocation path as string
                var path_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
                if (flow_to_walk.inv().path.module_qualifier) |mq| {
                    path_buf.appendSlice(allocator, mq) catch {};
                    path_buf.append(allocator, ':') catch {};
                }
                for (flow_to_walk.inv().path.segments, 0..) |seg, i| {
                    if (i > 0) path_buf.append(allocator, '.') catch {};
                    path_buf.appendSlice(allocator, seg) catch {};
                }
                const inv_path = path_buf.items;
                // Check if this invocation has a mock
                if (mocks.get(inv_path)) |_| {
                    // Has mock - walk only matching continuation
                    // (mock value is known, prune other branches)
                    return;
                }
                // Subflow/composed tors: walk the implementation body instead of
                // flagging the outer tor.
                if (emitter_helpers.findImplByPath(all_items, &flow_to_walk.inv().path)) |found_impl| {
                    switch (found_impl) {
                        .immediate_impl => return,
                        .flow => |impl_flow| {
                            call(impl_flow, mocks, impure_list, all_items, allocator);
                            return;
                        },
                    }
                }
                // No mock - check if tor/proc is pure
                if (emitter_helpers.findProcDeclByPath(all_items, &flow_to_walk.inv().path)) |proc| {
                    if (!proc.is_pure) {
                        // Impure proc without mock!
                        var already_added = false;
                        for (impure_list.items) |existing| {
                            if (std.mem.eql(u8, existing, inv_path)) {
                                already_added = true;
                                break;
                            }
                        }
                        if (!already_added) {
                            impure_list.append(allocator, inv_path) catch {};
                        }
                    }
                } else if (emitter_helpers.findEventDeclByPath(all_items, &flow_to_walk.inv().path)) |event| {
                    if (!event.is_pure) {
                        var already_added = false;
                        for (impure_list.items) |existing| {
                            if (std.mem.eql(u8, existing, inv_path)) {
                                already_added = true;
                                break;
                            }
                        }
                        if (!already_added) {
                            impure_list.append(allocator, inv_path) catch {};
                        }
                    }
                }
                // Walk continuations recursively
                for (flow_to_walk.body.continuations) |cont| {
                    walkContinuation(&cont, mocks, impure_list, all_items, allocator);
                }
            }
            fn walkContinuation(
                cont: *const @import("ast").Continuation,
                mocks: *const std.StringHashMap(@import("ast").BranchConstructor),
                impure_list: *std.ArrayList([]const u8),
                all_items: []const @import("ast").Item,
                allocator: std.mem.Allocator,
            ) void {
                const ast_mod = @import("ast");
                if (cont.node) |node| {
                    switch (node) {
                        .invocation => {
                            // Wrap the site as a flow to walk (same core, thin wrapper)
                            const temp_flow = ast_mod.Flow{
                                .body = cont.*,
                                .location = cont.location,
                                .module = "",
                                .is_pure = true,
                                .is_transitively_pure = false,
                            };
                            call(&temp_flow, mocks, impure_list, all_items, allocator);
                        },
                        else => {
                            for (cont.continuations) |nested| {
                                walkContinuation(&nested, mocks, impure_list, all_items, allocator);
                            }
                        },
                    }
                } else {
                    for (cont.continuations) |nested| {
                        walkContinuation(&nested, mocks, impure_list, all_items, allocator);
                    }
                }
            }
        }.call;
        // Helper: Emit a flow with mock substitution using REAL emitter
        const emitFlowWithMocks = struct {
            fn call(
                code_emitter: *@import("emitter_helpers").CodeEmitter,
                ctx: *@import("emitter_helpers").EmissionContext,
                flow_to_emit: *const @import("ast").Flow,
                mocks: *const std.StringHashMap(@import("ast").BranchConstructor),
                counter: *usize,
            ) !void {
                const ast_mod = @import("ast");
                const emitter_helpers = @import("emitter_helpers");
                // Get invocation path as string
                var path_buf = std.ArrayList(u8).initCapacity(ctx.allocator, 64) catch unreachable;
                for (flow_to_emit.inv().path.segments, 0..) |seg, i| {
                    if (i > 0) try path_buf.append(ctx.allocator, '.');
                    try path_buf.appendSlice(ctx.allocator, seg);
                }
                const inv_path = path_buf.items;
                // Check if this invocation has a mock
                if (mocks.get(inv_path)) |bc| {
                    // Emit mock value directly
                    const result_var = try std.fmt.allocPrint(ctx.allocator, "__mock_result_{d}", .{counter.*});
                    counter.* += 1;
                    try code_emitter.writeIndent();
                    try code_emitter.write("const ");
                    try code_emitter.write(result_var);
                    try code_emitter.write(" = ");
                    try emitter_helpers.emitBranchConstructor(code_emitter, ctx, &bc, true);
                    try code_emitter.write(";\n");
                    // Emit matching continuation
                    for (flow_to_emit.body.continuations) |cont| {
                        if (std.mem.eql(u8, cont.branch, bc.branch_name)) {
                            if (cont.binding) |binding| {
                                // Emit binding extraction: const x = result.branch;
                                try code_emitter.writeIndent();
                                try code_emitter.write("const ");
                                try code_emitter.write(binding);
                                try code_emitter.write(" = ");
                                try code_emitter.write(result_var);
                                try code_emitter.write(".");
                                try code_emitter.write(bc.branch_name);
                                try code_emitter.write(";\n");
                                // Suppress unused binding warning
                                try code_emitter.writeIndent();
                                try code_emitter.write("_ = &");
                                try code_emitter.write(binding);
                                try code_emitter.write(";\n");
                            }
                            // Emit nested flows
                            if (cont.node) |node| {
                                if (node == .invocation) {
                                    const nested_flow = ast_mod.Flow{
                                        .body = cont,
                                        .location = cont.location,
                                        .module = "",
                                        .is_pure = true,
                                        .is_transitively_pure = false,
                                    };
                                    try call(code_emitter, ctx, &nested_flow, mocks, counter);
                                }
                            }
                            break;
                        }
                    }
                    try code_emitter.writeIndent();
                    try code_emitter.write("_ = &");
                    try code_emitter.write(result_var);
                    try code_emitter.write(";\n");
                } else {
                    // No mock - emit flow normally using real emitter
                    try emitter_helpers.emitFlow(code_emitter, ctx, flow_to_emit);
                }
            }
        }.call;
        // Emission segment: Final code generation (abstract, can be overridden)
        // Parser service - makes the Koru parser available at backend comptime
        // This enables dynamic module loading during compilation passes
        // Zig code emission tor - the final step of compilation!
        // Comptime evaluation pass - executes tors with Program/Source parameters
        // Structural shape checking - validates tors/branches exist, base types match
        // Release gate - rejects [prototype] modules under --release (runs first in analysis)
        // Flow checking - validates control flow properties (when-clause exhaustiveness, etc.)
        // Phantom SIGNATURE validation - declaration-shape checks on tor signatures
        // (phantom syntax, obligation polarity: KORU033, unknown phantom modules: KORU040).
        // Runs BEFORE pass-auto-discharge: an illegal polarity on an tor's own
        // declaration must be rejected before any obligation-FLOW analysis reasons
        // about programs using that tor (otherwise auto-discharge halts first with
        // a spurious KORU030 leak and the declaration error stays dormant).
        // The ordering fact is declared on the consumer: pass-auto-discharge.
        // Phantom ARGUMENT validation - the argument-located call-site checks (state
        // threading, per-argument "Phantom state mismatch", use-after-discharge).
        // Runs BEFORE pass-auto-discharge: a call-site mismatch the user can point at
        // must surface with its precise, argument-located diagnostic — not be
        // preempted by the inserter's generic "was not discharged" wall, which never
        // acknowledges the explicit discharge already present in the source. The
        // flow-EXIT obligation-balance walls stay in check-phantom-semantic, after
        // insertion, where the inserted disposal calls exist to be credited.
        // Auto-discharge insertion - inserts disposal calls before terminators
        // Runs BEFORE check-phantom-semantic so checker validates the inserted calls
        // KORU180 enforces the contract:requires edges — a reorder that puts it
        // ahead of the signature/args checkers refuses at the frontend, not mid-run.
        // Witness check - the trusted consumer pass after every solver — decl, mark
        // helpers, and impl live in compiler.witness.kz (joined via ~part witness).
        // Semantic phantom type checking - validates type-state compatibility using
        // the default Koru semantic checker (module-qualified phantom states)
        // Purity checking - trusts [pure] annotations as developer assertions
        // Dead strip pass - removes unreachable tors/flows from the AST
        // Walks from entry points, marks reachable tors, prunes the rest
        // CCP observability pass - injects universal observability taps into user AST
        // When enabled, this makes every compiled program self-observing by adding:
        // - emit_json tor/proc for JSON output
        // - Universal tap (* -> *) that emits transition events
        // Implementation of Zig code emission - this IS ComptimeEmitter as a Koru proc!
        // Parser service implementation - wraps the Koru parser for comptime use
        // Comptime evaluation pass - executes tors with Program/Source parameters
        // This runs BEFORE emission so comptime tors can transform the AST
        // Structural shape checker implementation
        // Release gate: reject a [prototype] module built with --release (the production
        // gate). Runs FIRST in analysis and only under --release, so prototype code is
        // dismissed up front rather than leniently compiled. Dev builds (no --release)
        // skip it entirely and keep the prototype affordance. See release_gate.zig +
        // concepts/frag-prototype-mode-panic-holes.md.
        // Flow checker implementation
        // Validates control flow properties like when-clause exhaustiveness
        // Auto-discharge inserter implementation
        // Inserts disposal calls before terminators when exactly one disposal option exists
        // Phantom signature validation implementation
        // Declaration-shape checks only (polarity, phantom syntax, phantom module
        // resolution) — the obligation-FLOW analysis stays in check-phantom-semantic,
        // which runs after auto-discharge so it validates the inserted disposal calls.
        // Phantom argument validation implementation
        // The argument-located call-site slice of the phantom checker (state
        // threading + per-argument mismatch + use-after-discharge), run BEFORE
        // auto-discharge so the precise "Phantom state mismatch" diagnostics preempt
        // the inserter's generic "was not discharged" wall. The flow-EXIT
        // obligation-balance walls stay in check-phantom-semantic (post-insertion).
        // Flags for auto-discharge control (co-located with implementation!)
        // Semantic phantom type checker implementation
        // Validates module-qualified phantom states and their compatibility
        // Purity checker implementation
        // Tracks [pure] annotations - developer assertion, trusted without verification
        // Dead Strip Pass
        // Removes unreachable tors and flows from the AST
        // Walks from entry points (top-level flows), marks reachable tors, prunes the rest
        // Compiler flags
        //
        // Compiler pipeline control flow.
        //
        // [template] constructs (std/control:if, cond, for) splice host source text
        // and only expand where the per-call template pass reaches. Compiler pipeline
        // definitions — coordinate overrides and other impl-of-comptime flows — are
        // rebuilt downstream of that pass, so templates never expand there; the
        // fallback (calling the unreachable stub handler) always fails. Branch here
        // on VALUES instead: a plain proc returning a branch union lowers in every
        // position — pipeline overrides, walked flows, and plain runtime code.
        // Helper: Format metrics string
        // Koru Standard Library: the `paths` part of compiler.kz.
        // Joined via `~part paths` in compiler.kz; merged into the compiler
        // module at load.
        // Helper: Join path segments with dots
        // IMPORTANT: Takes an allocator to return heap-allocated memory (stack memory was causing corruption!)
        const joinPathAlloc = struct {
            fn call(allocator: std.mem.Allocator, path: []const []const u8) []const u8 {
                if (path.len == 0) return "";
                if (path.len == 1) return path[0];
                // Calculate total length needed
                var total_len: usize = path[0].len;
                for (1..path.len) |i| {
                    total_len += 1 + path[i].len; // dot + segment
                }
                // Allocate result buffer
                const result = allocator.alloc(u8, total_len) catch return path[0]; // Fallback to first segment if alloc fails
                var pos: usize = 0;
                @memcpy(result[pos..pos + path[0].len], path[0]);
                pos += path[0].len;
                for (1..path.len) |i| {
                    result[pos] = '.';
                    pos += 1;
                    @memcpy(result[pos..pos + path[i].len], path[i]);
                    pos += path[i].len;
                }
                return result[0..pos];
            }
        }.call;
        // Koru Standard Library: the `context` part of compiler.kz — the
        // compile-time context and diagnostic surface. Joined via `~part context`
        // in compiler.kz; merged into the compiler module at load.
        //
        // `CompilerContext` threads state for all passes; `ErrorReporter` is the
        // diagnostic channel re-exported under this module's name so a pass or a
        // `[comptime|transform]` tor can spell it `std/compiler:ErrorReporter`.
        // `std`, `ast` and `Program` are imported by the parent's preamble.
        // The diagnostic channel, re-exported under this module's name so a pass or a
        // `[comptime|transform]` tor can spell it `std/compiler:ErrorReporter`.
        // `CompilerError` below is message-plus-location; this carries the code, the
        // hint and the source preview that make a koru diagnostic look like one.
        pub const ErrorReporter = @import("errors").ErrorReporter;
        // ============================================================
        // COMPILER CONTEXT - Threading state for all passes
        // ============================================================
        pub const SourceLocation = struct {
            file: []const u8,
            line: u32,
            column: u32,
        };
        pub const CompilerError = struct {
            message: []const u8,
            location: SourceLocation,
        };
        pub const CompilerWarning = struct {
            message: []const u8,
            location: SourceLocation,
        };
        pub const ErrorPolicy = enum {
            abort_on_first,
            collect_all,
        };
        pub const CompilerContext = struct {
            ast: *const Program,
            original_ast: *const Program,  // Unfiltered AST for metadata queries (TypeRegistry, etc.)
            allocator: std.mem.Allocator,
            errors: std.ArrayList(CompilerError),
            warnings: std.ArrayList(CompilerWarning),
            error_policy: ErrorPolicy,
            current_pass: ?[]const u8,
            passes_completed: u32,
            tap_registry: ?*@import("tap_registry").TapRegistry,
            /// The compilation's ONE diagnostic reporter, bound to the user's source
            /// file at `context-create` and shared by every pass downstream. A pass
            /// that wants a code, a hint or a source preview reaches for this rather
            /// than appending to `errors` — same pipeline, one grade of diagnostic.
            /// Null only on a context built outside the pipeline head.
            reporter: ?*ErrorReporter,
        };
        /// Render the reporter's framed diagnostics to stderr, then move every
        /// error accumulated since `err_base` into the context's error list —
        /// the shared epilogue every check/pass gate runs on refusal. Nine
        /// gate bodies each carried this loop inline; one had already drifted
        /// (a stray blank line), which is how copies die. One drain, one owner.
        pub fn drainReporter(reporter: *ErrorReporter, ctx: *CompilerContext, err_base: usize) void {
            reporter.printErrors(@import("errors").FileSink.stderr()) catch {};
            for (reporter.errors.items[err_base..]) |reporter_err| {
                ctx.errors.append(ctx.allocator, .{
                    .message = ctx.allocator.dupe(u8, reporter_err.message) catch reporter_err.message,
                    .location = .{
                        .file = ctx.allocator.dupe(u8, reporter_err.location.file) catch reporter_err.location.file,
                        .line = @intCast(reporter_err.location.line),
                        .column = @intCast(reporter_err.location.column),
                    },
                }) catch {};
            }
        }
        // Koru Standard Library: the `dump` part of compiler.kz.
        // Joined via `~part dump` in compiler.kz; merged into the compiler
        // module at load.
        // Helper: Dump AST as JSON for introspection
        // Usage: Insert at key points in pipeline to inspect AST state
        // Void tor - just prints and continues
        // Example: ast-dump(ctx: c, flag: "elaborate") |> ...
        // Koru Standard Library: the `directives` part of compiler.kz — frontend-read
        // compiler directives. Joined via `~part directives` in compiler.kz; merged
        // into the compiler module at load.
        //
        // These tors are never dispatched: [norun] prevents auto-execution and the
        // FRONTEND reads the invocation from the AST — discovered by parsing, not
        // hardcoded. `requires` declares backend build requirements (build.zig
        // generation is metacircular this way); `use` pins the backend itself to a
        // minted compiler — it is consumed and stripped before backend emission, so
        // the mint name never reaches the closure it selects.
        // Pin the backend to a minted compiler: `std/compiler:use(my-compiler)`.
        // `expr` resolves in the mint store; `hash` pins binary identity.
        // Koru Standard Library: the `stages` part of compiler.kz.
        // Joined via `~part stages` in compiler.kz; merged into the compiler module at load.
        //
        // The pre-emission AST stage procs: the per-call template pass and the
        // `.pre` transform stage that must run before it. They live apart from the
        // pass-runner body because they are a named family — graft-aware ordering
        // is their whole contract.
        // Template processor: walks AST, renders any proc whose variant chain
        // starts with `template|...` through Liquid, then strips the `template`
        // tag so downstream emission sees a plain host-language proc. See
        // memory project_proc_variant_pipeline / docs/EFFECT_BRANCHES for the
        // `host[:processor]` story this implements.
        // Pre-stage transforms live in the `prelate` part (compiler.prelate.kz):
        // run-pre-transforms fires `.pre` then `.pre_late` BEFORE the template
        // pass. A transform that GRAFTS templated code — e.g. std/constructor
        // dissolving into a comptime list plus a `for` over the var it just
        // defined — must dissolve FIRST, so the template pass then processes the
        // graft as ordinary code. `.main`/`.post` still run at Phase 2.4
        // (evaluate-comptime). `.pre*` transforms carry @pass_ran, so that later
        // all-stages run re-visits them as no-ops. This is the named-stage
        // design: the pipeline sprinkles transform stages where they belong,
        // deliberately.
        // Koru Standard Library: the `prelate` part of compiler.kz.
        // Joined via `~part prelate` in compiler.kz; merged into the compiler module at load.
        //
        // The pre-template transform sprinkle: runs the `.pre` stage (producers —
        // component, store, channel) then `.pre_late` (consumers — std/ctx reads
        // synthesized decls) BEFORE the per-call template pass, so consumer output
        // is ordinary AST that expands normally. `.main`/`.post` still run at
        // Phase 2.4 (evaluate-comptime); `.pre*` transforms carry @pass_ran so the
        // later all-stages run re-visits them as no-ops.
        // Koru Standard Library: the `with` part of compiler.kz.
        // Joined via `~part with` in compiler.kz; merged into the compiler
        // module at load.
        //
        // resolve-with-scopes: the [with] vocabulary pass and its helpers.
        // [with] scoped-vocabulary resolution (641_010; concept
        // frag-with-declares-the-flows-vocabulary). Stage-A canonicalize stamps the
        // MAIN module onto every bare name with no import lookup, so a bare `match`
        // inside a grammar region arrives here as `<main>:match` and would die as an
        // unknown tor. `[with]` colors its whole flow — position is meaningless, the
        // gather runs over the entire subtree before any restamp — and the open set
        // is the union of every opener it finds: bare `[with]` derives the annotated
        // invocation's own module, `[with(a, b)]` names modules explicitly
        // (import-spelled, and each must be imported — KORU142). A bare name stamped
        // to its flow's home module that is NOT a real tor there but IS a real tor of
        // an opened module is re-qualified to it; matching is on the full dotted
        // event name, so `say.hi` and `log.hi` never collide on `hi`. Unresolved-only
        // — a name that genuinely resolves at home is never shadowed. Runs BEFORE
        // run-pre-transforms so the grammar transform (parser.kz `isVerb` keys off
        // the qualifier being present) sees the resolved `std.parser:match`. Mirrors
        // canonicalize_names' own flow/continuation/node recursion, so it visits
        // exactly the paths it does.
        // Koru Standard Library: the `desugars` part of compiler.kz.
        // Joined via `~part desugars` in compiler.kz; merged into the compiler module at load.
        //
        // The chain-desugar stage tor: point-free pyramid, bind pun + type thread,
        // flow return terminus, and the dead-produce audit — the pass that must run
        // after resolve-with-scopes, where every callee name is finally visible.
        // The AST desugars: the point-free pyramid, the bind pun + type thread, and the
        // flow return terminus.
        //
        // They live HERE, and not in koruc, because each one looks a declaration up BY
        // PATH. Stage-A canonicalize stamps `<main>:` onto every bare name, so a
        // `[with]`-scoped name is not resolvable until `resolve-with-scopes` has run.
        // A desugar running before that found no declaration, silently did nothing, and
        // left the failure to surface passes later wearing a different name — an
        // undischarged obligation, or a KORU100 for a binding whose only use the pun
        // never filled. Ordering, not a lookup bug.
        //
        // Order among the three is load-bearing: the pyramid first, so the canonical
        // explicit-continuation shape exists; then the pun and thread, so every step's
        // args are in place; then the terminus, which needs the last step final.
        // Koru Standard Library: the `witness` part of compiler.kz.
        // Joined via `~part witness` in compiler.kz; merged into the compiler module at load.
        //
        // The witness-check pass: the trusted consumer that runs after every solver
        // (docs/koru-verification-path.md §3.5: obligation-synthesis |> witness-check).
        // Prints the marks census for enforced programs; under [strict] it refuses
        // stored writes the numeric check left unproven or rounding. `std`, `ast`
        // and `Program` are imported by the parent's preamble.
        // Witness check - the trusted consumer pass after every solver
        // (docs/koru-verification-path.md §3.5: obligation-synthesis |> witness-check).
        // Prints the marks census for enforced programs; under [strict] it refuses
        // stored writes the numeric check left unproven or rounding.
        // ── pass-witness-check helpers ──────────────────────────────────────────
        // One parsed mark plus the enclosing flow's location — strict refusals
        // point at the flow, not the mark.
        const WitnessSiteMark = struct {
            kind: []const u8,
            site: []const u8,
            arrow: []const u8,
            verdict: []const u8,
            extra: []const u8, // optional fifth field (e.g. auto-discharge's `all:` enumeration); "" when absent
            line: usize,
            column: usize,
        };
        // @witness("kind","site","d<-s","verdict","extra"?) — parsed strictly: four
        // or five quoted fields in a parenthesised list; the fifth is optional
        // per-kind payload (auto-discharge carries `all:` — the completeness
        // commitment). A malformed mark is not a witness:
        // counted nowhere, printed nowhere. (Twin of WCensus.witnessMark in
        // koru_std/witness.kz — the command-side census and this pass are separate
        // generated units, so the parser lives in both.)
        fn witnessCheckParseMark(mark: []const u8, line: usize, column: usize) ?WitnessSiteMark {
            if (!std.mem.startsWith(u8, mark, "@witness(")) return null;
            var fields: [5][]const u8 = .{ "", "", "", "", "" };
            var rest = mark["@witness(".len..];
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                if (rest.len == 0 or rest[0] != '"') return null;
                const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
                fields[i] = rest[1 .. 1 + end];
                rest = rest[2 + end ..];
                if (rest.len == 0) return null;
                if (rest[0] == ',') {
                    rest = rest[1..];
                    continue;
                }
                break;
            }
            if (i < 3) return null;
            if (!std.mem.eql(u8, rest, ")")) return null;
            return .{ .kind = fields[0], .site = fields[1], .arrow = fields[2], .verdict = fields[3], .extra = fields[4], .line = line, .column = column };
        }
        fn witnessCheckCollectCont(
            out: *std.ArrayList(WitnessSiteMark),
            alloc: Allocator,
            cont: *const ast.Continuation,
            line: usize,
            column: usize,
        ) Allocator.Error!void {
            if (cont.node) |*node| {
                switch (node.*) {
                    .invocation => |*inv| {
                        for (inv.marks) |m| {
                            if (witnessCheckParseMark(m, line, column)) |wm| try out.append(alloc, wm);
                        }
                    },
                    .label_with_invocation => |*lwi| {
                        for (lwi.invocation.marks) |m| {
                            if (witnessCheckParseMark(m, line, column)) |wm| try out.append(alloc, wm);
                        }
                    },
                    .foreach => |*fe| for (fe.branches) |*b| try witnessCheckCollectConts(out, alloc, b.body, line, column),
                    .conditional => |*c| for (c.branches) |*b| try witnessCheckCollectConts(out, alloc, b.body, line, column),
                    .switch_result => |*sr| for (sr.branches) |*b| try witnessCheckCollectConts(out, alloc, b.body, line, column),
                    .conditional_block => |*cb| for (cb.nodes) |*n| {
                        if (n.* == .invocation) {
                            for (n.invocation.marks) |m| {
                                if (witnessCheckParseMark(m, line, column)) |wm| try out.append(alloc, wm);
                            }
                        }
                    },
                    else => {},
                }
            }
            try witnessCheckCollectConts(out, alloc, cont.continuations, line, column);
        }
        fn witnessCheckCollectConts(
            out: *std.ArrayList(WitnessSiteMark),
            alloc: Allocator,
            conts: []const ast.Continuation,
            line: usize,
            column: usize,
        ) Allocator.Error!void {
            for (conts) |*cont| try witnessCheckCollectCont(out, alloc, cont, line, column);
        }
        fn witnessCheckCollectItems(
            out: *std.ArrayList(WitnessSiteMark),
            alloc: Allocator,
            items: []const ast.Item,
        ) Allocator.Error!void {
            for (items) |*item| {
                switch (item.*) {
                    .module_decl => |*m| try witnessCheckCollectItems(out, alloc, m.items),
                    .flow => |*fl| try witnessCheckCollectCont(out, alloc, &fl.body, fl.location.line, fl.location.column),
                    else => {},
                }
            }
        }
        // Koru Standard Library: the `ccp` part of compiler.kz.
        // Joined via `~part ccp` in compiler.kz; merged into the compiler module at load.
        // CCP Observability Injection Pass
        // Injects universal observability taps into the user's AST
        // This makes every compiled program self-observing by adding emit_json and * -> * tap
        // CCP Command Processing Pass
        // Reads and processes incoming AI commands from stdin when --ccp is enabled
        // ============================================================================
        // NOTE: The default compiler coordinator is NOT defined as a Koru flow.
        //       It's hardcoded in src/main.zig as a Zig function.
        //
        // Why: The coordinator runs at Zig compile-time during backend.zig compilation,
        //      before the Koru runtime exists. Flows can't execute at that stage.
        //
        // To modify the compilation pipeline, edit compiler_coordinate_default
        // in src/main.zig directly.
        //
        // The pipeline executes these passes in order:
        //   1. compiler.passes.process-ccp-commands  (reads AI commands from stdin)
        //   2. compiler.passes.evaluate-comptime     (executes comptime tors)
        //   3. compiler.check.structure              (validates tor/branch shapes)
        //   4. compiler.check.phantom.semantic       (validates phantom types)
        //   5. compiler.passes.inject-ccp            (adds observability taps)
        //   6. compiler.passes.dead_strip            (removes unreachable tors/flows)
        //   7. compiler.emit.zig                     (generates final Zig code)
        //
        // [expand] tors are handled automatically by transform_pass_runner.zig
        // during the transform phase inside evaluate-comptime.
        // ============================================================================
        // >>> FLOW: /Users/larsde/src/koru-cypoe/koru_std/compiler.kz:18  ~std.deps:requires.system()
        pub fn comptime_flow0(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) void {
            _ = &program;
            _ = &allocator;
            _ = koru_std.koru_deps.requires_system_event.handler(.{ .source = __koru_ast.Source{ .text = 
                \\"name": "zig",
                \\"check": "zig version",
                \\"min_version": "0.15.0",
                \\"brew": "zig",
                \\"apt": "zig",
                \\"pacman": "zig",
                \\"apk": "zig"
                , .scope = .{ .bindings = &.{} }, .phantom_type = null } });
        }
        pub const flag_declare_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const paths_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const command_declare_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const coordinate_event = struct {
            pub const Input = struct {
                program_ast: *const koru_std.koru_compiler.Program,
                allocator: std.mem.Allocator,
            };
            pub const Output = union(enum(u8)) {
                coordinated: struct {
                    ast: *const koru_std.koru_compiler.Program,
                    code: []const u8,
                    metrics: []const u8,
                },
                @"error": []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> SUBFLOW: /Users/larsde/src/koru-cypoe/koru_std/compiler.kz:823
                const program_ast = __koru_event_input.program_ast;
                const allocator = __koru_event_input.allocator;
                _ = &program_ast;
                _ = &allocator;
                _ = &__koru_event_input;
                const result = koru_std.koru_compiler.context_create_event.handler(.{ .program_ast = program_ast,  .allocator = allocator });
                const c0 = result;
                _ = &result;
                const c1 = koru_std.koru_compiler.elaborate_event.handler(.{ .ctx = c0 });
                _ = &c1;
                const nested_result_0 = koru_std.koru_compiler.analysis_event.handler(.{ .ctx = c1 });
                return switch (nested_result_0) {
                    .ctx => |c2| {
                        _ = &c2;
                        const c3 = koru_std.koru_compiler.test_generation_event.handler(.{ .ctx = c2 });
                        _ = &c3;
                        _ = &c3;
                        const c4 = koru_std.koru_optimizer.optimize_event.handler(.{ .ctx = c3 });
                        _ = &c4;
                        const c5 = koru_std.koru_compiler.emission_event.handler(.{ .ctx = c4 });
                        _ = &c5;
                        const m = koru_std.koru_compiler.metrics_format_event.handler(.{ .passes_completed = c5.ctx.passes_completed, .allocator = allocator });
                        _ = &m;
                        const nested_result_2 = koru_std.koru_inter.start_event.handler(.{ .contexts = &[_]koru_std.koru_compiler.CompilerContext{ c0, c1, c2, c3, c4, c5.ctx } });
                        return switch (nested_result_2) {
                            .launched => .{ .coordinated = .{ .ast = c5.ctx.ast,  .code = c5.code,  .metrics = m } },
                            .skipped => .{ .coordinated = .{ .ast = c5.ctx.ast,  .code = c5.code,  .metrics = m } },
                        };
                    },
                    .failed => |f| .{ .@"error" = f.message },
                };
            }
        };
        pub const context_create_event = struct {
            pub const Input = struct {
                program_ast: *const koru_std.koru_compiler.Program,
                allocator: std.mem.Allocator,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: context_create  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:841]
                const program_ast = __koru_event_input.program_ast;
                const allocator = __koru_event_input.allocator;
                _ = &program_ast;
                _ = &allocator;
                _ = &__koru_event_input;

                    // The seed AST is deserialized from `program.ast.json` onto the compile arena
                    // in the backend's main() — it is already writable heap memory, so the
                    // metacircular pipeline's in-place mutations (`@constCast` template inline_body
                    // writes, auto-discharge binding-annotation stamps) are safe with no clone.
                    // (This is why the old rodata-SIGSEGV heap-clone hack is gone: there is no
                    // longer a `pub const PROGRAM_AST` in read-only `.rodata` to mutate.)

                    // The compilation's one reporter, minted here so every pass downstream —
                    // and every transform that declares `reporter:` — speaks through the SAME
                    // channel, bound to the user's file. The file these diagnostics render
                    // previews from is the first location the AST carries: one reporter renders
                    // one file, which is what koruc has always done — a multi-module program
                    // previews the main one only.
                    const reporter_path = blk: {
                        for (program_ast.items) |item| {
                            const file = switch (item) {
                                .flow => |f| f.location.file,
                                .proc_decl => |p| p.location.file,
                                .event_decl => |e| e.location.file,
                                else => "",
                            };
                            if (file.len > 0) break :blk file;
                        }
                        break :blk "";
                    };
                    const reporter_source = if (reporter_path.len > 0)
                        std.fs.cwd().readFileAlloc(allocator, reporter_path, 16 * 1024 * 1024) catch ""
                    else
                        "";
                    const reporter = allocator.create(ErrorReporter) catch {
                        @panic("context-create: out of memory allocating the compilation's diagnostic reporter");
                    };
                    reporter.* = ErrorReporter.init(allocator, reporter_path, reporter_source) catch {
                        @panic("context-create: could not initialise the compilation's diagnostic reporter");
                    };
                    // Continuation/source locations were recorded by the FRONTEND in its
                    // INJECTED-buffer coordinates — it auto-prepends `import std/compiler`
                    // (one line) and the frontend's own reporter knows to translate, while
                    // this backend reporter reads the user file raw. Apply the same user-source
                    // translation when the frontend injected (same condition as src/main.zig),
                    // or every continuation-located diagnostic (unknown branch, when-clause,
                    // missing input…) points one line past the arm (210_201).
                    const backend_injected = std.mem.indexOf(u8, reporter_source, "~import std/compiler") == null and
                        std.mem.indexOf(u8, reporter_source, "import std/compiler") == null;
                    if (backend_injected) reporter.setUserSource(reporter_source, 1) catch {};

                    const ctx = CompilerContext{
                        .ast = program_ast,
                        .original_ast = program_ast,  // Initially same as ast, preserved across filtering
                        .allocator = allocator,
                        .errors = std.ArrayList(CompilerError){},
                        .warnings = std.ArrayList(CompilerWarning){},
                        .error_policy = .collect_all,
                        .current_pass = "init",
                        .passes_completed = 0,
                        .tap_registry = null,
                        .reporter = reporter,
                    };
                    return ctx;

            }
        };
        pub const fold_comptime_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: fold_comptime  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:915]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    const comptime_eval = @import("comptime_eval");
                    var folder = comptime_eval.Folder.init(ctx.allocator);
                    // THE THUNK LAW: hand the walker the Stage A-generated dispatch table so
                    // interpreted comptime Koru can call the natively-compiled handlers.
                    // Same @hasDecl pattern as the comptime_main call — the table only
                    // exists when the user program has thunkable comptime tors.
                    const backend_output = @import("backend_output_emitted.zig");
                    if (@hasDecl(backend_output, "koru_comptime_thunks")) {
                        folder.setThunks(&backend_output.koru_comptime_thunks);
                    }
                    const folded = folder.fold(ctx.ast) catch {
                        log.err("comptime fold failed: {s}\n", .{folder.diag()});
                        @panic("comptime evaluation failed — see the diagnostic above");
                    };

                    var updated_ctx = ctx;
                    updated_ctx.ast = folded;
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "fold_comptime";
                    return updated_ctx;

            }
        };
        pub const elaborate_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> SUBFLOW: /Users/larsde/src/koru-cypoe/koru_std/compiler.kz:954
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;
                const result = koru_std.koru_compiler.process_ccp_commands_event.handler(.{ .ctx = ctx });
                const __thread0 = result;
                _ = &result;
                const __thread1 = koru_std.koru_compiler.resolve_with_scopes_event.handler(.{ .ctx = __thread0 });
                _ = &__thread1;
                const __thread2 = koru_std.koru_compiler.desugar_chains_event.handler(.{ .ctx = __thread1 });
                _ = &__thread2;
                const __thread3 = koru_std.koru_compiler.run_pre_transforms_event.handler(.{ .ctx = __thread2 });
                _ = &__thread3;
                const __thread4 = koru_std.koru_compiler.process_template_procs_event.handler(.{ .ctx = __thread3 });
                _ = &__thread4;
                const __thread5 = koru_std.koru_compiler.fold_comptime_event.handler(.{ .ctx = __thread4 });
                _ = &__thread5;
                const __ret0 = koru_std.koru_compiler.evaluate_comptime_event.handler(.{ .ctx = __thread5 });
                _ = &__ret0;
                return __ret0;
            }
        };
        pub const analysis_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> SUBFLOW: /Users/larsde/src/koru-cypoe/koru_std/compiler.kz:961
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;
                const result = koru_std.koru_compiler.check_release_gate_event.handler(.{ .ctx = ctx });
                return switch (result) {
                    .ctx => |__pf_t0| {
                        _ = &__pf_t0;
                        const nested_result_0 = koru_std.koru_compiler.check_structure_event.handler(.{ .ctx = __pf_t0 });
                        _ = &nested_result_0;
                        return switch (nested_result_0) {
                            .ctx => |__pf_t1| {
                                _ = &__pf_t1;
                                const nested_result_1 = koru_std.koru_compiler.check_phantom_signatures_event.handler(.{ .ctx = __pf_t1 });
                                _ = &nested_result_1;
                                return switch (nested_result_1) {
                                    .ctx => |__pf_t2| {
                                        _ = &__pf_t2;
                                        const nested_result_2 = koru_std.koru_compiler.check_phantom_args_event.handler(.{ .ctx = __pf_t2 });
                                        _ = &nested_result_2;
                                        return switch (nested_result_2) {
                                            .ctx => |__pf_t3| {
                                                _ = &__pf_t3;
                                                const nested_result_3 = koru_std.koru_compiler.pass_auto_discharge_event.handler(.{ .ctx = __pf_t3 });
                                                _ = &nested_result_3;
                                                return switch (nested_result_3) {
                                                    .ctx => |__pf_t4| {
                                                        _ = &__pf_t4;
                                                        const nested_result_4 = koru_std.koru_compiler.pass_witness_check_event.handler(.{ .ctx = __pf_t4 });
                                                        _ = &nested_result_4;
                                                        return switch (nested_result_4) {
                                                            .ctx => |__pf_t5| {
                                                                _ = &__pf_t5;
                                                                const nested_result_5 = koru_std.koru_compiler.check_flow_event.handler(.{ .ctx = __pf_t5 });
                                                                _ = &nested_result_5;
                                                                return switch (nested_result_5) {
                                                                    .ctx => |__pf_t6| {
                                                                        _ = &__pf_t6;
                                                                        const nested_result_6 = koru_std.koru_compiler.check_phantom_semantic_event.handler(.{ .ctx = __pf_t6 });
                                                                        _ = &nested_result_6;
                                                                        return switch (nested_result_6) {
                                                                            .ctx => |__pf_t7| {
                                                                                _ = &__pf_t7;
                                                                                const nested_result_7 = koru_std.koru_compiler.check_purity_event.handler(.{ .ctx = __pf_t7 });
                                                                                _ = &nested_result_7;
                                                                                return switch (nested_result_7) {
                                                                                    .ctx => |__pf_t8| .{ .ctx = __pf_t8 },
                                                                                    .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                                                                };
                                                                            },
                                                                            .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                                                        };
                                                                    },
                                                                    .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                                                };
                                                            },
                                                            .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                                        };
                                                    },
                                                    .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                                };
                                            },
                                            .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                        };
                                    },
                                    .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                                };
                            },
                            .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                        };
                    },
                    .failed => |f| .{ .failed = .{ .ctx = f.ctx,  .message = f.message } },
                };
            }
        };
        pub const transform_taps_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: transform_taps  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:978]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // Build tap registry from AST (before transformation removes taps)
                    const tap_registry_module = @import("tap_registry");
                    const registry_ptr = ctx.allocator.create(tap_registry_module.TapRegistry) catch unreachable;
                    registry_ptr.* = tap_registry_module.buildTapRegistry(
                        ctx.ast.items,
                        ctx.allocator
                    ) catch unreachable;
                    // Don't defer deinit - we need the registry to persist for emission

                    // Transform AST - insert tap invocations as regular flow code
                    const tap_transformer = @import("tap_transformer");
                    const emitter_helpers = @import("emitter_helpers");
                    const transformed_ast = tap_transformer.transformAst(
                        ctx.ast,
                        registry_ptr,
                        emitter_helpers.EmitMode.runtime_only,
                        ctx.allocator
                    ) catch unreachable;

                    // Update context with transformed AST and tap registry
                    var updated_ctx = ctx;
                    updated_ctx.ast = transformed_ast;
                    updated_ctx.tap_registry = registry_ptr;
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "transform_taps";

                    return updated_ctx;

            }
        };
        pub const test_generation_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: test_generation  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:1015]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "test_generation";

                    // Import needed modules
                    const ast_mod = @import("ast");

                    // Storage for the tests we will generate, keyed by INDEX rather than by
                    // pointer.
                    //
                    // WHY NOT POINTERS (fixed 2026-08-06): `for (slice) |item|` binds `item` BY
                    // VALUE, so `&item.flow` is the address of a loop-local copy that dies at the
                    // end of the iteration. This pass collected such addresses in one loop and
                    // compared them against freshly-taken addresses in a SECOND loop below, so the
                    // comparison could never be true. `should_replace` was structurally always
                    // false: every generated test block was built and then silently discarded, and
                    // the pass looked like it was doing nothing at all. A top-level item's index
                    // into `ast.items` is its stable identity — nothing can copy it out from under
                    // us — and pairing the index with its generated code makes the substitution
                    // order impossible to desynchronise.
                    const PendingTest = struct { idx: usize, code: ast_mod.Item };
                    var pending = std.ArrayList(PendingTest).initCapacity(mutable_ctx.allocator, 8) catch unreachable;

                    // Scan AST for test invocations
                    // A test invocation is a flow that calls the "test" tor from std.testing
                    for (mutable_ctx.ast.items, 0..) |*item, idx| {
                        if (item.* == .flow) {
                            const flow = &item.flow;
                            // Check if this is a test invocation
                            if (isTestInvocation(flow.inv())) {
                                // Found a test! Process it
                                const inline_code = processTestFlow(flow, mutable_ctx.ast, mutable_ctx.allocator);
                                if (inline_code) |code| {
                                    pending.append(mutable_ctx.allocator, .{ .idx = idx, .code = code }) catch {};
                                }
                            }
                        }
                        // Tests nested inside a `module_decl` are deliberately NOT handled here.
                        // The replacement below rebuilds only the TOP-LEVEL item list, so a
                        // module-nested flow has no slot to be substituted into. Generating code
                        // for one and dropping it is what previously let the inline-code cursor
                        // drift out of step with the replacement order — the next top-level test
                        // would then be replaced with a *different* test's block. Named as a gap
                        // rather than left half-done.
                    }

                    // If we found tests, build new AST with them replaced
                    if (pending.items.len > 0) {
                        log.verbose("[TEST-GEN] Found {} test(s) to generate\n", .{pending.items.len});

                        // Build new items array with test flows replaced by inline_codes.
                        // `pending` is populated in ascending index order by the scan above, so a
                        // single cursor walks it in step with the item list — no search, no pointer
                        // comparison, and the code that lands at an index is by construction the
                        // code generated FOR that index.
                        var new_items = std.ArrayList(ast_mod.Item).initCapacity(mutable_ctx.allocator, mutable_ctx.ast.items.len) catch unreachable;
                        var next: usize = 0;

                        for (mutable_ctx.ast.items, 0..) |item, idx| {
                            if (next < pending.items.len and pending.items[next].idx == idx) {
                                new_items.append(mutable_ctx.allocator, pending.items[next].code) catch {};
                                next += 1;
                            } else {
                                new_items.append(mutable_ctx.allocator, item) catch {};
                            }
                        }

                        // Create new Program with updated items
                        const new_program = mutable_ctx.allocator.create(ast_mod.Program) catch unreachable;
                        new_program.* = ast_mod.Program{
                            .items = new_items.items,
                            .module_annotations = mutable_ctx.ast.module_annotations,
                            .main_module_name = mutable_ctx.ast.main_module_name,
                            .allocator = mutable_ctx.allocator,
                        };
                        mutable_ctx.ast = new_program;
                    }

                    mutable_ctx.passes_completed += 1;
                    return mutable_ctx;

            }
        };
        pub const emission_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = struct { ctx: koru_std.koru_compiler.CompilerContext, code: []const u8 };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> SUBFLOW: /Users/larsde/src/koru-cypoe/koru_std/compiler.kz:1502
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;
                const result = koru_std.koru_compiler.inject_ccp_event.handler(.{ .ctx = ctx });
                const c1 = result;
                _ = &result;
                const c2 = koru_std.koru_compiler.pass_dead_strip_event.handler(.{ .ctx = c1 });
                _ = &c2;
                const c3 = koru_std.koru_compiler.emit_zig_event.handler(.{ .ctx = c2 });
                _ = &c3;
                return .{ .ctx = c3.ctx,  .code = c3.code };
            }
        };
        pub const parse_event = struct {
            pub const Input = struct {
                source: []const u8,
                module_name: []const u8,
            };
            pub const Output = union(enum(u8)) {
                parsed: []koru_std.koru_compiler.Item,
                failed: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: parse  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:1697]
                const source = __koru_event_input.source;
                const module_name = __koru_event_input.module_name;
                _ = &source;
                _ = &module_name;
                _ = &__koru_event_input;

                    const Parser = @import("parser").Parser;
                    // Note: 'std' is already imported at top level by the emitter

                    // Use a comptime-friendly allocator
                    // Note: In actual comptime context, we'd use a fixed buffer allocator
                    // For now, we use the standard allocator which works at comptime
                    var buffer: [1024 * 1024]u8 = undefined; // 1MB buffer for parsing
                    var fba = std.heap.FixedBufferAllocator.init(&buffer);
                    const allocator = fba.allocator();

                    // Initialize parser (empty compiler flags, no resolver for standalone parsing)
                    var parser = Parser.init(allocator, source, module_name, &[_][]const u8{}, null) catch {
                        return .{ .failed = "Failed to initialize parser" };
                    };
                    defer parser.deinit();

                    // Parse the source
                    const parse_result = parser.parse() catch {
                        // Try to get error details if available
                        if (parser.reporter.hasErrors()) {
                            return .{ .failed = "Parse error - see compiler output" };
                        }
                        return .{ .failed = "Failed to parse source" };
                    };

                    // Return the parsed items
                    // Note: The items are allocated in our buffer, which is stack-allocated
                    // This is fine for comptime usage where everything gets evaluated away
                    return .{ .parsed = parse_result.source_file.items };

            }
        };
        pub const emit_zig_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = struct { ctx: koru_std.koru_compiler.CompilerContext, code: []const u8 };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: emit_zig  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:1592]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // NEW VISITOR-BASED IMPLEMENTATION!
                    // Replaces the 2184-line procedural emitter with visitor orchestrator

                    // DUMP POINT 5: AST at emission entry (after all passes)
                    const backend_output = @import("backend_output_emitted.zig");
                    backend_output.dumpAST(ctx.ast, "5-emit-zig", ctx.allocator);

                    // Import libraries needed for emission
                    const emitter_lib = @import("emitter_helpers");
                    const visitor_emitter_lib = @import("visitor_emitter");
                    const tap_registry_module = @import("tap_registry");

                    // Growable emitter: generated code has no natural size ceiling (a large
                    // regex DFA alone can pass a fixed 256KB — pinned by 640_004). The buffer
                    // is heap-allocated (we return a slice into it via getOutput) and grows
                    // on demand; reads go through code_emitter.buffer, never a stale local.
                    var code_emitter = emitter_lib.CodeEmitter.initGrowable(ctx.allocator, 256 * 1024) catch unreachable;

                    // Use tap registry from context (built during transform_taps pass)
                    // If no registry exists, build one from current AST (shouldn't happen in normal flow)
                    const tap_registry = if (ctx.tap_registry) |registry|
                        registry
                    else blk: {
                        const registry_ptr = ctx.allocator.create(tap_registry_module.TapRegistry) catch unreachable;
                        registry_ptr.* = tap_registry_module.buildTapRegistry(
                            ctx.ast.items,
                            ctx.allocator
                        ) catch unreachable;
                        break :blk registry_ptr;
                    };

                    // Build type registry from ORIGINAL canonicalized AST (before filtering)
                    // The original_ast contains ALL tors (including comptime ones) so TypeRegistry has complete metadata
                    const type_registry_module = @import("type_registry");
                    var type_registry = type_registry_module.TypeRegistry.init(ctx.allocator);
                    defer type_registry.deinit();
                    type_registry.populateFromAST(ctx.original_ast.items) catch unreachable;

                    // Create visitor orchestrator with tap registry and type registry
                    // Use .runtime_only mode to emit only modules WITHOUT [comptime] annotation
                    var visitor_emitter = visitor_emitter_lib.VisitorEmitter.init(
                        ctx.allocator,
                        &code_emitter,
                        ctx.ast.items,
                        tap_registry,
                        &type_registry,
                        .runtime_only
                    );
                    visitor_emitter.library = CompilerEnv.library;

                    // Emit using visitor pattern!
                    visitor_emitter.emit(ctx.ast) catch unreachable;

                    // Get the emitted code
                    const visitor_code = code_emitter.getOutput();

                    // JS-target spike: when --lang=js, replace the visitor's Zig output with the
                    // real AST→JS emitter (src/js_emitter.zig). It walks ctx.ast and emits
                    // runnable JavaScript for the event-pump subset (tors, |js proc bodies,
                    // effect handlers, terminal branches, flows). Gated behind CompilerEnv.lang
                    // so the default Zig path is untouched. CompilerEnv is already in scope at
                    // file level in the generated backend_output_emitted.zig (re-exported pub
                    // const) — reference it directly rather than re-importing, which would
                    // shadow that declaration.
                    const final_code = if (@import("std").mem.eql(u8, CompilerEnv.lang, "js")) blk: {
                        const js_emitter = @import("js_emitter");
                        // Fail loud: a JS-emit failure must surface, not silently fall back to
                        // Zig. A refusal is a USER error — some tor has no JavaScript
                        // implementation on this target (a zig-only proc, an unmodelled
                        // construct) — so it becomes a clean, located diagnostic (the
                        // js_emitter already printed WHICH tor) and exit 1. The old
                        // std.debug.panic made every refusal read as a compiler bug: SIGABRT,
                        // a raw error name, and a backtrace that buried the reason. Pinned by
                        // 400_191_zig_only_proc_js_build_refuses.
                        break :blk js_emitter.emit(ctx.allocator, ctx.ast, CompilerEnv.library) catch |err| {
                            std.debug.print("error[KORU047]: JS emission failed: {s}\n", .{@errorName(err)});
                            std.process.exit(1);
                        };
                    } else if (@import("std").mem.eql(u8, CompilerEnv.lang, "cs")) blk: {
                        const cs_emitter = @import("cs_emitter");
                        // K# vertical spike: same fail-loud contract as the JS arm — an
                        // unmodelled construct or unlowered builtin refuses here, never
                        // falls back to the Zig visitor's output.
                        break :blk cs_emitter.emit(ctx.allocator, ctx.ast, CompilerEnv.library) catch |err| {
                            std.debug.print("error[KORU047]: CS emission failed: {s}\n", .{@errorName(err)});
                            std.process.exit(1);
                        };
                    } else if (@import("std").mem.eql(u8, CompilerEnv.lang, "c")) blk: {
                        const c_emitter = @import("c_emitter");
                        // Verification lane: same fail-loud contract — a refusal is a
                        // program outside the verified fragment, never a Zig fallback.
                        break :blk c_emitter.emit(ctx.allocator, ctx.ast, CompilerEnv.library) catch |err| {
                            std.debug.print("error[KORU047]: C emission failed: {s}\n", .{@errorName(err)});
                            std.process.exit(1);
                        };
                    } else visitor_code;

                    var updated_ctx = ctx;
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "emission";
                    return .{ .ctx = updated_ctx, .code = final_code };

            }
        };
        pub const evaluate_comptime_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: evaluate_comptime  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:1731]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // Comptime-only means "takes the compiler's own AST" — a Program param.
                    // Source/Expression carry captured text, not timing.
                    const comptime_scan = struct {
                        fn isProgramType(raw_type: []const u8) bool {
                            var t = raw_type;
                            while (true) {
                                t = std.mem.trimLeft(u8, t, " \t");
                                if (std.mem.startsWith(u8, t, "*")) {
                                    t = t[1..];
                                    continue;
                                }
                                if (std.mem.startsWith(u8, t, "const")) {
                                    t = t["const".len..];
                                    continue;
                                }
                                break;
                            }
                            return std.mem.endsWith(u8, t, "Program");
                        }

                        fn record(event_decl: anytype, qualifier: ?[]const u8, allocator: Allocator,
                                  comptime_events: *[64][]const u8, comptime_count: *usize) void {
                            // [comptime]/[norun] decls count, not Program params alone —
                            // field-keyed alone dropped std/build:config and KORU022'd its call sites.
                            const ann = @import("annotation_parser").hasPart;
                            var is_comptime = ann(event_decl.annotations, "comptime") or ann(event_decl.annotations, "norun");
                            for (event_decl.input.fields) |field| {
                                if (isProgramType(field.@"type")) { is_comptime = true; break; }
                            }
                            if (!is_comptime or comptime_count.* >= 64) return;
                            const path_str = joinPathAlloc(allocator, event_decl.path.segments);
                            const event_name = if (qualifier) |q|
                                std.fmt.allocPrint(allocator, "{s}:{s}", .{q, path_str}) catch path_str
                            else
                                path_str;
                            comptime_events[comptime_count.*] = event_name;
                            comptime_count.* += 1;
                        }

                        fn run(items: []const Item, allocator: Allocator,
                               comptime_events: *[64][]const u8, comptime_count: *usize) void {
                            for (items) |item| {
                                switch (item) {
                                    .event_decl => |event_decl| {
                                        record(event_decl, event_decl.path.module_qualifier, allocator,
                                               comptime_events, comptime_count);
                                    },
                                    .module_decl => |module| {
                                        for (module.items) |mod_item| {
                                            if (mod_item == .event_decl) {
                                                const qualifier: ?[]const u8 = if (module.logical_name.len > 0)
                                                    module.logical_name else null;
                                                record(mod_item.event_decl, qualifier, allocator,
                                                       comptime_events, comptime_count);
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    };

                    // Phase 1: Build map of comptime-only tors (Program params)
                    var comptime_events: [64][]const u8 = undefined;
                    var comptime_count: usize = 0;
                    comptime_scan.run(ctx.ast.items, ctx.allocator, &comptime_events, &comptime_count);

                    // Phase 2: Walk flows and find comptime tor invocations
                    // std.debug.print("  Phase 2: Scanning flows for comptime invocations...\n", .{});
                    for (ctx.ast.items) |item| {
                        if (item == .flow) {
                            const flow = item.flow;
                            // For module-qualified flows, include the module name: "std.build:requires"
                            const path_str = joinPathAlloc(ctx.allocator, flow.inv().path.segments);
                            const inv_path = if (flow.inv().path.module_qualifier) |mq|
                                std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{mq, path_str}) catch path_str
                            else
                                path_str;
                            // std.debug.print("    Flow invokes: {s}\n", .{inv_path});

                            // Check if this invocation is to a comptime tor
                            for (0..comptime_count) |i| {
                                if (std.mem.eql(u8, inv_path, comptime_events[i])) {
                                    // Found a comptime tor invocation!
                                    // std.debug.print("  ✓ Found comptime invocation: {s}\n", .{inv_path});

                                    // TODO: Call the comptime handler!
                                    // const handler_result = callComptimeHandler(inv_path, ctx.ast);
                                    // For now, just print that we called it
                                    // TODO: Use result to transform flow/AST
                                    // switch (handler_result) {
                                    //     .none => {
                                    //         // std.debug.print("  WARNING: Handler not found for: {s}\n", .{inv_path});
                                    //     },
                                    // }

                                    break;
                                }
                            }
                        }
                    }

                    // std.debug.print("  Detected {} comptime tors, {} invocations\n", .{comptime_count, invocations_found});

                    const backend_output = @import("backend_output_emitted.zig");

                    // Phase 2.3.5: Early comptime_main pass — registers build-time configuration
                    // (build:variants, build:config) into emitter_helpers registries so that Phase 2.4
                    // transforms can dispatch through the populated registry. Phase 2.5 runs
                    // comptime_main again for post-transform work (tap injection etc.). This
                    // double-execution is a known wart; the cleaner fix is to segregate
                    // build-config flows into a dedicated pre_transform_main() at codegen time.
                    if (@hasDecl(backend_output, "comptime_main")) {
                        log.debug("[PHASE 2.3.5] Early comptime_main() — registering build-time variants/config\n", .{});
                        _ = backend_output.comptime_main(ctx.ast, ctx.allocator);
                    }

                    // Phase 2.4: Execute transform handlers FIRST (if they exist)
                    // NOTE: Transforms run BEFORE comptime tors so that comptime tors
                    // (like tap injection) can see the fully-transformed AST
                    const transform_updated_ctx = if (@hasDecl(backend_output, "run_pass")) blk: {
                        log.debug("[PHASE 2.4] Calling run_pass for transforms\\n", .{});

                        // DUMP POINT 3: AST before transform handlers
                        backend_output.dumpAST(ctx.ast, "3-pre-transform", ctx.allocator);

                        // The ctx handed to the transforms is the one this block returns, so
                        // anything a transform records on it survives the call.
                        var transform_ctx = ctx;

                        const post_transform_ast = backend_output.run_pass("transform", ctx.ast, ctx.allocator, @ptrCast(&transform_ctx)) catch |err| {
                            if (err == error.TransformContinuationPositionUnsupported or
                                err == error.TransformBlastRadiusExceeded or
                                err == error.TransformAccountingFailed) {
                                // The runner already emitted a located error[KORU124] /
                                // error[KORU181] koru diagnostic. This proc returns a ctx (no
                                // clean error channel), so stop the pipeline cleanly rather
                                // than leaking the ICE-shaped @panic + host stack trace.
                                std.process.exit(1);
                            }
                            // Transforms either complete or fail loudly. Continuing with the
                            // untransformed AST used to mask the failure behind a cascade of
                            // downstream KORU021/022 errors about tors the transform should
                            // have rewritten away.
                            log.err("FATAL: transform pass failed ({s}). The pipeline cannot continue with a partially-transformed AST.\n", .{@errorName(err)});
                            @panic("transform pass failed — see error above");
                        };

                        // A transform that spoke through the compilation's reporter has said
                        // something a later pass must not talk over. Drain HERE, at the end of
                        // the phase that produced it: a store declaring an undrainable column
                        // is a fact about the DECLARATION, and letting the pipeline run on
                        // means the analysis passes report the consequences instead — the
                        // author gets KORU030 at a call site that is perfectly fine, and the
                        // sentence naming the real fix is never reached at all.
                        if (ctx.reporter) |rep| {
                            if (rep.hasErrors()) {
                                rep.printErrors(@import("errors").FileSink.stderr()) catch {};
                                std.process.exit(1);
                            }
                        }

                        // DUMP POINT 4: AST after transform handlers
                        backend_output.dumpAST(post_transform_ast, "4-post-transform", ctx.allocator);

                        const post_transform_weld = @import("post_transform_weld");
                        post_transform_weld.weldAfterTransform(@constCast(post_transform_ast), ctx.allocator) catch |err| {
                            log.err("FATAL: post-transform import weld failed ({s}).\n", .{@errorName(err)});
                            @panic("post-transform import weld failed — see error above");
                        };

                        transform_ctx.ast = post_transform_ast;
                        break :blk transform_ctx;
                    } else ctx;

                    // Phase 2.5: Execute comptime flows AFTER transforms (if they exist)
                    // comptime_main() calls all comptime_flowN() functions at Zig RUNTIME (when ./backend runs)
                    // Now sees the transformed AST, enabling comptime tors to do post-transform work
                    // Returns *const Program — comptime flows may modify the AST
                    const comptime_updated_ctx = if (@hasDecl(backend_output, "comptime_main")) blk: {
                        log.debug("[PHASE 2.5] Executing comptime_main() - running comptime flows\n", .{});
                        const post_comptime_ast = backend_output.comptime_main(transform_updated_ctx.ast, transform_updated_ctx.allocator);
                        log.debug("[PHASE 2.5] Comptime flows complete ({} items)\n", .{post_comptime_ast.items.len});
                        var comptime_ctx = transform_updated_ctx;
                        comptime_ctx.ast = post_comptime_ast;
                        break :blk comptime_ctx;
                    } else transform_updated_ctx;

                    // Phase 2.6: Rebuild comptime_events list from transformed AST
                    // Transforms may have added/removed tors, so we need to rescan
                    log.debug("[PHASE 2.6] Rescanning transformed AST ({} items)\n", .{comptime_updated_ctx.ast.items.len});
                    comptime_count = 0;  // Reset counter
                    comptime_scan.run(comptime_updated_ctx.ast.items, ctx.allocator, &comptime_events, &comptime_count);
                    log.debug("[PHASE 2.6] Rescan complete: {} comptime events found\n", .{comptime_count});
                    for (0..comptime_count) |i| {
                        log.debug("  [{}] {s}\n", .{i, comptime_events[i]});
                    }

                    // Phase 3: Build new AST without comptime flows, procs, and modules (AST TRANSFORMATION!)
                    // Count non-comptime items first
                    var count_non_comptime: usize = 0;
                    for (comptime_updated_ctx.ast.items) |item| {
                        var should_keep = true;
                        if (item == .flow) {
                            const flow = item.flow;
                            // For module-qualified flows, include the module name: "std.build:requires"
                            const path_str = joinPathAlloc(ctx.allocator, flow.inv().path.segments);
                            const inv_path = if (flow.inv().path.module_qualifier) |mq|
                                std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{mq, path_str}) catch path_str
                            else
                                path_str;

                            // Check if comptime flow
                            for (0..comptime_count) |i| {
                                if (std.mem.eql(u8, inv_path, comptime_events[i])) {
                                    var transformed = false;
                                    if (flow.inline_body != null or flow.preamble_code != null) {
                                        transformed = true;
                                    } else {
                                        for (flow.inv().marks) |mark| {
                                            if (std.mem.eql(u8, mark, "@pass_ran(\"transform\")")) {
                                                transformed = true;
                                                break;
                                            }
                                        }
                                    }
                                    if (!transformed) {
                                        should_keep = false;
                                    }
                                    break;
                                }
                            }
                        }

                        // Filter out comptime procs (they were already executed)
                        // Note: [raw] annotation only affects emission style, not filtering
                        if (item == .proc_decl) {
                            const proc = item.proc_decl;

                            // Check if this proc is comptime (in comptime_events list)
                            const proc_path_str = joinPathAlloc(ctx.allocator, proc.path.segments);
                            const proc_path = if (proc.path.module_qualifier) |mq|
                                std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{mq, proc_path_str}) catch proc_path_str
                            else
                                proc_path_str;
                            for (0..comptime_count) |i| {
                                if (std.mem.eql(u8, proc_path, comptime_events[i])) {
                                    // This is a comptime proc - filter it out (already executed)
                                    should_keep = false;
                                    break;
                                }
                            }
                        }

                        // NOTE: Don't filter modules based on [comptime] annotation here.
                        // Modules with [comptime] may contain [runtime] tors that need to be emitted.
                        // The visitor_emitter handles this correctly by checking if the module contains
                        // any emittable items before filtering the module itself.

                        if (should_keep) {
                            count_non_comptime += 1;
                        }
                    }

                    // Build new array with exact size (now allocated at runtime)
                    const new_items = ctx.allocator.alloc(Item, count_non_comptime) catch {
                        // Allocation failed - return original AST unchanged
                        return ctx;
                    };
                    var idx: usize = 0;
                    for (comptime_updated_ctx.ast.items) |item| {
                        var should_keep = true;
                        if (item == .flow) {
                            const flow = item.flow;
                            // For module-qualified flows, include the module name: "std.build:requires"
                            const path_str2 = joinPathAlloc(ctx.allocator, flow.inv().path.segments);
                            const inv_path = if (flow.inv().path.module_qualifier) |mq|
                                std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{mq, path_str2}) catch path_str2
                            else
                                path_str2;

                            // Check if comptime flow
                            for (0..comptime_count) |i| {
                                if (std.mem.eql(u8, inv_path, comptime_events[i])) {
                                    var transformed = false;
                                    if (flow.inline_body != null or flow.preamble_code != null) {
                                        transformed = true;
                                    } else {
                                        for (flow.inv().marks) |mark| {
                                            if (std.mem.eql(u8, mark, "@pass_ran(\"transform\")")) {
                                                transformed = true;
                                                break;
                                            }
                                        }
                                    }
                                    if (!transformed) {
                                        should_keep = false;
                                    }
                                    break;
                                }
                            }
                        }

                        // Filter out comptime procs (they were already executed)
                        // Note: [raw] annotation only affects emission style, not filtering
                        if (item == .proc_decl) {
                            const proc = item.proc_decl;

                            // Check if this proc is comptime (in comptime_events list)
                            const proc_path_str = joinPathAlloc(ctx.allocator, proc.path.segments);
                            const proc_path = if (proc.path.module_qualifier) |mq|
                                std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{mq, proc_path_str}) catch proc_path_str
                            else
                                proc_path_str;
                            for (0..comptime_count) |i| {
                                if (std.mem.eql(u8, proc_path, comptime_events[i])) {
                                    // This is a comptime proc - filter it out (already executed)
                                    should_keep = false;
                                    break;
                                }
                            }
                        }

                        // NOTE: Don't filter modules based on [comptime] annotation here.
                        // Modules with [comptime] may contain [runtime] tors that need to be emitted.
                        // The visitor_emitter handles this correctly by checking if the module contains
                        // any emittable items before filtering the module itself.

                        if (should_keep) {
                            new_items[idx] = item;
                            idx += 1;
                        }
                    }

                    const transformed_ast = ctx.allocator.create(Program) catch {
                        // Allocation failed - return original AST unchanged
                        return ctx;
                    };
                    transformed_ast.* = Program{
                        .items = new_items,
                        .module_annotations = ctx.ast.module_annotations,
                        .main_module_name = ctx.ast.main_module_name,
                        .allocator = ctx.allocator,
                    };

                    // Update context with transformed AST
                    // IMPORTANT: Keep original_ast unchanged - it preserves comptime tor metadata!
                    var updated_ctx = ctx;
                    updated_ctx.ast = transformed_ast;  // Filtered AST for emission
                    // updated_ctx.original_ast stays the same - unfiltered AST for TypeRegistry
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "evaluate_comptime";

                    return updated_ctx;

            }
        };
        pub const check_release_gate_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_release_gate  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2095]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_release_gate";

                    // Only release builds gate. Dev builds allow [prototype].
                    if (!CompilerEnv.hasFlag("release")) {
                        return .{ .ctx = mutable_ctx };
                    }

                    const release_gate = @import("release_gate");

                    // THE COMPILATION'S reporter, bound to the user's file AND source at
                    // context-create. Minting one here as `init(alloc, "release_gate", "")` put
                    // the PASS NAME where the filename goes and left no source to render a
                    // snippet from, so KORU029 could only ever point at `release_gate:<line>`.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("check-release-gate: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    var gate = release_gate.ReleaseGate.init(reporter);
                    gate.check(mutable_ctx.ast) catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        const err_msg = switch (err) {
                            error.ReleaseRejectsPrototype => "prototype module rejected in release build",
                            else => "release gate error",
                        };

                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const check_structure_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_structure  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2135]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // Need mutable ctx to append errors
                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_structure";

                    // Surface any diagnostics an ELABORATION pass already recorded (name resolution
                    // has no `.failed` arm of its own — `resolve-with-scopes` reports the KORU140
                    // `[with]` pick-wall into ctx.errors, and analysis is the first boundary that
                    // can halt cleanly). Print and fail BEFORE structural checking, so the real
                    // diagnostic wins instead of a downstream "unknown tor" for the name
                    // elaboration deliberately left unresolved.
                    if (mutable_ctx.errors.items.len > 0) {
                        for (mutable_ctx.errors.items) |e| {
                            std.debug.print("{s}\n  --> {s}:{}:{}\n\n", .{
                                e.message,
                                e.location.file,
                                e.location.line,
                                e.location.column,
                            });
                        }
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = mutable_ctx.errors.items[0].message } };
                    }

                    // Use the Zig shape_checker library for structural validation
                    const shape_checker = @import("shape_checker");

                    // THE COMPILATION'S reporter, bound to the user's file AND source at
                    // context-create. Minting one here as `init(alloc, "structural_check", "")`
                    // put the PASS NAME where the filename goes and left no source to render a
                    // snippet from — the whole KORU021/022/028/102/130/131 family could only
                    // ever point at `structural_check:<line>`.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("check-structure: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    // Create shape checker
                    var checker = shape_checker.ShapeChecker.init(
                        ctx.allocator,
                        reporter
                    ) catch {
                        // Report error to context
                        mutable_ctx.errors.append(mutable_ctx.allocator, .{
                            .message = "Failed to initialize shape checker",
                            .location = .{ .file = "compiler", .line = 0, .column = 0 },
                        }) catch {};
                        return .{ .ctx = mutable_ctx };
                    };
                    defer checker.deinit();

                    // [prototype]: relax required terminal-branch exhaustiveness so unhandled
                    // `|` branches become synthesized @panic holes (see ShapeChecker.prototype_mode).
                    for (mutable_ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "prototype")) {
                            checker.prototype_mode = true;
                        }
                    }

                    // Run structural validation
                    checker.checkSourceFile(mutable_ctx.ast) catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        // Generate error message based on error type
                        const err_msg = switch (err) {
                            error.UnknownEvent => "Unknown tor referenced",
                            error.IncompleteBranchCoverage => "Incomplete branch coverage",
                            error.ProcWithoutEvent => "Proc without matching event",
                            error.SubflowWithoutEvent => "Subflow without matching event",
                            error.DuplicateBranchHandler => "Duplicate branch handler at same indentation level",
                            error.ValidationFailed => "Validation failed (see errors above)",
                            error.InvalidPath => "Invalid path",
                            error.DuplicateLabel => "Duplicate label defined",
                            error.UnknownLabel => "Unknown label referenced",
                            error.DeprecatedInlineFlowPath => "Deprecated inline flow path",
                            error.LabelRequiresParameters => "Label requires parameters",
                            error.LabelDoesNotAcceptParameters => "Label does not accept parameters",
                            error.InvalidBranchConstructor => "Invalid branch constructor",
                            else => "Structural validation failed (unknown error)",
                        };

                        // Return failed branch - stops the pipeline!
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    // Validation succeeded
                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const check_flow_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_flow  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2230]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // Need mutable ctx to append errors
                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_flow";

                    // Use the Zig flow_checker library for flow validation
                    const flow_checker = @import("flow_checker");

                    // THE COMPILATION'S reporter, bound to the user's file AND source at
                    // context-create. Minting one here as `init(alloc, "flow_check", "")` put
                    // the PASS NAME where the filename goes and left no source to render a
                    // snippet from — a when-clause exhaustiveness rejection could only ever
                    // point at `flow_check:<line>`.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("check-flow: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    // Create flow checker
                    var checker = flow_checker.FlowChecker.init(
                        ctx.allocator,
                        reporter
                    ) catch {
                        // Report error to context
                        mutable_ctx.errors.append(mutable_ctx.allocator, .{
                            .message = "Failed to initialize flow checker",
                            .location = .{ .file = "compiler", .line = 0, .column = 0 },
                        }) catch {};
                        return .{ .ctx = mutable_ctx };
                    };
                    defer checker.deinit();

                    // [prototype]: relax required terminal-branch exhaustiveness (see
                    // FlowChecker.prototype_mode). Consistent with check-structure; by this pass
                    // the auto-discharge synthesis has usually already filled the hole arm.
                    for (mutable_ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "prototype")) {
                            checker.prototype_mode = true;
                        }
                    }

                    // Run flow validation
                    checker.checkSourceFile(mutable_ctx.ast) catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        // Generate error message based on error type
                        const err_msg = switch (err) {
                            error.FlowValidationFailed => "Flow validation failed",
                            error.DuplicateBranchHandler => "Duplicate branch handler at same indentation level",
                            else => "Flow validation error",
                        };

                        // Return failed branch - stops the pipeline!
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    // Validation succeeded
                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const check_phantom_signatures_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_phantom_signatures  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2302]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_phantom_signatures";

                    const phantom_semantic_checker = @import("phantom_semantic_checker");

                    // THE COMPILATION'S reporter, bound to the user's file AND source at
                    // context-create. Minting one here as
                    // `init(alloc, "phantom_signature_check", "")` put the PASS NAME where the
                    // filename goes and left no source to render a snippet from — an illegal
                    // polarity on an tor's own signature (KORU033/KORU040) could only ever
                    // point at `phantom_signature_check:<line>`.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("check-phantom-signatures: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    // Create phantom semantic checker (signature-only entry point)
                    var checker = phantom_semantic_checker.PhantomSemanticChecker.init(
                        ctx.allocator,
                        reporter
                    ) catch {
                        mutable_ctx.errors.append(mutable_ctx.allocator, .{
                            .message = "Failed to initialize phantom semantic checker",
                            .location = .{ .file = "compiler", .line = 0, .column = 0 },
                        }) catch {};
                        return .{ .ctx = mutable_ctx };
                    };
                    defer checker.deinit();

                    // Run signature validation only — no obligation-flow analysis here
                    checker.checkSignatures(mutable_ctx.ast) catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        // Generic phantom-checker banner — identical to check-phantom-semantic's.
                        // Both passes drive the SAME PhantomSemanticChecker library; the specific
                        // KORU0xx line above carries the real diagnostic (330_034 pins KORU040).
                        // The banner rides the .failed branch and reaches stderr only when no
                        // located diagnostic printed — diagnostics_were_printed gates the
                        // coordination echo (errors.zig).
                        const err_msg = switch (err) {
                            error.ValidationFailed => "Phantom semantic validation failed",
                            else => "Phantom semantic validation error",
                        };

                        // Return failed branch - stops the pipeline!
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const check_phantom_args_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_phantom_args  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2365]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_phantom_args";

                    const phantom_semantic_checker = @import("phantom_semantic_checker");

                    // THE COMPILATION'S reporter, minted at context-create and bound to the
                    // user's file AND source. This pass used to mint its own as
                    // `init(alloc, "phantom_args_check", "")` — the pass name where the FILENAME
                    // goes and no source at all, which is why its KORU030 rendered as
                    // `--> phantom_args_check:72:0` with no line and no snippet the author could
                    // act on. The location on the node was fine the whole time; the reporter had
                    // no file to resolve it against.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("check-phantom-args: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    // Create phantom semantic checker (argument-only entry point)
                    var checker = phantom_semantic_checker.PhantomSemanticChecker.init(
                        ctx.allocator,
                        reporter
                    ) catch {
                        mutable_ctx.errors.append(mutable_ctx.allocator, .{
                            .message = "Failed to initialize phantom semantic checker",
                            .location = .{ .file = "compiler", .line = 0, .column = 0 },
                        }) catch {};
                        return .{ .ctx = mutable_ctx };
                    };
                    defer checker.deinit();

                    // [prototype]: same relaxation as check-phantom-semantic (400_165) — the
                    // argument slice walks the same continuations, so the same doodle arms
                    // must slide here too.
                    for (mutable_ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "prototype")) {
                            checker.prototype_mode = true;
                        }
                    }

                    // Run argument-located validation only — no exit-balance walls here
                    checker.checkArguments(mutable_ctx.ast, mutable_ctx.original_ast) catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview. Hand-formatting here is what made this pass's
                        // diagnostics render plainer than every other pass's.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        // Generic phantom-checker banner — identical to check-phantom-semantic's.
                        // All three phantom passes drive the SAME PhantomSemanticChecker library;
                        // the specific KORU0xx line above carries the real diagnostic (see the
                        // banner-parity note in check-phantom-signatures, 330_034).
                        const err_msg = switch (err) {
                            error.ValidationFailed => "Phantom semantic validation failed",
                            else => "Phantom semantic validation error",
                        };

                        // Return failed branch - stops the pipeline!
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const pass_auto_discharge_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: pass_auto_discharge  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2444]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // Check if auto-discharge is disabled entirely. Disabling means "do not
                    // INSERT disposal calls — let phantom errors fire"; it never means the
                    // discard shapes go invisible. The pass still runs in normalize-only mode
                    // below so an obligation-carrying bare call (`open()` discarding a
                    // `-> T<state!>` return) is materialized into its explicit `: _ |> _`
                    // form and the phantom checker can fire KORU030 on the leak.
                    const insertion_disabled = CompilerEnv.hasFlag("auto-discharge=disable");

                    // Honor the `strict` module-level convention.
                    // `strict` is an opaque annotation word, not a fixed semantics: each pass
                    // that cares reads it and renders it into its own domain. For auto-discharge,
                    // strict means "do not guess the single cleanup — require it explicitly",
                    // so a module marked [strict] opts out of insertion and the phantom checker
                    // fires KORU030 for any undischarged obligation. Other passes (ours and
                    // third-party) may read the same word and honor it in their own lane.
                    var strict_module = false;
                    for (ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "strict")) {
                            strict_module = true;
                        }
                    }

                    // Check if warnings are enabled for auto-discharge
                    const warn_mode = CompilerEnv.hasFlag("auto-discharge=warn");

                    // Crash-surface map (strict mode): --panic-branches=strict makes every
                    // unhandled panic branch (| ?!...) a compile error (KORU022), enumerating
                    // where the program can crash on a rare failure. Dev build (flag off) stays
                    // silent — the synthesized @panic is still there at runtime; production/audit
                    // build (flag on) blocks compilation until each is handled or explicitly
                    // muted (`| <name> _ |> ...`). Same source, flag flips it.
                    const strict_panic_branches = CompilerEnv.hasFlag("panic-branches=strict");

                    // `[prototype]`: module opt-in to compile-and-run INCOMPLETE. An unhandled
                    // required TERMINAL branch becomes a synthesized @panic hole (same body as
                    // an unhandled `| ?!`) instead of a KORU022 exhaustiveness error — so a
                    // half-shaped program runs its built paths now and crashes loudly at a hole.
                    // Read like `strict` (an opaque module-annotation word), but it does NOT
                    // early-return: the pass runs WITH the flag so synthesis fills the holes.
                    // Never leaks to production — without the annotation this stays false and
                    // exhaustiveness is enforced.
                    var prototype_mode = false;
                    for (ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "prototype")) {
                            prototype_mode = true;
                        }
                    }

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "auto_discharge";

                    const auto_discharge_inserter = @import("auto_discharge_inserter");

                    // THE COMPILATION'S reporter, bound to the user's file AND source at
                    // context-create. Minting one here as `init(alloc, "auto_discharge", "")`
                    // put the PASS NAME where the filename goes and left no source to render a
                    // snippet from — "Resource 'x' obligation was not discharged", the single
                    // most common obligation diagnostic, could only ever point at
                    // `auto_discharge:<line>`. The inserter also renders through this reporter
                    // itself (auto_discharge_inserter.zig:787, :834), so those paths gain the
                    // file and the snippet with it.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("insert-auto-discharge: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    var inserter = auto_discharge_inserter.AutoDischargeInserter.init(
                        ctx.allocator, reporter, warn_mode, strict_panic_branches, prototype_mode,
                        CompilerEnv.lang,
                    ) catch {
                        mutable_ctx.errors.append(mutable_ctx.allocator, .{
                            .message = "Failed to initialize auto-discharge inserter",
                            .location = .{ .file = "compiler", .line = 0, .column = 0 },
                        }) catch {};
                        return .{ .ctx = mutable_ctx };
                    };
                    defer inserter.deinit();

                    // Run the pass - may modify AST. Insertion opted out (flag or [strict])
                    // still normalizes head discards so downstream enforcement sees them.
                    const run_result = if (insertion_disabled or strict_module)
                        inserter.runNormalizeOnly(mutable_ctx.ast)
                    else
                        inserter.run(mutable_ctx.ast);
                    const new_ast = run_result catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview. This is the ONLY render for most of the
                        // inserter's failure paths (auto_discharge_inserter.zig:1178, :1764,
                        // :2123, :2267, :2397, :3852 all return without printing). The gates
                        // that DO print for themselves (the hasErrors bail-outs in run() and
                        // runNormalizeOnly()) do NOT double up: printErrors carries a
                        // printed-count watermark, so this call emits only diagnostics no
                        // earlier render has shown.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        const err_msg = switch (err) {
                            error.ValidationFailed => "Auto-discharge failed (multiple disposal options or no disposal event)",
                            else => "Auto-discharge pass error",
                        };

                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    // Update AST with potentially modified version
                    mutable_ctx.ast = new_ast;
                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const check_phantom_semantic_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_phantom_semantic  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2558]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    log.debug("\n[PHANTOM-KORU] Starting phantom check proc...\n", .{});
                    // Need mutable ctx to append errors
                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_phantom";

                    // Use the Zig phantom_semantic_checker library for phantom state validation
                    const phantom_semantic_checker = @import("phantom_semantic_checker");

                    // THE COMPILATION'S reporter, bound to the user's file AND source at
                    // context-create. Minting one here as
                    // `init(alloc, "phantom_semantic_check", "")` put the PASS NAME where the
                    // filename goes and left no source to render a snippet from — the flow-exit
                    // obligation-balance walls, the diagnostics an author most needs to act on,
                    // could only ever point at `phantom_semantic_check:<line>`.
                    const reporter = mutable_ctx.reporter orelse {
                        @panic("check-phantom-semantic: the compilation carries no diagnostic reporter");
                    };
                    // Only diagnostics THIS pass adds — the compilation's reporter accumulates,
                    // so a later pass must not re-report an earlier one's errors.
                    const err_base = reporter.errors.items.len;

                    // Create phantom semantic checker
                    var checker = phantom_semantic_checker.PhantomSemanticChecker.init(
                        ctx.allocator,
                        reporter
                    ) catch {
                        // Report error to context
                        mutable_ctx.errors.append(mutable_ctx.allocator, .{
                            .message = "Failed to initialize phantom semantic checker",
                            .location = .{ .file = "compiler", .line = 0, .column = 0 },
                        }) catch {};
                        return .{ .ctx = mutable_ctx };
                    };
                    defer checker.deinit();

                    // [prototype]: relax the "handled a branch the tor doesn't produce" wall
                    // (KORU030) for terminal continuations — the doodle where handler arms lead
                    // the declaration (see PhantomSemanticChecker.prototype_mode, 400_165).
                    // Consistent with check-structure / check-flow.
                    for (mutable_ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "prototype")) {
                            checker.prototype_mode = true;
                        }
                    }

                    // Run phantom semantic validation
                    checker.check(mutable_ctx.ast, mutable_ctx.original_ast) catch |err| {
                        // Render through the reporter itself — it owns the code frame, the hint
                        // and the source preview.
                        drainReporter(reporter, &mutable_ctx, err_base);

                        // Generate error message based on error type
                        const err_msg = switch (err) {
                            error.ValidationFailed => "Phantom semantic validation failed",
                            else => "Phantom semantic validation error",
                        };

                        // Return failed branch - stops the pipeline!
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = err_msg } };
                    };

                    // Validation succeeded
                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const check_purity_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: check_purity  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2627]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "check_purity";

                    // Purity is determined by [pure] annotation only
                    // We don't analyze host (Zig) code - if you say it's pure, we trust you

                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const pass_dead_strip_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: pass_dead_strip  [/Users/larsde/src/koru-cypoe/koru_std/compiler.kz:2641]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "dead_strip";

                    const dead_strip = @import("dead_strip");

                    var pass = dead_strip.DeadStripPass.init(ctx.allocator);
                    defer pass.deinit();
                    // A library keeps its exports; a program keeps what it calls. The flag
                    // rides CompilerEnv for the same reason `lang` does — this pass runs
                    // across the metacircular boundary and sees per-user state only there.
                    pass.library_roots = CompilerEnv.library;

                    const new_ast = pass.run(mutable_ctx.ast, mutable_ctx.original_ast) catch {
                        return mutable_ctx;
                    };

                    mutable_ctx.ast = new_ast;
                    mutable_ctx.passes_completed += 1;
                    return mutable_ctx;

            }
        };
        pub const inject_ccp_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: inject_ccp  [/Users/larsde/src/koru-cypoe/koru_std/compiler.ccp.kz:7]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // Inject CCP observability helpers as self-contained Zig code
                    // Uses __ccp_std local import to avoid namespace pollution

                    // CCP is a self-governing feature that requires BOTH:
                    // 1. User imports std/ccp (declares intent to use CCP)
                    // 2. Compiler flag --ccp is set (enables CCP infrastructure)
                    // This pattern allows features to exist in AST but remain dormant without flags

                    // TODO: CCP feature is disabled until CompilerEnv is implemented
                    // This would inject observability helpers when --ccp flag is set
                    var updated_ctx = ctx;
                    updated_ctx.passes_completed += 1;
                    return updated_ctx;

            }
        };
        pub const has_flag_event = struct {
            pub const Input = struct {
                flag: []const u8,
            };
            pub const Output = bool;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: has_flag  [/Users/larsde/src/koru-cypoe/koru_std/compiler.flags.kz:4]
                const flag = __koru_event_input.flag;
                _ = &flag;
                _ = &__koru_event_input;

                    return CompilerEnv.hasFlag(flag);

            }
        };
        pub const branch_event = struct {
            pub const Input = struct {
                cond: bool,
            };
            pub const Output = union(enum(u8)) {
                yes: struct {
                },
                no: struct {
                },
            };
            pub inline fn handler(__koru_event_input: @This().Input) @This().Output {
                return __koru_handler_impl(__koru_event_input.cond);
            }
            fn __koru_handler_impl(__koru_p_0: bool) @This().Output {
                const __koru_event_input: @This().Input = .{ .cond = __koru_p_0 };
                // >>> PROC: branch  [/Users/larsde/src/koru-cypoe/koru_std/compiler.control.kz:14]
                const cond = __koru_event_input.cond;
                _ = &cond;
                _ = &__koru_event_input;

                    if (cond) {
                        return .{ .yes = .{} };
                    }
                    return .{ .no = .{} };

            }
        };
        pub const metrics_format_event = struct {
            pub const Input = struct {
                passes_completed: u32,
                allocator: std.mem.Allocator,
            };
            pub const Output = []const u8;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: metrics_format  [/Users/larsde/src/koru-cypoe/koru_std/compiler.control.kz:24]
                const passes_completed = __koru_event_input.passes_completed;
                const allocator = __koru_event_input.allocator;
                _ = &passes_completed;
                _ = &allocator;
                _ = &__koru_event_input;

                    const metrics = std.fmt.allocPrint(
                        allocator,
                        "Passes: {d} (flow-based: elaborate, analysis, emission)",
                        .{passes_completed}
                    ) catch "Passes: <unknown> (flow-based: elaborate, analysis, emission)";
                    return metrics;

            }
        };
        pub const ast_dump_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
                flag: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: ast_dump  [/Users/larsde/src/koru-cypoe/koru_std/compiler.dump.kz:14]
                const ctx = __koru_event_input.ctx;
                const flag = __koru_event_input.flag;
                _ = &ctx;
                _ = &flag;
                _ = &__koru_event_input;

                    // Serialize AST to JSON
                    const ast_serializer = @import("ast_serializer");
                    var serializer = ast_serializer.AstSerializer.init(ctx.allocator) catch unreachable;
                    defer serializer.deinit();

                    const json_output = serializer.serializeToJson(ctx.ast) catch unreachable;

                    // Print to stderr with separator showing which dump this is
                    std.debug.print("=== AST DUMP: {s} ===\n{s}\n", .{flag, json_output});

            }
        };
        pub const requires_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const use_event = struct {
            pub const Input = struct {
                expr: []const u8,
                hash: ?[]const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const process_template_procs_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: process_template_procs  [/Users/larsde/src/koru-cypoe/koru_std/compiler.stages.kz:16]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    const tp = @import("template_processor");
                    // Thread the build language into the per-call template pass. Per-call
                    // (`[template]`) procs are spliced inline HERE, upstream of the emitter's
                    // variant pick — so the renderer, not the emitter, must select the
                    // `|zig` vs `|js` body. CompilerEnv.lang is the user's `--lang` flag
                    // ("zig" default, "js" for JS builds), globally available in the backend.
                    tp.processTemplateProcs(ctx.ast, ctx.allocator, CompilerEnv.lang) catch unreachable;

                    var updated_ctx = ctx;
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "process_template_procs";
                    return updated_ctx;

            }
        };
        pub const run_pre_transforms_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: run_pre_transforms  [/Users/larsde/src/koru-cypoe/koru_std/compiler.prelate.kz:12]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    const backend_output = @import("backend_output_emitted.zig");
                    var updated_ctx = ctx;
                    if (@hasDecl(backend_output, "run_pass")) {
                        const runStage = struct {
                            // evaluate/run-pre have no clean error channel (they return a
                            // ctx), so stop the pipeline cleanly rather than leaking the
                            // ICE-shaped @panic + host stack trace.
                            fn call(stage: []const u8, p: *const @import("ast").Program, a: std.mem.Allocator, c: anytype) *@import("ast").Program {
                                const bo = @import("backend_output_emitted.zig");
                                return bo.run_pass(stage, p, a, @ptrCast(c)) catch |err| {
                                    if (err == error.TransformContinuationPositionUnsupported) std.process.exit(1);
                                    log.err("FATAL: {s}-stage transform pass failed ({s}). The pipeline cannot continue with a partially-transformed AST.\n", .{ stage, @errorName(err) });
                                    @panic("transform pass failed — see error above");
                                };
                            }
                        }.call;
                        updated_ctx.ast = runStage("pre", ctx.ast, ctx.allocator, &updated_ctx);
                        updated_ctx.ast = runStage("pre_late", updated_ctx.ast, ctx.allocator, &updated_ctx);
                    }
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "run_pre_transforms";
                    return updated_ctx;

            }
        };
        pub const resolve_with_scopes_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: resolve_with_scopes  [/Users/larsde/src/koru-cypoe/koru_std/compiler.with.kz:26]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    const ast_mod = @import("ast");
                    const main_mod = ctx.ast.main_module_name;
                    const alloc = ctx.allocator;

                    var updated_ctx = ctx;

                    const S = struct {
                        // Build a set of "module\x00event" keys from every event_decl (recursing
                        // module_decls). Collected from original_ast — the unfiltered AST — so the
                        // membership check is complete regardless of emit-mode filtering.
                        fn collect(items: []const ast_mod.Item, set: *std.StringHashMap(void), a: std.mem.Allocator) void {
                            for (items) |*item| {
                                switch (item.*) {
                                    .event_decl => |*e| {
                                        if (e.path.segments.len == 0) continue;
                                        const mq = e.path.module_qualifier orelse continue;
                                        const name = std.mem.join(a, ".", e.path.segments) catch continue;
                                        const key = std.fmt.allocPrint(a, "{s}\x00{s}", .{ mq, name }) catch continue;
                                        set.put(key, {}) catch {};
                                    },
                                    .module_decl => |*m| collect(m.items, set, a),
                                    else => {},
                                }
                            }
                        }

                        // The set of module names this program actually imported — what a
                        // `with(...)` argument is allowed to name (KORU142).
                        fn collectModules(items: []const ast_mod.Item, set: *std.StringHashMap(void), a: std.mem.Allocator) void {
                            for (items) |*item| {
                                switch (item.*) {
                                    .module_decl => |*m| {
                                        set.put(m.logical_name, {}) catch {};
                                        collectModules(m.items, set, a);
                                    },
                                    else => {},
                                }
                            }
                        }

                        fn has(set: *std.StringHashMap(void), mod: []const u8, seg: []const u8, a: std.mem.Allocator) bool {
                            const key = std.fmt.allocPrint(a, "{s}\x00{s}", .{ mod, seg }) catch return false;
                            defer a.free(key);
                            return set.contains(key);
                        }

                        const WithKind = union(enum) {
                            none,
                            derive, // bare `[with]` — the vocabulary is the annotated call's module
                            explicit: []const u8, // `[with(a, b)]` — the arg list IS the open set
                        };

                        // `with` alone derives; `with(a, b)` declares. Args are module paths
                        // spelled exactly as `import` writes them, comma-separated like any
                        // argument list — `|` separates annotations, never arguments.
                        fn withKind(ann: []const u8) WithKind {
                            if (std.mem.eql(u8, ann, "with")) return .derive;
                            if (ann.len > 6 and std.mem.startsWith(u8, ann, "with(") and ann[ann.len - 1] == ')')
                                return .{ .explicit = ann[5 .. ann.len - 1] };
                            return .none;
                        }

                        // A `with(...)` argument names a module this file imported — the
                        // annotation abbreviates a declared dependency, it never creates one.
                        // An arg matching no module_decl in the program is KORU142.
                        fn addExplicit(args: []const u8, targets: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), mods: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            var it = std.mem.splitScalar(u8, args, ',');
                            while (it.next()) |raw| {
                                const spelled = std.mem.trim(u8, raw, " \t");
                                if (spelled.len == 0) continue;
                                const dotted = std.mem.replaceOwned(u8, a, spelled, "/", ".") catch continue;
                                if (!mods.contains(dotted)) {
                                    const msg = std.fmt.allocPrint(a, "error[KORU142]: [with] module '{s}' is not imported — the annotation abbreviates a dependency this file declares; write 'import {s}' to declare it", .{ spelled, spelled }) catch continue;
                                    errs.append(a, .{ .message = msg, .location = .{
                                        .file = loc.file,
                                        .line = @intCast(loc.line),
                                        .column = @intCast(loc.column),
                                    } }) catch {};
                                    continue;
                                }
                                addTarget(dotted, targets, seen, a);
                            }
                        }

                        fn applyAnnotations(anns: []const []const u8, derived: ?[]const u8, targets: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), mods: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            for (anns) |ann| {
                                switch (withKind(ann)) {
                                    .none => {},
                                    .derive => addTarget(derived, targets, seen, a),
                                    .explicit => |args| addExplicit(args, targets, seen, mods, a, errs, loc),
                                }
                            }
                        }

                        fn addTarget(mq: ?[]const u8, targets: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), a: std.mem.Allocator) void {
                            const m = mq orelse return;
                            if (seen.contains(m)) return;
                            seen.put(m, {}) catch {};
                            targets.append(a, m) catch {};
                        }

                        // Gather every `[with]` target opened anywhere in a flow subtree — the head
                        // AND every mid-chain step, now that the parser hangs the annotation on the
                        // step's Invocation. Distinct by module.
                        fn gatherNode(node: *const ast_mod.Node, targets: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), mods: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            switch (node.*) {
                                .invocation => |*inv| {
                                    applyAnnotations(inv.annotations, inv.path.module_qualifier, targets, seen, mods, a, errs, loc);
                                },
                                .label_with_invocation => |*lwi| {
                                    applyAnnotations(lwi.invocation.annotations, lwi.invocation.path.module_qualifier, targets, seen, mods, a, errs, loc);
                                },
                                .conditional_block => |*cb| for (cb.nodes) |*n| gatherNode(n, targets, seen, mods, a, errs, loc),
                                .foreach => |*fe| for (fe.branches) |*b| for (b.body) |*c| gatherCont(c, targets, seen, mods, a, errs, loc),
                                .conditional => |*cond| for (cond.branches) |*b| for (b.body) |*c| gatherCont(c, targets, seen, mods, a, errs, loc),
                                .switch_result => |*sr| for (sr.branches) |*b| for (b.body) |*c| gatherCont(c, targets, seen, mods, a, errs, loc),
                                else => {},
                            }
                        }

                        fn gatherCont(cont: *const ast_mod.Continuation, targets: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), mods: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            if (cont.node) |*n| gatherNode(n, targets, seen, mods, a, errs, loc);
                            for (cont.continuations) |*nested| gatherCont(nested, targets, seen, mods, a, errs, loc);
                        }

                        // Resolve one bare name against the active `[with]` targets.
                        //   .local     — resolves in the main module; never shadowed
                        //   .unknown   — no active target owns it; leave for the downstream KORU040
                        //   .resolved  — exactly one target owns it; restamped in place here
                        //   .ambiguous — two or more own it; caller raises the KORU140 pick-wall
                        //
                        // `.ambiguous` carries EVERY owner, not a pair. A pick-wall exists to
                        // hand the author the whole set to choose from; naming a subset means
                        // you qualify to escape the reported collision and the owner it never
                        // mentioned ambushes you on the next build (641_014).
                        const Outcome = union(enum) {
                            local,
                            unknown,
                            resolved,
                            ambiguous: []const []const u8,
                        };

                        // An invocation's full dotted name (`say.hi`), not its last segment —
                        // two events sharing a tail (`say.hi`, `log.hi`) are different names.
                        fn fullName(inv: *const ast_mod.Invocation, a: std.mem.Allocator) ?[]const u8 {
                            if (inv.path.segments.len == 0) return null;
                            return std.mem.join(a, ".", inv.path.segments) catch null;
                        }

                        fn restamp(inv: *ast_mod.Invocation, targets: []const []const u8, main: []const u8, set: *std.StringHashMap(void), a: std.mem.Allocator) Outcome {
                            const name = fullName(inv, a) orelse return .unknown;
                            const mq = inv.path.module_qualifier orelse return .unknown;
                            if (!std.mem.eql(u8, mq, main)) return .unknown; // already qualified — not ours
                            if (has(set, main, name, a)) return .local; // resolves locally — never shadow
                            var owners = std.ArrayList([]const u8){};
                            for (targets) |t| {
                                if (has(set, t, name, a)) owners.append(a, t) catch return .unknown;
                            }
                            if (owners.items.len == 0) return .unknown; // unknown in every target too
                            if (owners.items.len > 1) return .{ .ambiguous = owners.toOwnedSlice(a) catch return .unknown };
                            const only = owners.items[0];
                            owners.deinit(a);
                            inv.path.module_qualifier = a.dupe(u8, only) catch return .unknown;
                            return .resolved;
                        }

                        // Restamp one invocation and, on ambiguity, record the KORU140 pick-wall
                        // into ctx.errors — surfaced (and halted on) at the analysis boundary.
                        fn resolveInv(inv: *ast_mod.Invocation, targets: []const []const u8, main: []const u8, set: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            switch (restamp(inv, targets, main, set, a)) {
                                .ambiguous => |owners| {
                                    defer a.free(owners);
                                    const seg = fullName(inv, a) orelse return;
                                    // Name every owner: `'a' and 'b'`, `'a', 'b' and 'c'`, ...
                                    var listing = std.ArrayList(u8){};
                                    defer listing.deinit(a);
                                    for (owners, 0..) |owner, i| {
                                        if (i > 0) listing.appendSlice(a, if (i + 1 == owners.len) " and " else ", ") catch return;
                                        listing.append(a, '\'') catch return;
                                        listing.appendSlice(a, owner) catch return;
                                        listing.append(a, '\'') catch return;
                                    }
                                    const msg = std.fmt.allocPrint(a, "error[KORU140]: bare name '{s}' resolves against more than one opened vocabulary ({s}) — qualify the call explicitly to pick one", .{ seg, listing.items }) catch return;
                                    errs.append(a, .{ .message = msg, .location = .{
                                        .file = loc.file,
                                        .line = @intCast(loc.line),
                                        .column = @intCast(loc.column),
                                    } }) catch {};
                                },
                                else => {},
                            }
                        }

                        fn walkNode(node: *ast_mod.Node, targets: []const []const u8, main: []const u8, set: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            switch (node.*) {
                                .invocation => |*inv| resolveInv(@constCast(inv), targets, main, set, a, errs, loc),
                                .label_with_invocation => |*lwi| resolveInv(@constCast(&lwi.invocation), targets, main, set, a, errs, loc),
                                .conditional_block => |*cb| {
                                    for (cb.nodes) |*n| walkNode(@constCast(n), targets, main, set, a, errs, loc);
                                },
                                .foreach => |*fe| {
                                    for (fe.branches) |*b| {
                                        for (b.body) |*c| walkCont(@constCast(c), targets, main, set, a, errs, loc);
                                    }
                                },
                                .conditional => |*cond| {
                                    for (cond.branches) |*b| {
                                        for (b.body) |*c| walkCont(@constCast(c), targets, main, set, a, errs, loc);
                                    }
                                },
                                .switch_result => |*sr| {
                                    for (sr.branches) |*b| {
                                        for (b.body) |*c| walkCont(@constCast(c), targets, main, set, a, errs, loc);
                                    }
                                },
                                else => {},
                            }
                        }

                        fn walkCont(cont: *ast_mod.Continuation, targets: []const []const u8, main: []const u8, set: *std.StringHashMap(void), a: std.mem.Allocator, errs: anytype, loc: anytype) void {
                            if (cont.node) |*n| walkNode(@constCast(n), targets, main, set, a, errs, loc);
                            for (cont.continuations) |*nested| walkCont(@constCast(nested), targets, main, set, a, errs, loc);
                        }
                    };

                    var set = std.StringHashMap(void).init(alloc);
                    S.collect(ctx.original_ast.items, &set, alloc);

                    var imported = std.StringHashMap(void).init(alloc);
                    S.collectModules(ctx.original_ast.items, &imported, alloc);

                    // Flows live at TWO depths. The entry file's are top-level items; an
                    // imported module's arrive wrapped in a single `.module_decl` carrying its
                    // own items. The flat walk this replaced resolved `[with]` for the entry
                    // file alone, so a vocabulary opened inside a library never restamped and
                    // its bare names kept the library's own qualifier — `std/parser:parse` then
                    // refused the grammar's `match(l)` picker as "not the static shape" while
                    // looking straight at it (115_012).
                    //
                    // The stamp to resolve against is the flow's HOME MODULE, not the program's
                    // main module. Stage-A canonicalize stamps a bare name with the module it
                    // was written in; for a library flow that is the library's logical name, so
                    // passing `main_module_name` down made every restamp bail as "already
                    // qualified — not ours". Home is `main_mod` at top level and the enclosing
                    // `.module_decl`'s logical name below it.
                    const Walk = struct {
                        fn items(
                            its: []const ast_mod.Item,
                            home: []const u8,
                            set2: *std.StringHashMap(void),
                            mods: *std.StringHashMap(void),
                            a: std.mem.Allocator,
                            errs: anytype,
                        ) void {
                            for (its) |*item| {
                                switch (item.*) {
                                    .module_decl => |*m| items(m.items, m.logical_name, set2, mods, a, errs),
                                    .flow => |*flow| {
                                        // Collect the vocabularies this flow opens: a flow-head
                                        // `[with]` (the annotation may live on the flow itself)
                                        // plus every mid-chain opener.
                                        var targets = std.ArrayList([]const u8){};
                                        var seen = std.StringHashMap(void).init(a);
                                        // `flow.inv()` assumes an invocation head — derive the
                                        // flow-level vocabulary only when the head really is one.
                                        const derived: ?[]const u8 = if (flow.body.node) |*n| switch (n.*) {
                                            .invocation => |*i| i.path.module_qualifier,
                                            .label_with_invocation => |*l| l.invocation.path.module_qualifier,
                                            else => null,
                                        } else null;
                                        S.applyAnnotations(flow.annotations, derived, &targets, &seen, mods, a, errs, flow.location);
                                        S.gatherCont(&flow.body, &targets, &seen, mods, a, errs, flow.location);
                                        if (targets.items.len == 0) continue;

                                        S.walkCont(@constCast(&flow.body), targets.items, home, set2, a, errs, flow.location);
                                    },
                                    else => {},
                                }
                            }
                        }
                    };
                    Walk.items(updated_ctx.ast.items, main_mod, &set, &imported, alloc, &updated_ctx.errors);

                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "resolve_with_scopes";
                    return updated_ctx;

            }
        };
        pub const desugar_chains_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: desugar_chains  [/Users/larsde/src/koru-cypoe/koru_std/compiler.desugars.kz:26]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    const ast_transform = @import("ast_transform");
                    const errors_sink = @import("errors");

                    var updated_ctx = ctx;
                    const program = @constCast(ctx.ast);

                    // The compilation's reporter, minted at the pipeline head and already bound
                    // to the user's file — KORU092/093's hints and previews ride on it.
                    const reporter = ctx.reporter orelse {
                        @panic("desugar-chains: the compilation carries no diagnostic reporter");
                    };

                    ast_transform.desugarPointfreeChains(ctx.allocator, program, reporter) catch |err| {
                        log.err("FATAL: point-free desugar failed ({s})\n", .{@errorName(err)});
                        @panic("point-free desugar failed — see error above");
                    };
                    ast_transform.desugarBindingPuns(ctx.allocator, program, reporter) catch |err| {
                        log.err("FATAL: bind-pun/thread desugar failed ({s})\n", .{@errorName(err)});
                        @panic("bind-pun/thread desugar failed — see error above");
                    };
                    ast_transform.desugarFlowReturnTerminus(ctx.allocator, program, reporter) catch |err| {
                        log.err("FATAL: return-terminus desugar failed ({s})\n", .{@errorName(err)});
                        @panic("return-terminus desugar failed — see error above");
                    };
                    // The dead-produce audit deferred every chain whose step names the
                    // bootstrap segment could not resolve — `[with]`-scoped bare names get
                    // their verdict here, now that every callee is visible (641_015).
                    ast_transform.auditDeadThreadsInProgram(ctx.allocator, program, reporter) catch |err| {
                        log.err("FATAL: dead-thread audit failed ({s})\n", .{@errorName(err)});
                        @panic("dead-thread audit failed — see error above");
                    };

                    // KORU038 / KORU092 / KORU093 / KORU094 surface here, hints and source
                    // previews intact — the same gate koruc used to hold, one segment later.
                    // Halt rather than hand a half-desugared AST to the rest of the pipeline.
                    if (reporter.hasErrors()) {
                        const out = errors_sink.FileSink.stderr();
                        reporter.printErrors(out) catch {};
                        std.process.exit(1);
                    }

                    updated_ctx.ast = program;
                    updated_ctx.passes_completed += 1;
                    updated_ctx.current_pass = "desugar_chains";
                    return updated_ctx;

            }
        };
        pub const pass_witness_check_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                ctx: koru_std.koru_compiler.CompilerContext,
                failed: struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                    message: []const u8,
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: pass_witness_check  [/Users/larsde/src/koru-cypoe/koru_std/compiler.witness.kz:121]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // No-op unless the program declared std/witness:enforce — registration
                    // happens in enforce|zig during comptime_main (Phase 3 strips the
                    // enforce flow, so process state is the only channel reaching here).
                    const emitter_helpers = @import("emitter_helpers");
                    if (!emitter_helpers.witness_enforced) return .{ .ctx = ctx };

                    var mutable_ctx = ctx;
                    mutable_ctx.current_pass = "witness_check";

                    const reporter = mutable_ctx.reporter orelse {
                        @panic("pass-witness-check: the compilation carries no diagnostic reporter");
                    };
                    const err_base = reporter.errors.items.len;

                    var marks = std.ArrayList(WitnessSiteMark).initCapacity(mutable_ctx.allocator, 8) catch {
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = "witness check: out of memory" } };
                    };
                    witnessCheckCollectItems(&marks, mutable_ctx.allocator, mutable_ctx.ast.items) catch {
                        return .{ .failed = .{ .ctx = mutable_ctx, .message = "witness check: out of memory" } };
                    };

                    // One site line per mark in walk order (all kinds interleaved), then
                    // one census line per kind that appeared — the verbatim record a later
                    // checker consumes from backend output (pinned by expected_comptime.txt).
                    if (marks.items.len > 0) {
                        var w_lossless: usize = 0;
                        var w_deferred: usize = 0;
                        var w_rounds: usize = 0;
                        var w_non_numeric: usize = 0;
                        var w_refused: usize = 0;
                        var d_sole: usize = 0;
                        var d_preferred: usize = 0;
                        for (marks.items) |wm| {
                            if (wm.extra.len > 0) {
                                std.debug.print("[witness] site {s} {s} {s} {s} {s}\n", .{ wm.kind, wm.site, wm.arrow, wm.verdict, wm.extra });
                            } else {
                                std.debug.print("[witness] site {s} {s} {s} {s}\n", .{ wm.kind, wm.site, wm.arrow, wm.verdict });
                            }
                            if (std.mem.eql(u8, wm.kind, "stored-write-numeric")) {
                                if (std.mem.eql(u8, wm.verdict, "lossless")) {
                                    w_lossless += 1;
                                } else if (std.mem.eql(u8, wm.verdict, "deferred")) {
                                    w_deferred += 1;
                                } else if (std.mem.eql(u8, wm.verdict, "rounds")) {
                                    w_rounds += 1;
                                } else if (std.mem.eql(u8, wm.verdict, "non-numeric")) {
                                    w_non_numeric += 1;
                                } else if (std.mem.eql(u8, wm.verdict, "refused")) {
                                    w_refused += 1;
                                }
                            } else if (std.mem.eql(u8, wm.kind, "auto-discharge")) {
                                const colon = std.mem.indexOfScalar(u8, wm.verdict, ':') orelse wm.verdict.len;
                                const rule = wm.verdict[0..colon];
                                if (std.mem.eql(u8, rule, "sole")) {
                                    d_sole += 1;
                                } else if (std.mem.eql(u8, rule, "preferred")) {
                                    d_preferred += 1;
                                }
                            }
                        }
                        const n_numeric = w_lossless + w_deferred + w_rounds + w_non_numeric + w_refused;
                        if (n_numeric > 0) {
                            std.debug.print("[witness] stored-write-numeric: lossless={d} deferred={d} rounds={d} non-numeric={d} refused={d}\n", .{ w_lossless, w_deferred, w_rounds, w_non_numeric, w_refused });
                        }
                        if (d_sole + d_preferred > 0) {
                            std.debug.print("[witness] auto-discharge: sole={d} preferred={d}\n", .{ d_sole, d_preferred });
                        }
                    }

                    // `strict` is an opaque annotation word, not a fixed semantics: each
                    // pass that cares reads it and renders it into its own domain (the
                    // [strict] convention at ~pass-auto-discharge). For the witness pass
                    // strict means every stored write must be PROVEN lossless — a write the
                    // numeric check left deferred, or a literal that rounds, is a refusal.
                    // Discharge marks never trigger strict: under [strict] auto-discharge
                    // doesn't insert, so none exist.
                    var strict_module = false;
                    for (mutable_ctx.ast.module_annotations) |ann| {
                        if (std.mem.eql(u8, ann, "strict")) strict_module = true;
                    }
                    if (strict_module) {
                        var refused = false;
                        for (marks.items) |wm| {
                            if (!std.mem.eql(u8, wm.kind, "stored-write-numeric")) continue;
                            const arrow_dest_end = std.mem.indexOf(u8, wm.arrow, "<-") orelse continue;
                            const dest = wm.arrow[0..arrow_dest_end];
                            if (std.mem.eql(u8, wm.verdict, "rounds")) {
                                const lit_src = wm.arrow[arrow_dest_end + 2 ..];
                                const lit_text = if (std.mem.startsWith(u8, lit_src, "literal:")) lit_src["literal:".len..] else lit_src;
                                reporter.addError(.KORU209, wm.line, wm.column, "std/witness: [strict] requires every stored write to be proven lossless — '{s}' ({s}) is written from literal {s}, which rounds in {s}", .{ wm.site, dest, lit_text, dest }) catch {};
                                refused = true;
                            } else if (std.mem.eql(u8, wm.verdict, "deferred")) {
                                reporter.addError(.KORU209, wm.line, wm.column, "std/witness: [strict] requires every stored write to be proven lossless — '{s}' ({s}) is written from an unproven value (deferred)", .{ wm.site, dest }) catch {};
                                refused = true;
                            }
                        }
                        if (refused) {
                            drainReporter(reporter, &mutable_ctx, err_base);
                            return .{ .failed = .{ .ctx = mutable_ctx, .message = "witness check: [strict] stored writes not proven lossless" } };
                        }
                    }

                    mutable_ctx.passes_completed += 1;
                    return .{ .ctx = mutable_ctx };

            }
        };
        pub const process_ccp_commands_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: process_ccp_commands  [/Users/larsde/src/koru-cypoe/koru_std/compiler.ccp.kz:27]
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;

                    // TODO: Check if --ccp flag is enabled via CompilerEnv
                    // TODO: Attempt non-blocking stdin read for JSONL commands
                    // TODO: Parse and dispatch commands to appropriate handlers
                    // For now, just pass through the context unchanged
                    var updated_ctx = ctx;
                    updated_ctx.passes_completed += 1;
                    return updated_ctx;

            }
        };
    };
    pub const koru_io = struct {
        // Koru Standard Library: I/O
        // Basic input/output operations for Koru programs
        //
        // Finally! After achieving consciousness (metacircular compilation),
        // we can now print "Hello, World!"
        const std = @import("std");
        const codegen_utils_io = @import("codegen_utils");
        // Print without trailing newline — the no-newline sibling of print.ln.
        // SAME implementation (__printInterpolate, with_newline=false): comptime
        // {{ }} interpolation, rerouted to print.impl for shape checking.
        //
        // The old RUNTIME passthrough tor (`print { text }` + |zig/|js procs) died
        // here (2026-06-11, Lars ruling: std/io's print surface is comptime-only;
        // stage/runtime printing is the future std/compiler print-family). Its
        // positional-arg mis-emit bug died with the codepath.
        // `println` REMOVED — subsumed by `print.ln` (the interpolating print). Calling
        // `std/io:println` is now an unknown-event error by design (greenfield: the old
        // form must fail loudly once removed).
        // Print formatted text
        // NOTE: printf with varargs would require runtime support — deliberately absent.
        // One blocking line from stdin. EOF is a branch, not an empty string —
        // an empty line is `line` with length 0. The buffer is module-static:
        // the returned slice is valid until the next readln (the caller must
        // finish with the line first). That is the interactive/pipe contract
        // (`650_009`); read.ln remains the leaky slurp-a-chunk sibling.
        var readln_buf: [8192]u8 = undefined;
        // Simple line reader - returns the line, or empty string on EOF/error
        // No error handling, just returns what it gets
        // Debug print for development
        // NOTE: debug with anytype would require runtime support - skipping for now
        // pub tor io.debug { label: string, value: anytype }
        // | printed {}
        //
        // proc io.debug {
        //     std.debug.print("[DEBUG {s}]: ", .{label});
        //     std.debug.print("{any}\n", .{value});
        //     return .{ .printed = .{} };
        // }
        // ============================================================================
        // FILE/STDIN READING - For interpreter and scripting
        // ============================================================================
        // Read stdin as a stream of lines — the same effect contract as
        // std/fs:read-lines, sourced from stdin (the interactive/pipe vertical).
        // Read entire stdin as text. The buffer is allocator-owned and carries the
        // `allocated!` obligation: hand it to `std/io:free` (auto-discharge inserts
        // the call when the trace is unambiguous — most callers never write it).
        // Ruled 2026-07-31 (the 335_042/043 question): one label, `allocated`, for
        // every allocator-owned buffer an io tor hands back; `std/io:free` is the
        // one disposer.
        // Read entire file as text. `ok` carries the `allocated!` obligation — see
        // read-stdin's header; `std/io:free` discharges it.
        // Discharge the `allocated!` obligation on a buffer an io tor handed back
        // (read-file, read-stdin). The one disposer for the one label.
        // Get command line arguments
        // ============================================================================
        // PRINT.LN - Interpolated printing with Expression (ZERO OVERHEAD)
        // ============================================================================
        //
        // Syntax: std/io:print.ln("Hello {{ name }}! Count: {{ count }}")
        //
        // ARCHITECTURE:
        // - print.ln is a comptime transform that generates inline Zig code
        // - Parses {{ ... }} placeholders from the Expression string
        // - Optional format specifier: {{ name:s }} or {{ count:d }}
        // - Generates: std.debug.print("Hello {}! Count: {}\n", .{name, count});
        //
        // This is NOT a regular tor - it's a pure compile-time transformation.
        // eprint / eprint.ln — the stderr siblings of print / print.ln. Same engine
        // (__printInterpolate), routed to fd 2. They reuse print.impl for shape
        // checking (the reroute is analysis-only; the inline body does the write).
        // ============================================================================
        // Shared interpolation engine for the comptime print family. `print` IS
        // `print.ln` without the trailing newline — ONE implementation, parameterized
        // at comptime. Both reroute to the [norun] print.impl tor for shape
        // checking. (Stage/runtime printing belongs to the future std/compiler
        // print-family — std/io's print surface is comptime-only by ruling,
        // 2026-06-11.)
        //
        // `item: anytype` + lazy ast import keep this fn unanalyzed (and harmless)
        // if it rides along into runtime emission units where @import("ast") does
        // not exist — Zig only analyzes referenced declarations.
        // ============================================================================
        // A literal `{` or `}` from the user's message has to reach Zig's `std.fmt`
        // DOUBLED, or the message's own braces are read as format placeholders.
        // `{{ … }}` is the interpolation opener and is consumed before a byte ever
        // gets here, so every brace that arrives IS the user's own text.
        //
        // Found by the ECS benchmark: without this no Koru program could print a JSON
        // line — `print.ln("{\"a\":1}")` died inside std.fmt at comptime, in the
        // STDLIB's format string, with no source location the author could act on.
        fn __appendFmtLiteralByte(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) void {
            if (byte == '{' or byte == '}') buf.append(allocator, byte) catch unreachable;
            buf.append(allocator, byte) catch unreachable;
        }
        // ONE writer, four call sites. `print`/`print.ln`/`eprint`/`eprint.ln` share
        // __printInterpolate; `print.blk` has two more lowerings of its own (|zig and
        // |raw_posix), each with a :f/:any fallback. Every one of them has to reach the
        // OS, and pasting the host branch into each is precisely how two lowerings of one
        // construct drift apart — a shape this file has already produced four times.
        //
        // The branch itself is a NECESSITY, not a preference: `std.posix.write` does not
        // exist on a freestanding target, so without it every print in the stdlib is a
        // compile error there, which is what kept Koru off unikernels. ISO C `fputs` and
        // not POSIX `write`, because freestanding has no guaranteed fd table — measured
        // on Unikraft 0.21.0, `write` links only after four more Kconfig libraries, costs
        // 12,544 image bytes, and still traps at boot because nothing opened fd 1.
        //
        // Chunked through its OWN 4 KB buffer rather than NUL-terminating the caller's:
        // the callers' buffer is 65,536 bytes, which is Unikraft's ENTIRE default boot
        // stack (order 4 = 16 pages, exactly 64 KB), and a writer needing a second copy
        // of that would double a requirement that is already the whole stack.
        //
        // KORU_OUT_UNESCAPED is the source of truth. KORU_OUT_FN is the same text with
        // braces doubled, derived at comptime, because four of the five call sites splice
        // it into an allocPrint FORMAT string where a bare `{` is a format specifier and
        // the fifth (raw_io_prefix) is a plain concatenation. Deriving rather than
        // keeping two hand-maintained copies is the whole point of this const existing.
        const KORU_OUT_UNESCAPED: []const u8 =
            "fn __kout(__fd: i32, __b: []const u8) void { " ++
            "if (@import(\"builtin\").os.tag == .freestanding) { " ++
            "const __kc = struct { extern var stdout: ?*anyopaque; extern var stderr: ?*anyopaque; " ++
            "extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; }; " ++
            "var __kt: [4096]u8 = undefined; " ++
            "for (0..(__b.len + __kt.len - 2) / (__kt.len - 1)) |__ki| { const __kn = @min(__kt.len - 1, __b.len - __ki * (__kt.len - 1)); " ++
            "@memcpy(__kt[0..__kn], __b[__ki * (__kt.len - 1)..][0..__kn]); __kt[__kn] = 0; " ++
            "@import(\"std\").mem.doNotOptimizeAway(__kc.fputs(@as([*:0]const u8, @ptrCast(&__kt)), " ++
            "if (__fd == 2) __kc.stderr else __kc.stdout)); } " ++
            "} else if (@import(\"builtin\").os.tag == .windows) { "
            // fd_t is a HANDLE on Windows, not an int — resolve 1/2 through
            // GetStdHandle and write via WriteFile (the same call std.posix.write
            // makes, once the fd is already a handle).
            ++ "const __wh = @import(\"std\").os.windows.GetStdHandle(if (__fd == 2) @import(\"std\").os.windows.STD_ERROR_HANDLE else @import(\"std\").os.windows.STD_OUTPUT_HANDLE) catch return; "
            ++ "@import(\"std\").mem.doNotOptimizeAway(@import(\"std\").os.windows.WriteFile(__wh, __b, null) catch @as(usize, 0)); "
            ++ "} else { @import(\"std\").mem.doNotOptimizeAway(@import(\"std\").posix.write(__fd, __b) catch @as(usize, 0)); } } ";
        fn __doubleBraces(comptime s: []const u8) []const u8 {
            comptime {
                @setEvalBranchQuota(100000);
                var out: []const u8 = "";
                for (s) |c| {
                    out = out ++ switch (c) {
                        '{' => "{{",
                        '}' => "}}",
                        else => &[_]u8{c},
                    };
                }
                return out;
            }
        }
        const KORU_OUT_FN: []const u8 = __doubleBraces(KORU_OUT_UNESCAPED);
        fn __printInterpolate(
            expr: []const u8,
            item: anytype,
            rep: anytype,
            allocator: std.mem.Allocator,
            comptime with_newline: bool,
            comptime label: []const u8,
            to_fd: u8,
        ) @import("ast").SiteResult {
            const ast = @import("ast");
            // Helper: Check if identifier is a Zig keyword
            const isZigKeyword = struct {
                fn check(word: []const u8) bool {
                    const keywords = [_][]const u8{
                        "error", "type", "async", "await", "suspend", "resume",
                        "try", "catch", "if", "else", "switch", "while",
                        "for", "break", "continue", "return", "defer", "errdefer",
                        "test", "pub", "export", "extern", "packed", "inline",
                        "noinline", "comptime", "nosuspend", "volatile", "allowzero",
                        "align", "linksection", "callconv", "noalias",
                        "struct", "enum", "union", "opaque", "fn", "const",
                        "var", "anyframe", "anytype", "anyerror", "unreachable",
                        "undef", "null", "true", "false", "and", "or",
                        "orelse", "threadlocal",
                    };
                    for (keywords) |kw| {
                        if (std.mem.eql(u8, word, kw)) return true;
                    }
                    // Zig primitive names — a local may not shadow them, so they
                    // escape exactly like keywords (230_018).
                    const primitives = [_][]const u8{
                        "bool",         "void",     "noreturn", "anyopaque",
                        "usize",        "isize",    "f16",      "f32",
                        "f64",          "f80",      "f128",     "undefined",
                        "comptime_int", "comptime_float",       "c_char",
                        "c_short",      "c_ushort", "c_int",    "c_uint",
                        "c_long",       "c_ulong",  "c_longlong",
                        "c_ulonglong",  "c_longdouble",
                    };
                    for (primitives) |p| {
                        if (std.mem.eql(u8, word, p)) return true;
                    }
                    // u<digits> / i<digits> — the arbitrary-width integer family.
                    if (word.len >= 2 and (word[0] == 'u' or word[0] == 'i')) {
                        var all_digits = true;
                        for (word[1..]) |c| {
                            if (c < '0' or c > '9') all_digits = false;
                        }
                        if (all_digits) return true;
                    }
                    return false;
                }
            }.check;
            // Helper: Append path with escaped keywords (e.g., err.error -> err.@"error")
            const appendEscapedPath = struct {
                fn append(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) void {
                    var start: usize = 0;
                    var pos: usize = 0;
                    var is_first = true;
                    while (pos <= path.len) {
                        if (pos == path.len or path[pos] == '.') {
                            const segment = path[start..pos];
                            if (!is_first) {
                                buf.append(alloc, '.') catch unreachable;
                                // Check if this segment is a keyword
                                if (isZigKeyword(segment)) {
                                    buf.appendSlice(alloc, "@\"") catch unreachable;
                                    buf.appendSlice(alloc, segment) catch unreachable;
                                    buf.append(alloc, '"') catch unreachable;
                                } else {
                                    buf.appendSlice(alloc, segment) catch unreachable;
                                }
                            } else if (isZigKeyword(segment)) {
                                // A bare binding may legally collide with a Zig
                                // keyword or primitive (`: u1` — 230_018); the first
                                // segment escapes like any other.
                                buf.appendSlice(alloc, "@\"") catch unreachable;
                                buf.appendSlice(alloc, segment) catch unreachable;
                                buf.append(alloc, '"') catch unreachable;
                            } else {
                                buf.appendSlice(alloc, segment) catch unreachable;
                            }
                            is_first = false;
                            start = pos + 1;
                        }
                        pos += 1;
                    }
                }
            }.append;
            // Get the flow from the item (flows with impl context now use item.flow with impl_of set)
            const flow = if (item.* == .flow)
                &item.flow
            else
                return .{};
            // Parse the Expression string for ${...} placeholders
            var format_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
            var args_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
            var i: usize = 0;
            var first_arg = true;
            var missing_spec: ?[]const u8 = null;
            var function_call_expr: ?[]const u8 = null;
            var keyed_placeholder: ?[]const u8 = null;
            // Use the expression parser to detect function calls properly
            const expr_parser = @import("expression_parser");
            // Detect string literal vs bare expression
            const is_string_literal = expr.len > 0 and expr[0] == '"';
            // Skip leading/trailing quotes if string literal
            const start: usize = if (is_string_literal) 1 else 0;
            const end: usize = if (is_string_literal and expr[expr.len - 1] == '"') expr.len - 1 else expr.len;
            const raw_content = expr[start..end];
            // Bare expression (not a string literal): wrap as {{ raw_content }} for single-value interpolation
            // If expression already has a format spec (contains :), don't add :s
            const content = if (!is_string_literal and raw_content.len > 0) blk: {
                const has_format_spec = std.mem.indexOf(u8, raw_content, ":") != null;
                const suffix = if (has_format_spec) " }}" else ":s }}";
                var wrapped = std.ArrayList(u8).initCapacity(allocator, raw_content.len + 8) catch unreachable;
                wrapped.appendSlice(allocator, "{{ ") catch unreachable;
                wrapped.appendSlice(allocator, raw_content) catch unreachable;
                wrapped.appendSlice(allocator, suffix) catch unreachable;
                break :blk wrapped.items;
            } else raw_content;
            while (i < content.len) {
                // Look for {% if var %}...{% endif %} control blocks
                if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                    const tag_start = i + 2;
                    // Skip whitespace after {%
                    var ws_start = tag_start;
                    while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                    // Check for "if " keyword
                    if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start..ws_start + 3], "if ")) {
                        const var_start = ws_start + 3;
                        // Skip whitespace after "if"
                        var var_pos = var_start;
                        while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}
                        // Find end of variable name (until whitespace or %)
                        var var_end = var_pos;
                        while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                        const cond_var = content[var_pos..var_end];
                        // Find closing %}
                        var tag_end = var_end;
                        while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}
                        if (tag_end + 1 < content.len) {
                            const body_start = tag_end + 2;
                            // Find matching {% endif %}
                            const endif_marker = "{% endif %}";
                            if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                const body_end = body_start + endif_offset;
                                const body_content = content[body_start..body_end];
                                // Generate: {s} with arg: if (var) "content" else ""
                                format_buf.appendSlice(allocator, "{s}") catch unreachable;
                                if (!first_arg) {
                                    args_buf.appendSlice(allocator, ", ") catch unreachable;
                                }
                                args_buf.appendSlice(allocator, "if (") catch unreachable;
                                appendEscapedPath(&args_buf, allocator, cond_var);
                                args_buf.appendSlice(allocator, ") \"") catch unreachable;
                                // Escape body content for Zig string
                                for (body_content) |c| {
                                    switch (c) {
                                        '"' => args_buf.appendSlice(allocator, "\\\"") catch unreachable,
                                        '\\' => args_buf.appendSlice(allocator, "\\\\") catch unreachable,
                                        '\n' => args_buf.appendSlice(allocator, "\\n") catch unreachable,
                                        '\r' => args_buf.appendSlice(allocator, "\\r") catch unreachable,
                                        '\t' => args_buf.appendSlice(allocator, "\\t") catch unreachable,
                                        else => args_buf.append(allocator, c) catch unreachable,
                                    }
                                }
                                args_buf.appendSlice(allocator, "\" else \"\"") catch unreachable;
                                first_arg = false;
                                i = body_end + endif_marker.len;
                                continue;
                            }
                        }
                    }
                    // Not a recognized tag, treat as literal
                    __appendFmtLiteralByte(&format_buf, allocator, content[i]);
                    i += 1;
                }
                // Look for {{ ... }} placeholders (Liquid-style syntax)
                else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                    const placeholder_start = i + 2;
                    // Skip leading whitespace inside {{ }}
                    var ws_start = placeholder_start;
                    while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                    // Find closing }}
                    var j = ws_start;
                    while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}
                    if (j + 1 < content.len) {
                        // Trim trailing whitespace
                        var ws_end = j;
                        while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}
                        const placeholder = content[ws_start..ws_end];
                        var var_name: []const u8 = placeholder;
                        var format_spec: []const u8 = "any";
                        var has_spec = false;
                        // Keyed addressing `store[key: value]` is a pinned hole
                        // (690_018): the `key:` decl emits no lookup machinery, and
                        // the bracket `:` would misfire the format-spec split below.
                        // Honor or refuse: refuse, before either defect runs.
                        if (keyed_placeholder == null and codegen_utils_io.colonInsideBrackets(placeholder)) {
                            keyed_placeholder = placeholder;
                        }
                        // Check for format specifier: {{ name:s }}
                        if (std.mem.indexOf(u8, placeholder, ":")) |colon_pos| {
                            var_name = placeholder[0..colon_pos];
                            format_spec = placeholder[colon_pos + 1..];
                            has_spec = true;
                        }
                        // Function call check: parse the expression and check for
                        // USER function calls. The store rewriters splice their
                        // synthesized `__koru_resolve` handle deref into hole text
                        // after admission; that machinery call is not the user's.
                        if (function_call_expr == null) {
                            var parser = expr_parser.ExpressionParser.init(allocator, var_name);
                            defer parser.deinit();
                            if (parser.parse()) |parsed_expr| {
                                if (expr_parser.containsUserFunctionCall(parsed_expr)) {
                                    function_call_expr = var_name;
                                }
                            } else |_| {
                                // Parse failed - let the Zig compiler catch it later
                            }
                        }
                        // Missing specifier: record error (first one only)
                        if (!has_spec and missing_spec == null) {
                            missing_spec = placeholder;
                        }
                        // :f maps to {} in Zig (default float format — Zig has no {f}).
                        // :S is the handle form (610_007, ruled 2026-09-05): the arg is
                        // a *String, read as `.data` INSIDE the emitted step — the
                        // owner binding is live and KORU030-checked there, so the
                        // borrow never outlives anything. Zero-copy, zero new state.
                        const zig_fmt_spec_ln = if (std.mem.eql(u8, format_spec, "f")) "" else if (std.mem.eql(u8, format_spec, "S")) "s" else format_spec;
                        format_buf.append(allocator, '{') catch unreachable;
                        format_buf.appendSlice(allocator, zig_fmt_spec_ln) catch unreachable;
                        format_buf.append(allocator, '}') catch unreachable;
                        if (!first_arg) {
                            args_buf.appendSlice(allocator, ", ") catch unreachable;
                        }
                        // Escape Zig keywords in dotted paths (e.g., err.error -> err.@"error")
                        appendEscapedPath(&args_buf, allocator, var_name);
                        if (std.mem.eql(u8, format_spec, "S")) args_buf.appendSlice(allocator, ".data") catch unreachable;
                        first_arg = false;
                        i = j + 2; // Skip past }}
                    } else {
                        __appendFmtLiteralByte(&format_buf, allocator, content[i]);
                        i += 1;
                    }
                } else {
                    __appendFmtLiteralByte(&format_buf, allocator, content[i]);
                    i += 1;
                }
            }
            if (with_newline) {
                format_buf.appendSlice(allocator, "\\n") catch unreachable;
            }
            const inline_code = if (function_call_expr) |fn_expr| kblk1: {
                rep.addErrorAtLocation(.KORU168, flow.location, "std/io:" ++ label ++ ": '{{{{ {s} }}}}' contains a function call — function calls are not allowed in expressions. Use tor chaining instead.", .{fn_expr}) catch {};
                break :kblk1 std.fmt.allocPrint(
                    allocator,
                    "@compileError(\"std/io:" ++ label ++ ": '{{{{ {s} }}}}' contains a function call — function calls are not allowed in expressions. Use tor chaining instead.\");",
                    .{fn_expr}
                ) catch unreachable;
            }
            else if (keyed_placeholder) |placeholder| kblk_keyed: {
                rep.addErrorAtLocation(.KORU168, flow.location, "std/io:" ++ label ++ ": '{{{{ {s} }}}}' uses keyed addressing 'store[key: value]' - a pinned hole (690_018); bind the row's handle and interpolate store[handle].field instead", .{placeholder}) catch {};
                break :kblk_keyed std.fmt.allocPrint(
                    allocator,
                    "@compileError(\"std/io:" ++ label ++ ": '{{{{ {s} }}}}' uses keyed addressing - a pinned hole (690_018); use store[handle].field\");",
                    .{placeholder}
                ) catch unreachable;
            }
            else if (missing_spec) |placeholder| kblk2: {
                rep.addErrorAtLocation(.KORU168, flow.location, "std/io:" ++ label ++ ": '{{{{ {s} }}}}' requires a format specifier (:d, :s, :f, or :any)", .{placeholder}) catch {};
                break :kblk2 std.fmt.allocPrint(
                    allocator,
                    "@compileError(\"std/io:" ++ label ++ ": '{{{{ {s} }}}}' requires a format specifier (:d, :s, :f, or :any)\");",
                    .{placeholder}
                ) catch unreachable;
            }
            else
                // Write to to_fd (1 = stdout for print/print.ln, 2 = stderr for eprint/
                // eprint.ln). Inline (struct { fn w }).w("fmt", .{args}) — the args tuple
                // is evaluated in the OUTER scope, so captured interpolation vars work;
                // the body holds the 64K stack buffer. Unbuffered write of a bufPrint'd
                // slice — no flush, version-stable (std.debug.print is stderr-only). NO
                // `_` token: the flow/tap emitter rewrites a bare `_` to the binding
                // name, so the discard goes through doNotOptimizeAway.
                // (64K cap per call; longer output is dropped — rare, the suite catches it.)
                // Reaches the OS through the shared KORU_OUT_FN writer — see its
                // definition for why the freestanding branch exists and why it is fputs.
                std.fmt.allocPrint(
                    allocator,
                    "(struct {{ " ++ KORU_OUT_FN ++ "fn __kw(comptime __f: []const u8, __a: anytype) void {{ var __kb: [65536]u8 = undefined; const __ks = @import(\"std\").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout({d}, __ks); }} }}).__kw(\"{s}\", .{{{s}}});",
                    .{ to_fd, format_buf.items, args_buf.items }
                ) catch unreachable;
            // Position-agnostic: the runner lifts nested sites into a synthetic
            // top-level flow, so the flow's own invocation is correct at every depth.
            // Re-route path to void print.impl tor for shape checking
            const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
            impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
            impl_segments[1] = allocator.dupe(u8, "impl") catch unreachable;
            const impl_path = ast.DottedPath{
                .module_qualifier = flow.inv().path.module_qualifier,
                .segments = impl_segments,
            };
            // Already transformed — don't re-run
            if (flow.inline_body != null) {
                return .{};
            }
            const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
            for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
            new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;
            const new_invocation = ast.Invocation{
                .path = impl_path,
                .args = flow.inv().args,
                .annotations = flow.inv().annotations,
                .marks = new_marks,
                .inserted_by_tap = flow.inv().inserted_by_tap,
                .from_opaque_tap = flow.inv().from_opaque_tap,
            };
            // Whole-struct copy, NOT a field-list literal: a hand-rolled literal
            // silently drops any field it doesn't name (this exact rebuild used to
            // lose impl_variant, breaking variant subflows whose body is a print).
            var transformed_flow = flow.*;
            transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
            transformed_flow.inline_body = inline_code;
            const new_item = ast.Item{ .flow = transformed_flow };
            return .{ .replacement = new_item };
        }
        // eprint family — same interpolation engine, routed to stderr (fd 2). The
        // stdout/stderr split: print/print.ln -> stdout, eprint/eprint.ln -> stderr.
        // ============================================================================
        // JS-target interpolation engine for the comptime print family. The parallel
        // of __printInterpolate: SAME expr surface — string-literal vs bare expression,
        // `{{ var:fmt }}` placeholders, `{% if v %}…{% endif %}` blocks — but it emits
        // a JS string-concat and a `process.{stdout,stderr}.write(…)` call instead of
        // the Zig posix.write inline. Format specs (:d/:s/:f/:any) are accepted and
        // dropped except a `:.N` precision tail, which emits `Number(x).toFixed(N)`
        // — the same honoring `fmt`'s jsPlaceholder gives `ln|js`. `to_fd` selects the stream (1 =
        // stdout, 2 = stderr); the trailing newline for the `.ln` variants is appended
        // as a `+ "\n"` operand, matching |zig's fd + `\n` semantics (neither stream
        // adds an implicit newline).
        //
        // Literal text from a string-literal expr is ALREADY escaped for a `"…"` body
        // (Koru string escapes are C-like and valid inside a JS `"…"`), so literal runs
        // are copied VERBATIM — the key divergence from print.blk|js, whose source
        // block holds raw text that must be re-escaped. On a bare expression the whole
        // value is stringified (`"" + (expr)`), the `""` forcing string-concat context.
        // ============================================================================
        fn __printInterpolateJs(
            expr: []const u8,
            item: anytype,
            allocator: std.mem.Allocator,
            comptime with_newline: bool,
            to_fd: u8,
        ) @import("ast").SiteResult {
            const ast = @import("ast");
            const flow = if (item.* == .flow)
                &item.flow
            else
                return .{};
            // Already transformed — don't re-run.
            if (flow.inline_body != null) {
                return .{};
            }
            var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
            var first = true;
            var in_literal = false;
            const openLit = struct {
                fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, f: *bool, il: *bool) void {
                    if (!il.*) {
                        if (!f.*) b.appendSlice(a, " + ") catch unreachable;
                        b.append(a, '"') catch unreachable;
                        il.* = true;
                        f.* = false;
                    }
                }
            }.call;
            const closeLit = struct {
                fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, il: *bool) void {
                    if (il.*) {
                        b.append(a, '"') catch unreachable;
                        il.* = false;
                    }
                }
            }.call;
            const is_string_literal = expr.len > 0 and expr[0] == '"';
            if (is_string_literal) {
                // Scan the INSIDE of the quotes — already-escaped, valid in a JS `"…"`.
                const end: usize = if (expr[expr.len - 1] == '"') expr.len - 1 else expr.len;
                const content = expr[1..end];
                var i: usize = 0;
                while (i < content.len) {
                    // {% if var %}body{% endif %} → + (var ? "body" : "") +
                    if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                        var ws_start = i + 2;
                        while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                        if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start .. ws_start + 3], "if ")) {
                            var var_pos = ws_start + 3;
                            while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}
                            var var_end = var_pos;
                            while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                            const cond_var = content[var_pos..var_end];
                            var tag_end = var_end;
                            while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}
                            if (tag_end + 1 < content.len) {
                                const body_start = tag_end + 2;
                                const endif_marker = "{% endif %}";
                                if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                    const body_end = body_start + endif_offset;
                                    const body_content = content[body_start..body_end];
                                    closeLit(&buf, allocator, &in_literal);
                                    if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                                    first = false;
                                    buf.append(allocator, '(') catch unreachable;
                                    buf.appendSlice(allocator, cond_var) catch unreachable;
                                    buf.appendSlice(allocator, " ? \"") catch unreachable;
                                    buf.appendSlice(allocator, body_content) catch unreachable; // verbatim — already escaped
                                    buf.appendSlice(allocator, "\" : \"\")") catch unreachable;
                                    i = body_end + endif_marker.len;
                                    continue;
                                }
                            }
                        }
                        // Unrecognized {% — treat as literal.
                        openLit(&buf, allocator, &first, &in_literal);
                        buf.append(allocator, content[i]) catch unreachable;
                        i += 1;
                    }
                    // {{ var:fmt }} → + var +  (fmt dropped — JS auto-stringifies)
                    else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                        var ws_start = i + 2;
                        while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                        var j = ws_start;
                        while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}
                        if (j + 1 < content.len) {
                            var ws_end = j;
                            while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}
                            closeLit(&buf, allocator, &in_literal);
                            if (first) {
                                // Seed string-concat context so a lone/leading numeric
                                // value is promoted to a string, never arithmetic-added
                                // (process.stdout.write demands a string arg).
                                buf.appendSlice(allocator, "\"\" + ") catch unreachable;
                                first = false;
                            } else {
                                buf.appendSlice(allocator, " + ") catch unreachable;
                            }
                            // Spec split + `:.N` precision + operand emission live in
                            // io.jsprec (line-baseline wall) — same honoring fmt's
                            // jsPlaceholder gives ln|js.
                            ioJsPlaceholderOperand(&buf, allocator, content[ws_start..ws_end]);
                            i = j + 2;
                        } else {
                            openLit(&buf, allocator, &first, &in_literal);
                            buf.append(allocator, content[i]) catch unreachable;
                            i += 1;
                        }
                    } else {
                        openLit(&buf, allocator, &first, &in_literal);
                        buf.append(allocator, content[i]) catch unreachable;
                        i += 1;
                    }
                }
                closeLit(&buf, allocator, &in_literal);
                // Empty template → emit `""` so write() gets a valid string arg.
                if (first) {
                    buf.appendSlice(allocator, "\"\"") catch unreachable;
                    first = false;
                }
            } else {
                // Bare expression: stringify the whole value; leading `""` forces
                // string-concat context so a Number is promoted, not arithmetic-added.
                buf.appendSlice(allocator, "\"\" + (") catch unreachable;
                buf.appendSlice(allocator, ioLowerJsExpr(allocator, expr)) catch unreachable;
                buf.append(allocator, ')') catch unreachable;
                first = false;
            }
            if (with_newline) {
                if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                buf.appendSlice(allocator, "\"\\n\"") catch unreachable;
            }
            const write_fn: []const u8 = if (to_fd == 2) "__koru_stderr_write" else "__koru_stdout_write";
            const inline_code = std.fmt.allocPrint(
                allocator,
                "{s}({s});",
                .{ write_fn, buf.items },
            ) catch unreachable;
            // Re-route to the [norun] print.impl tor for shape checking — the reroute
            // is analysis-only; the spliced inline_body does the write. Mirrors |zig's
            // __printInterpolate AST surgery (whole-struct copy, not a field literal).
            const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
            impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
            impl_segments[1] = allocator.dupe(u8, "impl") catch unreachable;
            const impl_path = ast.DottedPath{
                .module_qualifier = flow.inv().path.module_qualifier,
                .segments = impl_segments,
            };
            const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
            for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
            new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;
            const new_invocation = ast.Invocation{
                .path = impl_path,
                .args = flow.inv().args,
                .annotations = flow.inv().annotations,
                .marks = new_marks,
                .inserted_by_tap = flow.inv().inserted_by_tap,
                .from_opaque_tap = flow.inv().from_opaque_tap,
            };
            var transformed_flow = flow.*;
            transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
            transformed_flow.inline_body = inline_code;
            const new_item = ast.Item{ .flow = transformed_flow };
            return .{ .replacement = new_item };
        }
        // JS variants of the print family — selected on a --lang=js build, the way
        // print.blk|js is. Same fd + newline semantics as the |zig procs above, routed
        // through the shared __printInterpolateJs engine.
        // Koru Standard Library: I/O — JS placeholder operand emission.
        // Joined via `~part jsprec` in io.kz; merged into the io module at load.
        /// Emit one `{{ … }}` placeholder's VALUE operand for the JS concat
        /// `__printInterpolateJs` is building. The raw text between the braces arrives
        /// untrimmed; the spec after the first `:` is dropped — JS `+` promotes Numbers
        /// to strings on concat, so no per-spec mapping is needed — EXCEPT a `:.N`
        /// precision tail, which emits `Number(x).toFixed(N)`, the same honoring fmt's
        /// jsPlaceholder gives `ln|js` (same parse as it).
        ///
        /// A lone/leading operand is parenthesized so a multi-term expr (`{{ c + 1 }}`)
        /// is ONE operand — `"n=" + c + 1` would otherwise fold left-to-right to
        /// `"n=<c>" + 1` = "n=<c>1" instead of the sum.
        fn ioJsPlaceholderOperand(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) void {
            var ws_start: usize = 0;
            while (ws_start < raw.len and (raw[ws_start] == ' ' or raw[ws_start] == '\t')) : (ws_start += 1) {}
            var ws_end = raw.len;
            while (ws_end > ws_start and (raw[ws_end - 1] == ' ' or raw[ws_end - 1] == '\t')) : (ws_end -= 1) {}
            var var_name = raw[ws_start..ws_end];
            var precision: ?[]const u8 = null;
            if (std.mem.indexOf(u8, var_name, ":")) |colon_pos| {
                const spec = var_name[colon_pos + 1 ..];
                var_name = var_name[0..colon_pos];
                if (std.mem.indexOf(u8, spec, ":")) |p2| {
                    // `:.N` — the dot is the precision marker, digits after it are N.
                    const rest = spec[p2 + 1 ..];
                    if (rest.len > 1 and rest[0] == '.') {
                        const d = rest[1..];
                        var digits = true;
                        for (d) |c| digits = digits and c >= '0' and c <= '9';
                        if (digits) precision = d;
                    }
                }
            }
            if (precision) |d| {
                buf.appendSlice(allocator, "Number(") catch unreachable;
                buf.appendSlice(allocator, ioLowerJsExpr(allocator, var_name)) catch unreachable;
                buf.appendSlice(allocator, ").toFixed(") catch unreachable;
                buf.appendSlice(allocator, d) catch unreachable;
                buf.append(allocator, ')') catch unreachable;
            } else {
                buf.append(allocator, '(') catch unreachable;
                buf.appendSlice(allocator, ioLowerJsExpr(allocator, var_name)) catch unreachable;
                buf.append(allocator, ')') catch unreachable;
            }
        }
        // Koru Standard Library: I/O — CS placeholder operand + interpolation engine.
        // Joined via `~part csprec` in io.kz; merged into the io module at load.
        //
        // The K# vertical's print path. Same surface as __printInterpolateJs —
        // string-literal vs bare expression, `{{ var:fmt }}` placeholders,
        // `{% if v %}…{% endif %}` blocks — and nearly the same emitted text: `"" +
        // x + "lit"` is valid C# (string concat promotes the operand exactly like
        // JS), and `(cond ? "body" : "")` is the same ternary. What differs lives in
        // the two helpers here: exprs lower through the `.cs` arm (and/or, .len,
        // `++`, reserved words) and a `:.N` precision tail honors via
        // `.ToString("F"+N, InvariantCulture)` rather than JS's toFixed — C#'s
        // culture-sensitive formatting would otherwise answer "3,14" for "3.14" in
        // half the world's locales.
        // ============================================================================
        // CS-target interpolation engine — the __printInterpolateJs twin. SAME expr
        // surface, same reroute-to-print.impl surgery; only the emitted operand text
        // differs, and both helpers producing it live above.
        // ============================================================================
        fn __printInterpolateCs(
            expr: []const u8,
            item: anytype,
            allocator: std.mem.Allocator,
            comptime with_newline: bool,
            to_fd: u8,
        ) @import("ast").SiteResult {
            const ast = @import("ast");
            const flow = if (item.* == .flow)
                &item.flow
            else
                return .{};
            // Already transformed — don't re-run.
            if (flow.inline_body != null) {
                return .{};
            }
            var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
            var first = true;
            var in_literal = false;
            const openLit = struct {
                fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, f: *bool, il: *bool) void {
                    if (!il.*) {
                        if (!f.*) b.appendSlice(a, " + ") catch unreachable;
                        b.append(a, '"') catch unreachable;
                        il.* = true;
                        f.* = false;
                    }
                }
            }.call;
            const closeLit = struct {
                fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, il: *bool) void {
                    if (il.*) {
                        b.append(a, '"') catch unreachable;
                        il.* = false;
                    }
                }
            }.call;
            const is_string_literal = expr.len > 0 and expr[0] == '"';
            if (is_string_literal) {
                const end: usize = if (expr[expr.len - 1] == '"') expr.len - 1 else expr.len;
                const content = expr[1..end];
                var i: usize = 0;
                while (i < content.len) {
                    // {% if var %}body{% endif %} → + (var ? "body" : "") +
                    if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                        var ws_start = i + 2;
                        while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                        if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start .. ws_start + 3], "if ")) {
                            var var_pos = ws_start + 3;
                            while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}
                            var var_end = var_pos;
                            while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                            const cond_var = content[var_pos..var_end];
                            var tag_end = var_end;
                            while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}
                            if (tag_end + 1 < content.len) {
                                const body_start = tag_end + 2;
                                const endif_marker = "{% endif %}";
                                if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                    const body_end = body_start + endif_offset;
                                    const body_content = content[body_start..body_end];
                                    closeLit(&buf, allocator, &in_literal);
                                    if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                                    first = false;
                                    buf.append(allocator, '(') catch unreachable;
                                    buf.appendSlice(allocator, cond_var) catch unreachable;
                                    buf.appendSlice(allocator, " ? \"") catch unreachable;
                                    buf.appendSlice(allocator, body_content) catch unreachable; // verbatim — already escaped
                                    buf.appendSlice(allocator, "\" : \"\")") catch unreachable;
                                    i = body_end + endif_marker.len;
                                    continue;
                                }
                            }
                        }
                        // Unrecognized {% — treat as literal.
                        openLit(&buf, allocator, &first, &in_literal);
                        buf.append(allocator, content[i]) catch unreachable;
                        i += 1;
                    }
                    // {{ var:fmt }} → + (operand) +
                    else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                        var ws_start = i + 2;
                        while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                        var j = ws_start;
                        while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}
                        if (j + 1 < content.len) {
                            var ws_end = j;
                            while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}
                            closeLit(&buf, allocator, &in_literal);
                            if (first) {
                                // Seed string-concat context so a lone/leading numeric
                                // value promotes to a string, never arithmetic-adds
                                // (Console.Out.Write(object) would also work — the ""
                                // keeps the call typed string throughout).
                                buf.appendSlice(allocator, "\"\" + ") catch unreachable;
                                first = false;
                            } else {
                                buf.appendSlice(allocator, " + ") catch unreachable;
                            }
                            ioCsPlaceholderOperand(&buf, allocator, content[ws_start..ws_end]);
                            i = j + 2;
                        } else {
                            openLit(&buf, allocator, &first, &in_literal);
                            buf.append(allocator, content[i]) catch unreachable;
                            i += 1;
                        }
                    } else {
                        openLit(&buf, allocator, &first, &in_literal);
                        buf.append(allocator, content[i]) catch unreachable;
                        i += 1;
                    }
                }
                closeLit(&buf, allocator, &in_literal);
                // Empty template → emit `""` so write() gets a valid string arg.
                if (first) {
                    buf.appendSlice(allocator, "\"\"") catch unreachable;
                    first = false;
                }
            } else {
                // Bare expression: stringify the whole value; leading `""` forces
                // string-concat context so a Number is promoted, not arithmetic-added.
                buf.appendSlice(allocator, "\"\" + (") catch unreachable;
                buf.appendSlice(allocator, ioLowerCsExpr(allocator, expr)) catch unreachable;
                buf.append(allocator, ')') catch unreachable;
                first = false;
            }
            if (with_newline) {
                if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                buf.appendSlice(allocator, "\"\\n\"") catch unreachable;
            }
            const write_fn: []const u8 = if (to_fd == 2) "__koru_stderr_write" else "__koru_stdout_write";
            const inline_code = std.fmt.allocPrint(
                allocator,
                "{s}({s});",
                .{ write_fn, buf.items },
            ) catch unreachable;
            // Re-route to the [norun] print.impl tor for shape checking — identical
            // surgery to the zig/js engines; the spliced inline_body does the write.
            const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
            impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
            impl_segments[1] = allocator.dupe(u8, "impl") catch unreachable;
            const impl_path = ast.DottedPath{
                .module_qualifier = flow.inv().path.module_qualifier,
                .segments = impl_segments,
            };
            const new_inv_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
            for (flow.inv().marks, 0..) |m, idx| {
                new_inv_marks[idx] = m;
            }
            new_inv_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;
            const new_invocation = ast.Invocation{
                .path = impl_path,
                .args = flow.inv().args,
                .annotations = flow.inv().annotations, .marks = new_inv_marks,
                .inserted_by_tap = flow.inv().inserted_by_tap,
                .from_opaque_tap = flow.inv().from_opaque_tap,
            };
            var transformed_flow = flow.*;
            transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
            transformed_flow.inline_body = inline_code;
            const new_item = ast.Item{ .flow = transformed_flow };
            return .{ .replacement = new_item };
        }
        // CS variants of the print family — the K# vertical's first transform path.
        // Selected under --lang=cs the way print|js is under --lang=js; same fd +
        // newline semantics, routed through the shared __printInterpolateCs engine.
        // Koru Standard Library: I/O — C placeholder operand + interpolation engine.
        // Joined via `~part cprec` in io.kz; merged into the io module at load.
        //
        // The C verification lane's print path. C has no `"" + x` auto-stringify, so
        // the engine does NOT build a concatenation — it emits one
        // __koru_stdout_write()/__koru_stderr_write() call per chunk: literal text
        // verbatim, a `{{ ... }}` placeholder lowered through the `.c` arm and
        // passed as the call's sole operand. A non-string operand (print.ln(42))
        // therefore emits a call the C type system itself refuses at the oracle —
        // argument type mismatch — which is the fragment's honest gate: faithful
        // emission, typed refusal, never a silent reinterpretation.
        //
        // `:.N` precision is refused outright rather than dropped: emitting the
        // operand unpadded would change output bytes silently, and a refusal is the
        // only honest answer while the lane has no printf-family formatter.
        // ============================================================================
        // C placeholder operand — the ioJsPlaceholderOperand twin.
        // ============================================================================
        /// Emit one `{{ … }}` placeholder's operand for `__printInterpolateC`, and
        /// route its TYPE through `write_suffix`: the spec after `:` is the author's
        /// own type declaration, so `:d` writes through `__koru_stdout_write_i64`
        /// (long long), `:f` through `__koru_stdout_write_f64` (double), and `:s`
        /// (or a missing spec — the frontend's missing-spec check errors first)
        /// stays on the `const char *` write. Return codes: 0 ok; 1 — a `:.N`
        /// precision tail, REFUSED (no C formatter yet); 2 — `:S` handle form,
        /// REFUSED (pointer machinery is outside the first fragment). Anything else
        /// falls back to the string write, where a wrong-typed operand fails loudly
        /// at the oracle's typecheck — the fragment's typed gate.
        fn ioCPlaceholderOperand(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8, write_suffix: *[]const u8) u8 {
            var ws_start: usize = 0;
            while (ws_start < raw.len and (raw[ws_start] == ' ' or raw[ws_start] == '\t')) : (ws_start += 1) {}
            var ws_end = raw.len;
            while (ws_end > ws_start and (raw[ws_end - 1] == ' ' or raw[ws_end - 1] == '\t')) : (ws_end -= 1) {}
            var var_name = raw[ws_start..ws_end];
            var spec: []const u8 = "";
            var precision: ?[]const u8 = null;
            if (std.mem.indexOf(u8, var_name, ":")) |colon_pos| {
                spec = var_name[colon_pos + 1 ..];
                var_name = var_name[0..colon_pos];
                if (std.mem.indexOf(u8, spec, ":")) |p2| {
                    // `:.N` — the dot is the precision marker, digits after it are N.
                    const rest = spec[p2 + 1 ..];
                    if (rest.len > 1 and rest[0] == '.') {
                        const d = rest[1..];
                        var digits = true;
                        for (d) |c| digits = digits and c >= '0' and c <= '9';
                        if (digits) precision = d;
                    }
                    spec = spec[0..p2];
                }
            }
            if (precision != null) return 1;
            if (std.mem.eql(u8, spec, "d")) {
                write_suffix.* = "_i64";
            } else if (std.mem.eql(u8, spec, "f")) {
                write_suffix.* = "_f64";
            } else if (std.mem.eql(u8, spec, "S")) {
                return 2;
            } else {
                write_suffix.* = "";
            }
            buf.append(allocator, '(') catch unreachable;
            buf.appendSlice(allocator, ioLowerCExpr(allocator, var_name)) catch unreachable;
            buf.append(allocator, ')') catch unreachable;
            return 0;
        }
        // ============================================================================
        // C-target interpolation engine — the __printInterpolateCs twin. Same expr
        // surface, same reroute-to-print.impl surgery; what differs is the emitted
        // text shape (a statement LIST of write calls, not one concatenated arg).
        // ============================================================================
        fn __printInterpolateC(
            expr: []const u8,
            item: anytype,
            reporter: anytype,
            allocator: std.mem.Allocator,
            comptime with_newline: bool,
            to_fd: u8,
        ) @import("ast").SiteResult {
            const ast = @import("ast");
            const flow = if (item.* == .flow)
                &item.flow
            else
                return .{};
            // Already transformed — don't re-run.
            if (flow.inline_body != null) {
                return .{};
            }
            const write_fn: []const u8 = if (to_fd == 2) "__koru_stderr_write" else "__koru_stdout_write";
            var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
            var chunk = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
            const flush = struct {
                fn call(b: *std.ArrayList(u8), ch: *std.ArrayList(u8), a: std.mem.Allocator, w: []const u8) void {
                    if (ch.items.len == 0) return;
                    b.appendSlice(a, w) catch unreachable;
                    b.appendSlice(a, "(\"") catch unreachable;
                    b.appendSlice(a, ch.items) catch unreachable;
                    b.appendSlice(a, "\"); ") catch unreachable;
                    ch.clearRetainingCapacity();
                }
            }.call;
            const is_string_literal = expr.len > 0 and expr[0] == '"';
            var wrote_any = false;
            if (is_string_literal) {
                // Scan the INSIDE of the quotes — already-escaped, valid in a C "…".
                const end: usize = if (expr[expr.len - 1] == '"') expr.len - 1 else expr.len;
                const content = expr[1..end];
                var i: usize = 0;
                while (i < content.len) {
                    // {% if var %}body{% endif %} → write((var) ? "body" : "")
                    if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                        var ws_start = i + 2;
                        while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                        if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start .. ws_start + 3], "if ")) {
                            var var_pos = ws_start + 3;
                            while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}
                            var var_end = var_pos;
                            while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                            const cond_var = content[var_pos..var_end];
                            var tag_end = var_end;
                            while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}
                            if (tag_end + 1 < content.len) {
                                const body_start = tag_end + 2;
                                const endif_marker = "{% endif %}";
                                if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                    const body_end = body_start + endif_offset;
                                    const body_content = content[body_start..body_end];
                                    flush(&buf, &chunk, allocator, write_fn);
                                    buf.appendSlice(allocator, write_fn) catch unreachable;
                                    buf.appendSlice(allocator, "((") catch unreachable;
                                    buf.appendSlice(allocator, ioLowerCExpr(allocator, cond_var)) catch unreachable;
                                    buf.appendSlice(allocator, ") ? \"") catch unreachable;
                                    buf.appendSlice(allocator, body_content) catch unreachable; // verbatim — already escaped
                                    buf.appendSlice(allocator, "\" : \"\"); ") catch unreachable;
                                    wrote_any = true;
                                    i = body_end + endif_marker.len;
                                    continue;
                                }
                            }
                        }
                        // Unrecognized {% — treat as literal.
                        chunk.append(allocator, content[i]) catch unreachable;
                        i += 1;
                    }
                    // {{ var:fmt }} → write((lowered)); :.N refuses (see header).
                    else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                        var ws_start = i + 2;
                        while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}
                        var j = ws_start;
                        while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}
                        if (j + 1 < content.len) {
                            var ws_end = j;
                            while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}
                            flush(&buf, &chunk, allocator, write_fn);
                            var operand = std.ArrayList(u8).initCapacity(allocator, 32) catch unreachable;
                            var write_suffix: []const u8 = "";
                            const op_rc = ioCPlaceholderOperand(&operand, allocator, content[ws_start..ws_end], &write_suffix);
                            if (op_rc == 1) {
                                return ast.refuse(allocator, reporter, .KORU047, flow.location, flow.module, "std/io:print.ln|c: `:.N` precision has no C formatter yet — emitting the operand unpadded would change output bytes silently, so the lane refuses", .{});
                            }
                            if (op_rc == 2) {
                                return ast.refuse(allocator, reporter, .KORU047, flow.location, flow.module, "std/io:print.ln|c: `{{ :S }}` handle form is outside the first fragment — *String pointer machinery has no C lowering", .{});
                            }
                            buf.appendSlice(allocator, write_fn) catch unreachable;
                            buf.appendSlice(allocator, write_suffix) catch unreachable;
                            buf.append(allocator, '(') catch unreachable;
                            buf.appendSlice(allocator, operand.items) catch unreachable;
                            buf.appendSlice(allocator, "); ") catch unreachable;
                            wrote_any = true;
                            i = j + 2;
                        } else {
                            chunk.append(allocator, content[i]) catch unreachable;
                            i += 1;
                        }
                    } else {
                        chunk.append(allocator, content[i]) catch unreachable;
                        i += 1;
                    }
                }
                flush(&buf, &chunk, allocator, write_fn);
                if (chunk.items.len > 0) wrote_any = true;
            } else {
                // Bare expression: the operand must already be `const char *` — a
                // numeric arg emits a call the oracle's typecheck refuses (the
                // fragment's typed gate, see header).
                buf.appendSlice(allocator, write_fn) catch unreachable;
                buf.appendSlice(allocator, "((") catch unreachable;
                buf.appendSlice(allocator, ioLowerCExpr(allocator, expr)) catch unreachable;
                buf.appendSlice(allocator, ")); ") catch unreachable;
                wrote_any = true;
            }
            if (with_newline) {
                buf.appendSlice(allocator, write_fn) catch unreachable;
                buf.appendSlice(allocator, "(\"\\n\"); ") catch unreachable;
            } else if (!wrote_any) {
                // `print("")` — still one call, matching the other lanes' arity.
                buf.appendSlice(allocator, write_fn) catch unreachable;
                buf.appendSlice(allocator, "(\"\"); ") catch unreachable;
            }
            const inline_code = allocator.dupe(u8, buf.items) catch unreachable;
            // Re-route to the [norun] print.impl tor for shape checking — the reroute
            // is analysis-only; the spliced inline_body does the write. Mirrors the
            // js/cs engines' whole-struct copy.
            const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
            impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
            impl_segments[1] = allocator.dupe(u8, "impl") catch unreachable;
            const impl_path = ast.DottedPath{
                .module_qualifier = flow.inv().path.module_qualifier,
                .segments = impl_segments,
            };
            const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
            for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
            new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;
            const new_invocation = ast.Invocation{
                .path = impl_path,
                .args = flow.inv().args,
                .annotations = flow.inv().annotations,
                .marks = new_marks,
                .inserted_by_tap = flow.inv().inserted_by_tap,
                .from_opaque_tap = flow.inv().from_opaque_tap,
            };
            var transformed_flow = flow.*;
            transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
            transformed_flow.inline_body = inline_code;
            const new_item = ast.Item{ .flow = transformed_flow };
            return .{ .replacement = new_item };
        }
        // C variants of the print family — selected under --lang=c the way print|js
        // is under --lang=js; same fd + newline semantics, routed through
        // __printInterpolateC.
        // Koru Standard Library: the `lowers` part of io.kz.
        // Joined via `~part lowers` in io.kz; merged into the io module at load.
        //
        // The `{{ … }}` interpolation doors — one per host vocabulary arm. Both
        // engines splice a Koru expression into host text through these twins;
        // they live together because a fix to the lowering contract lands in
        // both places or in neither.
        /// A `{{ … }}` INTERPOLATION IS A KORU EXPRESSION, and this builder splices it
        /// into JavaScript. It is the third door onto the same pass — after `std/store`'s
        /// guards and `std/kernel`'s op bodies — and it was the last one still writing
        /// the text through raw.
        ///
        /// What that cost: `print.ln("… {{ new:s }}")` over `! updated { old, new }`
        /// emitted a bare `new` into the concatenation, and node refused the file. It
        /// also meant an interpolation naming `a and b` or `@as(i64, x)` reached node
        /// unlowered, which nothing had noticed because no test interpolates one.
        ///
        /// Refusal is swallowed rather than reported: an unmodelled `@`-operation here
        /// falls back to the raw text, which is what this site did for every expression
        /// until now, so the failure mode is unchanged rather than newly silent. The
        /// diagnostic belongs with the print transform's own error surface and that is a
        /// separate job.
        fn ioLowerJsExpr(alloc: std.mem.Allocator, text: []const u8) []const u8 {
            var d = codegen_utils_io.LowerDiag{};
            return codegen_utils_io.lowerKoruExpr(alloc, text, .js, .koru_expr, &d) catch text;
        }
        /// The third door's cs twin: a `{{ … }}` interpolation is a Koru expression,
        /// lowered through the `.cs` vocabulary arm. Same swallowed-refusal contract
        /// as ioLowerJsExpr — an unmodelled operation falls back to raw text (the
        /// pre-lowering behavior), the diagnostic surface being a separate job.
        fn ioLowerCsExpr(alloc: std.mem.Allocator, text: []const u8) []const u8 {
            var d = codegen_utils_io.LowerDiag{};
            return codegen_utils_io.lowerKoruExpr(alloc, text, .cs, .koru_expr, &d) catch text;
        }
        /// The third door's c twin: a `{{ … }}` interpolation is a Koru expression,
        /// lowered through the `.c` vocabulary arm. Same swallowed-refusal contract
        /// as ioLowerJsExpr — an unmodelled operation falls back to raw text, and
        /// the emitted C refusing at the oracle is the fragment's honest gate.
        fn ioLowerCExpr(alloc: std.mem.Allocator, text: []const u8) []const u8 {
            var d = codegen_utils_io.LowerDiag{};
            return codegen_utils_io.lowerKoruExpr(alloc, text, .c, .koru_expr, &d) catch text;
        }
        // Koru Standard Library: the `blkcs` part of io.kz.
        // Joined via `~part blkcs` in io.kz; merged into the io module at load.
        //
        // print.blk|cs — the C#-target variant of the block-print transform, ported
        // from print.blk|js in io.blk.kz. Same scan: `{% if v %}…{% endif %}` →
        // `(v ? "escaped" : "")` (C#'s ternary is the same shape), `{{ var:fmt }}` →
        // the ioCsPlaceholderOperand door (parens + .cs lowering + the :.N honoring),
        // literal runs escaped into `"…"` segments, all joined by ` + ` — C# string
        // concat promotes the operand exactly like JS.
        //
        // Newline: JS's console.log appends one, so |js strips a trailing `\n` from
        // the template content. __koru_stdout_write is a bare Write — the same strip
        // applies, then the newline is re-added inside the concat, so the emitted
        // program writes exactly what |zig's raw_posix writes.
        /// Emit one `{{ … }}` placeholder's VALUE operand for the C# concat
        /// `__printInterpolateCs` is building — the ioJsPlaceholderOperand twin.
        /// The spec after the first `:` is dropped (C# string concat ToString()s the
        /// operand, same promotion rule as JS) — EXCEPT a `:.N` precision tail, which
        /// emits `(x).ToString("F"+N, InvariantCulture)`: culture-invariant so a
        /// French locale doesn't answer "3,14".
        fn ioCsPlaceholderOperand(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) void {
            var ws_start: usize = 0;
            while (ws_start < raw.len and (raw[ws_start] == ' ' or raw[ws_start] == '\t')) : (ws_start += 1) {}
            var ws_end = raw.len;
            while (ws_end > ws_start and (raw[ws_end - 1] == ' ' or raw[ws_end - 1] == '\t')) : (ws_end -= 1) {}
            var var_name = raw[ws_start..ws_end];
            var precision: ?[]const u8 = null;
            var handle_deref = false;
            if (std.mem.indexOf(u8, var_name, ":")) |colon_pos| {
                const spec = var_name[colon_pos + 1 ..];
                var_name = var_name[0..colon_pos];
                // `:S` is the owned-handle form (610_007): print the payload, not the
                // handle — the zig arm's `args[i].data` spelled `(i).data` here.
                if (std.mem.eql(u8, spec, "S")) handle_deref = true;
                if (std.mem.indexOf(u8, spec, ":")) |p2| {
                    // `:.N` — the dot is the precision marker, digits after it are N.
                    const rest = spec[p2 + 1 ..];
                    if (rest.len > 1 and rest[0] == '.') {
                        const d = rest[1..];
                        var digits = true;
                        for (d) |c| digits = digits and c >= '0' and c <= '9';
                        if (digits) precision = d;
                    }
                }
            }
            if (precision) |d| {
                buf.append(allocator, '(') catch unreachable;
                buf.appendSlice(allocator, ioLowerCsExpr(allocator, var_name)) catch unreachable;
                buf.appendSlice(allocator, ").ToString(\"F") catch unreachable;
                buf.appendSlice(allocator, d) catch unreachable;
                buf.appendSlice(allocator, "\", global::System.Globalization.CultureInfo.InvariantCulture)") catch unreachable;
            } else {
                // `__koru_str` unwraps a bool operand to `true`/`false` — C#
                // ToString would answer `True`, and the `is bool` test has to live
                // behind `dynamic` (a statically-typed operand can't spell it).
                buf.appendSlice(allocator, "__koru_str(") catch unreachable;
                buf.appendSlice(allocator, ioLowerCsExpr(allocator, var_name)) catch unreachable;
                if (handle_deref) buf.appendSlice(allocator, ".data") catch unreachable;
                buf.append(allocator, ')') catch unreachable;
            }
        }
        // Koru Standard Library: the `console` part of io.kz — joined via
        // `~part console` in io.kz; merged into the io module at load.
        // Console messaging tors: stderr error, success, warning.
        // Print error to stderr
        // Success message with green color (if terminal supports it)
        // Warning message
        // Koru Standard Library: I/O — the `print.blk` family.
        // Joined via `~part blk` in io.kz; merged into the io module at load.
        // Lifted out of io.kz so both files stay under their line baselines;
        // module-scope names (KORU_OUT_FN, __appendFmtLiteralByte,
        // codegen_utils_io, the expr_parser idiom) resolve through the merge.
        // ============================================================================
        // PRINT.BLK - Multi-line block printing with Source block (ZERO OVERHEAD)
        // ============================================================================
        //
        // Syntax: std/io:print.blk {
        //     Header: {{ title }}
        //     Value:  {{ count }}
        // }
        //
        // ARCHITECTURE:
        // - Takes a Source block (multi-line text)
        // - Parses {{ ... }} and {% if %} placeholders
        // - Generates inline Zig print statement
        //
        // This is NOT a regular tor - it's a pure compile-time transformation.
        // ============================================================================
        // PRINT.BLK|RAW_POSIX - raw I/O fast path variant for linux/macos
        // ============================================================================
        // Selected via [build(linux)] / [build(macos)] std/build:variants below.
        // Emits inline posix.write calls when all placeholders use :d or :s specifiers.
        // Falls back to std.debug.print only when complex format specifiers (:any, :f)
        // are used. The raw path produces 1,728 B ELF binaries vs 7 KB for stdlib.
        // ============================================================================
        // PRINT.BLK|JS - JavaScript-target variant (EXPERIMENTAL STUB)
        // ============================================================================
        // What the |js tag means HERE is different from what it means on a runtime
        // proc. On runtime procs, |js = "this body is JavaScript, JS emitter splices
        // it." On a [comptime|transform] proc, the body must be Zig (the compiler's
        // host language). So |js here means: "this transform variant produces JS
        // output, body is structurally Zig."
        //
        // First-pass STUB: ignores the template content, emits a fixed `console.log`.
        // Purpose is to validate that (a) the parser accepts a |js variant alongside
        // |zig and |raw_posix on a comptime transform, and (b) some dispatch
        // mechanism actually selects it when --lang=js. Once we know the path is
        // open, the Liquid template parsing logic from |zig can be ported over and
        // only the OUTPUT shape (Zig `std.debug.print` → JS `console.log + concat`)
        // changes.
        // ============================================================================
        // VARIANT REGISTRATION - Platform-specific dispatch for print.blk
        // ============================================================================
        // On linux/macos, route std.io:print.blk → raw_posix variant (raw posix.write).
        // On windows, the bare proc print.blk (std.debug.print) is used by default.
        // build=<host_os> is auto-injected by koruc; users can override with --build=<other>.
        pub const print_event = struct {
            pub const Input = struct {
                expr: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                reporter: *koru_std.koru_compiler.ErrorReporter,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: print  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:731]
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolate(expr, item, reporter, allocator, false, "print", 1);

            }
            pub fn handler__js(__koru_event_input: @This().Input) @This().Output { // |js
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateJs(expr, item, allocator, false, 1);

            }
            pub fn handler__cs(__koru_event_input: @This().Input) @This().Output { // |cs
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateCs(expr, item, allocator, false, 1);

            }
            pub fn handler__c(__koru_event_input: @This().Input) @This().Output { // |c
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateC(expr, item, reporter, allocator, false, 1);

            }
        };
        pub const readln_event = struct {
            pub const Input = struct {
            };
            pub const Output = union(enum(u8)) {
                line: []const u8,
                eof: struct {
                },
                failed: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: readln  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:56]
                _ = &__koru_event_input;

                    const stdin = std.fs.File.stdin();
                    var i: usize = 0;
                    while (i < readln_buf.len) {
                        var b: [1]u8 = undefined;
                        const n = stdin.read(b[0..]) catch return .{ .failed = "Failed to read stdin" };
                        if (n == 0) {
                            if (i == 0) return .{ .eof = .{} };
                            return .{ .line = readln_buf[0..i] };
                        }
                        if (b[0] == '\n') {
                            if (i > 0 and readln_buf[i - 1] == '\r') i -= 1;
                            return .{ .line = readln_buf[0..i] };
                        }
                        readln_buf[i] = b[0];
                        i += 1;
                    }
                    return .{ .failed = "line too long" };

            }
        };
        pub const read_ln_event = struct {
            pub const Input = struct {
            };
            pub const Output = []const u8;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: read.ln  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:80]
                _ = &__koru_event_input;

                    const stdin = std.fs.File.stdin();
                    var buf: [4096]u8 = undefined;
                    const n = stdin.read(&buf) catch return "";
                    if (n == 0) return "";
                    // Find newline and exclude it
                    var end: usize = 0;
                    while (end < n and buf[end] != '\n') : (end += 1) {}
                    const duped = koru_allocator().dupe(u8, buf[0..end]) catch "";
                    return duped;

            }
        };
        pub const read_lines_event = struct {
            pub const Input = struct {
            };
            pub const Output = union(enum(u8)) {
                done: usize,
                failed: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input, comptime __H: type) @This().Output {
                const line = __H.line;
                _ = &line;
                // >>> PROC: read_lines  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:119]
                _ = &__koru_event_input;

                    // HYGIENE: this body INLINES into the consumer's frame (effect
                    // lowering), so locals are __koru-prefixed to never collide with
                    // user bindings in the surrounding flow.
                    const __koru_rl_stdin = std.fs.File.stdin();
                    const __koru_rl_content = __koru_rl_stdin.readToEndAlloc(koru_allocator(), std.math.maxInt(usize)) catch |err| {
                        const __koru_rl_msg = switch (err) {
                            error.OutOfMemory => "Out of memory reading stdin",
                            else => "Failed to read stdin",
                        };
                        return .{ .failed = __koru_rl_msg };
                    };
                    defer koru_allocator().free(__koru_rl_content);

                    var __koru_rl_n: usize = 0;
                    var __koru_rl_it = std.mem.splitScalar(u8, __koru_rl_content, '\n');
                    while (__koru_rl_it.next()) |__koru_rl_raw| {
                        if (__koru_rl_raw.len == 0 and __koru_rl_it.peek() == null) break;
                        const __koru_rl_l = if (__koru_rl_raw.len > 0 and __koru_rl_raw[__koru_rl_raw.len - 1] == '\r') __koru_rl_raw[0 .. __koru_rl_raw.len - 1] else __koru_rl_raw;
                        line(__koru_rl_l);
                        __koru_rl_n += 1;
                    }
                    return .{ .done = __koru_rl_n };

            }
        };
        pub const read_stdin_event = struct {
            pub const Input = struct {
            };
            pub const Output = union(enum(u8)) {
                ok: []const u8,
                eof: struct {
                },
                failed: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: read_stdin  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:155]
                _ = &__koru_event_input;

                    const stdin = std.fs.File.stdin();
                    const content = stdin.readToEndAlloc(koru_allocator(), std.math.maxInt(usize)) catch |err| {
                        const msg = switch (err) {
                            error.OutOfMemory => "Out of memory reading stdin",
                            else => "Failed to read stdin",
                        };
                        return .{ .failed = msg };
                    };

                    if (content.len == 0) {
                        return .{ .eof = .{} };
                    }

                    return .{ .ok = content };

            }
        };
        pub const read_file_event = struct {
            pub const Input = struct {
                path: []const u8,
            };
            pub const Output = union(enum(u8)) {
                ok: []const u8,
                not_found: struct {
                },
                failed: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: read_file  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:179]
                const path = __koru_event_input.path;
                _ = &path;
                _ = &__koru_event_input;

                    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                        return switch (err) {
                            error.FileNotFound => .{ .not_found = .{} },
                            error.AccessDenied => .{ .failed = "Access denied" },
                            error.IsDir => .{ .failed = "Path is a directory" },
                            else => .{ .failed = "Failed to open file" },
                        };
                    };
                    defer file.close();

                    const content = file.readToEndAlloc(koru_allocator(), std.math.maxInt(usize)) catch |err| {
                        const msg = switch (err) {
                            error.OutOfMemory => "Out of memory reading file",
                            else => "Failed to read file",
                        };
                        return .{ .failed = msg };
                    };

                    return .{ .ok = content };

            }
        };
        pub const free_event = struct {
            pub const Input = struct {
                content: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: free  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:205]
                const content = __koru_event_input.content;
                _ = &content;
                _ = &__koru_event_input;

                    koru_allocator().free(content);

            }
        };
        pub const args_event = struct {
            pub const Input = struct {
            };
            pub const Output = []const []const u8;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: args  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:217]
                _ = &__koru_event_input;

                    var arg_list = std.ArrayList([]const u8).init(koru_allocator());
                    var iter = std.process.args();
                    while (iter.next()) |arg| {
                        arg_list.append(arg) catch continue;
                    }
                    return arg_list.toOwnedSlice() catch &.{};

            }
        };
        pub const print_ln_event = struct {
            pub const Input = struct {
                expr: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                reporter: *koru_std.koru_compiler.ErrorReporter,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: print.ln  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:725]
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolate(expr, item, reporter, allocator, true, "print.ln", 1);

            }
            pub fn handler__js(__koru_event_input: @This().Input) @This().Output { // |js
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateJs(expr, item, allocator, true, 1);

            }
            pub fn handler__cs(__koru_event_input: @This().Input) @This().Output { // |cs
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateCs(expr, item, allocator, true, 1);

            }
            pub fn handler__c(__koru_event_input: @This().Input) @This().Output { // |c
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateC(expr, item, reporter, allocator, true, 1);

            }
        };
        pub const print_impl_event = struct {
            pub const Input = struct {
                expr: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const eprint_ln_event = struct {
            pub const Input = struct {
                expr: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                reporter: *koru_std.koru_compiler.ErrorReporter,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: eprint.ln  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:739]
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolate(expr, item, reporter, allocator, true, "eprint.ln", 2);

            }
            pub fn handler__js(__koru_event_input: @This().Input) @This().Output { // |js
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateJs(expr, item, allocator, true, 2);

            }
            pub fn handler__cs(__koru_event_input: @This().Input) @This().Output { // |cs
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateCs(expr, item, allocator, true, 2);

            }
            pub fn handler__c(__koru_event_input: @This().Input) @This().Output { // |c
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateC(expr, item, reporter, allocator, true, 2);

            }
        };
        pub const eprint_event = struct {
            pub const Input = struct {
                expr: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                reporter: *koru_std.koru_compiler.ErrorReporter,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: eprint  [/Users/larsde/src/koru-cypoe/koru_std/io.kz:745]
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolate(expr, item, reporter, allocator, false, "eprint", 2);

            }
            pub fn handler__js(__koru_event_input: @This().Input) @This().Output { // |js
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateJs(expr, item, allocator, false, 2);

            }
            pub fn handler__cs(__koru_event_input: @This().Input) @This().Output { // |cs
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateCs(expr, item, allocator, false, 2);

            }
            pub fn handler__c(__koru_event_input: @This().Input) @This().Output { // |c
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    _ = &invocation;
                    _ = &program;
                    return __printInterpolateC(expr, item, reporter, allocator, false, 2);

            }
        };
        pub const eprintln_event = struct {
            pub const Input = struct {
                message: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: eprintln  [/Users/larsde/src/koru-cypoe/koru_std/io.console.kz:8]
                const message = __koru_event_input.message;
                _ = &message;
                _ = &__koru_event_input;

                    const stderr = std.fs.File.stderr().writer();
                    stderr.print("ERROR: {s}\n", .{message}) catch {
                        // Fall back to debug print if stderr fails
                        std.debug.print("ERROR: {s}\n", .{message});
                    };

            }
        };
        pub const success_event = struct {
            pub const Input = struct {
                message: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: success  [/Users/larsde/src/koru-cypoe/koru_std/io.console.kz:19]
                const message = __koru_event_input.message;
                _ = &message;
                _ = &__koru_event_input;

                    std.debug.print("✅ {s}\n", .{message});

            }
        };
        pub const warn_event = struct {
            pub const Input = struct {
                message: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: warn  [/Users/larsde/src/koru-cypoe/koru_std/io.console.kz:26]
                const message = __koru_event_input.message;
                _ = &message;
                _ = &__koru_event_input;

                    std.debug.print("⚠️  {s}\n", .{message});

            }
        };
        pub const print_blk_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                reporter: *koru_std.koru_compiler.ErrorReporter,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: print.blk  [/Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:36]
                const source = __koru_event_input.source;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &source;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    const ast = @import("ast");

                    // Helper: Check if identifier is a Zig keyword
                    const isZigKeyword = struct {
                        fn check(word: []const u8) bool {
                            const keywords = [_][]const u8{
                                "error", "type", "async", "await", "suspend", "resume",
                                "try", "catch", "if", "else", "switch", "while",
                                "for", "break", "continue", "return", "defer", "errdefer",
                                "test", "pub", "export", "extern", "packed", "inline",
                                "noinline", "comptime", "nosuspend", "volatile", "allowzero",
                                "align", "linksection", "callconv", "noalias",
                                "struct", "enum", "union", "opaque", "fn", "const",
                                "var", "anyframe", "anytype", "anyerror", "unreachable",
                                "undef", "null", "true", "false", "and", "or",
                                "orelse", "threadlocal",
                            };
                            for (keywords) |kw| {
                                if (std.mem.eql(u8, word, kw)) return true;
                            }
                            // Zig primitive names — a local may not shadow them, so they
                            // escape exactly like keywords (230_018).
                            const primitives = [_][]const u8{
                                "bool",         "void",     "noreturn", "anyopaque",
                                "usize",        "isize",    "f16",      "f32",
                                "f64",          "f80",      "f128",     "undefined",
                                "comptime_int", "comptime_float",       "c_char",
                                "c_short",      "c_ushort", "c_int",    "c_uint",
                                "c_long",       "c_ulong",  "c_longlong",
                                "c_ulonglong",  "c_longdouble",
                            };
                            for (primitives) |p| {
                                if (std.mem.eql(u8, word, p)) return true;
                            }
                            // u<digits> / i<digits> — the arbitrary-width integer family.
                            if (word.len >= 2 and (word[0] == 'u' or word[0] == 'i')) {
                                var all_digits = true;
                                for (word[1..]) |c| {
                                    if (c < '0' or c > '9') all_digits = false;
                                }
                                if (all_digits) return true;
                            }
                            return false;
                        }
                    }.check;

                    // Helper: Append path with escaped keywords
                    const appendEscapedPath = struct {
                        fn append(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) void {
                            var start: usize = 0;
                            var pos: usize = 0;
                            var is_first = true;

                            while (pos <= path.len) {
                                if (pos == path.len or path[pos] == '.') {
                                    const segment = path[start..pos];
                                    if (!is_first) {
                                        buf.append(alloc, '.') catch unreachable;
                                        if (isZigKeyword(segment)) {
                                            buf.appendSlice(alloc, "@\"") catch unreachable;
                                            buf.appendSlice(alloc, segment) catch unreachable;
                                            buf.append(alloc, '"') catch unreachable;
                                        } else {
                                            buf.appendSlice(alloc, segment) catch unreachable;
                                        }
                                    } else if (isZigKeyword(segment)) {
                                        // A bare binding may legally collide with a Zig
                                        // keyword or primitive (`: u1` — 230_018); the first
                                        // segment escapes like any other.
                                        buf.appendSlice(alloc, "@\"") catch unreachable;
                                        buf.appendSlice(alloc, segment) catch unreachable;
                                        buf.append(alloc, '"') catch unreachable;
                                    } else {
                                        buf.appendSlice(alloc, segment) catch unreachable;
                                    }
                                    is_first = false;
                                    start = pos + 1;
                                }
                                pos += 1;
                            }
                        }
                    }.append;

                    // Get the flow from the item (flows with impl context now use item.flow with impl_of set)
                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    const isSameInvocation = struct {
                        fn check(a: *const ast.Invocation, b: *const ast.Invocation) bool {
                            if (a.path.module_qualifier) |amq| {
                                if (b.path.module_qualifier) |bmq| {
                                    if (!std.mem.eql(u8, amq, bmq)) return false;
                                } else {
                                    return false;
                                }
                            } else if (b.path.module_qualifier != null) {
                                return false;
                            }

                            if (a.path.segments.len != b.path.segments.len) return false;
                            for (a.path.segments, 0..) |seg, seg_i| {
                                if (!std.mem.eql(u8, seg, b.path.segments[seg_i])) return false;
                            }

                            if (a.args.len != b.args.len) return false;
                            for (a.args, 0..) |arg, arg_i| {
                                const other = b.args[arg_i];
                                if (!std.mem.eql(u8, arg.name, other.name)) return false;
                                if (arg.value.len > 0 and other.value.len > 0 and !std.mem.eql(u8, arg.value, other.value)) return false;
                            }
                            return true;
                        }
                    }.check;

                    // Position-agnostic: the runner lifts nested sites into a synthetic
                    // top-level flow, so `invocation` IS the flow's own invocation at every depth.
                    _ = &invocation;
                    _ = isSameInvocation; // keep for now; value match is not a top-level signal

                    // Parse the Source content for {{ ... }} placeholders
                    var format_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                    var args_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
                    var i: usize = 0;
                    var first_arg = true;

                    var missing_spec: ?[]const u8 = null;
                    var function_call_expr: ?[]const u8 = null;
                    var keyed_placeholder: ?[]const u8 = null;

                    // Use the expression parser to detect function calls properly
                    const expr_parser = @import("expression_parser");

                    const content = source.text;

                    while (i < content.len) {
                        // Look for {% if var %}...{% endif %} control blocks
                        if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                            const tag_start = i + 2;
                            // Skip whitespace after {%
                            var ws_start = tag_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            // Check for "if " keyword
                            if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start..ws_start + 3], "if ")) {
                                const var_start = ws_start + 3;
                                // Skip whitespace after "if"
                                var var_pos = var_start;
                                while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}

                                // Find end of variable name
                                var var_end = var_pos;
                                while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                                const cond_var = content[var_pos..var_end];

                                // Find closing %}
                                var tag_end = var_end;
                                while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}

                                if (tag_end + 1 < content.len) {
                                    const body_start = tag_end + 2;

                                    // Find matching {% endif %}
                                    const endif_marker = "{% endif %}";
                                    if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                        const body_end = body_start + endif_offset;
                                        const body_content = content[body_start..body_end];

                                        format_buf.appendSlice(allocator, "{s}") catch unreachable;

                                        if (!first_arg) {
                                            args_buf.appendSlice(allocator, ", ") catch unreachable;
                                        }
                                        args_buf.appendSlice(allocator, "if (") catch unreachable;
                                        appendEscapedPath(&args_buf, allocator, cond_var);
                                        args_buf.appendSlice(allocator, ") \"") catch unreachable;
                                        for (body_content) |c| {
                                            switch (c) {
                                                '"' => args_buf.appendSlice(allocator, "\\\"") catch unreachable,
                                                '\\' => args_buf.appendSlice(allocator, "\\\\") catch unreachable,
                                                '\n' => args_buf.appendSlice(allocator, "\\n") catch unreachable,
                                                '\r' => args_buf.appendSlice(allocator, "\\r") catch unreachable,
                                                '\t' => args_buf.appendSlice(allocator, "\\t") catch unreachable,
                                                else => args_buf.append(allocator, c) catch unreachable,
                                            }
                                        }
                                        args_buf.appendSlice(allocator, "\" else \"\"") catch unreachable;
                                        first_arg = false;

                                        i = body_end + endif_marker.len;
                                        continue;
                                    }
                                }
                            }
                            // Not a recognized tag, treat as literal
                            switch (content[i]) {
                                '"' => {
                                    format_buf.appendSlice(allocator, "\\\"") catch unreachable;
                                },
                                '\\' => {
                                    format_buf.appendSlice(allocator, "\\\\") catch unreachable;
                                },
                                '\n' => {
                                    format_buf.appendSlice(allocator, "\\n") catch unreachable;
                                },
                                '\r' => {
                                    format_buf.appendSlice(allocator, "\\r") catch unreachable;
                                },
                                '\t' => {
                                    format_buf.appendSlice(allocator, "\\t") catch unreachable;
                                },
                                else => __appendFmtLiteralByte(&format_buf, allocator, content[i]),
                            }
                            i += 1;
                        }
                        // Look for {{ ... }} placeholders
                        else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                            const placeholder_start = i + 2;
                            // Skip leading whitespace
                            var ws_start = placeholder_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            // Find closing }}
                            var j = ws_start;
                            while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}

                            if (j + 1 < content.len) {
                                // Trim trailing whitespace
                                var ws_end = j;
                                while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}

                                const placeholder = content[ws_start..ws_end];
                                var var_name: []const u8 = placeholder;
                                var format_spec: []const u8 = "any";
                                var has_spec = false;

                                // Keyed addressing `store[key: value]` is a pinned hole
                                // (690_018): the `key:` decl emits no lookup machinery, and
                                // the bracket `:` would misfire the format-spec split below.
                                // Honor or refuse: refuse, before either defect runs.
                                if (keyed_placeholder == null and codegen_utils_io.colonInsideBrackets(placeholder)) {
                                    keyed_placeholder = placeholder;
                                }

                                // Check for format specifier
                                if (std.mem.indexOf(u8, placeholder, ":")) |colon_pos| {
                                    var_name = placeholder[0..colon_pos];
                                    format_spec = placeholder[colon_pos + 1..];
                                    has_spec = true;
                                }

                                // Function call check: parse the expression and check for
                                // USER function calls. The store rewriters splice their
                                // synthesized `__koru_resolve` handle deref into hole text
                                // after admission; that machinery call is not the user's.
                                if (function_call_expr == null) {
                                    var parser = expr_parser.ExpressionParser.init(allocator, var_name);
                                    defer parser.deinit();
                                    if (parser.parse()) |parsed_expr| {
                                        if (expr_parser.containsUserFunctionCall(parsed_expr)) {
                                            function_call_expr = var_name;
                                        }
                                    } else |_| {
                                        // Parse failed - let the Zig compiler catch it later
                                    }
                                }

                                // Missing specifier: record error (first one only)
                                if (!has_spec and missing_spec == null) {
                                    missing_spec = placeholder;
                                }

                                // :f maps to {} in Zig (default float format — Zig has no {f})
                                const zig_fmt_spec_blk = if (std.mem.eql(u8, format_spec, "f")) "" else format_spec;
                                format_buf.append(allocator, '{') catch unreachable;
                                format_buf.appendSlice(allocator, zig_fmt_spec_blk) catch unreachable;
                                format_buf.append(allocator, '}') catch unreachable;

                                if (!first_arg) {
                                    args_buf.appendSlice(allocator, ", ") catch unreachable;
                                }
                                appendEscapedPath(&args_buf, allocator, var_name);
                                first_arg = false;

                                i = j + 2;
                            } else {
                                switch (content[i]) {
                                    '"' => {
                                        format_buf.appendSlice(allocator, "\\\"") catch unreachable;
                                    },
                                    '\\' => {
                                        format_buf.appendSlice(allocator, "\\\\") catch unreachable;
                                    },
                                    '\n' => {
                                        format_buf.appendSlice(allocator, "\\n") catch unreachable;
                                    },
                                    '\r' => {
                                        format_buf.appendSlice(allocator, "\\r") catch unreachable;
                                    },
                                    '\t' => {
                                        format_buf.appendSlice(allocator, "\\t") catch unreachable;
                                    },
                                    else => __appendFmtLiteralByte(&format_buf, allocator, content[i]),
                                }
                                i += 1;
                            }
                        } else {
                            // Escape special characters for Zig string literal
                            switch (content[i]) {
                                '"' => {
                                    format_buf.appendSlice(allocator, "\\\"") catch unreachable;
                                },
                                '\\' => {
                                    format_buf.appendSlice(allocator, "\\\\") catch unreachable;
                                },
                                '\n' => {
                                    format_buf.appendSlice(allocator, "\\n") catch unreachable;
                                },
                                '\r' => {
                                    format_buf.appendSlice(allocator, "\\r") catch unreachable;
                                },
                                '\t' => {
                                    format_buf.appendSlice(allocator, "\\t") catch unreachable;
                                },
                                else => __appendFmtLiteralByte(&format_buf, allocator, content[i]),
                            }
                            i += 1;
                        }
                    }

                    // Add final newline if not present
                    if (format_buf.items.len < 2 or
                        format_buf.items[format_buf.items.len - 2] != '\\' or
                        format_buf.items[format_buf.items.len - 1] != 'n')
                    {
                        format_buf.appendSlice(allocator, "\\n") catch unreachable;
                    }

                    const inline_code = if (function_call_expr) |fn_expr| kblk3: {
                        reporter.addErrorAtLocation(.KORU168, flow.location, "std/io:print.blk: '{{{{ {s} }}}}' contains a function call — function calls are not allowed in expressions. Use tor chaining instead.", .{fn_expr}) catch {};
                        break :kblk3 std.fmt.allocPrint(
                            allocator,
                            "@compileError(\"std/io:print.blk: '{{{{ {s} }}}}' contains a function call — function calls are not allowed in expressions. Use tor chaining instead.\");",
                            .{fn_expr}
                        ) catch unreachable;
                    }
                    else if (keyed_placeholder) |placeholder| kblk_keyed: {
                        reporter.addErrorAtLocation(.KORU168, flow.location, "std/io:print.blk: '{{{{ {s} }}}}' uses keyed addressing 'store[key: value]' - a pinned hole (690_018); bind the row's handle and interpolate store[handle].field instead", .{placeholder}) catch {};
                        break :kblk_keyed std.fmt.allocPrint(
                            allocator,
                            "@compileError(\"std/io:print.blk: '{{{{ {s} }}}}' uses keyed addressing - a pinned hole (690_018); use store[handle].field\");",
                            .{placeholder}
                        ) catch unreachable;
                    }
                    else if (missing_spec) |placeholder| kblk4: {
                        reporter.addErrorAtLocation(.KORU168, flow.location, "std/io:print.blk: '{{{{ {s} }}}}' requires a format specifier (:d, :s, :f, or :any)", .{placeholder}) catch {};
                        break :kblk4 std.fmt.allocPrint(
                            allocator,
                            "@compileError(\"std/io:print.blk: '{{{{ {s} }}}}' requires a format specifier (:d, :s, :f, or :any)\");",
                            .{placeholder}
                        ) catch unreachable;
                    }
                    else
                        // print.blk -> stdout (fd 1). Labeled-block posix.write of a bufPrint'd
                        // slice (std.debug.print is stderr-only). Block (not inline fn) so it can
                        // reference captured interpolation vars; ends in ';' so the emitter's
                        // terminator doesn't double up.
                        std.fmt.allocPrint(
                            allocator,
                            "(struct {{ " ++ KORU_OUT_FN ++ "fn __kw(comptime __f: []const u8, __a: anytype) void {{ var __kb: [65536]u8 = undefined; const __ks = @import(\"std\").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); }} }}).__kw(\"{s}\", .{{{s}}});",
                            .{ format_buf.items, args_buf.items }
                        ) catch unreachable;

                    // Position-agnostic: one write-back path at every depth (the runner lifts
                    // nested sites and grafts the result back).

                    // Create impl path for shape checking
                    const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
                    impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
                    impl_segments[1] = allocator.dupe(u8, "blk.impl") catch unreachable;
                    const impl_path = ast.DottedPath{
                        .module_qualifier = flow.inv().path.module_qualifier,
                        .segments = impl_segments,
                    };

                    // Build new invocation with @pass_ran annotation
                    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
                    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = impl_path,
                        .args = flow.inv().args,
                        .annotations = flow.inv().annotations,
                        .marks = new_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                    };

                    // Whole-struct copy, NOT a field-list literal: a hand-rolled literal
                    // silently drops any field it doesn't name (this exact rebuild used to
                    // lose impl_variant, breaking variant subflows whose body is a print).
                    var transformed_flow = flow.*;
                    transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
                    transformed_flow.inline_body = inline_code;

                    const new_item = ast.Item{ .flow = transformed_flow };

                    return .{ .replacement = new_item };

            }
            pub fn handler__cs(__koru_event_input: @This().Input) @This().Output { // |cs
                const source = __koru_event_input.source;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &source;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    const ast = @import("ast");

                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    // Position-agnostic: the runner lifts nested sites into a synthetic
                    // top-level flow, so `invocation` IS the flow's own invocation at every depth.
                    _ = &invocation;

                    const raw_content = source.text;
                    const content = if (raw_content.len > 0 and raw_content[raw_content.len - 1] == '\n')
                        raw_content[0 .. raw_content.len - 1]
                    else
                        raw_content;

                    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                    var first = true;
                    var in_literal = false;

                    const openLit = struct {
                        fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, f: *bool, il: *bool) void {
                            if (!il.*) {
                                if (!f.*) b.appendSlice(a, " + ") catch unreachable;
                                b.append(a, '"') catch unreachable;
                                il.* = true;
                                f.* = false;
                            }
                        }
                    }.call;

                    const closeLit = struct {
                        fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, il: *bool) void {
                            if (il.*) {
                                b.append(a, '"') catch unreachable;
                                il.* = false;
                            }
                        }
                    }.call;

                    const escapeAndAppend = struct {
                        fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, c: u8) void {
                            switch (c) {
                                '"' => b.appendSlice(a, "\\\"") catch unreachable,
                                '\\' => b.appendSlice(a, "\\\\") catch unreachable,
                                '\n' => b.appendSlice(a, "\\n") catch unreachable,
                                '\r' => b.appendSlice(a, "\\r") catch unreachable,
                                '\t' => b.appendSlice(a, "\\t") catch unreachable,
                                else => b.append(a, c) catch unreachable,
                            }
                        }
                    }.call;

                    var i: usize = 0;
                    while (i < content.len) {
                        // {% if var %}...{% endif %} → + (var ? "body_escaped" : "") +
                        if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                            const tag_start = i + 2;
                            var ws_start = tag_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start..ws_start + 3], "if ")) {
                                const var_start = ws_start + 3;
                                var var_pos = var_start;
                                while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}
                                var var_end = var_pos;
                                while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                                const cond_var = content[var_pos..var_end];

                                var tag_end = var_end;
                                while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}

                                if (tag_end + 1 < content.len) {
                                    const body_start = tag_end + 2;
                                    const endif_marker = "{% endif %}";
                                    if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                        const body_end = body_start + endif_offset;
                                        const body_content = content[body_start..body_end];

                                        closeLit(&buf, allocator, &in_literal);
                                        if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                                        first = false;

                                        buf.append(allocator, '(') catch unreachable;
                                        buf.appendSlice(allocator, cond_var) catch unreachable;
                                        buf.appendSlice(allocator, " ? \"") catch unreachable;
                                        for (body_content) |c| escapeAndAppend(&buf, allocator, c);
                                        buf.appendSlice(allocator, "\" : \"\")") catch unreachable;

                                        i = body_end + endif_marker.len;
                                        continue;
                                    }
                                }
                            }
                            // Unrecognized {% — treat as literal.
                            openLit(&buf, allocator, &first, &in_literal);
                            escapeAndAppend(&buf, allocator, content[i]);
                            i += 1;
                        }
                        // {{ var:fmt }} → the operand door (lowering + parens + :.N honoring)
                        else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                            const placeholder_start = i + 2;
                            var ws_start = placeholder_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            var j = ws_start;
                            while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}

                            if (j + 1 < content.len) {
                                var ws_end = j;
                                while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}

                                const placeholder = content[ws_start..ws_end];
                                // Keyed `store[k: v]` is a pinned hole (690_018) — refuse
                                // before the `:` spec split inside the operand helper would
                                // take the bracket colon.
                                if (codegen_utils_io.colonInsideBrackets(placeholder)) {
                                    return .{ .replacement = ast.refusal(allocator, reporter, .KORU168, flow.location, flow.module, "std/io:print.blk: '{{{{ {s} }}}}' uses keyed addressing 'store[key: value]' - a pinned hole (690_018); bind the row's handle and interpolate store[handle].field instead", .{placeholder}) };
                                }

                                closeLit(&buf, allocator, &in_literal);
                                if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                                first = false;
                                ioCsPlaceholderOperand(&buf, allocator, placeholder);

                                i = j + 2;
                            } else {
                                openLit(&buf, allocator, &first, &in_literal);
                                escapeAndAppend(&buf, allocator, content[i]);
                                i += 1;
                            }
                        } else {
                            openLit(&buf, allocator, &first, &in_literal);
                            escapeAndAppend(&buf, allocator, content[i]);
                            i += 1;
                        }
                    }

                    closeLit(&buf, allocator, &in_literal);

                    // Empty template → emit `""` so the write gets a valid arg.
                    if (first) buf.appendSlice(allocator, "\"\"") catch unreachable;

                    const inline_code = std.fmt.allocPrint(
                        allocator,
                        "__koru_stdout_write({s} + \"\\n\");",
                        .{buf.items}
                    ) catch unreachable;

                    // Position-agnostic: one write-back path at every depth (the runner lifts
                    // nested sites and grafts the result back) — mirror |zig's AST surgery.
                    const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
                    impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
                    impl_segments[1] = allocator.dupe(u8, "blk.impl") catch unreachable;
                    const impl_path = ast.DottedPath{
                        .module_qualifier = flow.inv().path.module_qualifier,
                        .segments = impl_segments,
                    };

                    const new_inv_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| {
                        new_inv_marks[idx] = m;
                    }
                    new_inv_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = impl_path,
                        .args = flow.inv().args,
                        .annotations = flow.inv().annotations, .marks = new_inv_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                    };

                    // Whole-struct copy, NOT a field-list literal: a hand-rolled literal
                    // silently drops any field it doesn't name (this exact rebuild used to
                    // lose impl_variant, breaking variant subflows whose body is a print).
                    var transformed_flow = flow.*;
                    transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
                    transformed_flow.inline_body = inline_code;

                    const new_item = ast.Item{ .flow = transformed_flow };
                    return .{ .replacement = new_item };

            }
            pub fn handler__raw_posix(__koru_event_input: @This().Input) @This().Output { // |raw_posix
                const source = __koru_event_input.source;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &source;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    const ast = @import("ast");

                    const isZigKeyword = struct {
                        fn check(word: []const u8) bool {
                            const keywords = [_][]const u8{
                                "error", "type", "async", "await", "suspend", "resume",
                                "try", "catch", "if", "else", "switch", "while",
                                "for", "break", "continue", "return", "defer", "errdefer",
                                "test", "pub", "export", "extern", "packed", "inline",
                                "noinline", "comptime", "nosuspend", "volatile", "allowzero",
                                "align", "linksection", "callconv", "noalias",
                                "struct", "enum", "union", "opaque", "fn", "const",
                                "var", "anyframe", "anytype", "anyerror", "unreachable",
                                "undef", "null", "true", "false", "and", "or",
                                "orelse", "threadlocal",
                            };
                            for (keywords) |kw| {
                                if (std.mem.eql(u8, word, kw)) return true;
                            }
                            // Zig primitive names — a local may not shadow them, so they
                            // escape exactly like keywords (230_018).
                            const primitives = [_][]const u8{
                                "bool",         "void",     "noreturn", "anyopaque",
                                "usize",        "isize",    "f16",      "f32",
                                "f64",          "f80",      "f128",     "undefined",
                                "comptime_int", "comptime_float",       "c_char",
                                "c_short",      "c_ushort", "c_int",    "c_uint",
                                "c_long",       "c_ulong",  "c_longlong",
                                "c_ulonglong",  "c_longdouble",
                            };
                            for (primitives) |p| {
                                if (std.mem.eql(u8, word, p)) return true;
                            }
                            // u<digits> / i<digits> — the arbitrary-width integer family.
                            if (word.len >= 2 and (word[0] == 'u' or word[0] == 'i')) {
                                var all_digits = true;
                                for (word[1..]) |c| {
                                    if (c < '0' or c > '9') all_digits = false;
                                }
                                if (all_digits) return true;
                            }
                            return false;
                        }
                    }.check;

                    const appendEscapedPath = struct {
                        fn append(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) void {
                            var start: usize = 0;
                            var pos: usize = 0;
                            var is_first = true;

                            while (pos <= path.len) {
                                if (pos == path.len or path[pos] == '.') {
                                    const segment = path[start..pos];
                                    if (!is_first) {
                                        buf.append(alloc, '.') catch unreachable;
                                        if (isZigKeyword(segment)) {
                                            buf.appendSlice(alloc, "@\"") catch unreachable;
                                            buf.appendSlice(alloc, segment) catch unreachable;
                                            buf.append(alloc, '"') catch unreachable;
                                        } else {
                                            buf.appendSlice(alloc, segment) catch unreachable;
                                        }
                                    } else if (isZigKeyword(segment)) {
                                        // A bare binding may legally collide with a Zig
                                        // keyword or primitive (`: u1` — 230_018); the first
                                        // segment escapes like any other.
                                        buf.appendSlice(alloc, "@\"") catch unreachable;
                                        buf.appendSlice(alloc, segment) catch unreachable;
                                        buf.append(alloc, '"') catch unreachable;
                                    } else {
                                        buf.appendSlice(alloc, segment) catch unreachable;
                                    }
                                    is_first = false;
                                    start = pos + 1;
                                }
                                pos += 1;
                            }
                        }
                    }.append;

                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    // Position-agnostic: the runner lifts nested sites into a synthetic
                    // top-level flow, so `invocation` IS the flow's own invocation at every depth.
                    _ = &invocation;

                    var format_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                    var args_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
                    var i: usize = 0;
                    var first_arg = true;

                    // Raw I/O state: two parallel buffers — std.debug.print fallback and raw write path.
                    var needs_fmt = false;
                    var missing_spec: ?[]const u8 = null;
                    var keyed_placeholder: ?[]const u8 = null;
                    var raw_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                    var literal_run = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;

                    const flushLiteralFn = struct {
                        fn flush(rb: *std.ArrayList(u8), lr: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
                            if (lr.items.len > 0) {
                                rb.appendSlice(alloc, "__kio.__kz_w(\"") catch unreachable;
                                rb.appendSlice(alloc, lr.items) catch unreachable;
                                rb.appendSlice(alloc, "\"); ") catch unreachable;
                                lr.clearRetainingCapacity();
                            }
                        }
                    }.flush;

                    // Inline __kio helper struct: raw posix.write + hand-coded i64 formatter.
                    // fd=2 (stderr) matches std.debug.print's destination so semantics align.
                    const raw_io_prefix =
                        "//@koru:inline_stmt\n{ const __kio = struct { " ++
                        KORU_OUT_UNESCAPED ++
                        "fn __kz_w(__kz_b: []const u8) void { __kout(1, __kz_b); } " ++
                        "fn __kz_wd(__kz_v: i64) void { " ++
                        "var _buf: [20]u8 = undefined; var _n: usize = 0; var _v: u64 = undefined; " ++
                        "if (__kz_v < 0) { __kz_w(\"-\"); _v = @intCast(-(__kz_v + 1)); _v += 1; " ++
                        "} else { _v = @intCast(__kz_v); } " ++
                        "if (_v == 0) { _buf[0] = '0'; _n = 1; } else { " ++
                        "while (_v > 0) : (_n += 1) { _buf[_n] = @intCast('0' + _v % 10); _v /= 10; } " ++
                        "for (0.._n / 2) |_i| { const _t = _buf[_i]; _buf[_i] = _buf[_n - 1 - _i]; _buf[_n - 1 - _i] = _t; } " ++
                        "} __kz_w(_buf[0.._n]); } }; ";

                    const content = source.text;

                    while (i < content.len) {
                        if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                            const tag_start = i + 2;
                            var ws_start = tag_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start..ws_start + 3], "if ")) {
                                const var_start = ws_start + 3;
                                var var_pos = var_start;
                                while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}

                                var var_end = var_pos;
                                while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                                const cond_var = content[var_pos..var_end];

                                var tag_end = var_end;
                                while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}

                                if (tag_end + 1 < content.len) {
                                    const body_start = tag_end + 2;
                                    const endif_marker = "{% endif %}";
                                    if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                        const body_end = body_start + endif_offset;
                                        const body_content = content[body_start..body_end];

                                        format_buf.appendSlice(allocator, "{s}") catch unreachable;

                                        if (!first_arg) {
                                            args_buf.appendSlice(allocator, ", ") catch unreachable;
                                        }
                                        args_buf.appendSlice(allocator, "if (") catch unreachable;
                                        appendEscapedPath(&args_buf, allocator, cond_var);
                                        args_buf.appendSlice(allocator, ") \"") catch unreachable;
                                        for (body_content) |c| {
                                            switch (c) {
                                                '"' => args_buf.appendSlice(allocator, "\\\"") catch unreachable,
                                                '\\' => args_buf.appendSlice(allocator, "\\\\") catch unreachable,
                                                '\n' => args_buf.appendSlice(allocator, "\\n") catch unreachable,
                                                '\r' => args_buf.appendSlice(allocator, "\\r") catch unreachable,
                                                '\t' => args_buf.appendSlice(allocator, "\\t") catch unreachable,
                                                else => args_buf.append(allocator, c) catch unreachable,
                                            }
                                        }
                                        args_buf.appendSlice(allocator, "\" else \"\"") catch unreachable;
                                        first_arg = false;

                                        flushLiteralFn(&raw_buf, &literal_run, allocator);
                                        raw_buf.appendSlice(allocator, "__kio.__kz_w(if (") catch unreachable;
                                        appendEscapedPath(&raw_buf, allocator, cond_var);
                                        raw_buf.appendSlice(allocator, ") \"") catch unreachable;
                                        for (body_content) |c| {
                                            switch (c) {
                                                '"' => raw_buf.appendSlice(allocator, "\\\"") catch unreachable,
                                                '\\' => raw_buf.appendSlice(allocator, "\\\\") catch unreachable,
                                                '\n' => raw_buf.appendSlice(allocator, "\\n") catch unreachable,
                                                '\r' => raw_buf.appendSlice(allocator, "\\r") catch unreachable,
                                                '\t' => raw_buf.appendSlice(allocator, "\\t") catch unreachable,
                                                else => raw_buf.append(allocator, c) catch unreachable,
                                            }
                                        }
                                        raw_buf.appendSlice(allocator, "\" else \"\"); ") catch unreachable;

                                        i = body_end + endif_marker.len;
                                        continue;
                                    }
                                }
                            }
                            switch (content[i]) {
                                '"' => {
                                    format_buf.appendSlice(allocator, "\\\"") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\\"") catch unreachable;
                                },
                                '\\' => {
                                    format_buf.appendSlice(allocator, "\\\\") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\\\") catch unreachable;
                                },
                                '\n' => {
                                    format_buf.appendSlice(allocator, "\\n") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\n") catch unreachable;
                                },
                                '\r' => {
                                    format_buf.appendSlice(allocator, "\\r") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\r") catch unreachable;
                                },
                                '\t' => {
                                    format_buf.appendSlice(allocator, "\\t") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\t") catch unreachable;
                                },
                                else => {
                                    __appendFmtLiteralByte(&format_buf, allocator, content[i]);
                                    literal_run.append(allocator, content[i]) catch unreachable;
                                },
                            }
                            i += 1;
                        }
                        else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                            const placeholder_start = i + 2;
                            var ws_start = placeholder_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            var j = ws_start;
                            while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}

                            if (j + 1 < content.len) {
                                var ws_end = j;
                                while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}

                                const placeholder = content[ws_start..ws_end];
                                var var_name: []const u8 = placeholder;
                                var format_spec: []const u8 = "any";
                                var has_spec = false;

                                // Keyed addressing `store[key: value]` is a pinned hole
                                // (690_018): the `key:` decl emits no lookup machinery, and
                                // the bracket `:` would misfire the format-spec split below.
                                // Honor or refuse: refuse, before either defect runs.
                                if (keyed_placeholder == null and codegen_utils_io.colonInsideBrackets(placeholder)) {
                                    keyed_placeholder = placeholder;
                                }

                                if (std.mem.indexOf(u8, placeholder, ":")) |colon_pos| {
                                    var_name = placeholder[0..colon_pos];
                                    format_spec = placeholder[colon_pos + 1..];
                                    has_spec = true;
                                }

                                if (!has_spec and missing_spec == null) {
                                    missing_spec = placeholder;
                                }

                                const zig_fmt_spec_blk = if (std.mem.eql(u8, format_spec, "f")) "" else format_spec;
                                format_buf.append(allocator, '{') catch unreachable;
                                format_buf.appendSlice(allocator, zig_fmt_spec_blk) catch unreachable;
                                format_buf.append(allocator, '}') catch unreachable;

                                if (!first_arg) {
                                    args_buf.appendSlice(allocator, ", ") catch unreachable;
                                }
                                appendEscapedPath(&args_buf, allocator, var_name);
                                first_arg = false;

                                // Anything other than :d or :s requires std.fmt — fall back.
                                if (!std.mem.eql(u8, format_spec, "d") and !std.mem.eql(u8, format_spec, "s")) {
                                    needs_fmt = true;
                                }

                                flushLiteralFn(&raw_buf, &literal_run, allocator);
                                if (std.mem.eql(u8, format_spec, "d")) {
                                    raw_buf.appendSlice(allocator, "__kio.__kz_wd(@as(i64, @intCast(") catch unreachable;
                                    appendEscapedPath(&raw_buf, allocator, var_name);
                                    raw_buf.appendSlice(allocator, "))); ") catch unreachable;
                                } else if (std.mem.eql(u8, format_spec, "s")) {
                                    raw_buf.appendSlice(allocator, "__kio.__kz_w(") catch unreachable;
                                    appendEscapedPath(&raw_buf, allocator, var_name);
                                    raw_buf.appendSlice(allocator, "); ") catch unreachable;
                                }

                                i = j + 2;
                            } else {
                                switch (content[i]) {
                                    '"' => {
                                        format_buf.appendSlice(allocator, "\\\"") catch unreachable;
                                        literal_run.appendSlice(allocator, "\\\"") catch unreachable;
                                    },
                                    '\\' => {
                                        format_buf.appendSlice(allocator, "\\\\") catch unreachable;
                                        literal_run.appendSlice(allocator, "\\\\") catch unreachable;
                                    },
                                    '\n' => {
                                        format_buf.appendSlice(allocator, "\\n") catch unreachable;
                                        literal_run.appendSlice(allocator, "\\n") catch unreachable;
                                    },
                                    '\r' => {
                                        format_buf.appendSlice(allocator, "\\r") catch unreachable;
                                        literal_run.appendSlice(allocator, "\\r") catch unreachable;
                                    },
                                    '\t' => {
                                        format_buf.appendSlice(allocator, "\\t") catch unreachable;
                                        literal_run.appendSlice(allocator, "\\t") catch unreachable;
                                    },
                                    else => {
                                        __appendFmtLiteralByte(&format_buf, allocator, content[i]);
                                        literal_run.append(allocator, content[i]) catch unreachable;
                                    },
                                }
                                i += 1;
                            }
                        } else {
                            switch (content[i]) {
                                '"' => {
                                    format_buf.appendSlice(allocator, "\\\"") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\\"") catch unreachable;
                                },
                                '\\' => {
                                    format_buf.appendSlice(allocator, "\\\\") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\\\") catch unreachable;
                                },
                                '\n' => {
                                    format_buf.appendSlice(allocator, "\\n") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\n") catch unreachable;
                                },
                                '\r' => {
                                    format_buf.appendSlice(allocator, "\\r") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\r") catch unreachable;
                                },
                                '\t' => {
                                    format_buf.appendSlice(allocator, "\\t") catch unreachable;
                                    literal_run.appendSlice(allocator, "\\t") catch unreachable;
                                },
                                else => {
                                    __appendFmtLiteralByte(&format_buf, allocator, content[i]);
                                    literal_run.append(allocator, content[i]) catch unreachable;
                                },
                            }
                            i += 1;
                        }
                    }

                    if (format_buf.items.len < 2 or
                        format_buf.items[format_buf.items.len - 2] != '\\' or
                        format_buf.items[format_buf.items.len - 1] != 'n')
                    {
                        format_buf.appendSlice(allocator, "\\n") catch unreachable;
                        literal_run.appendSlice(allocator, "\\n") catch unreachable;
                    }

                    const inline_code = if (keyed_placeholder) |placeholder| kblk_keyed: {
                        reporter.addErrorAtLocation(.KORU168, flow.location, "std.io:print.blk: '{{{{ {s} }}}}' uses keyed addressing 'store[key: value]' - a pinned hole (690_018); bind the row's handle and interpolate store[handle].field instead", .{placeholder}) catch {};
                        break :kblk_keyed std.fmt.allocPrint(
                            allocator,
                            "@compileError(\"std.io:print.blk: '{{{{ {s} }}}}' uses keyed addressing - a pinned hole (690_018); use store[handle].field\");",
                            .{placeholder}
                        ) catch unreachable;
                    }
                    else if (missing_spec) |placeholder| kblk5: {
                        reporter.addErrorAtLocation(.KORU168, flow.location, "std.io:print.blk: '{{{{ {s} }}}}' requires a format specifier (:d, :s, :f, or :any)", .{placeholder}) catch {};
                        break :kblk5 std.fmt.allocPrint(
                            allocator,
                            "@compileError(\"std.io:print.blk: '{{{{ {s} }}}}' requires a format specifier (:d, :s, :f, or :any)\");",
                            .{placeholder}
                        ) catch unreachable;
                    }
                    else if (needs_fmt)
                        // print.blk -> stdout (fd 1), :f/:any fallback. See the |zig site above.
                        std.fmt.allocPrint(
                            allocator,
                            "(struct {{ " ++ KORU_OUT_FN ++ "fn __kw(comptime __f: []const u8, __a: anytype) void {{ var __kb: [65536]u8 = undefined; const __ks = @import(\"std\").fmt.bufPrint(&__kb, __f, __a) catch __kb[0..0]; __kout(1, __ks); }} }}).__kw(\"{s}\", .{{{s}}});",
                            .{ format_buf.items, args_buf.items }
                        ) catch unreachable
                    else blk: {
                        flushLiteralFn(&raw_buf, &literal_run, allocator);
                        var code = std.ArrayList(u8).initCapacity(allocator, raw_buf.items.len + 1024) catch unreachable;
                        code.appendSlice(allocator, raw_io_prefix) catch unreachable;
                        code.appendSlice(allocator, raw_buf.items) catch unreachable;
                        code.appendSlice(allocator, "}") catch unreachable;
                        break :blk code.items;
                    };

                    // Position-agnostic: one write-back path at every depth (the runner lifts
                    // nested sites and grafts the result back).
                    const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
                    impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
                    impl_segments[1] = allocator.dupe(u8, "blk.impl") catch unreachable;
                    const impl_path = ast.DottedPath{
                        .module_qualifier = flow.inv().path.module_qualifier,
                        .segments = impl_segments,
                    };

                    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
                    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = impl_path,
                        .args = flow.inv().args,
                        .annotations = flow.inv().annotations,
                        .marks = new_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                    };

                    // Whole-struct copy, NOT a field-list literal: a hand-rolled literal
                    // silently drops any field it doesn't name (this exact rebuild used to
                    // lose impl_variant, breaking variant subflows whose body is a print).
                    var transformed_flow = flow.*;
                    transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
                    transformed_flow.inline_body = inline_code;

                    const new_item = ast.Item{ .flow = transformed_flow };

                    return .{ .replacement = new_item };

            }
            pub fn handler__js(__koru_event_input: @This().Input) @This().Output { // |js
                const source = __koru_event_input.source;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const reporter = __koru_event_input.reporter;
                const allocator = __koru_event_input.allocator;
                _ = &source;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &reporter;
                _ = &allocator;
                _ = &__koru_event_input;

                    const ast = @import("ast");

                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    // Position-agnostic: the runner lifts nested sites into a synthetic
                    // top-level flow, so `invocation` IS the flow's own invocation at every depth.
                    _ = &invocation;

                    // Build a JS string-concat expression mirroring |zig's format-string +
                    // arg-list shape. Each {{ var }} becomes ` + var + `; each {% if v %}body
                    // {% endif %} becomes ` + (v ? "body" : "") + `; literal chars accumulate
                    // in a `"..."` segment with standard string-literal escaping. JS's `+`
                    // promotes Numbers to strings on concat, so no per-field-spec mapping
                    // (`:s`/`:d`) is needed — :s/:d/:f/:any all lower to bare `${var}` semantics.
                    //
                    // Trailing newline behavior diverges from |zig: console.log auto-appends
                    // `\n`, so we strip ONE trailing newline from the template content (if
                    // present) to avoid the double-newline that would otherwise result. The
                    // template content's leading newline is preserved as-is.
                    const raw_content = source.text;
                    const content = if (raw_content.len > 0 and raw_content[raw_content.len - 1] == '\n')
                        raw_content[0 .. raw_content.len - 1]
                    else
                        raw_content;

                    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                    var first = true;
                    var in_literal = false;

                    const openLit = struct {
                        fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, f: *bool, il: *bool) void {
                            if (!il.*) {
                                if (!f.*) b.appendSlice(a, " + ") catch unreachable;
                                b.append(a, '"') catch unreachable;
                                il.* = true;
                                f.* = false;
                            }
                        }
                    }.call;

                    const closeLit = struct {
                        fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, il: *bool) void {
                            if (il.*) {
                                b.append(a, '"') catch unreachable;
                                il.* = false;
                            }
                        }
                    }.call;

                    const escapeAndAppend = struct {
                        fn call(b: *std.ArrayList(u8), a: std.mem.Allocator, c: u8) void {
                            switch (c) {
                                '"' => b.appendSlice(a, "\\\"") catch unreachable,
                                '\\' => b.appendSlice(a, "\\\\") catch unreachable,
                                '\n' => b.appendSlice(a, "\\n") catch unreachable,
                                '\r' => b.appendSlice(a, "\\r") catch unreachable,
                                '\t' => b.appendSlice(a, "\\t") catch unreachable,
                                else => b.append(a, c) catch unreachable,
                            }
                        }
                    }.call;

                    var i: usize = 0;
                    while (i < content.len) {
                        // {% if var %}...{% endif %} → + (var ? "body_escaped" : "") +
                        if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '%') {
                            const tag_start = i + 2;
                            var ws_start = tag_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            if (ws_start + 3 <= content.len and std.mem.eql(u8, content[ws_start..ws_start + 3], "if ")) {
                                const var_start = ws_start + 3;
                                var var_pos = var_start;
                                while (var_pos < content.len and (content[var_pos] == ' ' or content[var_pos] == '\t')) : (var_pos += 1) {}
                                var var_end = var_pos;
                                while (var_end < content.len and content[var_end] != ' ' and content[var_end] != '\t' and content[var_end] != '%') : (var_end += 1) {}
                                const cond_var = content[var_pos..var_end];

                                var tag_end = var_end;
                                while (tag_end + 1 < content.len and !(content[tag_end] == '%' and content[tag_end + 1] == '}')) : (tag_end += 1) {}

                                if (tag_end + 1 < content.len) {
                                    const body_start = tag_end + 2;
                                    const endif_marker = "{% endif %}";
                                    if (std.mem.indexOf(u8, content[body_start..], endif_marker)) |endif_offset| {
                                        const body_end = body_start + endif_offset;
                                        const body_content = content[body_start..body_end];

                                        closeLit(&buf, allocator, &in_literal);
                                        if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                                        first = false;

                                        buf.append(allocator, '(') catch unreachable;
                                        buf.appendSlice(allocator, cond_var) catch unreachable;
                                        buf.appendSlice(allocator, " ? \"") catch unreachable;
                                        for (body_content) |c| escapeAndAppend(&buf, allocator, c);
                                        buf.appendSlice(allocator, "\" : \"\")") catch unreachable;

                                        i = body_end + endif_marker.len;
                                        continue;
                                    }
                                }
                            }
                            // Unrecognized {% — treat as literal.
                            openLit(&buf, allocator, &first, &in_literal);
                            escapeAndAppend(&buf, allocator, content[i]);
                            i += 1;
                        }
                        // {{ var:fmt }} → + var +  (fmt ignored — JS auto-stringifies)
                        else if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
                            const placeholder_start = i + 2;
                            var ws_start = placeholder_start;
                            while (ws_start < content.len and (content[ws_start] == ' ' or content[ws_start] == '\t')) : (ws_start += 1) {}

                            var j = ws_start;
                            while (j + 1 < content.len and !(content[j] == '}' and content[j + 1] == '}')) : (j += 1) {}

                            if (j + 1 < content.len) {
                                var ws_end = j;
                                while (ws_end > ws_start and (content[ws_end - 1] == ' ' or content[ws_end - 1] == '\t')) : (ws_end -= 1) {}

                                const placeholder = content[ws_start..ws_end];
                                // Keyed `store[k: v]` is a pinned hole (690_018) — refuse
                                // before the `:` spec split below takes the bracket colon.
                                if (codegen_utils_io.colonInsideBrackets(placeholder)) {
                                    return .{ .replacement = ast.refusal(allocator, reporter, .KORU168, flow.location, flow.module, "std/io:print.blk: '{{{{ {s} }}}}' uses keyed addressing 'store[key: value]' - a pinned hole (690_018); bind the row's handle and interpolate store[handle].field instead", .{placeholder}) };
                                }
                                var var_name: []const u8 = placeholder;
                                if (std.mem.indexOf(u8, placeholder, ":")) |colon_pos| {
                                    var_name = placeholder[0..colon_pos];
                                }

                                closeLit(&buf, allocator, &in_literal);
                                if (!first) buf.appendSlice(allocator, " + ") catch unreachable;
                                first = false;
                                buf.appendSlice(allocator, var_name) catch unreachable;

                                i = j + 2;
                            } else {
                                openLit(&buf, allocator, &first, &in_literal);
                                escapeAndAppend(&buf, allocator, content[i]);
                                i += 1;
                            }
                        } else {
                            openLit(&buf, allocator, &first, &in_literal);
                            escapeAndAppend(&buf, allocator, content[i]);
                            i += 1;
                        }
                    }

                    closeLit(&buf, allocator, &in_literal);

                    // Empty template → emit `""` so console.log gets a valid arg.
                    if (first) buf.appendSlice(allocator, "\"\"") catch unreachable;

                    const inline_code = std.fmt.allocPrint(
                        allocator,
                        "console.log({s});",
                        .{buf.items}
                    ) catch unreachable;

                    // Position-agnostic: one write-back path at every depth (the runner lifts
                    // nested sites and grafts the result back) — mirror |zig's AST surgery.
                    const impl_segments = allocator.alloc([]const u8, 2) catch unreachable;
                    impl_segments[0] = allocator.dupe(u8, "print") catch unreachable;
                    impl_segments[1] = allocator.dupe(u8, "blk.impl") catch unreachable;
                    const impl_path = ast.DottedPath{
                        .module_qualifier = flow.inv().path.module_qualifier,
                        .segments = impl_segments,
                    };

                    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
                    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = impl_path,
                        .args = flow.inv().args,
                        .annotations = flow.inv().annotations,
                        .marks = new_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                    };

                    // Whole-struct copy, NOT a field-list literal: a hand-rolled literal
                    // silently drops any field it doesn't name (this exact rebuild used to
                    // lose impl_variant, breaking variant subflows whose body is a print).
                    var transformed_flow = flow.*;
                    transformed_flow.body = ast.rootSite(new_invocation, flow.body.continuations, flow.location);
                    transformed_flow.inline_body = inline_code;

                    const new_item = ast.Item{ .flow = transformed_flow };
                    return .{ .replacement = new_item };

            }
        };
        pub const print_blk_impl_event = struct {
            pub const Input = struct {
                text: []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        // >>> FLOW: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1102  ~std.build:variants()
        pub fn comptime_flow1(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) void {
            _ = &program;
            _ = &allocator;
            const result_0 = koru_std.koru_build.variants_event.handler(.{ .source = __koru_ast.Source{ .text = 
                \\"std.io:print.blk": "raw_posix"
                , .scope = .{ .bindings = &.{} }, .phantom_type = null }, .meta = __koru_ast.InvocationMeta{
                .path = "std.build:variants",
                .module = "std.build",
                .event_name = "variants",
                .annotations = &[_][]const u8{"build(linux)"},
                .location = .{ .file = "/Users/larsde/src/koru-cypoe/koru_std/io.blk.kz", .line = 1102, .column = 0 },
            }, .program = program });
            switch (result_0) {
                // >>> BRANCH: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1106  | skipped _ |>
                .skipped => |_| {
                },
                // >>> BRANCH: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1107  | invalid-event _ |>
                .invalid_event => |_| {
                },
                // >>> BRANCH: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1105  | configured _ |>
                .configured => |_| {
                },
            }
        }
        // >>> FLOW: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1109  ~std.build:variants()
        pub fn comptime_flow2(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) void {
            _ = &program;
            _ = &allocator;
            const result_0 = koru_std.koru_build.variants_event.handler(.{ .source = __koru_ast.Source{ .text = 
                \\"std.io:print.blk": "raw_posix"
                , .scope = .{ .bindings = &.{} }, .phantom_type = null }, .meta = __koru_ast.InvocationMeta{
                .path = "std.build:variants",
                .module = "std.build",
                .event_name = "variants",
                .annotations = &[_][]const u8{"build(macos)"},
                .location = .{ .file = "/Users/larsde/src/koru-cypoe/koru_std/io.blk.kz", .line = 1109, .column = 0 },
            }, .program = program });
            switch (result_0) {
                // >>> BRANCH: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1113  | skipped _ |>
                .skipped => |_| {
                },
                // >>> BRANCH: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1114  | invalid-event _ |>
                .invalid_event => |_| {
                },
                // >>> BRANCH: /Users/larsde/src/koru-cypoe/koru_std/io.blk.kz:1112  | configured _ |>
                .configured => |_| {
                },
            }
        }
    };
    pub const koru_testing = struct {
        // Koru Testing Framework
        //
        // Compiler-guided test development with automatic mock detection.
        //
        // Usage:
        //   test(User cannot withdraw more than balance) {
        //       account.balance = amount 50
        //       app:withdraw(amount: 100)
        //       | insufficient_funds |> assert.ok()
        //   }
        //
        // The compiler:
        //   1. Traces the flow to find impure tors
        //   2. Errors if impure tor not mocked
        //   3. Errors if mock is unused
        //   4. Generates Zig test block
        const std = @import("std");
        const validateMocks = struct {
            fn call(
                allocator: std.mem.Allocator,
                program: *const @import("ast").Program,
                mocks: []const @import("ast").Item,
                source: *const @import("ast").Source,
            ) bool {
                const std_import = @import("std");
                const ast = @import("ast");
                const emitter_helpers = @import("emitter_helpers");
                const errors_mod = @import("errors");
                const type_registry_module = @import("type_registry");
                if (mocks.len == 0) return true;
                const source_file_name = if (source.location.file.len > 0) source.location.file else "__test__.kz";
                var reporter = errors_mod.ErrorReporter.init(allocator, source_file_name, source.text) catch {
                    std_import.debug.print("ERROR: Failed to initialize mock shape reporter\n", .{});
                    return false;
                };
                defer reporter.deinit();
                const fieldExists = struct {
                    fn check(fields: []const ast.Field, name: []const u8) bool {
                        for (fields) |field| {
                            if (std_import.mem.eql(u8, field.name, name)) return true;
                        }
                        return false;
                    }
                }.check;
                var local_registry_ptr: ?*type_registry_module.TypeRegistry = null;
                const type_registry_ptr: ?*type_registry_module.TypeRegistry = if (program.type_registry) |ptr| blk: {
                    break :blk @ptrCast(@alignCast(ptr));
                } else blk: {
                    local_registry_ptr = allocator.create(type_registry_module.TypeRegistry) catch unreachable;
                    local_registry_ptr.?.* = type_registry_module.TypeRegistry.init(allocator);
                    local_registry_ptr.?.populateFromAST(program.items) catch unreachable;
                    break :blk local_registry_ptr.?;
                };
                defer if (local_registry_ptr) |ptr| {
                    ptr.deinit();
                    allocator.destroy(ptr);
                };
                for (mocks) |mock_item| {
                    if (mock_item != .immediate_impl) continue;
                    const ii = mock_item.immediate_impl;
                    const bc = ii.value;
                    const mock_line = if (source.location.line > 0)
                        source.location.line + ii.location.line - 1
                    else
                        ii.location.line;
                    const mock_column = ii.location.column;
                    const event_decl = emitter_helpers.findEventDeclByPath(program.items, &ii.event_path);
                    var event_type: ?type_registry_module.EventType = null;
                    if (event_decl == null) {
                        if (type_registry_ptr) |registry| {
                            const canonical = emitter_helpers.buildCanonicalEventName(&ii.event_path, allocator, program.main_module_name) catch null;
                            if (canonical) |name| {
                                defer allocator.free(name);
                                if (registry.getEventType(name)) |et| {
                                    event_type = et;
                                }
                            }
                        }
                    }
                    if (event_decl == null and event_type == null) {
                        reporter.addError(
                            .KORU040,
                            mock_line,
                            mock_column,
                            "mock references unknown event",
                            .{},
                        ) catch {
                            @panic("Mock shape validation failed");
                        };
                        continue;
                    }
                    // A bare return (`ev -> value`) is the TWIN of the branch
                    // constructor (`ev => branch value`), not a degenerate case of it:
                    // it pairs with the declaration's `return_type` and carries no
                    // branch tag at all, so `bc.branch_name` is empty by construction.
                    // Looking that empty name up in `branches` is what refused every
                    // correctly-mocked `-> T` tor with "unknown branch ''" — the mock
                    // form the compiler itself recommends (flow_checker.zig:419) was the
                    // one the mock validator could not express (395_006). There is no
                    // branch payload to shape-check here; the value is checked against
                    // `return_type` by the ordinary emission path.
                    if (bc.is_bare_return) {
                        const declares_branches = if (event_decl) |decl|
                            decl.branches.len > 0
                        else if (event_type) |et|
                            et.return_type == null
                        else
                            false;
                        if (declares_branches) {
                            reporter.addError(
                                .KORU021,
                                mock_line,
                                mock_column,
                                "mocked tor declares branches, so its mock constructs one — a bare return (`->`) produces no branch tag",
                                .{},
                            ) catch {
                                @panic("Mock shape validation failed");
                            };
                        }
                        continue;
                    }
                    var payload_fields: []const ast.Field = &[_]ast.Field{};
                    var payload_is_wildcard = false;
                    if (event_decl) |decl| {
                        var branch_ptr: ?*const ast.Branch = null;
                        for (decl.branches) |*branch| {
                            if (std_import.mem.eql(u8, branch.name, bc.branch_name)) {
                                branch_ptr = branch;
                                break;
                            }
                        }
                        const branch = branch_ptr orelse {
                            reporter.addError(
                                .KORU021,
                                mock_line,
                                mock_column,
                                "unknown branch '{s}' in mock",
                                .{bc.branch_name},
                            ) catch {
                                @panic("Mock shape validation failed");
                            };
                            continue;
                        };
                        payload_fields = branch.payload.fields;
                        payload_is_wildcard = branch.payload.is_wildcard;
                    } else if (event_type) |et| {
                        var branch_type_ptr: ?*const type_registry_module.BranchType = null;
                        for (et.branches) |*branch| {
                            if (std_import.mem.eql(u8, branch.name, bc.branch_name)) {
                                branch_type_ptr = branch;
                                break;
                            }
                        }
                        const branch_type = branch_type_ptr orelse {
                            reporter.addError(
                                .KORU021,
                                mock_line,
                                mock_column,
                                "unknown branch '{s}' in mock",
                                .{bc.branch_name},
                            ) catch {
                                @panic("Mock shape validation failed");
                            };
                            continue;
                        };
                        if (branch_type.payload) |payload| {
                            payload_fields = payload.fields;
                            payload_is_wildcard = payload.is_wildcard;
                        } else {
                            payload_fields = &[_]ast.Field{};
                            payload_is_wildcard = false;
                        }
                    }
                    if (payload_is_wildcard) continue;
                    if (bc.plain_value != null and bc.fields.len == 0) {
                        if (payload_fields.len != 1) {
                            reporter.addError(
                                .KORU081,
                                mock_line,
                                mock_column,
                                "mock branch '{s}' expects fields, not a bare value",
                                .{bc.branch_name},
                            ) catch {
                                @panic("Mock shape validation failed");
                            };
                        }
                        continue;
                    }
                    for (payload_fields) |expected_field| {
                        if (!fieldExists(bc.fields, expected_field.name)) {
                            reporter.addError(
                                .KORU080,
                                mock_line,
                                mock_column,
                                "missing required field '{s}' in mock branch '{s}'",
                                .{expected_field.name, bc.branch_name},
                            ) catch {
                                @panic("Mock shape validation failed");
                            };
                        }
                    }
                    for (bc.fields) |provided_field| {
                        if (!fieldExists(payload_fields, provided_field.name)) {
                            reporter.addError(
                                .KORU081,
                                mock_line,
                                mock_column,
                                "unknown field '{s}' in mock branch '{s}'",
                                .{provided_field.name, bc.branch_name},
                            ) catch {
                                @panic("Mock shape validation failed");
                            };
                        }
                    }
                }
                if (reporter.hasErrors()) {
                    const stderr_writer = std_import.debug.lockStderrWriter(&.{});
                    defer std_import.debug.unlockStderrWriter();
                    reporter.printErrors(stderr_writer) catch {};
                    return false;
                }
                return true;
            }
        }.call;
        // =============================================================================
        // Test Declaration
        // =============================================================================
        // Main test tor - takes name as Expression, body as Source
        // Transform generates Zig test blocks using real emitter infrastructure
        // Test transform - generates proper Zig test blocks
        // NEW ARCHITECTURE: Run transforms on parsed Source, then use normal emitter
        // Helper: Walk flow checking purity
        const walkFlowForPurity = struct {
            fn call(
                flow_to_walk: *const @import("ast").Flow,
                mocks: *const @import("std").StringHashMap(@import("ast").BranchConstructor),
                impure_list: *@import("std").ArrayList([]const u8),
                all_items: []const @import("ast").Item,
                allocator: @import("std").mem.Allocator,
            ) void {
                const emitter_helpers = @import("emitter_helpers");
                var path_buf = @import("std").ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
                if (flow_to_walk.inv().path.module_qualifier) |mq| {
                    path_buf.appendSlice(allocator, mq) catch {};
                    path_buf.append(allocator, ':') catch {};
                }
                for (flow_to_walk.inv().path.segments, 0..) |seg, i| {
                    if (i > 0) path_buf.append(allocator, '.') catch {};
                    path_buf.appendSlice(allocator, seg) catch {};
                }
                const inv_path = path_buf.items;
                if (mocks.get(inv_path)) |_| return;
                // Subflow/composed tors: walk the implementation body instead of
                // flagging the outer tor. Tests call process_payment etc.; purity
                // lives in the leaf proc calls inside the impl.
                if (emitter_helpers.findImplByPath(all_items, &flow_to_walk.inv().path)) |found_impl| {
                    switch (found_impl) {
                        .immediate_impl => return,
                        .flow => |impl_flow| {
                            call(impl_flow, mocks, impure_list, all_items, allocator);
                            return;
                        },
                    }
                }
                if (emitter_helpers.findProcDeclByPath(all_items, &flow_to_walk.inv().path)) |proc| {
                    if (!proc.is_pure) {
                        for (impure_list.items) |existing| {
                            if (@import("std").mem.eql(u8, existing, inv_path)) return;
                        }
                        impure_list.append(allocator, inv_path) catch {};
                    }
                } else if (emitter_helpers.findEventDeclByPath(all_items, &flow_to_walk.inv().path)) |event| {
                    if (!event.is_pure) {
                        for (impure_list.items) |existing| {
                            if (@import("std").mem.eql(u8, existing, inv_path)) return;
                        }
                        impure_list.append(allocator, inv_path) catch {};
                    }
                }
                for (flow_to_walk.body.continuations) |cont| {
                    walkContinuation(&cont, mocks, impure_list, all_items, allocator);
                }
            }
            fn walkContinuation(
                cont: *const @import("ast").Continuation,
                mocks: *const @import("std").StringHashMap(@import("ast").BranchConstructor),
                impure_list: *@import("std").ArrayList([]const u8),
                all_items: []const @import("ast").Item,
                allocator: @import("std").mem.Allocator,
            ) void {
                if (cont.node) |node| {
                    if (node == .invocation) {
                        const temp_flow = @import("ast").Flow{
                            .body = cont.*,
                            .location = cont.location,
                            .module = "",
                            .is_pure = true,
                            .is_transitively_pure = false,
                        };
                        call(&temp_flow, mocks, impure_list, all_items, allocator);
                    } else {
                        for (cont.continuations) |nested| {
                            walkContinuation(&nested, mocks, impure_list, all_items, allocator);
                        }
                    }
                } else {
                    for (cont.continuations) |nested| {
                        walkContinuation(&nested, mocks, impure_list, all_items, allocator);
                    }
                }
            }
        }.call;
        // Helper: Emit flow with mock substitution using real emitter
        const emitFlowWithMocks = struct {
            fn call(
                code_emitter: *@import("emitter_helpers").CodeEmitter,
                ctx: *@import("emitter_helpers").EmissionContext,
                flow_to_emit: *const @import("ast").Flow,
                mocks: *const @import("std").StringHashMap(@import("ast").BranchConstructor),
                counter: *usize,
            ) !void {
                const emitter_helpers = @import("emitter_helpers");
                const std_local = @import("std");
                var path_buf = std_local.ArrayList(u8).initCapacity(ctx.allocator, 64) catch unreachable;
                for (flow_to_emit.inv().path.segments, 0..) |seg, i| {
                    if (i > 0) try path_buf.append(ctx.allocator, '.');
                    try path_buf.appendSlice(ctx.allocator, seg);
                }
                const inv_path = path_buf.items;
                // Handle assert transform inline - emit if(!expr) @panic
                if (std_local.mem.eql(u8, inv_path, "assert")) {
                    // Get the expression from first arg's value (parser stores it there)
                    if (flow_to_emit.inv().args.len > 0) {
                        const expr_text = flow_to_emit.inv().args[0].value;
                        if (expr_text.len > 0) {
                            try code_emitter.writeIndent();
                            try code_emitter.write("try @import(\"std\").testing.expect(");
                            try code_emitter.write(expr_text);
                            try code_emitter.write(");\n");
                            return;
                        }
                    }
                    return; // Skip if no expression found
                }
                // Handle assert.ok - unconditional pass (noop)
                if (std_local.mem.eql(u8, inv_path, "assert.ok")) {
                    // assert.ok() is a pass-through checkpoint - just continue
                    // Emit nothing (the test passed this branch)
                    return;
                }
                // Handle assert.fail - unconditional failure
                if (std_local.mem.eql(u8, inv_path, "assert.fail")) {
                    try code_emitter.writeIndent();
                    try code_emitter.write("return error.TestUnexpectedResult;\n");
                    return;
                }
                if (mocks.get(inv_path)) |bc| {
                    const result_var = try @import("std").fmt.allocPrint(ctx.allocator, "__mock_result_{d}", .{counter.*});
                    counter.* += 1;
                    try code_emitter.writeIndent();
                    try code_emitter.write("const ");
                    try code_emitter.write(result_var);
                    try code_emitter.write(" = ");
                    try emitter_helpers.emitBranchConstructor(code_emitter, ctx, &bc, true);
                    try code_emitter.write(";\n");
                    for (flow_to_emit.body.continuations) |cont| {
                        if (@import("std").mem.eql(u8, cont.branch, bc.branch_name)) {
                            if (cont.binding) |binding| {
                                try code_emitter.writeIndent();
                                try code_emitter.write("const ");
                                try code_emitter.write(binding);
                                try code_emitter.write(" = ");
                                try code_emitter.write(result_var);
                                try code_emitter.write(".");
                                try code_emitter.write(bc.branch_name);
                                try code_emitter.write(";\n");
                                try code_emitter.writeIndent();
                                try code_emitter.write("_ = &");
                                try code_emitter.write(binding);
                                try code_emitter.write(";\n");
                            }
                            if (cont.node) |node| {
                                if (node == .invocation) {
                                    const nested_flow = @import("ast").Flow{
                                        .body = cont,
                                        .location = cont.location,
                                        .module = "",
                                        .is_pure = true,
                                        .is_transitively_pure = false,
                                    };
                                    try call(code_emitter, ctx, &nested_flow, mocks, counter);
                                }
                            }
                            break;
                        }
                    }
                    try code_emitter.writeIndent();
                    try code_emitter.write("_ = &");
                    try code_emitter.write(result_var);
                    try code_emitter.write(";\n");
                } else {
                    try emitter_helpers.emitFlow(code_emitter, ctx, flow_to_emit);
                }
            }
        }.call;
        // Test with shared harness (mocks can be unused per-test)
        // Define a test harness with shared mocks
        // =============================================================================
        // Property Testing
        // =============================================================================
        // Test that multiple variants produce equivalent results
        // Usage:
        //   test.property.equivalent {
        //       ast:select(blur|*)
        //   }
        // =============================================================================
        // Transform Implementation (Stub)
        // =============================================================================
        // The actual transform will:
        // 1. Parse source block as Koru AST
        // 2. Find mock definitions: lines matching `tor = branch { ... }`
        // 3. Extract the flow under test (non-mock lines)
        // 4. Trace flow to find impure tors
        // 5. Error if impure tor not mocked
        // 6. Error if mock unused
        // 7. Create mangled proc implementations for mocks
        // 8. Rewrite flow to call mangled versions
        // 9. Emit Zig test block
        // proc test {
        //     // TODO: Implement transform
        //     // For now, just parse and validate structure
        // }
        // Koru Standard Library: the `assert` part of testing.kz.
        // Joined via `~part assert` in testing.kz; merged into the testing module at load.
        // =============================================================================
        // Assertions
        // =============================================================================
        // Pass-through assertion checkpoint
        // Usage: assert(u.name == "Alice") |> next_step()
        // Panics with message if expression is false, otherwise continues
        // Simple pass - marks a test branch as passing (noop)
        // Simple fail - fails the test with optional message
        // Koru Standard Library: the `compare` part of testing.kz.
        // Joined via `~part compare`; merged into the testing module at load.
        // Equality assertion
        // Contains assertion (for strings/slices)
        pub const test_event = struct {
            pub const Input = struct {
                expr: []const u8,
                source: __koru_ast.Source,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: test  [/Users/larsde/src/koru-cypoe/koru_std/testing.kz:283]
                const expr = __koru_event_input.expr;
                const source = __koru_event_input.source;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &source;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &allocator;
                _ = &__koru_event_input;

                    const std_import = @import("std");
                    const ast = @import("ast");
                    const ast_functional = @import("ast_functional");
                    const parser_impl = @import("parser");
                    const emitter_helpers = @import("emitter_helpers");

                    // Get the flow from the item
                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    // Position-agnostic: the runner lifts nested sites into a synthetic
                    // top-level flow, so `invocation` IS the flow's own invocation at every depth.
                    _ = &invocation;

                    // Get test name from expr parameter
                    const test_name = expr;

                    // Storage for parsed items
                    var cloned_mocks = std_import.ArrayList(ast.Item).initCapacity(allocator, 8) catch unreachable;
                    var cloned_flows = std_import.ArrayList(ast.Item).initCapacity(allocator, 8) catch unreachable;

                    // Parse the source block
                    parse_block: {
                        if (source.text.len == 0) break :parse_block;

                        // The test body has no file of its own. It inherits the ENCLOSING file's
                        // DIALECT — and only the dialect. A `.k` is pure Koru with no ``; the
                        // invented "__test__.kz" told the parser this was host-embedded, so every
                        // line of the body parsed as HOST TEXT, nothing was collected, and the
                        // emitted test block came out EMPTY — a pass with zero assertions in it
                        // (395_002, 395_009).
                        //
                        // The synthetic NAME is kept deliberately. A filename answers two
                        // questions in Parser.init — the dialect (parser.zig:707) and the MODULE
                        // NAME (parser.zig:696-705) — and handing it the real path fixes the
                        // first while silently renaming the module, which took 395_005 and
                        // 395_010 red. Same disease as std/runtime:parse.source, seen from the
                        // other side: one parameter, two questions. So: synthetic name for the
                        // module, real extension for the dialect, set after init because is_k is
                        // read during parse and never during init.
                        //
                        // Ruled by Lars 2026-08-07: "use the same extension and semantics as the
                        // original file... Writing `` inside a `.k`-file makes no sense, that is
                        // literally the actual rule."
                        var p = parser_impl.Parser.init(allocator, source.text, "__test__.kz", &[_][]const u8{}, null) catch {
                            break :parse_block;
                        };
                        p.is_k = std_import.mem.endsWith(u8, source.location.file, ".k");
                        defer p.deinit();

                        var result = p.parse() catch {
                            break :parse_block;
                        };
                        defer result.deinit();

                        // Clone parsed items to owned memory
                        for (result.source_file.items) |*parsed_item| {
                            switch (parsed_item.*) {
                                .immediate_impl => {
                                    const cloned = ast_functional.cloneItem(allocator, parsed_item) catch continue;
                                    cloned_mocks.append(allocator, cloned) catch {};
                                },
                                .flow => {
                                    const cloned = ast_functional.cloneItem(allocator, parsed_item) catch continue;
                                    cloned_flows.append(allocator, cloned) catch {};
                                },
                                else => {},
                            }
                        }
                    }

                    // ==========================================================================
                    // NEW ARCHITECTURE: Clone program, substitute mocks, emit test module
                    // ==========================================================================

                    // Generate unique test module name from test_name
                    var test_module_name_buf: [128]u8 = undefined;
                    var test_module_name_len: usize = 0;
                    const prefix = "test_";
                    @memcpy(test_module_name_buf[0..prefix.len], prefix);
                    test_module_name_len = prefix.len;
                    // Sanitize test name: replace spaces/special chars with underscores
                    for (test_name) |c| {
                        if (test_module_name_len >= test_module_name_buf.len - 8) break;
                        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
                            test_module_name_buf[test_module_name_len] = c;
                            test_module_name_len += 1;
                        } else if (c == ' ' or c == '-' or c == '_') {
                            test_module_name_buf[test_module_name_len] = '_';
                            test_module_name_len += 1;
                        }
                    }
                    const suffix = "_module";
                    @memcpy(test_module_name_buf[test_module_name_len..test_module_name_len + suffix.len], suffix);
                    test_module_name_len += suffix.len;
                    const test_module_name = test_module_name_buf[0..test_module_name_len];

                    // Clone program AST
                    const cloned_program = ast_functional.cloneSourceFile(allocator, program) catch {
                        return .{};
                    };

                    // Build test module items: program items with mocks substituted
                    var test_module_items = std_import.ArrayList(ast.Item).initCapacity(allocator, cloned_program.items.len + cloned_mocks.items.len) catch unreachable;

                    // Helper to check if an impl matches any mock (mocks are now immediate_impl items)
                    const matchesMock = struct {
                        fn check(impl_path: *const ast.DottedPath, mocks: []const ast.Item) bool {
                            for (mocks) |mock_item| {
                                if (mock_item == .immediate_impl) {
                                    const mock_path = &mock_item.immediate_impl.event_path;
                                    if (impl_path.segments.len == mock_path.segments.len) {
                                        var all_match = true;
                                        for (impl_path.segments, mock_path.segments) |a, b| {
                                            if (!std_import.mem.eql(u8, a, b)) {
                                                all_match = false;
                                                break;
                                            }
                                        }
                                        if (all_match) return true;
                                    }
                                }
                            }
                            return false;
                        }
                    };

                    // Add cloned program items, filtering out impls that are mocked
                    // Also skip top-level flows, module_decls, and imports that shouldn't be in the flat test module
                    for (cloned_program.items) |p_item| {
                        switch (p_item) {
                            .flow => |f| {
                                // Skip top-level flows (they contain test), but keep impl flows (impl_of set)
                                if (f.impl_of) |*impl_path| {
                                    // Only add if NOT mocked
                                    if (!matchesMock.check(impl_path, cloned_mocks.items)) {
                                        test_module_items.append(allocator, p_item) catch {};
                                    }
                                }
                                // else: top-level flow, skip
                            },
                            .module_decl => {},  // Skip module declarations (test module is flat)
                            .import_decl => {},  // Skip imports (test module uses parent's imports)
                            .immediate_impl => |ii| {
                                // Only add if NOT mocked
                                if (!matchesMock.check(&ii.event_path, cloned_mocks.items)) {
                                    test_module_items.append(allocator, p_item) catch {};
                                }
                            },
                            else => test_module_items.append(allocator, p_item) catch {},
                        }
                    }

                    // Add mock immediate_impls (these override any filtered out)
                    for (cloned_mocks.items) |m| {
                        test_module_items.append(allocator, m) catch {};
                    }

                    if (!validateMocks(allocator, &cloned_program, cloned_mocks.items, &source)) {
                        @panic("Mock shape validation failed");
                    }

                    const type_registry_module = @import("type_registry");
                    var local_registry_ptr: ?*type_registry_module.TypeRegistry = null;
                    const type_registry_ptr: ?*type_registry_module.TypeRegistry = if (program.type_registry) |ptr| blk: {
                        break :blk @ptrCast(@alignCast(ptr));
                    } else blk: {
                        local_registry_ptr = allocator.create(type_registry_module.TypeRegistry) catch unreachable;
                        local_registry_ptr.?.* = type_registry_module.TypeRegistry.init(allocator);
                        local_registry_ptr.?.populateFromAST(program.items) catch unreachable;
                        break :blk local_registry_ptr.?;
                    };
                    defer if (local_registry_ptr) |ptr| {
                        ptr.deinit();
                        allocator.destroy(ptr);
                    };

                    // Emit the test module using emitModuleSubset
                    // Pass the original main module name so tor references are redirected to test module
                    const test_module_code = emitter_helpers.emitModuleSubset(
                        allocator,
                        test_module_items.items,
                        test_module_name,
                        type_registry_ptr,
                        program.main_module_name,  // original main module name for tor redirection
                    ) catch |err| {
                        // Loud failure: silently skipping emission would mean the test block
                        // never exists — a test that "passes" by not being generated.
                        std_import.debug.print("FATAL: emitModuleSubset failed in test: {s}\n", .{@errorName(err)});
                        @panic("test transform: emitModuleSubset failed — see error above");
                    };

                    // The cloned body is a fresh parse (`__test__.kz`) and never went through
                    // the compiler's keyword-resolution pass. Without this, `assert` still
                    // carries the synthetic home and misses a qualified `std.testing:assert`
                    // handler (395_001). Registry and declaration lookup use the PARENT
                    // program — the clone skipped module_decls. Home is `__test__`, the
                    // parser's module name for that filename. Only the cloned body is
                    // rewritten; test_module_items already came through the outer pass.
                    const keyword_registry = @import("keyword_registry");
                    var kw_registry = keyword_registry.KeywordRegistry.init(allocator);
                    defer kw_registry.deinit();
                    keyword_registry.buildFromItems(program.items, &kw_registry, allocator) catch |err| {
                        std_import.debug.print("FATAL: keyword registry failed in test: {}\n", .{err});
                        @panic("test transform: keyword registry failed — see error above");
                    };
                    if (kw_registry.count() > 0) {
                        keyword_registry.resolveInASTWithLookup(
                            cloned_flows.items,
                            &kw_registry,
                            allocator,
                            "__test__",
                            cloned_flows.items,
                            program.items,
                        ) catch |err| {
                            std_import.debug.print("FATAL: keyword resolve failed in test: {}\n", .{err});
                            @panic("test transform: keyword resolve failed — see error above");
                        };
                    }

                    // Run transforms on test flows (for assert -> inline_code, etc.)
                    var flow_items = std_import.ArrayList(ast.Item).initCapacity(allocator, cloned_flows.items.len + test_module_items.items.len) catch unreachable;
                    for (cloned_flows.items) |f| flow_items.append(allocator, f) catch {};
                    // Include test module items for tor resolution during transform
                    for (test_module_items.items) |ti| flow_items.append(allocator, ti) catch {};

                    const flow_program = allocator.create(ast.Program) catch unreachable;
                    flow_program.* = ast.Program{
                        .items = flow_items.items,
                        .module_annotations = &[_][]const u8{},
                        .main_module_name = test_module_name,
                        .allocator = allocator,
                        .type_registry = program.type_registry,
                    };

                    const backend_output = @import("backend_output_emitted.zig");
                    const transformed_program = backend_output.run_pass("transform", flow_program, allocator, null) catch |err| {
                        // Loud failure: continuing with untransformed test flows would emit
                        // raw transform invocations into the test block.
                        std_import.debug.print("FATAL: transform pass failed in test: {}\n", .{err});
                        @panic("test transform: inner transform pass failed — see error above");
                    };

                    // ==========================================================================
                    // NEW: Walk TRANSFORMED flows for purity (after transforms!)
                    // At this point, assert() is already inline_code - won't trigger purity check
                    // ==========================================================================

                    std_import.debug.print("[TEST] Building mock lookup map\n", .{});

                    // Build mock lookup map for purity checking (still needed to know what's mocked)
                    var mock_paths = std_import.StringHashMap(ast.BranchConstructor).init(allocator);
                    for (cloned_mocks.items) |mock_item| {
                        if (mock_item == .immediate_impl) {
                            const ii = mock_item.immediate_impl;
                            var path_buf = std_import.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
                            for (ii.event_path.segments, 0..) |seg, i| {
                                if (i > 0) path_buf.append(allocator, '.') catch {};
                                path_buf.appendSlice(allocator, seg) catch {};
                            }
                            mock_paths.put(path_buf.items, ii.value) catch {};
                        }
                    }

                    // Also scan program for constant tors (immediate_impl items)
                    const scanForConstants = struct {
                        fn scan(items: []const ast.Item, paths: *std_import.StringHashMap(ast.BranchConstructor), alloc: std_import.mem.Allocator) void {
                            for (items) |prog_item| {
                                switch (prog_item) {
                                    .immediate_impl => |ii| {
                                        var path_buf = std_import.ArrayList(u8).initCapacity(alloc, 64) catch unreachable;
                                        for (ii.event_path.segments, 0..) |seg, i| {
                                            if (i > 0) path_buf.append(alloc, '.') catch {};
                                            path_buf.appendSlice(alloc, seg) catch {};
                                        }
                                        paths.put(path_buf.items, ii.value) catch {};
                                    },
                                    .module_decl => |mod| {
                                        scan(mod.items, paths, alloc);
                                    },
                                    else => {},
                                }
                            }
                        }
                    };
                    scanForConstants.scan(program.items, &mock_paths, allocator);

                    // Debug: Show all items in transformed program
                    std_import.debug.print("[TEST] Transformed program has {d} items:\n", .{transformed_program.items.len});
                    for (transformed_program.items, 0..) |t_item, idx| {
                        const item_type = switch (t_item) {
                            .flow => "flow",
                            .immediate_impl => "immediate_impl",
                            .event_decl => "event_decl",
                            .proc_decl => "proc_decl",
                            .module_decl => "module_decl",
                            .inline_code => "inline_code",
                            else => "other",
                        };
                        std_import.debug.print("[TEST]   [{d}] {s}\n", .{idx, item_type});
                        if (t_item == .flow) {
                            std_import.debug.print("[TEST]       invocation: {s}\n", .{t_item.flow.inv().path.segments[0]});
                        }
                        if (t_item == .inline_code) {
                            const preview_len = @min(50, t_item.inline_code.code.len);
                            std_import.debug.print("[TEST]       code: {s}...\n", .{t_item.inline_code.code[0..preview_len]});
                        }
                    }

                    // Find ONLY flows that originated from the test source block
                    var transformed_flows = std_import.ArrayList(*const ast.Flow).initCapacity(allocator, 8) catch unreachable;
                    for (transformed_program.items) |*t_item| {
                        if (t_item.* == .flow) {
                            if (std_import.mem.eql(u8, t_item.flow.location.file, "__test__.kz")) {
                                transformed_flows.append(allocator, &t_item.flow) catch {};
                            }
                        }
                    }

                    std_import.debug.print("[TEST] Found {d} transformed flows\n", .{transformed_flows.items.len});

                    var impure_events = std_import.ArrayList([]const u8).initCapacity(allocator, 8) catch unreachable;
                    for (transformed_flows.items) |t_flow| {
                        walkFlowForPurity(t_flow, &mock_paths, &impure_events, transformed_program.items, allocator);
                    }
                    std_import.debug.print("[TEST] Purity walk complete, {d} impure events\n", .{impure_events.items.len});

                    // Error on impure tors without mocks.
                    //
                    // The whole point of this refusal is that it names EVERY impure tor at
                    // once — one recompile, not one per tor. So the names go on the SAME LINE
                    // as the headline: a `@panic` payload is read as a single `panic: <msg>`
                    // line by every tool that quotes it, and a one-per-line list is silently
                    // dropped by anything that quotes only that first line (which is how this
                    // diagnostic got reported as printing nothing at all). One line also makes
                    // the full list a literal substring the regression corpus can PIN, so
                    // "lists them all" is defended by 395_005 rather than by eyeball.
                    if (impure_events.items.len > 0) {
                        var err_msg = std_import.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
                        err_msg.appendSlice(allocator, "Test '") catch {};
                        err_msg.appendSlice(allocator, test_name) catch {};
                        err_msg.appendSlice(allocator, "' has impure events without mocks: ") catch {};
                        for (impure_events.items, 0..) |event_path, i| {
                            if (i > 0) err_msg.appendSlice(allocator, ", ") catch {};
                            err_msg.appendSlice(allocator, event_path) catch {};
                        }
                        @panic(err_msg.items);
                    }

                    // ==========================================================================
                    // Emit test flow using test module prefix
                    // ==========================================================================

                    // Growable: generated test code has no natural size ceiling.
                    var code_emitter = emitter_helpers.CodeEmitter.initGrowable(allocator, 16 * 1024) catch unreachable;

                    // Dupe the test module name for the context (it needs to outlive the stack buffer)
                    const module_prefix_owned = allocator.dupe(u8, test_module_name) catch unreachable;

                    var emit_ctx = emitter_helpers.EmissionContext{
                        .allocator = allocator,
                        .indent_level = 1,
                        .ast_items = test_module_items.items,  // Use test module items for resolution
                        .main_module_name = module_prefix_owned,
                        .module_prefix = module_prefix_owned,  // KEY: Use test module for local references!
                        .is_sync = true,
                        .type_registry = type_registry_ptr,
                    };
                    code_emitter.indent_level = 1;

                    // Emit each transformed flow using the test module prefix
                    for (transformed_flows.items) |t_flow| {
                        emitter_helpers.emitFlow(&code_emitter, &emit_ctx, t_flow) catch {};
                    }

                    const flow_code = code_emitter.getOutput();

                    // Build final test code: test module + test block
                    const test_code = std_import.fmt.allocPrint(
                        allocator,
                        \\{s}
                        \\test "{s}" {{
                        \\{s}}}
                        ,
                        .{ test_module_code, test_name, flow_code }
                    ) catch unreachable;

                    // Create inline_code item
                    const new_item = ast.Item{ .inline_code = ast.InlineCode{
                        .code = test_code,
                        .location = flow.location,
                        .module = allocator.dupe(u8, flow.module) catch unreachable,
                    } };

                    return .{ .replacement = new_item };

            }
        };
        pub const validate_mocks_event = struct {
            pub const Input = struct {
                program: *const koru_std.koru_compiler.Program,
                mocks: []const koru_std.koru_compiler.Item,
                source: *const koru_std.koru_compiler.Source,
                allocator: std.mem.Allocator,
            };
            pub const Output = union(enum(u8)) {
                ok: struct {
                },
                failed: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: validate_mocks  [/Users/larsde/src/koru-cypoe/koru_std/testing.kz:274]
                const program = __koru_event_input.program;
                const mocks = __koru_event_input.mocks;
                const source = __koru_event_input.source;
                const allocator = __koru_event_input.allocator;
                _ = &program;
                _ = &mocks;
                _ = &source;
                _ = &allocator;
                _ = &__koru_event_input;

                    if (validateMocks(allocator, program, mocks, source)) {
                        return .{ .ok = .{} };
                    }
                    return .{ .failed = "Mock shape validation failed" };

            }
        };
        pub const test_with_harness_event = struct {
            pub const Input = struct {
                expr: []const u8,
                harness: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const test_harness_event = struct {
            pub const Input = struct {
                expr: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const test_property_equivalent_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const assert_event = struct {
            pub const Input = struct {
                expr: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: assert  [/Users/larsde/src/koru-cypoe/koru_std/testing.assert.kz:19]
                const expr = __koru_event_input.expr;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                _ = &expr;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &allocator;
                _ = &__koru_event_input;

                    const std_import = @import("std");
                    const ast = @import("ast");

                    // Get the flow from the item
                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    // Position-agnostic: the runner lifts nested sites into a synthetic
                    // top-level flow, so `invocation` IS the flow's own invocation at every depth.
                    // One write-back path: a statement-shaped inline_body (the old fork used
                    // preamble_code at top level and a raw inline_code node in pipelines —
                    // same emitted statement, two encodings). Continuations are KEPT so a
                    // chained `assert(x) |> next()` keeps running its chain at any depth.
                    _ = &invocation;

                    // Build assertion code - use idiomatic Zig testing assertions.
                    // //@koru:inline_stmt marks it statement-shaped for the inline emitter.
                    const assert_code = std_import.fmt.allocPrint(
                        allocator,
                        "//@koru:inline_stmt\ntry @import(\"std\").testing.expect({s});",
                        .{ expr }
                    ) catch unreachable;

                    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
                    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = flow.inv().path,
                        .args = &[_]ast.Arg{},
                        .annotations = flow.inv().annotations,
                        .marks = new_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                        .inline_body = assert_code,
                    };

                    const transformed_flow = ast.Flow{
                        .body = ast.rootSite(new_invocation, flow.body.continuations, flow.location),
                        .annotations = flow.annotations,
                        .pre_label = flow.pre_label,
                        .super_shape = flow.super_shape,
                        .inline_body = assert_code,
                        .is_pure = true,
                        .is_transitively_pure = true,
                        .impl_of = flow.impl_of,
                        .location = flow.location,
                        .module = flow.module,
                    };

                    const new_item = ast.Item{ .flow = transformed_flow };

                    return .{ .replacement = new_item };

            }
        };
        pub const assert_ok_event = struct {
            pub const Input = struct {
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: assert.ok  [/Users/larsde/src/koru-cypoe/koru_std/testing.assert.kz:80]
                _ = &__koru_event_input;

                    // assert.ok is a pass-through checkpoint - do nothing
                    // The test passed this branch by reaching this point

            }
        };
        pub const assert_fail_event = struct {
            pub const Input = struct {
                message: ?[]const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: assert.fail  [/Users/larsde/src/koru-cypoe/koru_std/testing.assert.kz:88]
                const message = __koru_event_input.message;
                _ = &message;
                _ = &__koru_event_input;

                    const msg = message orelse "Assertion failed";
                    @panic(msg);

            }
        };
        pub const assert_eq_event = struct {
            pub const Input = struct {
                expected: []const u8,
                actual: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: assert.eq  [/Users/larsde/src/koru-cypoe/koru_std/testing.compare.kz:14]
                const expected = __koru_event_input.expected;
                const actual = __koru_event_input.actual;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                _ = &expected;
                _ = &actual;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &allocator;
                _ = &__koru_event_input;

                    const std_import = @import("std");
                    const ast = @import("ast");

                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    _ = &invocation;
                    _ = &program;

                    // std.meta.eql compares structurally (numbers, strings, slices,
                    // optionals) without needing the element type spelled out. @panic
                    // rather than `try expect` — this fires in run-flows too, where the
                    // flow does not return an error union. Continuations are KEPT so a
                    // chained `assert.eq(a, b) |> next()` keeps running.
                    const assert_code = std_import.fmt.allocPrint(
                        allocator,
                        "//@koru:inline_stmt\nif (!@import(\"std\").meta.eql({s}, {s})) @panic(\"assert.eq failed\");",
                        .{ expected, actual }
                    ) catch unreachable;

                    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
                    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = flow.inv().path,
                        .args = &[_]ast.Arg{},
                        .annotations = flow.inv().annotations,
                        .marks = new_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                        .inline_body = assert_code,
                    };

                    const transformed_flow = ast.Flow{
                        .body = ast.rootSite(new_invocation, flow.body.continuations, flow.location),
                        .annotations = flow.annotations,
                        .pre_label = flow.pre_label,
                        .super_shape = flow.super_shape,
                        .inline_body = assert_code,
                        .is_pure = true,
                        .is_transitively_pure = true,
                        .impl_of = flow.impl_of,
                        .location = flow.location,
                        .module = flow.module,
                    };

                    const new_item = ast.Item{ .flow = transformed_flow };

                    return .{ .replacement = new_item };

            }
        };
        pub const assert_contains_event = struct {
            pub const Input = struct {
                haystack: []const u8,
                needle: []const u8,
                invocation: *const __koru_ast.Invocation,
                item: *const koru_std.koru_compiler.Item,
                program: *const koru_std.koru_compiler.Program,
                allocator: std.mem.Allocator,
            };
            pub const Output = __koru_ast.SiteResult;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: assert.contains  [/Users/larsde/src/koru-cypoe/koru_std/testing.compare.kz:79]
                const haystack = __koru_event_input.haystack;
                const needle = __koru_event_input.needle;
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                _ = &haystack;
                _ = &needle;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &allocator;
                _ = &__koru_event_input;

                    const std_import = @import("std");
                    const ast = @import("ast");

                    const flow = if (item.* == .flow)
                        &item.flow
                    else
                        return .{};

                    _ = &invocation;
                    _ = &program;

                    // u8-slice (string) contains — generic-element contains wants the
                    // child type named; string is the declared scope.
                    const assert_code = std_import.fmt.allocPrint(
                        allocator,
                        "//@koru:inline_stmt\nif (@import(\"std\").mem.indexOf(u8, {s}, {s}) == null) @panic(\"assert.contains failed\");",
                        .{ haystack, needle }
                    ) catch unreachable;

                    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 1) catch unreachable;
                    for (flow.inv().marks, 0..) |m, idx| new_marks[idx] = m;
                    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;

                    const new_invocation = ast.Invocation{
                        .path = flow.inv().path,
                        .args = &[_]ast.Arg{},
                        .annotations = flow.inv().annotations,
                        .marks = new_marks,
                        .inserted_by_tap = flow.inv().inserted_by_tap,
                        .from_opaque_tap = flow.inv().from_opaque_tap,
                        .inline_body = assert_code,
                    };

                    const transformed_flow = ast.Flow{
                        .body = ast.rootSite(new_invocation, flow.body.continuations, flow.location),
                        .annotations = flow.annotations,
                        .pre_label = flow.pre_label,
                        .super_shape = flow.super_shape,
                        .inline_body = assert_code,
                        .is_pure = true,
                        .is_transitively_pure = true,
                        .impl_of = flow.impl_of,
                        .location = flow.location,
                        .module = flow.module,
                    };

                    const new_item = ast.Item{ .flow = transformed_flow };

                    return .{ .replacement = new_item };

            }
        };
    };
    pub const koru_inter = struct {
        // Koru Interactive Compiler Mode
        // ===============================
        //
        // Usage:
        //   koruc myapp.kz --inter
        //
        // Launches an interactive TUI during compilation. Commands 1-9 print item
        // counts (tors, procs, flows, imports, ...) for each captured pipeline
        // stage; h for help, q to quit.
        //
        // This is a COMPTIME-ONLY feature - it runs during backend compilation,
        // not in the final binary.
        const std = @import("std");
        // Declare the --inter flag
        // The interactive mode entry point
        // Called from the compiler pipeline with contexts from each stage
        pub const start_event = struct {
            pub const Input = struct {
                contexts: []const koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = union(enum(u8)) {
                launched: struct {
                },
                skipped: struct {
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: start  [/Users/larsde/src/koru-cypoe/koru_std/inter.kz:35]
                const contexts = __koru_event_input.contexts;
                _ = &contexts;
                _ = &__koru_event_input;

                    // Always print to verify the integration works
                    log.debug("\n[INTER] inter:start called with {d} contexts\n", .{contexts.len});

                    // CompilerEnv is provided globally by the compiler backend
                    const env = @import("root").CompilerEnv;

                    // Check if --inter flag is set
                    if (!env.hasFlag("inter")) {
                        log.debug("[INTER] --inter flag not set, skipping\n", .{});
                        return .{ .skipped = .{} };
                    }

                    std.debug.print("\n", .{});
                    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
                    std.debug.print("║  KORU INTERACTIVE COMPILER                                   ║\n", .{});
                    std.debug.print("║  --inter mode activated                                      ║\n", .{});
                    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
                    std.debug.print("║  Pipeline stages captured: {d:<33}║\n", .{contexts.len});
                    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
                    std.debug.print("\n", .{});

                    // List what we have
                    for (contexts, 0..) |ctx, i| {
                        if (ctx.current_pass) |pass| {
                            std.debug.print("  {d}. {s:<20} ({d} passes, {d} items)\n", .{i + 1, pass, ctx.passes_completed, ctx.ast.items.len});
                        } else {
                            std.debug.print("  {d}. (unnamed)            ({d} passes, {d} items)\n", .{i + 1, ctx.passes_completed, ctx.ast.items.len});
                        }
                    }

                    std.debug.print("\n", .{});

                    // Interactive command loop
                    std.debug.print("Type 'h' for help, 'q' to quit.\n\n", .{});
                    const stdin = std.fs.File.stdin();
                    while (true) {
                        std.debug.print("inter> ", .{});

                        var buf: [256]u8 = undefined;
                        const n = stdin.read(&buf) catch break;
                        if (n == 0) break;  // EOF

                        // Find first non-whitespace char
                        var cmd: u8 = 0;
                        for (buf[0..n]) |c| {
                            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                                cmd = c;
                                break;
                            }
                        }

                        if (cmd == 'q' or cmd == 'Q') {
                            std.debug.print("Exiting inter mode.\n", .{});
                            break;
                        }

                        if (cmd == 'h' or cmd == 'H' or cmd == '?') {
                            std.debug.print("Commands:\n", .{});
                            std.debug.print("  1-{d}  Show stats for stage N\n", .{contexts.len});
                            std.debug.print("  h    Help\n", .{});
                            std.debug.print("  q    Quit\n", .{});
                            continue;
                        }

                        // Check for digit 1-9
                        if (cmd >= '1' and cmd <= '9') {
                            const stage_idx = cmd - '1';
                            if (stage_idx < contexts.len) {
                                const ctx = contexts[stage_idx];
                                std.debug.print("\n=== Stage {d} Stats ===\n", .{stage_idx + 1});
                                if (ctx.current_pass) |pass| {
                                    std.debug.print("  Current pass: {s}\n", .{pass});
                                }
                                std.debug.print("  Passes completed: {d}\n", .{ctx.passes_completed});
                                std.debug.print("  Total items: {d}\n", .{ctx.ast.items.len});

                                // Count item types
                                var events: usize = 0;
                                var procs: usize = 0;
                                var flows: usize = 0;
                                var flows_transformed: usize = 0;
                                var imports: usize = 0;
                                var host_lines: usize = 0;
                                var immediate_impls: usize = 0;
                                var modules: usize = 0;

                                // Helper to count a flow and check if transformed
                                const countFlow = struct {
                                    fn count(flow: anytype, f: *usize, ft: *usize) void {
                                        f.* += 1;
                                        if (flow.inline_body != null) ft.* += 1;
                                    }
                                }.count;

                                for (ctx.ast.items) |item| {
                                    switch (item) {
                                        .event_decl => events += 1,
                                        .proc_decl => procs += 1,
                                        .flow => |f| countFlow(f, &flows, &flows_transformed),
                                        .import_decl => imports += 1,
                                        .host_line => host_lines += 1,
                                        .immediate_impl => immediate_impls += 1,
                                        .module_decl => |mod| {
                                            modules += 1;
                                            for (mod.items) |mod_item| {
                                                switch (mod_item) {
                                                    .event_decl => events += 1,
                                                    .proc_decl => procs += 1,
                                                    .flow => |f| countFlow(f, &flows, &flows_transformed),
                                                    .import_decl => imports += 1,
                                                    .host_line => host_lines += 1,
                                                    .immediate_impl => immediate_impls += 1,
                                                    else => {},
                                                }
                                            }
                                        },
                                        else => {},
                                    }
                                }

                                std.debug.print("  Modules: {d}\n", .{modules});
                                std.debug.print("  Events: {d}\n", .{events});
                                std.debug.print("  Procs: {d}\n", .{procs});
                                std.debug.print("  Flows: {d} ({d} transformed)\n", .{flows, flows_transformed});
                                if (immediate_impls > 0) std.debug.print("  Immediate impls: {d}\n", .{immediate_impls});
                                std.debug.print("  Host lines: {d}\n", .{host_lines});
                                std.debug.print("  Errors: {d}, Warnings: {d}\n", .{ctx.errors.items.len, ctx.warnings.items.len});
                                std.debug.print("\n", .{});
                            } else {
                                std.debug.print("Stage {d} doesn't exist (max: {d})\n", .{stage_idx + 1, contexts.len});
                            }
                            continue;
                        }

                        if (cmd != 0) {
                            std.debug.print("Unknown command '{c}'. Type 'h' for help.\n", .{cmd});
                        }
                    }

                    return .{ .launched = .{} };

            }
        };
    };
    pub const koru_deps = struct {
        // deps.kz - System dependency management for Koru
        //
        // This module provides tors for declaring system-level dependencies
        // (libraries installed via brew, apt, dnf, pacman, etc.) that are required
        // for Koru packages to build.
        //
        // Usage in a library (e.g., curl/index.kz):
        //
        //   import std/deps
        //
        //   std/deps:requires.system {
        //       "name": "curl",
        //       "check": "curl-config --version",
        //       "brew": "curl",
        //       "apt": "libcurl4-openssl-dev"
        //   }
        //
        //   `check` answers presence (installed?). An optional `ready` field answers
        //   liveness — a command whose exit 0 means the dependency is usable NOW:
        //   a daemon accepting connections, a server listening:
        //
        //   std/deps:requires.system {
        //       "name": "docker",
        //       "check": "docker --version",
        //       "ready": "docker info",
        //       "brew": "docker"
        //   }
        //
        //   The third state — installed but not ready — is reported separately;
        //   `deps install` cannot fix a down daemon.
        //
        // Then users can run:
        //   koruc main.kz deps           # Show status of all system dependencies
        //   koruc main.kz deps install   # Install missing deps (auto-detects package manager)
        //   koruc main.kz deps install --pm brew   # Force specific package manager
        // ============================================================
        // REQUIRES.SYSTEM EVENT - Declare a system dependency
        // ============================================================
        // ============================================================
        // REQUIRES.ZIG EVENT - Declare a Zig package dependency
        // ============================================================
        // Koru Standard Library: the `command` part of deps.kz — the deps check/
        // install command implementation. Joined via `~part command` in deps.kz;
        // merged into the deps module at load.
        // ============================================================
        // DEPS COMMAND - Check and install system dependencies
        // ============================================================
        pub const requires_system_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: requires.system  [/Users/larsde/src/koru-cypoe/koru_std/deps.kz:51]
                const source = __koru_event_input.source;
                _ = &source;
                _ = &__koru_event_input;

                    // Void tor - collected during AST walking

            }
        };
        pub const requires_zig_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: requires.zig  [/Users/larsde/src/koru-cypoe/koru_std/deps.kz:61]
                const source = __koru_event_input.source;
                _ = &source;
                _ = &__koru_event_input;

                    // Void tor - collected during AST walking / build.zig.zon generation

            }
        };
        pub const deps_event = struct {
            pub const Input = struct {
                program: *const koru_std.koru_compiler.Program,
                allocator: __koru_std.mem.Allocator,
                argv: []const []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: deps  [/Users/larsde/src/koru-cypoe/koru_std/deps.command.kz:24]
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                const argv = __koru_event_input.argv;
                _ = &program;
                _ = &allocator;
                _ = &argv;
                _ = &__koru_event_input;

                    const std = @import("std");

                    // Helper types
                    const SystemDep = struct {
                        name: []const u8 = "",
                        check: []const u8 = "",
                        min_version: []const u8 = "",
                        brew: []const u8 = "",
                        apt: []const u8 = "",
                        dnf: []const u8 = "",
                        pacman: []const u8 = "",
                        apk: []const u8 = "",
                        // Liveness probe, separate from `check` (presence): exit 0 means the
                        // dependency is usable now — a daemon accepting connections, a server
                        // listening. `docker --version` answers installed; `docker info`
                        // answers alive. Install commands can fix missing, not not-ready.
                        ready: []const u8 = "",
                    };

                    const ZigDep = struct {
                        name: []const u8 = "",
                        url: []const u8 = "",
                        hash: []const u8 = "",
                    };

                    const CheckResult = struct {
                        success: bool,
                        output: []const u8,
                        version: ?[3]u32 = null,  // parsed semver: major, minor, patch
                    };

                    const Version = struct {
                        major: u32,
                        minor: u32,
                        patch: u32,

                        const Self = @This();

                        fn parse(s: []const u8) ?Self {
                            // Find version-like pattern: digits.digits.digits
                            var i: usize = 0;
                            // Skip non-digit prefix (e.g., "zig " or "v")
                            while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
                            if (i >= s.len) return null;

                            const start = i;
                            var dots: [2]usize = .{ 0, 0 };
                            var dot_count: usize = 0;

                            while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {
                                if (s[i] == '.' and dot_count < 2) {
                                    dots[dot_count] = i;
                                    dot_count += 1;
                                }
                            }

                            if (dot_count < 1) return null;  // Need at least major.minor

                            const major = std.fmt.parseInt(u32, s[start..dots[0]], 10) catch return null;
                            const minor_end = if (dot_count >= 2) dots[1] else i;
                            const minor = std.fmt.parseInt(u32, s[dots[0] + 1 .. minor_end], 10) catch return null;
                            const patch = if (dot_count >= 2)
                                std.fmt.parseInt(u32, s[dots[1] + 1 .. i], 10) catch 0
                            else
                                0;

                            return Self{ .major = major, .minor = minor, .patch = patch };
                        }

                        fn gte(self: Self, other: Self) bool {
                            if (self.major != other.major) return self.major > other.major;
                            if (self.minor != other.minor) return self.minor > other.minor;
                            return self.patch >= other.patch;
                        }

                        fn format(self: Self, buf: []u8) []const u8 {
                            return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch }) catch "?.?.?";
                        }
                    };

                    // Helper functions
                    const helpers = struct {
                        fn detectPackageManager(alloc: std.mem.Allocator) ?[]const u8 {
                            const pms = [_]struct { name: []const u8, check_cmd: []const u8 }{
                                .{ .name = "brew", .check_cmd = "brew --version" },
                                .{ .name = "apt", .check_cmd = "apt --version" },
                                .{ .name = "dnf", .check_cmd = "dnf --version" },
                                .{ .name = "pacman", .check_cmd = "pacman --version" },
                                .{ .name = "apk", .check_cmd = "apk --version" },
                            };

                            for (pms) |pm| {
                                const result = std.process.Child.run(.{
                                    .allocator = alloc,
                                    .argv = &[_][]const u8{ "sh", "-c", pm.check_cmd },
                                }) catch continue;
                                defer alloc.free(result.stdout);
                                defer alloc.free(result.stderr);

                                if (result.term.Exited == 0) {
                                    return pm.name;
                                }
                            }
                            return null;
                        }

                        fn runCheck(alloc: std.mem.Allocator, cmd: []const u8) CheckResult {
                            const result = std.process.Child.run(.{
                                .allocator = alloc,
                                .argv = &[_][]const u8{ "sh", "-c", cmd },
                            }) catch return .{ .success = false, .output = "" };

                            defer alloc.free(result.stderr);

                            if (result.term.Exited == 0) {
                                return .{ .success = true, .output = result.stdout };
                            } else {
                                alloc.free(result.stdout);
                                return .{ .success = false, .output = "" };
                            }
                        }

                        fn runInstall(alloc: std.mem.Allocator, pm: []const u8, pkg: []const u8) CheckResult {
                            const cmd = if (std.mem.eql(u8, pm, "brew"))
                                std.fmt.allocPrint(alloc, "brew install {s}", .{pkg}) catch return .{ .success = false, .output = "" }
                            else if (std.mem.eql(u8, pm, "apt"))
                                std.fmt.allocPrint(alloc, "sudo apt install -y {s}", .{pkg}) catch return .{ .success = false, .output = "" }
                            else if (std.mem.eql(u8, pm, "dnf"))
                                std.fmt.allocPrint(alloc, "sudo dnf install -y {s}", .{pkg}) catch return .{ .success = false, .output = "" }
                            else if (std.mem.eql(u8, pm, "pacman"))
                                std.fmt.allocPrint(alloc, "sudo pacman -S --noconfirm {s}", .{pkg}) catch return .{ .success = false, .output = "" }
                            else if (std.mem.eql(u8, pm, "apk"))
                                std.fmt.allocPrint(alloc, "sudo apk add {s}", .{pkg}) catch return .{ .success = false, .output = "" }
                            else
                                return .{ .success = false, .output = "" };

                            defer alloc.free(cmd);

                            const result = std.process.Child.run(.{
                                .allocator = alloc,
                                .argv = &[_][]const u8{ "sh", "-c", cmd },
                            }) catch return .{ .success = false, .output = "" };

                            defer alloc.free(result.stderr);

                            if (result.term.Exited == 0) {
                                return .{ .success = true, .output = result.stdout };
                            } else {
                                alloc.free(result.stdout);
                                const err_copy = alloc.dupe(u8, result.stderr) catch "";
                                return .{ .success = false, .output = err_copy };
                            }
                        }

                        fn firstLine(s: []const u8) []const u8 {
                            const trimmed = std.mem.trim(u8, s, " \t\n\r");
                            if (std.mem.indexOf(u8, trimmed, "\n")) |idx| {
                                return trimmed[0..idx];
                            }
                            return trimmed;
                        }

                        fn parseJsonField(source: []const u8, field: []const u8) []const u8 {
                            // Simple JSON field extraction: find "field": "value"
                            var search_buf: [64]u8 = undefined;
                            const search_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return "";

                            if (std.mem.indexOf(u8, source, search_pattern)) |start| {
                                const after_key = source[start + search_pattern.len ..];
                                // Skip whitespace
                                var i: usize = 0;
                                while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}
                                if (i >= after_key.len or after_key[i] != '"') return "";
                                i += 1; // Skip opening quote
                                const value_start = i;
                                while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
                                return after_key[value_start..i];
                            }
                            return "";
                        }
                    };

                    // Parse argv
                    var do_install = false;
                    var forced_pm: ?[]const u8 = null;

                    var i: usize = 0;
                    while (i < argv.len) : (i += 1) {
                        const arg = argv[i];
                        if (std.mem.eql(u8, arg, "install")) {
                            do_install = true;
                        } else if (std.mem.eql(u8, arg, "--pm") and i + 1 < argv.len) {
                            i += 1;
                            forced_pm = argv[i];
                        }
                    }

                    const detected_pm = forced_pm orelse helpers.detectPackageManager(allocator);

                    // Collect requires.system declarations
                    var deps_list = std.ArrayListUnmanaged(SystemDep){};
                    defer deps_list.deinit(allocator);

                    // Collect requires.zig declarations
                    var zig_deps_list = std.ArrayListUnmanaged(ZigDep){};
                    defer zig_deps_list.deinit(allocator);

                    // Always include Zig as a compiler requirement
                    deps_list.append(allocator, SystemDep{
                        .name = "zig",
                        .check = "zig version",
                        .min_version = "0.15.0",
                        .brew = "zig",
                        .apt = "zig",
                        .pacman = "zig",
                        .apk = "zig",
                    }) catch {};

                    // Helper to check build flags - inline to avoid cross-module import issues
                    const ann_parser = @import("annotation_parser");
                    const RootEnv = @import("root").CompilerEnv;
                    const matchesBuildFlags = struct {
                        fn check(annotations: []const []const u8) bool {
                            for (annotations) |ann| {
                                const maybe_call = ann_parser.parseCall(std.heap.page_allocator, ann) catch continue;
                                if (maybe_call) |call| {
                                    defer {
                                        var mc = call;
                                        mc.deinit(std.heap.page_allocator);
                                    }
                                    if (std.mem.eql(u8, call.name, "build")) {
                                        for (call.args) |arg| {
                                            var buf: [64]u8 = undefined;
                                            const flag = std.fmt.bufPrint(&buf, "build={s}", .{arg}) catch continue;
                                            if (RootEnv.hasFlagRuntime(flag)) return true;
                                        }
                                        return false;
                                    }
                                }
                            }
                            return true;
                        }
                    }.check;

                    // Scan for project dependencies — including those declared by IMPORTED
                    // LIBRARIES. `program.items` is one level deep, so walking it directly sees
                    // only the entry file: `koru/curl` declaring `requires.system` in its own
                    // index.kz was invisible, and `deps` reported one dependency for a program
                    // that links libcurl. `ast.allFlows` descends through `.module_decl`.
                    const ast_dep = @import("ast");
                    const all_flows = ast_dep.allFlows(allocator, program);
                    defer allocator.free(all_flows);
                    for (all_flows) |flow| {
                        {
                            if (flow.inv().path.module_qualifier) |mq| {
                                if (std.mem.eql(u8, mq, "std.deps") and
                                    flow.inv().path.segments.len == 2 and
                                    std.mem.eql(u8, flow.inv().path.segments[0], "requires") and
                                    std.mem.eql(u8, flow.inv().path.segments[1], "system"))
                                {
                                    // Respect build flags: [build("prod")], [build("dev")], etc.
                                    if (!matchesBuildFlags(flow.inv().annotations)) continue;
                                    // Extract source parameter
                                    for (flow.inv().args) |arg| {
                                        if (std.mem.eql(u8, arg.name, "source")) {
                                            var dep = SystemDep{};
                                            dep.name = helpers.parseJsonField(arg.value, "name");
                                            dep.check = helpers.parseJsonField(arg.value, "check");
                                            dep.min_version = helpers.parseJsonField(arg.value, "min_version");
                                            dep.brew = helpers.parseJsonField(arg.value, "brew");
                                            dep.apt = helpers.parseJsonField(arg.value, "apt");
                                            dep.dnf = helpers.parseJsonField(arg.value, "dnf");
                                            dep.pacman = helpers.parseJsonField(arg.value, "pacman");
                                            dep.apk = helpers.parseJsonField(arg.value, "apk");
                                            dep.ready = helpers.parseJsonField(arg.value, "ready");

                                            if (dep.name.len > 0) {
                                                deps_list.append(allocator, dep) catch {
                                                    std.debug.print("Out of memory\n", .{});
                                                    return;
                                                };
                                            }
                                        }
                                    }
                                }

                                // Check for requires.zig (Zig package manager dependencies)
                                if (std.mem.eql(u8, mq, "std.deps") and
                                    flow.inv().path.segments.len == 2 and
                                    std.mem.eql(u8, flow.inv().path.segments[0], "requires") and
                                    std.mem.eql(u8, flow.inv().path.segments[1], "zig"))
                                {
                                    if (!matchesBuildFlags(flow.inv().annotations)) continue;
                                    for (flow.inv().args) |arg| {
                                        if (std.mem.eql(u8, arg.name, "source")) {
                                            var zdep = ZigDep{};
                                            zdep.name = helpers.parseJsonField(arg.value, "name");
                                            zdep.url = helpers.parseJsonField(arg.value, "url");
                                            zdep.hash = helpers.parseJsonField(arg.value, "hash");

                                            if (zdep.name.len > 0) {
                                                zig_deps_list.append(allocator, zdep) catch {
                                                    std.debug.print("Out of memory\n", .{});
                                                    return;
                                                };
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Dedupe by name, first occurrence wins. Two libraries may each require
                    // curl, and now that the walk reaches imported modules that is the common
                    // case rather than the exception — a project should be told about curl once.
                    // It also absorbs `koru_std/compiler.kz`'s own `zig` declaration, which the
                    // recursive walk now reaches and which the seeded entry above already states.
                    {
                        var deduped = std.ArrayListUnmanaged(SystemDep){};
                        outer: for (deps_list.items) |d| {
                            for (deduped.items) |seen| {
                                if (std.mem.eql(u8, seen.name, d.name)) continue :outer;
                            }
                            deduped.append(allocator, d) catch break;
                        }
                        deps_list.deinit(allocator);
                        deps_list = deduped;
                    }

                    if (deps_list.items.len == 0 and zig_deps_list.items.len == 0) {
                        std.debug.print("No dependencies declared.\n", .{});
                        std.debug.print("Use: ~std.deps:requires.system {{ \"name\": \"...\", \"check\": \"...\", \"brew\": \"...\" }}\n", .{});
                        std.debug.print("     ~std.deps:requires.zig {{ \"name\": \"...\", \"url\": \"...\", \"hash\": \"...\" }}\n", .{});
                        return;
                    }

                    // Display zig package dependencies
                    if (zig_deps_list.items.len > 0) {
                        std.debug.print("\nZig package dependencies:\n\n", .{});

                        for (zig_deps_list.items) |zdep| {
                            std.debug.print("  {s} \x1b[34m⬡\x1b[0m\n", .{zdep.name});
                            if (zdep.url.len > 0) {
                                std.debug.print("       url: {s}\n", .{zdep.url});
                            }
                            if (zdep.hash.len > 0) {
                                std.debug.print("       hash: {s}\n", .{zdep.hash});
                            }
                        }

                        std.debug.print("\n", .{});

                        if (do_install) {
                            std.debug.print("Fetching zig dependencies...\n\n", .{});
                            for (zig_deps_list.items) |zdep| {
                                if (zdep.url.len == 0) continue;
                                std.debug.print("  Fetching {s}...\n", .{zdep.name});
                                const fetch_result = std.process.Child.run(.{
                                    .allocator = allocator,
                                    .argv = &[_][]const u8{ "zig", "fetch", zdep.url },
                                }) catch {
                                    std.debug.print("    \x1b[31m✗\x1b[0m failed to run zig fetch\n", .{});
                                    continue;
                                };
                                defer allocator.free(fetch_result.stdout);
                                defer allocator.free(fetch_result.stderr);

                                if (fetch_result.term.Exited == 0) {
                                    std.debug.print("    \x1b[32m✓\x1b[0m fetched\n", .{});
                                } else {
                                    std.debug.print("    \x1b[31m✗\x1b[0m fetch failed\n", .{});
                                    if (fetch_result.stderr.len > 0) {
                                        std.debug.print("    {s}\n", .{helpers.firstLine(fetch_result.stderr)});
                                    }
                                }
                            }
                            std.debug.print("\n", .{});
                        }
                    }

                    if (deps_list.items.len == 0) return;

                    std.debug.print("\nSystem dependencies for this project:\n\n", .{});

                    var missing = std.ArrayListUnmanaged(SystemDep){};
                    defer missing.deinit(allocator);

                    // Installed but the `ready` probe failed — present, unusable. Kept out of
                    // `missing` on purpose: `deps install` cannot fix a daemon that is down.
                    var not_ready = std.ArrayListUnmanaged(SystemDep){};
                    defer not_ready.deinit(allocator);

                    for (deps_list.items) |dep| {
                        if (dep.check.len > 0) {
                            const result = helpers.runCheck(allocator, dep.check);
                            if (result.success) {
                                const first_line = helpers.firstLine(result.output);
                                const installed_version = Version.parse(first_line);

                                // Check version constraint if specified
                                var version_ok = true;
                                if (dep.min_version.len > 0) {
                                    if (Version.parse(dep.min_version)) |min_ver| {
                                        if (installed_version) |inst_ver| {
                                            version_ok = inst_ver.gte(min_ver);
                                        } else {
                                            version_ok = false;  // Can't parse installed version
                                        }
                                    }
                                }

                                // Liveness is a third state: check passed but `ready` failed.
                                var ready_ok = true;
                                if (version_ok and dep.ready.len > 0) {
                                    const ready_result = helpers.runCheck(allocator, dep.ready);
                                    if (ready_result.output.len > 0) allocator.free(ready_result.output);
                                    ready_ok = ready_result.success;
                                }

                                if (version_ok and ready_ok) {
                                    std.debug.print("  {s} \x1b[32m✓\x1b[0m", .{dep.name});
                                } else {
                                    std.debug.print("  {s} \x1b[33m⚠\x1b[0m", .{dep.name});
                                }

                                if (result.output.len > 0) {
                                    std.debug.print(" ({s})", .{first_line});
                                    allocator.free(result.output);
                                }

                                if (!version_ok) {
                                    std.debug.print(" \x1b[33m- needs >= {s}\x1b[0m", .{dep.min_version});
                                    missing.append(allocator, dep) catch {};
                                } else if (!ready_ok) {
                                    std.debug.print(" \x1b[33m- installed, not ready\x1b[0m", .{});
                                    not_ready.append(allocator, dep) catch {};
                                }
                                std.debug.print("\n", .{});
                            } else {
                                std.debug.print("  {s} \x1b[31m✗\x1b[0m (not found)\n", .{dep.name});
                                missing.append(allocator, dep) catch {};
                            }
                        } else {
                            std.debug.print("  {s} \x1b[33m?\x1b[0m (no check command)\n", .{dep.name});
                        }

                        // Show package options
                        std.debug.print("       ", .{});
                        var has_any = false;
                        if (dep.brew.len > 0) {
                            if (detected_pm != null and std.mem.eql(u8, detected_pm.?, "brew")) {
                                std.debug.print("\x1b[1mbrew: {s}\x1b[0m", .{dep.brew});
                            } else {
                                std.debug.print("brew: {s}", .{dep.brew});
                            }
                            has_any = true;
                        }
                        if (dep.apt.len > 0) {
                            if (has_any) std.debug.print(" | ", .{});
                            if (detected_pm != null and std.mem.eql(u8, detected_pm.?, "apt")) {
                                std.debug.print("\x1b[1mapt: {s}\x1b[0m", .{dep.apt});
                            } else {
                                std.debug.print("apt: {s}", .{dep.apt});
                            }
                            has_any = true;
                        }
                        if (dep.dnf.len > 0) {
                            if (has_any) std.debug.print(" | ", .{});
                            std.debug.print("dnf: {s}", .{dep.dnf});
                            has_any = true;
                        }
                        if (dep.pacman.len > 0) {
                            if (has_any) std.debug.print(" | ", .{});
                            std.debug.print("pacman: {s}", .{dep.pacman});
                            has_any = true;
                        }
                        if (!has_any) {
                            std.debug.print("(no packages defined)", .{});
                        }
                        std.debug.print("\n", .{});
                    }

                    std.debug.print("\n", .{});

                    if (not_ready.items.len > 0) {
                        std.debug.print("\x1b[33mInstalled but not ready — start the service or daemon:\x1b[0m\n", .{});
                        for (not_ready.items) |dep| {
                            std.debug.print("  {s}  (ready-check: {s})\n", .{ dep.name, dep.ready });
                        }
                    }

                    if (missing.items.len == 0) {
                        if (not_ready.items.len == 0) {
                            std.debug.print("\x1b[32mAll system dependencies are installed!\x1b[0m\n", .{});
                        }
                        return;
                    }

                    if (!do_install) {
                        std.debug.print("To install missing dependencies:\n", .{});
                        std.debug.print("  koruc <file>.kz deps install", .{});
                        if (detected_pm) |pm| {
                            std.debug.print(" (detected: {s})\n", .{pm});
                        } else {
                            std.debug.print(" --pm <brew|apt|dnf|pacman|apk>\n", .{});
                        }
                        return;
                    }

                    const pm = detected_pm orelse {
                        std.debug.print("\x1b[31mCould not detect package manager. Use --pm to specify.\x1b[0m\n", .{});
                        return;
                    };

                    std.debug.print("Installing {d} missing dependencies with {s}...\n\n", .{ missing.items.len, pm });

                    for (missing.items) |dep| {
                        const pkg_name = if (std.mem.eql(u8, pm, "brew") and dep.brew.len > 0) dep.brew
                            else if (std.mem.eql(u8, pm, "apt") and dep.apt.len > 0) dep.apt
                            else if (std.mem.eql(u8, pm, "dnf") and dep.dnf.len > 0) dep.dnf
                            else if (std.mem.eql(u8, pm, "pacman") and dep.pacman.len > 0) dep.pacman
                            else if (std.mem.eql(u8, pm, "apk") and dep.apk.len > 0) dep.apk
                            else "";

                        if (pkg_name.len == 0) {
                            std.debug.print("  {s}: \x1b[33mno package defined for {s}\x1b[0m\n", .{ dep.name, pm });
                            continue;
                        }

                        std.debug.print("  Installing {s}...\n", .{pkg_name});

                        const install_result = helpers.runInstall(allocator, pm, pkg_name);
                        if (install_result.success) {
                            std.debug.print("    \x1b[32m✓\x1b[0m installed\n", .{});
                        } else {
                            std.debug.print("    \x1b[31m✗\x1b[0m failed\n", .{});
                            if (install_result.output.len > 0) {
                                std.debug.print("    {s}\n", .{install_result.output});
                            }
                        }
                        if (install_result.output.len > 0) allocator.free(install_result.output);
                    }

                    std.debug.print("\n", .{});

            }
        };
    };
    pub const koru_optimizer = struct {
        pub const optimize_event = struct {
            pub const Input = struct {
                ctx: koru_std.koru_compiler.CompilerContext,
            };
            pub const Output = koru_std.koru_compiler.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> SUBFLOW: /Users/larsde/src/koru-cypoe/koru_std/optimizer.k:31
                const ctx = __koru_event_input.ctx;
                _ = &ctx;
                _ = &__koru_event_input;
                const result = koru_std.koru_optimizations.koru_kernels.optimize_event.handler(.{ .ctx = ctx });
                const c1 = result;
                _ = &result;
                const c2 = koru_std.koru_optimizations.koru_loops.optimize_event.handler(.{ .ctx = c1 });
                _ = &c2;
                return c2;
            }
        };
    };
    pub const koru_rules = struct {
        // rules.kz — the CLAIMS REGISTRY for Koru
        //
        // A claim is something an author asserts about a declaration, written in the
        // vertical annotation block where the reader already is:
        //
        //   [
        //   - measured no-alloc-in-kernel
        //     This variant compiles the kernel body to a compute shader; the shape is
        //     checked by running it, not by inspection.
        //   ]proc compute|gpu { ... }
        //
        // The entry is the machine's half — a STAMP and an optional RULE NAME. The
        // prose underneath is the reader's half. They live in one block, so they cannot
        // drift apart.
        //
        //   koruc main.k claims          # the census, per stamp
        //   koruc main.k claims json     # the export
        //   koruc main.k assumes build   # what a declaration's flows rest on
        //   koruc main.k assumes build json
        //
        // WHO OWNS WHAT. The compiler carries an opaque entry list and, since the prose
        // change, the prose beside it; it does not know the word "claim". This module
        // defines the vocabulary — which words are stamps, what a key is, what counts
        // as a collision — and it errs loudly AS ITSELF when it evaluates something it
        // cannot (the consumer-relative-rejection rule from
        // frag-annotation-entries-are-expressions). A different module may ship a
        // different vocabulary over the same annotations and get identical support.
        //
        // WHAT THIS DOES NOT DO. It never judges whether a claim is TRUE. `proven` and
        // `measured` are discharged by runners; `inferred` is discharged by whatever
        // external engine the author points at the export. This module only guarantees
        // that every claim has a unique key, so an engine that judges one can say which
        // one it judged.
        //
        // `assumes` walks the CALL GRAPH instead of the annotation list. Literature:
        // Lean's `#print axioms`. Point at a declaration; get the transitive set of
        // declarations its flows can reach, graded by what each callee asserts about
        // itself — and, first-class, which reached declarations assert NOTHING. A
        // `measured` flow that calls five unclaimed things is telling you its
        // measurement did not cover them. The audit never judges truth; it reports
        // reach, and reach is a fact about the program, not a belief about it.
        const std = @import("std");
        const ast = @import("ast");
        // ============================================================
        // SHARED VOCABULARY — one definition, every command
        // ============================================================
        /// The stamps THIS module ships. A stamp says how well the claim is currently
        /// known, never whether it holds. The ladder runs proven (the type system
        /// discharged it) → measured (something ran) → inferred (something declared
        /// it) → aspirational (nothing yet — the honest undischarged claim).
        const STAMPS = [_][]const u8{ "proven", "measured", "inferred", "aspirational" };
        const Claim = struct {
            kind: []const u8, // "tor" (the contract) or "proc" (one implementation)
            module: []const u8,
            subject: []const u8,
            variant: []const u8, // proc target, e.g. "zig(optimized)"; "" for a tor
            stamp: []const u8,
            rule: []const u8, // "" when the stamp names no rule
            prose: []const u8,
            file: []const u8,
            line: usize,
        };
        /// An entry is a claim when its first word is one of our stamps. Every other
        /// entry belongs to some other consumer and is passed over in silence — the
        /// layering forbids this module having an opinion about `pure`, `comptime`,
        /// or anything else it did not define.
        const ClaimSplit = struct {
            stamp: []const u8,
            rule: []const u8,
        };
        fn claimSplit(entry: []const u8) ?ClaimSplit {
            const trimmed = std.mem.trim(u8, entry, " \t");
            const space = std.mem.indexOfAny(u8, trimmed, " \t");
            const head = if (space) |si| trimmed[0..si] else trimmed;
            for (STAMPS) |stamp| {
                if (std.mem.eql(u8, head, stamp)) {
                    const rule = if (space) |si| std.mem.trim(u8, trimmed[si..], " \t") else "";
                    return .{ .stamp = stamp, .rule = rule };
                }
            }
            return null;
        }
        fn dottedPath(alloc: std.mem.Allocator, p: *const ast.DottedPath) []const u8 {
            var buf = std.ArrayList(u8){};
            for (p.segments, 0..) |seg, i| {
                if (i > 0) buf.append(alloc, '.') catch unreachable;
                buf.appendSlice(alloc, seg) catch unreachable;
            }
            return buf.items;
        }
        /// "module:subject" for a dotted path — the canonical key every consumer
        /// compares on.
        fn pathKey(alloc: std.mem.Allocator, module: ?[]const u8, p: *const ast.DottedPath) []const u8 {
            const subj = dottedPath(alloc, p);
            var buf = std.ArrayList(u8){};
            if (module) |mq| {
                buf.appendSlice(alloc, mq) catch unreachable;
                buf.append(alloc, ':') catch unreachable;
            }
            buf.appendSlice(alloc, subj) catch unreachable;
            return buf.items;
        }
        fn claimFull(alloc: std.mem.Allocator, c: Claim) []const u8 {
            var buf = std.ArrayList(u8){};
            buf.appendSlice(alloc, c.module) catch unreachable;
            buf.append(alloc, ':') catch unreachable;
            buf.appendSlice(alloc, c.subject) catch unreachable;
            return buf.items;
        }
        /// Collect every claim on every declaration, descending through module_decl
        /// (an imported library's claims are visible, never silently dropped).
        fn collectClaims(alloc: std.mem.Allocator, list: []const ast.Item, out: *std.ArrayList(Claim)) void {
            for (list) |*it| switch (it.*) {
                .module_decl => |m| collectClaims(alloc, m.items, out),
                .event_decl => |e| {
                    for (e.annotations) |entry| {
                        const parts = claimSplit(entry) orelse continue;
                        out.append(alloc, .{
                            .kind = "tor",
                            .module = e.module,
                            .subject = dottedPath(alloc, &e.path),
                            .variant = "",
                            .stamp = parts.stamp,
                            .rule = parts.rule,
                            .prose = e.prose,
                            .file = e.location.file,
                            .line = e.location.line,
                        }) catch unreachable;
                    }
                },
                .proc_decl => |p| {
                    for (p.annotations) |entry| {
                        const parts = claimSplit(entry) orelse continue;
                        out.append(alloc, .{
                            .kind = "proc",
                            .module = p.module,
                            .subject = dottedPath(alloc, &p.path),
                            .variant = p.target orelse "",
                            .stamp = parts.stamp,
                            .rule = parts.rule,
                            .prose = p.prose,
                            .file = p.location.file,
                            .line = p.location.line,
                        }) catch unreachable;
                    }
                },
                else => {},
            };
        }
        fn printJson(v: []const u8) void {
            std.debug.print("\"", .{});
            for (v) |c| switch (c) {
                '"' => std.debug.print("\\\"", .{}),
                '\\' => std.debug.print("\\\\", .{}),
                '\n' => std.debug.print("\\n", .{}),
                '\t' => std.debug.print("\\t", .{}),
                else => std.debug.print("{c}", .{c}),
            };
            std.debug.print("\"", .{});
        }
        // ============================================================
        // THE CLAIMS COMMAND — the census
        // ============================================================
        // ============================================================
        // THE ASSUMES COMMAND — the transitive closure
        // ============================================================
        pub const claims_event = struct {
            pub const Input = struct {
                program: *const koru_std.koru_compiler.Program,
                allocator: __koru_std.mem.Allocator,
                argv: []const []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: claims  [/Users/larsde/src/koru-cypoe/koru_std/rules.kz:192]
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                const argv = __koru_event_input.argv;
                _ = &program;
                _ = &allocator;
                _ = &argv;
                _ = &__koru_event_input;

                    var format: []const u8 = "text";
                    if (argv.len > 0) {
                        const fmt = argv[0];
                        if (std.mem.eql(u8, fmt, "text") or std.mem.eql(u8, fmt, "json")) {
                            format = fmt;
                        } else {
                            std.debug.print("claims: unknown format '{s}' — expected text | json\n", .{fmt});
                            std.process.exit(2);
                        }
                    }

                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const arena_alloc = arena.allocator();

                    var claims_found = std.ArrayList(Claim){};
                    collectClaims(arena_alloc, program.items, &claims_found);
                    const found = claims_found.items;

                    // ── the key, and the crash ────────────────────────────────────────────
                    //
                    // The key is kind + module + subject + VARIANT + rule. The variant is not
                    // decoration: `proc compute|zig` and `proc compute|gpu` are two different
                    // implementations of one contract (370_VARIANTS/8201_variants_basic
                    // declares three), and each deserves its own claim. Drop the variant from
                    // the key and they collide — which is exactly what this check exists to
                    // catch, including in the design of the key itself.
                    const sameKey = struct {
                        fn call(a: Claim, b: Claim) bool {
                            return std.mem.eql(u8, a.kind, b.kind) and
                                std.mem.eql(u8, a.module, b.module) and
                                std.mem.eql(u8, a.subject, b.subject) and
                                std.mem.eql(u8, a.variant, b.variant) and
                                std.mem.eql(u8, a.rule, b.rule);
                        }
                    }.call;

                    var crashes: usize = 0;
                    for (found, 0..) |claim, i| {
                        for (found[0..i]) |earlier| {
                            if (!sameKey(claim, earlier)) continue;
                            crashes += 1;
                            const rule_label = if (claim.rule.len == 0) "<unnamed>" else claim.rule;
                            std.debug.print(
                                "error: duplicate claim key — {s} {s}:{s}{s}{s} already claims rule '{s}'\n" ++
                                    "  first  --> {s}:{d}  [{s}]\n" ++
                                    "  second --> {s}:{d}  [{s}]\n" ++
                                    "  a claim key is kind + module + subject + variant + rule; two claims on one\n" ++
                                    "  key cannot both be answered, and an external judgment could not say which it\n" ++
                                    "  judged. Make them distinct.\n",
                                .{ claim.kind, claim.module, claim.subject, if (claim.variant.len > 0) "|" else "", claim.variant, rule_label, earlier.file, earlier.line, earlier.stamp, claim.file, claim.line, claim.stamp },
                            );
                        }
                    }

                    if (std.mem.eql(u8, format, "json")) {
                        std.debug.print("{{\"claims\":[", .{});
                        for (found, 0..) |c, i| {
                            if (i > 0) std.debug.print(",", .{});
                            std.debug.print(
                                "{{\"kind\":\"{s}\",\"module\":\"{s}\",\"subject\":\"{s}\",\"variant\":\"{s}\"," ++
                                    "\"stamp\":\"{s}\",\"rule\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"prose\":",
                                .{ c.kind, c.module, c.subject, c.variant, c.stamp, c.rule, c.file, c.line },
                            );
                            printJson(c.prose);
                            std.debug.print("}}", .{});
                        }
                        std.debug.print("],\"key_collisions\":{d}}}\n", .{crashes});
                        if (crashes > 0) std.process.exit(1);
                        return;
                    }

                    if (found.len == 0) {
                        std.debug.print("📋 claims — none. Authors make one with a stamp in a vertical annotation block:\n", .{});
                        std.debug.print("   ~[\\n   - aspirational\\n     why this is not discharged yet\\n   ]tor thing {{}}\n", .{});
                        return;
                    }

                    std.debug.print("📋 claims — {d} in this program\n\n", .{found.len});
                    for (STAMPS) |stamp| {
                        var count: usize = 0;
                        for (found) |c| {
                            if (std.mem.eql(u8, c.stamp, stamp)) count += 1;
                        }
                        if (count == 0) continue;
                        std.debug.print("{s} ({d})\n", .{ stamp, count });
                        for (found) |c| {
                            if (!std.mem.eql(u8, c.stamp, stamp)) continue;
                            const sep = if (c.variant.len > 0) "|" else "";
                            const rule_label = if (c.rule.len == 0) "" else c.rule;
                            std.debug.print("  {s} {s}:{s}{s}{s}", .{ c.kind, c.module, c.subject, sep, c.variant });
                            if (rule_label.len > 0) std.debug.print("  → {s}", .{rule_label});
                            std.debug.print("\n      {s}:{d}\n", .{ c.file, c.line });
                            if (c.prose.len > 0) {
                                var lines = std.mem.splitScalar(u8, c.prose, '\n');
                                while (lines.next()) |line| std.debug.print("      │ {s}\n", .{line});
                            }
                        }
                        std.debug.print("\n", .{});
                    }

                    if (crashes > 0) {
                        std.debug.print("{d} duplicate claim key(s) — the export cannot be trusted until they\n", .{crashes});
                        std.debug.print("are distinct. Fix the claims, then re-run.\n", .{});
                        std.process.exit(1);
                    }

            }
        };
        pub const assumes_event = struct {
            pub const Input = struct {
                program: *const koru_std.koru_compiler.Program,
                allocator: __koru_std.mem.Allocator,
                argv: []const []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: assumes  [/Users/larsde/src/koru-cypoe/koru_std/rules.kz:316]
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                const argv = __koru_event_input.argv;
                _ = &program;
                _ = &allocator;
                _ = &argv;
                _ = &__koru_event_input;

                    // `assumes <subject> [text|json]`
                    //
                    // SUBJECT. A dotted path, or a bare name when unambiguous across modules:
                    //
                    //   koruc main.k assumes build              # any module's build, else error
                    //   koruc main.k assumes main:build         # qualified
                    //
                    // WALK. The scope of "rests on" is the program's flows: resolve the
                    // subject to a declaration key; expand that key to the flows that
                    // implement it (a flow item's `impl_of` names the tor it implements —
                    // the subflow `build = ...` carries impl_of = build; for flows without an
                    // impl_of, the head invocation names the contract); walk every flow body
                    // for invocations; every reached declaration is reported with its stamp —
                    // or conspicuously without one. visited guards the cycles a transitive
                    // closure always contains.
                    //
                    // It does not judge. It does not gate. It reports reach; what to do
                    // about an unclaimed callee belongs to a consumer.

                    if (argv.len == 0) {
                        std.debug.print("assumes: a subject is required — e.g. `koruc main.k assumes build`\n", .{});
                        std.process.exit(2);
                    }
                    var format: []const u8 = "text";
                    const subject_arg = argv[0];
                    if (argv.len > 1) {
                        const fmt = argv[1];
                        if (std.mem.eql(u8, fmt, "text") or std.mem.eql(u8, fmt, "json")) {
                            format = fmt;
                        } else {
                            std.debug.print("assumes: unknown format '{s}' — expected text | json\n", .{fmt});
                            std.process.exit(2);
                        }
                    }

                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const aa = arena.allocator();

                    // Index: every tor and proc key (the reachable declarations).
                    var event_keys = std.ArrayList([]const u8){};
                    var proc_keys = std.ArrayList([]const u8){};
                    var claims_all = std.ArrayList(Claim){};
                    collectClaims(aa, program.items, &claims_all);
                    const claims = claims_all.items;

                    const keyAdd = struct {
                        fn call(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, key: []const u8) void {
                            for (list.items) |k| if (std.mem.eql(u8, k, key)) return;
                            list.append(alloc, key) catch unreachable;
                        }
                    }.call;
                    {
                        var stack = std.ArrayList([]const ast.Item){};
                        stack.append(aa, program.items) catch unreachable;
                        while (stack.items.len > 0) {
                            const items = stack.pop().?;
                            for (items) |*it| switch (it.*) {
                                .module_decl => |m| stack.append(aa, m.items) catch unreachable,
                                .event_decl => |e| keyAdd(&event_keys, aa, pathKey(aa, e.module, &e.path)),
                                .proc_decl => |p| keyAdd(&proc_keys, aa, pathKey(aa, p.module, &p.path)),
                                else => {},
                            };
                        }
                    }

                    // Subject: bare name (last path segment) or full key, unambiguous.
                    var subject_full: []const u8 = "";
                    {
                        const isCandidate = struct {
                            fn call(k: []const u8, subj: []const u8) bool {
                                const colon = std.mem.lastIndexOfScalar(u8, k, ':');
                                const tail = if (colon) |ci| k[ci + 1 ..] else k;
                                return std.mem.eql(u8, tail, subj) or std.mem.eql(u8, k, subj);
                            }
                        }.call;
                        var matches: usize = 0;
                        for (event_keys.items) |k| {
                            if (isCandidate(k, subject_arg)) {
                                matches += 1;
                                subject_full = k;
                            }
                        }
                        for (proc_keys.items) |k| {
                            if (isCandidate(k, subject_arg)) {
                                matches += 1;
                                subject_full = k;
                            }
                        }
                        if (matches == 0) {
                            std.debug.print("assumes: no declaration '{s}' in this program\n", .{subject_arg});
                            std.process.exit(2);
                        }
                        if (matches > 1) {
                            std.debug.print("assumes: '{s}' is ambiguous ({d} candidates) — qualify it (module:name)\n", .{ subject_arg, matches });
                            std.process.exit(2);
                        }
                    }

                    // ── reachability over flows ────────────────────────────────────────────
                    const flows = ast.allFlows(aa, program);
                    defer _ = aa.free(flows);

                    // One owner->callee edge of the reach graph, recorded while a flow body
                    // is walked. `Edge` must be declared BEFORE walkBody (its signature names
                    // it), which is why it lives beside headKey rather than at the grade step.
                    const Edge = struct {
                        from: []const u8,
                        to: []const u8,
                    };

                    const headKey = struct {
                        fn call(f: *const ast.Flow, aa_param: std.mem.Allocator) []const u8 {
                            // A flow item's contract is its `impl_of` (the tor it
                            // implements); for flows without one, the head invocation names
                            // it. The head itself is the FIRST CALL in the body (the `~for`
                            // in `build = ~for(...)`), so it is the contract only for
                            // head-less flows.
                            if (f.impl_of) |io| {
                                return pathKey(aa_param, io.module_qualifier, &io);
                            }
                            const head = f.inv();
                            return pathKey(aa_param, head.path.module_qualifier, &head.path);
                        }
                    }.call;

                    var visited = std.StringHashMapUnmanaged(void){};
                    var order = std.ArrayList([]const u8){};
                    var frontier = std.ArrayList([]const u8){};

                    // visit — mark a key reached in discovery order; declared keys that may
                    // have bodies of their own go to the frontier for expansion. Everything
                    // comes in as parameters: nested structs cannot capture the proc's locals.
                    const visitKey = struct {
                        fn call(
                            key: []const u8,
                            aa_param: std.mem.Allocator,
                            visited_param: *std.StringHashMapUnmanaged(void),
                            order_param: *std.ArrayList([]const u8),
                            frontier_param: *std.ArrayList([]const u8),
                            event_keys_param: []const []const u8,
                            proc_keys_param: []const []const u8,
                        ) void {
                            if (key.len == 0) return;
                            if (visited_param.contains(key)) return;
                            visited_param.put(aa_param, key, {}) catch unreachable;
                            order_param.append(aa_param, key) catch unreachable;
                            var declared = false;
                            for (event_keys_param) |k| {
                                if (std.mem.eql(u8, k, key)) declared = true;
                            }
                            for (proc_keys_param) |k| {
                                if (std.mem.eql(u8, k, key)) declared = true;
                            }
                            if (declared) frontier_param.append(aa_param, key) catch unreachable;
                        }
                    }.call;

                    // walkBody — walk one flow's body as a continuation worklist; every
                    // invocation inside becomes a callee key (via visitKey). Branch bodies
                    // join the worklist; labelled invocations and legacy conditional blocks
                    // pass their inner invocation through.
                    const walkBody = struct {
                        fn call(
                            f: *const ast.Flow,
                            owner: []const u8,
                            aa_param: std.mem.Allocator,
                            visited_param: *std.StringHashMapUnmanaged(void),
                            order_param: *std.ArrayList([]const u8),
                            frontier_param: *std.ArrayList([]const u8),
                            event_keys_param: []const []const u8,
                            proc_keys_param: []const []const u8,
                            edges_param: *std.ArrayList(Edge),
                        ) void {
                            var cont_stack = std.ArrayList(ast.Continuation){};
                            cont_stack.append(aa_param, f.body) catch unreachable;
                            while (cont_stack.items.len > 0) {
                                const c = cont_stack.pop().?;
                                if (c.node) |n| switch (n) {
                                    .invocation => |inv| {
                                        const k = pathKey(aa_param, inv.path.module_qualifier, &inv.path);
                                        visitKey(k, aa_param, visited_param, order_param, frontier_param, event_keys_param, proc_keys_param);
                                        edges_param.append(aa_param, .{ .from = owner, .to = k }) catch unreachable;
                                    },
                                    .label_with_invocation => |lwi| {
                                        const k = pathKey(aa_param, lwi.invocation.path.module_qualifier, &lwi.invocation.path);
                                        visitKey(k, aa_param, visited_param, order_param, frontier_param, event_keys_param, proc_keys_param);
                                        edges_param.append(aa_param, .{ .from = owner, .to = k }) catch unreachable;
                                    },
                                    .foreach => |fe| for (fe.branches) |br| for (br.body) |cc| cont_stack.append(aa_param, cc) catch unreachable,
                                    .conditional => |cd| for (cd.branches) |br| for (br.body) |cc| cont_stack.append(aa_param, cc) catch unreachable,
                                    .switch_result => |sr| for (sr.branches) |br| for (br.body) |cc| cont_stack.append(aa_param, cc) catch unreachable,
                                    .conditional_block => |cb| for (cb.nodes) |nd| switch (nd) {
                                        .invocation => |inv| {
                                            const k = pathKey(aa_param, inv.path.module_qualifier, &inv.path);
                                            visitKey(k, aa_param, visited_param, order_param, frontier_param, event_keys_param, proc_keys_param);
                                            edges_param.append(aa_param, .{ .from = owner, .to = k }) catch unreachable;
                                        },
                                        else => {},
                                    },
                                    else => {},
                                };
                                for (c.continuations) |cc| cont_stack.append(aa_param, cc) catch unreachable;
                            }
                        }
                    }.call;

                    // ── the effective grade: what the closure RESTS ON ────────────────────
                    // The authored stamp is a fact about one declaration in isolation. The
                    // effective grade is a fact about the closure: the weakest claim anywhere
                    // beneath a key, computed over the reach edges just walked. Lean's
                    // `#print axioms` shows `[sorryAx]` under a theorem that uses `sorry`;
                    // this is the Koru analogue — a `proven` claim whose closure contains an
                    // `aspirational` or `unclaimed` callee presents an effective grade below
                    // `proven`. The authored stamp is never overridden.
                    var edges = std.ArrayList(Edge){};

                    // seed the subject, then expand the frontier: every flow whose head key
                    // matches a frontier key gets its body walked (enqueuing real callees
                    // and recording the owner->callee edge for the grade computation).
                    visitKey(subject_full, aa, &visited, &order, &frontier, event_keys.items, proc_keys.items);
                    while (frontier.items.len > 0) {
                        const key = frontier.pop().?;
                        for (flows) |*f| {
                            if (!std.mem.eql(u8, headKey(f, aa), key)) continue;
                            walkBody(f, key, aa, &visited, &order, &frontier, event_keys.items, proc_keys.items, &edges);
                        }
                    }

                    // ── the effective grade: what the closure RESTS ON ─────────────────
                    // The authored stamp is a fact about ONE declaration in isolation. The
                    // effective grade is a fact about the CLOSURE: the weakest claim anywhere
                    // beneath a key, per Lean's `#print axioms` showing [sorryAx]. A
                    // `proven` claim whose closure contains an aspirational/unclaimed callee
                    // presents an effective grade below `proven` — the authored stamp is
                    // never overridden.
                    //
                    // Ladder, weakest first: unclaimed(0) < aspirational(1) < inferred(2) <
                    // measured(3) < proven(4). effective(key) = min(own rank, effective of
                    // every callee in the reach edges). The walk visited each key ONCE, so
                    // the edge graph is a DAG and the memo needs no cycle guard.

                    const LADDER = [_][]const u8{ "unclaimed", "aspirational", "inferred", "measured", "proven" };
                    const rankOf = struct {
                        fn call(stamp: []const u8) usize {
                            for (LADDER, 0..) |label, r| {
                                if (std.mem.eql(u8, stamp, label)) return r;
                            }
                            return 0;
                        }
                    }.call;
                    const labelOf = struct {
                        fn call(r: usize) []const u8 {
                            if (r < LADDER.len) return LADDER[r];
                            return "unclaimed";
                        }
                    }.call;

                    const Grade = struct {
                        aa_param: std.mem.Allocator,
                        keys_param: []const []const u8,
                        edges_param: []const Edge,
                        claims_param: []const Claim,
                    };
                    // The grade is the weak link of a key's SUBTREE. The walk visited each
                    // key exactly once in `order`, so the edges form a DAG; a post-order
                    // fold over that DAG computes every grade without recursion (Zig nested
                    // consts cannot self-reference, and an iterative fold needs no cycle
                    // guard for the same DAG reason). DFS with an explicit exit stack.
                    const gradeOfAll = struct {
                        fn call(
                            g: *const Grade,
                            memo: *std.StringHashMapUnmanaged(usize),
                        ) void {
                            // enter/exit phases; only leaf keys (no outgoing edges) finalise
                            // first, so every callee's grade is final before its caller's.
                            var stack = std.ArrayList(struct { key: []const u8, done: bool }){};
                            var visit = std.StringHashMapUnmanaged(void){};
                            for (g.keys_param) |root| {
                                if (memo.contains(root)) continue;
                                visit.put(g.aa_param, root, {}) catch unreachable;
                                stack.append(g.aa_param, .{ .key = root, .done = false }) catch unreachable;
                                while (stack.items.len > 0) {
                                    const top = stack.pop().?;
                                    if (top.done) {
                                        // finalise: min over own rank + final callee grades
                                        var best: usize = 0;
                                        for (g.claims_param) |c| {
                                            if (!std.mem.eql(u8, claimFull(g.aa_param, c), top.key)) continue;
                                            const r = rankOf(c.stamp);
                                            if (r > best) best = r;
                                        }
                                        var through: usize = best;
                                        for (g.edges_param) |e| {
                                            if (!std.mem.eql(u8, e.from, top.key)) continue;
                                            const cr = memo.get(e.to) orelse continue;
                                            if (cr < through) through = cr;
                                        }
                                        memo.put(g.aa_param, top.key, through) catch unreachable;
                                    } else {
                                        stack.append(g.aa_param, .{ .key = top.key, .done = true }) catch unreachable;
                                        for (g.edges_param) |e| {
                                            if (!std.mem.eql(u8, e.from, top.key)) continue;
                                            if (memo.contains(e.to)) continue;
                                            if (visit.contains(e.to)) continue;
                                            visit.put(g.aa_param, e.to, {}) catch unreachable;
                                            stack.append(g.aa_param, .{ .key = e.to, .done = false }) catch unreachable;
                                        }
                                    }
                                }
                            }
                        }
                    }.call;

                    var eff_memo = std.StringHashMapUnmanaged(usize){};
                    gradeOfAll(&.{ .aa_param = aa, .keys_param = order.items, .edges_param = edges.items, .claims_param = claims }, &eff_memo);

                    // ── render ─────────────────────────────
                    if (std.mem.eql(u8, format, "json")) {
                        std.debug.print("{{\"subject\":", .{});
                        printJson(subject_full);
                        std.debug.print(",\"reaches\":[", .{});
                        var first = true;
                        for (order.items) |key| {
                            const eff = eff_memo.get(key) orelse 0;
                            const eff_label = labelOf(eff);
                            var any_claim = false;
                            for (claims) |c| {
                                if (!std.mem.eql(u8, claimFull(aa, c), key)) continue;
                                if (!first) std.debug.print(",", .{});
                                first = false;
                                any_claim = true;
                                std.debug.print("{{\"key\":", .{});
                                printJson(key);
                                std.debug.print(",\"stamp\":", .{});
                                printJson(c.stamp);
                                std.debug.print(",\"effective\":", .{});
                                printJson(eff_label);
                                std.debug.print("}}", .{});
                            }
                            if (!any_claim) {
                                if (!first) std.debug.print(",", .{});
                                first = false;
                                std.debug.print("{{\"key\":", .{});
                                printJson(key);
                                std.debug.print(",\"stamp\":", .{});
                                printJson("unclaimed");
                                std.debug.print(",\"effective\":", .{});
                                printJson(eff_label);
                                std.debug.print("}}", .{});
                            }
                        }
                        std.debug.print("]}}\n", .{});
                        return;
                    }

                    std.debug.print("📋 assumes — {s}\n", .{subject_full});
                    if (order.items.len == 0) {
                        std.debug.print("  (nothing reachable)\n", .{});
                        return;
                    }
                    for (order.items) |key| {
                        var stamped = false;
                        const eff = eff_memo.get(key) orelse 0;
                        const eff_label = labelOf(eff);
                        for (claims) |c| {
                            if (std.mem.eql(u8, claimFull(aa, c), key)) {
                                std.debug.print("  {s}:{s}  [{s}] {s}\n", .{ c.module, c.subject, c.stamp, c.rule });
                                stamped = true;
                            }
                        }
                        if (!stamped) std.debug.print("  {s}  [unclaimed]\n", .{key});
                        std.debug.print("  ↓ effective: {s}\n", .{eff_label});
                    }

            }
        };
    };
    pub const koru_realize = struct {
        // Koru Standard Library: realize — the generic correspondence solver.
        //
        // The solver over the std/spec harvest (DESIGN-0001 §3.4/§11.1): a program
        // walks its used interfaces, matches each against a catalog of declared
        // `row` sites, and admits or refuses each one against the selected
        // execution arm's bindings. A refusal writes no artifact — loud refusal of
        // unsupported capabilities is the contract, at every altitude:
        //
        //   interface -> row -> arm binding -> mechanism
        //
        // Declaration shape (the invariants idiom — data in the AST, [norun],
        // harvested after the parse by a [comptime|command] consumer):
        //
        //   ~std/realize:row {
        //       "iface": "dom/lift[:torprefix]",
        //       "stack": 4096,
        //       "resources": "mechanism: cost",
        //       "evidence": "V: ...",
        //       "binds": [ { "arm": "arm/name", "mechanism": "mech",
        //                    "deltas": ["..."] } ] }
        //
        //   ~std/realize:arm { "arm": "arm/name" }   // a matrix column; an arm with
        //                                            // no bindings IS the provider gap
        //
        // This module is policy-free: it owns the row/arm declaration vocabulary,
        // the catalog merge (duplicate-arm and contradiction refusals), the used-
        // interface walk, admission verdicts + marks, the arm matrix, rows.json and
        // the arm manifest writer. What it does NOT own: any concrete arm name, the
        // meaning of a `mechanism` string, artifact shapes (Kraftfile, Makefile.uk,
        // link-phase chains), and the waiver policy for system modules — those are
        // the consumer's (koruos/realize passes its arm table, its builtin rows as
        // ordinary declared sites, and its mechanism-specific artifact writers).
        //
        // `row`'s `iface` names the §3.6 demand-side identity — the interface
        // descriptor the program obliges — not the artifact that serves it. Today
        // the field carries the identifier (`qual/path[:torprefix]`); the typed
        // descriptor columns (inputs, branches, effects, authority, revision,
        // evidence) are the std/spec vocabulary this catalog is meant to grow into.
        // A lift declares its own row by invoking
        //   `~std/realize:row(iface: koruos/ext2) { ...json... }`
        // at module top level — norun data in the AST, harvested by the command
        // consumer. The `iface` arg is a *name* the resolver can know (bare path or
        // member chain; a quoted string stays verbatim — an explicitly conceptual
        // iface that opts out of resolution). Everything in the Source block is
        // foreign data — stacks, prose, arm names, mechanism deltas — strings by
        // nature, JSON by honesty. `arm` declares a coverage-matrix column: a
        // prospective arm needs no bindings to appear — its empty column IS the
        // provider gap.
        const std = @import("std");
        const ast = @import("ast");
        const eh = @import("emitter_helpers");
        // Bare file-scope spelling — works in both the program backend (root =
        // output_emitted.zig) and the command backend (root = backend.zig, where
        // @import("root") would NOT reach this emitted namespace).
        const spec_mod = koru_std.koru_spec;
        // ============================================================================
        // CATALOG TYPES — the declared correspondence vocabulary
        // ============================================================================
        pub const Binding = struct {
            arm: []const u8, // platform arm this binding serves
            mechanism: []const u8, // how the binding materializes ("kconfig", "host-libc", "native-runtime", ...)
            deltas: []const []const u8, // mechanism payload: "CONFIG_X=v" lines for kconfig
            declared_by: []const u8 = "builtin", // provenance: which declaration supplied this bind
        };
        pub const Row = struct {
            module: []const u8, // module qualifier as the parser spells it
            tor_prefix: []const u8, // "" = any tor of the module
            iface: []const u8, // the interface name reported in the tables
            stack: u64, // declared stack demand, bytes
            resources: []const u8, // outside the mechanism: "mechanism: cost"
            evidence: []const u8,
            binds: []const Binding, // which arms can satisfy this row, and how
            declared_by: []const u8 = "builtin", // provenance: which module/program declared it
        };
        pub const BindDecl = struct {
            arm: []const u8 = "",
            mechanism: []const u8 = "",
            deltas: []const []const u8 = &.{},
        };
        pub const RowDecl = struct {
            iface: []const u8 = "", // legacy — refused when present; iface lives in the site arg now
            stack: u64 = 0,
            resources: []const u8 = "",
            evidence: []const u8 = "",
            binds: []const BindDecl = &.{},
        };
        pub const ArmDecl = struct {
            arm: []const u8 = "",
        };
        pub const Used = struct { module: []const u8, tor: []const u8 };
        // ============================================================================
        // MARKS + GRADES — verdicts ride the command marks channel
        // ============================================================================
        //
        // commitCommandMark validates the wire invariants and the backend flushes
        // `<stem>.marks` after dispatch. kind names a decidable relation (admission,
        // declaration, catalog, projection), never a domain noun; the domain rides
        // site/payload as data. The line format never lives here.
        pub fn commitMark(al: std.mem.Allocator, kind: []const u8, site: []const u8, arrow: []const u8, verdict: []const u8, payload: []const u8) bool {
            return eh.commitCommandMark(al, kind, site, arrow, verdict, payload);
        }
        pub fn commitMarkf(
            al: std.mem.Allocator,
            kind: []const u8,
            comptime site_fmt: []const u8, site_args: anytype,
            comptime arrow_fmt: []const u8, arrow_args: anytype,
            verdict: []const u8,
            comptime payload_fmt: []const u8, payload_args: anytype,
        ) void {
            // the channel stores its own formatted line — our temporaries are freeable
            const site = std.fmt.allocPrint(al, site_fmt, site_args) catch return;
            defer al.free(site);
            const arrow = std.fmt.allocPrint(al, arrow_fmt, arrow_args) catch return;
            defer al.free(arrow);
            const payload = std.fmt.allocPrint(al, payload_fmt, payload_args) catch return;
            defer al.free(payload);
            if (!commitMark(al, kind, site, arrow, verdict, payload)) {
                std.debug.print("realize: mark commit refused (kind={s} site={s})\n", .{ kind, site });
            }
        }
        pub fn gradeOf(e: []const u8) u8 {
            if (e.len > 1 and e[1] == ':') return e[0];
            return '-';
        }
        // ============================================================================
        // DECL FIELD — `.key = "value"` extraction from a declared const line
        // ============================================================================
        pub fn declField(line: []const u8, comptime key: []const u8) ?[]const u8 {
            const k = "." ++ key ++ " = \"";
            const i = std.mem.indexOf(u8, line, k) orelse return null;
            const rest = line[i + k.len ..];
            const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
            return rest[0..j];
        }
        // ============================================================================
        // IFACE RESOLUTION — the arg is a name, not a string
        // ============================================================================
        //
        // `iface: koruos/ext2` or `iface: std.io.print` — a bare path/member chain the
        // resolver can know. `'/'` normalizes to '.'; longest-prefix match against the
        // program's module table splits `mod` from `tor` — `std.io.print` →
        // `std.io`+`print`, `koruos.ext2` → module whole. A quoted name stays
        // verbatim — an explicitly conceptual iface (`"koru.runtime"` — the emitted
        // seam, not a module) that opts out of resolution. Unresolvable bare names
        // stay whole: conceptual or not-yet-loaded interfaces are legal to declare.
        fn resolveIface(modules: []const []const u8, raw: []const u8, ra: std.mem.Allocator) []const u8 {
            const t = std.mem.trim(u8, raw, " \t\r\n");
            if (t.len == 0) return "";
            if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) {
                return ra.dupe(u8, t[1 .. t.len - 1]) catch return "";
            }
            const norm = ra.dupe(u8, t) catch return "";
            std.mem.replaceScalar(u8, norm, '/', '.');
            var i: usize = norm.len;
            while (true) {
                for (modules) |m| if (std.mem.eql(u8, m, norm[0..i])) {
                    if (i == norm.len) return norm;
                    return std.fmt.allocPrint(ra, "{s}:{s}", .{ norm[0..i], norm[i + 1 ..] }) catch return "";
                };
                const dot = std.mem.lastIndexOfScalar(u8, norm[0..i], '.') orelse return norm;
                i = dot;
            }
        }
        // ============================================================================
        // MERGE — one declared row into the catalog
        // ============================================================================
        //
        // The declared `iface` names what the row serves ("qual/path[:torprefix]" —
        // '/' normalizes to '.'); `prov` is the declaring site (provenance, not
        // ownership — a program may supply a binding for a lift it does not own).
        // Duplicate (iface, arm) bindings and contradictory row fields are loud
        // refusals, never silent first-wins.
        pub fn mergeDecl(
            rows_l: *std.ArrayListUnmanaged(Row),
            malformed_l: *std.ArrayListUnmanaged(u8),
            al: std.mem.Allocator,
            ra: std.mem.Allocator,
            prov: []const u8,
            iface: []const u8,
            stack_n: u64,
            resources: []const u8,
            evidence: []const u8,
            binds_in: []const Binding,
        ) void {
            var mod = iface;
            var tor: []const u8 = "";
            if (std.mem.indexOfScalar(u8, iface, ':')) |ci| {
                mod = iface[0..ci];
                tor = iface[ci + 1 ..];
            }
            if (std.mem.indexOfScalar(u8, mod, '/') != null) {
                const mb = ra.dupe(u8, mod) catch return;
                std.mem.replaceScalar(u8, mb, '/', '.');
                mod = mb;
            }
            for (binds_in, 0..) |b1, i| {
                for (binds_in[i + 1 ..]) |b2| {
                    if (std.mem.eql(u8, b1.arm, b2.arm)) {
                        malformed_l.writer(al).print("refused: row for {s} in {s} binds arm {s} twice\n", .{ iface, prov, b1.arm }) catch {};
                        commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "duplicate-arm {s} {s}", .{ iface, b1.arm });
                        return;
                    }
                }
            }
            for (rows_l.items) |*r| {
                if (!std.mem.eql(u8, r.iface, iface)) continue;
                for (binds_in) |nb| {
                    for (r.binds) |eb| {
                        if (std.mem.eql(u8, eb.arm, nb.arm)) {
                            malformed_l.writer(al).print("refused: row for {s} declares arm {s} twice ({s} vs earlier {s})\n", .{ iface, nb.arm, prov, r.declared_by }) catch {};
                            commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "duplicate-arm {s} {s} vs {s}", .{ iface, nb.arm, r.declared_by });
                            return;
                        }
                    }
                }
                // row-level fields: unset (0/"") defers to the existing row;
                // set-and-different is a real contradiction — refuse it.
                const contra = (stack_n != 0 and r.stack != 0 and r.stack != stack_n) or
                    (resources.len != 0 and r.resources.len != 0 and !std.mem.eql(u8, r.resources, resources)) or
                    (evidence.len != 0 and r.evidence.len != 0 and !std.mem.eql(u8, r.evidence, evidence));
                if (contra) {
                    malformed_l.writer(al).print("refused: row for {s} in {s} contradicts the earlier declaration by {s}\n", .{ iface, prov, r.declared_by }) catch {};
                    commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "contradiction {s} vs {s}", .{ iface, r.declared_by });
                    return;
                }
                if (r.stack == 0) r.stack = stack_n;
                if (r.resources.len == 0) r.resources = resources;
                if (r.evidence.len == 0) r.evidence = evidence;
                const nb2 = ra.alloc(Binding, r.binds.len + binds_in.len) catch return;
                @memcpy(nb2[0..r.binds.len], r.binds);
                @memcpy(nb2[r.binds.len..], binds_in);
                r.binds = nb2;
                return;
            }
            rows_l.append(al, .{
                .module = mod,
                .tor_prefix = tor,
                .iface = iface,
                .stack = stack_n,
                .resources = resources,
                .evidence = evidence,
                .binds = binds_in,
                .declared_by = prov,
            }) catch return;
        }
        // ============================================================================
        // HARVEST — the std/spec sites, plus the host-line fallback
        // ============================================================================
        //
        // Two declaration shapes, both module-owned:
        //   a) `~std/realize:row { "iface": ..., "stack": n, "binds": [...] }` — typed
        //      JSON in the AST; needs `~import std/realize`.
        //   b) `const realize_row = .{ .iface = "dom/x", .stack = "4096", .arm = "<arm>",
        //      .mechanism = "<mech>", .deltas = "A=v,B=v", .resources = "...",
        //      .evidence = "..." };` in host lines — the fallback for a lift that
        //      cannot import this module.
        // A malformed declaration is a loud refusal, never a silent skip.
        pub fn collectRows(
            program: *const ast.Program,
            rows: *std.ArrayListUnmanaged(Row),
            malformed: *std.ArrayListUnmanaged(u8),
            al: std.mem.Allocator,
            ra: std.mem.Allocator,
        ) void {
            // a) host-line declarations — fallback for a lift that cannot import
            //    std/realize (`const realize_row = .{ ... }`, one binding per line)
            for (program.items) |item| {
                if (item != .module_decl) continue;
                const prov = item.module_decl.logical_name;
                for (item.module_decl.items) |mi| {
                    if (mi != .host_line) continue;
                    const line = std.mem.trim(u8, mi.host_line.content, " \t\r");
                    if (!std.mem.startsWith(u8, line, "const realize_row")) continue;
                    const bad = struct {
                        fn go(ml: *std.ArrayListUnmanaged(u8), al2: std.mem.Allocator, m: []const u8, field: []const u8) void {
                            ml.writer(al2).print("refused: realize_row in module {s} lacks required field .{s}\n", .{ m, field }) catch {};
                            commitMarkf(al2, "declaration", "{s}", .{m}, "decl<-parsed", .{}, "refused", "lacks-field {s}", .{field});
                        }
                    }.go;
                    const iface = declField(line, "iface") orelse {
                        bad(malformed, al, prov, "iface");
                        continue;
                    };
                    const stack_s = declField(line, "stack") orelse {
                        bad(malformed, al, prov, "stack");
                        continue;
                    };
                    const arm_s = declField(line, "arm") orelse {
                        bad(malformed, al, prov, "arm");
                        continue;
                    };
                    const mech = declField(line, "mechanism") orelse {
                        bad(malformed, al, prov, "mechanism");
                        continue;
                    };
                    const stack_n = std.fmt.parseInt(u64, stack_s, 10) catch {
                        bad(malformed, al, prov, "stack");
                        continue;
                    };
                    const dstr = declField(line, "deltas") orelse "";
                    var dl = std.ArrayListUnmanaged([]const u8){};
                    var dit = std.mem.splitScalar(u8, dstr, ',');
                    while (dit.next()) |d| {
                        const t = std.mem.trim(u8, d, " ");
                        if (t.len > 0) dl.append(ra, t) catch return;
                    }
                    const bs = ra.alloc(Binding, 1) catch return;
                    bs[0] = .{ .arm = arm_s, .mechanism = mech, .deltas = dl.items, .declared_by = prov };
                    mergeDecl(rows, malformed, al, ra, prov, iface, stack_n, declField(line, "resources") orelse "", declField(line, "evidence") orelse "", bs);
                }
            }
            // b+c) declared sites — `~std/realize:row(iface: <name>) { ...json... }` in
            //      a lift module or at program level, harvested through std/spec's site
            //      walker. `iface` is the resolvable-name arg; the Source block is the
            //      foreign half (stack, resources, evidence, binds).
            // the module table the iface resolver works against
            var modules = std.ArrayListUnmanaged([]const u8){};
            for (program.items) |item| {
                if (item == .module_decl) modules.append(ra, item.module_decl.logical_name) catch {};
            }
            // site list lives in the row arena — arena teardown owns it; freeing a
            // bare `out.items` slice with `al` would mis-bucket (len != capacity).
            const site_list = spec_mod.sites(program, ra, "std.realize", "row");
            for (site_list) |site| {
                const prov = site.prov;
                const wrapped = std.fmt.allocPrint(ra, "{{{s}}}", .{site.source}) catch return;
                const parsed = std.json.parseFromSlice(RowDecl, ra, wrapped, .{ .ignore_unknown_fields = true }) catch {
                    malformed.writer(al).print("refused: std/realize:row in {s}: malformed JSON block ({s}:{d})\n", .{ prov, site.file, site.line }) catch {};
                    commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "malformed-json {s}:{d}", .{ site.file, site.line });
                    continue;
                };
                const decl = parsed.value;
                const iface_raw = spec_mod.siteArg(site.flow, "iface") orelse {
                    malformed.writer(al).print("refused: std/realize:row in {s} lacks the `iface:` arg — spell ~std/realize:row(iface: <name>)\n", .{prov}) catch {};
                    commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "lacks-iface-arg", .{});
                    continue;
                };
                if (decl.iface.len != 0) {
                    malformed.writer(al).print("refused: std/realize:row in {s} carries \"iface\" in the JSON body — it is the arg now\n", .{prov}) catch {};
                    commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "iface-in-json", .{});
                    continue;
                }
                const iface = resolveIface(modules.items, iface_raw, ra);
                if (iface.len == 0 or decl.binds.len == 0) {
                    malformed.writer(al).print("refused: std/realize:row in {s} lacks required field \"iface\" or \"binds\"\n", .{prov}) catch {};
                    commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "lacks-iface-or-binds", .{});
                    continue;
                }
                const bs = ra.alloc(Binding, decl.binds.len) catch return;
                var ok = true;
                for (decl.binds, 0..) |bd, i| {
                    if (bd.arm.len == 0 or bd.mechanism.len == 0) {
                        malformed.writer(al).print("refused: std/realize:row in {s} binds[{d}] lacks \"arm\" or \"mechanism\"\n", .{ prov, i }) catch {};
                        commitMarkf(al, "declaration", "{s}", .{prov}, "decl<-parsed", .{}, "refused", "binds-{d}-lacks-arm-or-mechanism", .{i});
                        ok = false;
                        break;
                    }
                    bs[i] = .{ .arm = bd.arm, .mechanism = bd.mechanism, .deltas = bd.deltas, .declared_by = prov };
                }
                if (!ok) continue;
                mergeDecl(rows, malformed, al, ra, prov, iface, decl.stack, decl.resources, decl.evidence, bs);
            }
            // stack is a post-merge invariant, not a per-declaration rule: a stackless
            // declaration merging onto a declared row inherits that stack, so merge
            // order (import order) cannot decide legality. A row still stackless after
            // every merge is refused by name and dropped from the catalog.
            var w: usize = 0;
            for (rows.items) |r| {
                if (r.stack == 0) {
                    malformed.writer(al).print("refused: row for {s} in {s} lacks required field \"stack\" (no declaration supplies it)\n", .{ r.iface, r.declared_by }) catch {};
                    commitMarkf(al, "declaration", "{s}", .{r.declared_by}, "decl<-parsed", .{}, "refused", "row-lacks-stack {s}", .{r.iface});
                    continue;
                }
                rows.items[w] = r;
                w += 1;
            }
            rows.items.len = w;
        }
        // The declared arms — the columns of the coverage matrix. A prospective arm
        // needs no bindings to appear; its empty column IS the provider gap. Sites
        // are `~std/realize:arm { "arm": "<name>" }`; order is declaration order,
        // duplicates collapse.
        pub fn collectArms(
            program: *const ast.Program,
            malformed: *std.ArrayListUnmanaged(u8),
            al: std.mem.Allocator,
            ra: std.mem.Allocator,
        ) []const []const u8 {
            var arms = std.ArrayListUnmanaged([]const u8){};
            const site_list = spec_mod.sites(program, ra, "std.realize", "arm");
            for (site_list) |site| {
                const wrapped = std.fmt.allocPrint(ra, "{{{s}}}", .{site.source}) catch return arms.items;
                const parsed = std.json.parseFromSlice(ArmDecl, ra, wrapped, .{ .ignore_unknown_fields = true }) catch {
                    malformed.writer(al).print("refused: std/realize:arm in {s}: malformed JSON block ({s}:{d})\n", .{ site.prov, site.file, site.line }) catch {};
                    commitMarkf(al, "declaration", "{s}", .{site.prov}, "decl<-parsed", .{}, "refused", "malformed-arm-json {s}:{d}", .{ site.file, site.line });
                    continue;
                };
                const name = parsed.value.arm;
                if (name.len == 0) {
                    malformed.writer(al).print("refused: std/realize:arm in {s} lacks required field \"arm\"\n", .{site.prov}) catch {};
                    commitMarkf(al, "declaration", "{s}", .{site.prov}, "decl<-parsed", .{}, "refused", "lacks-arm-field", .{});
                    continue;
                }
                var dup = false;
                for (arms.items) |a| {
                    if (std.mem.eql(u8, a, name)) dup = true;
                }
                if (!dup) arms.append(ra, name) catch return arms.items;
            }
            return arms.items;
        }
        // ============================================================================
        // USED INTERFACES — every interface the program's flows actually invoke
        // ============================================================================
        fn usedAdd(list: *std.ArrayListUnmanaged(Used), al: std.mem.Allocator, mq: []const u8, tor: []const u8) void {
            for (list.items) |u| if (std.mem.eql(u8, u.module, mq) and std.mem.eql(u8, u.tor, tor)) return;
            list.append(al, .{ .module = mq, .tor = tor }) catch {};
        }
        fn usedInv(list: *std.ArrayListUnmanaged(Used), al: std.mem.Allocator, i: anytype) void {
            const mq = i.path.module_qualifier orelse return;
            if (i.path.segments.len == 0) return;
            usedAdd(list, al, mq, i.path.segments[0]);
        }
        fn usedCont(list: *std.ArrayListUnmanaged(Used), al: std.mem.Allocator, c: anytype) void {
            if (c.node) |n| switch (n) {
                .invocation => |i| usedInv(list, al, i),
                .label_with_invocation => |l| usedInv(list, al, l.invocation),
                else => {},
            };
            for (c.continuations) |cc| usedCont(list, al, cc);
        }
        pub fn collectUsed(program: *const ast.Program, used: *std.ArrayListUnmanaged(Used), al: std.mem.Allocator) void {
            for (program.items) |item| {
                if (item != .flow) continue;
                const flow = item.flow;
                usedCont(used, al, flow.body);
            }
        }
        // ============================================================================
        // ADMISSION — used interfaces against the catalog, on the selected arm
        // ============================================================================
        //
        // Toolchain-owned modules the solver never demands providers for: the
        // compiler's own pipeline surface, this module's declaration tors (a `row`
        // site is data, not a demanded interface), and the language runtime module.
        // A domain's own system prefixes (e.g. koruos's `koru.unikraft`) arrive via
        // `extra_skip`. A `std.*` module with no row is pure codegen — waived with a
        // mark, not silently skipped, and not refused.
        pub const engine_skip_prefixes = [_][]const u8{
            "std.realize", "std.spec", "std.compiler", "std.build", "std.deps",
            "std.control", "std.testing", "std.invariants", "koru",
        };
        pub fn admit(
            rows: []const Row,
            used: []const Used,
            arm: []const u8,
            runtime_iface: []const u8,
            extra_skip: []const []const u8,
            al: std.mem.Allocator,
            rw: anytype,
            hit: []bool,
            bound: []usize,
        ) u32 {
            var refusals: u32 = 0;
            // The runtime row is always demanded — find it by interface identity,
            // never by catalog position (declaration order is provenance, not index).
            var rt_idx: ?usize = null;
            for (rows, 0..) |r, ri| {
                if (std.mem.eql(u8, r.iface, runtime_iface)) {
                    rt_idx = ri;
                    break;
                }
            }
            if (rt_idx) |ri| {
                hit[ri] = true;
                var rt_bound = false;
                for (rows[ri].binds, 0..) |b, bi| if (std.mem.eql(u8, b.arm, arm)) {
                    bound[ri] = bi;
                    rt_bound = true;
                };
                if (!rt_bound) {
                    hit[ri] = false;
                    refusals += 1;
                    rw.print("refused: interface={s} arm={s} phase=configure missing=runtime binding for arm\n", .{ runtime_iface, arm }) catch return refusals;
                    commitMarkf(al, "admission", "{s}", .{runtime_iface}, "{s}<-none", .{arm}, "refused", "row={s} declared_by={s} reason=missing-binding", .{ runtime_iface, rows[ri].declared_by });
                } else {
                    const rb = rows[ri].binds[bound[ri]];
                    commitMarkf(al, "admission", "{s}", .{runtime_iface}, "{s}<-{s}", .{ arm, rb.mechanism }, "bound", "row={s} declared_by={s} bind_by={s} grade={c}", .{ runtime_iface, rows[ri].declared_by, rb.declared_by, gradeOf(rows[ri].evidence) });
                }
            } else {
                refusals += 1;
                rw.print("refused: interface={s} arm={s} phase=configure missing=runtime row\n", .{ runtime_iface, arm }) catch return refusals;
                commitMarkf(al, "admission", "{s}", .{runtime_iface}, "{s}<-none", .{arm}, "refused", "reason=missing-runtime-row", .{});
            }
            rw.print("used: {s} (always)\n", .{runtime_iface}) catch return refusals;
            for (used) |u| {
                var sys = false;
                for (engine_skip_prefixes) |p| if (std.mem.eql(u8, u.module, p)) {
                    sys = true;
                };
                for (extra_skip) |p| if (std.mem.eql(u8, u.module, p)) {
                    sys = true;
                };
                if (sys) continue;
                var rowed = false;
                var bound_here = false;
                var m_iface: []const u8 = "";
                var m_prov: []const u8 = "";
                var m_mech: []const u8 = "";
                var m_bindprov: []const u8 = "";
                var m_grade: u8 = '-';
                var served = std.ArrayListUnmanaged(u8){};
                defer served.deinit(al);
                for (rows, 0..) |r, ri| {
                    if (r.module.len == 0) continue;
                    if (!std.mem.eql(u8, r.module, u.module)) continue;
                    if (r.tor_prefix.len != 0 and !std.mem.startsWith(u8, u.tor, r.tor_prefix)) continue;
                    if (!rowed) {
                        m_iface = r.iface;
                        m_prov = r.declared_by;
                        m_grade = gradeOf(r.evidence);
                    }
                    rowed = true;
                    for (r.binds, 0..) |b, bi| {
                        served.writer(al).print("{s}{s}", .{ if (served.items.len == 0) "" else ",", b.arm }) catch {};
                        if (std.mem.eql(u8, b.arm, arm)) {
                            hit[ri] = true;
                            bound[ri] = bi;
                            bound_here = true;
                            m_mech = b.mechanism;
                            m_bindprov = b.declared_by;
                        }
                    }
                }
                if (!bound_here) {
                    if (rowed) {
                        // the interface is known but cannot be served on this arm
                        refusals += 1;
                        rw.print("refused: interface={s}:{s} arm={s} phase=configure missing=binding for arm (row serves: {s})\n", .{ u.module, u.tor, arm, served.items }) catch return refusals;
                        commitMarkf(al, "admission", "{s}:{s}", .{ u.module, u.tor }, "{s}<-none", .{arm}, "refused", "row={s} declared_by={s} reason=missing-binding serves={s}", .{ m_iface, m_prov, served.items });
                    } else if (std.mem.startsWith(u8, u.module, "std.")) {
                        // std modules with no row are pure codegen — no arm mechanism required
                        rw.print("used: {s}:{s} -> no row needed (std, pure)\n", .{ u.module, u.tor }) catch return refusals;
                        commitMarkf(al, "admission", "{s}:{s}", .{ u.module, u.tor }, "{s}<-std-codegen", .{arm}, "waived", "reason=std-pure", .{});
                    } else {
                        refusals += 1;
                        rw.print("refused: interface={s}:{s} arm={s} phase=configure missing=realize row offered=none\n", .{ u.module, u.tor, arm }) catch return refusals;
                        commitMarkf(al, "admission", "{s}:{s}", .{ u.module, u.tor }, "{s}<-none", .{arm}, "refused", "reason=missing-row", .{});
                    }
                    continue;
                }
                rw.print("used: {s}:{s}\n", .{ u.module, u.tor }) catch return refusals;
                commitMarkf(al, "admission", "{s}:{s}", .{ u.module, u.tor }, "{s}<-{s}", .{ arm, m_mech }, "bound", "row={s} declared_by={s} bind_by={s} grade={c}", .{ m_iface, m_prov, m_bindprov, m_grade });
            }
            return refusals;
        }
        // ============================================================================
        // MATRIX — row catalog x declared-arm coverage (+ rows.json + marks)
        // ============================================================================
        pub fn jsonWriteStr(jw: anytype, s: []const u8) void {
            jw.writeByte('"') catch {};
            for (s) |c| switch (c) {
                '"', '\\' => {
                    jw.writeByte('\\') catch {};
                    jw.writeByte(c) catch {};
                },
                else => jw.writeByte(c) catch {},
            };
            jw.writeByte('"') catch {};
        }
        pub fn writeMatrix(
            rows: []const Row,
            arms: []const []const u8,
            al: std.mem.Allocator,
        ) void {
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(al);
            const w = buf.writer(al);
            w.writeAll("# arm-matrix.txt: row catalog x arm coverage (std/realize, DESIGN-0001 #11.1)\n") catch return;
            w.writeAll("# cell = mechanism serving the row on that arm; - = refused at configure\n\n") catch return;
            w.writeAll("row                ") catch return;
            for (arms) |a| w.print("{s:<24}", .{a}) catch return;
            w.writeAll("\n") catch return;
            for (rows) |r| {
                w.print("{s:<19}", .{r.iface}) catch return;
                for (arms) |a| {
                    var cell: []const u8 = "-";
                    for (r.binds) |b| if (std.mem.eql(u8, b.arm, a)) {
                        cell = b.mechanism;
                    };
                    w.print("{s:<24}", .{cell}) catch return;
                }
                w.writeAll("\n") catch return;
            }
            w.writeAll("\nproviders bound per arm:\n") catch return;
            for (arms) |a| {
                var n: u32 = 0;
                for (rows) |r| for (r.binds) |b| {
                    if (std.mem.eql(u8, b.arm, a)) n += 1;
                };
                w.print("  {s}: {d}/{d}\n", .{ a, n, rows.len }) catch return;
            }
            const f = std.fs.cwd().createFile("arm-matrix.txt", .{}) catch return;
            defer f.close();
            f.writeAll(buf.items) catch return;
            // rows.json: the resolved catalog as data — an independent consumer
            // (check-realize.sh recount) can re-decide the matrix instead of
            // trusting the printed projection.
            var jbuf = std.ArrayListUnmanaged(u8){};
            defer jbuf.deinit(al);
            const jw = jbuf.writer(al);
            jw.writeAll("{\n  \"arms\": [") catch {};
            for (arms, 0..) |a, i| {
                if (i != 0) jw.writeAll(", ") catch {};
                jsonWriteStr(jw, a);
            }
            jw.writeAll("],\n  \"rows\": [\n") catch {};
            for (rows, 0..) |r, ri| {
                jw.writeAll("    { \"iface\": ") catch {};
                jsonWriteStr(jw, r.iface);
                jw.writeAll(", \"module\": ") catch {};
                jsonWriteStr(jw, r.module);
                jw.writeAll(", \"tor_prefix\": ") catch {};
                jsonWriteStr(jw, r.tor_prefix);
                jw.writeAll(", \"declared_by\": ") catch {};
                jsonWriteStr(jw, r.declared_by);
                jw.print(", \"stack\": {d}, \"resources\": ", .{r.stack}) catch {};
                jsonWriteStr(jw, r.resources);
                jw.writeAll(", \"evidence\": ") catch {};
                jsonWriteStr(jw, r.evidence);
                jw.writeAll(", \"binds\": [") catch {};
                for (r.binds, 0..) |b, bi| {
                    if (bi != 0) jw.writeAll(", ") catch {};
                    jw.writeAll("{ \"arm\": ") catch {};
                    jsonWriteStr(jw, b.arm);
                    jw.writeAll(", \"mechanism\": ") catch {};
                    jsonWriteStr(jw, b.mechanism);
                    jw.writeAll(", \"deltas\": [") catch {};
                    for (b.deltas, 0..) |d, di| {
                        if (di != 0) jw.writeAll(", ") catch {};
                        jsonWriteStr(jw, d);
                    }
                    jw.writeAll("] }") catch {};
                }
                jw.writeAll("] }") catch {};
                jw.writeAll(if (ri + 1 < rows.len) ",\n" else "\n") catch {};
            }
            jw.writeAll("  ]\n}\n") catch {};
            const jf = std.fs.cwd().createFile("rows.json", .{}) catch return;
            defer jf.close();
            jf.writeAll(jbuf.items) catch return;
            // The same catalog committed as marks: `catalog` marks are the
            // data, `projection` marks the derived claim — a checker
            // recounts binds per arm over the committed rows instead of
            // trusting the printed matrix ("koru-native: 2/8" becomes a
            // re-decidable cell, not prose).
            for (rows) |r| {
                var csv = std.ArrayListUnmanaged(u8){};
                defer csv.deinit(al);
                for (r.binds, 0..) |b, bi| {
                    if (bi != 0) csv.append(al, ',') catch {};
                    csv.appendSlice(al, b.arm) catch {};
                }
                commitMarkf(al, "catalog", "{s}", .{r.iface}, "row<-declared", .{}, "listed", "declared_by={s} binds={s}", .{ r.declared_by, if (csv.items.len == 0) "none" else csv.items });
            }
            for (arms) |a| {
                var n: usize = 0;
                for (rows) |r| {
                    for (r.binds) |b| {
                        if (std.mem.eql(u8, b.arm, a)) {
                            n += 1;
                            break;
                        }
                    }
                }
                commitMarkf(al, "projection", "{s}", .{a}, "matrix<-catalog", .{}, "holds", "bound={d} total={d}", .{ n, rows.len });
            }
            std.debug.print("realize: arm-matrix.txt + rows.json written ({d} rows x {d} arms)\n", .{ rows.len, arms.len });
        }
        // ============================================================================
        // MANIFEST — the generic arm artifact: bound rows, mechanism, deltas
        // ============================================================================
        pub fn armSlug(arm: []const u8, al: std.mem.Allocator) []const u8 {
            var slug = std.ArrayListUnmanaged(u8){};
            for (arm) |ch| slug.append(al, if (ch == '/' or ch == '\\' or ch == ':') '-' else ch) catch return arm;
            return slug.items;
        }
        pub fn writeManifest(
            slug: []const u8,
            arm: []const u8,
            app_name: []const u8,
            rows: []const Row,
            hit: []const bool,
            bound: []const usize,
            al: std.mem.Allocator,
        ) void {
            const mfname = std.fmt.allocPrint(al, "manifest-{s}.txt", .{slug}) catch return;
            defer al.free(mfname);
            // stale Unikraft projections from an earlier run must not survive an arm switch
            std.fs.cwd().deleteFile("Kraftfile") catch {};
            std.fs.cwd().deleteFile("Makefile.uk") catch {};
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(al);
            const w = buf.writer(al);
            w.print("# manifest-{s}: generated by `koruc <file> realize gen --arm {s}` (std/realize)\n", .{ slug, arm }) catch return;
            w.print("arm: {s}\nname: {s}\n\n", .{ arm, app_name }) catch return;
            for (rows, 0..) |r, ri| {
                if (!hit[ri]) continue;
                const b = r.binds[bound[ri]];
                w.print("bind: {s} -> {s}", .{ r.iface, b.mechanism }) catch return;
                for (b.deltas, 0..) |d, i| w.print("{s}{s}", .{ if (i == 0) " deltas=" else ",", d }) catch return;
                w.writeAll("\n") catch return;
            }
            const f = std.fs.cwd().createFile(mfname, .{}) catch return;
            defer f.close();
            f.writeAll(buf.items) catch return;
            var nbound: u32 = 0;
            for (hit) |h| {
                if (h) nbound += 1;
            }
            std.debug.print("realize: {s} and realize.txt written for arm {s} ({d} bound)\n", .{ mfname, arm, nbound });
        }
        pub const row_event = struct {
            pub const Input = struct {
                iface: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const arm_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
    };
    pub const koru_build = struct {
        // Build Requirements Standard Library
        // Allows modules to declare their build dependencies
        //
        // TOP-LEVEL COMPTIME EXECUTION:
        // This module uses top-level comptime calls for automatic collection.
        // When imported, the top-level collect() executes automatically.
        const emit_build_zig = @import("emit_build_zig");
        const std = @import("std");
        const Root = @import("root");
        const ast_functional = @import("ast_functional");
        const emitter_helpers = @import("emitter_helpers");
        const annotation_parser = @import("annotation_parser");
        // Re-export variant registry functions from the core
        // This allows userland code to query variants via std.build.getVariant()
        pub const getVariant = emitter_helpers.getVariant;
        pub const registerVariant = emitter_helpers.registerVariant;
        // Import shared compiler types (to avoid circular dependency with compiler.kz)
        // ============================================================================
        // FLAG MATCHING - Annotation-based conditional compilation
        // ============================================================================
        // Use [build("prod")] or [build("dev", "staging")] to conditionally include
        // declarations based on the --build=X compiler flag.
        //
        // Usage in source code:
        //   [build("prod")]koru/docker:image(tag: "myapp:latest") {
        //       FROM alpine:3.18
        //       COPY zig-out/bin/main /usr/local/bin/myapp
        //       CMD ["myapp"]
        //   }
        //
        //   [build("dev")]koru/docker:image(tag: "myapp:latest") {
        //       FROM alpine:3.18
        //       RUN apk add --no-cache gdb strace
        //       COPY zig-out/bin/main /usr/local/bin/myapp
        //       CMD ["myapp", "--debug"]
        //   }
        //
        // Then: koruc main.kz --build=prod docker build
        //
        // Usage in a command proc:
        //   for (program.items) |item| {
        //       if (item == .flow) {
        //           const flow = item.flow;
        //           if (!matchesFlags(flow.inv().annotations)) continue;
        //           // ... process the flow
        //       }
        //   }
        //
        // Semantics:
        //   - No build(...) annotation → always matches
        //   - Has build("x", "y", ...) → matches if --build=x OR --build=y
        //
        pub fn matchesFlags(annotations: []const []const u8) bool {
            // Look for build(...) parametrized annotation
            for (annotations) |ann| {
                // Try to parse as a parametrized call
                const maybe_call = annotation_parser.parseCall(std.heap.page_allocator, ann) catch continue;
                if (maybe_call) |call| {
                    defer {
                        var mutable_call = call;
                        mutable_call.deinit(std.heap.page_allocator);
                    }
                    // Check if this is a build() annotation
                    if (std.mem.eql(u8, call.name, "build")) {
                        // Check if any of the args match current --build=X flag
                        for (call.args) |arg| {
                            // Build the flag string: "build=prod", "build=dev", etc.
                            var flag_buf: [64]u8 = undefined;
                            const flag = std.fmt.bufPrint(&flag_buf, "build={s}", .{arg}) catch continue;
                            if (Root.CompilerEnv.hasFlagRuntime(flag)) {
                                return true;  // Found a matching build flag
                            }
                        }
                        // Has build() annotation but none of the args matched
                        return false;
                    }
                }
            }
            // No build() annotation found → always matches
            return true;
        }
        // Declare build dependency using implicit Source block
        // Usage: std/build:requires { exe.linkSystemLibrary("sqlite3"); }
        // [norun] annotation prevents auto-execution - collect() reads from AST instead
        // ============================================================================
        // VARIANT SELECTION - Conditional proc selection based on build flags
        // ============================================================================
        // Allows selecting different proc variants based on --build flag.
        // Usage:
        //   [build("release")]std/build:variants {
        //       "compute": "fast",
        //       "blur": "gpu"
        //   }
        //   [build("debug")]std/build:variants {
        //       "compute": "naive",
        //       "blur": "cpu"
        //   }
        //
        // When compiled with --build=release, the emitter will use "fast" for compute.
        // When compiled with --build=debug, the emitter will use "naive" for compute.
        //
        // The Source block contains JSON-like mappings: event_name → variant_name
        // The program AST is used to validate that referenced tors exist
        // ============================================================================
        // BUILD CONFIG - Key-value build parameters based on build flags
        // ============================================================================
        // Sets build-time configuration values (e.g., cross-compilation target).
        // Composes with build:variants — variants select WHICH code, config sets
        // HOW to build it. Both use the same [build(X)] guard system.
        //
        // Usage:
        //   [build("linux")]std/build:config {
        //       "target": "x86_64-linux-musl"
        //   }
        //
        // The compiler is agnostic to the keys — it just passes them through.
        // Currently the backend recognizes "target" for zig cross-compilation.
        // ============================================================================
        // BUILD COMMANDS - Shell Script Execution (Frontend Optimization)
        // ============================================================================
        // FRONTEND OPTIMIZATION: Unlike most compiler features, build:command.sh
        // is processed in the frontend (koruc) rather than the backend compiler.
        // This allows instant execution without backend compilation overhead.
        //
        // For commands that need Zig/Koru compilation, use build:command.proc or
        // build:command.flow (backend passes, slower but more powerful).
        //
        // Usage:
        //   std/build:command.sh(name: "test", description: "Run all tests") {
        //     ./run_regression.sh
        //   }
        //
        // Invoke: koruc main.kz test --all --verbose
        // Executes: ./run_regression.sh --all --verbose
        //
        // The shell command receives all remaining argv as arguments.
        // Use `koruc main.kz help` to list all available commands.
        // ============================================================================
        // BUILD COMMANDS - Zig Functions (Frontend Compilation + Execution)
        // ============================================================================
        // FRONTEND EXECUTION: Powerful commands with full compiler access!
        // Unlike command.sh, command.zig functions have access to the AST and allocator,
        // enabling sophisticated build orchestration and metaprogramming.
        //
        // Function Signature:
        //   pub fn execute(
        //       allocator: std.mem.Allocator,
        //       argv: [][]const u8,
        //       ast: *const Program
        //   ) !void
        //
        // Usage:
        //   std/build:command.zig(name: "build") {
        //     const std = @import("std");
        //     const ast = @import("ast");
        //
        //     pub fn execute(allocator: std.mem.Allocator, argv: [][]const u8, program: *const ast.Program) !void {
        //       // Parse argv for command arguments
        //       // Collect build:step invocations from AST
        //       // Orchestrate build step execution with dependency resolution
        //     }
        //   }
        //
        // Invoke: koruc main.kz build test --verbose
        //   - Command name: "build"
        //   - argv: ["test", "--verbose"]
        //   - AST: Full program AST for inspection/manipulation
        //
        // Available in scope:
        //   - std.mem.Allocator for memory management
        //   - Full AST access for metaprogramming
        //   - Can import compiler utilities (build_step_utils, etc.)
        //
        // Examples:
        //   koruc main.kz build           # Run all build steps
        //   koruc main.kz build test      # Run 'test' step + dependencies
        //   koruc main.kz clean           # Custom cleanup command
        //   koruc main.kz deploy prod     # Deployment orchestration
        // ============================================================================
        // BUILD COMMANDS - Native Koru Flows (Zero Context Switch)
        // ============================================================================
        // FRONTEND EXECUTION: Write build commands in pure Koru!
        // The command body IS a flow continuation - no Source block, no Zig, just Koru.
        //
        // Usage:
        //   std/build:command(name: "greet", description: "Say hello")
        //   | execute ctx |>
        //       if(ctx.argv.len > 1)
        //       | then |> std/io:println("Hello, " ++ ctx.argv[1] ++ "!")
        //       | else |> std/io:println("Usage: greet <name>")
        //
        // Invoke: koruc main.kz greet World
        //   Output: Hello, World!
        //
        // The execute branch receives:
        //   - ctx.argv: [][]const u8 - command line arguments after command name
        //   - ctx.program: *const Program - full AST access (optional)
        //
        // Unlike command.sh (shell) or command.zig (raw Zig), command uses normal
        // Koru flow syntax. Same patterns as everything else - tors, branches, if.
        //
        // Examples:
        //   std/build:command(name: "check", description: "Run all checks")
        //   | execute ctx |>
        //       std/build:run_step("lint")
        //       | done |> std/build:run_step("test")
        //           | done |> std/io:println("All checks passed!")
        //           | failed e |> std/io:println("Tests failed: " ++ e)
        //       | failed e |> std/io:println("Lint failed: " ++ e)
        // ============================================================================
        // BUILD STEPS - Declarative Build Pipeline with Dependencies
        // ============================================================================
        // FRONTEND EXECUTION: Build steps are collected and executed in dependency order
        // during the compilation process. Steps declare dependencies using annotations.
        //
        // Usage:
        //   std/build:step(name: "compile") {
        //     zig build-exe main.zig
        //   }
        //
        //   [depends_on(compile)]std/build:step(name: "test") {
        //     ./main --test
        //   }
        //
        //   [depends_on(compile, test)]std/build:step(name: "package") {
        //     tar czf app.tar.gz main
        //   }
        //
        // Execution:
        // - Steps are collected from AST with their annotations
        // - Dependencies are extracted from [depends_on(...)] annotations
        // - Dependency graph is built and topologically sorted
        // - Steps execute in correct order (circular dependencies are detected and error)
        //
        // Annotations:
        // - [depends_on(step1, step2, ...)] - Variadic dependency list
        // - Future: [parallel], [optional], [timeout(30)], etc.
        // ============================================================================
        // DEFAULT BUILD STEPS - Standard 2-Phase Metaprogramming Compilation
        // ============================================================================
        // These steps implement Koru's standard compilation pipeline:
        //   1. Compile backend metaprogram (main.zig → backend executable)
        //   2. Run backend (applies optimizations, generates final code)
        //   3. Run the final program
        //
        // Users can override any step by defining their own with the same name
        // (without the [default] annotation). The override resolution in main.zig
        // will automatically use user-defined steps over these defaults.
        // Phase 1: Compile backend metaprogram using build_backend.zig
        // Phase 2: Run backend to generate & compile final program.
        //
        // TWO defects lived in these six lines, independently, and both were latent
        // because the declarative step pipeline only engages once a program declares a
        // step of its own — and the one test that covers the chain (310_033) overrides
        // compile_backend, build AND run with echoes, so it proves ordering while
        // executing none of these scripts.
        //
        // 1. The separator was `,`. Annotations separate on `|` (`[comptime|transform]`,
        //    `[abstract|retain]`). `[default, depends_on(compile_backend)]` parsed as
        //    something that is not two annotations, and the depends_on was DROPPED
        //    SILENTLY — no diagnostic, just a dependency that never fires. The comma
        //    inside `depends_on(a, b)` is a different thing: that is one annotation's
        //    argument list, and it is correct.
        // 2. The binary is `backend`, not `main` — phase 1 emits `zig-out/bin/backend`.
        //
        // Together they meant anyone attaching `[depends_on(build)]` to the real default
        // got `sh: ./zig-out/bin/main: No such file or directory` / `BuildStepFailed`,
        // and fixing only the name moved it to `./zig-out/bin/backend: No such file`,
        // because compile_backend still never ran.
        // Phase 3: Run the final program
        // ============================================================================
        // BUILD COLLECTION - Generate build.zig from build:requires declarations
        // ============================================================================
        // BACKEND PASS: Collects all build:requires from the user's final program AST
        // and generates build.zig for compiling the final executable.
        //
        // This is distinct from compiler:requires (which configures backend compilation).
        // build:requires configures the FINAL PROGRAM compilation.
        //
        // Usage (invoked by compiler.kz during backend coordination):
        //   std/build:collect(ctx: ctx, output-path: "build.zig")
        //   | collected { ctx: CompilerContext }
        //
        // The pass:
        // - Walks ctx.ast for all build:requires invocations
        // - Collects the Source parameters (Zig build code)
        // - Generates build.zig using emit_build_zig library
        // - Returns updated ctx with passes_completed incremented
        pub const requires_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = union(enum(u8)) {
                added: struct {
                },
                parse_error: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: requires  [/Users/larsde/src/koru-cypoe/koru_std/build.kz:102]
                const source = __koru_event_input.source;
                _ = &source;
                _ = &__koru_event_input;

                    // Validate Source syntax
                    // Can be called programmatically by collect() to validate each requirement
                    // TODO: Actually validate Zig syntax
                    return .{ .added = .{} };

            }
        };
        pub const variants_event = struct {
            pub const Input = struct {
                meta: __koru_ast.InvocationMeta,
                source: __koru_ast.Source,
                program: *const __koru_ast.Program,
            };
            pub const Output = union(enum(u8)) {
                configured: usize,
                skipped: []const u8,
                invalid_event: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: variants  [/Users/larsde/src/koru-cypoe/koru_std/build.kz:134]
                const meta = __koru_event_input.meta;
                const source = __koru_event_input.source;
                const program = __koru_event_input.program;
                _ = &meta;
                _ = &source;
                _ = &program;
                _ = &__koru_event_input;

                    // Check if this config's annotation matches the --build flag
                    if (!matchesFlags(meta.annotations)) {
                        return .{ .skipped = "no matching build flag" };
                    }

                    // Parse the source as simple JSON-like key:value pairs
                    // Format: "event_name": "variant_name"
                    var count: usize = 0;
                    var pos: usize = 0;
                    const text = source.text;

                    while (pos < text.len) {
                        // Skip whitespace and braces
                        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\n' or text[pos] == '\r' or text[pos] == '\t' or text[pos] == '{' or text[pos] == '}' or text[pos] == ',')) {
                            pos += 1;
                        }
                        if (pos >= text.len) break;

                        // Expect opening quote for key
                        if (text[pos] != '"') {
                            pos += 1;
                            continue;
                        }
                        pos += 1;

                        // Read key
                        const key_start = pos;
                        while (pos < text.len and text[pos] != '"') {
                            pos += 1;
                        }
                        const key = text[key_start..pos];
                        pos += 1; // skip closing quote

                        // Skip colon and whitespace
                        while (pos < text.len and (text[pos] == ':' or text[pos] == ' ')) {
                            pos += 1;
                        }

                        // Expect opening quote for value
                        if (pos >= text.len or text[pos] != '"') continue;
                        pos += 1;

                        // Read value
                        const value_start = pos;
                        while (pos < text.len and text[pos] != '"') {
                            pos += 1;
                        }
                        const value = text[value_start..pos];
                        pos += 1; // skip closing quote

                        // Validate that the tor exists in the AST and grab its decl
                        const event = ast_functional.findEventByCanonicalName(program, key) orelse {
                            return .{ .invalid_event = key };
                        };

                        // Register under the tor's canonical name (e.g. "blinky:main"),
                        // not the raw user-supplied key (e.g. "main"). visitor_emitter looks
                        // up the canonical form at emission time, so the registry must match.
                        // page_allocator: this is comptime, the slice lives until process exit.
                        const canonical = emitter_helpers.buildCanonicalEventName(&event.path, std.heap.page_allocator, null) catch continue;

                        if (emitter_helpers.registerVariant(canonical, value)) {
                            count += 1;
                        }
                    }

                    return .{ .configured = count };

            }
        };
        pub const config_event = struct {
            pub const Input = struct {
                meta: __koru_ast.InvocationMeta,
                source: __koru_ast.Source,
            };
            pub const Output = union(enum(u8)) {
                configured: usize,
                skipped: []const u8,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: config  [/Users/larsde/src/koru-cypoe/koru_std/build.kz:223]
                const meta = __koru_event_input.meta;
                const source = __koru_event_input.source;
                _ = &meta;
                _ = &source;
                _ = &__koru_event_input;

                    if (!matchesFlags(meta.annotations)) {
                        return .{ .skipped = "no matching build flag" };
                    }

                    // Parse the source as simple JSON-like key:value pairs
                    var count: usize = 0;
                    var pos: usize = 0;
                    const text = source.text;

                    while (pos < text.len) {
                        // Skip whitespace and braces
                        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\n' or text[pos] == '\r' or text[pos] == '\t' or text[pos] == '{' or text[pos] == '}' or text[pos] == ',')) {
                            pos += 1;
                        }
                        if (pos >= text.len) break;

                        // Expect opening quote for key
                        if (text[pos] != '"') {
                            pos += 1;
                            continue;
                        }
                        pos += 1;

                        // Read key
                        const key_start = pos;
                        while (pos < text.len and text[pos] != '"') {
                            pos += 1;
                        }
                        const key = text[key_start..pos];
                        pos += 1; // skip closing quote

                        // Skip colon and whitespace
                        while (pos < text.len and (text[pos] == ':' or text[pos] == ' ')) {
                            pos += 1;
                        }

                        // Expect opening quote for value
                        if (pos >= text.len or text[pos] != '"') continue;
                        pos += 1;

                        // Read value
                        const value_start = pos;
                        while (pos < text.len and text[pos] != '"') {
                            pos += 1;
                        }
                        const value = text[value_start..pos];
                        pos += 1; // skip closing quote

                        // Register in the build config registry
                        if (emitter_helpers.registerBuildConfig(key, value)) {
                            count += 1;
                        }
                    }

                    return .{ .configured = count };

            }
        };
        pub const command_sh_event = struct {
            pub const Input = struct {
                name: []const u8,
                description: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const command_zig_event = struct {
            pub const Input = struct {
                name: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const command_event = struct {
            pub const Input = struct {
                name: []const u8,
                description: []const u8,
            };
            pub const Output = []const []const u8;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                @panic("koru: reached `command`, which nothing implements — this program was built with the box still empty");
            }
        };
        pub const step_event = struct {
            pub const Input = struct {
                name: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
        pub const collect_event = struct {
            pub const Input = struct {
                ctx: koru_compiler_types.CompilerContext,
                output_path: []const u8,
            };
            pub const Output = koru_compiler_types.CompilerContext;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: collect  [/Users/larsde/src/koru-cypoe/koru_std/build.kz:483]
                const ctx = __koru_event_input.ctx;
                const output_path = __koru_event_input.output_path;
                _ = &ctx;
                _ = &output_path;
                _ = &__koru_event_input;

                    // Extract nested fields from ctx (auto-destructuring only works for top-level tor params)
                    const allocator = ctx.allocator;
                    const ast_items = ctx.ast.items;

                    // Collect all build:requires from AST
                    var requirements = std.ArrayList(emit_build_zig.BuildRequirement){
                        .items = &.{},
                        .capacity = 0,
                    };
                    errdefer requirements.deinit(allocator);

                    // Walk AST looking for std.build:requires flows
                    for (ast_items) |item| {
                        switch (item) {
                            .flow => |flow| {
                                // Check if this is std.build:requires
                                if (flow.inv().path.module_qualifier) |mq| {
                                    const is_build_requires = (std.mem.eql(u8, mq, "std.build") and
                                        flow.inv().path.segments.len == 1 and
                                        std.mem.eql(u8, flow.inv().path.segments[0], "requires"));

                                    if (is_build_requires) {
                                        // Respect build flags: [build("prod")], [build("dev")], etc.
                                        if (!matchesFlags(flow.inv().annotations)) continue;
                                        // Extract source parameter
                                        for (flow.inv().args) |arg| {
                                            if (std.mem.eql(u8, arg.name, "source")) {
                                                // Deduplicate by checking if this source already exists
                                                var found = false;
                                                for (requirements.items) |req| {
                                                    if (std.mem.eql(u8, req.source_code, arg.value)) {
                                                        found = true;
                                                        break;
                                                    }
                                                }
                                                if (!found) {
                                                    const requirement = emit_build_zig.BuildRequirement{
                                                        .module_name = "main", // All user code is in "main" module
                                                        .source_code = arg.value,
                                                    };
                                                    try requirements.append(allocator, requirement);
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            .module_decl => |module| {
                                // Also check imported modules
                                for (module.items) |mod_item| {
                                    if (mod_item == .flow) {
                                        const flow = mod_item.flow;
                                        if (flow.inv().path.module_qualifier) |mq| {
                                            const is_build_requires = (std.mem.eql(u8, mq, "std.build") and
                                                flow.inv().path.segments.len == 1 and
                                                std.mem.eql(u8, flow.inv().path.segments[0], "requires"));

                                            if (is_build_requires) {
                                                // Respect build flags: [build("prod")], [build("dev")], etc.
                                                if (!matchesFlags(flow.inv().annotations)) continue;
                                                for (flow.inv().args) |arg| {
                                                    if (std.mem.eql(u8, arg.name, "source")) {
                                                        // Deduplicate by checking if this source already exists
                                                        var found = false;
                                                        for (requirements.items) |req| {
                                                            if (std.mem.eql(u8, req.source_code, arg.value)) {
                                                                found = true;
                                                                break;
                                                            }
                                                        }
                                                        if (!found) {
                                                            const requirement = emit_build_zig.BuildRequirement{
                                                                .module_name = module.logical_name,
                                                                .source_code = arg.value,
                                                            };
                                                            try requirements.append(allocator, requirement);
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }

                    // If we found requirements, generate build.zig
                    if (requirements.items.len > 0) {
                        std.debug.print("📦 Found {d} build requirement(s)\n", .{requirements.items.len});
                        try emit_build_zig.emitBuildZig(allocator, requirements.items, output_path);
                        std.debug.print("✓ Generated {s}\n", .{output_path});
                    }

                    requirements.deinit(allocator);

                    // Update context
                    var updated_ctx = ctx;
                    updated_ctx.passes_completed += 1;

                    return updated_ctx;

            }
        };
    };
    pub const koru_control = struct {
        // Koru Standard Library: Control Flow
        // Provides if for zero-overhead conditional branching
        //
        // ARCHITECTURE: if is a pure comptime transform that generates inline Zig code.
        // - if(expr) | then |> ... | else |> ... becomes a literal if/else statement
        // - No function call overhead, full access to outer scope
        // - Uses template_utils.lookupTemplate + interpolate for metaprogramming!
        const std = @import("std");
        // IF - Conditional as a template over the continuation-return mechanism.
        //
        // Syntax: if(cond)
        //         | then |> ...      // REQUIRED: an `if` with no true arm is an omission, not a shape
        //         | else |> ...      // optional: `if(c) | then |> f()` is a complete statement
        //
        // ARCHITECTURE:
        // - `if` is a `[template]` proc, NOT a dedicated AST node (no ConditionalNode).
        //   The body is a literal Zig if/else. `then` / `else` are TERMINAL
        //   continuations, CONTINUED by the template via `{{ continuations["X"].continue }}`
        //   — the same producer→consumer dispatch every branched tor uses. Where
        //   `for` CALLS effects during the loop, `if` CONTINUES to one of its terminals in
        //   the matching arm. Same machine; `if`'s "during" half is just empty.
        // - Zero-overhead: the consumer's `then` / `else` body is spliced into the
        //   matching arm in the enclosing scope. An omitted optional branch mints no
        //   marker, so its arm renders empty.
        // The |js and |cs host variants of if/cond/for live in control.targets.kz —
        // the part holds every non-zig template body because their surfaces converge.
        // ============================================================================
        // COND - Flat multi-way dispatch (ZERO OVERHEAD)
        // ============================================================================
        //
        // Syntax: cond(scrutinee)
        //         | c b when <guard> -> <value>   // N guarded arms, first match wins
        //         | c _ -> <default>              // guardless final arm (the else)
        //
        // ARCHITECTURE:
        // - `cond` is a `[template]` proc, like `if`. `| c *` is a single VARIADIC
        //   terminal branch — the wildcard `*` legalizes the lone declaration (parser
        //   single-branch exemption) and marks it as filled by N guarded arms at the
        //   use site. The template renders continuations["c"] as ONE `if / else if /
        //   else` cascade: each guarded arm's `when` becomes a condition (`arm.guard`)
        //   and its body the matching block (`arm.continue[unguarded]`), with the
        //   guardless `| c _` arm as the trailing `else`. Same continuation-return
        //   machine as if; if's two fixed arms become N guard-selected ones.
        // - DISPATCH IS EXCLUSIVE — the arm whose guard matches runs, and no other. The
        //   cascade is what makes that structural: `else if` cannot re-test a guard
        //   against state an earlier arm just wrote. Pinned by 320_138, whose two arms
        //   toggle one store field back and forth.
        // - `{{ binds }}` emits every arm's binder ONCE, ahead of the cascade, because
        //   a guard in condition position must already see the name its arm binds.
        //   Per-arm binding is what a cascade cannot express, and reaching for N
        //   independent blocks to get it is what made dispatch fall through.
        // - KORU050/051 require the guardless arm to exist and KORU053 requires it last,
        //   so the cascade always closes with a real `else` and never re-orders an arm.
        // ============================================================================
        // FOR - Iteration as a template over the effect-branch engine (ZERO OVERHEAD)
        // ============================================================================
        //
        // Syntax: for(iterable_expr)
        //         ! each item |> process(value: item)
        //         | done |> finalize()        // optional: runs once after the loop
        //
        // ARCHITECTURE:
        // - `for` is a `[template]` proc, NOT a dedicated AST node. The body is a
        //   literal Zig `for`; each `! each` effect handler is called inside it
        //   (guarded by its `when`, if any). The optional `| done` terminal is RETURNED
        //   via `{{ continuations["done"].continue }}` — the producer→consumer dispatch,
        //   not an emitter append. Effects are called during; continuations returned.
        // - The `! each` handlers lower to a synthesized Handlers struct + in-scope
        //   alias (emitter inline-body bridge); the template references each by link
        //   and emits a guarded call. No ForeachNode. Mirrors `if` above (pure
        //   continuation-return); `for` and `if` are one mechanism.
        // - Zero-overhead: comptime-known handlers inline into the loop.
        // - `keep:` is OPTIONAL and turns the loop into one that STOPS: the emitted body
        //   breaks the moment the expression goes false. Omit it and `for` is exactly
        //   what it always was — an absent `keep` renders no line at all, so every
        //   existing call site emits byte-identical code.
        //
        //   This started life as a separate `scan` keyword and that was WRONG. The two
        //   templates differed by ONE line and shared everything else, across two targets
        //   — four procs where two do. That is the two-lowerings-of-one-construct shape
        //   this repo keeps getting bitten by (`frag-a-fix-lands-in-one-lowering-path`),
        //   installed deliberately by someone who had written that concept's newest
        //   section the same morning. A second copy that merely agrees today is the same
        //   bug waiting: the next person to improve the JS range handling would have had
        //   to remember there were two homes for it. Lars caught it; converging is the
        //   concept's own prescription.
        // CONST moved to koru_std/declarations.kz — it is a value declaration, not
        // control flow (and not a type). See `declarations.kz` for the tor + the
        // per-target template procs.
        // Koru Standard Library: the `targets` part of control.kz.
        // Joined via `~part targets` in control.kz; merged into the control module at load.
        //
        // The NON-zig template bodies of control.kz's three keywords — the |js and
        // |cs variants of if, cond, for. They share one home because their surfaces
        // converge: if/cond bodies are byte-identical across hosts (the js comment
        // below already argued "shared, not re-derived"), and a fix that lands in
        // one lowering path has to land in all of them — one file is where a sweep
        // actually sees that. The tor decls and the |zig originals stay in
        // control.kz.
        // JS variant of if. The per-call render is target-blind to the EMITTER (the
        // body is spliced inline before variant selection), so the RENDERER selects
        // THIS variant when --lang=js. The body is byte-identical to the Zig one — JS
        // `if/else` shares the same surface — but it is now HONESTLY the JS variant,
        // not a Zig-body leak that happened to also be valid JS. The
        // `__koru_continue_N` markers it mints are resolved by js_emitter's
        // emitInlineBodyResolvingContinuations.
        // CS variant of if — the K# vertical. C# `if/else` shares the surface with
        // both other hosts, so the body is again byte-identical; what makes it the cs
        // variant is that selectPerCallTemplateProc picks it under --lang=cs and
        // cs_emitter resolves the `__koru_continue_N` markers.
        // JS variant of cond. The CASCADE is byte-identical to the Zig one and that is
        // the point: `if (g) { … } else if (g2) { … } else { … }` is one construct in
        // both languages, so every structural decision `cond` makes — first-match
        // exclusivity, the guardless arm as the trailing `else`, `{{ binds }}` hoisted
        // ahead so a guard in condition position sees the name its arm binds — is
        // shared, not re-derived. `arm.continue[unguarded]` mints the same
        // `__koru_continue_bare_N` marker the Zig path uses; js_emitter resolves it via
        // emitInlineBodyResolvingContinuations (mirroring the Zig
        // emitInlineCodeResolvingSplices), exactly as `~[template]proc if|js` does.
        //
        // The ONE divergence is `{{ binds }}`, and it is not in this file: the binder
        // preamble is host DECLARATION syntax (`const v = <scrutinee>;`), so
        // template_processor renders that single context key in the build language
        // (BinderHost). Zig gets `.{ .value = n, }` plus `_ = &v;` unused-suppression
        // and `: T` representation annotations; JS gets `{ value: n, }` and neither —
        // an unused const is legal there and `_ = &v;` does not parse. Keeping it one
        // key means a future improvement to which arms bind lands on both targets at
        // once.
        // CS variant of cond — the K# vertical. The cascade is byte-identical to the
        // JS one (C# `if / else if / else` is the same construct); the ONE divergence
        // stays in `{{ binds }}`, rendered host-keyed inside template_processor —
        // cs binders lower to `var b = <scrutinee>;` and a `{ k: v }` scrutinee to
        // `new { k = v }`.
        // JS variant of for. Same Liquid context surface as the Zig variant —
        // `{{ iterable }}`, `effects["each"]`, `h.inlined_link[scope]`,
        // `continuations["done"].continue` — but a JS-native `for…of` loop header
        // instead of the Zig `for (…) |x| {}` capture form. The per-iteration
        // `{{ h.inlined_link[scope] }}(__koru_item)` mints a `__koru_inline_scoped_N`
        // effect-splice marker, resolved on the JS path by js_emitter's
        // emitInlineBodyResolvingContinuations (mirrors the Zig
        // emitInlineCodeResolvingSplices). The `| done` terminal is continued via the
        // `__koru_continue_N` marker, resolved the same way.
        //
        // CROSS-TARGET (140_014): the iterable expression is classified by the
        // `parse_range` filter (template_processor.zig). A Zig range `0..N` becomes a JS
        // counting loop `for (let i = 0; i < N; i++)` — the performance-correct form
        // (NOT `Array.from`); anything else (e.g. a JS array literal `[1,2,3]`) flows
        // through verbatim as a `for…of`. Only the loop HEADER differs between the two;
        // the body (effect-handler calls) is shared. The richer Zig-subset expression
        // translator (array literals, `@builtins`, …) is the deferred follow-up
        // (docs/PARSER_PALETTE.md §8.4); for now JS `for` supports ranges + JS-shaped
        // iterables.
        // CS variant of for — the K# vertical. Same `parse_range` as |js: `0..N` →
        // counting `for` (never `while` — trip count known); else `foreach … in`
        // through `cs_lower`. `__koru_item{{ __site }}`: C# forbids shadowing an
        // enclosing local (CS0136 — unlike JS `let`), so each render spells a fresh
        // induction name shared by the header and the splice arg.
        // C variant of if — the sequential-fragment vertical. Same `if/else` surface
        // as the other hosts; the ONE divergence is `c_lower(expr)` — the C lane's
        // writeHostText is verbatim, so the condition must arrive already-lowered
        // (Koru `and`/`or`/`not` would leak otherwise). The continuation markers are
        // resolved by c_emitter's emitInlineBodyResolvingContinuations.
        // C variant of for — the sequential-fragment vertical. `parse_range` on the
        // c_lowered iterable: `lo..hi` becomes the counting loop every C backend
        // wants (the trip count is known); a NON-range iterable has no sequential-C
        // lowering in the first fragment, so the else arm emits a `__koru_c_refuse_*`
        // marker the emitter refuses by name (KORU047) rather than silently emitting
        // wrong C. `long long` is the fragment's int spelling.
        // Koru Standard Library: the `capture` part of control.kz.
        // Joined via `~part capture` in control.kz; merged into the control module at load.
        // ============================================================================
        // CAPTURE - Accumulation with pure semantics (ZERO OVERHEAD)
        // ============================================================================
        //
        // Syntax: capture { total: 0 }
        //         ! as acc |> for(items)
        //             ! each i |> captured { total: acc.total + i }
        //         | captured final |> result(sum: final.total)
        //
        // Both `capture` and `captured` take a SOURCE BLOCK — bare braces, no parens.
        // Bare `name { ... }` is unambiguously an invocation since the `=>` construct
        // glyph took over branch construction (210_047). The parens forms
        // `capture({...})` / `captured({...})` are retired (ratified 2026-06-11).
        // A block holding a single bare expression (`capture { entity }`) seeds from
        // an existing value instead of building a new struct cell.
        //
        // ARCHITECTURE:
        // - capture is a comptime transform: `! as` binds the cell (live/during),
        //   `captured { ... }` invocations are rewritten into general `.assignment`
        //   nodes, `| captured` is the one-shot after-read.
        //
        // SEMANTICS:
        // - Pure from Koru's perspective (captured computes the NEXT value)
        // - Efficient mutation in generated Zig (var cell + field writes)
        // - Decomposes fold while preserving purity guarantees
        // The tor declares the USER surface (second [transform]proc migrant after
        // std/regex:match): a source block, the `! as` cell effect, the optional
        // `| captured` after-read. The shape checker does NOT enforce this contract —
        // transforms run before it and the transform's replacement is what the checker
        // sees — so the transform below audits the claimed set itself
        // (unclaimedContinuation). The machine interface (invocation/item/program/
        // allocator → transformed SiteResult) is the proc-return convention.
        pub const if_event = struct {
            pub const Input = struct {
                expr: []const u8,
            };
            pub const Output = union(enum(u8)) {
                then: struct {
                },
                @"else": struct {
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: if  [/Users/larsde/src/koru-cypoe/koru_std/control.kz:36]
                const expr = __koru_event_input.expr;
                _ = &expr;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
            pub fn handler__c(__koru_event_input: @This().Input) @This().Output { // |c
                const expr = __koru_event_input.expr;
                _ = &expr;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
        };
        pub const cond_event = struct {
            pub const Input = struct {
                expr: []const u8,
            };
            pub const Output = union(enum(u8)) {
                c: struct {
                },
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: cond  [/Users/larsde/src/koru-cypoe/koru_std/control.kz:76]
                const expr = __koru_event_input.expr;
                _ = &expr;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
        };
        pub const for_event = struct {
            pub const Input = struct {
                expr: []const u8,
                keep: ?[]const u8 = null,
            };
            pub const Output = union(enum(u8)) {
                done: struct {
                },
            };
            pub fn handler(__koru_event_input: @This().Input, comptime __H: type) @This().Output {
                const each = __H.each;
                _ = &each;
                // >>> PROC: for  [/Users/larsde/src/koru-cypoe/koru_std/control.kz:124]
                const expr = __koru_event_input.expr;
                const keep = __koru_event_input.keep;
                _ = &expr;
                _ = &keep;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
            pub fn handler__c(__koru_event_input: @This().Input, comptime __H: type) @This().Output { // |c
                const expr = __koru_event_input.expr;
                const keep = __koru_event_input.keep;
                const each = __H.each;
                _ = &each;
                _ = &expr;
                _ = &keep;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
        };
        pub const capture_event = struct {
            pub const Input = struct {
                invocation: *const __koru_ast.Invocation,
                item: *const __koru_ast.Item,
                program: *const __koru_ast.Program,
                allocator: std.mem.Allocator,
                reporter: *koru_std.koru_compiler.ErrorReporter,
            };
            pub const Output = union(enum(u8)) {
                transformed: __koru_ast.SiteResult,
            };
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                const invocation = __koru_event_input.invocation;
                const item = __koru_event_input.item;
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                const reporter = __koru_event_input.reporter;
                _ = &invocation;
                _ = &item;
                _ = &program;
                _ = &allocator;
                _ = &reporter;
                _ = &__koru_event_input;
                // >>> PROC: capture|zig  [/Users/larsde/src/koru-cypoe/koru_std/control.capture.kz:40]

    const ast = @import("ast");
    const ast_functional = @import("ast_functional");
    const struct_literal = @import("struct_literal");

    // The walker hands transforms the containing item of the matched
    // invocation; a capture invocation always lives in a flow. A non-flow
    // item means the dispatch contract broke upstream — crash loudly.
    if (item.* != .flow) @panic("capture transform: containing item is not a flow - walker dispatch contract broken");
    const flow = &item.flow;

    // Idempotency: a prior run already set preamble_code.
    if (flow.preamble_code != null) return .{ .transformed = .{} };

    // The cell seed is the invocation's source block (parser attaches the
    // block interior as the `source` arg). A capture without a block is
    // meaningless — fail loudly at the user.
    var source_text: ?[]const u8 = null;
    for (invocation.args) |arg| {
        if (std.mem.eql(u8, arg.name, "source")) source_text = arg.value;
    }
    if (source_text == null) {
        return .{ .transformed = .{ .replacement = ast.refusal(allocator, reporter, .KORU164, flow.location, flow.module, "~capture requires a seed block: capture {{ field: value }}", .{}) } };
    }

    // --- Find `! as <cell>` (the mutable cell) and `| captured <result>` (the
    //     after-read). Mirrors const's `| as` lookup. ---
    var as_cont: ?*const ast.Continuation = null;
    var captured_cont: ?*const ast.Continuation = null;
    var cell_name: []const u8 = "acc";
    var result_name: []const u8 = "result";
    for (flow.body.continuations) |*cont| {
        if (std.mem.eql(u8, cont.branch, "as")) {
            as_cont = cont;
            if (cont.binding) |b| cell_name = b;
        } else if (std.mem.eql(u8, cont.branch, "captured")) {
            captured_cont = cont;
            if (cont.binding) |b| result_name = b;
        }
    }
    if (as_cont == null) {
        return .{ .transformed = .{ .replacement = ast.refusal(allocator, reporter, .KORU164, flow.location, flow.module, "~capture requires a `! as <cell>` effect branch", .{}) } };
    }

    // The declared contract (`! as *` / `| ?captured *`) is DOCS for transform
    // sites — the shape checker runs AFTER transforms, so nothing downstream
    // ever sees the arms this site drops. The replacement is built from `as`
    // and `captured` alone; every other named arm would parse, then never run
    // and never diagnose (same wall as 690_364's query site). Refuse by name.
    if (ast_functional.unclaimedContinuation(flow.body.continuations, &.{ "as", "captured" })) |uname| {
        return .{ .transformed = .{ .replacement = ast.refusal(allocator, reporter, .KORU164, flow.location, flow.module, "~capture: unclaimed arm `| {s}` — this site claims `! as` and `| captured` only; a `{s}` arm never runs, the transform replaces the site without it", .{ uname, uname }) } };
    }

    // `! as _` discards the cell NAME, but the cell IS the accumulator the
    // capture machinery declares, writes (via `captured {...}`), and reads (the
    // `| captured` after-read) — it needs a real, referenceable Zig identifier.
    // A bare `_` cannot be declared (`var _: T` is a Zig error) nor read. So a
    // `_` cell is never a genuine discard: synthesize a real name, keyed on
    // source line for uniqueness across sibling captures. cell_name is the
    // single source for every downstream reference (preamble var/type, rewrite
    // target, done read), so renaming here covers them all. Mirrors the
    // auto-discharge `_`→synthetic rename for obligation-carrying binds.
    if (std.mem.eql(u8, cell_name, "_")) {
        cell_name = std.fmt.allocPrint(allocator, "__koru_cap_{d}", .{flow.location.line}) catch unreachable;
    }

    // The cell's fields, in declaration order, parsed ONCE via the struct-literal
    // projector (the walker foundation). Used for the `var` seed below. Bare
    // entries pun by name/path; bare expressions and redundant labels are
    // rejected (nothing is positional). The Source text is the block INTERIOR;
    // the projector wants braces back. Singleton non-punnable (`capture { entity }`)
    // is the existing-expression seed carve-out.
    const expr = std.fmt.allocPrint(allocator, "{{{s}}}", .{source_text.?}) catch unreachable;
    const cell_fields = struct_literal.parseFieldsWithOptions(allocator, expr, .{ .allow_singleton_expression = true }) catch |err| {
        return .{ .transformed = .{ .replacement = ast.refusal(allocator, reporter, .KORU164, flow.location, flow.module, "~capture seed: {s}", .{struct_literal.describeErrorIn(allocator, err, expr)}) } };
    };

    // --- Rewrite `captured(...)` invocations into general `.assignment` nodes
    //     that write field-wise into the cell. The opaque `{...}` payload is
    //     interpreted by the projector under the pun law — bare paths pun by
    //     last segment; bare expressions / redundant labels fail loudly.
    //     No `.capture` node, no emitter concession. ---
    const Rewriter = struct {
        err: ?struct { msg: []const u8, loc: @TypeOf(flow.location) } = null,

        fn rewrite(
            self: *@This(),
            alloc: std.mem.Allocator,
            cont: *const ast.Continuation,
            target: []const u8,
        ) *const ast.Continuation {
            var new_node: ?ast.Node = cont.node;
            if (cont.node) |step| {
                if (step == .invocation) {
                    const segs = step.invocation.path.segments;
                    if (segs.len > 0 and std.mem.eql(u8, segs[segs.len - 1], "captured")) {
                        // Block form: the parser stored the block INTERIOR as the
                        // source arg's value; the projector wants braces back.
                        const raw = if (step.invocation.args.len > 0) step.invocation.args[0].value else "";
                        const payload = std.fmt.allocPrint(alloc, "{{{s}}}", .{raw}) catch unreachable;
                        const parsed = struct_literal.parseFields(alloc, payload) catch |err| {
                            self.err = .{ .msg = std.fmt.allocPrint(alloc, "captured: {s}", .{struct_literal.describeErrorIn(alloc, err, payload)}) catch "captured: struct literal error", .loc = cont.location };
                            const out_err = alloc.create(ast.Continuation) catch unreachable;
                            out_err.* = cont.*;
                            return out_err;
                        };
                        const asgn_fields = alloc.alloc(ast.Field, parsed.len) catch unreachable;
                        for (parsed, 0..) |pf, i| {
                            asgn_fields[i] = .{
                                .name = alloc.dupe(u8, pf.name) catch unreachable,
                                .type = "",
                                .expression_str = alloc.dupe(u8, pf.value) catch unreachable,
                            };
                        }
                        new_node = .{ .assignment = .{
                            .target = target,
                            .fields = asgn_fields,
                        } };
                    }
                }
            }
            const new_conts = alloc.alloc(ast.Continuation, cont.continuations.len) catch unreachable;
            for (cont.continuations, 0..) |*nc, i| {
                new_conts[i] = self.rewrite(alloc, nc, target).*;
            }
            const out = alloc.create(ast.Continuation) catch unreachable;
            out.* = cont.*;
            out.node = new_node;
            out.continuations = new_conts;
            return out;
        }
    };

    var rewriter = Rewriter{};
    const rewritten_as = rewriter.rewrite(allocator, as_cont.?, cell_name);
    if (rewriter.err) |e| {
        return .{ .transformed = .{ .replacement = ast.refusal(allocator, reporter, .KORU164, e.loc, flow.module, "{s}", .{e.msg}) } };
    }

    // --- Assemble the new flow continuations: void chains so the REAL for / if
    //     templates run over the cell (no degradation). ---
    var new_conts = std.ArrayList(ast.Continuation).initCapacity(allocator, 2) catch unreachable;

    // (1) The `! as` body, flattened to a void chain. The cell is in scope from
    //     the preamble, so its binding is already satisfied.
    new_conts.append(allocator, .{
        .branch = "",
        .binding = null,
        .condition = null,
        .node = rewritten_as.node,
        .indent = 0,
        .continuations = rewritten_as.continuations,
    }) catch unreachable;

    // (2) `| captured result` → `const result = cell;` (the after-read) then the
    //     captured body. A plain inline_code binding + the body as its child.
    if (captured_cont) |cc| {
        // A `_` (or `_`-prefixed) read binding is a DISCARD: the user runs the
        // after-body without reading the cell — emit no binding at all
        // (`const _ = cell;` is not legal Zig).
        const bind_code = if (std.mem.startsWith(u8, result_name, "_"))
            allocator.dupe(u8, "") catch unreachable
        else
            std.fmt.allocPrint(allocator, "const {s} = {s};", .{ result_name, cell_name }) catch unreachable;
        const body_inner = allocator.alloc(ast.Continuation, 1) catch unreachable;
        body_inner[0] = .{
            .branch = "",
            .binding = null,
            .condition = null,
            .node = cc.node,
            .indent = 0,
            .continuations = cc.continuations,
        };
        new_conts.append(allocator, .{
            .branch = "",
            .binding = null,
            .condition = null,
            .node = .{ .inline_code = bind_code },
            .indent = 0,
            .continuations = body_inner,
        }) catch unreachable;
    }

    // --- The cell seed: `var <cell> = .{ .name = value, ... };`, built from the
    //     projector's fields (no koruStructToZig text surgery). For existing-var
    //     captures (`capture(myVar)`) the expr is not a struct literal, so emit
    //     it verbatim. `_ = &cell;` keeps it live even if the loop never writes. ---
    //
    // HOST LANGUAGE. Everything below is host DECLARATION syntax, which makes it
    // the one part of this transform that cannot be target-neutral — the same
    // split `cond`'s `{{ binds }}` makes at template_processor.zig:594
    // (`lowerScrutinee`), for the same reason and with the same two answers. A
    // capture cell is a struct literal plus a mutable binding; Zig needs a
    // synthesized non-comptime struct type to get a runtime cell out of an
    // anonymous literal, JS needs `let` and an object literal and nothing else.
    // Read the build language ONCE, here, and let both spellings fall out of it:
    // a second `preamble_js` field would be two lowerings of one construct, the
    // shape `for`/`scan` was converged to avoid (see `for`, above).
    //
    // Before this, the Zig text was unconditional, so `--lang=js` got a
    // `comptime blk:` type synthesis and `_ = &cell;` spliced into JavaScript.
    // Every capture on the JS target refused at emission (20 of the 29
    // UnsupportedConstruct failures, measured 2026-08-06) — correctly, since the
    // alternative was emitting Zig and calling it JS.
    const host_is_js = std.mem.eql(u8, CompilerEnv.lang, "js");

    // A block holding exactly one bare expression seeds from an existing
    // value: `capture { entity }`. After the pun law, a bare punnable name
    // resolves to name==value (e.g. entity/entity); a singleton non-punnable
    // keeps name=="". Anything with distinct named fields builds a fresh
    // struct cell.
    const is_existing_var = cell_fields.len == 1 and (cell_fields[0].name.len == 0 or
        std.mem.eql(u8, cell_fields[0].name, cell_fields[0].value));
    const is_struct_init = !is_existing_var;
    const init_host = if (is_struct_init) blk: {
        var seed = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
        seed.appendSlice(allocator, if (host_is_js) "{ " else ".{ ") catch unreachable;
        for (cell_fields, 0..) |cf, i| {
            if (i > 0) seed.appendSlice(allocator, ", ") catch unreachable;
            if (cf.name.len > 0) {
                if (!host_is_js) seed.append(allocator, '.') catch unreachable;
                seed.appendSlice(allocator, cf.name) catch unreachable;
                seed.appendSlice(allocator, if (host_is_js) ": " else " = ") catch unreachable;
            }
            // Koru-native typed seed: `floor: 0[i32]` pins the cell field's
            // type — the SAME annotation (and the same parser) as `const`'s
            // `count: 42[i32]`. Zig pins with @as; untyped values paste
            // verbatim (and a bare 0 stays comptime_int, which the runtime
            // cell rejects — the annotation is how you say "this is data").
            //
            // JS has ONE number type and no comptime, so there is nothing to pin
            // and nothing to rescue: the annotation is PEELED and the value pasted
            // bare. Dropping it is not a loss of information on that target — it is
            // the absence of the problem the annotation solves.
            const peeled = struct_literal.peelBaseType(cf.value);
            if (peeled.type.len > 0 and !host_is_js) {
                seed.appendSlice(allocator, "@as(") catch unreachable;
                seed.appendSlice(allocator, peeled.type) catch unreachable;
                seed.appendSlice(allocator, ", ") catch unreachable;
                seed.appendSlice(allocator, peeled.value) catch unreachable;
                seed.appendSlice(allocator, ")") catch unreachable;
            } else if (peeled.type.len > 0) {
                seed.appendSlice(allocator, peeled.value) catch unreachable;
            } else {
                seed.appendSlice(allocator, cf.value) catch unreachable;
            }
        }
        seed.appendSlice(allocator, " }") catch unreachable;
        break :blk seed.toOwnedSlice(allocator) catch unreachable;
    } else cell_fields[0].value;
    // JS: `let <cell> = <init>;` and that is the whole declaration. An object
    // literal is already mutable and structurally typed, so the Zig type
    // synthesis below has no twin to write; an unused binding is legal there, so
    // `_ = &cell;` has none either (and does not parse).
    //
    // An anonymous ZIG struct literal is comptime, so a bare `var cell = .{...}`
    // is a comptime var and runtime field writes fail. Give the cell an explicit
    // struct type built from the seed's fields (made non-comptime) so it is a
    // runtime value. Existing-var captures already have a concrete type — seed
    // verbatim.
    const preamble = if (host_is_js)
        std.fmt.allocPrint(allocator, "let {s} = {s};", .{ cell_name, init_host }) catch unreachable
    else if (is_struct_init) blk2: {
        const type_name = std.fmt.allocPrint(allocator, "__KoruCaptureT_{s}", .{cell_name}) catch unreachable;
        var p = std.ArrayList(u8).initCapacity(allocator, 512) catch unreachable;
        p.appendSlice(allocator, "const ") catch unreachable;
        p.appendSlice(allocator, type_name) catch unreachable;
        p.appendSlice(allocator, " = comptime blk: {\n") catch unreachable;
        p.appendSlice(allocator, "    const __info = @typeInfo(@TypeOf(") catch unreachable;
        p.appendSlice(allocator, init_host) catch unreachable;
        p.appendSlice(allocator, "));\n") catch unreachable;
        p.appendSlice(allocator, "    var __fields: [__info.@\"struct\".fields.len]@import(\"std\").builtin.Type.StructField = undefined;\n") catch unreachable;
        p.appendSlice(allocator, "    for (__info.@\"struct\".fields, 0..) |__f, __i| {\n") catch unreachable;
        p.appendSlice(allocator, "        __fields[__i] = .{ .name = __f.name, .type = __f.type, .default_value_ptr = null, .is_comptime = false, .alignment = __f.alignment };\n") catch unreachable;
        p.appendSlice(allocator, "    }\n") catch unreachable;
        p.appendSlice(allocator, "    break :blk @Type(.{ .@\"struct\" = .{ .layout = .auto, .fields = &__fields, .decls = &.{}, .is_tuple = false } });\n") catch unreachable;
        p.appendSlice(allocator, "};\n") catch unreachable;
        p.appendSlice(allocator, "var ") catch unreachable;
        p.appendSlice(allocator, cell_name) catch unreachable;
        p.appendSlice(allocator, ": ") catch unreachable;
        p.appendSlice(allocator, type_name) catch unreachable;
        p.appendSlice(allocator, " = ") catch unreachable;
        p.appendSlice(allocator, init_host) catch unreachable;
        p.appendSlice(allocator, ";\n_ = &") catch unreachable;
        p.appendSlice(allocator, cell_name) catch unreachable;
        p.appendSlice(allocator, ";") catch unreachable;
        break :blk2 p.toOwnedSlice(allocator) catch unreachable;
    } else std.fmt.allocPrint(allocator, "var {s} = {s};\n_ = &{s};", .{ cell_name, init_host, cell_name }) catch unreachable;

    // --- @pass_ran (circuit breaker) + @shape_valid (conscious checker
    //     exemption, WITH reason). The dissolution CONSUMES the user's
    //     `! as`/`| captured` branches — they become the cell preamble and
    //     field assignments — so the replacement flow no longer matches the
    //     tor's user contract. That is by design, and this is the rare,
    //     explicit @shape_valid case. NOTE: checkers run AFTER transforms, so
    //     the user surface is validated HERE in the transform (loud
    //     @compileError on missing block / missing `! as`), not by the shape
    //     checker. The decl's branch contract still serves parse + docs. ---
    const new_marks = allocator.alloc([]const u8, flow.inv().marks.len + 2) catch unreachable;
    for (flow.inv().marks, 0..) |m, i| new_marks[i] = m;
    new_marks[flow.inv().marks.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch unreachable;
    new_marks[flow.inv().marks.len + 1] = allocator.dupe(u8, "@shape_valid(\"capture dissolves ! as / | captured into cell preamble + assignments\")") catch unreachable;

    const new_invocation = ast.Invocation{
        .path = flow.inv().path,
        .args = flow.inv().args,
        .annotations = flow.inv().annotations,
        .marks = new_marks,
        .inserted_by_tap = flow.inv().inserted_by_tap,
        .from_opaque_tap = flow.inv().from_opaque_tap,
    };

    // WHOLE-STRUCT COPY, never a field-list literal. A literal silently drops
    // every field it does not name, and this one named eleven of them — losing
    // `is_impl` and `impl_variant`, which decide how a subflow implementation
    // (`run = capture { … }`) is validated. io.kz carries the same warning at
    // its own rebuild, written after that exact drop broke variant subflows
    // whose body is a print. Copy first, then set only what changes.
    var transformed_flow = flow.*;
    transformed_flow.body = ast.rootSite(new_invocation, new_conts.toOwnedSlice(allocator) catch unreachable, flow.location);
    transformed_flow.inline_body = null;
    transformed_flow.preamble_code = preamble;

    const new_item = ast.Item{ .flow = transformed_flow };
    return .{ .transformed = .{ .replacement = new_item, .consumed_arms = &.{ "as", "captured" } } };
            }
        };

    };
    pub const koru_declarations = struct {
        // Koru Standard Library: Declarations
        // ====================================
        //
        // Name-introducing constructs that are neither control flow nor type
        // declarations. Today this is `const` — a module-level VALUE binding. It used
        // to live in `control.kz`, but a value declaration is not control flow; and it
        // is not a type, so it does not belong in `types.kz` either. It is its own
        // thing: a declaration.
        //
        // This module is auto-imported via `index.kz` (like `control`), so the `const`
        // keyword is globally available whenever any std/* module is imported.
        // ============================================================================
        // CONST - module-level value declarations as a per-target TEMPLATE.
        // ============================================================================
        // const({ threshold: 5 }) | as cfg |> ...use cfg.threshold...
        //
        // Much simpler than capture:
        // - No mutation, so no `captured` branches to transform
        // - No runtime struct type conversion needed
        // - Just binds constants and flows through
        //
        // Syntax: const { name: "Claude", count: 42 }   (newline- OR comma-separated)
        //
        // ARCHITECTURE: `const` is a `[template]` proc over a `source: Source` block —
        // NOT a transform. The block is captured WHOLE as a Source (no first-field
        // truncation), and the `parse_fields` Zig FILTER (template_processor.zig) splits
        // it into `{ name, value }` records. Both the |zig| and |js| variants call that
        // SAME filter, so the two lowerings of a const block cannot drift. Each field
        // becomes a `const name = value;` declaration; values are emitted verbatim, and
        // per-target value shaping (a future `comptime_int` vs `number` split) rides the
        // variant boundary — exactly like `if`/`for`. This replaces the old
        // transform-+-codegen_utils.koruStructToConstDecls path ("emit Zig and hope").
        // `[declaration]`: this keyword template emits DECLARATIONS (names into the
        // enclosing scope), not a statement. The emitter splices a declaration flow's
        // rendered body directly at container scope (struct members), NOT wrapped in a
        // `flow()` function — so sibling flows see the names via Zig container-scope
        // lookup. Contrast `if`/`for`, which emit statements into a function body.
        // An optional `value[type]` base-type annotation (e.g. `count: 42[i32]`) is the
        // FIRST thing that genuinely diverges between the two variants: Zig pins the type
        // with `@as(i32, 42)`; JS erases it (numbers are numbers). Array literals diverge
        // too — `["a", "b"]` is valid JS but Zig needs `[_][]const u8{ … }` — so the Zig
        // value is pre-lowered by parse_fields into `f.zig` (arrays → `[_]T{…}`, typed
        // scalars → `@as(T, v)`, everything else verbatim). JS emits the value as-is.
        // Koru Standard Library: the `targets` part of declarations.kz.
        // Joined via `~part targets` in declarations.kz; merged into the module at load.
        //
        // The non-zig template bodies of `const` — same home-for-the-variants
        // doctrine as control.targets.kz. The |zig original stays in
        // declarations.kz beside the tor it spells.
        // CS variant of const — the K# vertical. The splice lands INSIDE
        // `static class main_module` (cs_emitter Phase 0.5), so each field must
        // be a class member: `static readonly dynamic` is the spike spelling —
        // `dynamic` because the type annotation is optional (`name: "World"`
        // carries none) and `readonly` because the Koru const is immutable.
        // `f.value` is the peeled literal (the `[i32]` type annotation is
        // dropped the way |js drops it; a typed-const lowering is the later
        // design talk). cs_lower on the name applies the @verbatim mangle for
        // C#-reserved words — the same lowering references elsewhere take.
        // C variant of const — module-scope `static const` declarations. `ctype` is
        // computed per-field by parse_fields (annotation mapped, else inferred);
        // `cval` is the value through c_lower. The `//@koru:file_scope` flag line
        // tells the C emitter to hoist the whole body out of the flow function —
        // C flows are one `static void` fn each, and a decl inside one would be
        // invisible to sibling flows (the zig lane survives it because every flow
        // shares main's scope). A field the fragment cannot spell renders the
        // `__koru_c_refuse_*` marker — a named refusal, never an ill-formed decl.
        pub const const_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: const  [/Users/larsde/src/koru-cypoe/koru_std/declarations.kz:50]
                const source = __koru_event_input.source;
                _ = &source;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
            pub fn handler__c(__koru_event_input: @This().Input) @This().Output { // |c
                const source = __koru_event_input.source;
                _ = &source;
                _ = &__koru_event_input;
                unreachable; // [template] proc — inlined at call sites
            }
        };
    };
    pub const koru_optimizations = struct {
        pub const koru_kernels = struct {
            // Kernel Optimization Pass - Fuses kernel operations for performance
            // ==============================================================
            // Detects patterns like:
            //   kernel:pairwise { ... } |> advance_positions(...)
            //
            // And fuses them into a single inlined loop, eliminating:
            //   - Function call overhead between kernel ops
            //   - Redundant array traversals
            //
            // Status: Phase 1 - Infrastructure (pass-through)
            // Next: Detect kernel operation sequences and fuse them
            // ============================================================
            // KERNEL OPTIMIZATION EVENT
            // ============================================================
            // ============================================================
            // DETECTION HELPERS (to be implemented)
            // ============================================================
            // TODO: Detect kernel:pairwise invocations in flow
            // fn isKernelPairwise(inv: *const ast.Invocation) bool
            // TODO: Detect position/velocity update patterns
            // fn isKernelUpdate(inv: *const ast.Invocation, kernel-binding: []const u8) bool
            // TODO: Check if two operations can be fused
            // fn canFuse(op1: *const ast.Node, op2: *const ast.Node) bool
            // TODO: Perform the fusion transformation
            // fn fuseKernelOps(allocator: std.mem.Allocator, ops: []const *ast.Node) *ast.Node
            pub const optimize_event = struct {
                pub const Input = struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                };
                pub const Output = koru_std.koru_compiler.CompilerContext;
                pub fn handler(__koru_event_input: @This().Input) @This().Output {
                    // >>> PROC: optimize  [/Users/larsde/src/koru-cypoe/koru_std/optimizations/kernels.kz:23]
                    const ctx = __koru_event_input.ctx;
                    _ = &ctx;
                    _ = &__koru_event_input;

                        // Phase 1: Infrastructure - pass through unchanged
                        // This establishes the pass in the pipeline

                        var updated_ctx = ctx;
                        updated_ctx.passes_completed += 1;

                        // Future phases:
                        // Phase 2: Detect kernel operation sequences
                        //   - Find kernel:pairwise followed by position/velocity updates
                        //   - Track which kernel binding is being operated on
                        //
                        // Phase 3: Analyze fusion candidates
                        //   - Check that operations are on the same kernel
                        //   - Verify no side effects between operations
                        //   - Ensure iteration patterns are compatible
                        //
                        // Phase 4: Transform AST
                        //   - Merge pairwise body with following operations
                        //   - Eliminate intermediate function calls
                        //   - Generate single fused loop

                        return updated_ctx;

                }
            };
        };
        pub const koru_loops = struct {
            // Loop Optimization Pass - GENERAL recursive event pattern → native for loops
            // ==============================================================================
            // Transforms ANY code using checker events + label jumps into native loops.
            // This is backend-agnostic: creates IR nodes that emit to Zig, GLSL, JS, etc.
            //
            // Pattern Detected (GENERAL, not nbody-specific!):
            //   event loop_step { i: usize, limit: usize, ... }
            //   | continue { i: usize, ... }
            //   | done { ... }
            //
            //   proc loop_step {
            //       if (i < limit) {
            //           return .{ .continue = .{ .i = i, ... } };
            //       } else {
            //           return .{ .done = ... };
            //       }
            //   }
            //
            //   some_event = loop_step(i: 0, limit: n, ...)
            //   | continue c |> #loop work_event(i: c.i, ...)
            //       | result |> @loop(i: c.i + 1, ...)
            //   | done |> finished {}
            //
            // Transformation:
            //   SubflowImpl{ .body = .flow } → NativeLoop IR node
            //
            // Status: Phase 1 - Infrastructure (pass-through)
            // Next: Detect loop patterns and create NativeLoop nodes
            // Event: Run loop optimization on AST
            // TODO: Helper functions for detection (to be implemented):
            // - fn isCheckerEvent(event: *const EventDecl) bool
            // - fn isCheckerProc(proc: *const ProcDecl, event: *const EventDecl) bool
            // - fn detectLoopSubflow(subflow: *const SubflowImpl) ?LoopMetadata
            // - fn createNativeLoopNode(metadata: LoopMetadata) NativeLoop
            // - fn transformAST(ctx: CompilerContext, transformations: []Transformation) *Program
            pub const optimize_event = struct {
                pub const Input = struct {
                    ctx: koru_std.koru_compiler.CompilerContext,
                };
                pub const Output = koru_std.koru_compiler.CompilerContext;
                pub fn handler(__koru_event_input: @This().Input) @This().Output {
                    // >>> PROC: optimize  [/Users/larsde/src/koru-cypoe/koru_std/optimizations/loops.kz:37]
                    const ctx = __koru_event_input.ctx;
                    _ = &ctx;
                    _ = &__koru_event_input;

                        // Phase 1: Detect checker events
                        // A checker event has:
                        // - Event with two branches: continue_X and done_X
                        // - Proc with if/else: if (var < expr) return continue else return done

                        // Phase 2: Detect loop subflows
                        // - Subflow that calls checker with init value (i: 0)
                        // - Has label with recursive jump that increments (i: i + 1)

                        // Phase 3: Transform to NativeLoop IR nodes
                        // - Extract: variable, init, limit, work event
                        // - Create NativeLoop with inlined body
                        // - Replace SubflowImpl with NativeLoop in AST

                        // For now: pass through (infrastructure already working!)
                        var updated_ctx = ctx;
                        updated_ctx.passes_completed += 1;
                        return updated_ctx;

                }
            };
        };
    };
    pub const koru_spec = struct {
        // Koru Standard Library: spec — the contract vocabulary a declared
        // interface speaks, plus the generic `[comptime|norun] spec` declaration
        // carrier and the `sites()` harvester shared by spec consumers.
        //
        // These types were uplifted from runtime.specs / interpreter.contracts /
        // the interpreter's value-transport block: an interface descriptor
        // (ScopeEvent) names inputs, branches, obligation create/discharge and the
        // dispatcher contract — none of that is runtime-specific, it is the *spec
        // of a surface*. std/runtime, std/interpreter and every consumer re-alias
        // these names so emitted code (`koru_std.koru_runtime.ScopeEvent` in
        // generated dispatchers, `koru_std.koru_interpreter.CreateSpec` in shape
        // checking) keeps resolving to this single definition.
        //
        // `spec` is the generic declaration carrier: data attached to the AST as a
        // [norun] site, harvested by a [comptime|command] consumer through
        // `spec.sites(program, qualifier, tor)`. A domain that wants its own
        // spelling declares its own [norun] tor and harvests it under its own
        // qualifier — std/realize's `row`/`arm` are that, one level down.
        // The module's runtime presence: the vocabulary's revision, served as data —
        // the §3.6 contract-revision column made real, and the retained event that
        // keeps this host-type library in the emitted namespace (runtime_only emits
        // a module only when an event/proc/flow survives; spec's surface is types +
        // a norun tor, so without this there is no koru_std.koru_spec to resolve).
        const std = @import("std");
        const ast = @import("ast");
        // ============================================================================
        // TYPED FIELD PAYLOAD — what one named field of a call/result can carry
        // ============================================================================
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
        // ============================================================================
        // CALL CONTRACT — the dispatcher signature a descriptor names
        // ============================================================================
        pub const DispatchResult = struct {
            branch: []const u8,
            fields: []const NamedField, // Direct typed field values
        };
        pub const DispatchFn = *const fn (*const ast.Invocation, *DispatchResult) anyerror!void;
        pub const CostFn = *const fn ([]const u8) u64;
        // Obligation functions - tors can create/discharge multiple obligations
        pub const ObligationsArrayFn = *const fn ([]const u8) []const []const u8; // tor -> []obligations
        pub const DischargeEventFn = *const fn ([]const u8) ?[]const u8; // obligation -> tor name
        // ============================================================================
        // OBLIGATION SPECS — which output field creates / input arg discharges
        // ============================================================================
        // CreateSpec describes an obligation created by an tor's output field
        pub const CreateSpec = struct {
            obligation_module: []const u8, // e.g., "sqlite3"
            obligation_name: []const u8, // e.g., "opened"
            field_name: []const u8, // which output field holds the handle ID
            resource_type: []const u8, // e.g., "Connection"
            // Outcome branch carrying this create, in source spelling — null = bare
            // return. A branched tor books only the spec whose branch FIRED.
            branch: ?[]const u8 = null,
        };
        // DischargeSpec describes an obligation discharged by an tor's input arg
        pub const DischargeSpec = struct {
            obligation_module: []const u8, // e.g., "sqlite3"
            obligation_name: []const u8, // e.g., "opened"
            arg_name: []const u8, // which input arg carries the handle ID
        };
        // Spec lookup functions - return full specs with field/arg names
        pub const CreatesSpecFn = *const fn ([]const u8) []const CreateSpec; // tor -> []CreateSpec
        pub const DischargesSpecFn = *const fn ([]const u8) []const DischargeSpec; // tor -> []DischargeSpec
        // ============================================================================
        // SURFACE DESCRIPTOR — the typed tor-surface a scope/interface declares
        // ============================================================================
        // Branch field metadata for shape validation
        pub const BranchField = struct {
            name: []const u8,
            type_name: []const u8,
            is_optional: bool = false,
        };
        // Branch metadata for shape validation
        pub const BranchSpec = struct {
            name: []const u8,
            fields: []const BranchField,
            is_optional: bool = false,
        };
        // Input-field metadata — the argument vocabulary of an tor, what a caller
        // must NAME when invoking it. Carries the raw possession phantom (`!open`
        // discharges, `open!` creates) so the vocabulary is renderable as
        // `handle: string<!open>` — the exact spelling the scope enforces.
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
        // ============================================================================
        // DESCRIPTOR SERVING — the fn-ptr vocabulary a descriptor answers through
        // ============================================================================
        // Branches lookup function type for shape validation
        pub const BranchesLookupFn = *const fn ([]const u8) []const BranchSpec;
        // Event-name enumeration type — the scope's whole vocabulary, order-preserving
        pub const EventsLookupFn = *const fn () []const []const u8;
        // Input-field lookup type — an tor's argument vocabulary; null = the name
        // is not this scope's verb (vocabulary membership answers first).
        pub const InputLookupFn = *const fn ([]const u8) ?[]const InputFieldSpec;
        // Doc lookup type — an tor's declaration prose; empty when the decl
        // carried none.
        pub const DocLookupFn = *const fn ([]const u8) []const u8;
        // ============================================================================
        // SITES — the generic spec-site harvest
        // ============================================================================
        //
        // A spec site is a [norun] flow whose invocation carries a `source` block —
        // `~std/spec:spec { ...json... }` or any domain tor (std/realize:row). The
        // consumer names the qualifier + tor it owns; sites() returns every match
        // in the program's module declarations and top level, in declaration order.
        pub const Site = struct {
            prov: []const u8, // declaring site: module logical name, or the file for program-level sites
            source: []const u8, // the raw `source` block text — the consumer owns the payload's grammar
            flow: *const ast.Flow, // the site itself — consumers read named args (e.g. `iface: <expr>`) off it
            file: []const u8,
            line: usize,
        };
        /// A named arg on a site — e.g. `iface: koruos/ext2` — carried as its raw
        /// text; the consumer owns the name's grammar (module path, tor, foreign id).
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
            // a) module-declared sites — a lift declares its own spec inside its module
            for (program.items) |item| {
                if (item != .module_decl) continue;
                const prov = item.module_decl.logical_name;
                for (item.module_decl.items) |*mi| {
                    if (mi.* != .flow) continue;
                    const src = siteMatch(&mi.flow, qualifier, tor_name) orelse continue;
                    out.append(al, .{ .prov = prov, .source = src, .flow = &mi.flow, .file = mi.flow.location.file, .line = mi.flow.location.line }) catch return out.items;
                }
            }
            // b) program-level sites — the program supplies a declaration for an
            //    interface it does not own (its own provider for a lift)
            for (program.items) |*item| {
                if (item.* != .flow) continue;
                const src = siteMatch(&item.flow, qualifier, tor_name) orelse continue;
                out.append(al, .{ .prov = item.flow.location.file, .source = src, .flow = &item.flow, .file = item.flow.location.file, .line = item.flow.location.line }) catch return out.items;
            }
            return out.items;
        }
        pub const spec_event = struct {
            pub const Input = struct {
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
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
    pub const koru_compiler_types = struct {
        // NOTE: This module is marked [comptime] because CompilerContext contains
        // ast.Program pointers which are only available during compilation.
        // If runtime code needs context, use a different type without AST dependencies.
        // Dummy tor to prevent auto-injection of compiler import (which would create circular dependency)
        const std = @import("std");
        // Import AST types (we'll use ast.Program and ast.Item directly to avoid conflicts)
        const ast = @import("ast");
        // ============================================================
        // SHARED COMPILER TYPES - Used by both compiler and build
        // ============================================================
        // These types are extracted to avoid circular dependencies:
        // - compiler.kz needs to import build.kz (for build:collect)
        // - build.kz needs CompilerContext type
        // - Solution: Both import compiler_types.kz
        pub const SourceLocation = struct {
            file: []const u8,
            line: u32,
            column: u32,
        };
        pub const CompilerError = struct {
            message: []const u8,
            location: SourceLocation,
        };
        pub const CompilerWarning = struct {
            message: []const u8,
            location: SourceLocation,
        };
        pub const ErrorPolicy = enum {
            abort_on_first,
            collect_all,
        };
        pub const CompilerContext = struct {
            ast: *const ast.Program,
            original_ast: *const ast.Program,  // Unfiltered AST for metadata queries (TypeRegistry, etc.)
            allocator: std.mem.Allocator,
            errors: std.ArrayList(CompilerError),
            warnings: std.ArrayList(CompilerWarning),
            error_policy: ErrorPolicy,
            current_pass: ?[]const u8,
            passes_completed: u32,
            tap_registry: ?*@import("tap_registry").TapRegistry,
        };
        pub const __compiler_types_marker_event = struct {
            pub const Input = struct {
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
    };
    pub const koru_template = struct {
        pub const define_event = struct {
            pub const Input = struct {
                name: []const u8,
                source: __koru_ast.Source,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                _ = &__koru_event_input;
                return undefined;
            }
        };
    };
};
pub const koru_koruos = struct {
    pub const koru_realize = struct {
        // koruos/realize: koru-os's realization command + arm policy, over std/realize
        // (DESIGN-0001 §11.1).
        //
        // `koruc main.k realize gen [--arm <id>]` — on the default arm
        // (`unikraft/qemu-x86_64`) it writes the same Makefile.uk (derived from
        // `unikraft:image`, as koru-libs `unikraft` does), but the Kraftfile's kconfig
        // is no longer a hand list:
        //
        //   1. std/realize walks the program's flows and collects every interface it
        //      actually invokes (module + tor), plus the Koru runtime itself.
        //   2. Each used interface is matched to a declared `std/realize:row` site:
        //      kconfig deltas, a declared stack demand, the resources it needs outside
        //      Kconfig, and the evidence for the row.
        //   3. The derived deltas are written, then the author's `unikraft:kconfig`
        //      lines as reported policy overrides. An author line that contradicts a
        //      derived requirement is a refusal. A used, non-system module with no row
        //      is a refusal. A refusal writes no Kraftfile.
        //   4. `realize.txt`: the three tables of §3.5
        //      (interface -> row -> kconfig, resource -> mechanism -> cost,
        //      missing -> refusal).
        //
        // CONFIG_STACK_SIZE_PAGE_ORDER is derived from the declared demand of the used
        // rows (instead of koru-libs' hard pin of 6). The build then measures the
        // reachable stack demand of the linked kernel (experiments/realize/
        // stack-demand.py) and refuses the image if the measurement exceeds it.
        //
        // The solver itself is generic — koruos/realize is only the koru-os policy on
        // top of it: this file declares the koru-os arm table and the rows that cannot
        // be module-owned (the language runtime is not a module, print is std codegen,
        // unikraft/sched lives in koru-libs) as ordinary `std/realize` sites, owns the
        // `unikraft:image`/`unikraft:kconfig` walk, the kconfig derivation, the
        // no-scheduler default, the koruos/nid link phase, and the artifacts
        // (Kraftfile + Makefile.uk; `manifest-<arm>.txt` and the matrix are generic).
        // A mechanism name is this file's vocabulary: "kconfig" for the Unikraft donor
        // arms, "native-runtime" for koru-native, "host-libc" for hosted — std/realize
        // treats every mechanism as an opaque string and does not know Unikraft exists.
        // ---- koru-os's declared policy: the arm table + the rows no lift can own ----
        // These are ordinary std/realize sites — the solver harvests them exactly as
        // it harvests every lift's row; koru-os's only privilege is that this module
        // is where the policy lives, not a privileged code path.
        // koru-os's baseline rows — declared through the same std/realize:row site a
        // lift uses (declared_by=koruos.realize). Stack is a post-merge invariant in
        // the engine, so a lift's stackless extension bind merges onto these rows
        // legally regardless of import order.
        const std = @import("std");
        // ------------------------------------------------------------ link phase (DESIGN-0001 §11.7)
        //
        // For programs that use koruos/nid, realize evaluates the binding chain at build time:
        // every `koruos/nid:open` with a literal manifest is admitted against the export table
        // that the koruos/nid module itself compiles into the image (read from its host lines, so
        // there is one source), and every REQUIRED `koruos/nid:resolve` with a literal foreign
        // name is resolved against the lexically enclosing table. A required import that cannot
        // bind is a table-3 refusal: no Kraftfile, so no image. `probe` (optional) and every
        // outcome are reported as predictions, which the run later checks against the image.
        // Run-time-only facts (generations, stale bindings) are not predicted.
        const NidExport = struct { artifact: []const u8, symbol: []const u8, realizes: []const u8 };
        const NidRow = struct { foreign: []const u8, nid: u64, iface: []const u8, ex: usize, occluded: bool };
        const NidTable = struct {
            id: u32,
            ok: bool,
            reason: []const u8 = "",
            bits: u32 = 64,
            rows: [32]NidRow = undefined,
            n: u32 = 0,
        };
        fn nidHash(comptime domain: []const u8, s: []const u8) u64 {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(domain);
            h.update(s);
            var d: [32]u8 = undefined;
            h.final(&d);
            return std.mem.readInt(u64, d[0..8], .big);
        }
        fn nidMask(bits: u32, v: u64) u64 {
            if (bits >= 64) return v;
            return v >> @intCast(64 - bits) << @intCast(64 - bits);
        }
        fn nidRender(v: u64, out: *[11]u8) []const u8 {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .big);
            _ = std.base64.url_safe_no_pad.Encoder.encode(out, &b);
            return out;
        }
        fn nidField(line: []const u8, comptime key: []const u8) ?[]const u8 {
            return koru_std.koru_realize.declField(line, key);
        }
        fn nidFindExport(exs: []const NidExport, spec: []const u8) ?usize {
            const c = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
            for (exs, 0..) |e, i| if (std.mem.eql(u8, e.artifact, spec[0..c]) and std.mem.eql(u8, e.symbol, spec[c + 1 ..])) return i;
            return null;
        }
        fn nidNsName(f: []const u8) struct { ns: []const u8, name: []const u8 } {
            var it = std.mem.splitScalar(u8, f, '/');
            const a = it.next() orelse "";
            const b = it.next() orelse "";
            const li = std.mem.lastIndexOfScalar(u8, f, '/') orelse 0;
            return .{ .ns = f[0..@min(f.len, a.len + 1 + b.len)], .name = f[li + 1 ..] };
        }
        // The same admission rules as koruos/nid:open (koru/nid/index.kz); the run cross-checks them.
        fn nidOpen(id: u32, manifest: []const u8, bits: u32, exs: []const NidExport) NidTable {
            var t = NidTable{ .id = id, .ok = true, .bits = bits };
            var it = std.mem.splitScalar(u8, manifest, ';');
            while (it.next()) |l0| {
                const l = std.mem.trim(u8, l0, " ");
                if (l.len == 0) continue;
                var f = std.mem.tokenizeScalar(u8, l, ' ');
                const verb = f.next() orelse "";
                const foreign = f.next() orelse "";
                const arrow = f.next() orelse "";
                const iface = f.next() orelse "";
                const arrow2 = f.next() orelse "";
                const spec = f.next() orelse "";
                const ex = nidFindExport(exs, spec);
                var why: []const u8 = "";
                if (!(std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "evolve")) or !std.mem.eql(u8, arrow, "->") or !std.mem.eql(u8, arrow2, "=>") or std.mem.count(u8, foreign, "/") != 3 or std.mem.indexOfScalar(u8, iface, '@') == null or f.next() != null) {
                    why = "malformed row";
                } else if (t.n == t.rows.len) {
                    why = "too many rows";
                } else if (ex == null) {
                    why = "provider export not in this realization";
                } else if (!std.mem.eql(u8, exs[ex.?].realizes, iface)) {
                    why = "provider export realizes another interface";
                }
                const nid = nidMask(bits, nidHash("koruos.nid.v1|", foreign));
                var parent: ?u32 = null;
                if (why.len == 0) {
                    var i: u32 = 0;
                    while (i < t.n) : (i += 1) {
                        const r = &t.rows[i];
                        if (r.nid != nid) continue;
                        if (!std.mem.eql(u8, r.foreign, foreign)) {
                            why = "nid collision";
                            break;
                        }
                        if (r.occluded) continue;
                        if (std.mem.eql(u8, verb, "create")) {
                            why = "create would overwrite a bound foreign name (use evolve)";
                            break;
                        }
                        if (std.mem.eql(u8, r.iface, iface) and r.ex == ex.?) {
                            why = "evolve without change";
                            break;
                        }
                        parent = i;
                    }
                    if (why.len == 0 and std.mem.eql(u8, verb, "evolve") and parent == null) why = "evolve without a parent row";
                }
                if (why.len != 0) {
                    t.ok = false;
                    t.reason = why;
                    return t;
                }
                if (parent) |p| t.rows[p].occluded = true;
                t.rows[t.n] = .{ .foreign = foreign, .nid = nid, .iface = iface, .ex = ex.?, .occluded = false };
                t.n += 1;
            }
            return t;
        }
        const NidCtx = struct {
            al: std.mem.Allocator,
            rep: *std.ArrayListUnmanaged(u8),
            refs: *std.ArrayListUnmanaged(u8),
            exs: []const NidExport,
            arm: []const u8 = "unikraft/qemu-x86_64",
            opens: u32 = 0,
            refusals: u32 = 0,
            predictions: u32 = 0,
        };
        fn nidArg(i: anytype, name: []const u8) ?[]const u8 {
            for (i.args) |a| if (std.mem.eql(u8, a.name, name)) {
                const v = a.value;
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"' and std.mem.indexOf(u8, v, "{{") == null) return v[1 .. v.len - 1];
                return null;
            };
            return null;
        }
        fn nidWalk(c: *NidCtx, cont: anytype, table: ?*const NidTable) void {
            const here: ?*const NidTable = table;
            var tbuf: NidTable = undefined;
            var inv_opt: ?@TypeOf(cont.node.?.invocation) = null;
            if (cont.node) |n| switch (n) {
                .invocation => |i| inv_opt = i,
                .label_with_invocation => |l| inv_opt = l.invocation,
                else => {},
            };
            var kind: enum { other, open, resolve, probe, retarget } = .other;
            if (inv_opt) |i| {
                if (i.path.module_qualifier) |mq| if (std.mem.eql(u8, mq, "koruos.nid") and i.path.segments.len > 0) {
                    const seg = i.path.segments[0];
                    if (std.mem.eql(u8, seg, "open")) kind = .open else if (std.mem.eql(u8, seg, "resolve")) kind = .resolve else if (std.mem.eql(u8, seg, "probe")) kind = .probe else if (std.mem.eql(u8, seg, "retarget")) kind = .retarget;
                };
            }
            var nb: [11]u8 = undefined;
            switch (kind) {
                .open => {
                    const i = inv_opt.?;
                    const id = c.opens;
                    c.opens += 1;
                    const man = nidArg(i, "manifest");
                    var bits: u32 = 64;
                    for (i.args) |a| if (std.mem.eql(u8, a.name, "nid_bits")) {
                        bits = std.fmt.parseInt(u32, a.value, 10) catch 64;
                    };
                    if (man) |m| {
                        tbuf = nidOpen(id, m, bits, c.exs);
                        c.predictions += 1;
                        if (tbuf.ok) c.rep.writer(c.al).print("predict: open #{d} bits={d} -> ok rows={d}\n", .{ id, bits, tbuf.n }) catch {} else c.rep.writer(c.al).print("predict: open #{d} bits={d} -> refused reason={s}\n", .{ id, bits, tbuf.reason }) catch {};
                    } else {
                        tbuf = .{ .id = id, .ok = false, .reason = "manifest not a literal (run-time admission only)" };
                        c.rep.writer(c.al).print("predict: open #{d} -> unknown (manifest not a literal)\n", .{id}) catch {};
                    }
                    // only the `ok` arm holds the table
                    for (cont.continuations) |cc| nidWalk(c, cc, if (std.mem.eql(u8, cc.branch, "ok")) &tbuf else null);
                    return;
                },
                .resolve, .probe => {
                    const i = inv_opt.?;
                    const required = kind == .resolve;
                    const how: []const u8 = if (required) "resolve" else "probe";
                    const foreign = nidArg(i, "foreign");
                    if (foreign == null) {
                        if (required) {
                            c.refusals += 1;
                            c.refs.writer(c.al).print("refused: required import with a non-literal foreign name cannot be checked at build time phase=configure (use probe)\n", .{}) catch {};
                        }
                    } else if (here == null or !here.?.ok) {
                        const f = foreign.?;
                        const why: []const u8 = if (here == null) "no enclosing koruos/nid:open" else here.?.reason;
                        c.predictions += 1;
                        c.rep.writer(c.al).print("predict: {s} foreign={s} -> refused table={s}\n", .{ how, f, why }) catch {};
                        if (required) {
                            c.refusals += 1;
                            c.refs.writer(c.al).print("refused: foreign={s} arm={s} phase=configure missing=table ({s}) via=resolve (required)\n", .{ f, c.arm, why }) catch {};
                        }
                    } else {
                        const t = here.?;
                        const f = foreign.?;
                        const nid = nidMask(t.bits, nidHash("koruos.nid.v1|", f));
                        const nids = nidRender(nid, &nb);
                        var hit: ?u32 = null;
                        var collide = false;
                        var off = std.ArrayListUnmanaged(u8){};
                        defer off.deinit(c.al);
                        const me = nidNsName(f);
                        var k: u32 = 0;
                        while (k < t.n) : (k += 1) {
                            const r = t.rows[k];
                            if (r.occluded) continue;
                            if (r.nid == nid) {
                                if (std.mem.eql(u8, r.foreign, f)) hit = k else collide = true;
                            } else {
                                const o = nidNsName(r.foreign);
                                if (std.mem.eql(u8, o.ns, me.ns) and std.mem.eql(u8, o.name, me.name)) off.writer(c.al).print("{s}{s}", .{ if (off.items.len == 0) "" else " ", r.foreign }) catch {};
                            }
                        }
                        if (hit != null and collide) hit = null;
                        c.predictions += 1;
                        if (hit) |h| {
                            const r = t.rows[h];
                            c.rep.writer(c.al).print("predict: {s} foreign={s} nid={s} table=#{d} -> bound row {d} interface={s} export={s}:{s}\n", .{ how, f, nids, t.id, h, r.iface, c.exs[r.ex].artifact, c.exs[r.ex].symbol }) catch {};
                        } else {
                            const missing: []const u8 = if (collide) "unique nid (collides with a row for another foreign name)" else "correspondence row";
                            const offered: []const u8 = if (off.items.len == 0) "none" else off.items;
                            c.rep.writer(c.al).print("predict: {s} foreign={s} nid={s} table=#{d} -> refused missing={s} offered=[{s}]\n", .{ how, f, nids, t.id, missing, offered }) catch {};
                            if (required) {
                                c.refusals += 1;
                                c.refs.writer(c.al).print("refused: foreign={s} nid={s} arm={s} phase=configure missing={s} offered=[{s}] via=resolve (required)\n", .{ f, nids, c.arm, missing, offered }) catch {};
                            }
                        }
                    }
                },
                .retarget => if (here != null and here.?.ok) {
                    const i = inv_opt.?;
                    const iface = nidArg(i, "iface") orelse "";
                    const to = nidArg(i, "to") orelse "";
                    const ex = nidFindExport(c.exs, to);
                    c.predictions += 1;
                    if (ex == null or !std.mem.eql(u8, c.exs[ex.?].realizes, iface)) {
                        c.rep.writer(c.al).print("predict: retarget {s} to={s} -> refused\n", .{ iface, to }) catch {};
                    } else {
                        tbuf = here.?.*;
                        var n: u32 = 0;
                        var k: u32 = 0;
                        while (k < tbuf.n) : (k += 1) if (!tbuf.rows[k].occluded and std.mem.eql(u8, tbuf.rows[k].iface, iface)) {
                            tbuf.rows[k].ex = ex.?;
                            n += 1;
                        };
                        c.rep.writer(c.al).print("predict: retarget {s} to={s} -> ok rows={d}\n", .{ iface, to, n }) catch {};
                        for (cont.continuations) |cc| nidWalk(c, cc, if (std.mem.eql(u8, cc.branch, "ok")) &tbuf else here);
                        return;
                    }
                },
                .other => {},
            }
            for (cont.continuations) |cc| nidWalk(c, cc, here);
        }
        pub const realize_event = struct {
            pub const Input = struct {
                program: *const koru_std.koru_compiler.Program,
                allocator: __koru_std.mem.Allocator,
                argv: []const []const u8,
            };
            pub const Output = void;
            pub fn handler(__koru_event_input: @This().Input) @This().Output {
                // >>> PROC: realize  [/Users/larsde/src/koru-os-m1/koru/realize/index.kz:103]
                const program = __koru_event_input.program;
                const allocator = __koru_event_input.allocator;
                const argv = __koru_event_input.argv;
                _ = &program;
                _ = &allocator;
                _ = &argv;
                _ = &__koru_event_input;

                    // Bare file-scope spelling — in the command backend, root is backend.zig,
                    // not the emitted file; `koru_std` is the emitted namespace either way.
                    const rlz = koru_std.koru_realize;
                    const eh = @import("emitter_helpers");

                    // ---- 0. arm selection: --arm <id> or --arm=<id>, default unikraft/qemu-x86_64
                    var arm: []const u8 = "unikraft/qemu-x86_64";
                    {
                        var i: usize = 0;
                        while (i < argv.len) : (i += 1) {
                            if (std.mem.eql(u8, argv[i], "--arm") and i + 1 < argv.len) {
                                arm = argv[i + 1];
                                i += 1;
                            } else if (std.mem.startsWith(u8, argv[i], "--arm=")) {
                                arm = argv[i]["--arm=".len..];
                            }
                        }
                    }
                    const is_unikraft = std.mem.startsWith(u8, arm, "unikraft/");

                    // When no used interface needs a scheduler, ask for none. Whether Unikraft honours it is
                    // checked after the build against the resolved .config (check-config.py).
                    const nosched = [_][]const u8{ "CONFIG_LIBUKBOOT_INITNOSCHED=y", "CONFIG_LIBUKSCHEDCOOP=n" };

                    // ---- row table: every declared `std/realize:row` site (koru-os baselines
                    // included), harvested and merged by the engine — order-independent.
                    var rows = std.ArrayListUnmanaged(rlz.Row){};
                    defer rows.deinit(allocator);
                    var malformed = std.ArrayListUnmanaged(u8){};
                    defer malformed.deinit(allocator);
                    var row_arena = std.heap.ArenaAllocator.init(allocator);
                    defer row_arena.deinit();
                    const ra = row_arena.allocator();
                    rlz.collectRows(program, &rows, &malformed, allocator, ra);

                    // ---- matrix mode: `koruc <prog> realize matrix` prints row x arm coverage
                    // of the catalog and writes arm-matrix.txt + rows.json + catalog/projection
                    // marks. No program walk — the instrument for finding provider gaps before
                    // implementing them. The arms are the declared `std/realize:arm` sites.
                    {
                        var matrix = false;
                        for (argv) |a| if (std.mem.eql(u8, a, "matrix")) {
                            matrix = true;
                        };
                        if (matrix) {
                            rlz.writeMatrix(rows.items, rlz.collectArms(program, &malformed, allocator, ra), allocator);
                            return;
                        }
                    }

                    const unquote = struct {
                        fn go(v: []const u8) []const u8 {
                            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
                            return v;
                        }
                    }.go;

                    // ---- 1. collect used interfaces
                    var used = std.ArrayListUnmanaged(rlz.Used){};
                    defer used.deinit(allocator);
                    rlz.collectUsed(program, &used, allocator);

                    var app_name: []const u8 = "";
                    var extra = std.ArrayListUnmanaged([]const u8){};
                    defer extra.deinit(allocator);
                    var author = std.ArrayListUnmanaged([]const u8){};
                    defer author.deinit(allocator);

                    for (program.items) |item| {
                        if (item != .flow) continue;
                        const flow = item.flow;
                        const mq = flow.inv().path.module_qualifier orelse continue;
                        if (!std.mem.eql(u8, mq, "koru.unikraft") and !std.mem.eql(u8, mq, "unikraft")) continue;
                        if (flow.inv().path.segments.len != 1) continue;
                        const seg = flow.inv().path.segments[0];
                        for (flow.inv().args) |arg| {
                            if (std.mem.eql(u8, seg, "image")) {
                                if (std.mem.eql(u8, arg.name, "name")) app_name = unquote(arg.value) else if (std.mem.eql(u8, arg.name, "source")) {
                                    const body = std.mem.trim(u8, arg.value, " \t\r\n");
                                    if (body.len > 0) extra.append(allocator, body) catch return;
                                }
                            } else if (std.mem.eql(u8, seg, "kconfig") and std.mem.eql(u8, arg.name, "source")) {
                                var it = std.mem.splitScalar(u8, arg.value, '\n');
                                while (it.next()) |raw| {
                                    const line = std.mem.trim(u8, raw, " \t\r\n");
                                    if (line.len != 0) author.append(allocator, line) catch return;
                                }
                            }
                        }
                    }
                    if (app_name.len == 0) {
                        if (is_unikraft) {
                            std.debug.print("realize: refused: no unikraft:image declared\n", .{});
                            eh.command_exit_code = 2;
                            return;
                        }
                        app_name = "koru";
                    }

                    // ---- 2. rows for the used interfaces, bound on the selected arm ----
                    var report = std.ArrayListUnmanaged(u8){};
                    defer report.deinit(allocator);
                    const rw = report.writer(allocator);
                    var derived = std.ArrayListUnmanaged([]const u8){};
                    defer derived.deinit(allocator);
                    var stack: u64 = 0;
                    var need_sched = false;
                    // koru-os's own system prefixes — compiler-pipeline surface and the
                    // toolchain-owned modules are the engine's internal skips; these are the
                    // domain's (the donor-unikraft module face).
                    const system_prefixes = [_][]const u8{ "koru.unikraft", "unikraft" };

                    rw.writeAll("# realize.txt: generated by `koruc <file> realize gen` (std/realize + koruos policy, DESIGN-0001 §11.1)\n\n") catch return;
                    rw.print("arm: {s}\n\n", .{arm}) catch return;
                    rw.writeAll("## table 1: interface -> row -> arm binding\n") catch return;
                    const hit = allocator.alloc(bool, rows.items.len) catch return;
                    defer allocator.free(hit);
                    @memset(hit, false);
                    const bound = allocator.alloc(usize, rows.items.len) catch return;
                    defer allocator.free(bound);
                    @memset(bound, 0);
                    var refusals = rlz.admit(rows.items, used.items, arm, "koru.runtime", &system_prefixes, allocator, rw, hit, bound);

                    for (rows.items, 0..) |r, ri| {
                        if (!hit[ri]) continue;
                        const b = r.binds[bound[ri]];
                        if (std.mem.eql(u8, r.iface, "unikraft/sched")) need_sched = true;
                        if (std.mem.eql(u8, b.mechanism, "kconfig")) {
                            rw.print("row: {s} stack={d} kconfig=", .{ r.iface, r.stack }) catch return;
                            for (b.deltas, 0..) |k, i| {
                                rw.print("{s}{s}", .{ if (i == 0) "" else ",", k }) catch return;
                                derived.append(allocator, k) catch return;
                            }
                            if (b.deltas.len == 0) rw.writeAll("none") catch return;
                        } else {
                            rw.print("row: {s} stack={d} mechanism={s} deltas=none", .{ r.iface, r.stack, b.mechanism }) catch return;
                        }
                        rw.print(" evidence=\"{s}\"\n", .{r.evidence}) catch return;
                        stack += r.stack;
                    }
                    if (!need_sched and is_unikraft) {
                        rw.writeAll("row: no-scheduler (no used interface needs one) kconfig=") catch return;
                        for (nosched, 0..) |k, i| {
                            rw.print("{s}{s}", .{ if (i == 0) "" else ",", k }) catch return;
                            derived.append(allocator, k) catch return;
                        }
                        rw.writeAll("\n") catch return;
                    }

                    // stack: smallest order >= 4 whose stack holds the declared demand plus 25 %
                    const want = stack + stack / 4;
                    var order: u6 = 4;
                    while ((@as(u64, 4096) << order) < want) order += 1;
                    const sk = std.fmt.allocPrint(allocator, "CONFIG_STACK_SIZE_PAGE_ORDER={d}", .{order}) catch return;
                    defer allocator.free(sk);
                    if (is_unikraft) derived.append(allocator, sk) catch return;

                    rw.writeAll("\n## table 2: resource -> mechanism -> cost\n") catch return;
                    if (is_unikraft) {
                        rw.print("resource: stack -> CONFIG_STACK_SIZE_PAGE_ORDER={d} ({d} B) -> declared demand {d} B + 25 % = {d} B\n", .{ order, @as(u64, 4096) << order, stack, want }) catch return;
                    } else {
                        rw.print("resource: stack -> host stack (OS-managed, not a kconfig knob) -> declared demand {d} B\n", .{stack}) catch return;
                    }
                    for (rows.items, 0..) |r, ri| if (hit[ri]) {
                        rw.print("resource: {s} -> {s}\n", .{ r.iface, r.resources }) catch return;
                    };

                    // ---- link phase: koruos/nid binding chain at build time (§11.7)
                    var linkrefs = std.ArrayListUnmanaged(u8){};
                    defer linkrefs.deinit(allocator);
                    var uses_nid = false;
                    for (used.items) |u| if (std.mem.eql(u8, u.module, "koruos.nid")) {
                        uses_nid = true;
                    };
                    if (uses_nid) {
                        var exs = std.ArrayListUnmanaged(NidExport){};
                        defer exs.deinit(allocator);
                        for (program.items) |item| {
                            if (item != .module_decl) continue;
                            if (!std.mem.eql(u8, item.module_decl.logical_name, "koruos.nid") and !std.mem.endsWith(u8, item.module_decl.logical_name, "nid")) continue;
                            var inside = false;
                            for (item.module_decl.items) |mi| {
                                if (mi != .host_line) continue;
                                const line = mi.host_line.content;
                                if (std.mem.indexOf(u8, line, "const exports = [_]Export{") != null) {
                                    inside = true;
                                    continue;
                                }
                                if (!inside) continue;
                                if (std.mem.startsWith(u8, std.mem.trim(u8, line, " "), "};")) {
                                    inside = false;
                                    continue;
                                }
                                const a = rlz.declField(line, "artifact") orelse continue;
                                const s = rlz.declField(line, "symbol") orelse continue;
                                const r = rlz.declField(line, "realizes") orelse continue;
                                exs.append(allocator, .{ .artifact = a, .symbol = s, .realizes = r }) catch return;
                            }
                        }
                        rw.writeAll("\n## link: foreign import -> NID -> row -> interface -> export (koruos/nid, evaluated at build time)\n") catch return;
                        for (exs.items) |e| rw.print("export: {s}:{s} realizes {s} (from koru/nid/index.kz, the table linked into the image)\n", .{ e.artifact, e.symbol, e.realizes }) catch return;
                        if (exs.items.len == 0) {
                            refusals += 1;
                            linkrefs.writer(allocator).print("refused: koruos/nid used but its export table was not found in the module phase=configure\n", .{}) catch return;
                        }
                        var ctx = NidCtx{ .al = allocator, .rep = &report, .refs = &linkrefs, .exs = exs.items, .arm = arm };
                        for (program.items) |item| {
                            if (item != .flow) continue;
                            nidWalk(&ctx, item.flow.body, null);
                        }
                        rw.print("link: opens={d} predictions={d} required-import refusals={d}\n", .{ ctx.opens, ctx.predictions, ctx.refusals }) catch return;
                        refusals += ctx.refusals;
                    }

                    // ---- 3. author lines: policy overrides, refused if they contradict a derived line
                    rw.writeAll("\n## table 3: missing / contradicted -> refusal\n") catch return;
                    rw.writeAll(linkrefs.items) catch return;
                    if (malformed.items.len != 0) {
                        rw.writeAll(malformed.items) catch return;
                        for (malformed.items) |ch| if (ch == '\n') {
                            refusals += 1;
                        };
                    }
                    const keyOf = struct {
                        fn go(l: []const u8) []const u8 {
                            const i = std.mem.indexOfAny(u8, l, ":=") orelse return l;
                            return std.mem.trim(u8, l[0..i], " ");
                        }
                    }.go;
                    const valOf = struct {
                        fn go(l: []const u8) []const u8 {
                            const i = std.mem.indexOfAny(u8, l, ":=") orelse return "";
                            return std.mem.trim(u8, l[i + 1 ..], " '\"");
                        }
                    }.go;
                    for (author.items) |a| {
                        if (!is_unikraft) {
                            rw.print("not-applicable: author kconfig line {s} (arm={s})\n", .{ a, arm }) catch return;
                            continue;
                        }
                        var contradicted = false;
                        for (derived.items) |d| {
                            if (std.mem.eql(u8, keyOf(a), keyOf(d)) and !std.mem.eql(u8, valOf(a), valOf(d))) {
                                refusals += 1;
                                contradicted = true;
                                rw.print("refused: author line {s} contradicts derived {s} phase=configure\n", .{ a, d }) catch return;
                            }
                        }
                        if (!contradicted) rw.print("override: author policy {s} (not derived; reported)\n", .{a}) catch return;
                    }
                    if (refusals == 0) rw.writeAll("refusals: none\n") catch return;

                    const slug = rlz.armSlug(arm, allocator);
                    const mfname = std.fmt.allocPrint(allocator, "manifest-{s}.txt", .{slug}) catch return;
                    defer allocator.free(mfname);

                    const rf = std.fs.cwd().createFile("realize.txt", .{}) catch return;
                    rf.writeAll(report.items) catch {};
                    rf.close();
                    if (refusals != 0) {
                        std.fs.cwd().deleteFile("Kraftfile") catch {};
                        std.fs.cwd().deleteFile("Makefile.uk") catch {};
                        std.fs.cwd().deleteFile(mfname) catch {};
                        std.debug.print("realize: {d} refusal(s), no image manifest written; see realize.txt\n", .{refusals});
                        eh.command_exit_code = 3;
                        return;
                    }
                    if (!is_unikraft) {
                        rlz.writeManifest(slug, arm, app_name, rows.items, hit, bound, allocator);
                        return;
                    }

                    // ---- Makefile.uk (same derivation as koru-libs unikraft:image)
                    const lib_name = std.fmt.allocPrint(allocator, "app{s}", .{app_name}) catch return;
                    defer allocator.free(lib_name);
                    const prefix = std.ascii.allocUpperString(allocator, lib_name) catch return;
                    defer allocator.free(prefix);
                    {
                        var buf = std.ArrayListUnmanaged(u8){};
                        defer buf.deinit(allocator);
                        const w = buf.writer(allocator);
                        w.writeAll("# Generated by koruc from ~unikraft:image via koruos/realize — do not edit.\n") catch return;
                        w.print("$(eval $(call addlib,{s}))\n\n", .{lib_name}) catch return;
                        w.print("{s}_SRCS-y += $({s}_BASE)/main.c\n", .{ prefix, prefix }) catch return;
                        w.print("{s}_ALIBS-y += $({s}_BASE)/lib{s}app.a\n", .{ prefix, prefix, app_name }) catch return;
                        if (extra.items.len > 0) w.writeAll("\n") catch return;
                        for (extra.items) |line| {
                            w.writeAll(line) catch return;
                            w.writeAll("\n") catch return;
                        }
                        const f = std.fs.cwd().createFile("Makefile.uk", .{}) catch return;
                        defer f.close();
                        f.writeAll(buf.items) catch return;
                    }
                    // ---- Kraftfile: derived lines first, then author policy
                    {
                        var buf = std.ArrayListUnmanaged(u8){};
                        defer buf.deinit(allocator);
                        const w = buf.writer(allocator);
                        w.writeAll("# Generated by koruc via koruos/realize — derived from the used interfaces (realize.txt).\n") catch return;
                        w.writeAll("spec: v0.6\n") catch return;
                        w.print("name: {s}\n\n", .{app_name}) catch return;
                        w.writeAll("unikraft:\n  version: stable\n  kconfig:\n") catch return;
                        for (derived.items) |d| w.print("    {s}: '{s}'\n", .{ keyOf(d), valOf(d) }) catch return;
                        for (author.items) |a| {
                            var dup = false;
                            for (derived.items) |d| {
                                if (std.mem.eql(u8, keyOf(a), keyOf(d)) and std.mem.eql(u8, valOf(a), valOf(d))) dup = true;
                            }
                            if (!dup) w.print("    {s}\n", .{a}) catch return;
                        }
                        // arm "unikraft/<plat>-<arch>" -> kraft target "<plat>/<arch>"
                        w.writeAll("\ntargets:\n  - ") catch return;
                        {
                            const t = arm["unikraft/".len..];
                            var saw_sep = false;
                            for (t) |ch| {
                                if (ch == '-' and !saw_sep) {
                                    saw_sep = true;
                                    w.writeAll("/") catch return;
                                } else w.print("{c}", .{ch}) catch return;
                            }
                            w.writeAll("\n") catch return;
                        }
                        const f = std.fs.cwd().createFile("Kraftfile", .{}) catch return;
                        defer f.close();
                        f.writeAll(buf.items) catch return;
                    }
                    std.debug.print("realize: Makefile.uk, Kraftfile ({d} derived, {d} author) and realize.txt written; stack order {d}\n", .{ derived.items.len, author.items.len, order });

            }
        };
    };
};
pub fn comptime_main(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) *const __koru_ast.Program {
    var current_program = program;
    _ = &current_program;
    _ = &allocator;
    koru_std.koru_compiler.comptime_flow0(current_program, allocator);
    koru_std.koru_io.comptime_flow1(current_program, allocator);
    koru_std.koru_io.comptime_flow2(current_program, allocator);
    return current_program;
}
// Transform handler imports
const transform_std = __koru_std;
const Arg = __koru_ast.Arg;
const Flow = __koru_ast.Flow;
const SiteResult = __koru_ast.SiteResult;

// Helper: Extract Source struct from flow arguments
fn extractSourceFromArgs(args: []const Arg) ?__koru_ast.Source {
    for (args) |arg| {
        if (arg.source_value) |source| {
            return source.*;  // Return full Source struct
        }
    }
    return null;
}

// Helper: Extract Expression text from flow arguments
fn extractExprFromArgs(args: []const Arg) ?[]const u8 {
    // First try: look for CapturedExpression
    for (args) |arg| {
        if (arg.expression_value) |expr| {
            return expr.text;  // Return expression text
        }
    }
    // Fallback: use first arg's value directly
    // This handles pipeline invocations where expression_value wasn't captured
    if (args.len > 0 and args[0].value.len > 0) {
        return args[0].value;
    }
    return null;
}

fn extractExprFromArgsNamed(args: []const Arg, name: []const u8, expr_idx: usize) ?[]const u8 {
    for (args) |arg| {
        if (arg.name.len > 0 and __koru_std.mem.eql(u8, arg.name, name)) {
            if (arg.expression_value) |expr| return expr.text;
            if (arg.value.len > 0) return arg.value;
        }
    }
    var seen: usize = 0;
    for (args) |arg| {
        if (seen == expr_idx) {
            if (arg.expression_value) |expr| return expr.text;
            if (arg.value.len > 0) return arg.value;
            return null;
        }
        seen += 1;
    }
    return null;
}

fn extractOptionalExprFromArgs(args: []const Arg) ?[]const u8 {
    for (args) |arg| {
        if (arg.expression_value) |expr| {
            return expr.text;
        }
    }
    return null;
}

// Transform handler for: io_print
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_io_print(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    log.debug("[TRANSFORM] io_print: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_io.print_event;
    const expr_opt = extractExprFromArgs(invocation.args);
    if (expr_opt) |expr_text| {
        const input = handler.Input{
            .expr = expr_text,
            .item = item,
            .invocation = invocation,
            .program = program,
            .reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse @panic("transform 'print' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context")))).reporter orelse @panic("transform 'print' declares reporter: *ErrorReporter but the compilation carries none")),
            .allocator = allocator,
        };
        const __variant_opt: ?[]const u8 = blk: {
            if (invocation.variant) |v| break :blk v;
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js")) break :blk "js";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs")) break :blk "cs";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "c")) break :blk "c";
            if (__koru_emitter_helpers.getVariant("std.koru_io:print")) |v| break :blk v;
            break :blk null;
        };
        if (__variant_opt) |__v| {
            const __koru_declared = [_][]const u8{ "js", "cs", "c" };
            var __koru_variant_known = false;
            for (__koru_declared) |__t| {
                if (__koru_std.mem.eql(u8, __v, __t)) __koru_variant_known = true;
            }
            if (!__koru_variant_known) {
                __koru_std.debug.print("error[KORU122]: transform `std.koru_io:print` has no `|{s}` variant — the call site (or build config) selects one\n  declared variants: |js |cs |c\n  a `|variant` tag on a transform invocation selects the variant that produces that output; it never falls back to the default body\n  fix: declare `~proc print|{s} {{ ... }}` next to the existing variants, or drop the tag\n", .{ __v, __v });
                __koru_std.process.exit(1);
            }
        }
        const result = if (__variant_opt) |__v| (if (__koru_std.mem.eql(u8, __v, "js")) handler.handler__js(input) else if (__koru_std.mem.eql(u8, __v, "cs")) handler.handler__cs(input) else if (__koru_std.mem.eql(u8, __v, "c")) handler.handler__c(input) else handler.handler(input)) else handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: io_print_ln
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_io_print_ln(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    log.debug("[TRANSFORM] io_print_ln: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_io.print_ln_event;
    const expr_opt = extractExprFromArgs(invocation.args);
    if (expr_opt) |expr_text| {
        const input = handler.Input{
            .expr = expr_text,
            .item = item,
            .invocation = invocation,
            .program = program,
            .reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse @panic("transform 'print.ln' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context")))).reporter orelse @panic("transform 'print.ln' declares reporter: *ErrorReporter but the compilation carries none")),
            .allocator = allocator,
        };
        const __variant_opt: ?[]const u8 = blk: {
            if (invocation.variant) |v| break :blk v;
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js")) break :blk "js";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs")) break :blk "cs";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "c")) break :blk "c";
            if (__koru_emitter_helpers.getVariant("std.koru_io:print.ln")) |v| break :blk v;
            break :blk null;
        };
        if (__variant_opt) |__v| {
            const __koru_declared = [_][]const u8{ "js", "cs", "c" };
            var __koru_variant_known = false;
            for (__koru_declared) |__t| {
                if (__koru_std.mem.eql(u8, __v, __t)) __koru_variant_known = true;
            }
            if (!__koru_variant_known) {
                __koru_std.debug.print("error[KORU122]: transform `std.koru_io:print.ln` has no `|{s}` variant — the call site (or build config) selects one\n  declared variants: |js |cs |c\n  a `|variant` tag on a transform invocation selects the variant that produces that output; it never falls back to the default body\n  fix: declare `~proc print.ln|{s} {{ ... }}` next to the existing variants, or drop the tag\n", .{ __v, __v });
                __koru_std.process.exit(1);
            }
        }
        const result = if (__variant_opt) |__v| (if (__koru_std.mem.eql(u8, __v, "js")) handler.handler__js(input) else if (__koru_std.mem.eql(u8, __v, "cs")) handler.handler__cs(input) else if (__koru_std.mem.eql(u8, __v, "c")) handler.handler__c(input) else handler.handler(input)) else handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: io_eprint_ln
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_io_eprint_ln(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    log.debug("[TRANSFORM] io_eprint_ln: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_io.eprint_ln_event;
    const expr_opt = extractExprFromArgs(invocation.args);
    if (expr_opt) |expr_text| {
        const input = handler.Input{
            .expr = expr_text,
            .item = item,
            .invocation = invocation,
            .program = program,
            .reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse @panic("transform 'eprint.ln' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context")))).reporter orelse @panic("transform 'eprint.ln' declares reporter: *ErrorReporter but the compilation carries none")),
            .allocator = allocator,
        };
        const __variant_opt: ?[]const u8 = blk: {
            if (invocation.variant) |v| break :blk v;
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js")) break :blk "js";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs")) break :blk "cs";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "c")) break :blk "c";
            if (__koru_emitter_helpers.getVariant("std.koru_io:eprint.ln")) |v| break :blk v;
            break :blk null;
        };
        if (__variant_opt) |__v| {
            const __koru_declared = [_][]const u8{ "js", "cs", "c" };
            var __koru_variant_known = false;
            for (__koru_declared) |__t| {
                if (__koru_std.mem.eql(u8, __v, __t)) __koru_variant_known = true;
            }
            if (!__koru_variant_known) {
                __koru_std.debug.print("error[KORU122]: transform `std.koru_io:eprint.ln` has no `|{s}` variant — the call site (or build config) selects one\n  declared variants: |js |cs |c\n  a `|variant` tag on a transform invocation selects the variant that produces that output; it never falls back to the default body\n  fix: declare `~proc eprint.ln|{s} {{ ... }}` next to the existing variants, or drop the tag\n", .{ __v, __v });
                __koru_std.process.exit(1);
            }
        }
        const result = if (__variant_opt) |__v| (if (__koru_std.mem.eql(u8, __v, "js")) handler.handler__js(input) else if (__koru_std.mem.eql(u8, __v, "cs")) handler.handler__cs(input) else if (__koru_std.mem.eql(u8, __v, "c")) handler.handler__c(input) else handler.handler(input)) else handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: io_eprint
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_io_eprint(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    log.debug("[TRANSFORM] io_eprint: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_io.eprint_event;
    const expr_opt = extractExprFromArgs(invocation.args);
    if (expr_opt) |expr_text| {
        const input = handler.Input{
            .expr = expr_text,
            .item = item,
            .invocation = invocation,
            .program = program,
            .reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse @panic("transform 'eprint' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context")))).reporter orelse @panic("transform 'eprint' declares reporter: *ErrorReporter but the compilation carries none")),
            .allocator = allocator,
        };
        const __variant_opt: ?[]const u8 = blk: {
            if (invocation.variant) |v| break :blk v;
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js")) break :blk "js";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs")) break :blk "cs";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "c")) break :blk "c";
            if (__koru_emitter_helpers.getVariant("std.koru_io:eprint")) |v| break :blk v;
            break :blk null;
        };
        if (__variant_opt) |__v| {
            const __koru_declared = [_][]const u8{ "js", "cs", "c" };
            var __koru_variant_known = false;
            for (__koru_declared) |__t| {
                if (__koru_std.mem.eql(u8, __v, __t)) __koru_variant_known = true;
            }
            if (!__koru_variant_known) {
                __koru_std.debug.print("error[KORU122]: transform `std.koru_io:eprint` has no `|{s}` variant — the call site (or build config) selects one\n  declared variants: |js |cs |c\n  a `|variant` tag on a transform invocation selects the variant that produces that output; it never falls back to the default body\n  fix: declare `~proc eprint|{s} {{ ... }}` next to the existing variants, or drop the tag\n", .{ __v, __v });
                __koru_std.process.exit(1);
            }
        }
        const result = if (__variant_opt) |__v| (if (__koru_std.mem.eql(u8, __v, "js")) handler.handler__js(input) else if (__koru_std.mem.eql(u8, __v, "cs")) handler.handler__cs(input) else if (__koru_std.mem.eql(u8, __v, "c")) handler.handler__c(input) else handler.handler(input)) else handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: io_print_blk
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_io_print_blk(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    log.debug("[TRANSFORM] io_print_blk: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_io.print_blk_event;
    const source_opt = extractSourceFromArgs(invocation.args);
    if (source_opt) |source| {
        const input = handler.Input{
            .source = source,
            .item = item,
            .invocation = invocation,
            .program = program,
            .reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse @panic("transform 'print.blk' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context")))).reporter orelse @panic("transform 'print.blk' declares reporter: *ErrorReporter but the compilation carries none")),
            .allocator = allocator,
        };
        const __variant_opt: ?[]const u8 = blk: {
            if (invocation.variant) |v| break :blk v;
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "cs")) break :blk "cs";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "raw_posix")) break :blk "raw_posix";
            if (__koru_std.mem.eql(u8, CompilerEnv.lang, "js")) break :blk "js";
            if (__koru_emitter_helpers.getVariant("std.koru_io:print.blk")) |v| break :blk v;
            break :blk null;
        };
        if (__variant_opt) |__v| {
            const __koru_declared = [_][]const u8{ "cs", "raw_posix", "js" };
            var __koru_variant_known = false;
            for (__koru_declared) |__t| {
                if (__koru_std.mem.eql(u8, __v, __t)) __koru_variant_known = true;
            }
            if (!__koru_variant_known) {
                __koru_std.debug.print("error[KORU122]: transform `std.koru_io:print.blk` has no `|{s}` variant — the call site (or build config) selects one\n  declared variants: |cs |raw_posix |js\n  a `|variant` tag on a transform invocation selects the variant that produces that output; it never falls back to the default body\n  fix: declare `~proc print.blk|{s} {{ ... }}` next to the existing variants, or drop the tag\n", .{ __v, __v });
                __koru_std.process.exit(1);
            }
        }
        const result = if (__variant_opt) |__v| (if (__koru_std.mem.eql(u8, __v, "cs")) handler.handler__cs(input) else if (__koru_std.mem.eql(u8, __v, "raw_posix")) handler.handler__raw_posix(input) else if (__koru_std.mem.eql(u8, __v, "js")) handler.handler__js(input) else handler.handler(input)) else handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: testing_test
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_testing_test(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    _ = __koru_ctx;
    log.debug("[TRANSFORM] testing_test: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_testing.test_event;
    const source_opt = extractSourceFromArgs(invocation.args);
    const expr_opt = extractExprFromArgs(invocation.args);
    if (source_opt != null and expr_opt != null) {
        const source = source_opt.?;
        const expr_text = expr_opt.?;
        const input = handler.Input{
            .source = source,
            .expr = expr_text,
            .item = item,
            .invocation = invocation,
            .program = program,
            .allocator = allocator,
        };
        if (invocation.variant) |__v| {
            __koru_std.debug.print("error[KORU122]: transform `test` declares no variants, but the call site selects `|{s}`\n  fix: declare `~proc test|{s} {{ ... }}` next to the transform, or drop the tag\n", .{ __v, __v });
            __koru_std.process.exit(1);
        }
        const result = handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: testing_assert
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_testing_assert(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    _ = __koru_ctx;
    log.debug("[TRANSFORM] testing_assert: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_testing.assert_event;
    const expr_opt = extractExprFromArgs(invocation.args);
    if (expr_opt) |expr_text| {
        const input = handler.Input{
            .expr = expr_text,
            .item = item,
            .invocation = invocation,
            .program = program,
            .allocator = allocator,
        };
        if (invocation.variant) |__v| {
            __koru_std.debug.print("error[KORU122]: transform `assert` declares no variants, but the call site selects `|{s}`\n  fix: declare `~proc assert|{s} {{ ... }}` next to the transform, or drop the tag\n", .{ __v, __v });
            __koru_std.process.exit(1);
        }
        const result = handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: testing_assert_eq
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_testing_assert_eq(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    _ = __koru_ctx;
    log.debug("[TRANSFORM] testing_assert_eq: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_testing.assert_eq_event;
    const expr_0 = extractExprFromArgsNamed(invocation.args, "expected", 0);
    const expr_1 = extractExprFromArgsNamed(invocation.args, "actual", 1);
    if (expr_0 != null and expr_1 != null) {
        const input = handler.Input{
            .expected = expr_0.?,
            .actual = expr_1.?,
            .item = item,
            .invocation = invocation,
            .program = program,
            .allocator = allocator,
        };
        if (invocation.variant) |__v| {
            __koru_std.debug.print("error[KORU122]: transform `assert.eq` declares no variants, but the call site selects `|{s}`\n  fix: declare `~proc assert.eq|{s} {{ ... }}` next to the transform, or drop the tag\n", .{ __v, __v });
            __koru_std.process.exit(1);
        }
        const result = handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: testing_assert_contains
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_testing_assert_contains(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    _ = __koru_ctx;
    log.debug("[TRANSFORM] testing_assert_contains: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_testing.assert_contains_event;
    const expr_0 = extractExprFromArgsNamed(invocation.args, "haystack", 0);
    const expr_1 = extractExprFromArgsNamed(invocation.args, "needle", 1);
    if (expr_0 != null and expr_1 != null) {
        const input = handler.Input{
            .haystack = expr_0.?,
            .needle = expr_1.?,
            .item = item,
            .invocation = invocation,
            .program = program,
            .allocator = allocator,
        };
        if (invocation.variant) |__v| {
            __koru_std.debug.print("error[KORU122]: transform `assert.contains` declares no variants, but the call site selects `|{s}`\n  fix: declare `~proc assert.contains|{s} {{ ... }}` next to the transform, or drop the tag\n", .{ __v, __v });
            __koru_std.process.exit(1);
        }
        const result = handler.handler(input);
        return result;
    } else {
        return .{};  // Required args not present, no change
    }
}

// Transform handler for: control_capture
// Transform handler: called when a flow invokes this transform event
// Uses unified ASTNode interface for generic AST traversal
fn call_handler_control_capture(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {
    const invocation = node.invocation;
    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("ERROR: Could not find containing item for invocation\n", .{});
        @panic("transform: invocation not found in program");
    };
    log.debug("[TRANSFORM] control_capture: {d} args\n", .{invocation.args.len});
    for (invocation.args, 0..) |arg, i| {
        log.debug("  Arg[{d}]: name='{s}' has_source={} has_expr={}\n", .{i, arg.name, arg.source_value != null, arg.expression_value != null});
    }
    const handler = koru_std.koru_control.capture_event;
    {
        const input = handler.Input{
            .item = item,
            .invocation = invocation,
            .program = program,
            .reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse @panic("transform 'capture' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context")))).reporter orelse @panic("transform 'capture' declares reporter: *ErrorReporter but the compilation carries none")),
            .allocator = allocator,
        };
        if (invocation.variant) |__v| {
            __koru_std.debug.print("error[KORU122]: transform `capture` declares no variants, but the call site selects `|{s}`\n  fix: declare `~proc capture|{s} {{ ... }}` next to the transform, or drop the tag\n", .{ __v, __v });
            __koru_std.process.exit(1);
        }
        const result = handler.handler(input);
        return switch (result) {
            .transformed => |t| t,
        };
    }
}

// Transform Dispatcher - uses transform_pass_runner for proper recursive AST walking
//
// CRITICAL: Transform execution order is SIGNIFICANT!
//
// Transforms walk the AST in SOURCE ORDER and each transform receives the CURRENT state
// of the AST (including modifications from previous transforms). This means:
//
// 1. Dependencies must appear BEFORE dependents in source code
// 2. Upstream transforms complete BEFORE downstream transforms run
// 3. Type resolution via AST-walking sees the TRANSFORMED upstream AST
//
// Example:
//   ~getUserData() | data u |> renderHTML [HTML]{ $[u.name] }
//
// If getUserData is also a transform, it runs FIRST (appears earlier in source),
// then renderHTML sees the TRANSFORMED getUserData event when resolving 'u's type.
//
// This is why binding.type is "unknown" at parse time - type resolution happens
// at transform time via ast_functional.resolveBindingType().
pub fn run_pass(annotation: []const u8, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, ctx: ?*anyopaque) !*__koru_ast.Program {
    // The `annotation` names WHICH transform stage to run, so the pipeline can
    // sprinkle named stages where they belong: "pre" / "main" / "post" run just
    // that stage; anything else (e.g. "transform") runs all stages in order.
    const __only_stage: ?@import("transform_pass_runner").Stage =
        if (transform_std.mem.eql(u8, annotation, "pre")) .pre
        else if (transform_std.mem.eql(u8, annotation, "pre_late")) .pre_late
        else if (transform_std.mem.eql(u8, annotation, "main")) .main
        else if (transform_std.mem.eql(u8, annotation, "post")) .post
        else null;
    
    // DUMP POINT 6: AST at run_pass() entry
    dumpAST(program, "6-run-pass-start", allocator);
    
    // Build dispatch table for transform/derive handlers
    // Handlers are Koru-defined events with *const Invocation or *const EventDecl params
    const transform_pass_runner = @import("transform_pass_runner");
    const transforms = &[_]transform_pass_runner.TransformEntry{
        .{ .name = "print", .qualifier = "std.io", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_io_print },
        .{ .name = "print.ln", .qualifier = "std.io", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_io_print_ln },
        .{ .name = "eprint.ln", .qualifier = "std.io", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_io_eprint_ln },
        .{ .name = "eprint", .qualifier = "std.io", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_io_eprint },
        .{ .name = "print.blk", .qualifier = "std.io", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_io_print_blk },
        .{ .name = "test", .qualifier = "std.testing", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_testing_test },
        .{ .name = "assert", .qualifier = "std.testing", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_testing_assert },
        .{ .name = "assert.eq", .qualifier = "std.testing", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_testing_assert_eq },
        .{ .name = "assert.contains", .qualifier = "std.testing", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_testing_assert_contains },
        .{ .name = "capture", .qualifier = "std.control", .claims_descendants = false, .stage = .main, .requires = &.{}, .preserves = &.{}, .obligations = &.{}, .handler_fn = call_handler_control_capture },
    };
    
    // Use transform_pass_runner for proper recursive AST walking
    const result = try transform_pass_runner.walkAndTransformStages(program, transforms, allocator, __only_stage, ctx);
    
    if (transform_pass_runner.transform_app_witness_enabled) {
        const __pg_edges = [_]struct { c: []const u8, r: []const u8 }{ .{ .c = "pass-auto-discharge", .r = "check-phantom-signatures" }, .{ .c = "pass-auto-discharge", .r = "check-phantom-args" }, .{ .c = "check-phantom-semantic", .r = "pass-auto-discharge" }, .{ .c = "desugar-chains", .r = "resolve-with-scopes" }, .{ .c = "pass-witness-check", .r = "pass-auto-discharge" } };
        const __pg_tedges = [_]struct { c: []const u8, r: []const u8 }{  };
        const __pg_tstages = [_]struct { n: []const u8, s: []const u8 }{ .{ .n = "print", .s = "main" }, .{ .n = "ln", .s = "main" }, .{ .n = "ln", .s = "main" }, .{ .n = "eprint", .s = "main" }, .{ .n = "blk", .s = "main" }, .{ .n = "test", .s = "main" }, .{ .n = "with-harness", .s = "main" }, .{ .n = "harness", .s = "main" }, .{ .n = "equivalent", .s = "main" }, .{ .n = "assert", .s = "main" }, .{ .n = "ok", .s = "main" }, .{ .n = "eq", .s = "main" }, .{ .n = "contains", .s = "main" }, .{ .n = "capture", .s = "main" } };
        const __pg_orders = [_]struct { c: []const u8, steps: []const []const u8 }{ .{ .c = "system", .steps = &.{ "std.deps:system" } }, .{ .c = "requires", .steps = &.{ "std.compiler:requires" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "coordinate", .steps = &.{ "std.compiler:context-create", "std.compiler:elaborate", "std.compiler:process-ccp-commands", "std.compiler:resolve-with-scopes", "std.compiler:desugar-chains", "std.compiler:run-pre-transforms", "std.compiler:process-template-procs", "std.compiler:fold-comptime", "std.compiler:evaluate-comptime", "std.compiler:analysis", "std.compiler:check-release-gate", "std.compiler:check-structure", "std.compiler:check-phantom-signatures", "std.compiler:check-phantom-args", "std.compiler:pass-auto-discharge", "std.compiler:pass-witness-check", "std.compiler:check-flow", "std.compiler:check-phantom-semantic", "std.compiler:check-purity", "std.compiler:test-generation", "std.optimizer:optimize", "std.optimizations.kernels:optimize", "std.optimizations.loops:optimize", "std.compiler:emission", "std.compiler:inject-ccp", "std.compiler:pass-dead-strip", "std.compiler:emit-zig", "std.compiler:metrics-format", "std.inter:start" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "row", .steps = &.{ "std.realize:row" } }, .{ .c = "row", .steps = &.{ "std.realize:row" } }, .{ .c = "row", .steps = &.{ "std.realize:row" } }, .{ .c = "variants", .steps = &.{ "std.build:variants" } }, .{ .c = "variants", .steps = &.{ "std.build:variants" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "declare", .steps = &.{ "std.compiler:declare" } }, .{ .c = "arm", .steps = &.{ "std.realize:arm" } }, .{ .c = "arm", .steps = &.{ "std.realize:arm" } }, .{ .c = "arm", .steps = &.{ "std.realize:arm" } }, .{ .c = "arm", .steps = &.{ "std.realize:arm" } }, .{ .c = "row", .steps = &.{ "std.realize:row" } }, .{ .c = "row", .steps = &.{ "std.realize:row" } }, .{ .c = "row", .steps = &.{ "std.realize:row" } }, .{ .c = "step", .steps = &.{ "std.build:step" } }, .{ .c = "step", .steps = &.{ "std.build:step" } }, .{ .c = "step", .steps = &.{ "std.build:step" } }, .{ .c = "define", .steps = &.{ "std.template:define" } }, .{ .c = "define", .steps = &.{ "std.template:define" } }, .{ .c = "define", .steps = &.{ "std.template:define" } }, .{ .c = "define", .steps = &.{ "std.template:define" } }, .{ .c = "paths", .steps = &.{ "std.compiler:paths" } }, .{ .c = "info", .steps = &.{ "koruos.fb:info", "std.io:ln", "koruos.fb:fill", "koruos.fb:fill", "koruos.fb:fill", "koruos.fb:present", "std.io:ln", "std.io:ln", "std.io:ln", "std.io:ln", "std.io:ln", "std.io:ln" } }, .{ .c = "start", .steps = &.{ "koru:start" } }, .{ .c = "end", .steps = &.{ "koru:end" } } };
        for (__pg_edges) |e| __koru_std.debug.print("[witness] site pass-graph-edge {s} requires {s}\n", .{ e.c, e.r });
        for (__pg_orders) |o| { __koru_std.debug.print("[witness] site pass-graph-order {s} runs ", .{o.c}); for (o.steps, 0..) |st, i| __koru_std.debug.print("{s}{s}", .{ if (i == 0) "" else ",", st }); __koru_std.debug.print("\n", .{}); }
        for (__pg_tedges) |e| __koru_std.debug.print("[witness] site pass-graph-tedge {s} requires {s}\n", .{ e.c, e.r });
        for (__pg_tstages) |t| __koru_std.debug.print("[witness] site pass-graph-tstage {s} at {s}\n", .{ t.n, t.s });
        __koru_std.debug.print("[witness] site pass-graph-census graph counts edges=5 orders=36,tedges=0,tstages=14\n", .{});
    }
    
    // DUMP POINT 7: AST at run_pass() exit (after all transforms)
    dumpAST(result, "7-run-pass-end", allocator);
    
    return result;
}

// Alias for backward compatibility
pub const process_all_transforms = run_pass;


// ============================================================
// EXTERN WRAPPERS — link-time entry points for backend.zig
// ============================================================

const __KoruCoordinateResult = extern struct {
    is_error: bool,
    code_ptr: [*]const u8,
    code_len: usize,
    metrics_ptr: [*]const u8,
    metrics_len: usize,
    error_ptr: [*]const u8,
    error_len: usize,
};
pub export fn koru_coordinate(
    program_ast: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
) __KoruCoordinateResult {
    const result = koru_std.koru_compiler.coordinate_event.handler(.{
        .program_ast = program_ast,
        .allocator = allocator.*,
    });
    return switch (result) {
        .coordinated => |r| .{
            .is_error = false,
            .code_ptr = r.code.ptr,
            .code_len = r.code.len,
            .metrics_ptr = r.metrics.ptr,
            .metrics_len = r.metrics.len,
            .error_ptr = "".ptr,
            .error_len = 0,
        },
        .@"error" => |e| .{
            .is_error = true,
            .code_ptr = "".ptr,
            .code_len = 0,
            .metrics_ptr = "".ptr,
            .metrics_len = 0,
            .error_ptr = e.ptr,
            .error_len = e.len,
        },
    };
}
pub export fn koru_command_dispatch(
    name: *const anyopaque,
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
    argv: *const anyopaque,
) void {
    const name_typed: *const []const u8 = @ptrCast(@alignCast(name));
    const argv_typed: *const []const []const u8 = @ptrCast(@alignCast(argv));
    // Command dispatch returns before the pipeline reaches Phase 2.3.5,
    // the early comptime_main pass that registers build:config /
    // build:variants into emitter_helpers. Without this prime those
    // registries are empty inside every command handler. The returned
    // program is discarded: handlers keep the seed AST, the prime is
    // for registry side-effects only.
    if (@hasDecl(@This(), "comptime_main")) {
        _ = comptime_main(program, allocator.*);
    }
    if (__koru_std.mem.eql(u8, name_typed.*, "deps")) {
        _ = koru_std.koru_deps.deps_event.handler(.{
            .program = program,
            .allocator = allocator.*,
            .argv = argv_typed.*,
        });
        return;
    }
    if (__koru_std.mem.eql(u8, name_typed.*, "claims")) {
        _ = koru_std.koru_rules.claims_event.handler(.{
            .program = program,
            .allocator = allocator.*,
            .argv = argv_typed.*,
        });
        return;
    }
    if (__koru_std.mem.eql(u8, name_typed.*, "assumes")) {
        _ = koru_std.koru_rules.assumes_event.handler(.{
            .program = program,
            .allocator = allocator.*,
            .argv = argv_typed.*,
        });
        return;
    }
    if (__koru_std.mem.eql(u8, name_typed.*, "realize")) {
        _ = koru_koruos.koru_realize.realize_event.handler(.{
            .program = program,
            .allocator = allocator.*,
            .argv = argv_typed.*,
        });
        return;
    }
}
pub export fn koru_run_pass(
    annotation: *const anyopaque,
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
    out_program: *?*const __koru_ast.Program,
    ctx: ?*anyopaque,
) bool {
    const annotation_typed: *const []const u8 = @ptrCast(@alignCast(annotation));
    out_program.* = run_pass(annotation_typed.*, program, allocator.*, ctx) catch {
        return false;
    };
    return true;
}
pub fn koru_explain_gather(
    program: *const __koru_ast.Program,
    allocator: *const __koru_std.mem.Allocator,
) []const __koru_ast.ExplainReport {
    _ = &program; // may be unused when zero explainers are registered
    var __explain_list = __koru_std.ArrayList(__koru_ast.ExplainReport){};
    return __explain_list.toOwnedSlice(allocator.*) catch return &.{};
}

