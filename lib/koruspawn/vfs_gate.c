/* SPDX-License-Identifier: BSD-3-Clause */
/* Path gate for Spawn children: called from the vfscore patch on every
 * task_conv / taskat_conv. Ambient (non-child) contexts always pass. */
#include <string.h>
#include "koruspawn.h"

int koru_vfs_path_gate(const char *abs)
{
	if (!abs)
		return 1;
	return ksp_path_allowed(abs);
}
