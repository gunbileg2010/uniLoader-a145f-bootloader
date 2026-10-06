// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2022, Ivaylo Ivanov <ivo.ivanov.ivanov1@gmail.com>
 */

#include <board.h>
#include <drivers/framework.h>
#include <lib/console.h>
#include <main/boot.h>
#include <main/main.h>
#include <lib/debug.h>

extern struct board_data board_ops;

static void print_splash(void)
{
	printk(KERN_INFO, "passed board initialization\n");
	printk(KERN_INFO, "finally booted into bootloader %s on %s\n", VER_TAG, board_ops.name);
}

void main(void* dt, void* kernel, void* ramdisk)
{
	early_console_init();
	INITCALL(board_ops.ops.early_init);

	driver_probe_all(board_ops.devices, board_ops.num_devices);

	print_splash();

	INITCALL(board_ops.ops.late_init);

	boot_kernel(dt, kernel, ramdisk);

	// todo: reset the board?
	printk(KERN_EMERG, "Something wrong happened, we shouldn't be here. Hanging....\n");
	HANG();
}
