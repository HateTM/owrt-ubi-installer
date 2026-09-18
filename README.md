## An OpenWrt UBI Installer Image Generator for TP-Link Archer AX80 v1

> [!WARNING]
> This will replace the bootloader (TF-A 2.13, U-Boot 2025.10) and convert the flash layout of the device to an all-in-UBI layout. The installer stores a copy of the previous bootchain in a dedicated UBI volume `boot_backup`.

> [!CAUTION]
>Re-flashing the installer when the device is already using UBI flash layout will erase the previously backed up bootchain, which in most cases would be the vendor/official one.

If you plan to ever go back to the stock firmware, you will need a backup of the vendor bootchain and firmware.

> [!CAUTION]
> The installer is meant to be executed only once per device.

## Table of Contents
* [Script information](#script-information)
* [Installing OpenWrt](#installing-openwrt)
* [Enter recovery mode under OpenWrt](#enter-recovery-mode-under-openwrt)


## Script information

This script downloads the OpenWrt ImageBuilder to generate a firmware upgrade image compatible with the stock firmware which will automatically carry out the installation. The process involves re-packaging the *initramfs* image to contain everything necessary for a permanent installation of a replacement Das U-Boot bootloader, ARM TrustedFirmware-A and an OpenWrt recovery (initramfs) image within the NAND flash, plus the installer script itself.

You'll need the below to use the script to generate the installer image:
* All [prerequisites of the OpenWrt ImageBuilder](https://openwrt.org/docs/guide-user/additional-software/imagebuilder#prerequisites) 
* `libfdt-dev`
* `cmake`
* `zstd`

**If you are not interested in building yourself**, the pre-built files are available [here](https://github.com/HateTM/owrt-ubi-installer/releases).

## Building and Publishing a Release

To build the installer and publish it for others to use:

1. Build the OpenWrt images (recovery, sysupgrade, and Image Builder) for the `tplink_archer-ax80-v1-ubi` board target.

2. Generate a checksum manifest covering the three image artifacts:
   ```shell
   sha256sum openwrt-${OPENWRT_RELEASE}-mediatek-filogic-${BOARD_NAME}-initramfs-recovery.itb \
             openwrt-${OPENWRT_RELEASE}-mediatek-filogic-${BOARD_NAME}-squashfs-sysupgrade.itb \
             openwrt-imagebuilder-${OPENWRT_RELEASE}-mediatek-filogic.Linux-x86_64.tar.zst > sha256sums
   ```

3. Sign the manifest with your GPG key:
   ```shell
   gpg --detach-sign --armor -u 0xE45257FFB6039696 sha256sums
   ```
   This produces `sha256sums.asc`.

4. Create a GitHub release with a tag matching the `OPENWRT_RELEASE` value in `build_installer.sh` (e.g., `25.12.5`), and upload the following assets:
   - `sha256sums`
   - `sha256sums.asc`
   - All three images from step 1

5. Publish your signing key to a public keyserver so others can verify the signature:
   ```shell
   gpg --keyserver keys.openpgp.org --send-keys 0xE45257FFB6039696
   ```
   Note: Your key's email address must be verified with keys.openpgp.org before the key is served with its user ID.

The installer script will fetch and verify the signature on `sha256sums` before using any of the checksums, ensuring that only releases signed with this key are trusted.

## Installing OpenWrt all-in-UBI

1. Ensure your router is running the latest generic OpenWrt firmware. Upgrade it if necessary.

2. Assign IP 192.168.1.254/24 to your computer's Ethernet port

3. Connect Ethernet to the 1GE LAN port

4. Open browser and visit http://192.168.1.1

5. Prepare and stage the Wi-Fi calibration data. Connect to your device via SSH and run these commands to build a calibration blob from your device's stored EEPROM and MAC address:

   ```shell
   dd if=/dev/zero bs=32768 count=1 | tr '\000' '\377' > /tmp/factory.bin
   dd if=/tmp/tp_data/MT7986_EEPROM.bin of=/tmp/factory.bin conv=notrunc
   cat /tmp/tp_data/default-mac >> /tmp/factory.bin
   mtd write /tmp/factory.bin userconfig
   ```

   This builds the calibration blob from your device's own data: the Wi-Fi EEPROM at offset 0 and the MAC address at offset 0x8000. It is stored in the `userconfig` partition, which the conversion will discard anyway. The installer will refuse to proceed if it cannot find and validate this blob, so if you skip this step it will abort rather than destroy your calibration data. Before proceeding, make sure you also keep an independent backup of `/tmp/tp_data` off the device.

6. Flash `openwrt-[version]-mediatek-filogic-tplink_archer-ax80-v1-ubi-initramfs-recovery-installer.itb` via sysupgrade.

7. Once OpenWrt initramfs system comes up, do sysupgrade using
   `openwrt-[version]-mediatek-filogic-tplink_archer-ax80-v1-ubi-squashfs-sysupgrade.itb`

## Backup stock/vendor bootchain

Connect to the device via SSH and enter the following command:

```shell
cat /dev/ubi0_6 | tar xzv -C /tmp
```

Then, copy the files under `/tmp/boot_backup` using *scp* to your computer. These files are needed in case you want to restore the original/vendor firmware. They can also be used in emergency case for reflashing via [UART].


## Enter recovery mode under OpenWrt


#### Using the RESET button:

1. Hold down the "reset" button whilst powering on the device.

2. Release the button once the status LED turns into red.

This will remove any user configuration and allow restoring or upgrading from [ssh](https://openwrt.org/docs/guide-user/installation/sysupgrade.cli)/http/[tftp](https://openwrt.org/docs/guide-user/installation/generic.flashing.tftp).

#### Using PSTORE/ramoops

1. While running the production firmware enter this command in the shell

   ```shell
   echo c > /proc/sysrq-trigger
   ```

2. Once the router has rebooted into recovery mode, clear PSTORE to make it reboot into production mode again:

   ```shell
   rm /sys/fs/pstore/*
   ```

This keep user configuration but still allow restoring or upgrading from [ssh](https://openwrt.org/docs/guide-user/installation/sysupgrade.cli)/http/[tftp](https://openwrt.org/docs/guide-user/installation/generic.flashing.tftp).
