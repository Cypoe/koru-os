/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU: per-child page table derived from the Spawn rights bag.
 * Local in koru-os until Q33. Requires CONFIG_LIBUKPAGING + CONFIG_LIBUKVMEM. */
#ifndef KORUSPAWN_MMU_H
#define KORUSPAWN_MMU_H

#include <stddef.h>
#include <uk/arch/types.h>
#include <uk/paging.h>

struct uk_vas;

/* One memory/object grant that seal installs into the child PT. */
struct ksp_mem_grant {
	__vaddr_t va;		/* page-aligned */
	__sz len;		/* page multiple */
	__paddr_t pa;		/* UK_PAL_PADDR_INV = resolve from parent at derive */
	unsigned long attr;	/* UK_PAGING_PAGE_ATTR_PROT_* */
	int cow;		/* 1: shared RO until cow-break; AS-copy grant */
	unsigned gi;		/* bag index (for revoke/epoch) */
};

struct ksp_mmu_domain {
	struct uk_pagetable pt;
	struct uk_pagetable *parent_pt;
	int live;
	int active;		/* 1 if currently CR3-selected */
};

/* Derive child PT: clone parent, strip every parent VMA not covered by a
 * mem grant, install grants with the granted attrs (CoW => RO share). */
int ksp_mmu_derive(struct ksp_mmu_domain *d, struct uk_vas *parent_vas,
		   const struct ksp_mem_grant *grants, unsigned ngrants);

/* Switch CR3 to the child domain / back to the parent. */
int ksp_mmu_activate(struct ksp_mmu_domain *d);
int ksp_mmu_deactivate(struct ksp_mmu_domain *d);

/* Revoke one mem grant: unmap in child PT, TLB flush. */
int ksp_mmu_revoke(struct ksp_mmu_domain *d, const struct ksp_mem_grant *g);

/* CoW break: allocate a private frame, copy, map RW into child (attenuation
 * of a cow grant into a private writable page). */
int ksp_mmu_cow_break(struct ksp_mmu_domain *d, __vaddr_t va, __sz len);

/* Free child PT resources (frames of grants kept if KEEP was used). */
void ksp_mmu_destroy(struct ksp_mmu_domain *d);

/* Probe helpers for tests (wrap uk_nofault). */
__sz ksp_mmu_probe_r(__vaddr_t va, __sz len);
__sz ksp_mmu_probe_rw(__vaddr_t va, __sz len);

/* Parse verbs ("read", "read+write", "read+cow", "read+write+exec") -> attr+cow. */
int ksp_mmu_parse_verbs(const char *verbs, unsigned long *attr_out, int *cow_out);

/* True if `as` names a memory grant ("mem:0x..." or "obj:0x..."). */
int ksp_mmu_is_mem_as(const char *as);
int ksp_mmu_parse_mem_as(const char *as, __vaddr_t *va_out);

#endif /* KORUSPAWN_MMU_H */
