/* Q30 stage 2 (koru-os / M9): LD_PRELOAD for Hyprland 0.56.2.
 *
 * Stage 1: interpose fork inside CExecutor::spawnRawProc -> posix_spawnp.
 * Stage 2: for the declared hyprland.children policy (foot), replace posix-inherit
 * blanket inheritance with an explicit grant manifest (env allowlist + close all
 * other fds). Unknown simple commands keep a loud posix-inherit path.
 *
 * When KORU_CHILD_ROLE=foot is set in the child's env, the same .so also:
 *   - interposes open/openat against a path allowlist (userspace path gate);
 *   - runs a rights census (ungranted fd EBADF, ungranted path EACCES) into
 *     /tmp/rights-census.txt so the host can check the negative.
 *
 * Build: gcc -shared -fPIC -O2 -o libhypr-spawn-compat.so hyprland_spawn_compat.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

enum { SPAWN_RAW_OFF = 0x527940, SPAWN_RAW_END = 0x5280f0 };
enum { FD_SCAN = 256 };

static uintptr_t hypr_base;
static pid_t (*real_fork)(void);
static int (*real_open)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int child_role_foot; /* set in constructor from env */
static int ungranted_fd = -1; /* planted in Hyprland before foot spawn */

/* ---- hyprland.children policy for foot (Q30 stage 2) -------------------- */

static const char *foot_env_allow[] = {
	"WAYLAND_DISPLAY",
	"XDG_RUNTIME_DIR",
	"XDG_CACHE_HOME",
	"HOME",
	"LANG",
	"PATH",
	"SHELL",
	"LIBSEAT_BACKEND",
	"HYPRLAND_INSTANCE_SIGNATURE",
	"KORU_CHILD_ROLE", /* self: activates child-side gate + census */
	"LD_PRELOAD",      /* keep this .so in the child for the path gate */
	NULL,
};

/* Path prefixes foot may open. /tmp/ungranted-secret is deliberately absent. */
static const char *foot_path_allow[] = {
	"/usr/bin/foot",
	"/usr/lib",
	"/lib/",
	"/lib64/",
	"/etc/fonts",
	"/etc/ld.so",
	"/usr/share/fonts",
	"/usr/share/foot",
	"/usr/share/libdrm",
	"/usr/share/X11",
	"/usr/share/glvnd",
	"/dev/korupty",
	"/dev/null",
	"/dev/urandom",
	"/dev/random",
	"/dev/dri",
	"/tmp/xdg",
	"/tmp/cache",
	"/tmp/rights-census", /* census output */
	"/proc/",             /* glibc / foot may touch */
	"/sys/",
	NULL,
};

static int is_foot_cmd(const char *cmd, size_t len)
{
	/* match absolute or basename foot, optionally with args */
	if (len >= 13 && !strncmp(cmd, "/usr/bin/foot", 13) &&
	    (len == 13 || cmd[13] == ' '))
		return 1;
	if (len >= 4 && !strncmp(cmd, "foot", 4) && (len == 4 || cmd[4] == ' '))
		return 1;
	return 0;
}

static int env_allowed(const char *name)
{
	for (int i = 0; foot_env_allow[i]; i++)
		if (strcmp(name, foot_env_allow[i]) == 0)
			return 1;
	return 0;
}

static int path_allowed(const char *path)
{
	if (!path || !*path)
		return 0;
	for (int i = 0; foot_path_allow[i]; i++) {
		size_t n = strlen(foot_path_allow[i]);
		if (!strncmp(path, foot_path_allow[i], n))
			return 1;
	}
	return 0;
}

static int is_simple(const char *s, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		char c = s[i];
		if (c == '|' || c == '&' || c == ';' || c == '>' || c == '<' || c == '`' ||
		    c == '\n' || c == '(' || c == ')')
			return 0;
	}
	return 1;
}

static int phdr_cb(struct dl_phdr_info *info, size_t size, void *data)
{
	(void)size;
	(void)data;
	if (!info->dlpi_name || !info->dlpi_name[0] || strstr(info->dlpi_name, "Hyprland")) {
		for (int i = 0; i < info->dlpi_phnum; i++) {
			const ElfW(Phdr) *p = &info->dlpi_phdr[i];
			if (p->p_type != PT_LOAD || !(p->p_flags & PF_X))
				continue;
			uintptr_t start = info->dlpi_addr + p->p_vaddr;
			uintptr_t end = start + p->p_memsz;
			uintptr_t cand = info->dlpi_addr + SPAWN_RAW_OFF;
			if (cand >= start && cand < end) {
				hypr_base = info->dlpi_addr;
				return 1;
			}
		}
	}
	return 0;
}

static void ensure_base(void)
{
	if (!hypr_base)
		dl_iterate_phdr(phdr_cb, NULL);
}

