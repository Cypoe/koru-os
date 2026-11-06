// pyrun.c — the CPython probe's launcher: the .k exec verb passes
// only argv[0]=basename, so this stub execve()s python with the real
// vector through the exec-verb arm. argv[1] = script path inside the
// initramfs view. The child's stdout IS the evidence: PY lines are
// the interpreter talking; a traceback or SEAM REFUSE is a named gap.
#include <unistd.h>
#include <stdio.h>

int main(void) {
    const char *script = "/main.py";
    execve("/usr/bin/python3",
           (char *[]){ "python3", "-S", (char *)script, (char *)0 },
           (char *[]){ "HOME=/", "PATH=/usr/bin:/bin", (char *)0 });
    // exec only returns on failure — the view refused or the image
    // wouldn't load; name it on the way out.
    perror("pyrun: execve");
    return 92;
}
