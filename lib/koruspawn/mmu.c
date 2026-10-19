/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU bag → per-child page table (DESIGN-0001 §8.6.7c). */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <uk/essentials.h>
#include <uk/list.h>
#if CONFIG_LIBUKNOFAULT
#include <uk/nofault.h>
#endif
#include <uk/paging.h>
#include <uk/falloc.h>
#include <uk/print.h>
#include <uk/vmem.h>

#include "mmu.h"

#define PG UK_PAGING_PAGE_SIZE
#define FL_4K (UK_PAGING_PAGE_FLAG_FORCE_SIZE | \
	       UK_PAGING_PAGE_FLAG_SIZE(UK_PAL_PAGE_LEVEL))

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
		while (*tok == ' ') tok++;
		if (!strcmp(tok, "read") || !strcmp(tok, "r"))
			attr |= UK_PAGING_PAGE_ATTR_PROT_READ;
		else if (!strcmp(tok, "write") || !strcmp(tok, "w"))
			attr |= UK_PAGING_PAGE_ATTR_PROT_WRITE;
		else if (!strcmp(tok, "exec") || !strcmp(tok, "x"))
			attr |= UK_PAGING_PAGE_ATTR_PROT_EXEC;
		else if (!strcmp(tok, "cow"))
			cow = 1;
	}
	/* CoW is an AS-copy grant: shared RO until cow_break. */
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

static int map_grant(struct uk_pagetable *pt, const struct ksp_mem_grant *g)
{
	unsigned long pages = g->len / PG;
	unsigned long attr = g->attr;
	__paddr_t pa = g->pa;
	int rc;

	if (!pages || (g->va & (PG - 1)) || (g->len & (PG - 1)))
		return -EINVAL;
	if (pa == UK_PAL_PADDR_INV)
		return -EINVAL;
	/* Ensure not present first (clone may have had different attrs). */
	(void)unmap_range(pt, g->va, g->len);
	rc = uk_paging_page_map(pt, g->va, pa, pages, attr, FL_4K);
	return rc;
}

int ksp_mmu_derive(struct ksp_mmu_domain *d, struct uk_vas *parent_vas,
		   const struct ksp_mem_grant *grants, unsigned ngrants)
{
	struct uk_pagetable *ppt;
	const struct uk_vma *vma;
	unsigned i;
	int rc;

	if (!d || !parent_vas || !parent_vas->pt)
		return -EINVAL;
	ppt = parent_vas->pt;
	memset(d, 0, sizeof(*d));
	d->parent_pt = ppt;

	/* Work on a mutable copy so we can fill INV physical addresses. */
	struct ksp_mem_grant local[8];
	if (ngrants > 8)
		return -ENOSPC;
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
	mlog("mmu: pt_clone ok grants=%u", ngrants);

	/* Strip every parent VMA from the child unless a mem grant covers it.
	 * Keep heap + the VMA that holds the current stack (CR3 switch must
	 * not unmap the caller's stack). */
	{
		__vaddr_t sp_now;
#if defined(__x86_64__)
		__asm__ volatile("mov %%rsp, %0" : "=r"(sp_now));
#else
		sp_now = 0;
#endif
	for (vma = uk_vma_first(parent_vas); vma; vma = uk_vma_next(vma)) {
		__vaddr_t va = vma->start;
		__sz len = vma->end - vma->start;
		const struct ksp_mem_grant *g;

		if (!len)
			continue;
		if (vma->name && strcmp(vma->name, "heap") == 0)
			continue;
		if (sp_now && va <= sp_now && sp_now < va + len) {
			mlog("mmu: keep stack vma va=0x%lx len=0x%lx",
			     (unsigned long)va, (unsigned long)len);
			continue;
		}
		g = find_grant(grants, ngrants, va);
		if (g && grant_covers(g, va, len))
			continue;
		rc = unmap_range(&d->pt, va, len);
		if (rc) {
			mlog("mmu: strip va=0x%lx len=0x%lx rc=%d",
			     (unsigned long)va, (unsigned long)len, rc);
			/* continue: some VMAs may not be fully present */
		} else {
			mlog("mmu: strip va=0x%lx len=0x%lx name=%s",
			     (unsigned long)va, (unsigned long)len,
			     vma->name ? vma->name : "-");
		}
	}

	}

	/* Install each grant with attenuated permission. */
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
	mlog("mmu: derive done (seal-child PT from bag)");
	return 0;
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
	uk_paging_tlb_flush();
	mlog("mmu: activate child PT (CR3 switch)");
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
	uk_paging_tlb_flush();
	mlog("mmu: deactivate → parent PT");
	return 0;
}

int ksp_mmu_revoke(struct ksp_mmu_domain *d, const struct ksp_mem_grant *g)
{
	int rc;

	if (!d || !d->live || !g)
		return -EINVAL;
	rc = unmap_range(&d->pt, g->va, g->len);
	uk_paging_tlb_flush();
	uk_paging_tlb_flush_entry(g->va);
	mlog("mmu: revoke va=0x%lx len=0x%lx tlb_flush gi=%u rc=%d",
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
	rc = uk_paging_page_map(pt, va, new_pa, pages,
				UK_PAGING_PAGE_ATTR_PROT_RW, FL_4K);
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
	(void)va; (void)len;
	return 0;
#endif
}

__sz ksp_mmu_probe_rw(__vaddr_t va, __sz len)
{
#if CONFIG_LIBUKNOFAULT
	return uk_nofault_probe_rw(va, len, UK_NOFAULTF_NOPAGING);
#else
	(void)va; (void)len;
	return 0;
#endif
}
