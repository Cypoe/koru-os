/* SPDX-License-Identifier: BSD-3-Clause */
/* M-SPAWN-MMU gaps 1–3: no parent heap/stack, always-on AS, sched CR3. */
#include <stdio.h>
#include <string.h>

#include <uk/essentials.h>
#include <uk/arch/ctx.h>
#include <uk/sched.h>
#include <uk/thread.h>
#include <uk/paging.h>
#include <uk/print.h>
#include <uk/vmem.h>
#include <uk/vmem/vma_types.h>

#include "mmu.h"

#define PG UK_PAGING_PAGE_SIZE
#define MAGIC_A "CHILD-A-SECRET-PAGE!!"
#define MAGIC_B "CHILD-B-SECRET-PAGE!!"

static int fails;
static volatile int thr_done[2];
static volatile int thr_ok[2];
static struct ksp_mmu_domain *thr_dom[2];
static __vaddr_t thr_secret[2];
static volatile unsigned stress_switches;

/* Domains in .bss (boot-mapped) — never on parent stack after CR3. */
static struct ksp_mmu_domain g_d0, g_d1;

static void say(const char *s)
{
	uk_pr_err("%s\n", s);
	fputs(s, stdout);
	fputc('\n', stdout);
}

static void expect(const char *name, int cond)
{
	char buf[160];

	snprintf(buf, sizeof(buf), "%s %s", cond ? "PASS" : "FAIL", name);
	say(buf);
	if (!cond)
		fails++;
}

static volatile int child_checks[8];
static volatile int child_nchecks;
static struct ksp_mmu_domain *wc_dom;
static void (*wc_fn)(struct ksp_mmu_domain *);
static volatile int wc_act_rc;
static __vaddr_t wc_saved_sp;

static void __attribute__((noinline)) wc_on_ambient(void)
{
	wc_act_rc = ksp_mmu_activate(wc_dom);
	if (wc_act_rc == 0) {
		wc_fn(wc_dom);
		(void)ksp_mmu_deactivate(wc_dom);
	}
}

static void with_child_as(struct ksp_mmu_domain *d,
			  void (*fn)(struct ksp_mmu_domain *))
{
	__vaddr_t asp;

	wc_dom = d;
	wc_fn = fn;
	wc_act_rc = -1;
	child_nchecks = 0;
	asp = ukarch_gen_sp((__uptr)d->stack_va, d->stack_len);
#if defined(__x86_64__)
	__asm__ volatile("mov %%rsp, %0" : "=r"(wc_saved_sp));
	__asm__ volatile("mov %0, %%rsp" : : "r"(asp) : "memory");
	wc_on_ambient();
	__asm__ volatile("mov %0, %%rsp" : : "r"(wc_saved_sp) : "memory");
#else
	(void)asp;
	wc_on_ambient();
#endif
	if (wc_act_rc != 0) {
		say("FAIL activate in with_child_as");
		fails++;
	}
}

static void child_expect(int idx, int cond)
{
	if (idx < 8)
		child_checks[idx] = cond ? 1 : 0;
	if (idx + 1 > child_nchecks)
		child_nchecks = idx + 1;
}

static __vaddr_t g_secret, g_allowed;

static void step_gap1_body(struct ksp_mmu_domain *d)
{
	__sz n;

	n = ksp_mmu_probe_r(d->parent_heap_va, 1);
	child_expect(0, n == 0);
	n = ksp_mmu_probe_r(g_secret, 1);
	child_expect(1, n == 0);
	n = ksp_mmu_probe_r(g_allowed, 8);
	child_expect(2, n >= 8);
	n = ksp_mmu_probe_rw(g_allowed, 1);
	child_expect(3, n == 0);
	n = ksp_mmu_probe_rw(d->heap_va, 1);
	child_expect(4, n >= 1);
}

