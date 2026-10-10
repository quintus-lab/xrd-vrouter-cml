#!/bin/bash
# Baked into the golden disk. The real init script is on the config CD so it
# can change without rebuilding the disk.
echo XRD_STUB_START
mkdir -p /mnt/cdrom
mount /dev/sr0 /mnt/cdrom
exec bash /mnt/cdrom/guest-init.sh </dev/ttyS0 >/dev/ttyS0 2>&1
