/* Q30 stage 1: LD_PRELOAD fork interposer for Hyprland 0.56.2.
 * spawnRawProc calls fork() with %rbp holding &std::string(cmd), then in the
 * child would execl("/bin/sh","-c",cmd). We never enter that child: when the
 * caller is spawnRawProc we posix_spawnp a simple argv and return the pid so
 * Hyprland takes its parent path. No text mprotect / hotpatch (crashes on UK). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

/* PIE offsets in hyprland_0.56.2+ds-3 (BuildID 791ffc118725092c427f3de4c233db775548d603) */
enum { SPAWN_RAW_OFF = 0x527940, SPAWN_RAW_END = 0x5280f0 };

static uintptr_t hypr_base;
static pid_t (*real_fork)(void);

static int phdr_cb(struct dl_phdr_info *info, size_t size, void *data)
{
	(void)size;
	(void)data;
	if (!info->dlpi_name || !info->dlpi_name[0] || strstr(info->dlpi_name, "Hyprland")) {
		/* Prefer the mapping that actually contains spawnRawProc's file offset. */
		for (int i = 0; i < info->dlpi_phnum; i++) {
			const ElfW(Phdr) *p = &info->dlpi_phdr[i];
			if (p->p_type != PT_LOAD || !(p->p_flags & PF_X))
				continue;
			uintptr_t start = info->dlpi_addr + p->p_vaddr;
			uintptr_t end = start + p->p_memsz;
			uintptr_t cand = info->dlpi_addr + SPAWN_RAW_OFF;
			if (cand >= start && cand < end) {
				hypr_base = info->dlpi_addr;
				return 1; /* stop */
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

static pid_t spawn_simple(const char *cmd, size_t len)
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
	posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
	posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

	pid_t pid = 0;
	int rc = posix_spawnp(&pid, argv[0], &fa, &attr, argv, environ);
	posix_spawnattr_destroy(&attr);
	posix_spawn_file_actions_destroy(&fa);
	free(buf);
	if (rc != 0) {
		errno = rc;
		return -1;
	}
	return pid;
}

/* Called from asm with Hyprland's %rbp (cxx string*) and return address. */
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
		fprintf(stderr, "spawn-compat: hyprland-fork->posix_spawn cmd=%.*s (Q30 stage 1)\n",
			(int)len, cmd);
		fflush(stderr);
		if (!is_simple(cmd, len)) {
			fprintf(stderr, "spawn-compat: REFUSED complex shell (no fork)\n");
			fflush(stderr);
			errno = ENOSYS;
			return -1;
		}
		pid_t pid = spawn_simple(cmd, len);
		if (pid < 0) {
			fprintf(stderr, "spawn-compat: FAILED errno=%d\n", errno);
			fflush(stderr);
			return -1;
		}
		fprintf(stderr, "spawn-compat: ok pid=%d\n", (int)pid);
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

/* Preserve Hyprland's %rbp (args) and pass return address; no C prologue. */
__asm__(
	".text\n"
	".globl fork\n"
	".type fork, @function\n"
	"fork:\n"
	"  endbr64\n"
	"  movq %rbp, %rdi\n"
	"  movq (%rsp), %rsi\n"
	"  jmp koru_fork_dispatch\n"
	".size fork, .-fork\n"
);
