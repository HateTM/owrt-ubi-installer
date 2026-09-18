#!/bin/sh

. /lib/upgrade/nand.sh

BOARD_NAME=$(cat /proc/device-tree/compatible | tr '\0' '\n' | head -1 | tr ',' '_')

# LED definitions for the installer initramfs.
# These are used to signal installer status and errors to the user via the board's LED(s).
LED_BLUE="B"
LED_GREEN="G"
LED_RED="R"

led_reset() {
	echo none > /sys/class/leds/${LED_BLUE}/trigger
	echo none > /sys/class/leds/${LED_GREEN}/trigger
	echo none > /sys/class/leds/${LED_RED}/trigger
	echo 0 > /sys/class/leds/${LED_BLUE}/brightness
	echo 0 > /sys/class/leds/${LED_GREEN}/brightness
	echo 0 > /sys/class/leds/${LED_RED}/brightness
}

# Installation complete: solid LED.
led_done() {
	led_reset
	echo 255 > /sys/class/leds/${LED_RED}/brightness
	echo 255 > /sys/class/leds/${LED_GREEN}/brightness
}

# Flashing in progress: LED with a short delay to indicate activity.
led_run() {
	led_reset
	echo timer > /sys/class/leds/${LED_GREEN}/trigger
	echo 1 > /sys/class/leds/${LED_GREEN}/delay_on
	echo 70 > /sys/class/leds/${LED_GREEN}/delay_off
}

# Error state: LED with a long delay to indicate a problem.
led_error() {
	led_reset
	echo timer > /sys/class/leds/${LED_RED}/trigger
	echo 120 > /sys/class/leds/${LED_RED}/delay_on
	echo 200 > /sys/class/leds/${LED_RED}/delay_off
}

# All installer messages go to the kernel ring buffer so they appear in both
# the live console and the dmesg.log saved to the boot_backup UBI volume.
log () {
	echo "INSTALLER: $@" > /dev/kmsg
}

# On unrecoverable error: signal failure via LED, wait for the message to be
# visible to anyone watching serial, then panic the kernel. A kernel panic is
# intentional here — it produces a crash dump and prevents the board from
# silently booting into a half-installed state.
trigger_crash() {
	led_error
	sleep 5
	log "$@"
	echo c > /proc/sysrq-trigger
}

led_run

sleep 1

echo
log "OpenWrt UBI installer (${BOARD_NAME})"
echo

INSTALLER_DIR="/installer"
PRELOADER="$(ls -1 $INSTALLER_DIR/mt7986-*-bl2.img)"
FIP="$INSTALLER_DIR/mt7986_${BOARD_NAME}-u-boot.fip"
# Use ls to resolve the wildcard at runtime so the script does not need to
# hardcode the OpenWrt build version string in the filename.
RECOVERY="$(ls -1 $INSTALLER_DIR/openwrt-*mediatek-filogic-${BOARD_NAME}-initramfs-recovery.itb)"

# These flags allow selectively skipping volume creation.
HAS_ENV=1
HAS_FIP=1
HAS_FACTORY=1
# The backup volume takes storage space - make it optional
HAS_BACKUP=1

if [ ! -s "$PRELOADER" ] || [ ! -s "$FIP" ] || [ ! -s "$RECOVERY" ]; then
	trigger_crash "Missing files. Aborting."
fi

# UBI device nodes are not created by udev in the installer initramfs, so we
# create them manually from the sysfs uevent attributes after each attach/mkvol.
ubi_mknod() {
	local dev="$1"
	dev="${dev##*/}"
	[ -e "/sys/class/ubi/$dev/uevent" ] || return 2
	. "/sys/class/ubi/$dev/uevent"
	mknod "/dev/$dev" c $MAJOR $MINOR
}

# The calibration blob can be in one of two places, depending on what the
# device was running before. Coming from the partial-UBI layout it is the real
# factory partition, which the target map puts at the very start of mtd1.
# Coming from the stock layout the user stages a prepared blob into the
# userconfig partition (flash 0x6700000), which lands further in. Both are
# checked, and whichever validates is used.
FACTORY_OFFSETS="0x0 0x6600000"

# Validate a candidate blob: it must carry the EEPROM magic and a MAC that is
# not simply erased flash. Getting this wrong means formatting over calibration
# data that cannot be recovered, so a failed check aborts the install.
factory_blob_valid() {
	local magic mac

	# The chip ID is stored as a little-endian u16 (bytes 86 79 on flash),
	# which hexdump's default 2-byte unit prints as 7986.
	magic="$(hexdump -v -n 2 -e '"%02x"' /tmp/factory 2>/dev/null)"
	[ "$magic" = "7986" ] || return 1

	# Print the MAC byte by byte; with the default unit hexdump would swap
	# every pair and the logged address would not match the device.
	mac="$(hexdump -v -s 32768 -n 6 -e '6/1 "%02x"' /tmp/factory 2>/dev/null)"
	case "$mac" in
	ffffffffffff|000000000000|"")
		return 1
		;;
	esac

	log "factory data looks good, MAC $mac"
}

install_get_factory() {
	local mtddev="$1"
	local ebs=$(cat /sys/class/mtd/$(basename $mtddev)/erasesize)
	local off skip

	for off in $FACTORY_OFFSETS; do
		skip=$(( $off / ebs ))
		log "looking for factory data at offset $(printf %08x $((off)))"
		dd if=$mtddev bs=$ebs skip=$skip count=1 of=/tmp/factory 2>/dev/null

		if factory_blob_valid; then
			return 0
		fi
	done

	rm -f /tmp/factory
	return 1
}