/* Build filtered envp on the heap; caller frees the vector (not the strings). */
static char **build_policy_envp(int *out_count)
{
	char **out = calloc(64, sizeof(char *));
	int n = 0;
	if (!out)
		return NULL;
	for (char **e = environ; *e && n < 62; e++) {
		char *eq = strchr(*e, '=');
		char name[128];
		size_t nl;
		if (!eq)
			continue;
		nl = (size_t)(eq - *e);
		if (nl >= sizeof(name))
			continue;
		memcpy(name, *e, nl);
		name[nl] = 0;
		if (!env_allowed(name)) {
			fprintf(stderr, "spawn-compat: drop env/%s why=not-in-hyprland.children\n",
				name);
			continue;
		}
		out[n++] = *e;
		fprintf(stderr, "spawn-compat: grant as=env/%s why=hyprland.children\n", name);
	}
	/* Ensure role + preload for the child-side gate. */
	{
		static char role[] = "KORU_CHILD_ROLE=foot";
		static char pre[256];
		int have_role = 0, have_pre = 0;
		for (int i = 0; i < n; i++) {
			if (!strncmp(out[i], "KORU_CHILD_ROLE=", 16))
				have_role = 1;
			if (!strncmp(out[i], "LD_PRELOAD=", 11))
				have_pre = 1;
		}
		if (!have_role)
			out[n++] = role;
		if (!have_pre) {
			snprintf(pre, sizeof(pre), "LD_PRELOAD=/lib/libhypr-spawn-compat.so");
			out[n++] = pre;
		}
	}
	out[n] = NULL;
	*out_count = n;
	fflush(stderr);
	return out;
}

static pid_t spawn_with_policy(const char *cmd, size_t len, int use_policy)
{
	char *buf = malloc(len + 1);
	if (!buf)
		return -1;
	memcpy(buf, cmd, len);
	buf[len] = 0;

	char *argv[64];
	int argc = 0;
	char *p = buf;
	while (*p && argc < 63) {
		while (*p == ' ' || *p == '\t')
			p++;
		if (!*p)
			break;
		argv[argc++] = p;
		while (*p && *p != ' ' && *p != '\t')
			p++;
		if (*p)
			*p++ = 0;
	}
	argv[argc] = NULL;
	if (argc == 0) {
		free(buf);
		errno = EINVAL;
		return -1;
	}

	if (!getenv("WAYLAND_DISPLAY"))
		setenv("WAYLAND_DISPLAY", "wayland-1", 0);

	/* Plant an ungranted fd in the parent so the negative can prove it is closed. */
	if (use_policy && ungranted_fd < 0) {
		int fd = open("/tmp/ungranted-secret", O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd >= 0) {
			(void)!write(fd, "SECRET\n", 7);
			ungranted_fd = fd;
			fprintf(stderr,
				"spawn-compat: planted ungranted fd=%d path=/tmp/ungranted-secret (must not reach child)\n",
				fd);
			fflush(stderr);
		}
	}

	posix_spawn_file_actions_t fa;
	posix_spawnattr_t attr;
	if (posix_spawn_file_actions_init(&fa) != 0) {
		free(buf);
		return -1;
	}
	if (posix_spawnattr_init(&attr) != 0) {
		posix_spawn_file_actions_destroy(&fa);
		free(buf);
		return -1;
	}

	if (use_policy) {
		/* Close every fd that is actually open in the parent (F3). POSIX
		 * fails the spawn if addclose names a closed fd. */
		for (int fd = 0; fd < FD_SCAN; fd++) {
			if (fcntl(fd, F_GETFD) >= 0)
				posix_spawn_file_actions_addclose(&fa, fd);
		}
		/* Then open stdio to /dev/null as explicit grants (why=hyprland.children). */
		posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
		posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
		posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
		fprintf(stderr,
			"spawn-compat: grant as=fd/0,fd/1,fd/2 from=/dev/null verbs=read|write why=hyprland.children\n");
		fprintf(stderr,
			"spawn-compat: grant as=path:/dev/korupty0 verbs=read+write why=hyprland.children (foot --pty opens it)\n");
		fprintf(stderr,
			"spawn-compat: grant as=path:wayland-socket verbs=connect why=hyprland.children (via WAYLAND_DISPLAY)\n");
		fflush(stderr);
	} else {
		posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
		posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
	}

	char **envp = environ;
	char **policy_env = NULL;
	int envc = 0;
	if (use_policy) {
		policy_env = build_policy_envp(&envc);
		if (policy_env)
			envp = policy_env;
	}

	pid_t pid = 0;
	int rc = posix_spawnp(&pid, argv[0], &fa, &attr, argv, envp);
	posix_spawnattr_destroy(&attr);
	posix_spawn_file_actions_destroy(&fa);
	free(policy_env);
	free(buf);
	if (rc != 0) {
		errno = rc;
		return -1;
	}
	return pid;
}