static int gap1(struct uk_vas *vas)
{
	int rc;

	say("== gap1 no parent heap/stack ==");
	g_secret = UK_PAGING_VADDR_ANY;
	g_allowed = UK_PAGING_VADDR_ANY;
	rc = uk_vma_map_anon(vas, &g_secret, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			     UK_VMA_MAP_POPULATE, "mmu-secret");
	rc |= uk_vma_map_anon(vas, &g_allowed, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			      UK_VMA_MAP_POPULATE, "mmu-allowed");
	if (rc) {
		say("FAIL map");
		return -1;
	}
	memcpy((void *)g_allowed, "ALLOWED!", 8);

	{
		struct ksp_mem_grant g = {
			.va = g_allowed, .len = PG, .pa = UK_PAL_PADDR_INV,
			.attr = UK_PAGING_PAGE_ATTR_PROT_READ, .cow = 0, .gi = 0,
		};
		rc = ksp_mmu_derive(&g_d0, vas, &g, 1);
	}
	expect("gap1 derive (strips heap+stack)", rc == 0 && g_d0.parent_heap_va);
	if (rc)
		return -1;
	rc = ksp_mmu_provision_ambient(&g_d0, 64 * 1024, 64 * 1024);
	expect("gap1 provision ambient", rc == 0);
	if (rc)
		return -1;

	with_child_as(&g_d0, step_gap1_body);
	expect("gap1 fault: child cannot read parent heap", child_checks[0]);
	expect("gap1 fault: ungranted secret", child_checks[1]);
	expect("gap1 granted readable", child_checks[2]);
	expect("gap1 attenuation RO write faults", child_checks[3]);
	expect("gap1 own ambient heap writable", child_checks[4]);
	expect("gap1 parent secret intact after",
	       memcmp((void *)g_allowed, "ALLOWED!", 8) == 0);
	ksp_mmu_destroy(&g_d0);
	return 0;
}

static void gap2_body(struct ksp_mmu_domain *d)
{
	__sz n;

	n = ksp_mmu_probe_r(d->parent_heap_va, 1);
	child_expect(0, n == 0);
	n = ksp_mmu_probe_rw(d->stack_va + 0x100, 1);
	child_expect(1, n >= 1);
}

static int gap2(struct uk_vas *vas)
{
	int rc;

	say("== gap2 always-on AS (zero mem grants) ==");
	rc = ksp_mmu_derive(&g_d0, vas, NULL, 0);
	expect("gap2 derive empty bag", rc == 0);
	if (rc)
		return -1;
	rc = ksp_mmu_provision_ambient(&g_d0, 64 * 1024, 64 * 1024);
	expect("gap2 ambient", rc == 0);
	with_child_as(&g_d0, gap2_body);
	expect("gap2 zero-grant: parent heap fault", child_checks[0]);
	expect("gap2 zero-grant: own stack ok", child_checks[1]);
	ksp_mmu_destroy(&g_d0);
	return 0;
}

/*
 * Child threads run with CR3=child (arrive/activate). Unikraft's yield/exit
 * touch heap-backed uk_thread before the leave hook, so we drop to the parent
 * PT immediately before those calls; arrive() restores the child PT on resume.
 */
static void mmu_yield(struct ksp_mmu_domain *d)
{
	if (d && d->active)
		(void)ksp_mmu_deactivate(d);
	uk_sched_yield();
	/* arrive() re-activates if priv is set; belt-and-suspenders: */
	if (d && d->live && !d->active)
		(void)ksp_mmu_activate(d);
}

static void __noreturn mmu_exit(struct ksp_mmu_domain *d, int ok, int id)
{
	thr_ok[id] = ok;
	thr_done[id] = 1;
	if (d && d->active)
		(void)ksp_mmu_deactivate(d);
	ksp_mmu_bind_thread(uk_thread_current(), NULL);
	uk_sched_thread_exit();
}

static void __noreturn child_thr(void *arg);
static void __noreturn child_thr_entry(long arg)
{
	int id = (int)arg;
	struct ksp_mmu_domain *d = thr_dom[id];

	if (d && d->live && ksp_mmu_activate(d))
		mmu_exit(d, 0, id);
	child_thr((void *)arg);
}

static void __noreturn child_thr(void *arg)
{
	int id = (int)(long)arg;
	struct ksp_mmu_domain *d = thr_dom[id];
	__sz n;
	unsigned i;

	n = ksp_mmu_probe_r(thr_secret[id], sizeof(MAGIC_A));
	if (n < 8)
		mmu_exit(d, 0, id);
	n = ksp_mmu_probe_r(thr_secret[1 - id], 1);
	if (n != 0)
		mmu_exit(d, 0, id);
	n = ksp_mmu_probe_r(d->parent_heap_va, 1);
	if (n != 0)
		mmu_exit(d, 0, id);

	for (i = 0; i < 200; i++) {
		mmu_yield(d);
		stress_switches++;
		n = ksp_mmu_probe_r(thr_secret[1 - id], 1);
		if (n != 0)
			mmu_exit(d, 0, id);
		n = ksp_mmu_probe_r(thr_secret[id], 8);
		if (n < 8)
			mmu_exit(d, 0, id);
	}
	mmu_exit(d, 1, id);
}

