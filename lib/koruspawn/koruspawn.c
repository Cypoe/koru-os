/* SPDX-License-Identifier: BSD-3-Clause */
/* koru-os lib/koruspawn: Unikraft provider + loud spawn-compat layer.
 * See koruspawn.h. Q32: the ELF loader is the forked app-elfloader load path
 * in lib/koruelf (elf_load.c / elf_ctx.c / elf_binfmt.c), not a live dependency
 * on apps/elfloader. */

#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <uk/assert.h>
#include <uk/config.h>
#include <uk/essentials.h>
#include <uk/print.h>
#include <uk/sched.h>
#include <uk/thread.h>
#include <uk/arch/ctx.h>
#include <uk/console.h>
#include <uk/file.h>
#include <uk/file/nops.h>
#include <uk/posix-fdtab.h>
#include <uk/posix-fd.h>
#include <uk/process.h>
#include <uk/syscall.h>
#include <uk/process/events.h>
#include <uk/plat/config.h>
#include <uk/errptr.h>

#include "koruspawn.h"
#include "elf_prog.h"
#include <libelf.h>
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
#include "mmu.h"
#include <uk/vmem.h>
#endif

extern char **environ;

/* ---- logging ----------------------------------------------------------- */

static void ksp_libelf_init(void)
{
	static int done;
	if (done) return;
	if (elf_version(EV_CURRENT) == EV_NONE)
		uk_pr_err("libelf init failed\n");
	done = 1;
}

static void ksp_log(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if (n >= (int)sizeof(buf) - 1)
		n = (int)sizeof(buf) - 2;
	buf[n++] = '\n';
	buf[n] = '\0';
	uk_console_out(buf, (__sz)n);
}

/* ---- grant store (epoch per §8.5) -------------------------------------- */

struct ksp_slot {
	struct ksp_grant g;
	uint32_t epoch;
	uint32_t revoked_epoch; /* when revoked_epoch == epoch, the grant is dead */
	int live;
};

struct ksp_rec {
	int used;
	int instance;
	int generation;
	int parent;
	int pid;                 /* posix-process pid once started, else 0 */
	enum {
		KSP_STAGED = 1,
		KSP_SEALED,
		KSP_RUNNING,
		KSP_EXITED,
		KSP_DETACHED
	} state;
	char path[256];
	uint64_t budget;
	struct ksp_slot bag[KSP_MAX_GRANTS];
	unsigned nbag;
	int status;
	int entered;
	char supervisor[64];
	struct uk_thread *thread;
	struct elf_prog *prog;
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
	struct ksp_mmu_domain mmu;	/* per-child PT; live after seal when paging */
	struct ksp_mem_grant mem[KSP_MAX_GRANTS];
	unsigned nmem;
#endif
};

static struct ksp_rec table[KSP_MAX_REC];
static int next_instance = 2;
static unsigned roster;

/* Active Spawn child by posix pid (TLS is overwritten by musl arch_prctl). */
static int child_by_pid[128];

int ksp_active_child(void)
{
	pid_t pid = uk_sys_getpid();

	if (pid <= 0 || pid >= (pid_t)(sizeof(child_by_pid) / sizeof(child_by_pid[0])))
		return 0;
	return child_by_pid[pid];
}

static void retire(struct ksp_rec *r, const char *how);

static struct ksp_rec *find(int child)
{
	int i;

	for (i = 0; i < KSP_MAX_REC; i++)
		if (table[i].used && table[i].instance == child)
			return &table[i];
	return NULL;
}

unsigned ksp_roster(void)
{
	return roster;
}

/* ---- proxy file: every granted fd is one of these ---------------------- */

struct ksp_proxy {
	int used;
	int child;
	unsigned gi;
	const char *verbs;
	/* backing: console, or a preloaded buffer */
	enum { PX_CONSOLE, PX_BUF } kind;
	char *buf;
	size_t buflen;
	size_t bufpos;
	struct uk_file file;
	uk_file_refcnt refcnt;
	struct uk_file_state state;
};

static struct ksp_proxy proxies[KSP_MAX_PROXY];
static const char PROXY_VOL[] = "koruspawn-proxy";

static struct ksp_proxy *proxy_of(const struct uk_file *f)
{
	return (struct ksp_proxy *)((char *)f - offsetof(struct ksp_proxy, file));
}

static int verb_ok(const char *verbs, const char *need)
{
	const char *p = verbs;
	size_t n = strlen(need);

	while (*p) {
		while (*p == '+')
			p++;
		if (!*p)
			break;
		if (strncmp(p, need, n) == 0 && (p[n] == '+' || p[n] == '\0'))
			return 1;
		while (*p && *p != '+')
			p++;
	}
	return 0;
}

