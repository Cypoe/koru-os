/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU: bag→PT, private ambient heap/stack, sched CR3 (4b). */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <uk/essentials.h>
#include <uk/falloc.h>
#include <uk/list.h>
#if CONFIG_LIBUKNOFAULT
#include <uk/nofault.h>
#endif
#include <uk/paging.h>
#include <uk/print.h>
#include <uk/thread.h>
#include <uk/event.h>
#include <uk/lcpu/except.h>
#include <uk/vmem.h>
#include <uk/vmem/vma_types.h>

#include "mmu.h"
#include <signal.h>
#include <uk/plat/config.h>
#include <uk/arch/ctx.h>
#include <uk/lcpu.h>
#include <uk/lcpu/auxsp.h>
#include <uk/plat/pal/addr.h>
#if CONFIG_LIBSYSCALL_SHIM
#include <uk/syscall_entertab.h>
#include <uk/syscall_exittab.h>
#include <uk/prio.h>
#endif

#define PG UK_PAGING_PAGE_SIZE
#define FL_4K (UK_PAGING_PAGE_FLAG_FORCE_SIZE | \
	       UK_PAGING_PAGE_FLAG_SIZE(UK_PAL_PAGE_LEVEL))

/* High user VA for child-private ambient regions (below typical map base).
 * Each domain gets a unique slot so dual-map into the parent PT does not collide
 * when several children are live (gap3 / concurrent spawn). */
#define CHILD_STACK_BASE	((__vaddr_t)0x0000000ff0000000ULL)
#define CHILD_HEAP_BASE		((__vaddr_t)0x0000000fe0000000ULL)
#define CHILD_AS_STRIDE		((__vaddr_t)0x0000000001000000ULL) /* 16 MiB */

static struct uk_pagetable *g_parent_pt;
static struct ksp_mmu_domain *g_active_dom;
/* Authoritative child-context test: the hardware CR3. g_active_dom and the
 * sched/syscall counters are advisory; the exception hooks key off this. */
#define KSP_DOM_MAX 32
static struct ksp_mmu_domain *g_doms[KSP_DOM_MAX];
static unsigned g_ndoms;

static void dom_register(struct ksp_mmu_domain *d)
{
	unsigned i;

	for (i = 0; i < g_ndoms; i++)
		if (g_doms[i] == d)
			return;
	if (g_ndoms < KSP_DOM_MAX)
		g_doms[g_ndoms++] = d;
}

static void dom_unregister(struct ksp_mmu_domain *d)
{
	unsigned i;

	for (i = 0; i < g_ndoms; i++)
		if (g_doms[i] == d) {
			g_doms[i] = g_doms[--g_ndoms];
			return;
		}
}

static struct ksp_mmu_domain *dom_by_cr3(__paddr_t cr3)
{
	unsigned i;

	for (i = 0; i < g_ndoms; i++)
		if (g_doms[i]->live && g_doms[i]->pt.pt_pbase == cr3)
			return g_doms[i];
	return NULL;
}
static int ksp_mmu_nofault_depth;
void ksp_mmu_nofault_begin(void);
void ksp_mmu_nofault_end(void);
int ksp_mmu_strip_directmap(struct ksp_mmu_domain *d);
int ksp_mmu_strip_nonimage(struct ksp_mmu_domain *d);
long ksp_mmu_census(struct ksp_mmu_domain *d, const char *phase,
		    __vaddr_t *hits_out, unsigned *nhits_out);

static void mlog(const char *fmt, ...)
{
	char buf[256];
	va_list a;
	int n;

	va_start(a, fmt);
	n = vsnprintf(buf, sizeof(buf) - 1, fmt, a);
	va_end(a);
	if (n < 0)
		return;
	if (n >= (int)sizeof(buf) - 1)
		n = (int)sizeof(buf) - 2;
	buf[n++] = '\n';
	buf[n] = '\0';
	uk_pr_err("%s", buf);
	fputs(buf, stdout);
}

struct uk_pagetable *ksp_mmu_parent_pt(void)
{
	return g_parent_pt;
}

