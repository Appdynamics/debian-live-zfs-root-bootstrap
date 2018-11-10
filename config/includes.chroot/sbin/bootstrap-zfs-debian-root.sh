#!/bin/bash

#FIXME add a -h option.

USAGE="\
Usage: bootstrap-zfs-debian-root.sh <rootpool> [pooltwo]...

Installs bootable Debian root filesystem to the specified ZFS pool(s).
"

ROOT_POOL=$1
DISTRO_NAME=stretch
ROOT_CONTAINER_FS="${ROOT_POOL}/ROOT"
ROOTFS="${ROOT_CONTAINER_FS}/debian"
STAGE2_BOOTSTRAP=stage-2-bootstrap.sh

declare -a ZFS_DATASETS
declare -a ZFS_DATASET_OPTS

# Appends zfs dataset information to ZFS_DATASETS and ZFS_DATASET_OPTS arrays
# usage:
# eval `append_dataset <dataset_name> [dataset_opt1=foo] [dataset_opt2=bar] ...`
append_dataset(){
    echo 'ZFS_DATASETS+=( "'$1'" )'
    shift 1
    echo 'ZFS_DATASET_OPTS+=( "'$@'" )'
}

eval `append_dataset "$ROOT_CONTAINER_FS" canmount=off mountpoint=none`
eval `append_dataset "$ROOTFS" mountpoint=/`
eval `append_dataset "$ROOT_POOL/home" setuid=off`
eval `append_dataset "$ROOT_POOL/home/root" mountpoint=/root`
eval `append_dataset "$ROOT_POOL/var" canmount=off setuid=off exec=off`
# FIXME: https://github.com/zfsonlinux/zfs/pull/7329 may to change the way /var/lib is mounted
eval `append_dataset "$ROOT_POOL/var/lib" mountpoint=legacy exec=on`
eval `append_dataset "$ROOT_POOL/var/cache" com.sun:auto-snapshot=false`
eval `append_dataset "$ROOT_POOL/var/log"`
eval `append_dataset "$ROOT_POOL/var/spool"`
eval `append_dataset "$ROOT_POOL/var/tmp" com.sun:auto-snapshot=false exec=on`

sigint_handler(){
    >&2 echo "Caught SIGINT.  Exiting."
    exit
}

reverse(){
    i=${#@}
        while [ $i -gt 0 ]; do
        echo ${!i}
        ((i--))
    done
}

if [ -z "$ROOT_POOL" ]; then
    >&2 echo "Root pool argument required.  Unable to proceed.  Exiting"
    exit 1
fi

# if we aren't using a deb-caching proxy, check connectivity to debian's HTTP redirector
if [ -z "$http_proxy" ] && ! curl -IL http://httpredir.debian.org/ >/dev/null 2>&1; then
    >&2 echo "Failed to conect to http://httpredir.debian.org/
Check your network and firewall configurations."
exit 2
fi

i=0
while [ $i -lt ${#ZFS_DATASETS[@]} ]; do
    if ! zfs list ${ZFS_DATASETS[$i]} >/dev/null 2>&1 ; then
        # try to create dataset but don't mount it yet
        if ! zfs create -o canmount=noauto ${ZFS_DATASETS[$i]}; then
            >&2 echo "Failed to create ZFS dataset '${ZFS_DATASETS[$i]}'. Exiting."
            exit 4
        fi

        # reset the canmount property to its default
        zfs set canmount=on ${ZFS_DATASETS[$i]}
    fi

    # Apply any properties that were specified with the dataset.
    for property in ${ZFS_DATASET_OPTS[$i]}; do
        zfs set $property ${ZFS_DATASETS[$i]}
    done
    ((i++))
done

zpool set bootfs=$ROOTFS $ROOT_POOL

zpool export -a

for pool in $@; do
    if ! zpool import -o altroot=/mnt $pool; then
        >&2 echo "Failed to export and reimport ZFS pools at /mnt"
        exit 6
    fi
done

# FIXME: https://github.com/zfsonlinux/zfs/pull/7329 may to change the way /var/lib is mounted
if ! mkdir /mnt/var/lib && mount -t zfs $ROOT_POOL/var/lib /mnt/var/lib; then
    >&2 echo "Failed to mount $ROOT_POOL/var/lib at /mnt/var/lib"
    exit 7
fi

# TODO: identify the root pool and add a bios boot partition to each non-cache, non-log leaf vdev

mkdir -p /mnt/etc/zfs
for pool in `zpool list -H | awk '{print $1}'`; do
    zpool set cachefile=/mnt/etc/zfs/zpool.cache $pool
done

mkdir /mnt/dev
mount -o bind /dev/ /mnt/dev
mount -o bind /dev/pts /mnt/dev/pts

mkdir /mnt/proc

mkdir /mnt/sys
mount -o bind /sys /mnt/sys

trap sigint_handler INT

if ! apt-get update || ! cdebootstrap $DISTRO_NAME /mnt; then
    >&2 echo "Failed to setup root filesystem in $ROOTFS"
    exit 4
fi

# copy custom apt and other config files into new root
cp -a /target_config/* /mnt/

mount -o bind /proc /mnt/proc

cp /scripts/$STAGE2_BOOTSTRAP /mnt/root/$STAGE2_BOOTSTRAP
# $http_proxy is an environment variable that (c)debootstrap honors for downloading packages
# if it happens to point to caching proxy like apt-cacher-ng, it can greatly accelerate installs
if ! chroot /mnt /root/$STAGE2_BOOTSTRAP $http_proxy; then
    >&2 echo "Stage 2 bootstrap failed. Exiting"
    exit 5
fi

cleanup.sh $(reverse $@)