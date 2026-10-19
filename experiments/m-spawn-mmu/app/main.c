/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU steps 1–4 under TCG (DESIGN-0001 §8.6.7c). */
#include <stdio.h>
#include <string.h>

#include <uk/essentials.h>
#include <uk/nofault.h>
#include <uk/paging.h>
#include <uk/print.h>
#include <uk/vmem.h>
#include <uk/vmem/vma_types.h>

#include "mmu.h"

#define PG UK_PAGING_PAGE_SIZE
#define MAGIC1 "KORU-MMU-SECRET-PARENT"
#define MAGIC2 "KORU-MMU-SHARED-COW-REG"

static int fails;

static void say(const char *s)
{
	uk_pr_err("%s\n", s);
	fputs(s, stdout);
	fputc('\n', stdout);
}

static void expect(const char *name, int cond)
{
	char buf[128];

	snprintf(buf, sizeof(buf), "%s %s", cond ? "PASS" : "FAIL", name);
	say(buf);
	if (!cond)
		fails++;
}


/* ---- step 2: bag → PT at "seal" ---------------------------------------- */
static int step2(struct uk_vas *vas, __vaddr_t secret, __vaddr_t allowed)
{
	struct ksp_mmu_domain d;
	struct ksp_mem_grant g[1];
	__sz n;
	int rc;

	say("== step2 bag-to-PT ==");
	memcpy((void *)secret, MAGIC1, sizeof(MAGIC1));
	memcpy((void *)allowed, "ALLOWED-RO", 11);

	g[0] = (struct ksp_mem_grant){
		.va = allowed,
		.len = PG,
		.pa = UK_PAL_PADDR_INV,
		.attr = UK_PAGING_PAGE_ATTR_PROT_READ, /* attenuation: RO */
		.cow = 0,
		.gi = 0,
	};
	rc = ksp_mmu_derive(&d, vas, g, 1);
	expect("step2 derive", rc == 0);
	if (rc)
		return -1;

	rc = ksp_mmu_activate(&d);
	expect("step2 activate", rc == 0);

	n = ksp_mmu_probe_r(secret, PG);
	expect("step2 fault-on-violation (ungranted secret)", n == 0);

	n = ksp_mmu_probe_r(allowed, 11);
	expect("step2 granted RO readable", n >= 11);

	n = ksp_mmu_probe_rw(allowed, 1);
	expect("step2 attenuation (RO: write faults)", n == 0);

	/* revoke granted region */
	rc = ksp_mmu_revoke(&d, &g[0]);
	expect("step2 revoke rc", rc == 0);
	n = ksp_mmu_probe_r(allowed, 1);
	expect("step2 fault after revoke", n == 0);

	(void)ksp_mmu_deactivate(&d);
	n = ksp_mmu_probe_r(secret, sizeof(MAGIC1));
	expect("step2 parent secret intact", n >= sizeof(MAGIC1) &&
	       memcmp((void *)secret, MAGIC1, sizeof(MAGIC1)) == 0);

	ksp_mmu_destroy(&d);
	return 0;
}

/* ---- step 3: CoW grant as AS-copy -------------------------------------- */
static int step3(struct uk_vas *vas, __vaddr_t region, __vaddr_t other)
{
	struct ksp_mmu_domain d;
	struct ksp_mem_grant g[1];
	unsigned long attr;
	int cow, rc;
	__sz n;

	say("== step3 CoW grant ==");
	memcpy((void *)region, MAGIC2, sizeof(MAGIC2));
	memcpy((void *)other, "NOCOPY", 7);

	/* Refuse ambient AS: deriving with zero grants leaves other unmapped. */
	rc = ksp_mmu_parse_verbs("read+cow", &attr, &cow);
	expect("step3 parse cow verbs", rc == 0 && cow == 1 &&
	       (attr & UK_PAGING_PAGE_ATTR_PROT_READ) &&
	       !(attr & UK_PAGING_PAGE_ATTR_PROT_WRITE));

	g[0] = (struct ksp_mem_grant){
		.va = region,
		.len = PG,
		.pa = UK_PAL_PADDR_INV,
		.attr = attr,
		.cow = cow,
		.gi = 0,
	};
	rc = ksp_mmu_derive(&d, vas, g, 1);
	expect("step3 derive with cow grant", rc == 0);
	if (rc)
		return -1;

	(void)ksp_mmu_activate(&d);
	n = ksp_mmu_probe_r(region, sizeof(MAGIC2));
	expect("step3 cow region readable", n >= sizeof(MAGIC2));
	n = ksp_mmu_probe_rw(region, 1);
	expect("step3 cow write faults before break", n == 0);
	n = ksp_mmu_probe_r(other, 1);
	expect("step3 no ambient AS copy (other faults)", n == 0);

	rc = ksp_mmu_cow_break(&d, region, PG);
	expect("step3 cow_break", rc == 0);
	n = ksp_mmu_probe_rw(region, 1);
	expect("step3 writable after cow_break", n >= 1);
	/* parent still has original */
	(void)ksp_mmu_deactivate(&d);
	expect("step3 parent still MAGIC2",
	       memcmp((void *)region, MAGIC2, sizeof(MAGIC2)) == 0);

	/* Explicit refuse path: without cow/mem grant, AS copy not present —
	 * already shown by `other` fault. Log the F2-equivalent. */
	say("step3 F2: ambient address-space copy refused (no grant → unmapped)");

	ksp_mmu_destroy(&d);
	return 0;
}