int ksp_grant_epoch_ok(unsigned slot)
{
	struct ksp_rec *r;
	int c = ksp_active_child();

	if (c == 0)
		return 1; /* ambient / parent context: not gated */
	r = find(c);
	if (!r || slot >= r->nbag)
		return 0;
	return r->bag[slot].live &&
	       r->bag[slot].epoch != r->bag[slot].revoked_epoch;
}

static ssize_t proxy_read(const struct uk_file *f, const struct iovec *iov,
			  size_t iovcnt, size_t off __unused, long flags __unused)
{
	struct ksp_proxy *px = proxy_of(f);
	size_t want, got = 0, i;

	if (!ksp_grant_epoch_ok(px->gi)) {
		ksp_log("refused: child=%d use=fd grant=%u reason=revoked phase=run",
			px->child, px->gi);
		return -EPERM;
	}
	if (!verb_ok(px->verbs, "read")) {
		ksp_log("refused: child=%d use=fd verb=read granted=%s phase=run",
			px->child, px->verbs);
		return -EPERM;
	}
	if (px->kind == PX_CONSOLE)
		return 0;
	for (i = 0; i < iovcnt && px->bufpos < px->buflen; i++) {
		want = iov[i].iov_len;
		if (want > px->buflen - px->bufpos)
			want = px->buflen - px->bufpos;
		memcpy(iov[i].iov_base, px->buf + px->bufpos, want);
		px->bufpos += want;
		got += want;
	}
	return (ssize_t)got;
}

static ssize_t proxy_write(const struct uk_file *f, const struct iovec *iov,
			   size_t iovcnt, size_t off __unused, long flags __unused)
{
	struct ksp_proxy *px = proxy_of(f);
	size_t i, n, total = 0;

	if (!ksp_grant_epoch_ok(px->gi)) {
		ksp_log("refused: child=%d use=fd grant=%u reason=revoked phase=run",
			px->child, px->gi);
		return -EPERM;
	}
	if (!verb_ok(px->verbs, "write")) {
		ksp_log("refused: child=%d use=fd verb=write granted=%s phase=run",
			px->child, px->verbs);
		return -EPERM;
	}
	if (px->kind != PX_CONSOLE)
		return -EPERM;
	for (i = 0; i < iovcnt; i++) {
		n = iov[i].iov_len;
		uk_console_out(iov[i].iov_base, (__sz)n);
		total += n;
	}
	return (ssize_t)total;
}

static const struct uk_file_ops proxy_ops = {
	.read = proxy_read,
	.write = proxy_write,
	.mem = uk_file_nop_mem,
	.getstat = uk_file_nop_getstat,
	.setstat = uk_file_nop_setstat,
	.ctl = uk_file_nop_ctl,
};

static struct ksp_proxy *proxy_alloc(int child, unsigned gi, const char *verbs,
				     const char *value)
{
	int i;
	struct ksp_proxy *px;

	for (i = 0; i < KSP_MAX_PROXY; i++)
		if (!proxies[i].used)
			break;
	if (i == KSP_MAX_PROXY)
		return NULL;
	px = &proxies[i];
	memset(px, 0, sizeof(*px));
	px->used = 1;
	px->child = child;
	px->gi = gi;
	px->verbs = verbs;
	if (value && strncmp(value, "file:", 5) == 0) {
		int fd = open(value + 5, O_RDONLY);
		off_t sz;
		ssize_t n;

		if (fd < 0)
			return NULL;
		sz = lseek(fd, 0, SEEK_END);
		if (sz < 0 || lseek(fd, 0, SEEK_SET) < 0) {
			close(fd);
			return NULL;
		}
		px->buf = malloc((size_t)sz);
		if (!px->buf) {
			close(fd);
			return NULL;
		}
		n = read(fd, px->buf, (size_t)sz);
		close(fd);
		if (n != (ssize_t)sz) {
			free(px->buf);
			return NULL;
		}
		px->buflen = (size_t)sz;
		px->kind = PX_BUF;
	} else {
		px->kind = PX_CONSOLE;
	}
	px->refcnt = UK_FILE_REFCNT_INIT_VALUE(px->refcnt);
	px->state = UK_FILE_STATE_EVENTS_INIT_VALUE(px->state, POLLIN | POLLOUT);
	px->file = (struct uk_file){
		.vol = PROXY_VOL,
		.node = px,
		.ops = &proxy_ops,
		.refcnt = &px->refcnt,
		.state = &px->state,
		._release = uk_file_static_release,
	};
	return px;
}

/* ---- path gate (vfscore task_conv / taskat_conv) ----------------------- */