# Back up raw MTD regions before we erase anything. These are preserved in the
# boot_backup UBI volume so the original bootloader and calibration data can be
# recovered if the install goes wrong.
install_prepare_mtd_backup() {
	log "preparing backup of the $2 from mtd$1 ${3:+using $3 blocks} ${4:+after skipping first $4 blocks}"
	local mtdnum=$1
	local ebs=$(cat /sys/class/mtd/mtd${mtdnum}/erasesize)
	dd bs=$ebs if=/dev/mtd${mtdnum} of=/tmp/boot_backup/$2.bin ${3:+count=$3} ${4:+skip=$4}
}

# Write all pre-install backups into a dedicated UBI volume.
install_write_backup() {
	log "writing backup to ubi volume..."
	ubimkvol /dev/ubi0 -n 6 -s $(du -b "/tmp/boot_backup.tar.gz" | awk '{print $1}') -N boot_backup
	ubi_mknod ubi0_6 && ubiupdatevol /dev/ubi0_6 "/tmp/boot_backup.tar.gz"
	log "Done."
}

# Format the UBI partition and populate the fixed-layout volumes expected by
# the OpenWrt U-Boot port for this board:
#   vol 0  fip       - BL31 + U-Boot FIP image (static)
#   vol 1  factory   - Wi-Fi EEPROM / calibration data (static)
#   vol 2  ubootenv  - primary U-Boot environment store
#   vol 3  ubootenv2 - redundant U-Boot environment store
# Volumes 4 (recovery), 5 (fit), and 6 (boot_backup) are written separately.
install_prepare_ubi() {
	log "preparing UBI on $1"
	local mtddev=$1
	[ -e /sys/class/ubi/ubi0 ] && ubidetach -p $mtddev
	ubiformat -y $mtddev
	sleep 1
	ubiattach -p $mtddev
	sync
	sleep 1
	[ -e /dev/ubi0 ] || ubi_mknod ubi0
	[ "$HAS_FIP" = "1" ] && ubimkvol /dev/ubi0 -n 0 -t static -s $(du -b $FIP | awk '{print $1}') -N fip && \
		ubi_mknod ubi0_0 && ubiupdatevol /dev/ubi0_0 "$FIP"
	[ "$HAS_FACTORY" = "1" ] && ubimkvol /dev/ubi0 -n 1 -t static -s $(du -b "/tmp/factory" | awk '{print $1}') -N factory && \
		ubi_mknod ubi0_1 && ubiupdatevol /dev/ubi0_1 "/tmp/factory"
	[ "$HAS_ENV" = "1" ] && ubimkvol /dev/ubi0 -n 2 -s 126976 -N ubootenv && ubimkvol /dev/ubi0 -n 3 -s 126976 -N ubootenv2
}

# The installer runs with the new all-in-UBI device tree, so the partition map
# it sees is already the target one, laid over the old on-flash contents:
#   mtd0 = bl2 (0x000000-0x0fffff), unchanged by the conversion
#   mtd1 = ubi (0x100000-0x7ffffff), the region being converted
# Coming from the previous layout, mtd1 starts with the old raw factory
# partition in its first erase block, followed by the old UBI content.
if [ "$HAS_BACKUP" = "1" ]; then
	log "backing up bl2 and factory from mtd0, mtd1 before erase"
	mkdir -p /tmp/boot_backup
	install_prepare_mtd_backup 0 bl2
	# 8 erase blocks x 128 KiB = the full 1 MiB factory region of the previous
	# layout; the calibration data itself lives in the first block, but the
	# whole region is kept so the device can be restored to stock.
	install_prepare_mtd_backup 1 factory 8

	# Create a compressed archive of the backup files and remove the temporary directory.
	tar czvf /tmp/boot_backup.tar.gz -C /tmp boot_backup && rm -rf /tmp/boot_backup
fi

# Extract Wi-Fi calibration data before erasing mtd1. Loss of this data
# requires physical access to restore and will break wireless permanently.
install_get_factory /dev/mtd1 || trigger_crash "factory data not found - was the preparation step run?"

# BL2 is written at the start of the raw bl2 partition.
for bl2start in 0x0 ; do
	log "write bl2 at offset $bl2start"
	mtd -p $bl2start write $PRELOADER /dev/mtd0 || \
	log "bl2 write to mtd0 at offset $bl2start failed"
done

# mtd1 holds everything above BL2: env, factory, FIP, and the UBI partition.
# This call erases and reformats it entirely.
install_prepare_ubi /dev/mtd1

log "write recovery ubi volume"
RECOVERY_SIZE=$(du -b $RECOVERY | awk '{print $1}')
ubimkvol /dev/ubi0 -n 4 -s $RECOVERY_SIZE -N recovery
ubi_mknod ubi0_4 && ubiupdatevol /dev/ubi0_4 $RECOVERY

# Reserve a minimal dynamic volume for the production FIT image. It will be
# populated on first boot by the sysupgrade or TFTP flow in U-Boot.
log "create fit ubi volume"
ubimkvol /dev/ubi0 -n 5 -s 126976 -N fit

if [ "$HAS_BACKUP" = "1" ]; then
	install_write_backup
fi

sync

# Lime = done. The 5s pause makes the state visible before the board disappears
# from the console on reboot.
led_done

sleep 5

reboot -f
