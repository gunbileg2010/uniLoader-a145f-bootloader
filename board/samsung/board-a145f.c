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

/* Busy-wait on the ARM generic timer (the system counter keeps running). */
static void __attribute__((unused)) delay_seconds(unsigned int s)
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

#ifdef CONFIG_A145F_SPLASH
#include "a145f-splash.h"

/*
 * Draw the embedded splash picture (palette + RLE, see
 * tools/samsung-a145f/make_splash.py). Centred when nothing else is printed,
 * at the bottom when the debug log screens use the top of the display.
 */
static void a145f_draw_splash(void)
{
	volatile unsigned int *fb = (volatile unsigned int *)a145f_fb.address;
	unsigned long total = (unsigned long)A145F_SPLASH_WIDTH * A145F_SPLASH_HEIGHT;
	unsigned long n = 0, i = 0;
	int x0 = (a145f_fb.width - A145F_SPLASH_WIDTH) / 2;
	int y0 = (a145f_fb.height - A145F_SPLASH_HEIGHT) / 2;

#ifdef CONFIG_A145F_SHOW_PREV_LOG
	y0 = a145f_fb.height - A145F_SPLASH_HEIGHT - 60;
#endif
	if (x0 < 0 || y0 < 0)
		return;
	while (n < total && i + 1 < A145F_SPLASH_RLE_LEN) {
		unsigned int run = a145f_splash_rle[i];
		unsigned int c = a145f_splash_pal[a145f_splash_rle[i + 1]];

		i += 2;
		while (run-- && n < total) {
			int x = x0 + (int)(n % A145F_SPLASH_WIDTH);
			int y = y0 + (int)(n / A145F_SPLASH_WIDTH);

			fb[(unsigned long)y * a145f_fb.width + x] = c;
			n++;
		}
	}
}
#endif

#ifdef CONFIG_A145F_SHOW_PREV_LOG
/*
 * Bring-up aid, shown on screen before booting again after a failed boot.
 * DRAM survives a warm reset, so two RAM areas are inspected:
 *
 *  1. "ramoops": a 1 MiB reserved area that make_a145f_blobs.py adds to the
 *     device tree. The kernel's pstore console writes everything it prints
 *     there from early boot on, which is the kernel's own log.
 *  2. "log_kernel": the debug-snapshot area at 0xf0010000. In practice it
 *     holds the stock bootloader's log (ends at "Starting kernel...").
 */
#define RAMOOPS_BASE	0x8fe00000UL
#define RAMOOPS_SIZE	0x100000UL
#define RAMOOPS_CON	(RAMOOPS_BASE + 0x80000UL)	/* console zone */
#define RAMOOPS_CON_SZ	0x80000UL
#define PRZ_SIG		0x43474244U			/* "DBGC" */
#define PRZ_HDR		12UL

#define BLLOG_BASE	0xf0010000UL
#define BLLOG_SIZE	0x200000UL

#define SHOW_LINES	12
#define SHOW_COLS	90
#define HOLD_SECONDS	40

struct ring {
	const volatile unsigned char *p;
	unsigned long bufsz;	/* ring size */
	unsigned long off;	/* index of oldest byte */
	unsigned long len;	/* valid bytes */
};

static inline unsigned char ring_at(const struct ring *r, unsigned long i)
{
	unsigned long k = r->off + i;

	return r->p[k >= r->bufsz ? k % r->bufsz : k];
}

/* Print the last SHOW_LINES lines of a ring, long lines truncated. */
static void ring_tail(const struct ring *r)
{
	unsigned long starts[SHOW_LINES], nlines = 0, pos, n, p;
	unsigned long end = r->len;
	char line[SHOW_COLS + 1];

	if (end && ring_at(r, end - 1) == '\n')
		end--;
	for (pos = end; pos > 0 && nlines < SHOW_LINES; pos--)
		if (ring_at(r, pos - 1) == '\n')
			starts[nlines++] = pos;
	if (nlines < SHOW_LINES)
		starts[nlines++] = 0;

	while (nlines--) {
		n = 0;
		p = starts[nlines];
		while (p < end && n < SHOW_COLS) {
			unsigned char c = ring_at(r, p++);

			if (c == '\n')
				break;
			line[n++] = (c >= 32 && c < 127) ? c : '.';
		}
		line[n] = 0;
		printk(KERN_INFO, "%s\n", line);
	}
}