int ksp_path_allowed(const char *abs)
{
	struct ksp_rec *r;
	unsigned i;
	int c = ksp_active_child();

	if (c == 0) {
		/* Parent / ambient context. */
		return 1;
	}
	ksp_log("spawn: path-gate child=%d path=%s", c, abs ? abs : "(null)");
	r = find(c);
	if (!r)
		return 0;
	/* The image's own path is ambient (the closure grant of reserve). */
	if (strcmp(abs, r->path) == 0)
		return 1;
	for (i = 0; i < r->nbag; i++) {
		const char *as = r->bag[i].g.as;

		if (!r->bag[i].live ||
		    r->bag[i].epoch == r->bag[i].revoked_epoch)
			continue;
		if (strncmp(as, "path:", 5) != 0)
			continue;
		if (!verb_ok(r->bag[i].g.verbs, "read") &&
		    !verb_ok(r->bag[i].g.verbs, "exec"))
			continue;
		if (strcmp(abs, as + 5) == 0 ||
		    (strncmp(abs, as + 5, strlen(as + 5)) == 0 &&
		     abs[strlen(as + 5)] == '/'))
			return 1;
	}
	ksp_log("refused: child=%d use=path path=%s phase=run (not in bag)",
		c, abs);
	return 0;
}

/* ---- tors -------------------------------------------------------------- */

int ksp_reserve(const char *path, uint64_t budget)
{
	int i;
	struct ksp_rec *r;

	if (!path || path[0] != '/') {
		ksp_log("refused: reserve image=%s reason=path must be absolute phase=reserve",
			path ? path : "(null)");
		return -EINVAL;
	}
	if (strcmp(path, "@caller") == 0) {
		ksp_log("refused: reserve image=@caller reason=no second context: continuing at the caller's instruction pointer is not grantable (F2) phase=reserve");
		return -EPERM;
	}
	for (i = 0; i < KSP_MAX_REC; i++)
		if (!table[i].used)
			break;
	if (i == KSP_MAX_REC)
		return -ENOMEM;
	r = &table[i];
	memset(r, 0, sizeof(*r));
	r->used = 1;
	r->instance = next_instance++;
	r->generation = 1;
	r->parent = 1;
	r->state = KSP_STAGED;
	r->budget = budget;
	strncpy(r->path, path, sizeof(r->path) - 1);
	roster++;
	ksp_log("spawn: reserve child=%d.%d image=%s parent=%d budget=%llu bag=0 (empty by default) roster=%u",
		r->instance, r->generation, r->path, r->parent,
		(unsigned long long)budget, roster);
	return r->instance;
}

int ksp_grant(int child, const struct ksp_grant *g)
{
	struct ksp_rec *r = find(child);

	if (!r || r->state != KSP_STAGED)
		return -EINVAL;
	if (!g || !g->as || !g->verbs)
		return -EINVAL;
	/* F2: wholesale address-space copy is not grantable. Per-region mem:/obj:
	 * grants (incl. cow verb) are the dissected-fork AS-copy path (M-SPAWN-MMU). */
	if (strcmp(g->from ? g->from : "", "address-space") == 0 ||
	    (strcmp(g->as, "as") == 0) ||
	    (strncmp(g->as, "as/", 3) == 0)) {
		ksp_log("refused: grant child=%d.%d handle=%s verbs=%s as=%s reason=address-space copy is not grantable (F2) phase=grant",
			r->instance, r->generation, g->from ? g->from : "",
			g->verbs, g->as);
		return -EPERM;
	}
	if (r->nbag >= KSP_MAX_GRANTS) {
		ksp_log("refused: grant child=%d.%d handle=%s verbs=%s as=%s reason=bag full (max_bag) phase=grant",
			r->instance, r->generation, g->from ? g->from : "",
			g->verbs, g->as);
		return -ENOSPC;
	}
	r->bag[r->nbag].g = *g;
	r->bag[r->nbag].epoch = 1;
	r->bag[r->nbag].revoked_epoch = 0;
	r->bag[r->nbag].live = 1;
	r->nbag++;
	ksp_log("spawn: grant child=%d.%d as=%s from=%s verbs=%s across_exec=%d granted_by=%d why=explicit",
		r->instance, r->generation, g->as, g->from ? g->from : "",
		g->verbs, g->across_exec, r->parent);
	return 0;
}


int ksp_grant_mem(int child, unsigned long va, unsigned long len,
		  const char *verbs, int across_exec)
{
	static char asbuf[KSP_MAX_GRANTS][32];
	static char lenbuf[KSP_MAX_GRANTS][32];
	static unsigned as_i;
	struct ksp_grant g;
	unsigned idx;

	if (!verbs || !len)
		return -EINVAL;
	idx = as_i++ % KSP_MAX_GRANTS;
	snprintf(asbuf[idx], sizeof(asbuf[idx]), "mem:0x%lx", va);
	snprintf(lenbuf[idx], sizeof(lenbuf[idx]), "0x%lx", len);
	g = (struct ksp_grant){
		.as = asbuf[idx],
		.from = "parent-mem",
		.verbs = verbs,
		.value = lenbuf[idx],
		.across_exec = across_exec,
	};
	return ksp_grant(child, &g);
}

