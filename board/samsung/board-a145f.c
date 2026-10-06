/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (c) 2026, schoosh212 <superaviation001@gmail.com>
 * Copyright (c) 2024, Ivaylo Ivanov <ivo.ivanov.ivanov1@gmail.com>
 * Copyright (c) 2026, gunbileg naranbaatar <gunbileg2010@gmail.com>
 */
#include <board.h>
#include <util.h>
#include <drivers/framework.h>
#include <lib/simplefb.h>
#include <soc/exynos3830.h>
#include <lib/debug.h>
#include <stdint.h>

int a145f_init(void)
{
	/* Kick the Exynos 850 Display Controller (DECON) hardware trigger to flush buffer */
	*(int*) (DECON_F_BASE + HW_SW_TRIG_CONTROL) = 0x1281;
	return 0;
}

static struct video_info a145f_fb = {
	.format = FB_FORMAT_ARGB8888,
	.width = 1080,
	.height = 2408,
	.stride = 4,
	.address = (void *)0xfa000000
};

static const struct device a145f_devices[] = {
	{ "simplefb", &a145f_fb, "fb" },
};

#ifdef CONFIG_A145F_SHOW_PREV_LOG
/*
 * Bring-up aid: Samsung's debug-snapshot driver mirrors the kernel console
 * into a reserved RAM area ("log_kernel" in the device tree). It survives a
 * warm reboot, so after a failed boot we show the tail of the previous boot's
 * kernel log on screen before booting again. The text starts at the base of
 * the region; unused space is zero.
 */
#define RAMLOG_BASE	0xf0010000UL
#define RAMLOG_SIZE	0x200000UL
#define RAMLOG_LINES	38
#define RAMLOG_COLS	96

static void delay_seconds(unsigned int s)
{
	unsigned long freq, start, now;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	if (!freq)
		freq = 26000000UL;	/* Exynos 850 system counter */
	__asm__ volatile("mrs %0, cntpct_el0" : "=r"(start));
	do {
		__asm__ volatile("mrs %0, cntpct_el0" : "=r"(now));
	} while (now - start < freq * s);
}

static int a145f_late_init(void)
{
	const volatile unsigned char *log = (const volatile unsigned char *)RAMLOG_BASE;
	unsigned long end = 0, i, pos, nlines = 0, el, sctlr;
	unsigned long text = 0, nonzero = 0, probe = 4096;
	unsigned long starts[RAMLOG_LINES];
	char line[RAMLOG_COLS + 1];

	/* CPU state at hand-off: useful when a kernel does not come up. */
	__asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
	el >>= 2;
	if (el == 2)
		__asm__ volatile("mrs %0, sctlr_el2" : "=r"(sctlr));
	else
		__asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
	printk(KERN_INFO, "cpu: EL%d sctlr=%x (MMU %s, D-cache %s)\n", (int)el,
	       (unsigned int)sctlr, (sctlr & 1) ? "on" : "off",
	       (sctlr & 4) ? "on" : "off");

	/* Is there readable text from a previous boot? */
	for (i = 0; i < probe; i++) {
		if (!log[i])
			continue;
		nonzero++;
		if ((log[i] >= 32 && log[i] < 127) || log[i] == '\n')
			text++;
	}
	/* real text is >90% readable; random RAM garbage is not */
	if (nonzero < 64 || text * 100 < nonzero * 90) {
		printk(KERN_INFO, "previous kernel log: none (RAM log empty)\n");
		return 0;
	}

	/* Last non-zero byte = end of what the kernel wrote. */
	for (i = 0; i < RAMLOG_SIZE; i++)
		if (log[i])
			end = i + 1;

	/* Remember where the last RAMLOG_LINES lines start. */
	for (pos = end; pos > 0 && nlines < RAMLOG_LINES; pos--) {
		if (pos == end && log[pos - 1] == '\n')
			continue;
		if (log[pos - 1] == '\n') {
			starts[nlines++] = pos;
		}
	}
	if (nlines < RAMLOG_LINES)
		starts[nlines++] = 0;

	printk(KERN_INFO, "previous kernel log (%d bytes), last lines:\n", (int)end);
	while (nlines--) {
		unsigned long n = 0, p = starts[nlines];

		while (p < end && log[p] != '\n' && n < RAMLOG_COLS) {
			unsigned char c = log[p++];

			line[n++] = (c >= 32 && c < 127) ? c : '.';
		}
		line[n] = 0;
		printk(KERN_INFO, "%s\n", line);
	}
	printk(KERN_INFO, "--- end of previous log, continuing in 10s ---\n");
	delay_seconds(10);
	return 0;
}
#endif

struct board_data board_ops = {
	.name = "samsung-a145f",
	.ops = {
		.early_init = a145f_init,
#ifdef CONFIG_A145F_SHOW_PREV_LOG
		.late_init = a145f_late_init,
#endif
	},
	.devices = a145f_devices,
	.num_devices = ARRAY_SIZE(a145f_devices),
	.quirks = 0
};