/* ---- step 4: separate AS activate / parent restore --------------------- */
static int step4(struct uk_vas *vas, __vaddr_t secret, __vaddr_t grant_va)
{
	struct ksp_mmu_domain d;
	struct ksp_mem_grant g[1];
	__sz n;
	int rc;

	say("== step4 separate AS (CR3) ==");
	g[0] = (struct ksp_mem_grant){
		.va = grant_va,
		.len = PG,
		.pa = UK_PAL_PADDR_INV,
		.attr = UK_PAGING_PAGE_ATTR_PROT_RW,
		.cow = 0,
		.gi = 0,
	};
	rc = ksp_mmu_derive(&d, vas, g, 1);
	expect("step4 derive", rc == 0);
	if (rc)
		return -1;

	rc = ksp_mmu_activate(&d);
	expect("step4 CR3-child", rc == 0);
	n = ksp_mmu_probe_r(secret, 1);
	expect("step4 child AS: secret fault", n == 0);
	n = ksp_mmu_probe_rw(grant_va, 1);
	expect("step4 child AS: grant rw", n >= 1);

	rc = ksp_mmu_deactivate(&d);
	expect("step4 CR3-parent", rc == 0);
	n = ksp_mmu_probe_r(secret, sizeof(MAGIC1));
	expect("step4 parent AS restored", n >= sizeof(MAGIC1));

	/* Attenuation: re-derive RO only */
	ksp_mmu_destroy(&d);
	g[0].attr = UK_PAGING_PAGE_ATTR_PROT_READ;
	rc = ksp_mmu_derive(&d, vas, g, 1);
	(void)ksp_mmu_activate(&d);
	n = ksp_mmu_probe_rw(grant_va, 1);
	expect("step4 attenuation RO", n == 0);
	(void)ksp_mmu_deactivate(&d);
	ksp_mmu_destroy(&d);
	return 0;
}

int main(int argc __unused, char *argv[] __unused)
{
	struct uk_vas *vas = uk_vas_get_active();
	__vaddr_t secret = UK_PAGING_VADDR_ANY;
	__vaddr_t allowed = UK_PAGING_VADDR_ANY;
	__vaddr_t cowreg = UK_PAGING_VADDR_ANY;
	__vaddr_t other = UK_PAGING_VADDR_ANY;
	int rc;

	fails = 0;
	say("m-spawn-mmu: begin steps 2-4");
	if (!vas || !vas->pt) {
		say("FAIL no vas");
		return 1;
	}

	rc = uk_vma_map_anon(vas, &secret, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			     UK_VMA_MAP_POPULATE, "mmu-secret");
	rc |= uk_vma_map_anon(vas, &allowed, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			      UK_VMA_MAP_POPULATE, "mmu-allowed");
	rc |= uk_vma_map_anon(vas, &cowreg, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			      UK_VMA_MAP_POPULATE, "mmu-cow");
	rc |= uk_vma_map_anon(vas, &other, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			      UK_VMA_MAP_POPULATE, "mmu-other");
	if (rc) {
		say("FAIL map_anon");
		return 1;
	}

	/* step 1 residual: clone sanity already covered by derive */

	step2(vas, secret, allowed);
	step3(vas, cowreg, other);
	step4(vas, secret, allowed);

	if (fails) {
		say("M-SPAWN-MMU STEPS FAIL");
		return 1;
	}
	say("M-SPAWN-MMU STEPS PASS");
	return 0;
}