#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
static int seal_derive_mmu(struct ksp_rec *r)
{
	struct uk_vas *vas = uk_vas_get_active();
	unsigned i, nmem = 0;
	int rc;

	r->nmem = 0;
	for (i = 0; i < r->nbag; i++) {
		struct ksp_grant *g = &r->bag[i].g;
		__vaddr_t va;
		unsigned long attr;
		int cow;

		if (!ksp_mmu_is_mem_as(g->as))
			continue;
		if (ksp_mmu_parse_mem_as(g->as, &va))
			return -EINVAL;
		if (ksp_mmu_parse_verbs(g->verbs, &attr, &cow))
			return -EINVAL;
		/* value may carry length as decimal/hex; default one page */
		{
			unsigned long len = UK_PAGING_PAGE_SIZE;
			if (g->value && g->value[0])
				len = strtoul(g->value, NULL, 0);
			if (!len || (len & (UK_PAGING_PAGE_SIZE - 1)))
				return -EINVAL;
			r->mem[nmem] = (struct ksp_mem_grant){
				.va = va,
				.len = len,
				.pa = UK_PAL_PADDR_INV,
				.attr = attr,
				.cow = cow,
				.gi = i,
			};
			nmem++;
		}
	}
	r->nmem = nmem;
	if (!nmem) {
		ksp_log("manifest: child=%d.%d mmu=skipped (no mem/obj grants; seam only)",
			r->instance, r->generation);
		return 0;
	}
	if (!vas)
		return -EIO;
	rc = ksp_mmu_derive(&r->mmu, vas, r->mem, r->nmem);
	if (rc)
		return rc;
	ksp_log("manifest: child=%d.%d mmu=derived grants_mem=%u rung=2 (PT from bag)",
		r->instance, r->generation, r->nmem);
	return 0;
}
#endif

int ksp_seal(int child)
{
	struct ksp_rec *r = find(child);
	unsigned i;

	if (!r || r->state != KSP_STAGED)
		return -EINVAL;
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
	{
		int rc = seal_derive_mmu(r);
		if (rc) {
			ksp_log("refused: seal child=%d.%d reason=mmu_derive %d phase=seal",
				r->instance, r->generation, rc);
			return rc;
		}
	}
	ksp_log("manifest: child=%d.%d image=%s parent=%d rung=2 (MMU PT from bag) bag=%u ambient=memory<=%llu,clock,exit,yield",
		r->instance, r->generation, r->path, r->parent, r->nbag,
		(unsigned long long)r->budget);
#else
	ksp_log("manifest: child=%d.%d image=%s parent=%d rung=0/1 (one address space; enforced at the seam) bag=%u ambient=memory<=%llu,clock,exit,yield",
		r->instance, r->generation, r->path, r->parent, r->nbag,
		(unsigned long long)r->budget);
#endif
	r->state = KSP_SEALED;
	for (i = 0; i < r->nbag; i++)
		ksp_log("manifest: child=%d.%d grant as=%s from=%s verbs=%s across_exec=%d granted_by=%d why=explicit",
			r->instance, r->generation, r->bag[i].g.as,
			r->bag[i].g.from ? r->bag[i].g.from : "",
			r->bag[i].g.verbs, r->bag[i].g.across_exec, r->parent);
	return 0;
}

/* Install the bag into the CURRENT thread's fdtab and environ. Called from
 * the child thread before jumping into the ELF. */
static int install_bag(struct ksp_rec *r)
{
	unsigned i;
	int fd, want;

	/* Clear every inherited fd: empty by default (F3). */
	for (fd = 0; fd < 64; fd++)
		(void)uk_sys_close(fd);

	/* Clear the environment; re-add only what the bag grants (F5). */
	clearenv();

	for (i = 0; i < r->nbag; i++) {
		struct ksp_grant *g = &r->bag[i].g;

		if (strncmp(g->as, "env/", 4) == 0) {
			if (verb_ok(g->verbs, "read") && g->value)
				setenv(g->as + 4, g->value, 1);
			continue;
		}
		if (strncmp(g->as, "fd/", 3) == 0) {
			struct ksp_proxy *px;
			unsigned mode = 0;

			want = atoi(g->as + 3);
			if (verb_ok(g->verbs, "read"))
				mode |= O_RDONLY;
			if (verb_ok(g->verbs, "write"))
				mode |= O_WRONLY;
			if ((mode & (O_RDONLY | O_WRONLY)) == (O_RDONLY | O_WRONLY))
				mode = O_RDWR;
			px = proxy_alloc(r->instance, i, g->verbs,
					 g->value ? g->value : "console");
			if (!px)
				return -ENOMEM;
			fd = uk_fdtab_open(&px->file, mode);
			if (fd < 0)
				return fd;
			if (fd != want) {
				if (uk_sys_dup3(fd, want, 0) < 0)
					return -errno;
				(void)uk_sys_close(fd);
			}
			continue;
		}
		/* path: grants are checked by the vfscore gate; nothing to install. */
	}
	return 0;
}

