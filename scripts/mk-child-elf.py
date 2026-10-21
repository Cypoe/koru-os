#!/usr/bin/env python3
# mk-child-elf.py <out> — emit the ELF64 child binary loaded from ext2 in
# the boot_spawn path. SYSCALL ABI (the real seam — int 0x80 retired):
# nr in rax, args rdi/rsi/rdx. The child's bag grants {write=1, exit=60}
# only — it then calls getpid (nr 2, defined but ungranted), observes
# -EACCES, and prints its own evidence that the refusal came back as a
# return value. Different message + status than the embedded child so
# disk provenance is distinguishable in the serial evidence.
import struct, sys

msg = b"disk child says hi\n"      # 19 bytes
refused = b"getpid refused\n"      # 15 bytes

# write(1, msg, 19) — granted
code = bytearray()
code += b"\xB8\x01\x00\x00\x00"          # mov $1, %eax
code += b"\xBF\x01\x00\x00\x00"          # mov $1, %edi
code += b"\x48\x8D\x35" + struct.pack("<i", 0)  # lea msg(%rip),%rsi — patched
code += b"\xBA" + struct.pack("<I", len(msg))   # mov $len, %edx
code += b"\x0F\x05"                      # syscall
# getpid — defined (nr 2) but NOT in the bag → -EACCES
code += b"\xB8\x02\x00\x00\x00"          # mov $2, %eax
code += b"\x0F\x05"                      # syscall
code += b"\x83\xF8\xF3"                  # cmp $-13, %eax
jne_off = len(code)
code += b"\x75\x00"                      # jne skip — patched
# write(1, refused, 15) — prove the refusal arrived as a return value
code += b"\xB8\x01\x00\x00\x00"          # mov $1, %eax
code += b"\xBF\x01\x00\x00\x00"          # mov $1, %edi
code += b"\x48\x8D\x35" + struct.pack("<i", 0)  # lea refused(%rip) — patched
code += b"\xBA" + struct.pack("<I", len(refused))
code += b"\x0F\x05"                      # syscall
skip = len(code)
# exit(43)
code += b"\xB8\x3C\x00\x00\x00"          # mov $60, %eax
code += b"\xBF\x2B\x00\x00\x00"          # mov $43, %edi
code += b"\x0F\x05"                      # syscall
code += b"\xEB\xFE"                      # jmp $
msg1_off = len(code)
code += msg
msg2_off = len(code)
code += refused

# patch: jne rel8, both lea disp32 (rip = next insn)
code[jne_off + 1] = skip - (jne_off + 2)
struct.pack_into("<i", code, 13, msg1_off - 17)
struct.pack_into("<i", code, 49, msg2_off - 53)

EHDR, PHDR, SEG_OFF = 64, 56, 0x78
VADDR = 0x800000 + SEG_OFF

b = bytearray(EHDR + PHDR + len(code))
b[0:4] = b"\x7fELF"; b[4] = 2; b[5] = 1; b[6] = 1
struct.pack_into("<H", b, 16, 2)      # ET_EXEC
struct.pack_into("<H", b, 18, 0x3E)   # EM_X86_64
struct.pack_into("<I", b, 20, 1)
struct.pack_into("<Q", b, 24, VADDR)  # e_entry
struct.pack_into("<Q", b, 32, EHDR)   # e_phoff
struct.pack_into("<H", b, 52, EHDR)
struct.pack_into("<H", b, 54, PHDR)
struct.pack_into("<H", b, 56, 1)      # e_phnum
# phdr: PT_LOAD R+X
struct.pack_into("<I", b, EHDR + 0, 1)
struct.pack_into("<I", b, EHDR + 4, 5)
struct.pack_into("<Q", b, EHDR + 8, SEG_OFF)
struct.pack_into("<Q", b, EHDR + 16, VADDR)
struct.pack_into("<Q", b, EHDR + 24, VADDR)
struct.pack_into("<Q", b, EHDR + 32, len(code))
struct.pack_into("<Q", b, EHDR + 40, len(code))
struct.pack_into("<Q", b, EHDR + 48, 1)
b[SEG_OFF:] = code

open(sys.argv[1], "wb").write(bytes(b))
print(f"mk-child-elf: {sys.argv[1]} ({len(b)} bytes, entry 0x{VADDR:x})")
