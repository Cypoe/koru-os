/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M3: make the init process's exit status observable on the serial
 * console. Unikraft 0.21 computes it (posix-process term hook, late class)
 * but only prints it at debug level and QEMU's isa-debug-exit carries only
 * crash/no-crash. This term hook sits in the SYS class, so it runs after the
 * LATE-class hook that filled ctx->exit_code (terms run in reverse order).
 */
#include <stdio.h>
#include <uk/init.h>

static int koruos_exitstatus_init(struct uk_init_ctx *ictx __unused)
{
	return 0;
}

static void koruos_exitstatus_term(struct uk_term_ctx *tctx)
{
	printf("koru-os: init exited with status %d\n", tctx->exit_code);
}

uk_sys_initcall(koruos_exitstatus_init, koruos_exitstatus_term);
