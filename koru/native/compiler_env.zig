// compiler_env stub for freestanding images — the emitted program imports
// `compiler_env` unconditionally. On a real filesystem the module loads
// compiler_env.json at backend startup; bare metal has no filesystem at
// entry, so every field is the zero value and every query is the empty
// answer. Programs that actually read flags get the same defaults as an
// unflagged compile — fail-closed, never invented values.

pub const CompilerEnv = struct {
    pub var lang: []const u8 = "zig";
    pub var library: bool = false;
    pub var flags: []const []const u8 = &.{};
    pub var entry_file: []const u8 = "";
    pub var entry_dir: []const u8 = "";
    pub var project_root: []const u8 = "";
    pub var koru_home: []const u8 = "";
    pub var env_vars: []const EnvVar = &.{};

    pub const EnvVar = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn hasFlag(name: []const u8) bool {
        _ = name;
        return false;
    }

    pub fn hasFlagRuntime(name: []const u8) bool {
        return hasFlag(name);
    }

    pub fn getEnv(key: []const u8) ?[]const u8 {
        _ = key;
        return null;
    }

    pub fn load() !void {}
};
