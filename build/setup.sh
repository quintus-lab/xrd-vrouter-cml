#!/bin/bash
# First boot of the golden disk. Installs the XRd image and the guest service,
# then powers off. Later boots do not run cloud-init.
#
# The archive name and the tag come from share/xrd-build.env, which
# build-golden.sh writes. Without that file, the 26.2.2 defaults apply.
set -eu
mkdir -p /mnt/share
mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 share /mnt/share
exec > >(tee -a /mnt/share/setup.log) 2>&1
echo SETUP_START
XRD_ARCHIVE=ios-xrd-vrouter-26-2-2.tar.gz
XRD_TAG=ios-xrd-vrouter:26-2-2
if [ -f /mnt/share/xrd-build.env ]; then
  . /mnt/share/xrd-build.env
fi
echo "XRD_ARCHIVE=$XRD_ARCHIVE XRD_TAG=$XRD_TAG"
install -D -m 755 /mnt/cidata/stub.sh /usr/local/sbin/xrd-guest-init
cat >/etc/systemd/system/xrd-guest.service <<'EOF'
[Unit]
Description=IOS XRd vRouter
After=docker.service
Requires=docker.service
ConditionPathExists=/dev/ttyS0
[Service]
Type=simple
ExecStart=/usr/local/sbin/xrd-guest-init
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl enable xrd-guest.service
systemctl disable --now serial-getty@ttyS0.service || true
systemctl mask serial-getty@ttyS0.service || true
mkdir -p /etc/modules-load.d
echo vfio-pci >/etc/modules-load.d/vfio-pci.conf
# Three 1 GiB pages are reserved at boot. guest-init.sh gives back the pages
# that XR_VROUTER_DP_HUGEPAGE_MB in xrd.env does not need.
cat >/etc/default/grub.d/99-xrd-lab.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=3"
EOF
update-grub
grep -q "hugepages=3" /boot/grub/grub.cfg
grep -q "intel_iommu=on" /boot/grub/grub.cfg
systemctl enable --now docker
loaded=$(docker load -i "/mnt/share/$XRD_ARCHIVE" | tee /dev/stderr | sed -n 's/^Loaded image: //p' | tail -1)
if ! docker image inspect "$XRD_TAG" >/dev/null 2>&1; then
  # The Cisco archive carries its own name, for example ios-xr/xrd-vrouter:26.2.2.
  test -n "$loaded"
  docker tag "$loaded" "$XRD_TAG"
fi
docker image inspect "$XRD_TAG" >/dev/null
install -d /etc/xrd
echo "$XRD_TAG" >/etc/xrd/image
touch /etc/cloud/cloud-init.disabled
sync
echo XRD_GOLDEN_READY >/dev/ttyS0
sync
poweroff
