# Background
* FIXME: talk about live-manual-pdf

# Building
* Clone this project to a debian box
* ***Become root** (this is a gross but unavoidable artifact of Debian's live-build architecture)* 
* Change directories into the project root
* `lb clean --purge && lb build`

# Usage

(TBW)


# TODO:
* https://github.com/zfsonlinux/zfs/wiki/Debian-Jessie-Root-on-ZFS `--rbind` rather than `-o bind`  what's the difference? *`--rbind` is a recursive bind mount.*


# Old Notes used to get this project going

`http_proxy=http://proxyhost:proxyport` environment variable tells debootstrap to download via a caching proxy

`lb clean --purge && lb build` 
