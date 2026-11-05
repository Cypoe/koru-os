/* koruos/native link script — flat ELF64 kernel at 1 MiB, multiboot2 header
 * leading .text (must sit inside the image's first 32 KiB for the loader's
 * scan). Nothing PIE: the image is position-fixed at the load address. */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)
SECTIONS {
    . = 1M;
    .note : { KEEP(*(.note*)) }
    .text : {
        KEEP(*(.multiboot))
        *(.text)
        *(.text.*)
    }
    . = ALIGN(4K);
    .rodata : { *(.rodata) *(.rodata.*) }
    . = ALIGN(4K);
    .data : { *(.data) *(.data.*) }
    . = ALIGN(4K);
    .bss : { *(COMMON) *(.bss) *(.bss.*) }
    . = ALIGN(4K);
    _end = .;
    /DISCARD/ : { *(.comment) *(.eh_frame) *(.eh_frame_hdr) *(.gnu.*) }
}
