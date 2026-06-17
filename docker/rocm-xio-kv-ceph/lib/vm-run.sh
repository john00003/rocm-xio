#!/usr/bin/env bash
# Launch the VM via the configurable run-vm[-modified] launcher, attaching the
# SPDK vfio-user socket + passing through GPU and the real NVMe. Foregrounds QEMU.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
# QEMU_BIN is set in the Dockerfile ENV; default here so sourcing under set -u
# (e.g. the source-test) does not trip on an unbound var outside the container.
: "${QEMU_BIN:=/opt/qemu/build/qemu-system-x86_64}"

vm_run() {
  # STAGE is read by common.sh's die()/log() via ${STAGE:-error}; shellcheck
  # cannot follow that cross-function read.
  # shellcheck disable=SC2034
  local STAGE=vm-run
  local sock; sock="$(cat "$RUN_DIR/vfio_user_sock" 2>/dev/null || true)"
  [ -S "$sock" ] || die "vfio-user socket missing ($sock); run spdk-kv first"
  # The tooling clone lives on the bind mount; ensure it exists (a serve container
  # that skipped build-vm's clone, or a fresh container, still gets it here).
  ensure_tooling
  [ -f "$TOOLING_DIR/$RUNVM_SCRIPT" ] || die "RUNVM_SCRIPT $RUNVM_SCRIPT not in tooling repo"
  log vm-run "launching $RUNVM_SCRIPT (NVMe=$NVME_BDF GPU=$GPU_BDFS port=$SSH_PORT vram_idx=$VRAM_DEV_INDEX)"
  cd "$TOOLING_DIR/$(dirname "$RUNVM_SCRIPT")"
  # PCI_HOSTDEV is NVMe-FIRST so VRAM_DEV_INDEX=2 (1-based) selects the GPU VGA fn.
  # QEMU_PATH is a string PREFIX in the launcher (${QEMU_PATH}qemu-system-x86_64),
  # so it must be the binary's DIRECTORY *with* a trailing slash.
  # The launcher runs in the FOREGROUND (no exec): vm_run blocks until QEMU exits.
  # We deliberately do NOT exec, so the caller's process (the serve stage) keeps
  # its `trap kill_tracked EXIT INT TERM` and can reap the backgrounded nvmf_tgt
  # when QEMU exits or the container is stopped. The serve stage forwards signals.
  # FILESYSTEM=none disables the launcher's 9p host-share (-virtfs local,path=...).
  # The KV E2E needs no host share (rocm-xio is baked into the guest qcow), and the
  # default ($HOME/code) does not exist in the container -> qemu fsdev init failure.
  VM_NAME="$VM_NAME" SSH_PORT="$SSH_PORT" \
  PCI_HOSTDEV="${NVME_BDF},${GPU_BDFS}" \
  VFIO_USERDEV="$sock" \
  PCI_MMIO_BRIDGE="$PCI_MMIO_BRIDGE" IOMMU="$IOMMU" \
  VRAM_DEV_INDEX="$VRAM_DEV_INDEX" VRAM_BAR="$VRAM_BAR" \
  VCPUS="$VCPUS" VMEM="$VMEM" NVME="$NVME" UEFI=enable \
  FILESYSTEM="${FILESYSTEM:-none}" \
  QEMU_PATH="$(dirname "$QEMU_BIN")/" IMAGES="$IMAGES_DIR" \
    "./$(basename "$RUNVM_SCRIPT")"
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then vm_run; fi
