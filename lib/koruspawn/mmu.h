/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU: per-child page table from the Spawn bag. Local until Q33. */
#ifndef KORUSPAWN_MMU_H
#define KORUSPAWN_MMU_H

#include <stddef.h>
#include <uk/arch/types.h>
#include <uk/paging.h>

struct uk_vas;
struct uk_thread;

struct ksp_mem_grant {
	__vaddr_t va;
	__sz len;
	__paddr_t pa;		/* INV = resolve from parent at derive */
	unsigned long attr;
	int cow;
	unsigned gi;
};

struct ksp_mmu_domain {
	struct uk_pagetable pt;
	struct uk_pagetable *parent_pt;
	struct uk_vas *parent_vas;
	int live;
	int active;
	/* Child-private ambient regions (not parent heap/stack). */
	__vaddr_t stack_va;
	__sz stack_len;
	__paddr_t stack_pa;
	__vaddr_t heap_va;
	__sz heap_len;
	__paddr_t heap_pa;
	/* Parent heap VA range (for fault-on-violation tests). */
	__vaddr_t parent_heap_va;
	__sz parent_heap_len;
	int dm_stripped;
	int sys_left;
	/* Gap 3: last MMU violation (recorded ISR-safe in the PF handler). */
	unsigned faulted, kfaults;
	__vaddr_t fault_va;
	unsigned long fault_ip, fault_ec;
	const char *fault_class;	/* syscall entered from this domain's CR3 */
	/* Declared parent-heap pages the child may see: grants and kernel-half
	 * metadata (thread/uktls/ectx/auxsp). Census reports anything else. */
	struct { __vaddr_t va; __sz len; const char *label; } decl[16];
	unsigned ndecl;
};

int ksp_mmu_derive(struct ksp_mmu_domain *d, struct uk_vas *parent_vas,
		   const struct ksp_mem_grant *grants, unsigned ngrants);

/* Allocate private stack+heap frames (from `budget`), map into child PT and
 * also into the parent PT at the same VAs so the caller can pivot SP before
 * CR3 switch. */
int ksp_mmu_provision_ambient(struct ksp_mmu_domain *d, __sz stack_len,
			      __sz heap_len);

/* Map an existing parent-present range into the child PT (ELF, etc.). */
int ksp_mmu_map_from_parent(struct ksp_mmu_domain *d, __vaddr_t va, __sz len,
			    unsigned long attr);

int ksp_mmu_activate(struct ksp_mmu_domain *d);
int ksp_mmu_deactivate(struct ksp_mmu_domain *d);
int ksp_mmu_revoke(struct ksp_mmu_domain *d, const struct ksp_mem_grant *g);
int ksp_mmu_cow_break(struct ksp_mmu_domain *d, __vaddr_t va, __sz len);
void ksp_mmu_destroy(struct ksp_mmu_domain *d);

/* Bind a thread to a domain for always-on sched CR3 switch (4b). NULL = parent. */
void ksp_mmu_bind_thread(struct uk_thread *t, struct ksp_mmu_domain *d);
/* Before ctx_switch: drop to parent PT so heap-backed thread ctx is reachable.
 * After ctx_switch (on resume): enter next thread's PT. First entry of a new
 * thread must also call ksp_mmu_activate (see child entry stubs). */
void ksp_mmu_sched_switch(struct uk_thread *next);
void ksp_mmu_sched_arrive(void);
void ksp_mmu_nofault_begin(void);
void ksp_mmu_nofault_end(void);

__sz ksp_mmu_probe_r(__vaddr_t va, __sz len);
__sz ksp_mmu_probe_rw(__vaddr_t va, __sz len);
int ksp_mmu_parse_verbs(const char *verbs, unsigned long *attr_out, int *cow_out);
int ksp_mmu_is_mem_as(const char *as);
int ksp_mmu_parse_mem_as(const char *as, __vaddr_t *va_out);

struct uk_pagetable *ksp_mmu_parent_pt(void);

/* Gap 2: drop the direct map (physmap) from the child PT; DM alias of a PA. */
int ksp_mmu_strip_directmap(struct ksp_mmu_domain *d);
__vaddr_t ksp_mmu_dm_alias(__paddr_t pa);
/* Count child-PT pages whose frame is a parent-heap frame (any VA). */
long ksp_mmu_census(struct ksp_mmu_domain *d, const char *phase,
		    __vaddr_t *hits_out, unsigned *nhits_out);
unsigned long ksp_mmu_exc_under_child(void);
unsigned long ksp_mmu_child_faults(void);
void ksp_mmu_declare(struct ksp_mmu_domain *d, __vaddr_t va, __sz len,
		     const char *label);


#endif
