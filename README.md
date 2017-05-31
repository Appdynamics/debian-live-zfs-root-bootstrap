# Background
* FIXME: talk about live-manual-pdf

# Building
* Clone this project to a debian box
* ***Become root** (this is a gross but unavoidable artifact of Debian's live-build architecture)* 
* Change directories into the project root
* `lb clean --purge && lb build`

# Usage

## Mac Host Configuration
* VirtualBox
  * File -> Preferences
    * Network:
      * Host-only Networks
        * Create a new host-only network (i.e. vboxnet0)
* Virtual Machine
  * Network
    * Adapter 1:
      * Attached to: NAT
      * Advanced
        * Adapter type: Paravirtualized Network (virtio-net)
    * Adapter 2:
      * Attached to: Host-only Adapter
      * Name: (i.e. vboxnet0)
      * Advanced:
        * Adapter type: Paravirtualized Network (virtio-net)

## Live image
* dd the resulting .iso to your blank VM and boot it.
* Once booted:
  * Login with
    * User name: `user`
    * Password: `live`
  * `sudo -i` to get root
  * Create root pool with `zpool-create.sh [options] <pool name> <vdev spec>` (i.e. `zpool-create.sh -o ashift=12 foo-pool /dev/sda`) (Run `zpool-create.sh -h` for more useful info.) 
  * Create a BIOS boot partition on your boot drive(s) `create-bios-boot-partition.sh /dev/sda`
  * Create other pools and ZFS data sets as required for your environment
  * `bootstrap-zfs-debian-root.sh <root pool name> [extra-pool-1] [extra-pool-2]...`

## Installed system


# TODO:
* https://github.com/zfsonlinux/zfs/wiki/Debian-Jessie-Root-on-ZFS `--rbind` rather than `-o bind`  what's the difference? *`--rbind` is a recursive bind mount.*


# Old Notes used to get this project going

`http_proxy=http://proxyhost:proxyport` environment variable tells debootstrap to download via a caching proxy

`lb clean --purge && lb build` 
