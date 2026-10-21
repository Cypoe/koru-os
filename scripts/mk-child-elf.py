#!/usr/bin/env python3
# mk-child-elf.py <out> — emit the ELF64 child binary loaded from ext2 in
# the boot_spawn path. Same ABI as the embedded child in user.zig
# (int 0x80: write=1, exit=60), a different message + status so disk
# provenance is distinguishable in the serial evidence.
import struct, sys

msg = b"disk child says hi\n"  # 19 bytes

# mov $1,%eax; mov $1,%edi; lea msg(%rip),%rsi; mov $len,%edx; int $0x80
# mov $60,%eax; mov $43,%edi; int $0x80; jmp $ ; msg
code = bytearray()
code += b"\xB8\x01\x00\x00\x00"          # mov $1, %eax
code += b"\xBF\x01\x00\x00\x00"          # mov $1, %edi
code += b"\x48\x8D\x35" + struct.pack("<i", 0)  # lea, disp patched below
code += b"\xBA" + struct.pack("<I", len(msg))   # mov $len, %edx
code += b"\xCD\x80"                      # int $0x80
code += b"\xB8\x3C\x00\x00\x00"          # mov $60, %eax
code += b"\xBF\x2B\x00\x00\x00"          # mov $43, %edi
code += b"\xCD\x80"                      # int $0x80
code += b"\xEB\xFE"                      # jmp $
msg_off = len(code)
struct.pack_into("<i", code, 13, msg_off - 17)  # disp: msg - next rip (17)
code += msg

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
