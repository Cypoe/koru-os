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
#include <uk/vmem.h>
#include <uk/vmem/vma_types.h>

#include "mmu.h"
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
static unsigned g_ambient_slot;

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

	for (i = 0; i < ngrants; i++) {
		rc = map_grant(&d->pt, &grants[i]);
		if (rc) {
			mlog("mmu: map grant va=0x%lx rc=%d",
			     (unsigned long)grants[i].va, rc);
			uk_paging_pt_free(&d->pt, UK_PAGING_PAGE_FLAG_KEEP_FRAMES);
			return rc;
		}
		mlog("mmu: grant va=0x%lx len=0x%lx attr=0x%lx cow=%d gi=%u",
		     (unsigned long)grants[i].va, (unsigned long)grants[i].len,
		     (unsigned long)grants[i].attr, grants[i].cow, grants[i].gi);
	}

	d->live = 1;
	mlog("mmu: derive done (no parent heap/stack in child PT)");
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
	rc = uk_paging_pt_set_active(&d->pt);
	if (rc)
		return rc;
	d->active = 1;
	g_active_dom = d;
	uk_paging_tlb_flush();
	/* no mlog here: CR3 is child; libc/heap may be unmapped */
	return 0;
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
	(void)next;
	if (!g_parent_pt || !g_active_dom)
		return;
	(void)uk_paging_pt_set_active(g_parent_pt);
	g_active_dom->active = 0;
	g_active_dom = NULL;
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
	(void)uk_paging_pt_free(&d->pt, UK_PAGING_PAGE_FLAG_KEEP_FRAMES);
	d->live = 0;
	mlog("mmu: destroy child PT");
}

__sz ksp_mmu_probe_r(__vaddr_t va, __sz len)
{
#if CONFIG_LIBUKNOFAULT
	return uk_nofault_probe_r(va, len, UK_NOFAULTF_NOPAGING);
#else
	(void)va;
	(void)len;
	return 0;
#endif
}

__sz ksp_mmu_probe_rw(__vaddr_t va, __sz len)
{
#if CONFIG_LIBUKNOFAULT
	return uk_nofault_probe_rw(va, len, UK_NOFAULTF_NOPAGING);
#else
	(void)va;
	(void)len;
	return 0;
#endif
}

#if CONFIG_LIBSYSCALL_SHIM
/* Pair leave/restore only when the syscall interrupted a live child AS.
 * Do not call arrive() unbound — that would CR3-switch a thread that only
 * has priv set (bind) but was still on the parent PT. */
static unsigned ksp_mmu_sys_left;

static void ksp_mmu_syscall_enter(struct uk_syscall_enter_ctx *ctx)
{
	(void)ctx;
	if (g_active_dom) {
		ksp_mmu_sched_switch(NULL);
		ksp_mmu_sys_left++;
	}
}

static void ksp_mmu_syscall_exit(struct uk_syscall_exit_ctx *ctx)
{
	(void)ctx;
	if (ksp_mmu_sys_left) {
		ksp_mmu_sys_left--;
		if (!ksp_mmu_sys_left)
			ksp_mmu_sched_arrive();
	}
}

uk_syscall_entertab_prio(ksp_mmu_syscall_enter, UK_PRIO_EARLIEST);
uk_syscall_exittab_prio(ksp_mmu_syscall_exit, UK_PRIO_LATEST);
#endif /* CONFIG_LIBSYSCALL_SHIM */