/* Child body for uk_posix_process_run: install bag, load ELF, jump. */
static void __noreturn child_main(void *argc_v, void *argv_v)
{
	struct ksp_rec *r = argv_v;
	struct uk_thread *me = uk_thread_current();
	struct elf_prog *prog;
	uint64_t rand[2] = { 0xB0B0, 0xF00D };
	int envc = 0;
	int rc;
	void *stack_new;
	struct ukarch_ctx elfctx;
	struct ukarch_ctx junk;

	(void)argc_v;
	child_by_pid[uk_sys_getpid()] = r->instance;
	r->entered = 1;
	ksp_log("spawn: start child=%d.%d entered=yes", r->instance, r->generation);

	rc = install_bag(r);
	if (rc) {
		ksp_log("spawn: start child=%d.%d stalled reason=install_bag %d",
			r->instance, r->generation, rc);
		r->status = 127;
		r->state = KSP_EXITED;
		uk_syscall_r_exit_group(127); UK_BUG();
	}
	ksp_libelf_init();
	prog = elf_load_vfs(uk_alloc_get_default(), r->path,
			    strrchr(r->path, '/') ? strrchr(r->path, '/') + 1
						  : r->path);
	if (PTRISERR(prog) || !prog) {
		ksp_log("spawn: start child=%d.%d stalled reason=elf_load %d",
			r->instance, r->generation,
			PTRISERR(prog) ? (int)PTR2ERR(prog) : -ENOENT);
		r->status = 127;
		r->state = KSP_EXITED;
		uk_syscall_r_exit_group(127); UK_BUG();
	}
	r->prog = prog;
	ksp_log("spawn: loaded child=%d.%d entry=%p len=%lu",
		r->instance, r->generation, (void *)prog->entry,
		(unsigned long)prog->valen);
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
	/* Step 4: bring ELF image pages into the child PT, then CR3-switch.
	 * Load ran on the parent PT; clone already stripped user VMAs at seal. */
	if (r->mmu.live && prog->vabase && prog->valen) {
		__vaddr_t base = (__vaddr_t)prog->vabase & ~(UK_PAGING_PAGE_SIZE - 1);
		__sz len = (prog->valen + ((__vaddr_t)prog->vabase - base) +
			    UK_PAGING_PAGE_SIZE - 1) & ~(UK_PAGING_PAGE_SIZE - 1);
		unsigned long pages = len / UK_PAGING_PAGE_SIZE;
		unsigned long i;
		struct uk_pagetable *ppt = uk_paging_pt_get_active();
		unsigned long mapped = 0;
		for (i = 0; i < pages; i++) {
			__vaddr_t va = base + i * UK_PAGING_PAGE_SIZE;
			unsigned int lvl = UK_PAL_PAGE_LEVEL;
			__pte_t pte;
			if (uk_paging_pt_walk(ppt, va, &lvl, NULL, &pte) ||
			    !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
				continue;
			if (uk_paging_page_map(&r->mmu.pt, va,
					UK_PAL_PT_Lx_PTE_PADDR(pte, lvl), 1,
					UK_PAGING_PAGE_ATTR_PROT_RWX,
					UK_PAGING_PAGE_FLAG_FORCE_SIZE |
					UK_PAGING_PAGE_FLAG_SIZE(UK_PAL_PAGE_LEVEL)) == 0)
				mapped++;
		}
		ksp_log("spawn: mmu map elf child=%d va=%p pages=%lu mapped=%lu",
			r->instance, (void *)base, pages, mapped);
	}
#endif

	/* Fresh stack for the ELF (same as execve): never overwrite the
	 * Unikraft stack we are currently running on. */
	stack_new = uk_malloc(me->_mem.stack_a, STACK_SIZE);
	if (!stack_new) {
		ksp_log("spawn: start child=%d.%d stalled reason=stack",
			r->instance, r->generation);
		r->status = 127;
		r->state = KSP_EXITED;
		uk_syscall_r_exit_group(127); UK_BUG();
	}
	elfctx = (struct ukarch_ctx){0};
	elfctx.sp = ukarch_gen_sp((__uptr)stack_new, STACK_SIZE);

	if (environ)
		while (environ[envc])
			envc++;
	{
		const char *avng[1] = { NULL };
		int ac = 0;

		/* argv0 is prepended by elf_ctx_init from prog->name */
		rc = elf_arg_env_count(&ac, avng, &envc,
				       (const char **)environ, STACK_SIZE);
		if (rc < 0) {
			ksp_log("spawn: start child=%d.%d stalled reason=arg_env %d",
				r->instance, r->generation, rc);
			r->status = 127;
			r->state = KSP_EXITED;
			uk_syscall_r_exit_group(127); UK_BUG();
		}
	}
	elf_ctx_init(&elfctx, prog, prog->name, 0, NULL, envc,
		     (const char **)environ, rand);

	me->_mem.stack = stack_new;
	me->ctx = elfctx;
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
	if (r->mmu.live) {
		__vaddr_t sva = (__vaddr_t)stack_new & ~(UK_PAGING_PAGE_SIZE - 1);
		__sz slen = (STACK_SIZE + UK_PAGING_PAGE_SIZE - 1) &
			    ~(UK_PAGING_PAGE_SIZE - 1);
		unsigned long spages = slen / UK_PAGING_PAGE_SIZE;
		unsigned int lvl = UK_PAL_PAGE_LEVEL;
		__pte_t pte;
		struct uk_pagetable *ppt = uk_paging_pt_get_active();
		if (uk_paging_pt_walk(ppt, sva, &lvl, NULL, &pte) == 0 &&
		    UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl)) {
			(void)uk_paging_page_map(&r->mmu.pt, sva,
				UK_PAL_PT_Lx_PTE_PADDR(pte, lvl), spages,
				UK_PAGING_PAGE_ATTR_PROT_RW,
				UK_PAGING_PAGE_FLAG_FORCE_SIZE |
				UK_PAGING_PAGE_FLAG_SIZE(UK_PAL_PAGE_LEVEL));
		}
		if (ksp_mmu_activate(&r->mmu)) {
			ksp_log("spawn: start child=%d.%d stalled reason=mmu_activate",
				r->instance, r->generation);
			r->status = 127;
			r->state = KSP_EXITED;
			uk_syscall_r_exit_group(127); UK_BUG();
		}
		ksp_log("spawn: mmu active child=%d.%d (separate AS)",
			r->instance, r->generation);
	}
#endif
	ksp_log("spawn: jumping child=%d.%d ip=%p sp=%p",
		r->instance, r->generation, (void *)elfctx.ip,
		(void *)elfctx.sp);
	ukarch_ctx_switch(&junk, &elfctx);
	/* ELF returned (unusual); treat as exit 0. */
	r->status = 0;
	r->state = KSP_EXITED;
	uk_syscall_r_exit_group(0); UK_BUG();
}

