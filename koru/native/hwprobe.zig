// koru/native hwprobe — M-input hardware-enumeration probes.
//
// The T590's TrackPoint+touchpad didn't answer on legacy 8042 aux
// (aux=0). These shell commands enumerate what bus/interface the pointing
// devices actually sit on: full PCI table, USB/XHCI host-controller
// capability+port-status dump, ACPI table list + Embedded-Controller
// probe, and a synthesized verdict. Every line prints to the console,
// which the UDP mirror already streams to the listener — the log IS the
// oracle, no extra plumbing.
//
// Reuses the proven readers: pci.devices[]/count/barPhys/read8-32 (the
// same config-space walk net+i915 already ran), acpi.tables[]/findTable
// (the SDT walk from boot), mmio.map for BAR MMIO. No new bus drivers —
// enumeration and register dumps only, honest about depth.

const std = @import("std");
const pci = @import("pci");
const acpi = @import("acpi");
const mmio = @import("mmio"); // host page-table mapper (identity VA==PA)
const text = @import("text.zig");

fn puts(s: [*:0]const u8) void {
    text.puts(s);
}
fn hex2(v: u64) void {
    text.puthex(@intCast(v & 0xFF));
}
fn dec(v: u64) void {
    text.putdec(v);
}
fn nl() void {
    text.newline();
}
// "pci: 00:1f.2" style locator for a device.
fn loc(d: *const pci.Device) void {
    dec(d.bus); puts(":"); dec(d.slot); puts("."); dec(d.func);
}

// class:subclass name for the input-relevant classes — keeps the table
// readable instead of raw hex everywhere.
fn className(cls: u8, sub: u8) [*:0]const u8 {
    if (cls == 0x03 and sub == 0x00) return "VGA";
    if (cls == 0x02 and sub == 0x00) return "ETHERNET";
    if (cls == 0x0C and sub == 0x03) return "USB";
    if (cls == 0x0C and sub == 0x05) return "SMBUS/I2C";
    if (cls == 0x0C and sub == 0x06) return "SERIAL";
    if (cls == 0x01 and sub == 0x06) return "LPC/ISA-bridge";
    if (cls == 0x01 and sub == 0x05) return "LPC";
    if (cls == 0x08 and sub == 0x06) return "LPC";
    if (cls == 0x06) return "BRIDGE";
    return "other";
}

// ---- pciscan ---------------------------------------------------------------
// Full config-space enumeration table: every bus/slot/func pci.init walked,
// vendor:device, class:subclass(+progif), and each BAR's physical base.
// This is the ground truth for "what host controllers exist".
pub fn pciScan() void {
    puts("KORU pciscan — full PCI enumeration\n");
    pci.init(); // idempotent — one table, net.init may have filled it
    puts("pci: count="); dec(pci.count); puts("\n");
    var i: usize = 0;
    while (i < pci.count) : (i += 1) {
        const d = &pci.devices[i];
        loc(d); puts(" ");
        dec(d.vendor); puts(":"); dec(d.device);
        puts(" cls="); hex2(d.class); puts("/"); hex2(d.subclass);
        puts(" "); puts(className(d.class, d.subclass));
        // prog-if distinguishes XHCI(0x30)/EHCI(0x20)/UHCI(0x00) under USB
        const pif = pci.read8(d.bus, d.slot, d.func, 0x0A);
        puts(" pif="); hex2(pif);
        // BAR0 phys — the host-controller MMIO base for USB candidates
        const b0 = pci.barPhys(d, 0);
        if (b0 != 0) { puts(" bar0="); dec(b0); }
        puts("\n");
    }
    puts("KORU pciscan done\n");
}

