/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M7: input.* driver rows, the seam between an input provider (here the
 * native i8042 PS/2 keyboard, ps2kbd.c) and the Linux evdev personality
 * (evdev_linux.c, /dev/input/event0). Same shape as kms_rows.h in M6: a later
 * provider (DS3 silo, virtio-input over a modern transport) binds the same rows.
 */
#ifndef KORU_INPUT_ROWS_H
#define KORU_INPUT_ROWS_H
#include <stdint.h>

struct input_provider {
	const char *name;	/* EVIOCGNAME */
	const char *phys;	/* EVIOCGPHYS */
	uint16_t bustype, vendor, product, version;	/* EVIOCGID */
	/* capability bitmaps in Linux layout (bit n of byte n/8) */
	uint8_t evbits[4];	/* EV_* */
	uint8_t keybits[96];	/* KEY_* up to KEY_MAX 0x2ff */
	uint8_t mscbits[1];	/* MSC_* */
	uint8_t ledbits[2];	/* LED_* */
	unsigned int rep_delay_ms, rep_period_ms;	/* EVIOCGREP */
};

/* Provider -> personality. Called from thread context (never from an IRQ). */
int input_rows_bind(struct input_provider *p);
void input_rows_event(uint16_t type, uint16_t code, int32_t value);

#endif
