#!/bin/bash --login

#FIXME: should take an optional http_proxy argument and poke it into apt.conf.d

validate_ipv4(){
    return $(echo "$1" | awk -F . '{if($1 >=0 && $1 < 256 && $2 >= 0 && $2 < 256 && $3 >= 0 && $4 >= 0 && $4 < 256)
    print 0; else print 1; exit}')
}


ln -s /proc/mounts /etc/mtab

if [ -n "$1" ]; then
    cat > /etc/apt/apt.conf.d/99caching-proxy <<CACHING_PROXY_CONFIG
Acquire::http { Proxy "$1"; };
CACHING_PROXY_CONFIG
fi

apt_get_errors=0

# Packages required to make host bootable
apt-get update
apt-get --assume-yes install linux-image-amd64 linux-headers-amd64 \
    lsb-release build-essential gdisk vim-tiny dkms || ((apt_get_errors++))
apt-get --assume-yes install spl-dkms || ((apt_get_errors++))
apt-get --assume-yes install zfs-dkms zfs-initramfs || ((apt_get_errors++))
apt-get --assume-yes install grub-pc

if [ $apt_get_errors -gt 0 ]; then
    >&2 echo "Failed to install one or more required, stage 2 packages."
    exit 1
fi

# Extra packages required for Linux Containers
apt-get --assume-yes install bridge-utils lxc yum

# Configuring LXC for ZFS and vice versa
POOLNAME=$(zpool list -H -o name)
LXC_BASE_FS=$POOLNAME/lxc
zfs create $LXC_BASE_FS
echo "lxc.bdev.zfs.root = $LXC_BASE_FS" >> /etc/lxc/lxc.conf

# template container "hardware" config
cat - > /etc/lxc/default.conf <<LXC_DEFAULT_CONFIG
lxc.network.type = veth
lxc.network.link = br0
lxc.network.name = eth0

lxc.network.type = veth
lxc.network.link = br1
lxc.network.name = eth1
LXC_DEFAULT_CONFIG

# Host-only network static config
valid_static=false
while ! $valid_static; do
    read -p "Enter a static IP address for the host-only network interface (br1)
or press [return] to default to 192.168.56.2: " user_supplied_static
    if [ -n "$user_supplied_static" ]; then
        if validate_ipv4 "$user_supplied_static"; then
            STATIC_IP=$user_supplied_static
            valid_static=true
        else
            >&2 echo "Error: Improperly formatted IP address."
        fi
    else
        STATIC_IP=192.168.56.2
        valid_static=true
    fi
done

cat - >/etc/network/interfaces.d/br1 <<BR1_CONFIG
iface eth1 inet manual

auto br1
iface br1 inet static
        address $STATIC_IP
        netmask 255.255.255.0
        bridge_ports eth1
        bridge_fd 0
BR1_CONFIG

# SSH
apt-get --assume-yes install openssh-server
read -p "Paste an SSH public key for the root user, or hit [return] to skip: " ROOT_PUBLIC_KEY
if [ -n "$ROOT_PUBLIC_KEY" ]; then
    mkdir -m 755 /root/.ssh
    echo "$ROOT_PUBLIC_KEY" > /root/.ssh/authorized_keys
fi

ex -s /etc/default/grub <<UPDATE_DEFAULT_GRUB
%s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="boot=zfs"/
%s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="boot=zfs"/
wq
UPDATE_DEFAULT_GRUB

if ! update-grub; then
    >&2 echo "'update-grub' failed.  Your system is probably not bootable."
    exit 2
fi

echo "Set the root password for your newly-installed system."
ROOT_PASSWD_SET=false
while ! $ROOT_PASSWD_SET; do
    if passwd; then
        ROOT_PASSWD_SET=true
    fi
done

# irqbalance gets automatically started by kernel installation and hangs onto file handles in /dev/  Stop it before
# leaving chroot
service irqbalance stop