static int on_ppexit(void *data)
{
	struct posix_process_ppexit_event_data *ed = data;
	int i;

	for (i = 0; i < KSP_MAX_REC; i++) {
		if (!table[i].used || table[i].pid != ed->pid)
			continue;
		if (table[i].state == KSP_RUNNING ||
		    table[i].state == KSP_DETACHED)
			table[i].state = KSP_EXITED;
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
		if (table[i].mmu.live && table[i].mmu.active)
			(void)ksp_mmu_deactivate(&table[i].mmu);
#endif
		ksp_log("spawn: exited child=%d.%d (ppexit)",
			table[i].instance, table[i].generation);
		break;
	}
	return UK_EVENT_HANDLED_CONT;
}
UK_EVENT_HANDLER(POSIX_PROCESS_PPEXIT_EVENT, on_ppexit);

static struct ksp_rec *start_pending;

static void __noreturn child_trampoline(void *argc_v, void *argv_v)
{
	(void)argc_v;
	(void)argv_v;
	child_main(0, start_pending);
}

int ksp_start(int child)
{
	struct ksp_rec *r = find(child);
	pid_t pid;

	if (!r || r->state != KSP_SEALED)
		return -EINVAL;
	start_pending = r;
	pid = uk_posix_process_run(child_trampoline, 0, (const char **)r);
	if (pid < 0) {
		ksp_log("spawn: start child=%d.%d stalled reason=process_run %d",
			r->instance, r->generation, (int)pid);
		return (int)pid;
	}
	r->pid = pid;
	r->state = KSP_RUNNING;
	return 0;
}

