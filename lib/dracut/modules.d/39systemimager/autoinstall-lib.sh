#!/bin/sh
#
# "SystemImager" 
# funtions related to imaging script only.
#
#  Copyright (C) 2017 Olivier LAHAYE <olivier.lahaye1@free.fr>
#
#  $Id$
#  vi: set filetype=sh et ts=4:
#

type logmessage >/dev/null 2>&1 || . /lib/systemimager-lib.sh

################################################################################
#
#   Save the SIS imaging relevant logs to /root/SIS_Install_logs/ on the imaged
#   computer.
#
#
#
save_logs_to_sysroot() {
    loginfo "========================="
    loginfo "Saving logs to /sysroot/root..."
    if test -d /sysroot/root
    then
        mkdir -p /sysroot/root/SIS_Install_logs/
        cp /tmp/variables.txt /sysroot/root/SIS_Install_logs/
        cp /tmp/dhcp_info.${DEVICE} /sysroot/root/SIS_Install_logs/
        cp /tmp/si_monitor.log /sysroot/root/SIS_Install_logs/
        cp /tmp/si.log /sysroot/root/SIS_Install_logs/
	echo ${IMAGENAME} > /sysroot/root/SIS_Install_logs/image.txt
        test -f /run/initramfs/rdsoreport.txt && cp /run/initramfs/rdsoreport.txt /sysroot/root/SIS_Install_logs/
    else
        logwarn "/sysroot/root does not exists"
        shellout
    fi
}

################################################################################
#
# Find system filesystems and store them in /tmp/system_mounts.txt
# This file will be used to bind mount and unmount those filesystems in the image
# so the postinstall will work.
#
find_os_mounts() {
    loginfo "System specific mounted filesystems enumeration"
    findmnt -o target --raw|grep -v /sysroot |grep -v '^/$'|tail -n +2 > /tmp/system_mounts.txt
    loginfo "Found:"
    loginfo "$(cat /tmp/system_mounts.txt)"
    test -s "/tmp/system_mounts.txt" || shellout
}

################################################################################
#
# Mount OS virtual filesystems for /sysroot so chrooted cmd can work.
#
#
mount_os_filesystems_to_sysroot() {
    # 1st, we enumerates what filesystems to bindmount
    find_os_mounts
    # 2nd, then we do the binds.
    loginfo "bindin OS filesystems to image"
    test -s /tmp/system_mounts.txt || shellout
    for filesystem in $(cat /tmp/system_mounts.txt)
    do
        loginfo "Binding mount point ${filesystem} to /sysroot${filesystem} ."
        test -d "/sysroot${filesystem}" || mkdir -p "/sysroot${filesystem}" || shellout
        # In case of failure, we die as next steps will fail.
        mount -o bind "${filesystem}" "/sysroot${filesystem}" || shellout
    done
}

################################################################################
#
# Umount OS virtual filesystems from /sysroot so umount /sysroot can succeed later
#
#

umount_os_filesystems_from_sysroot()
{
    loginfo "Unmounting OS filesystems from image"
    test -s /tmp/system_mounts.txt || shellout
    # using tac (reverse cat) to unmount in the correct umount order.
    for mountpoint in $(tac /tmp/system_mounts.txt)
    do
        if test -d $mountpoint
        then
            if umount /sysroot${mountpoint}
            then
                loginfo "unmounted /sysroot${mountpoint}"
                return 0
            else
                # In case of failure we just report the issue. (imaging is finished in theory)".
                logwarn " failed to umount /sysroot${mountpoint}"
                return 1
            fi
        fi
    done
}

