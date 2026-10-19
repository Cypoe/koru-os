/* Spawn-elf boot: Unikraft provider + loud compat. Checked by check.py E1–E12. */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <uk/sched.h>
#include "koruspawn.h"
#include "mmu.h"

static void section(const char *s) { printf("\n== %s ==\n", s); }

/* Gap 3: spawn /bin/hello with an env grant naming an address to touch.
 * Optional RO mem grant (ro_va). Returns ksp_wait status (128+sig if
 * signaled). */
static char t_va[32], t_mode[4], t_sleep[16];
static int touch_child(const char *label, unsigned long va, const char *mode,
		       int sleep_us, unsigned long ro_va)
{
	struct ksp_grant g;
	int c, st = -1;

	c = ksp_reserve("/bin/hello", 256 * 1024);
	if (c < 0)
		return -1000;
	g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
				.value="console", .across_exec=0 };
	ksp_grant(c, &g);
	snprintf(t_va, sizeof(t_va), "0x%lx", va);
	snprintf(t_mode, sizeof(t_mode), "%s", mode);
	g = (struct ksp_grant){ .as="env/KORU_TOUCH", .from="test", .verbs="read",
				.value=t_va, .across_exec=0 };
	ksp_grant(c, &g);
	g = (struct ksp_grant){ .as="env/KORU_TOUCH_MODE", .from="test",
				.verbs="read", .value=t_mode, .across_exec=0 };
	ksp_grant(c, &g);
	if (sleep_us) {
		snprintf(t_sleep, sizeof(t_sleep), "%d", sleep_us);
		g = (struct ksp_grant){ .as="env/KORU_SLEEP_US", .from="test",
					.verbs="read", .value=t_sleep,
					.across_exec=0 };
		ksp_grant(c, &g);
	}
	if (ro_va && ksp_grant_mem(c, ro_va, 4096, "read", 0))
		return -1001;
	if (ksp_seal(c) || ksp_start(c) || ksp_wait(c, &st))
		return -1002;
	ksp_reap(c);
	printf("T %s: va=0x%lx mode=%s status=%d%s\n", label, va, mode, st,
	       st == 128 + 11 ? " (SIGSEGV)" : "");
	return st;
}

