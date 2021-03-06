#!/bin/bash --login

#FIXME: add a debug flag

USAGE="\
Usage: stage-2-bootstrap.sh [options] -r <rootpool> -c </host/chroot/path>

Makes a chroot setup with cdebootstrap bootable.

Options:
  -r <zfs root pool>        ZFS pool name hosting /. (Required.)
  -c </host/chroot/path>    That path given as 'NEWROOT' when chroot was
                            called. (Required.)
  -n                        Non-interactive mode.
  -R <root password>        Root password for the bootstrapped system
  -B <boot device>          Where the GRUB bootloader should be written.  This
                            flag may be used more than once to install to
                            redundant boot devices.
  -i <ipv4_addr/NN | dhcp>  IPv4 address / prefix length or 'dhcp' if the
                            host's network interface should be automatically
                            configured.  Can be specified multiple times for
                            multiple network interfaces.  Address settings will
                            be applied to non-loopback interfaces in the order
                            they appear in the output of 'ip -o -a link'.
"

NON_INTERACTIVE=false
ROOT_PASSWORD=""
BOOT_DEVICES=( )
IPV4_ADDRESSES=( )
BAD_INPUT=false

root_auth_keys_file_present(){
  local ROOT_AUTH_KEYS_FILE=/root/.ssh/authorized_keys
  [ -f "$ROOT_AUTH_KEYS_FILE" ] && [[ $(ls -s /root/.ssh/authorized_keys | cut -d \  -f 1) != 0 ]]
}

while getopts ":nc:r:R:B:H:h" option; do
  case $option in
    c )
      HOST_CHROOT_PATH="$OPTARG"
    ;;
    n )
      NON_INTERACTIVE=true
    ;;
    R )
      ROOT_PASSWORD="$OPTARG"
    ;;
    r )
      ROOT_POOL="$OPTARG"
    ;;
    B )
      BOOT_DEVICES+=( "$OPTARG" )
    ;;
    H )
      HOSTNAME=$OPTARG
    ;;
    h )
      echo "$USAGE"
      exit 0
    ;;
    * )
      >&2 echo "'$OPTARG' is not a recognized option flag."
      BAD_INPUT=true
    ;;
  esac
done

shift $((OPTIND-1))

if [ -z "$ROOT_POOL" ]; then
  >&2 echo "The ZFS pool hosting / must be specified."
  BAD_INPUT=true
fi

# Sanity check: require root password arg in non-interactive mode
if $NON_INTERACTIVE &&  [ -z "$ROOT_PASSWORD" ]; then
    >&2 echo "A root password or root ssh public key must be specified when running
$0 non-interactively.
"
  BAD_INPUT=true
fi

# Sanity check: grub config pre-seeding required in non-interactive mode
if $NON_INTERACTIVE && [ ${#BOOT_DEVICES[@]} -eq 0 ]; then
    >&2 echo "At least one boot device must be specified when running $0
non-interactively
"
    BAD_INPUT=true
fi

if $BAD_INPUT; then
    >&2 echo "$USAGE"
    exit 1
fi

ln -s /proc/mounts /etc/mtab

debconf-set-selections <<LOCALE_SETTINGS
locales locales/locales_to_be_generated multiselect     en_US ISO-8859-1, en_US.ISO-8859-15 ISO-8859-15, en_US.UTF-8 UTF-8
locales locales/default_environment_locale      select  en_US.UTF-8
LOCALE_SETTINGS

debconf-set-selections <<GRUB_BOOT_ZFS
grub-pc	grub2/linux_cmdline	string root="ZFS=$ROOT_POOL/ROOT/debian"
grub-pc	grub2/linux_cmdline_default	string
GRUB_BOOT_ZFS

if $NON_INTERACTIVE; then
    debconf-set-selections <<NON_INTERACTIVE_DEBCONF_SELECTIONS
zfs-dkms	zfs-dkms/stop-build-for-32bit-kernel	boolean	true
zfs-dkms	zfs-dkms/note-incompatible-licenses	note
zfs-dkms	zfs-dkms/stop-build-for-unknown-kernel	boolean	true
NON_INTERACTIVE_DEBCONF_SELECTIONS
fi

apt_get_errors=0

# $1:       non_interactive: true | false
# $2...:    package_1 package_2 ... package_n
wrapt-get(){
    NON_INTERACTIVE_APT=$1
    shift

    if $NON_INTERACTIVE_APT; then
        DEBIAN_FRONTEND=noninteractive apt-get --assume-yes install "$@" || ((apt_get_errors++))
    else
        apt-get --assume-yes install "$@" || ((apt_get_errors++))
    fi
}

# setting mountpoint=legacy unmounts a ZFS filesystem.  Remount it based on its fstab entry
mount /boot

if ! apt-get update; then
  >&2 echo "'apt-get update' exited with status code $?.  Dropping to a shell for troubleshooting..."
  /bin/bash --login
  exit 1
fi

# Make package installations dependent on their predecessors for easier troubleshooting
wrapt-get $NON_INTERACTIVE locales && \
wrapt-get $NON_INTERACTIVE openssh-server && \
wrapt-get $NON_INTERACTIVE linux-image-amd64 linux-headers-amd64 lsb-release build-essential gdisk dkms && \
wrapt-get $NON_INTERACTIVE zfs-initramfs && \
wrapt-get $NON_INTERACTIVE grub-pc

if [ $apt_get_errors -gt 0 ]; then
    >&2 echo "Failed to install one or more required, stage 2 packages."
    exit 1
fi

HOSTNAME=$(lsb_release -si | awk '{print tolower($0)}')

# set hostname.
echo $HOSTNAME > /etc/hostname
cat > /etc/hosts <<ETC_SLASH_HOSTS
127.0.0.1     localhost
127.0.1.1     $HOSTNAME


# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
ETC_SLASH_HOSTS

ZED_RUNTIME=5
ZFS_LIST_CACHEFILE="/etc/zfs/zfs-list.cache/$ROOT_POOL"
# enable zfs-mount-generator(8)
mkdir /etc/zfs/zfs-list.cache

touch "$ZFS_LIST_CACHEFILE"
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d

zed -F &
ZED_PID=$!
# wait for zed to write to $ZFS_LIST_CACHEFILE
while [[ $(find "$ZFS_LIST_CACHEFILE" -printf '%s\n' ) -eq 0 ]]; do
  sleep 1
done
kill -TERM $ZED_PID

# yank the altroot prefix off of the zfs-list cachefile.
sed -Ei "s|$HOST_CHROOT_PATH/?|/|" "$ZFS_LIST_CACHEFILE"

# enable mounting of /boot at the correct time
systemctl enable zfs-import-bootpool.service

grub_errors=0

# FIXME: could this be bypassed by creative use of debconf-set-selections?
for device in "${BOOT_DEVICES[@]}"; do
    if ! grub-install $device; then
        >&2 echo "'grub-install $device' failed."
        ((grub_errors++))
    fi
done

if [ $grub_errors -gt 0 ]; then
    >&2 echo "Exiting."
    exit 2
fi

if ! update-grub; then
    >&2 echo "'update-grub' failed.  Your system is probably not bootable."
    exit 3
fi

if [ -n "$ROOT_PASSWORD" ]; then
    if ! echo "root:$ROOT_PASSWORD" | chpasswd; then
        >&2 echo "Failed to set the root password with 'chpasswd'
Exiting."
        exit 4
    fi
else
    echo "Set the root password for your newly-installed system."
    ROOT_PASSWD_SET=false
    while ! $ROOT_PASSWD_SET; do
        if passwd; then
            ROOT_PASSWD_SET=true
        fi
    done
fi
