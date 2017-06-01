#!/bin/bash

# launched automatically by root's autologin

INTERVENTION_SHELL="/bin/bash --login"

drop_to_shell(){
    >&2 echo "Starting $INTERVENTION_SHELL."
    >&2 echo "Exiting will return to the beginning of $0."
    $INTERVENTION_SHELL
}

# Stop what you're doin'
trap exit INT
# 'cause I'm about to ruin...
trap drop_to_shell EXIT

get_guest_property(){
    # pass everything after "Value: " to the caller
    VBoxControl --nologo guestproperty get "$1" | awk '/^Value: /{print substr($0, 8, length($0))}'
}

>&2 echo "Unattended install script."
>&2 echo "Press [ctrl]-c to interrupt and drop to a shell."

if ! systemctl status zfs.target; then
    >&2 echo "Waiting for ZFS DKMS build to complete..."
fi
while ! systemctl status zfs.target >/dev/null 2>&1; do
    sleep 3
done

# grab guest properties
TARGET_HOSTNAME=$(get_guest_property HOSTNAME)
ZFS_ROOT_POOLNAME=$(get_guest_property ZFS_ROOT_POOLNAME)
BR1_IP=$(get_guest_property BR1_IP)
APT_CACHER_NG_URL="$(get_guest_property APT_CACHER_NG_URL)"
ROOT_PASSWD="$(get_guest_property ROOT_PASSWD)"
ROOT_PUBKEY="$(get_guest_property ROOT_PUBKEY)"

ZFS_BOOT_DEVICE=/dev/sda

# create pool
if ! zpool-create.sh -o ashift=12 "$ZFS_ROOT_POOLNAME" $ZFS_BOOT_DEVICE; then
    >&2 echo "Failed to create root ZFS pool.  Exiting."
    exit 1
fi

# add bios boot partition
if ! create-bios-boot-partition.sh /dev/sda; then
    >&2 echo "Failed to create BIOS boot partition on $ZFS_BOOT_DEVICE.  Exiting."
    exit 2
fi

# run bootstrap script
bootstrap-zfs-debian-root.sh \
    -i $BR1_IP\
    -k "$ROOT_PUBKEY"\
    -n $TARGET_HOSTNAME\
    -p "$APT_CACHER_NG_URL"\
    -r "$ROOT_PASSWD"

if [ $? -ne 0 ]; then
    >&2 echo "Failed to create bootable root filesystem in $ZFS_ROOT_POOLNAME.  Exiting."
    exit 3
fi

>&2 echo "Bootstrap complete.  Shutting down now."
# Give the customer a few seconds to see and process the last message...
sleep 3
shutdown -h now
