/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU first measured step (DESIGN-0001 §8.6.7c):
 * per-child page table via uk_paging_pt_clone; ungranted secret faults;
 * explicit grant (remap same frame) restores access. TCG only. */
#include <stdio.h>
#include <string.h>

#include <uk/alloc.h>
#include <uk/arch/limits.h>
#include <uk/essentials.h>
#include <uk/nofault.h>
#include <uk/paging.h>
#include <uk/plat/console.h>
#include <uk/print.h>
#include <uk/vmem.h>
#include <uk/vmem/vma_types.h>

#define SECRET_LEN 0x1000UL
#define MAGIC "KORU-SPAWN-MMU-SECRET-v1"

static void say(const char *s)
{
	uk_pr_err("%s\n", s);
	fputs(s, stdout);
	fputc('\n', stdout);
}

static int pte_present(struct uk_pagetable *pt, __vaddr_t va)
{
	unsigned int lvl = UK_PAL_PAGE_LEVEL;
	__pte_t pte = 0;
	int rc = uk_paging_pt_walk(pt, va, &lvl, NULL, &pte);

	if (rc)
		return 0;
	return UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl) ? 1 : 0;
}

int main(int argc __unused, char *argv[] __unused)
{
	struct uk_vas *vas = uk_vas_get_active();
	struct uk_pagetable *pt_parent;
	struct uk_pagetable pt_child;
	__vaddr_t secret_va = UK_PAGING_VADDR_ANY;
	__paddr_t secret_pa = UK_PAL_PADDR_INV;
	unsigned int lvl;
	__pte_t pte;
	__sz n;
	int rc, fail = 0;
	char buf[64];

	say("m-spawn-mmu: begin");
	if (!vas) {
		say("FAIL no active vas");
		return 1;
	}
	pt_parent = vas->pt;
	if (!pt_parent) {
		say("FAIL no parent pt");
		return 1;
	}

	/* Parent: map one anonymous page, write a secret, force present. */
	rc = uk_vma_map_anon(vas, &secret_va, SECRET_LEN,
			     UK_PAGING_PAGE_ATTR_PROT_RW,
			     UK_VMA_MAP_POPULATE, "spawn-mmu-secret");
	if (rc) {
		snprintf(buf, sizeof(buf), "FAIL map_anon rc=%d", rc);
		say(buf);
		return 1;
	}
	memcpy((void *)secret_va, MAGIC, sizeof(MAGIC));
	snprintf(buf, sizeof(buf), "secret_va=0x%lx", (unsigned long)secret_va);
	say(buf);

	lvl = UK_PAL_PAGE_LEVEL;
	rc = uk_paging_pt_walk(pt_parent, secret_va, &lvl, NULL, &pte);
	if (rc || !UK_PAL_PT_Lx_PTE_PRESENT(pte, lvl)) {
		say("FAIL parent walk missing secret");
		return 1;
	}
	secret_pa = UK_PAL_PT_Lx_PTE_PADDR(pte, lvl);
	snprintf(buf, sizeof(buf), "secret_pa=0x%lx parent_present=1",
		 (unsigned long)secret_pa);
	say(buf);

	/* Dissected fork: clone parent PT (explicit AS copy of mappings). */
	memset(&pt_child, 0, sizeof(pt_child));
	rc = uk_paging_pt_clone(&pt_child, pt_parent, 0);
	if (rc) {
		snprintf(buf, sizeof(buf), "FAIL pt_clone rc=%d", rc);
		say(buf);
		return 1;
	}
	say("pt_clone ok (dissected fork AS copy is explicit here)");

	if (!pte_present(&pt_child, secret_va)) {
		say("FAIL child missing secret right after clone");
		fail = 1;
	} else {
		say("child_present_after_clone=1");
	}

	/* Default bag empty for this region: drop secret from child, keep frame. */
	rc = uk_paging_page_unmap(&pt_child, secret_va, 1,
				  UK_PAGING_PAGE_FLAG_KEEP_FRAMES |
				  UK_PAGING_PAGE_FLAG_FORCE_SIZE |
				  UK_PAGING_PAGE_FLAG_SIZE(UK_PAL_PAGE_LEVEL));
	if (rc) {
		snprintf(buf, sizeof(buf), "FAIL child unmap rc=%d", rc);
		say(buf);
		fail = 1;
	}
	if (pte_present(&pt_child, secret_va)) {
		say("FAIL child still present after unmap");
		fail = 1;
	} else {
		say("child_present_after_unmap=0");
	}
	if (!pte_present(pt_parent, secret_va)) {
		say("FAIL parent lost secret after child unmap");
		fail = 1;
	} else {
		say("parent_present_after_child_unmap=1");
	}

	/* Switch to child PT and probe — must fault (MMU enforce). */
	rc = uk_paging_pt_set_active(&pt_child);
	if (rc) {
		snprintf(buf, sizeof(buf), "FAIL pt_set_active(child) rc=%d", rc);
		say(buf);
		fail = 1;
		goto out_parent;
	}
	n = uk_nofault_probe_r(secret_va, SECRET_LEN, UK_NOFAULTF_NOPAGING);
	snprintf(buf, sizeof(buf), "child_nofault_bytes=%lu", (unsigned long)n);
	say(buf);
	if (n != 0) {
		say("FAIL child could read ungranted secret");
		fail = 1;
	} else {
		say("PASS fault-on-violation (ungranted secret)");
	}

	/* Explicit grant: map the same frame back into the child. */
	rc = uk_paging_page_map(&pt_child, secret_va, secret_pa, 1,
				UK_PAGING_PAGE_ATTR_PROT_READ,
				UK_PAGING_PAGE_FLAG_FORCE_SIZE |
				UK_PAGING_PAGE_FLAG_SIZE(UK_PAL_PAGE_LEVEL));
	if (rc) {
		snprintf(buf, sizeof(buf), "FAIL grant map rc=%d", rc);
		say(buf);
		fail = 1;
	} else {
		say("grant_map ok (explicit AS share of secret frame)");
	}
	n = uk_nofault_probe_r(secret_va, sizeof(MAGIC), UK_NOFAULTF_NOPAGING);
	snprintf(buf, sizeof(buf), "child_nofault_after_grant=%lu",
		 (unsigned long)n);
	say(buf);
	if (n < sizeof(MAGIC)) {
		say("FAIL grant did not restore child read");
		fail = 1;
	} else if (memcmp((void *)secret_va, MAGIC, sizeof(MAGIC)) != 0) {
		say("FAIL grant content mismatch");
		fail = 1;
	} else {
		say("PASS explicit grant readable");
	}

out_parent:
	rc = uk_paging_pt_set_active(pt_parent);
	if (rc) {
		snprintf(buf, sizeof(buf), "FAIL pt_set_active(parent) rc=%d", rc);
		say(buf);
		fail = 1;
	}
	n = uk_nofault_probe_r(secret_va, sizeof(MAGIC), UK_NOFAULTF_NOPAGING);
	if (n < sizeof(MAGIC) ||
	    memcmp((void *)secret_va, MAGIC, sizeof(MAGIC)) != 0) {
		say("FAIL parent secret damaged");
		fail = 1;
	} else {
		say("PASS parent secret intact");
	}

	/* Best-effort free of child PT pages (frames of secret kept by parent). */
	(void)uk_paging_pt_free(&pt_child, 0);

	if (fail) {
		say("M-SPAWN-MMU STEP1 FAIL");
		return 1;
	}
	say("M-SPAWN-MMU STEP1 PASS");
	return 0;
}
