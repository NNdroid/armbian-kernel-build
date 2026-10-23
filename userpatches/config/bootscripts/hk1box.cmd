# HK1 Box / Vontar X3 - ophub Amlogic mainline U-Boot boot script
#
# Packaged as boot.cmd (readable source) and boot.scr (compiled):
#   mkimage -C none -A arm -T script -d boot.cmd boot.scr
#
# This body is the standard ophub Amlogic boot script, kept unchanged so it can
# double as a recovery copy when /boot/boot.scr is missing or corrupt. All values
# that change with a kernel release live in uEnv.txt, which is imported below.
#
# It relies on the vendor U-Boot to define kernel_addr_r, ramdisk_addr_r and
# fdt_addr_r; check with `printenv kernel_addr_r ramdisk_addr_r fdt_addr_r`
# before replacing an existing /boot/boot.scr.
echo "Start AMLOGIC mainline U-boot"
if printenv bootfromsd; then exit; fi;
setenv loadaddr "0x44000000"
setenv l_mmc "0 1 2 3"
for devtype in "usb mmc"; do
	if test "${devtype}" = "mmc"; then
		setenv l_mmc "1"
	fi
	for devnum in ${l_mmc}; do
		if test -e ${devtype} ${devnum} uEnv.txt; then
			load ${devtype} ${devnum} ${loadaddr} uEnv.txt
			env import -t ${loadaddr} ${filesize}
			setenv bootargs ${APPEND}
			if printenv mac; then
				setenv bootargs ${bootargs} mac=${mac}
			elif printenv eth_mac; then
				setenv bootargs ${bootargs} mac=${eth_mac}
			elif printenv ethaddr; then
				setenv bootargs ${bootargs} mac=${ethaddr}
			fi
			if load ${devtype} ${devnum} ${kernel_addr_r} ${LINUX}; then
				if load ${devtype} ${devnum} ${ramdisk_addr_r} ${INITRD}; then
					if load ${devtype} ${devnum} ${fdt_addr_r} ${FDT}; then
						fdt addr ${fdt_addr_r}
						booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
					fi
				fi
			fi
		fi
	done
done
