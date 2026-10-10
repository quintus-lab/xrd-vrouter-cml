#!/bin/bash
# Runs inside the golden guest on every lab boot when CML starts the guest as
# a native KVM node. Every NIC is the same model, so the first PCI NIC is the
# management port and the rest are XRd data ports. There is no vIOMMU, so
# vfio-pci runs in no-IOMMU mode. Optional docker env lines come from xrd.env
# on the config CD. XR state lives in the guest volume xr-storage, so it
# survives a CML stop/start until the node is wiped.
set -u
echo "XRD_GUEST_INIT_START kvm"
sysctl -w fs.inotify.max_user_instances=64000 >/dev/null
sysctl -w fs.inotify.max_user_watches=64000 >/dev/null
# Minimums from xrd-tools host-check (v1.3.3). Lower values make XRd warn about IPC loss.
# GUEST_SOCKET_SYSCTL=0 in xrd.env skips them.
if ! grep -qE '^GUEST_SOCKET_SYSCTL=0' /mnt/cdrom/xrd.env 2>/dev/null; then
  sysctl -w net.core.netdev_max_backlog=300000 net.core.optmem_max=67108864 \
    net.core.rmem_default=67108864 net.core.rmem_max=67108864 \
    net.core.wmem_default=67108864 net.core.wmem_max=67108864 >/dev/null
  sysctl -w net.ipv4.udp_mem="1124736 10000000 67108864" >/dev/null
fi
echo "XRD_GUEST_SOCK rmem_default=$(cat /proc/sys/net/core/rmem_default)"
modprobe vfio enable_unsafe_noiommu_mode=1 || true
modprobe vfio-pci || true
echo Y >/sys/module/vfio/parameters/enable_unsafe_noiommu_mode 2>/dev/null || true
echo "XRD_GUEST_NOIOMMU $(cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode 2>/dev/null)"
mkdir -p /mnt/cdrom /etc/xrd
if mountpoint -q /mnt/cdrom || mount /dev/sr0 /mnt/cdrom 2>/dev/null; then
  if [ -f /mnt/cdrom/first-boot.cfg ]; then
    cp /mnt/cdrom/first-boot.cfg /etc/xrd/first-boot.cfg
  fi
fi
if [ ! -f /etc/xrd/first-boot.cfg ]; then
  echo "XRD_GUEST_INIT_FAIL no first-boot.cfg"
  exit 1
fi
envfile=()
if [ -f /mnt/cdrom/xrd.env ]; then
  envfile=(--env-file /mnt/cdrom/xrd.env)
  echo "XRD_GUEST_ENV $(grep -v '^#' /mnt/cdrom/xrd.env | tr '\n' ' ')"
  # GRUB reserves three 1 GiB pages. Give back what XRd will not use.
  hp_mb=$(grep -E '^XR_VROUTER_DP_HUGEPAGE_MB=' /mnt/cdrom/xrd.env | tail -1 | cut -d= -f2)
  if [ -n "$hp_mb" ]; then
    echo $(((hp_mb + 1023) / 1024)) >/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
  fi
  # GUEST_THP=never|madvise|always sets transparent hugepages in the guest.
  thp=$(grep -E '^GUEST_THP=' /mnt/cdrom/xrd.env | tail -1 | cut -d= -f2)
  if [ -n "$thp" ]; then
    echo "$thp" >/sys/kernel/mm/transparent_hugepage/enabled
    echo "$thp" >/sys/kernel/mm/transparent_hugepage/defrag
  fi
fi

nics=()
for _ in $(seq 1 20); do
  nics=()
  for dev in /sys/bus/pci/devices/*; do
    class=$(cat "$dev/class" 2>/dev/null || true)
    case "$class" in
      0x0200*) nics+=("${dev##*/}") ;;
    esac
  done
  [ "${#nics[@]}" -gt 0 ] && break
  sleep 1
done
if [ "${#nics[@]}" -lt 2 ]; then
  echo "XRD_GUEST_INIT_FAIL need management plus one data NIC, found ${#nics[@]}"
  lspci -nn
  exit 1
fi
lspci -nn | grep -i ethernet || true

mgmt_bdf=${nics[0]}
mgmt=""
for _ in $(seq 1 20); do
  mgmt=$(ls "/sys/bus/pci/devices/$mgmt_bdf/net" 2>/dev/null | head -1)
  [ -n "$mgmt" ] && break
  sleep 1
done
if [ -z "$mgmt" ]; then
  echo "XRD_GUEST_INIT_FAIL no kernel netdev for management NIC $mgmt_bdf"
  exit 1
fi
data=""
for bdf in "${nics[@]:1}"; do
  if [ -n "$data" ]; then
    data="$data;pci:$bdf"
  else
    data="pci:$bdf"
  fi
done

image=$(cat /etc/xrd/image)
echo "XRD_GUEST_INIT_RUN mgmt=$mgmt($mgmt_bdf) data=$data"
grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo || true
echo "XRD_GUEST_THP $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
for _ in $(seq 1 20); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
exec docker run --name xrd --rm -it \
  --network host \
  --privileged \
  --ulimit memlock=-1:-1 \
  --security-opt apparmor=unconfined \
  --security-opt label=disable \
  -v /etc/xrd/first-boot.cfg:/etc/xrd/first-boot.cfg:ro \
  -v /dev/hugepages:/dev/hugepages \
  -v xr-storage:/xr-storage \
  -e XR_FIRST_BOOT_CONFIG=/etc/xrd/first-boot.cfg \
  -e XR_MGMT_INTERFACES="linux:${mgmt},chksum" \
  -e XR_INTERFACES="$data" \
  "${envfile[@]}" \
  "$image"