int ksp_wait(int child, int *status)
{
	struct ksp_rec *r = find(child);
	int wstatus = 0;
	pid_t got;

	if (!r)
		return -EINVAL;
	if (r->state == KSP_DETACHED)
		return -ECHILD;
	if (r->pid <= 0)
		return -EINVAL;
	got = waitpid(r->pid, &wstatus, 0);
	if (got < 0)
		return (int)got;
	r->state = KSP_EXITED;
	r->status = WEXITSTATUS(wstatus);
	if (status)
		*status = r->status;
	ksp_log("spawn: exited child=%d.%d status=%d",
		r->instance, r->generation, r->status);
	return 0;
}


static void retire(struct ksp_rec *r, const char *how)
{
	unsigned i;

	ksp_log("spawn: %s child=%d.%d released bag=%u roster=%u",
		how, r->instance, r->generation, r->nbag, roster ? roster - 1 : 0);
	if (r->prog) {
		elf_unload(r->prog);
		r->prog = NULL;
	}
	for (i = 0; i < KSP_MAX_PROXY; i++)
		if (proxies[i].used && proxies[i].child == r->instance) {
			free(proxies[i].buf);
			proxies[i].used = 0;
		}
	if (r->pid > 0 && r->pid < (int)(sizeof(child_by_pid) / sizeof(child_by_pid[0])))
		child_by_pid[r->pid] = 0;
	if (roster)
		roster--;
	memset(r, 0, sizeof(*r));
}

int ksp_reap(int child)
{
	struct ksp_rec *r = find(child);

	if (!r || r->state != KSP_EXITED)
		return -EINVAL;
	retire(r, "reap");
	return 0;
}

int ksp_abandon(int child)
{
	struct ksp_rec *r = find(child);

	if (!r || (r->state != KSP_STAGED && r->state != KSP_SEALED))
		return -EINVAL;
	retire(r, "abandon (no evidence it ran)");
	return 0;
}

int ksp_detach(int child, const char *supervisor)
{
	struct ksp_rec *r = find(child);

	if (!r || r->state != KSP_RUNNING)
		return -EINVAL;
	strncpy(r->supervisor, supervisor ? supervisor : "init",
		sizeof(r->supervisor) - 1);
	r->state = KSP_DETACHED;
	ksp_log("spawn: detach child=%d.%d supervisor=%s",
		r->instance, r->generation, r->supervisor);
	return 0;
}

int ksp_revoke(int child, unsigned gi)
{
	struct ksp_rec *r = find(child);

	if (!r || (r->state != KSP_RUNNING && r->state != KSP_DETACHED &&
		   r->state != KSP_SEALED))
		return -EINVAL;
	if (gi >= r->nbag || !r->bag[gi].live)
		return -EINVAL;
	/* §8.5: handle dies when its epoch equals the slot's revoked mark. */
	r->bag[gi].revoked_epoch = r->bag[gi].epoch;
	ksp_log("spawn: revoke child=%d.%d grant=%u as=%s epoch=%u (revoked)",
		r->instance, r->generation, gi, r->bag[gi].g.as,
		r->bag[gi].epoch);
#if CONFIG_LIBUKPAGING && CONFIG_LIBUKVMEM
	if (r->mmu.live) {
		unsigned i;
		for (i = 0; i < r->nmem; i++) {
			if (r->mem[i].gi == gi) {
				(void)ksp_mmu_revoke(&r->mmu, &r->mem[i]);
				break;
			}
		}
	}
#endif
	return 0;
}

int ksp_replace(int child, const char *path)
{
	struct ksp_rec *r = find(child);
	unsigned i, w;

	if (!r || r->state != KSP_RUNNING)
		return -EINVAL;
	if (!path || path[0] != '/')
		return -EINVAL;
	if (ksp_active_child() != r->instance) {
		ksp_log("refused: replace child=%d.%d reason=not held by the child itself phase=replace",
			r->instance, r->generation);
		return -EPERM;
	}
	/* Keep only across_exec grants (F12). */
	w = 0;
	for (i = 0; i < r->nbag; i++) {
		if (!r->bag[i].g.across_exec) {
			ksp_log("spawn: replace child=%d.%d drop as=%s (not across_exec)",
				r->instance, r->generation, r->bag[i].g.as);
			continue;
		}
		r->bag[w++] = r->bag[i];
	}
	r->nbag = w;
	strncpy(r->path, path, sizeof(r->path) - 1);
	r->generation++;
	ksp_log("spawn: replace child=%d.%d image=%s lineage=evolve bag=%u",
		r->instance, r->generation, r->path, r->nbag);
	/* Re-exec in place: the running thread is the child's. Only legal when
	 * called from that child (tls match). */
/* Jump back through child_main's load path by re-installing and
	 * loading. We do that by resetting entered and calling the body. */
	{
		struct uk_thread *me = uk_thread_current();
		struct elf_prog *prog;
		uint64_t rand[2] = { 0xB0B0, 0xF00D };
		const char *argv[2];
		int envc = 0;
		if (r->prog) {
			elf_unload(r->prog);
			r->prog = NULL;
		}
		if (install_bag(r))
			return -EIO;
		ksp_libelf_init();
	prog = elf_load_vfs(uk_alloc_get_default(), r->path,
				    strrchr(r->path, '/') + 1);
		if (PTRISERR(prog) || !prog)
			return PTRISERR(prog) ? (int)PTR2ERR(prog) : -ENOENT;
		r->prog = prog;
		argv[0] = prog->name;
		argv[1] = NULL;
me->ctx.sp = ukarch_gen_sp((__uptr)me->_mem.stack, STACK_SIZE);
		if (environ)
			while (environ[envc])
				envc++;
		elf_ctx_init(&me->ctx, prog, argv[0], 0, NULL, envc,
			     (const char **)environ, rand);
		{
			struct ukarch_ctx junk;

			ukarch_ctx_switch(&junk, &me->ctx);
		}
	}
	return 0;
}