static int ring_line_has(const struct ring *r, unsigned long p, unsigned long end,
			 const char *needle)
{
	unsigned long i, k;

	for (; p < end && ring_at(r, p) != '\n'; p++) {
		for (i = p, k = 0; needle[k] && i < end &&
		     ring_at(r, i) == (unsigned char)needle[k]; i++, k++)
			;
		if (!needle[k])
			return 1;
	}
	return 0;
}

static void ring_print_line(const struct ring *r, unsigned long p, unsigned long end)
{
	char line[SHOW_COLS + 1];
	unsigned long n = 0;

	while (p < end && n < SHOW_COLS) {
		unsigned char c = ring_at(r, p++);

		if (c == '\n')
			break;
		line[n++] = (c >= 32 && c < 127) ? c : '.';
	}
	line[n] = 0;
	printk(KERN_INFO, "%s\n", line);
}

/*
 * Show where a crash starts. The panic dump can be hundreds of lines, so jump
 * to the first line anywhere in the log that matches the most specific marker
 * and show a few lines before and after. Markers are tried in priority order;
 * the TZASC irq thread only reports a violation (it does not panic by itself),
 * so it is the last resort. Falls back to the plain tail.
 */
#define WIN_BEFORE	6
#define WIN_AFTER	12

static const char * const fault_needles[][3] = {
	{ "Kernel panic - not syncing", NULL, NULL },
	{ "Unable to handle kernel", "Internal error:", "Oops" },
	{ "BUG:", "Bad mode in", "SError" },
	{ "-tzasc:", "TZASC FAIL", NULL },
};
#define NUM_NEEDLE_PASSES (sizeof(fault_needles) / sizeof(fault_needles[0]))

static int line_is_fault(const struct ring *r, unsigned long p, unsigned long end,
			 unsigned int pass)
{
	unsigned int k;

	for (k = 0; k < 3; k++)
		if (fault_needles[pass][k] &&
		    ring_line_has(r, p, end, fault_needles[pass][k]))
			return 1;
	return 0;
}

static void ring_crash_window(const struct ring *r)
{
	unsigned long before[WIN_BEFORE], nb = 0, p = 0, end = r->len, q, i, hit = 0;
	int found = 0;
	unsigned int pass;

	if (end && ring_at(r, end - 1) == '\n')
		end--;
	for (pass = 0; pass < NUM_NEEDLE_PASSES && !found; pass++) {
		nb = 0;
		p = 0;
		while (p < end) {
			if (line_is_fault(r, p, end, pass)) {
				found = 1;
				hit = p;
				break;
			}
			/* remember this line start, keep the last WIN_BEFORE */
			if (nb < WIN_BEFORE) {
				before[nb++] = p;
			} else {
				for (i = 1; i < WIN_BEFORE; i++)
					before[i - 1] = before[i];
				before[WIN_BEFORE - 1] = p;
			}
			while (p < end && ring_at(r, p) != '\n')
				p++;
			p++;
		}
	}
	if (!found) {
		ring_tail(r);
		return;
	}
	for (i = 0; i < nb; i++)
		ring_print_line(r, before[i], end);
	printk(KERN_INFO, ">>> first match (pass %d):\n", (int)(pass - 1));
	q = hit;
	for (i = 0; i <= WIN_AFTER && q < end; i++) {
		ring_print_line(r, q, end);
		while (q < end && ring_at(r, q) != '\n')
			q++;
		q++;
	}
}