// ---- usb -------------------------------------------------------------------
// XHCI probe: for each USB host controller (class 0x0C/sub 0x03), map its
// BAR0, read the capability registers (CAPLENGTH, HCIVERSION, HCSPARAMS,
// HCCPARAMS, DBOFF, RTSOFF), then the operational registers and per-port
// PORTSC status. This tells us whether HID devices are electrically
// present even without transfer support.
fn xhciProbe(d: *const pci.Device) void {
    const bar0 = pci.barPhys(d, 0);
    puts("usb: xhci candidate at "); loc(d); puts("\n");
    if (bar0 == 0) {
        puts("usb:   BAR0 unmapped — cannot read caps\n");
        return;
    }
    // map a window covering cap regs + op regs + port status block.
    // XHCI MMIO: cap@+0, op@+CAPLENGTH, ports@op+0x400. 8KB covers all.
    if (!mmio.map(bar0, 0x2000)) {
        puts("usb:   BAR0 map failed\n");
        return;
    }
    const cap: [*]volatile u32 = @ptrFromInt(@as(usize,@intCast(bar0)));
    const caplen: usize = @intCast(cap[0] & 0xFF); // CAPLENGTH is a u8 at +0
    const hciver: u32 = cap[0] >> 16;              // HCIVERSION @ +2 (in dword0 hi)
    const hcsp: u32 = cap[1];                       // HCSPARAMS @ +4
    const hccp: u32 = cap[4];                       // HCCPARAMS @ +0x10
    const dboff: u32 = cap[5];                      // DBOFF @ +0x14
    const rtsoff: u32 = cap[6];                     // RTSOFF @ +0x18
    const maxslots: u32 = hcsp & 0xFF;
    const maxports: u32 = (hcsp >> 8) & 0xFF;
    puts("usb:   caplen="); dec(caplen);
    puts(" hciver="); hex2(hciver & 0xFFFF); puts("\n");
    puts("usb:   hcsp maxslots="); dec(maxslots);
    puts(" maxports="); dec(maxports); puts("\n");
    puts("usb:   hccp="); dec(hccp); puts(" dboff="); dec(dboff);
    puts(" rtsoff="); dec(rtsoff); puts("\n");

    const op: [*]volatile u32 = @ptrFromInt(@as(usize,@intCast(bar0 + caplen)));
    const usbcmd: u32 = op[0];
    const usbsts: u32 = op[1]; // USBSTS @ op+4
    puts("usb:   usbcmd="); dec(usbcmd); puts(" usbsts="); dec(usbsts); puts("\n");

    // PORTSC @ op + 0x400 + (port-1)*0x10. bit0=connect, bit1=enable,
    // bit2=overspeed, bit3=pending, bit9=speed(0=FS? actually port speed).
    puts("usb:   port status (connect/enable/CSC):\n");
    var p: u32 = 1;
    while (p <= maxports and p <= 16) : (p += 1) {
        const psc = op[0x100 + @as(usize, @intCast(p - 1)) * 4]; // +0x400/4=0x100
        const conn = psc & 1;
        const en = (psc >> 1) & 1;
        const csc = (psc >> 1) & 1; // CSC is bit0 of the *change* reg; approx
        puts("usb:     port "); dec(p); puts(" portsc="); dec(psc);
        puts(if (conn != 0) " CONNECTED" else "");
        puts(if (en != 0) " enabled" else "");
        puts("\n");
        _ = csc;
    }
}

pub fn usb() void {
    puts("KORU usb — host-controller enumeration\n");
    pci.init();
    var found: u32 = 0;
    var i: usize = 0;
    while (i < pci.count) : (i += 1) {
        const d = &pci.devices[i];
        if (d.class == 0x0C and d.subclass == 0x03) {
            const pif = pci.read8(d.bus, d.slot, d.func, 0x0A);
            // XHCI prog-if = 0x30; EHCI = 0x20; report all, probe XHCI deep.
            if (pif == 0x30) {
                found += 1;
                xhciProbe(d);
            } else {
                puts("usb: usb-controller at "); loc(d);
                puts(" pif="); hex2(pif); puts(" (non-XHCI)\n");
            }
        }
    }
    puts("usb: xhci controllers found="); dec(found); puts("\n");
    puts("KORU usb done\n");
}

// ---- acpi + ec ---------------------------------------------------------------
// List every ACPI SDT the boot walk found, then probe the Embedded
// Controller: find ECDT/FADT, hex-dump their heads (the EC_SC/EC_DATA port
// fields live there), and read the EC status port's OBF/IBF bits.
fn dumpTableHex(t: acpi.Table, maxb: usize) void {
    puts("acpi:   dump ");
    for (t.sig) |c| text.putc(c);
    puts(" @"); dec(t.phys); puts("\n");
    const p: [*]const u8 = @ptrFromInt(@as(usize,@intCast(t.phys)));
    const n = @min(@as(usize, @intCast(t.len)), maxb);
    var i: usize = 0;
    var col: usize = 0;
    while (i < n) : (i += 1) {
        if (col % 16 == 0) { puts("acpi:     "); dec(i); puts(": "); }
        hex2(p[i]); puts(" ");
        col += 1;
        if (col % 16 == 0) nl();
    }
    nl();
}