int ksp_fork_refuse(void)
{
	ksp_log("refused: fork by holder=1 reason=address-space copy is not grantable (F2) phase=run arm=unikraft/qemu-x86_64 offered=reserve+grant+seal+start");
	return -ENOSYS;
}

/* ---- compat layer (§8.6.4) -------------------------------------------- */

static int compat_spawn(const char *call, const char *path,
			char *const argv[], char *const envp[])
{
	int c, rc, st = -1;
	unsigned gi = 0;
	char *const *e;

	ksp_log("spawn-compat: %s path=%s", call, path);
	c = ksp_reserve(path, 65536);
	if (c < 0) {
		ksp_log("spawn-compat: %s -> refused reserve %d", call, c);
		return c;
	}
	/* One grant for stdout (posix-inherit), one per envp entry. */
	{
		struct ksp_grant g = {
			.as = "fd/1", .from = "console", .verbs = "write",
			.value = "console", .across_exec = 0,
		};
		rc = ksp_grant(c, &g);
		if (rc) {
			ksp_abandon(c);
			return rc;
		}
		ksp_log("spawn-compat: %s grant as=fd/1 why=posix-inherit", call);
	}
	if (envp) {
		for (e = envp; *e && gi + 1 < KSP_MAX_GRANTS; e++) {
			char *eq = strchr(*e, '=');
			char asbuf[96];
			char namebuf[64];
			struct ksp_grant g;
			size_t nl;

			if (!eq)
				continue;
			nl = (size_t)(eq - *e);
			if (nl >= sizeof(namebuf))
				continue;
			memcpy(namebuf, *e, nl);
			namebuf[nl] = '\0';
			snprintf(asbuf, sizeof(asbuf), "env/%s", namebuf);
			/* Strings must outlive the child: strdup. */
			g.as = strdup(asbuf);
			g.from = strdup(namebuf);
			g.verbs = "read";
			g.value = strdup(eq + 1);
			g.across_exec = 0;
			rc = ksp_grant(c, &g);
			if (rc)
				break;
			ksp_log("spawn-compat: %s grant as=%s why=posix-inherit",
				call, asbuf);
			gi++;
		}
	}
	rc = ksp_seal(c);
	if (rc) {
		ksp_abandon(c);
		return rc;
	}
	rc = ksp_start(c);
	if (rc) {
		ksp_abandon(c);
		return rc;
	}
	rc = ksp_wait(c, &st);
	if (rc == 0)
		ksp_reap(c);
	(void)argv;
	return rc == 0 ? st : rc;
}

int ksp_compat_posix_spawn(const char *path, char *const argv[],
			   char *const envp[])
{
	return compat_spawn("posix_spawn", path, argv, envp);
}

int ksp_compat_vfork_execve(const char *path, char *const argv[],
			    char *const envp[])
{
	ksp_log("spawn-compat: vfork-window path=%s (vfork child is not yet a Spawn child; execve becomes reserve+grant+seal+start)",
		path);
	return compat_spawn("vfork+execve", path, argv, envp);
}

int ksp_compat_fork(void)
{
	ksp_log("spawn-compat: fork -> refused ENOSYS (F2)");
	return ksp_fork_refuse();
}

int ksp_compat_execve(const char *path, char *const argv[], char *const envp[])
{
	int c = ksp_active_child();

	(void)argv;
	(void)envp;
	ksp_log("spawn-compat: execve path=%s (maps to replace)", path);
	if (c == 0) {
		/* Outside a Spawn child: treat as a fresh spawn of self. */
		return compat_spawn("execve", path, argv, envp);
	}
	return ksp_replace(c, path);
}
