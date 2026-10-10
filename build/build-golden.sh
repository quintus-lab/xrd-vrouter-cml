#!/bin/bash
# Build the XRd vRouter golden disk: Ubuntu 24.04 + Docker + the Cisco XRd image.
# Run on an x86-64 Linux host with KVM. The result is $WORKDIR/standalone.qcow2.
#
# Parameters (environment variables, all optional):
#   WORKDIR      build directory (default /var/tmp/xrd-vrouter-lab)
#   XRD_ARCHIVE  file name of the XRd image archive in $WORKDIR/share/
#                (default ios-xrd-vrouter-26-2-2.tar.gz)
#   XRD_TAG      Docker tag that the guest uses for XRd (default ios-xrd-vrouter:26-2-2)
#
# Example for a new release:
#   WORKDIR=/var/tmp/xrd-26-3-1 XRD_ARCHIVE=xrd-vrouter-26.3.1.dockerv1.tgz \
#   XRD_TAG=ios-xrd-vrouter:26-3-1 sudo -E bash build-golden.sh
set -eu
WORKDIR=${WORKDIR:-/var/tmp/xrd-vrouter-lab}
XRD_ARCHIVE=${XRD_ARCHIVE:-ios-xrd-vrouter-26-2-2.tar.gz}
XRD_TAG=${XRD_TAG:-ios-xrd-vrouter:26-2-2}
# setup.sh reads these two values as shell variables. Accept safe characters only.
case "$XRD_ARCHIVE" in
  ""|*[!A-Za-z0-9._-]*) echo "STOP: XRD_ARCHIVE must use only letters, digits, periods, underscores and hyphens" >&2; exit 1 ;;
esac
case "$XRD_TAG" in
  ""|*[!A-Za-z0-9._:/-]*) echo "STOP: XRD_TAG must be a valid Docker tag without spaces or shell characters" >&2; exit 1 ;;
esac
cd "$WORKDIR"
test -s noble-server-cloudimg-amd64.img
test -s "share/$XRD_ARCHIVE"
for artifact in seed.iso golden.qcow2 standalone.qcow2 serial.log; do
  if [ -e "$artifact" ]; then
    echo "STOP: existing build artifact: $artifact" >&2
    exit 1
  fi
done
# setup.sh reads the archive name and the tag from this file.
printf 'XRD_ARCHIVE=%s\nXRD_TAG=%s\n' "$XRD_ARCHIVE" "$XRD_TAG" >share/xrd-build.env
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock -graft-points \
  user-data=src/user-data \
  meta-data=src/meta-data \
  setup.sh=src/setup.sh \
  stub.sh=src/stub.sh
isoinfo -i seed.iso -f
qemu-img create -f qcow2 -F qcow2 -b "$PWD/noble-server-cloudimg-amd64.img" "$PWD/golden.qcow2" 32G
set +e
timeout 2700 qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -machine q35 \
  -m 6144 \
  -smp 4 \
  -display none \
  -serial file:"$PWD/serial.log" \
  -monitor none \
  -drive file="$PWD/golden.qcow2",if=none,id=disk,format=qcow2 \
  -device virtio-blk-pci,drive=disk,bootindex=1 \
  -drive file="$PWD/seed.iso",if=none,id=cidata,media=cdrom,readonly=on,format=raw \
  -device virtio-scsi-pci,id=scsi0 \
  -device scsi-cd,drive=cidata,bus=scsi0.0 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -fsdev local,security_model=none,id=share,path="$PWD/share" \
  -device virtio-9p-pci,fsdev=share,mount_tag=share
rc=$?
set -e
echo QEMU_RC:$rc
if [ "$rc" -eq 0 ] && grep -q XRD_GOLDEN_READY serial.log; then
  echo GOLDEN_OK
  qemu-img convert -O qcow2 golden.qcow2 standalone.qcow2
  ls -lh standalone.qcow2
  sha256sum standalone.qcow2
else
  echo GOLDEN_FAIL
  tail -c 4000 serial.log || true
  exit 1
fi