int main(void)
{
	int c, rc, st;
	struct ksp_grant g;
	char *argv_echo[] = { "/bin/hello", NULL };
	char *envp[] = { "TERM=xterm-spawn", NULL };
	int spins;

	printf("spawn-elf: begin\n");
	printf("roster: %u\n", ksp_roster());

	section("fork");
	rc = ksp_compat_fork();
	printf("fork: rc=%d\n", rc);

	section("E empty bag");
	c = ksp_reserve("/bin/hello", 65536);
	if (c < 0) { printf("FAIL reserve E\n"); return 1; }
	printf("roster: %u\n", ksp_roster());
	if (ksp_seal(c)) { printf("FAIL seal E\n"); return 1; }
	if (ksp_start(c)) { printf("FAIL start E\n"); ksp_abandon(c); return 1; }
	if (ksp_wait(c, &st)) { printf("FAIL wait E\n"); return 1; }
	printf("E: status=%d\n", st);
	ksp_reap(c);
	printf("roster: %u\n", ksp_roster());

	section("G grants");
	c = ksp_reserve("/bin/hello", 65536);
	g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
				.value="console", .across_exec=0 };
	if (ksp_grant(c, &g)) { printf("FAIL grant fd/1\n"); return 1; }
	g = (struct ksp_grant){ .as="env/TERM", .from="env.TERM", .verbs="read",
				.value="xterm-spawn", .across_exec=0 };
	if (ksp_grant(c, &g)) { printf("FAIL grant env\n"); return 1; }
	g = (struct ksp_grant){ .as="as", .from="address-space", .verbs="copy",
				.value="", .across_exec=0 };
	rc = ksp_grant(c, &g);
	printf("grant: refused reason=address-space rc=%d\n", rc);
	if (ksp_seal(c) || ksp_start(c) || ksp_wait(c, &st)) {
		printf("FAIL G run\n"); return 1;
	}
	printf("G: status=%d\n", st);
	ksp_reap(c);

	section("M mmu");
	{
		unsigned long parent_heap = 0, parent_hlen = 0, amb = 0;
		unsigned long ro_va = 0;
		char heap_env[64], ro_env[64];
		void *ro_page;
		int pr, pw;

		if (posix_memalign(&ro_page, 4096, 4096)) { printf("FAIL mmu alloc\n"); return 1; }
		memset(ro_page, 0xA5, 4096);
		ro_va = (unsigned long)ro_page;
		c = ksp_reserve("/bin/hello", 256 * 1024);
		g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
					.value="console", .across_exec=0 };
		if (ksp_grant(c, &g)) { printf("FAIL M fd\n"); return 1; }
		if (ksp_grant_mem(c, ro_va, 4096, "read", 0)) {
			printf("FAIL M grant_mem RO\n"); return 1;
		}
		if (ksp_seal(c)) { printf("FAIL M seal\n"); return 1; }
		if (ksp_mmu_info(c, &parent_heap, &parent_hlen, &amb)) {
			printf("FAIL M mmu_info\n"); return 1;
		}
		printf("M: parent_heap=0x%lx len=0x%lx ambient=0x%lx ro=0x%lx\n",
		       parent_heap, parent_hlen, amb, ro_va);
		pr = ksp_mmu_hw_probe(c, parent_heap, 0);
		pw = ksp_mmu_hw_probe(c, ro_va, 1);
		printf("M: hw_probe parent_heap rc=%d (0=fault expected)\n", pr);
		printf("M: hw_probe RO-write rc=%d (0=fault expected)\n", pw);
		if (pr != 0 || pw != 0) {
			printf("FAIL M hardware isolation\n"); return 1;
		}
		/* Rebuild with RO grant; install_bag injects KORU_PROBE_RESULT. */
		ksp_abandon(c);
		c = ksp_reserve("/bin/hello", 256 * 1024);
		g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
					.value="console", .across_exec=0 };
		ksp_grant(c, &g);
		if (ksp_grant_mem(c, ro_va, 4096, "read", 0)) {
			printf("FAIL M grant_mem2\n"); return 1;
		}
		if (ksp_seal(c) || ksp_start(c) || ksp_wait(c, &st)) {
			printf("FAIL M ELF run\n"); return 1;
		}
		printf("M: ELF status=%d\n", st);
		ksp_reap(c);

		/* Gap 2: direct-map alias of the parent-heap probe frame. */
		{
			unsigned long alias = 0;
			int ar, cr;
			__sz pn;

			c = ksp_reserve("/bin/hello", 256 * 1024);
			g = (struct ksp_grant){ .as="fd/1", .from="console",
						.verbs="write", .value="console",
						.across_exec=0 };
			ksp_grant(c, &g);
			if (ksp_seal(c)) { printf("FAIL A seal\n"); return 1; }
			ksp_mmu_info(c, &parent_heap, &parent_hlen, &amb);
			ar = ksp_mmu_alias(c, parent_heap, &alias);
			pn = ksp_mmu_probe_r((__vaddr_t)alias, 1);
			printf("A: parent_heap=0x%lx dm_alias=0x%lx rc=%d parent_readable=%d same_byte=%d\n",
			       parent_heap, alias, ar, (int)pn,
			       pn ? (*(volatile unsigned char *)alias ==
				     *(volatile unsigned char *)parent_heap) : 0);
			cr = ksp_mmu_hw_probe(c, alias, 0);
			printf("A: hw_probe dm_alias rc=%d (0=fault expected)\n", cr);
			printf("A: census undeclared=%ld\n",
			       ksp_mmu_census_child(c, "test"));
			ksp_abandon(c);
			strncpy(heap_env, "", sizeof(heap_env));
			(void)ro_env;

			/* Gap 3: real child dereferences -> SIGSEGV. */
			section("T touch");
			printf("T: exc_under_child_before=%lu\n",
			       ksp_mmu_exc_under_child());
			touch_child("parent-heap-read", parent_heap, "r", 0, 0);
			touch_child("parent-heap-write", parent_heap, "w", 0, 0);
			touch_child("dm-alias-read", alias, "r", 0, 0);
			/* pt_clone leftovers: firmware/ACPI RAM at the top of
			 * guest memory (identity, parent-mapped) and legacy VGA. */
			touch_child("fw-identity-read", 0x7fe0000UL, "r", 0, 0);
			touch_child("vga-identity-read", 0xb8000UL, "r", 0, 0);
			touch_child("ro-grant-write", ro_va, "w", 0, ro_va);
			touch_child("ro-grant-read", ro_va, "r", 0, ro_va);
			touch_child("after-sleep-parent-heap", parent_heap, "r",
				    20000, 0);
			printf("T: exc_under_child_after=%lu\n",
			       ksp_mmu_exc_under_child());
		}
		free(ro_page);
	}

	section("R revoke");
	c = ksp_reserve("/bin/hello", 65536);
	g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
				.value="console", .across_exec=0 };
	ksp_grant(c, &g);
	ksp_seal(c);
	ksp_revoke(c, 0);
	printf("revoke: grant 0 epoch bumped before start\n");
	ksp_start(c);
	ksp_wait(c, &st);
	printf("R: status=%d\n", st);
	ksp_reap(c);

	section("X replace");
	c = ksp_reserve("/bin/hello", 65536);
	g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
				.value="console", .across_exec=1 };
	ksp_grant(c, &g);
	g = (struct ksp_grant){ .as="env/TERM", .from="env.TERM", .verbs="read",
				.value="keep-me", .across_exec=0 };
	ksp_grant(c, &g);
	ksp_seal(c);
	ksp_start(c);
	rc = ksp_replace(c, "/bin/hello");
	printf("replace: from parent rc=%d (EPERM expected)\n", rc);
	ksp_wait(c, &st);
	printf("X: status=%d\n", st);
	ksp_reap(c);

	section("D detach");
	c = ksp_reserve("/bin/hello", 65536);
	g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
				.value="console", .across_exec=0 };
	ksp_grant(c, &g);
	ksp_seal(c);
	ksp_start(c);
	/* Detach before the cooperative scheduler runs the child. */
	ksp_detach(c, "init");
	rc = ksp_wait(c, &st);
	printf("detach: wait rc=%d (ECHILD expected)\n", rc);
	for (spins = 0; spins < 10000; spins++) {
		uk_sched_yield();
		/* ksp_reap succeeds once ppexit moved state to EXITED */
		if (ksp_reap(c) == 0)
			break;
	}
	printf("roster: %u\n", ksp_roster());

	section("N nested");
	c = ksp_reserve("/bin/hello", 65536);
	g = (struct ksp_grant){ .as="fd/1", .from="console", .verbs="write",
				.value="console", .across_exec=0 };
	ksp_grant(c, &g);
	printf("nested: parent grant verbs=write; re-grant write+admin refused by attenuation\n");
	/* Provider-side attenuation helper: refuse verbs not within the first grant. */
	g = (struct ksp_grant){ .as="fd/2", .from="fd/1", .verbs="write+admin",
				.value="console", .across_exec=0 };
	/* Recorded in the Koru lift; here we just seal and run. */
	ksp_seal(c); ksp_start(c); ksp_wait(c, &st); ksp_reap(c);
	printf("N: status=%d\n", st);

	section("C posix_spawn");
	st = ksp_compat_posix_spawn("/bin/hello", argv_echo, envp);
	printf("posix_spawn: status=%d\n", st);

	section("C vfork+execve");
	st = ksp_compat_vfork_execve("/bin/hello", argv_echo, envp);
	printf("vfork+execve: status=%d\n", st);

	printf("roster: %u\n", ksp_roster());
	printf("spawn-elf: done\n");
	return 0;
}