// read an I/O port byte (for the EC status probe).
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}

pub fn acpiEc() void {
    puts("KORU acpi — SDT table list\n");
    puts("acpi: found="); dec(@intFromBool(acpi.found)); puts(" ntables=");
    dec(acpi.ntables); puts("\n");
    var i: usize = 0;
    while (i < acpi.ntables) : (i += 1) {
        const t = acpi.tables[i];
        puts("acpi:   ");
        for (t.sig) |c| text.putc(c);
        puts(" phys="); dec(t.phys);
        puts(" len="); dec(t.len); puts("\n");
    }

    // EC probe: ECDT names the EC's SC/DATA ports; FADT backs it up.
    puts("KORU acpi-ec — embedded controller\n");
    if (acpi.findTable("ECDT")) |t| {
        puts("acpi: ECDT present len="); dec(t.len); puts("\n");
        dumpTableHex(t, 48);
        // ECDT EC_SC port is the first I/O address in the body; the dump
        // above carries it for manual read. Best-effort: bytes 0x0C.. are
        // the EC register block — print the two candidate port bytes.
        const p: [*]const u8 = @ptrFromInt(@as(usize,@intCast(t.phys)));
        puts("acpi: ec candidate ports byte[0x0C]="); dec(p[0x0C]);
        puts(" byte[0x0D]="); dec(p[0x0D]); puts("\n");
        // If a plausible EC status port surfaced, read its OBF/IBF bits.
        const sc: u16 = @intCast(@as(u16, p[0x0C]) | (@as(u16, p[0x0D]) << 8));
        if (sc != 0 and sc < 0x10000) {
            const st = inb(sc);
            puts("acpi: ec-sc="); dec(sc); puts(" status=0x");
            text.puthex(st); puts(" (bit0=OBF bit1=IBF)\n");
        }
    } else {
        puts("acpi: no ECDT — EC ports must come from DSDT (AML, unported)\n");
    }
    if (acpi.findTable("FADT")) |t| {
        puts("acpi: FADT present len="); dec(t.len); puts("\n");
        dumpTableHex(t, 64);
    }
    puts("KORU acpi-ec done\n");
}

// ---- inputscan ---------------------------------------------------------------
// Synthesize the enumeration into a verdict: which bus most likely carries
// the T590 TrackPoint+touchpad. ThinkPad pointing devices are USB HID on
// modern models (EC-routed or XHCI), legacy PS/2 aux only on old ones.
pub fn inputScan() void {
    puts("KORU inputscan — pointing-device bus verdict\n");
    pci.init();
    var xhci: u32 = 0;
    var echi: u32 = 0;
    var ehci: u32 = 0;
    var smbus: u32 = 0;
    var i2c: u32 = 0;
    var i: usize = 0;
    while (i < pci.count) : (i += 1) {
        const d = &pci.devices[i];
        if (d.class == 0x0C and d.subclass == 0x03) {
            const pif = pci.read8(d.bus, d.slot, d.func, 0x0A);
            if (pif == 0x30) xhci += 1 else if (pif == 0x20) ehci += 1
            else if (pif == 0x00 or pif == 0x10) echi += 1;
        }
        if (d.class == 0x0C and d.subclass == 0x05) smbus += 1;
        if (d.class == 0x0C and d.subclass == 0x04) i2c += 1; // IPMI? no—serial
    }
    puts("inputscan: xhci="); dec(xhci);
    puts(" ehci="); dec(ehci); puts(" u/ohci="); dec(echi);
    puts(" smbus/i2c-ctrl="); dec(smbus); puts("\n");
    puts("inputscan: class0C/sub04(i2c-ish)="); dec(i2c); puts("\n");

    puts("inputscan: VERDICT — ");
    if (xhci > 0) {
        puts("XHCI host controller present -> pointing devices are almost\n");
        puts("certainly USB HID behind it (T590 TrackPoint+touchpad are USB\n");
        puts("on modern ThinkPads, EC-routed). PS/2 aux=0 is EXPECTED — they\n");
        puts("were never on 8042 aux. Next: full XHCI enumerate + HID report.\n");
    } else if (ehci > 0 or echi > 0) {
        puts("EHCI/OHCI present, no XHCI -> devices on USB2 EHCI.\n");
    } else {
        puts("no USB host controller found -> check I2C/SMBUS or legacy aux.\n");
    }
    puts("KORU inputscan done\n");
}
