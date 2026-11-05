// real-ELF fixture for boot_real.k — a gcc-built static-pie (ET_DYN)
// no-libc child: proves the loader's bias application + entry stack
// through the seam, before any libc is in the picture. Build:
//   gcc -static-pie -nostdlib -nostartfiles -o pie.elf realhello.c
static const char msg[] = "real pie child says hi\n";

void _start(void) {
    __asm__ volatile(
        "mov $1, %%eax\n"          // write
        "mov $1, %%edi\n"          // fd
        "lea msg(%%rip), %%rsi\n"  // buf (rip-relative — no relocs needed)
        "mov $24, %%edx\n"         // len
        "syscall\n"
        "mov $231, %%eax\n"        // exit_group — folds to the exit cap
        "mov $42, %%edi\n"
        "syscall\n"
        ::: "rax", "rdi", "rsi", "rdx", "rcx", "r11", "memory");
    __builtin_unreachable();
}