pid_t koru_fork_dispatch(void *cxx_args, void *retaddr)
{
	ensure_base();
	uintptr_t off = (uintptr_t)retaddr - hypr_base;
	if (hypr_base && off > SPAWN_RAW_OFF && off < SPAWN_RAW_END) {
		const char *cmd = *(const char *const *)cxx_args;
		size_t len = *(const size_t *)((const char *)cxx_args + 8);
		if (!cmd) {
			cmd = "";
			len = 0;
		}
		fprintf(stderr, "spawn-compat: hyprland-fork->posix_spawn cmd=%.*s (Q30 stage 2)\n",
			(int)len, cmd);
		fflush(stderr);
		if (!is_simple(cmd, len)) {
			fprintf(stderr, "spawn-compat: REFUSED complex shell (no fork)\n");
			fflush(stderr);
			errno = ENOSYS;
			return -1;
		}
		int policy = is_foot_cmd(cmd, len);
		if (policy)
			fprintf(stderr,
				"spawn-compat: policy=hyprland.children image=foot (explicit grants; not posix-inherit)\n");
		else
			fprintf(stderr,
				"spawn-compat: policy=none (loud posix-inherit fallback for unknown simple cmd)\n");
		fflush(stderr);
		pid_t pid = spawn_with_policy(cmd, len, policy);
		if (pid < 0) {
			fprintf(stderr, "spawn-compat: FAILED errno=%d\n", errno);
			fflush(stderr);
			return -1;
		}
		fprintf(stderr, "spawn-compat: ok pid=%d policy=%s\n", (int)pid,
			policy ? "hyprland.children" : "posix-inherit");
		fflush(stderr);
		return pid;
	}
	if (!real_fork)
		real_fork = (pid_t(*)(void))dlsym(RTLD_NEXT, "fork");
	if (!real_fork) {
		errno = ENOSYS;
		return -1;
	}
	return real_fork();
}

__asm__(
	".text\n"
	".globl fork\n"
	".type fork, @function\n"
	"fork:\n"
	"  endbr64\n"
	"  movq %rbp, %rdi\n"
	"  movq (%rsp), %rsi\n"
	"  jmp koru_fork_dispatch\n"
	".size fork, .-fork\n");

/* ---- child-side path gate + rights census (KORU_CHILD_ROLE=foot) -------- */

static void run_rights_census(void)
{
	FILE *f = fopen("/tmp/rights-census.txt", "w");
	int fd, nopen = 0;
	int ungranted_ebadf = 0;
	int secret_eacces = 0;

	if (!f)
		f = stderr;

	fprintf(f, "role=foot\n");
	/* Fd census: any leftover from Hyprland would show up here. */
	for (fd = 0; fd < FD_SCAN; fd++) {
		if (fcntl(fd, F_GETFD) >= 0) {
			fprintf(f, "fd=%d open\n", fd);
			nopen++;
		}
	}
	fprintf(f, "fd_open_count=%d\n", nopen);

	/* Negative: the planted parent fd number is unknown; try a high fd that
	 * parent held — we closed 0..FD_SCAN-1 in file_actions, so reading the
	 * secret via open must be the path negative. Also try dup of unlikely fd. */
	errno = 0;
	if (fcntl(200, F_GETFD) < 0 && errno == EBADF)
		ungranted_ebadf = 1;
	fprintf(f, "negative_ungranted_fd200_ebadf=%d\n", ungranted_ebadf);

	errno = 0;
	fd = open("/tmp/ungranted-secret", O_RDONLY);
	if (fd < 0 && errno == EACCES)
		secret_eacces = 1;
	else if (fd >= 0) {
		fprintf(f, "negative_ungranted_path_OPENED_BUG fd=%d\n", fd);
		close(fd);
	} else {
		fprintf(f, "negative_ungranted_path_errno=%d\n", errno);
	}
	fprintf(f, "negative_ungranted_path_eacces=%d\n", secret_eacces);
	fprintf(f, "census_done=1\n");
	if (f != stderr)
		fclose(f);
	else
		fflush(stderr);
}

int open(const char *path, int flags, ...)
{
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	if (!real_open)
		real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
	if (child_role_foot && path && !path_allowed(path)) {
		fprintf(stderr, "spawn-compat: REFUSED path=%s why=not-in-hyprland.children\n", path);
		fflush(stderr);
		errno = EACCES;
		return -1;
	}
	if (flags & O_CREAT)
		return real_open(path, flags, mode);
	return real_open(path, flags);
}

int openat(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	if (!real_openat)
		real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
	if (child_role_foot && path && path[0] == '/' && !path_allowed(path)) {
		fprintf(stderr, "spawn-compat: REFUSED path=%s why=not-in-hyprland.children (openat)\n",
			path);
		fflush(stderr);
		errno = EACCES;
		return -1;
	}
	if (flags & O_CREAT)
		return real_openat(dirfd, path, flags, mode);
	return real_openat(dirfd, path, flags);
}

__attribute__((constructor)) static void ctor(void)
{
	const char *role = getenv("KORU_CHILD_ROLE");
	if (role && !strcmp(role, "foot")) {
		child_role_foot = 1;
		run_rights_census();
	}
}