static int gap3(struct uk_vas *vas)
{
	struct ksp_mem_grant g0, g1;
	__vaddr_t s0 = UK_PAGING_VADDR_ANY, s1 = UK_PAGING_VADDR_ANY;
	struct uk_thread *t0, *t1;
	int rc;
	unsigned spins;

	say("== gap3 sched CR3 multi-AS ==");
	rc = uk_vma_map_anon(vas, &s0, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			     UK_VMA_MAP_POPULATE, "sec-a");
	rc |= uk_vma_map_anon(vas, &s1, PG, UK_PAGING_PAGE_ATTR_PROT_RW,
			      UK_VMA_MAP_POPULATE, "sec-b");
	if (rc) {
		say("FAIL map secrets");
		return -1;
	}
	memcpy((void *)s0, MAGIC_A, sizeof(MAGIC_A));
	memcpy((void *)s1, MAGIC_B, sizeof(MAGIC_B));

	g0 = (struct ksp_mem_grant){ .va = s0, .len = PG, .pa = UK_PAL_PADDR_INV,
		.attr = UK_PAGING_PAGE_ATTR_PROT_READ, .gi = 0 };
	g1 = (struct ksp_mem_grant){ .va = s1, .len = PG, .pa = UK_PAL_PADDR_INV,
		.attr = UK_PAGING_PAGE_ATTR_PROT_READ, .gi = 0 };

	rc = ksp_mmu_derive(&g_d0, vas, &g0, 1);
	rc |= ksp_mmu_provision_ambient(&g_d0, 64 * 1024, 32 * 1024);
	expect("gap3 d0 ready", rc == 0);
	rc = ksp_mmu_derive(&g_d1, vas, &g1, 1);
	rc |= ksp_mmu_provision_ambient(&g_d1, 64 * 1024, 32 * 1024);
	expect("gap3 d1 ready", rc == 0);
	if (rc)
		return -1;

	thr_dom[0] = &g_d0;
	thr_dom[1] = &g_d1;
	thr_secret[0] = s0;
	thr_secret[1] = s1;
	thr_done[0] = thr_done[1] = 0;
	thr_ok[0] = thr_ok[1] = 0;
	stress_switches = 0;

	t0 = uk_sched_thread_create_fn1(uk_sched_current(), child_thr,
					(void *)(long)0, 0, 0, false, false,
					"mmu-a", NULL, NULL);
	t1 = uk_sched_thread_create_fn1(uk_sched_current(), child_thr,
					(void *)(long)1, 0, 0, false, false,
					"mmu-b", NULL, NULL);
	expect("gap3 create threads", t0 && t1);
	if (!t0 || !t1)
		return -1;

	ukarch_ctx_init_entry1(&t0->ctx,
			       ukarch_gen_sp((__uptr)g_d0.stack_va, g_d0.stack_len),
			       0, child_thr_entry, (long)0);
	ukarch_ctx_init_entry1(&t1->ctx,
			       ukarch_gen_sp((__uptr)g_d1.stack_va, g_d1.stack_len),
			       0, child_thr_entry, (long)1);
	t0->_mem.stack = (void *)g_d0.stack_va;
	t1->_mem.stack = (void *)g_d1.stack_va;
	ksp_mmu_bind_thread(t0, &g_d0);
	ksp_mmu_bind_thread(t1, &g_d1);

	uk_thread_wake(t0);
	uk_thread_wake(t1);

	for (spins = 0; spins < 100000 && !(thr_done[0] && thr_done[1]); spins++)
		uk_sched_yield();

	expect("gap3 both threads finished", thr_done[0] && thr_done[1]);
	expect("gap3 isolation A", thr_ok[0] == 1);
	expect("gap3 isolation B", thr_ok[1] == 1);
	expect("gap3 stress switches", stress_switches >= 100);
	{
		char buf[80];
		snprintf(buf, sizeof(buf), "gap3 stress_switches=%u", stress_switches);
		say(buf);
	}

	ksp_mmu_destroy(&g_d0);
	ksp_mmu_destroy(&g_d1);
	return 0;
}

int main(int argc __unused, char *argv[] __unused)
{
	struct uk_vas *vas = uk_vas_get_active();

	fails = 0;
	say("m-spawn-mmu: gaps 1-3 begin");
	if (!vas || !vas->pt) {
		say("FAIL no vas");
		return 1;
	}
	gap1(vas);
	gap2(vas);
	gap3(vas);
	if (fails) {
		say("M-SPAWN-MMU GAPS FAIL");
		return 1;
	}
	say("M-SPAWN-MMU GAPS PASS");
	return 0;
}