int ksp_mmu_parse_verbs(const char *verbs, unsigned long *attr_out, int *cow_out)
{
	unsigned long attr = UK_PAGING_PAGE_ATTR_PROT_NONE;
	int cow = 0;
	char buf[128];
	char *tok, *save;

	if (!verbs || !attr_out || !cow_out)
		return -EINVAL;
	strncpy(buf, verbs, sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = '\0';
	for (tok = strtok_r(buf, "+,", &save); tok; tok = strtok_r(NULL, "+,", &save)) {
		while (*tok == ' ')
			tok++;
		if (!strcmp(tok, "read") || !strcmp(tok, "r"))
			attr |= UK_PAGING_PAGE_ATTR_PROT_READ;
		else if (!strcmp(tok, "write") || !strcmp(tok, "w"))
			attr |= UK_PAGING_PAGE_ATTR_PROT_WRITE;
		else if (!strcmp(tok, "exec") || !strcmp(tok, "x"))
			attr |= UK_PAGING_PAGE_ATTR_PROT_EXEC;
		else if (!strcmp(tok, "cow"))
			cow = 1;
	}
	if (cow) {
		attr &= ~UK_PAGING_PAGE_ATTR_PROT_WRITE;
		attr |= UK_PAGING_PAGE_ATTR_PROT_READ;
	}
	if (attr == UK_PAGING_PAGE_ATTR_PROT_NONE)
		return -EINVAL;
	*attr_out = attr;
	*cow_out = cow;
	return 0;
}

int ksp_mmu_is_mem_as(const char *as)
{
	return as && (strncmp(as, "mem:", 4) == 0 || strncmp(as, "obj:", 4) == 0);
}

int ksp_mmu_parse_mem_as(const char *as, __vaddr_t *va_out)
{
	unsigned long v;

	if (!ksp_mmu_is_mem_as(as) || !va_out)
		return -EINVAL;
	v = strtoul(as + 4, NULL, 0);
	if (!v || (v & (PG - 1)))
		return -EINVAL;
	*va_out = (__vaddr_t)v;
	return 0;
}

static int grant_covers(const struct ksp_mem_grant *g, __vaddr_t va, __sz len)
{
	return g->va <= va && (g->va + g->len) >= (va + len);
}

static const struct ksp_mem_grant *
find_grant(const struct ksp_mem_grant *grants, unsigned n, __vaddr_t va)
{
	unsigned i;

	for (i = 0; i < n; i++)
		if (va >= grants[i].va && va < grants[i].va + grants[i].len)
			return &grants[i];
	return NULL;
}

static int unmap_range(struct uk_pagetable *pt, __vaddr_t va, __sz len)
{
	unsigned long pages = len / PG;

	if (!pages)
		return 0;
	return uk_paging_page_unmap(pt, va, pages,
				    UK_PAGING_PAGE_FLAG_KEEP_FRAMES | FL_4K);
}

static int map_pa(struct uk_pagetable *pt, __vaddr_t va, __paddr_t pa,
		  unsigned long pages, unsigned long attr)
{
	(void)unmap_range(pt, va, pages * PG);
	return uk_paging_page_map(pt, va, pa, pages, attr, FL_4K);
}

static int map_grant(struct uk_pagetable *pt, const struct ksp_mem_grant *g)
{
	return map_pa(pt, g->va, g->pa, g->len / PG, g->attr);
}

static int alloc_frames(struct uk_pagetable *pt, unsigned long pages,
			__paddr_t *pa_out)
{
	__paddr_t pa = UK_PAGING_PADDR_ANY;
	int rc;

	rc = pt->fa->falloc(pt->fa, &pa, pages, 0);
	if (rc)
		return -ENOMEM;
	*pa_out = pa;
	return 0;
}

int ksp_mmu_derive(struct ksp_mmu_domain *d, struct uk_vas *parent_vas,
		   const struct ksp_mem_grant *grants, unsigned ngrants)
{
	struct uk_pagetable *ppt;
	const struct uk_vma *vma;
	struct ksp_mem_grant local[8];
	unsigned i;
	int rc;

	if (!d || !parent_vas || !parent_vas->pt)
		return -EINVAL;
	if (ngrants > 8)
		return -ENOSPC;
	ppt = parent_vas->pt;
	memset(d, 0, sizeof(*d));
	d->parent_pt = ppt;
	d->parent_vas = parent_vas;
	g_parent_pt = ppt;

	if (ngrants)
		memcpy(local, grants, ngrants * sizeof(local[0]));
	for (i = 0; i < ngrants; i++) {
		unsigned int lvl;
		__pte_t pte;

		if (local[i].pa != UK_PAL_PADDR_INV)
			continue;
		lvl = UK_PAL_PAGE_LEVEL;
		rc = uk_paging_pt_walk(ppt, local[i].va, &lvl, NULL, &pte);
		if (rc || !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl)) {
			mlog("mmu: derive refuse grant va=0x%lx (not in parent)",
			     (unsigned long)local[i].va);
			return -EPERM;
		}
		local[i].pa = UK_PAL_PT_Lx_PTE_PADDR(pte, lvl);
	}
	grants = local;

	rc = uk_paging_pt_clone(&d->pt, ppt, 0);
	if (rc) {
		mlog("mmu: pt_clone rc=%d", rc);
		return rc;
	}
	mlog("mmu: pt_clone ok grants=%u (strip ALL parent VMAs incl heap/stack)",
	     ngrants);

	/* Record parent heap for fault tests; strip every parent VMA. */
	for (vma = uk_vma_first(parent_vas); vma; vma = uk_vma_next(vma)) {
		__vaddr_t va = vma->start;
		__sz len = vma->end - vma->start;
		const struct ksp_mem_grant *g;

		if (!len)
			continue;
		if (vma->name && strcmp(vma->name, "heap") == 0) {
			d->parent_heap_va = va;
			d->parent_heap_len = len;
			mlog("mmu: parent_heap va=0x%lx len=0x%lx (will unmap in child)",
			     (unsigned long)va, (unsigned long)len);
		}
		g = find_grant(grants, ngrants, va);
		if (g && grant_covers(g, va, len))
			continue;
		rc = unmap_range(&d->pt, va, len);
		mlog("mmu: strip va=0x%lx len=0x%lx name=%s rc=%d",
		     (unsigned long)va, (unsigned long)len,
		     vma->name ? vma->name : "-", rc);
	}

#if defined(__x86_64__)
	(void)ksp_mmu_strip_directmap(d);
	(void)ksp_mmu_strip_nonimage(d);
#endif
	for (i = 0; i < ngrants; i++) {
		rc = map_grant(&d->pt, &grants[i]);
		if (rc) {
			mlog("mmu: map grant va=0x%lx rc=%d",
			     (unsigned long)grants[i].va, rc);
			uk_paging_pt_free(&d->pt, UK_PAGING_PAGE_FLAG_KEEP_FRAMES);
			return rc;
		}
		ksp_mmu_declare(d, grants[i].va, grants[i].len, "grant");
		mlog("mmu: grant va=0x%lx len=0x%lx attr=0x%lx cow=%d gi=%u",
		     (unsigned long)grants[i].va, (unsigned long)grants[i].len,
		     (unsigned long)grants[i].attr, grants[i].cow, grants[i].gi);
	}

	d->live = 1;
#if defined(__x86_64__)
	rc = ksp_mmu_strip_directmap(d);
	if (rc) {
		mlog("mmu: directmap strip rc=%d (refuse)", rc);
		uk_paging_pt_free(&d->pt, UK_PAGING_PAGE_FLAG_KEEP_FRAMES);
		d->live = 0;
		return rc;
	}
	if (d->parent_heap_len &&
	    ksp_mmu_census(d, "derive", NULL, NULL) != 0) {
		mlog("mmu: derive refuse (parent-heap frame aliased in child PT)");
		uk_paging_pt_free(&d->pt, UK_PAGING_PAGE_FLAG_KEEP_FRAMES);
		d->live = 0;
		return -EPERM;
	}
#endif
	dom_register(d);
	mlog("mmu: derive done (no parent heap/stack/physmap in child PT)");
	return 0;
}

