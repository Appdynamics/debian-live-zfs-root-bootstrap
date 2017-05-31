#!/bin/bash

USAGE="\
Usage: bootstrap-zfs-debian-root.sh [options] <rootpool> [pooltwo]...

Installs bootable Debian root filesystem to /mnt.

Options:    -i <IP address for bootstrapped host>
            -k <SSH public key for root access>
            -p http://<apt-cacher-ng host>:<port>
            -r <root password for bootstrapped host>
"

while getopts ":i:k:p:r:" OPTION; do
    case $OPTION in
        i ) IP_ADDRESS=$OPTARG;;
        k ) ROOT_PUBKEY="$OPTARG";;
        p ) APT_CACHER_NG_URL=$OPTARG
            export http_proxy=$OPTARG
            ;;
        r ) ROOTPW="$OPTARG";;
        * ) >&2 echo "Unrecognized option: $OPTARG"
            exit
            ;;
    esac
done

DISTRO_NAME=jessie
ROOT_CONTAINER_FS="${1}/ROOT"
ROOTFS="${ROOT_CONTAINER_FS}/debian"
STAGE2_BOOTSTRAP=stage-2-bootstrap.sh

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

if [ -z "$1" ]; then
    >&2 echo "Root pool argument required.  Unable to proceed.  Exiting"
    exit 1
fi

# if we aren't using a deb-caching proxy, check connectivity to debian's HTTP redirector
if [ -z "$http_proxy" ] && ! curl -IL --connect-timeout 3 http://httpredir.debian.org/ >/dev/null 2>&1; then
    >&2 echo "Failed to conect to http://httpredir.debian.org/
Check your network and firewall configurations."
exit 2
fi

if ! zfs list $ROOT_CONTAINER_FS >/dev/null 2>&1; then
    if ! zfs create -o canmount=off -o mountpoint=none $ROOT_CONTAINER_FS; then
        >&2 echo "Failed to create $ROOT_CONTAINER_FS. Exiting."
        exit 3
    fi
fi

if ! zfs list $ROOTFS >/dev/null 2>&1; then
    # create rootfs and keep it from complaining that it can't mount to / with
    #   canmount=noauto
    if ! zfs create -o canmount=noauto -o mountpoint=/ $ROOTFS; then
        >&2 echo "Failed to create $ROOTFS. Exiting."
        exit 4
    fi
fi

zpool set bootfs=$ROOTFS $1

# make sure $ROOTFS mounts at / when we import its pool
zfs set canmount=on $ROOTFS

zpool export -a

for pool in $@; do
    if ! zpool import -o altroot=/mnt $pool; then
        >&2 echo "Failed to export and reimport ZFS pools at /mnt"
        exit 6
    fi
done

mkdir -p /mnt/etc/zfs
for pool in `zpool list -H | awk '{print $1}'`; do
    zpool set cachefile=/mnt/etc/zfs/zpool.cache $pool
done

mkdir /mnt/dev
# recursive bind mounts /dev and /dev/pts under /mnt/
mount --rbind /dev/ /mnt/dev

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

declare -a STAGE2_ARGS

if [ -n "$IP_ADDRESS" ]; then
    STAGE2_ARGS[${#STAGE2_ARGS[@]}=-i
    STAGE2_ARGS[${#STAGE2_ARGS[@]}=$IP_ADDRESS
fi

if [ -n "$APT_CACHER_NG_URL" ]; then
    STAGE2_ARGS[${#STAGE2_ARGS[@]}=-p
    STAGE2_ARGS[${#STAGE2_ARGS[@]}=$APT_CACHER_NG_URL
fi

# Ugly, but it tolerates spaces and special characters in $ROOTPW and $ROOT_PUBKEY
if [ -n "$ROOTPW" ] && [ -n "$ROOT_PUBKEY" ]; then
    chroot /mnt /root/$STAGE2_BOOTSTRAP -r "$ROOTPW" -k "$ROOT_PUBKEY" ${STAGE2_ARGS[@]}
elif [ -n "$ROOTPW" ]; then
    chroot /mnt /root/$STAGE2_BOOTSTRAP -r "$ROOTPW"  ${STAGE2_ARGS[@]}
elif [ -n "$ROOT_PUBKEY" ]; then
    chroot /mnt /root/$STAGE2_BOOTSTRAP -k "$ROOT_PUBKEY" ${STAGE2_ARGS[@]}
else
    chroot /mnt /root/$STAGE2_BOOTSTRAP ${STAGE2_ARGS[@]}
fi

if [ $? -gt 0 ]; then
    >&2 echo "Stage 2 bootstrap failed. Exiting"
    exit 5
fi

cleanup.sh $(reverse $@)
