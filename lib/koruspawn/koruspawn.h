/* SPDX-License-Identifier: BSD-3-Clause */
/* koru-os lib/koruspawn: Unikraft provider of koruos/spawn (§8.6.7; home is
 * koru-libs unikraft/spawn, here until Q33) and the loud Linux-ABI compat layer
 * (§8.6.4). Rung 0/1: bag enforced at the seam (proxy fds + vfscore path gate).
 */
#ifndef KORUSPAWN_H
#define KORUSPAWN_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define KSP_MAX_GRANTS 8
#define KSP_MAX_REC    16
#define KSP_MAX_PROXY  32

struct ksp_grant {
	const char *as;      /* "fd/N", "env/NAME", "path:ABS" */
	const char *from;    /* parent's handle name (provenance) */
	const char *verbs;   /* attenuated, '+' separated */
	const char *value;   /* env value, or "console" / "file:PATH" for fds */
	int across_exec;     /* kept across replace; default 0 (F12) */
};

/* Stages a child: allocates a record, mints identity, does not run. Returns
 * the child instance id (>= 2) or a negative errno. */
int ksp_reserve(const char *path, uint64_t budget);

/* Append one grant. Returns 0 or -errno (EPERM over-grant / F2, ENOSPC bag full). */
int ksp_grant(int child, const struct ksp_grant *g);

/* Freeze the bag, check imports, emit the manifest. */
int ksp_seal(int child);

/* Load the ELF (koruelf), install bag into the child's fdtab and env, schedule. */
int ksp_start(int child);

/* Block until the child exits; return its status (WEXITSTATUS-like). */
int ksp_wait(int child, int *status);

/* Retire an exited child. */
int ksp_reap(int child);

/* Retire a staged/sealed child that never ran. */
int ksp_abandon(int child);

/* Move the reap obligation to a named supervisor (logged). */
int ksp_detach(int child, const char *supervisor);

/* Bump the epoch of grant index `gi` in a live child's bag (§8.5). */
int ksp_revoke(int child, unsigned gi);

/* Exec: replace the running image. Keeps only across_exec grants; generation++. */
int ksp_replace(int child, const char *path);

/* Loud fork refusal: always -ENOSYS and a refusal row. */
int ksp_fork_refuse(void);

/* Roster size (live children). */
unsigned ksp_roster(void);

/* Compat layer (§8.6.4): prints spawn-compat: lines, then calls the tors. */
int ksp_compat_posix_spawn(const char *path, char *const argv[], char *const envp[]);
int ksp_compat_vfork_execve(const char *path, char *const argv[], char *const envp[]);
int ksp_compat_fork(void);
int ksp_compat_execve(const char *path, char *const argv[], char *const envp[]);

/* Seam helpers used by the vfscore path gate and the proxy file. */
int ksp_active_child(void);                 /* current thread's child instance, or 0 */
int ksp_path_allowed(const char *abs);      /* 1 if ambient or a path: grant covers it */
int ksp_grant_epoch_ok(unsigned slot);      /* 1 if the grant's epoch matches the store */

#endif /* KORUSPAWN_H */
