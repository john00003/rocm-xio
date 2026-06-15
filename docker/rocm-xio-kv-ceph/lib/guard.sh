#!/usr/bin/env bash
# Safety asserts run before every device-touching stage.
# Source common.sh first. Each function dies on violation.
set -Eeuo pipefail

# NOTE: blocklist + mounted-device check (not an allowlist); requires lsblk (absence fails open). The literal root-disk BDF is always refused.
# Refuse the host root disk and any BDF backing a mounted host block device.
guard_nvme_bdf() {
  local STAGE=guard
  local bdf="$NVME_BDF"
  [ "$bdf" = "0000:01:00.0" ] && die "NVME_BDF=$bdf is the HOST ROOT DISK. Refusing. Use 0000:04:00.0."
  local blkpath="/sys/bus/pci/devices/$bdf/nvme"
  if [ -d "$blkpath" ]; then
    local dev mp
    for dev in "$blkpath"/nvme*/nvme*n*; do
      [ -e "$dev" ] || continue
      mp="$(lsblk -no MOUNTPOINT "/dev/$(basename "$dev")" 2>/dev/null | grep -v '^$' || true)"
      [ -n "$mp" ] && die "NVME_BDF=$bdf backs a MOUNTED device ($dev -> $mp). Refusing."
    done
  fi
  log guard "NVMe BDF $bdf OK (not root disk, no mounted block device)"
}

# Refuse the parallel session's port and any already-bound port.
guard_ssh_port() {
  local STAGE=guard
  [ "$SSH_PORT" = "2222" ] && die "SSH_PORT=2222 is reserved by the parallel VM session. Use 2223+."
  if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
    die "SSH_PORT=$SSH_PORT already in use on this host/container."
  fi
  log guard "SSH port $SSH_PORT OK (free, not 2222)"
}

# We assert the nodes exist but cannot map BDF->iommu group inside the container; the host picks which numbered /dev/vfio/<N> to pass on `docker run`.
# Verify /dev/kvm and required vfio nodes are present and openable.
guard_devices() {
  local STAGE=guard
  [ -c /dev/kvm ] || die "/dev/kvm missing. docker run needs: --device /dev/kvm"
  { [ -r /dev/kvm ] && [ -w /dev/kvm ]; } || die "/dev/kvm not rw. Add --group-add kvm."
  [ -c /dev/vfio/vfio ] || die "/dev/vfio/vfio missing. docker run needs: --device /dev/vfio/vfio"
  local found=0 n
  for n in /dev/vfio/[0-9]*; do [ -e "$n" ] && found=1; done
  [ "$found" = 1 ] || die "No numbered /dev/vfio/<N> nodes. docker run needs e.g. --device /dev/vfio/22 --device /dev/vfio/27 --device /dev/vfio/28"
  log guard "device nodes present (/dev/kvm, /dev/vfio/*)"
}

# No-clobber: never collide with the user's normal VM image.
guard_no_clobber() {
  local -x STAGE=guard
  case "$VM_NAME" in
    rocm-passthrough*) die "VM_NAME=$VM_NAME collides with your normal VM. Use kv-ceph-vm." ;;
  esac
  log guard "VM_NAME $VM_NAME OK (no collision with rocm-passthrough)"
}

guard_all() { guard_nvme_bdf; guard_ssh_port; guard_devices; guard_no_clobber; }
