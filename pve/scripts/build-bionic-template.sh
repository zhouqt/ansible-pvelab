#!/bin/bash
set -euo pipefail

TPL_NAME="${1:-ubuntu-bionic-cloudimg-rootfs_18.04-1_amd64.tar.xz}"
IMAGE_URL="${BIONIC_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/bionic/release/ubuntu-18.04-server-cloudimg-amd64-root.tar.xz}"
CACHE_DIR=/var/lib/vz/template/cache
WORK_DIR=/root/bionic-repack

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (writes to $CACHE_DIR)" >&2
  exit 1
fi

if [ -f "$CACHE_DIR/$TPL_NAME" ]; then
  echo "TEMPLATE-PRESENT $CACHE_DIR/$TPL_NAME ($(du -h "$CACHE_DIR/$TPL_NAME" | cut -f1))"
  exit 0
fi

install -d -m 0755 "$WORK_DIR"
cd "$WORK_DIR"

ROOTFS=ubuntu-18.04-server-cloudimg-amd64-root.tar.xz
if [ ! -f "$ROOTFS" ]; then
  echo "downloading $IMAGE_URL"
  curl -fL --retry 3 --max-time 1800 -o "$ROOTFS.part" "$IMAGE_URL"
  mv "$ROOTFS.part" "$ROOTFS"
fi
echo "IMAGE-READY $(du -h "$ROOTFS" | cut -f1)"

rm -rf tree
mkdir tree
echo "extracting (dev/* excluded)"
tar -xJf "$ROOTFS" -C tree --exclude './dev/*'

for f in etc/passwd etc/os-release; do
  [ -s "tree/$f" ] || { echo "extraction is missing $f" >&2; exit 1; }
done
grep -q '^VERSION_ID="18.04"' tree/etc/os-release || {
  echo "rootfs is not bionic: $(grep '^VERSION_ID=' tree/etc/os-release)" >&2
  exit 1
}

echo "repacking into $CACHE_DIR/$TPL_NAME"
XZ_OPT="-T0" tar -cJf "$CACHE_DIR/$TPL_NAME.part" \
  --numeric-owner --acls --xattrs --format=pax -C tree .
mv "$CACHE_DIR/$TPL_NAME.part" "$CACHE_DIR/$TPL_NAME"

rm -rf tree
echo "TEMPLATE-CREATED $CACHE_DIR/$TPL_NAME ($(du -h "$CACHE_DIR/$TPL_NAME" | cut -f1))"
