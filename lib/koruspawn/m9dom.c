/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M-SPAWN-MMU R1: per-process domains for app-elfloader execve (M9).
 *
 * Policy: an execve whose envp carries KORU_CHILD_ROLE=foot (injected by the
 * parent's hyprland.children grant, experiments/m9-hyprland/spawn-compat) gets
 * its own protection domain. The marker can only ask for MORE isolation; a
 * thread already bound to a domain keeps it across execve (no escape by exec).
 *
 * Ownership: every VMA mapped by a bound thread (ukvmem owner hooks, patch
 * unikraft-0.21-vmem-owner-hooks.patch) is recorded in the domain ledger; unmap
 * and set_attr edit it. Attribution is by current thread, so the parent's
 * (Hyprland's) mappings are never recorded.
 *
 * Step 2 = shadow mode: domain + child PT + ledger are live, CR3 is never
 * activated (activation needs the step-3 fault resolver: ukvmem demand-pages,
 * so a fresh owned page is not yet present in any PT).
 */
#include <errno.h>
#include <string.h>
#include <uk/essentials.h>
#include <uk/print.h>
#include <uk/thread.h>
#include <uk/vmem.h>
#include <uk/arch/ctx.h>
#include "mmu.h"

#define M9_MAX_DOMS	4
#define M9_MAX_OWN	1024
#define M9_LOG_CAP	700	/* per-mapping log lines (evidence), then summary only */

struct m9_own {
	__vaddr_t va;
	__sz len;
	unsigned long attr;
	char name[24];
};

struct m9_dom {
	struct ksp_mmu_domain mmu;	/* first: (void *) handle == &mmu */
	int used;
	int id;
	char path[64];
	struct m9_own own[M9_MAX_OWN];
	unsigned nown;
	unsigned long maps, unmaps, attrs, overflow;
	__sz bytes, peak_bytes;
};

static struct m9_dom g_m9[M9_MAX_DOMS];
static int g_m9_next_id = 1;
static unsigned long g_m9_loglines;
static unsigned long g_unattr_maps;	/* maps by unbound threads while a domain lives */
static unsigned g_m9_live;

#define m9log(fmt, ...) uk_pr_err("m9dom: " fmt "\n", ##__VA_ARGS__) /* KLVL_ERR build */

static struct m9_dom *m9_of(struct ksp_mmu_domain *d)
{
	unsigned i;

	for (i = 0; i < M9_MAX_DOMS; i++)
		if (g_m9[i].used && &g_m9[i].mmu == d)
			return &g_m9[i];
	return NULL;
}

static const char *policy_of(char *const *envp)
{
	unsigned i;

	if (!envp)
		return NULL;
	for (i = 0; envp[i] && i < 512; i++)
		if (!strcmp(envp[i], "KORU_CHILD_ROLE=foot"))
			return "hyprland.children/foot";
	return NULL;
}

/* ---- ledger ------------------------------------------------------------ */

static void own_recount(struct m9_dom *m)
{
	unsigned i;
	__sz b = 0;

	for (i = 0; i < m->nown; i++)
		b += m->own[i].len;
	m->bytes = b;
	if (b > m->peak_bytes)
		m->peak_bytes = b;
}

static int own_add(struct m9_dom *m, __vaddr_t va, __sz len,
		   unsigned long attr, const char *name)
{
	struct m9_own *o;

	if (m->nown >= M9_MAX_OWN) {
		m->overflow++;
		return -ENOSPC;
	}
	o = &m->own[m->nown++];
	o->va = va;
	o->len = len;
	o->attr = attr;
	if (name)
		strncpy(o->name, name, sizeof(o->name) - 1);
	else
		strcpy(o->name, "-");
	o->name[sizeof(o->name) - 1] = 0;
	return 0;
}

/* Remove [va, va+len) from the ledger, splitting ranges. If set_attr, the
 * removed overlap is re-added with new_attr instead (mprotect). */
static void own_carve(struct m9_dom *m, __vaddr_t va, __sz len, int set_attr,
		      unsigned long new_attr)
{
	__vaddr_t end = va + len;
	unsigned i, n = m->nown;

	for (i = 0; i < n;) {
		struct m9_own o = m->own[i];
		__vaddr_t oe = o.va + o.len;

		if (oe <= va || o.va >= end) {
			i++;
			continue;
		}
		/* drop entry i (swap with last of the original window) */
		m->own[i] = m->own[n - 1];
		m->own[n - 1] = m->own[m->nown - 1];
		m->nown--;
		n--;
		if (o.va < va)
			(void)own_add(m, o.va, va - o.va, o.attr, o.name);
		if (oe > end)
			(void)own_add(m, end, oe - end, o.attr, o.name);
		if (set_attr) {
			__vaddr_t s = o.va > va ? o.va : va;
			__vaddr_t e = oe < end ? oe : end;

			(void)own_add(m, s, e - s, new_attr, o.name);
		}
	}
}

/* ---- ukvmem owner hooks (strong definitions of the weak refs) ---------- */

void ksp_vmem_mapped(struct uk_vas *vas __unused, __vaddr_t va, __sz len,
		     unsigned long attr, const char *name)
{
	struct ksp_mmu_domain *d;
	struct m9_dom *m;

	if (!g_m9_live)
		return;
	d = ksp_mmu_thread_dom(uk_thread_current());
	m = d ? m9_of(d) : NULL;
	if (!m) {
		g_unattr_maps++;
		return;
	}
	m->maps++;
	(void)own_add(m, va, len, attr, name);
	own_recount(m);
	if ((m->maps % 32) == 0)
		m9log("summary dom=%d maps=%lu unmaps=%lu attrs=%lu vmas=%u bytes=0x%lx peak=0x%lx unattributed_maps=%lu",
		      m->id, m->maps, m->unmaps, m->attrs, m->nown,
		      (unsigned long)m->bytes, (unsigned long)m->peak_bytes,
		      g_unattr_maps);
	if (g_m9_loglines++ < M9_LOG_CAP)
		m9log("own dom=%d +va=0x%lx len=0x%lx attr=0x%lx name=%s vmas=%u bytes=0x%lx",
		      m->id, (unsigned long)va, (unsigned long)len, attr,
		      name ? name : "-", m->nown, (unsigned long)m->bytes);
}

void ksp_vmem_unmapped(struct uk_vas *vas __unused, __vaddr_t va, __sz len)
{
	struct ksp_mmu_domain *d;
	struct m9_dom *m;

	if (!g_m9_live)
		return;
	d = ksp_mmu_thread_dom(uk_thread_current());
	m = d ? m9_of(d) : NULL;
	if (!m)
		return;
	m->unmaps++;
	own_carve(m, va, len, 0, 0);
	own_recount(m);
	if (g_m9_loglines++ < M9_LOG_CAP)
		m9log("own dom=%d -va=0x%lx len=0x%lx vmas=%u bytes=0x%lx",
		      m->id, (unsigned long)va, (unsigned long)len, m->nown,
		      (unsigned long)m->bytes);
}

void ksp_vmem_attr(struct uk_vas *vas __unused, __vaddr_t va, __sz len,
		   unsigned long attr)
{
	struct ksp_mmu_domain *d;
	struct m9_dom *m;

	if (!g_m9_live)
		return;
	d = ksp_mmu_thread_dom(uk_thread_current());
	m = d ? m9_of(d) : NULL;
	if (!m)
		return;
	m->attrs++;
	own_carve(m, va, len, 1, attr);
	own_recount(m);
	if (g_m9_loglines++ < M9_LOG_CAP)
		m9log("own dom=%d ~va=0x%lx len=0x%lx attr=0x%lx vmas=%u",
		      m->id, (unsigned long)va, (unsigned long)len, attr, m->nown);
}

/* ---- execve hooks (strong definitions of the weak refs) ---------------- */

void *ksp_execve_begin(const char *path, char *const *envp)
{
	struct uk_thread *t = uk_thread_current();
	struct ksp_mmu_domain *cur = ksp_mmu_thread_dom(t);
	const char *pol;
	struct m9_dom *m = NULL;
	struct uk_vas *vas;
	unsigned i;
	int rc;

	if (cur) {
		/* already in a domain: stays in it across exec (no escape) */
		m = m9_of(cur);
		m9log("execve dom=%d path=%s inherit=yes (domain kept across exec)",
		      m ? m->id : -1, path ? path : "?");
		return cur;
	}
	pol = policy_of(envp);
	if (!pol)
		return NULL;
	for (i = 0; i < M9_MAX_DOMS; i++)
		if (!g_m9[i].used) {
			m = &g_m9[i];
			break;
		}
	if (!m) {
		m9log("REFUSED domain path=%s policy=%s reason=no-slot (runs WITHOUT domain)",
		      path ? path : "?", pol);
		return NULL;
	}
	vas = uk_vas_get_active();
	memset(m, 0, sizeof(*m));
	rc = ksp_mmu_derive(&m->mmu, vas, NULL, 0);
	if (rc) {
		m9log("REFUSED domain path=%s policy=%s reason=derive rc=%d (runs WITHOUT domain)",
		      path ? path : "?", pol, rc);
		memset(m, 0, sizeof(*m));
		return NULL;
	}
	m->mmu.shadow = 1;
	m->used = 1;
	m->id = g_m9_next_id++;
	strncpy(m->path, path ? path : "?", sizeof(m->path) - 1);
	g_m9_live++;
	ksp_mmu_bind_thread(t, &m->mmu);
	m9log("domain dom=%d created at=execve path=%s policy=%s thread=%p cr3=0x%lx mode=shadow",
	      m->id, m->path, pol, (void *)t,
	      (unsigned long)m->mmu.pt.pt_pbase);
	return &m->mmu;
}

static void ledger_dump(struct m9_dom *m, const char *phase)
{
	unsigned i;

	m9log("ledger dom=%d phase=%s vmas=%u bytes=0x%lx peak=0x%lx maps=%lu unmaps=%lu attrs=%lu overflow=%lu unattributed_maps=%lu",
	      m->id, phase, m->nown, (unsigned long)m->bytes,
	      (unsigned long)m->peak_bytes, m->maps, m->unmaps, m->attrs,
	      m->overflow, g_unattr_maps);
	for (i = 0; i < m->nown && i < 48; i++)
		m9log("ledger dom=%d phase=%s [%u] va=0x%lx len=0x%lx attr=0x%lx name=%s",
		      m->id, phase, i, (unsigned long)m->own[i].va,
		      (unsigned long)m->own[i].len, m->own[i].attr,
		      m->own[i].name);
}

void ksp_execve_commit(void *dom, struct ukarch_ctx *ctx)
{
	struct m9_dom *m = m9_of((struct ksp_mmu_domain *)dom);
	long undecl;

	if (!m)
		return;
	undecl = ksp_mmu_census(&m->mmu, "execve", NULL, NULL);
	m9log("commit dom=%d entry=%p sp=%p census_undeclared=%ld mode=shadow (CR3 not activated: step 2)",
	      m->id, ctx ? (void *)ctx->ip : NULL, ctx ? (void *)ctx->sp : NULL,
	      undecl);
	ledger_dump(m, "execve");
}

void ksp_execve_abort(void *dom)
{
	struct m9_dom *m = m9_of((struct ksp_mmu_domain *)dom);

	if (!m)
		return;
	m9log("abort dom=%d path=%s (execve failed)", m->id, m->path);
}

/* Last bound thread gone: final ledger, free the child PT. */
void ksp_mmu_domain_orphaned(struct ksp_mmu_domain *d)
{
	struct m9_dom *m = m9_of(d);

	if (!m)
		return;
	ledger_dump(m, "exit");
	m9log("domain dom=%d destroyed path=%s", m->id, m->path);
	ksp_mmu_destroy(&m->mmu);
	m->used = 0;
	if (g_m9_live)
		g_m9_live--;
}