int ksp_mmu_provision_ambient(struct ksp_mmu_domain *d, __sz stack_len,
			      __sz heap_len)
{
	struct uk_vas *vas = uk_vas_get_active();
	unsigned long spages, hpages, i;
	__vaddr_t sva = UK_PAGING_VADDR_ANY, hva = UK_PAGING_VADDR_ANY;
	__paddr_t spa = UK_PAL_PADDR_INV, hpa = UK_PAL_PADDR_INV;
	int rc;

	if (!d || !d->live || !d->parent_pt || !vas)
		return -EINVAL;
	stack_len = (stack_len + PG - 1) & ~(PG - 1);
	heap_len = (heap_len + PG - 1) & ~(PG - 1);
	if (!stack_len)
		stack_len = 64 * 1024;
	if (!heap_len)
		heap_len = 64 * 1024;
	spages = stack_len / PG;
	hpages = heap_len / PG;

	/* Allocate in the parent VAS (normal vmem range) so ELF CRT/SP work. */
	rc = uk_vma_map_anon(vas, &sva, stack_len, UK_PAGING_PAGE_ATTR_PROT_RW,
			     UK_VMA_MAP_POPULATE, "child-ambient-stack");
	if (rc)
		return rc;
	rc = uk_vma_map_anon(vas, &hva, heap_len, UK_PAGING_PAGE_ATTR_PROT_RW,
			     UK_VMA_MAP_POPULATE, "child-ambient-heap");
	if (rc)
		return rc;

	/* Resolve first-page PAs (frames are contiguous from POPULATE buddy). */
	{
		unsigned int lvl = UK_PAL_PAGE_LEVEL;
		__pte_t pte;

		rc = uk_paging_pt_walk(d->parent_pt, sva, &lvl, NULL, &pte);
		if (rc || !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
			return -EFAULT;
		spa = UK_PAL_PT_Lx_PTE_PADDR(pte, lvl);
		lvl = UK_PAL_PAGE_LEVEL;
		rc = uk_paging_pt_walk(d->parent_pt, hva, &lvl, NULL, &pte);
		if (rc || !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
			return -EFAULT;
		hpa = UK_PAL_PT_Lx_PTE_PADDR(pte, lvl);
	}
	memset((void *)sva, 0, stack_len);
	memset((void *)hva, 0, heap_len);

	d->stack_va = sva;
	d->stack_len = stack_len;
	d->stack_pa = spa;
	d->heap_va = hva;
	d->heap_len = heap_len;
	d->heap_pa = hpa;

	/* Map each page into the child PT at the same VA (parent already has them). */
	for (i = 0; i < spages; i++) {
		unsigned int lvl = UK_PAL_PAGE_LEVEL;
		__pte_t pte;
		__vaddr_t va = sva + i * PG;

		if (uk_paging_pt_walk(d->parent_pt, va, &lvl, NULL, &pte) ||
		    !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
			return -EFAULT;
		rc = map_pa(&d->pt, va, UK_PAL_PT_Lx_PTE_PADDR(pte, lvl), 1,
			    UK_PAGING_PAGE_ATTR_PROT_RW);
		if (rc)
			return rc;
	}
	for (i = 0; i < hpages; i++) {
		unsigned int lvl = UK_PAL_PAGE_LEVEL;
		__pte_t pte;
		__vaddr_t va = hva + i * PG;

		if (uk_paging_pt_walk(d->parent_pt, va, &lvl, NULL, &pte) ||
		    !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
			return -EFAULT;
		rc = map_pa(&d->pt, va, UK_PAL_PT_Lx_PTE_PADDR(pte, lvl), 1,
			    UK_PAGING_PAGE_ATTR_PROT_RW);
		if (rc)
			return rc;
	}

	mlog("mmu: ambient stack va=0x%lx len=0x%lx pa=0x%lx",
	     (unsigned long)d->stack_va, (unsigned long)d->stack_len,
	     (unsigned long)d->stack_pa);
	mlog("mmu: ambient heap va=0x%lx len=0x%lx pa=0x%lx",
	     (unsigned long)d->heap_va, (unsigned long)d->heap_len,
	     (unsigned long)d->heap_pa);
	return 0;
}

int ksp_mmu_map_from_parent(struct ksp_mmu_domain *d, __vaddr_t va, __sz len,
			    unsigned long attr)
{
	struct uk_pagetable *ppt;
	__vaddr_t base;
	unsigned long pages, i, mapped = 0;

	if (!d || !d->live || !d->parent_pt || !len)
		return -EINVAL;
	ppt = d->parent_pt;
	base = va & ~(PG - 1);
	len = (len + (va - base) + PG - 1) & ~(PG - 1);
	pages = len / PG;
	for (i = 0; i < pages; i++) {
		__vaddr_t pva = base + i * PG;
		unsigned int lvl = UK_PAL_PAGE_LEVEL;
		__pte_t pte;

		if (uk_paging_pt_walk(ppt, pva, &lvl, NULL, &pte) ||
		    !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
			continue;
		if (map_pa(&d->pt, pva, UK_PAL_PT_Lx_PTE_PADDR(pte, lvl), 1,
			   attr) == 0)
			mapped++;
	}
	mlog("mmu: map_from_parent va=0x%lx pages=%lu mapped=%lu",
	     (unsigned long)base, pages, mapped);
	return mapped ? 0 : -EFAULT;
}

int ksp_mmu_activate(struct ksp_mmu_domain *d)
{
	int rc;

	if (!d || !d->live)
		return -EINVAL;
	{
		unsigned long irqf = uk_lcpu_save_irqf();

		/* Domain first: an exception between the two must see it. */
		g_active_dom = d;
		d->active = 1;
		rc = uk_paging_pt_set_active(&d->pt);
		if (rc) {
			d->active = 0;
			g_active_dom = NULL;
		}
		uk_paging_tlb_flush();
		uk_lcpu_restore_irqf(irqf);
	}
	return rc;
}

int ksp_mmu_deactivate(struct ksp_mmu_domain *d)
{
	int rc;

	if (!d || !d->live || !d->parent_pt)
		return -EINVAL;
	rc = uk_paging_pt_set_active(d->parent_pt);
	if (rc)
		return rc;
	d->active = 0;
	if (g_active_dom == d)
		g_active_dom = NULL;
	if (d->parent_vas)
		(void)uk_vas_set_active(d->parent_vas);
	uk_paging_tlb_flush();
	return 0;
}

void ksp_mmu_bind_thread(struct uk_thread *t, struct ksp_mmu_domain *d)
{
	if (!t)
		return;
	t->priv = d;
	mlog("mmu: bind thread=%p domain=%p", (void *)t, (void *)d);
}

void ksp_mmu_sched_switch(struct uk_thread *next)
{
	/* Leave child AS before heap ctx save/load. Current SP must be ambient
	 * (dual-mapped) or boot-mapped — never a parent-heap-only stack. */
	struct ksp_mmu_domain *d;

	(void)next;
	if (!g_parent_pt || !g_active_dom)
		return;
	d = g_active_dom;
	(void)uk_paging_pt_set_active(g_parent_pt);
	d->active = 0;
	g_active_dom = NULL;
	if (d->parent_vas)
		(void)uk_vas_set_active(d->parent_vas);
	uk_paging_tlb_flush();
}

void ksp_mmu_sched_arrive(void)
{
	struct uk_thread *t;
	struct ksp_mmu_domain *d;

	if (!g_parent_pt)
		return;
	t = uk_thread_current();
	if (!t)
		return;
	d = (struct ksp_mmu_domain *)t->priv;
	if (!d || !d->live)
		return;
	if (g_active_dom == d)
		return;
	/* Resumed inside a syscall (blocked, then rescheduled): the rest of
	 * the syscall, incl. signal delivery in the exit table, runs on the
	 * parent CR3; the syscall-exit hook enters the child CR3. */
	if (d->sys_left)
		return;
	(void)uk_paging_pt_set_active(&d->pt);
	if (g_active_dom)
		g_active_dom->active = 0;
	d->active = 1;
	g_active_dom = d;
	uk_paging_tlb_flush();
}

int ksp_mmu_revoke(struct ksp_mmu_domain *d, const struct ksp_mem_grant *g)
{
	int rc;

	if (!d || !d->live || !g)
		return -EINVAL;
	rc = unmap_range(&d->pt, g->va, g->len);
	uk_paging_tlb_flush();
	uk_paging_tlb_flush_entry(g->va);
	mlog("mmu: revoke va=0x%lx len=0x%lx gi=%u rc=%d",
	     (unsigned long)g->va, (unsigned long)g->len, g->gi, rc);
	return rc;
}

int ksp_mmu_cow_break(struct ksp_mmu_domain *d, __vaddr_t va, __sz len)
{
	struct uk_pagetable *pt;
	__paddr_t new_pa = UK_PAGING_PADDR_ANY;
	unsigned long pages;
	unsigned int lvl;
	__pte_t pte;
	__vaddr_t ksrc, kdst;
	int rc;

	if (!d || !d->live || !len || (va & (PG - 1)) || (len & (PG - 1)))
		return -EINVAL;
	pt = &d->pt;
	pages = len / PG;
	lvl = UK_PAL_PAGE_LEVEL;
	rc = uk_paging_pt_walk(pt, va, &lvl, NULL, &pte);
	if (rc || !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl))
		return -EFAULT;
	rc = pt->fa->falloc(pt->fa, &new_pa, pages, 0);
	if (rc)
		return -ENOMEM;
	ksrc = uk_paging_page_kmap(d->parent_pt ? d->parent_pt : pt,
				   UK_PAL_PT_Lx_PTE_PADDR(pte, lvl), pages, 0);
	kdst = uk_paging_page_kmap(pt, new_pa, pages, 0);
	if (ksrc == UK_PAGING_VADDR_INV || kdst == UK_PAGING_VADDR_INV) {
		pt->fa->ffree(pt->fa, new_pa, pages);
		return -ENOMEM;
	}
	memcpy((void *)kdst, (const void *)ksrc, len);
	uk_paging_page_kunmap(pt, kdst, pages, 0);
	uk_paging_page_kunmap(d->parent_pt ? d->parent_pt : pt, ksrc, pages, 0);
	(void)unmap_range(pt, va, len);
	rc = map_pa(pt, va, new_pa, pages, UK_PAGING_PAGE_ATTR_PROT_RW);
	uk_paging_tlb_flush_entry(va);
	mlog("mmu: cow_break va=0x%lx pages=%lu new_pa=0x%lx rc=%d",
	     (unsigned long)va, pages, (unsigned long)new_pa, rc);
	return rc;
}

void ksp_mmu_destroy(struct ksp_mmu_domain *d)
{
	if (!d || !d->live)
		return;
	if (d->active)
		(void)ksp_mmu_deactivate(d);
	dom_unregister(d);
	(void)uk_paging_pt_free(&d->pt, UK_PAGING_PAGE_FLAG_KEEP_FRAMES);
	d->live = 0;
	mlog("mmu: destroy child PT");
}

__sz ksp_mmu_probe_r(__vaddr_t va, __sz len)
{
#if CONFIG_LIBUKNOFAULT
	__sz n;

	ksp_mmu_nofault_begin();
	n = uk_nofault_probe_r(va, len, UK_NOFAULTF_NOPAGING);
	ksp_mmu_nofault_end();
	return n;
#else
	(void)va;
	(void)len;
	return 0;
#endif
}

__sz ksp_mmu_probe_rw(__vaddr_t va, __sz len)
{
#if CONFIG_LIBUKNOFAULT
	__sz n;

	ksp_mmu_nofault_begin();
	n = uk_nofault_probe_rw(va, len, UK_NOFAULTF_NOPAGING);
	ksp_mmu_nofault_end();
	return n;
#else
	(void)va;
	(void)len;
	return 0;
#endif
}

#if CONFIG_LIBSYSCALL_SHIM
/* Pair leave/restore per domain, not with a global counter: a child that
 * dies inside a syscall (e.g. SIGSEGV delivery from the fault stub) never
 * reaches the exit hook, and a global count would then leave every later
 * child on the parent CR3 after its first syscall. Restore only for the
 * bound thread whose domain was left on entry. */
static void ksp_mmu_syscall_enter(struct uk_syscall_enter_ctx *ctx)
{
	struct ksp_mmu_domain *d = NULL;
	__paddr_t cr3 = uk_paging_pt_read_base();

	(void)ctx;
	if (g_parent_pt && cr3 != g_parent_pt->pt_pbase)
		d = dom_by_cr3(cr3);
	if (d) {
		d->sys_left = 1;
		g_active_dom = d; /* so sched_switch performs the leave */
		ksp_mmu_sched_switch(NULL);
	}
}

static void ksp_mmu_syscall_exit(struct uk_syscall_exit_ctx *ctx)
{
	struct uk_thread *t = uk_thread_current();
	struct ksp_mmu_domain *d;

	(void)ctx;
	if (!t)
		return;
	d = (struct ksp_mmu_domain *)t->priv;
	if (d && d->live && d->sys_left) {
		d->sys_left = 0;
		ksp_mmu_sched_arrive();
	}
}

uk_syscall_entertab_prio(ksp_mmu_syscall_enter, UK_PRIO_EARLIEST);
uk_syscall_exittab_prio(ksp_mmu_syscall_exit, UK_PRIO_LATEST);
#endif /* CONFIG_LIBSYSCALL_SHIM */

#if CONFIG_LIBUKPAGING
/* ------------------------------------------------------------------------
 * Gap 2: direct-map (physmap) aliases.
 *
 * The parent PT maps all RAM at UK_PAL_DIRECTMAP_AREA_START (x86_64: the
 * whole top-level slot 511, -512 GiB). pt_clone deep-copies it, so a child
 * could reach any parent frame (heap included) at DM_BASE + pa. We drop the
 * slot from the child PT and free the copied subtree. All PT manipulation
 * runs on the parent CR3 (syscall/exception enter hooks leave first), so
 * nothing under the child CR3 needs the direct map.
 * ---------------------------------------------------------------------- */
#if defined(__x86_64__)
#define KSP_DM_BASE	((__vaddr_t)UK_PAL_DIRECTMAP_AREA_START)
#define X86_P		0x1ULL
#define X86_PS		0x80ULL
#define X86_ADDR	0x000ffffffffff000ULL
#define KSP_DM_TOPIDX	((unsigned)((KSP_DM_BASE >> 39) & 511))

static __vaddr_t canon(__vaddr_t v)
{
	return (v & (1ULL << 47)) ? (v | 0xffff000000000000ULL) : v;
}

static inline __u64 *dm_tbl(__paddr_t pa)
{
	return (__u64 *)(KSP_DM_BASE + pa);
}

/* lvl: 4=PML4 .. 1=PT (table level of the frame at `pa`). */
static unsigned long dm_free_tbl(struct uk_pagetable *pt, __paddr_t pa,
				 int lvl)
{
	__u64 *t = dm_tbl(pa);
	unsigned long n = 0;
	unsigned i;

	if (lvl > 1)
		for (i = 0; i < 512; i++) {
			__u64 e = t[i];

			if ((e & X86_P) && !(e & X86_PS))
				n += dm_free_tbl(pt, e & X86_ADDR, lvl - 1);
		}
	pt->fa->ffree(pt->fa, pa, 1);
	return n + 1;
}

int ksp_mmu_strip_directmap(struct ksp_mmu_domain *d)
{
	__u64 *top;
	__u64 e;
	unsigned long nfreed;

	if (!d || d->pt.pt_vbase == UK_PAL_VADDR_INV || !d->pt.pt_vbase)
		return -EINVAL;
	top = (__u64 *)d->pt.pt_vbase;
	e = top[KSP_DM_TOPIDX];
	if (!(e & X86_P)) {
		mlog("mmu: directmap slot=%u already absent in child PT",
		     KSP_DM_TOPIDX);
		return 0;
	}
	top[KSP_DM_TOPIDX] = 0;
	nfreed = dm_free_tbl(&d->pt, e & X86_ADDR, 3);
	d->dm_stripped = 1;
	mlog("mmu: directmap strip slot=%u base=0x%lx tables_freed=%lu (no physmap alias in child PT)",
	     KSP_DM_TOPIDX, (unsigned long)KSP_DM_BASE, nfreed);
	return 0;
}

/* After VMA strip, the child PT holds only pt_clone leftovers. Keep the
 * kernel image [_text, _end) (kernel-half: entry stubs, IDT/GDT/TSS,
 * exception stacks and per-CPU data live there) and clear every other leaf:
 * legacy/BIOS/VGA/ACPI identity ranges and the 1 TiB HT hole. Runs before
 * grants/ambient/metadata are mapped. Child tables are private copies. */
extern char _text[], _end[];

static unsigned long strip_nonimage(__paddr_t tbl, int lvl, __vaddr_t base,
				    __vaddr_t keep_lo, __vaddr_t keep_hi)
{
	__u64 *t = dm_tbl(tbl);
	__sz span = 1ULL << (12 + 9 * (lvl - 1));
	unsigned long n = 0;
	unsigned i;

	for (i = 0; i < 512; i++) {
		__u64 e = t[i];
		__vaddr_t va;

		if (!(e & X86_P))
			continue;
		va = (lvl == 4) ? canon((__vaddr_t)i << 39) : base + i * span;
		if (lvl == 4 && i == KSP_DM_TOPIDX)
			continue;	/* already removed */
		if (va >= keep_lo && va + (span - 1) < keep_hi)
			continue;	/* fully inside the image */
		if (lvl == 1 || (e & X86_PS)) {
			if (va + (span - 1) < keep_lo || va >= keep_hi) {
				t[i] = 0;
				n += span / PG;
			}
			/* a large leaf straddling the image is kept (none
			 * expected: the image is 4K-mapped) */
			continue;
		}
		n += strip_nonimage(e & X86_ADDR, lvl - 1, va, keep_lo,
				    keep_hi);
	}
	return n;
}

int ksp_mmu_strip_nonimage(struct ksp_mmu_domain *d)
{
	__vaddr_t lo = (__vaddr_t)_text & ~(PG - 1);
	__vaddr_t hi = ((__vaddr_t)_end + PG - 1) & ~(PG - 1);
	unsigned long n;

	n = strip_nonimage(d->pt.pt_pbase, 4, 0, lo, hi);
	mlog("mmu: strip non-image leftovers pages=%lu keep=[0x%lx,0x%lx) (kernel image only)",
	     n, (unsigned long)lo, (unsigned long)hi);
	return 0;
}

__vaddr_t ksp_mmu_dm_alias(__paddr_t pa)
{
	return KSP_DM_BASE + pa;
}

/* Raw leaf walker over a 4-level x86_64 table (read via the direct map,
 * i.e. only on the parent CR3). */
typedef void (*ksp_leaf_cb)(void *arg, __vaddr_t va, __paddr_t pa, __sz sz);

static void walk_leaves(__paddr_t tbl, int lvl, __vaddr_t base,
			__vaddr_t lo, __vaddr_t hi, ksp_leaf_cb cb, void *arg)
{
	__u64 *t = dm_tbl(tbl);
	__sz span = 1ULL << (12 + 9 * (lvl - 1));
	unsigned i;

	for (i = 0; i < 512; i++) {
		__u64 e = t[i];
		__vaddr_t va;

		if (!(e & X86_P))
			continue;
		va = (lvl == 4) ? canon((__vaddr_t)i << 39) : base + i * span;
		if (va + (span - 1) < lo || va > hi)
			continue;
		if (lvl == 1 || (e & X86_PS)) {
			cb(arg, va, (e & X86_ADDR) & ~((__u64)span - 1), span);
			continue;
		}
		walk_leaves(e & X86_ADDR, lvl - 1, va, lo, hi, cb, arg);
	}
}

#define KSP_MAXF	(1UL << 20) /* frames tracked: 4 GiB of RAM */
void ksp_mmu_declare(struct ksp_mmu_domain *d, __vaddr_t va, __sz len,
		     const char *label)
{
	if (!d || d->ndecl >= 16 || !len)
		return;
	d->decl[d->ndecl].va = va & ~(PG - 1);
	d->decl[d->ndecl].len = ((va & (PG - 1)) + len + PG - 1) & ~(PG - 1);
	d->decl[d->ndecl].label = label;
	d->ndecl++;
}

struct census {
	struct ksp_mmu_domain *d;
	unsigned long declared;
	unsigned char *bm;
	__vaddr_t lo, hi;
	unsigned long leaves, pages, hits, dm_leaves, untracked;
	__vaddr_t hit_va[16];
	unsigned nhit_va;
	__vaddr_t big_va[48];
	__paddr_t big_pa[48];
	__sz big_sz[48];
	unsigned nbig;
	unsigned long big_overflow;
};

static void cb_heap(void *arg, __vaddr_t va, __paddr_t pa, __sz sz)
{
	struct census *c = arg;
	__sz off;

	for (off = 0; off < sz; off += PG) {
		__paddr_t f = (pa + off) >> 12;

		if (va + off < c->lo || va + off > c->hi)
			continue;
		if (f < KSP_MAXF)
			c->bm[f >> 3] |= (unsigned char)(1u << (f & 7));
		else
			c->untracked++;
	}
}

static void cb_child(void *arg, __vaddr_t va, __paddr_t pa, __sz sz)
{
	struct census *c = arg;
	__sz off;

	c->leaves++;
	if (va >= KSP_DM_BASE)
		c->dm_leaves++;
	/* Coalesce VA/PA-contiguous leaves into ranges for the log. */
	if (c->nbig && c->big_va[c->nbig - 1] + c->big_sz[c->nbig - 1] == va &&
	    c->big_pa[c->nbig - 1] + c->big_sz[c->nbig - 1] == pa) {
		c->big_sz[c->nbig - 1] += sz;
	} else if (c->nbig < 48) {
		c->big_va[c->nbig] = va;
		c->big_pa[c->nbig] = pa;
		c->big_sz[c->nbig] = sz;
		c->nbig++;
	} else {
		c->big_overflow++;
	}
	for (off = 0; off < sz; off += PG) {
		__paddr_t f = (pa + off) >> 12;

		c->pages++;
		if (f < KSP_MAXF && (c->bm[f >> 3] & (1u << (f & 7)))) {
			unsigned k;
			int decl = 0;

			for (k = 0; k < c->d->ndecl; k++)
				if (va + off >= c->d->decl[k].va &&
				    va + off < c->d->decl[k].va +
					       c->d->decl[k].len) {
					decl = 1;
					break;
				}
			if (decl) {
				c->declared++;
				continue;
			}
			c->hits++;
			if (c->nhit_va < 16 &&
			    (!c->nhit_va ||
			     c->hit_va[c->nhit_va - 1] != va + off))
				c->hit_va[c->nhit_va++] = va + off;
		}
	}
}

/* Count child-PT leaf pages whose frame belongs to the parent heap VMA
 * (at any VA: heap VA, direct map, or any other alias). */
long ksp_mmu_census(struct ksp_mmu_domain *d, const char *phase,
		    __vaddr_t *hits_out, unsigned *nhits_out)
{
	struct census c;
	unsigned i;

	if (!d || !d->live || !d->parent_pt || !d->parent_heap_len)
		return -EINVAL;
	memset(&c, 0, sizeof(c));
	c.d = d;
	c.bm = calloc(KSP_MAXF / 8, 1);
	if (!c.bm)
		return -ENOMEM;
	c.lo = d->parent_heap_va;
	c.hi = d->parent_heap_va + d->parent_heap_len - 1;
	walk_leaves(d->parent_pt->pt_pbase, 4, 0, c.lo, c.hi, cb_heap, &c);
	c.lo = 0;
	c.hi = ~(__vaddr_t)0;
	walk_leaves(d->pt.pt_pbase, 4, 0, c.lo, c.hi, cb_child, &c);
	free(c.bm);
	mlog("mmu: census phase=%s child_leaves=%lu child_pages=%lu dm_leaves=%lu parent_heap_frames_declared=%lu parent_heap_frame_aliases_undeclared=%lu untracked=%lu",
	     phase, c.leaves, c.pages, c.dm_leaves, c.declared, c.hits,
	     c.untracked);
	if (!strcmp(phase, "derive") || !strcmp(phase, "gate")) {
		for (i = 0; i < c.nbig; i++)
			mlog("mmu: census phase=%s range va=0x%lx pa=0x%lx len=0x%lx",
			     phase, (unsigned long)c.big_va[i],
			     (unsigned long)c.big_pa[i],
			     (unsigned long)c.big_sz[i]);
		if (c.big_overflow)
			mlog("mmu: census phase=%s ranges_not_listed=%lu", phase,
			     c.big_overflow);
	}
	for (i = 0; i < d->ndecl; i++)
		mlog("mmu: census phase=%s declared va=0x%lx len=0x%lx what=%s",
		     phase, (unsigned long)d->decl[i].va,
		     (unsigned long)d->decl[i].len, d->decl[i].label);
	for (i = 0; i < c.nhit_va; i++)
		mlog("mmu: census phase=%s UNDECLARED alias va=0x%lx", phase,
		     (unsigned long)c.hit_va[i]);
	if (hits_out && nhits_out) {
		for (i = 0; i < c.nhit_va && i < *nhits_out; i++)
			hits_out[i] = c.hit_va[i];
		*nhits_out = i;
	}
	return (long)c.hits;
}
#endif /* __x86_64__ */

/* ------------------------------------------------------------------------
 * CR3 leave/restore around every exception and IRQ (patched dispatcher).
 * The previous event-handler pair was unsound: the IRQ controller handler
 * returns UK_EVENT_HANDLED, which stops the chain, so the LATEST "arrive"
 * never ran and the child resumed on the parent CR3 after any IRQ.
 * ---------------------------------------------------------------------- */
#define KSP_EXC_MAX 16
static struct ksp_mmu_domain *g_exc_stack[KSP_EXC_MAX];
static unsigned g_exc_depth;
static unsigned long g_exc_under_child;

void ksp_mmu_nofault_begin(void)
{
	ksp_mmu_nofault_depth++;
}

void ksp_mmu_nofault_end(void)
{
	if (ksp_mmu_nofault_depth)
		ksp_mmu_nofault_depth--;
}

unsigned long ksp_mmu_exc_under_child(void)
{
	return g_exc_under_child;
}

void uk_plat_native_except_enter_hook(void)
{
	struct ksp_mmu_domain *d = NULL;
	__paddr_t cr3 = uk_paging_pt_read_base();

	if (g_parent_pt && cr3 != g_parent_pt->pt_pbase)
		d = dom_by_cr3(cr3);
	if (g_exc_depth < KSP_EXC_MAX)
		g_exc_stack[g_exc_depth] = d;
	g_exc_depth++;
	if (d) {
		/* Handlers (vmem, timer, console) touch the parent heap, which
		 * is absent from the child PT: run them on the parent CR3. */
		g_exc_under_child++;
		(void)uk_paging_pt_set_active(g_parent_pt);
		if (g_active_dom == d) {
			g_active_dom = NULL;
			d->active = 0;
		}
		if (d->parent_vas)
			(void)uk_vas_set_active(d->parent_vas);
		uk_paging_tlb_flush();
	}
}

void uk_plat_native_except_exit_hook(void)
{
	struct ksp_mmu_domain *d = NULL;

	if (!g_exc_depth)
		return;
	g_exc_depth--;
	if (g_exc_depth < KSP_EXC_MAX) {
		d = g_exc_stack[g_exc_depth];
		g_exc_stack[g_exc_depth] = NULL;
	}
	if (d && d->live) {
		g_active_dom = d;
		d->active = 1;
		(void)uk_paging_pt_set_active(&d->pt);
		uk_paging_tlb_flush();
	}
}

/* ------------------------------------------------------------------------
 * Gap 3: child page fault on an ungranted address -> real SIGSEGV.
 *
 * A #PF taken under a Spawn child's CR3 from child context (not the aux
 * stack, not a uk_nofault probe) is an MMU domain violation. The handler
 * logs the reason, then returns into a kernel-text stub (mapped in every
 * child PT, executed on the child CR3) that issues a real
 * kill(getpid(), SIGSEGV) syscall. The stock posix-process exit path
 * (uk_signal_deliver) then applies the child's SIGSEGV disposition:
 * SIG_DFL terminates it (wait: WIFSIGNALED, WTERMSIG == SIGSEGV); an
 * installed handler runs on the child CR3. If the handler returns, the
 * faulting access cannot be retried meaningfully, so the stub follows with
 * SIGKILL. Stock Unikraft would instead UK_CRASH the whole image for a
 * SIG_DFL fault (sys_error_handler). Uses only exported syscalls.
 * ---------------------------------------------------------------------- */
#if defined(__x86_64__)
void ksp_mmu_segv_stub(void);
__asm__(
	".pushsection .text\n"
	".globl ksp_mmu_segv_stub\n"
	".type ksp_mmu_segv_stub,@function\n"
	"ksp_mmu_segv_stub:\n\t"
	"andq $-16, %rsp\n\t"
	"movl $39, %eax\n\t"		/* getpid */
	"syscall\n\t"
	"movl %eax, %edi\n\t"
	"pushq %rdi\n\t"
	"pushq %rdi\n\t"
	"movl $11, %esi\n\t"		/* SIGSEGV */
	"movl $62, %eax\n\t"		/* kill */
	"syscall\n\t"
	"popq %rdi\n\t"
	"popq %rdi\n\t"
	"movl $9, %esi\n\t"		/* handler returned: SIGKILL */
	"movl $62, %eax\n\t"
	"syscall\n\t"
	"movl $137, %edi\n\t"
	"movl $231, %eax\n\t"		/* exit_group */
	"syscall\n\t"
	"ud2\n"
	".size ksp_mmu_segv_stub, .-ksp_mmu_segv_stub\n"
	".popsection\n");

static unsigned long g_child_faults;

unsigned long ksp_mmu_child_faults(void)
{
	return g_child_faults;
}

static int ksp_mmu_pf_child(void *data)
{
	struct uk_lcpu_except_err_ctx *ctx = data;
	struct uk_lcpu_regs *regs;
	struct ksp_mmu_domain *d;
	__uptr auxsp, sp, ip;
	__vaddr_t va;
	__u64 ec;
	unsigned int lvl;
	__pte_t pte;
	int parent_mapped;
	const char *klass;

	if (!g_exc_depth || g_exc_depth > KSP_EXC_MAX)
		return UK_EVENT_NOT_HANDLED;
	d = g_exc_stack[g_exc_depth - 1];
	if (!d)
		return UK_EVENT_NOT_HANDLED;	/* not under a child CR3 */
	if (ksp_mmu_nofault_depth)
		return UK_EVENT_NOT_HANDLED;	/* probe: nofault fixes up */
	regs = (struct uk_lcpu_regs *)uk_lcpu_except_err_ctx_get_regs(ctx);
	auxsp = uk_pcpuvar_lval(uk_lcpu_get_current_idx_in_except(),
				UK_LCPU_AUXSP_SYM);
	sp = uk_lcpu_regs_get(regs, RSP);
	ip = uk_lcpu_regs_get(regs, RIP);
	va = (__vaddr_t)uk_lcpu_except_err_ctx_get_fault_addr(ctx);
	if (!auxsp || SP_IN_AUXSP(sp, auxsp) ||
	    ip == (__uptr)ksp_mmu_segv_stub) {
		/* Kernel context: fall through to the stock chain (which
		 * crashes loudly with its own report). */
		d->kfaults++;
		return UK_EVENT_NOT_HANDLED;
	}
	ec = uk_lcpu_x86_64_except_err_ctx_get_error_code(ctx);
	lvl = UK_PAL_PAGE_LEVEL;
	parent_mapped = (d->parent_pt &&
			 !uk_paging_pt_walk(d->parent_pt, va & ~(PG - 1), &lvl,
					    NULL, &pte) &&
			 UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl));
	klass = (va >= KSP_DM_BASE) ? "directmap-alias" :
		parent_mapped ? "parent-mapped-ungranted" : "unmapped";
	/* ISR-safe only: the child's TLS (%fs) is live here, so no printing,
	 * no uk_thread_current(). Record in the domain (.bss); ksp_wait logs
	 * the kill-with-reason line from normal context. */
	g_child_faults++;
	d->fault_va = va;
	d->fault_ip = ip;
	d->fault_ec = ec;
	d->fault_class = klass;
	d->faulted++;
	/* Resume the child (exit hook restores its CR3) in the stub. */
	uk_lcpu_regs_set(regs, RIP, (__uptr)ksp_mmu_segv_stub);
	return UK_EVENT_HANDLED;
}

UK_EVENT_HANDLER_PRIO(UK_LCPU_EXCEPT_EVENT_ERR_PAGE_FAULT, ksp_mmu_pf_child,
		      UK_PRIO_EARLIEST);
#endif /* __x86_64__ */
#endif /* CONFIG_LIBUKPAGING */
