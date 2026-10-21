#!/usr/bin/env python3
# mk-ticker-elf.py <out> <char> <count> <spin> <exit-code> — emit an ELF64
# child that writes one char per busy-spin epoch, `count` times, then
# exits. Paired on a two-child roster it produces interleaved serial
# output — the visible evidence of tick preemption: each child's outer
# counter lives in %ebx (a GP reg saved/restored by the frame swap).
# Same syscall ABI as mk-child-elf.py: nr in rax, args rdi/rsi/rdx.
import struct, sys

out, ch, count, spin, ecode = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
msg = ch.encode()[:1]

code = bytearray()
code += b"\xBB" + struct.pack("<I", count)          # mov $count, %ebx
loop_top = len(code)
code += b"\xB8\x01\x00\x00\x00"                     # mov $1, %eax   (write)
code += b"\xBF\x01\x00\x00\x00"                     # mov $1, %edi   (fd)
code += b"\x48\x8D\x35" + struct.pack("<i", 0)      # lea msg(%rip),%rsi — patched
code += b"\xBA\x01\x00\x00\x00"                     # mov $1, %edx   (len)
code += b"\x0F\x05"                                 # syscall
code += b"\xB9" + struct.pack("<I", spin)           # mov $spin, %ecx
code += b"\x48\xFF\xC9"                             # dec %rcx
code += b"\x75\xFB"                                 # jnz -5 (the dec)
code += b"\xFF\xCB"                                 # dec %ebx
jnz_off = len(code)
code += b"\x75\x00"                                 # jnz loop_top — patched
code += b"\xB8\x3C\x00\x00\x00"                     # mov $60, %eax  (exit)
code += b"\xBF" + struct.pack("<I", ecode)          # mov $code, %edi
code += b"\x0F\x05"                                 # syscall
code += b"\xEB\xFE"                                 # jmp $
msg_off = len(code)
code += msg

# patches: outer jnz rel8 back to loop_top; lea disp32 to msg
code[jnz_off + 1] = (loop_top - (jnz_off + 2)) & 0xFF
struct.pack_into("<i", code, 18, msg_off - 22)

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
struct.pack_into("<I", b, EHDR + 0, 1)  # PT_LOAD R+X
struct.pack_into("<I", b, EHDR + 4, 5)
struct.pack_into("<Q", b, EHDR + 8, SEG_OFF)
struct.pack_into("<Q", b, EHDR + 16, VADDR)
struct.pack_into("<Q", b, EHDR + 24, VADDR)
struct.pack_into("<Q", b, EHDR + 32, len(code))
struct.pack_into("<Q", b, EHDR + 40, len(code))
struct.pack_into("<Q", b, EHDR + 48, 1)
b[SEG_OFF:] = code

open(out, "wb").write(bytes(b))
print(f"mk-ticker-elf: {out} ({len(b)} bytes, {ch} x{count} spin={spin}, exit {ecode})")
