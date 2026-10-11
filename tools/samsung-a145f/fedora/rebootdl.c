/* Tiny static helper: reboot(RESTART2, "download") -> Samsung download mode. */
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>
int main(int argc, char **argv)
{
	const char *arg = argc > 1 ? argv[1] : "download";
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, arg);
	return 1;
}