static void show_ramoops(void)
{
	const volatile unsigned int *h = (const volatile unsigned int *)RAMOOPS_CON;
	unsigned long z;
	struct ring r;
	unsigned int sig = h[0], start = h[1], size = h[2];
	unsigned long bufsz = RAMOOPS_CON_SZ - PRZ_HDR;

	if (sig != PRZ_SIG) {
		printk(KERN_INFO, "ramoops: no kernel log (sig=%x, expected %x)\n",
		       sig, PRZ_SIG);
		/* list any zone that does carry a signature */
		for (z = 0; z < RAMOOPS_SIZE; z += 0x20000) {
			const volatile unsigned int *zh =
				(const volatile unsigned int *)(RAMOOPS_BASE + z);

			if (zh[0] == PRZ_SIG)
				printk(KERN_INFO, "ramoops: zone +%x has sig, size=%x\n",
				       (unsigned int)z, zh[2]);
		}
		return;
	}
	if (size > bufsz || start >= bufsz || !size) {
		printk(KERN_INFO, "ramoops: bad header start=%x size=%x\n",
		       start, size);
		return;
	}
	r.p = (const volatile unsigned char *)(RAMOOPS_CON + PRZ_HDR);
	r.bufsz = bufsz;
	r.len = size;
	r.off = (start + bufsz - size) % bufsz;	/* oldest byte */
	printk(KERN_INFO, "KERNEL LOG (ramoops, %d bytes), crash start:\n", (int)size);
	ring_crash_window(&r);
	printk(KERN_INFO, "--- end of kernel log, holding %ds ---\n", HOLD_SECONDS);
	delay_seconds(HOLD_SECONDS);
}

static void show_bootloader_log(void)
{
	const volatile unsigned char *log = (const volatile unsigned char *)BLLOG_BASE;
	unsigned long i, end = 0, text = 0, nonzero = 0;
	struct ring r;

	for (i = 0; i < 4096; i++) {
		if (!log[i])
			continue;
		nonzero++;
		if ((log[i] >= 32 && log[i] < 127) || log[i] == '\n')
			text++;
	}
	if (nonzero < 64 || text * 100 < nonzero * 90) {
		printk(KERN_INFO, "log_kernel: empty\n");
		return;
	}
	for (i = 0; i < BLLOG_SIZE; i++)
		if (log[i])
			end = i + 1;

	/* raw view of the last 48 bytes, so odd data is readable */
	printk(KERN_INFO, "log_kernel: %d bytes, last 48 raw:\n", (int)end);
	for (i = end > 48 ? end - 48 : 0; i < end; i += 16) {
		unsigned long j, m = end - i < 16 ? end - i : 16;
		char hex[16 * 3 + 1];
		static const char d[] = "0123456789abcdef";

		for (j = 0; j < m; j++) {
			hex[j * 3] = d[log[i + j] >> 4];
			hex[j * 3 + 1] = d[log[i + j] & 15];
			hex[j * 3 + 2] = ' ';
		}
		hex[m * 3] = 0;
		printk(KERN_INFO, "%x: %s\n", (unsigned int)i, hex);
	}
	/* keep the text view short: this is the bootloader's log */
	r.p = log;
	r.bufsz = BLLOG_SIZE;
	r.off = 0;
	for (i = end; i > 0 && log[i - 1] < 32 && log[i - 1] != '\n'; i--)
		;
	r.len = i;
	printk(KERN_INFO, "log_kernel text tail:\n");
	ring_tail(&r);
}

static void a145f_show_debug(void)
{
	unsigned long el, sctlr;

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

	show_ramoops();
	show_bootloader_log();
	printk(KERN_INFO, "--- continuing in 10s ---\n");
	delay_seconds(10);
}
#endif

#if defined(CONFIG_A145F_SPLASH) || defined(CONFIG_A145F_SHOW_PREV_LOG)
static int a145f_late_init(void)
{
#ifdef CONFIG_A145F_SPLASH
	a145f_draw_splash();
#ifndef CONFIG_A145F_SHOW_PREV_LOG
	delay_seconds(CONFIG_A145F_SPLASH_HOLD);
#endif
#endif
#ifdef CONFIG_A145F_SHOW_PREV_LOG
	a145f_show_debug();
#endif
	return 0;
}
#endif

struct board_data board_ops = {
	.name = "samsung-a145f",
	.ops = {
		.early_init = a145f_init,
#if defined(CONFIG_A145F_SPLASH) || defined(CONFIG_A145F_SHOW_PREV_LOG)
		.late_init = a145f_late_init,
#endif
	},
	.devices = a145f_devices,
	.num_devices = ARRAY_SIZE(a145f_devices),
	.quirks = 0
};
