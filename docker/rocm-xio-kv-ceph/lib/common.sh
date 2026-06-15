#!/usr/bin/env bash
# Shared library: env defaults, logging, data-dir layout, pidfile tracking.
# Sourced (not executed) by entrypoint.sh and lib/*.sh.
set -Eeuo pipefail

# ---- Data dir layout (bind-mounted from host) ----
: "${DATA_DIR:=/data}"
export IMAGES_DIR="$DATA_DIR/images"
export LOG_DIR="$DATA_DIR/log"
export CEPH_DIR="$DATA_DIR/ceph"
export RUN_DIR="$DATA_DIR/run"
mkdir -p "$IMAGES_DIR" "$LOG_DIR" "$CEPH_DIR" "$RUN_DIR"

# ---- VM tooling source (upstream default; override for full GPU pass) ----
: "${QEMU_MINIMAL_REMOTE:=https://github.com/sbates130272/qemu-minimal}"
: "${QEMU_MINIMAL_BRANCH:=master}"
: "${GENVM_SCRIPT:=qemu/gen-vm}"
: "${RUNVM_SCRIPT:=qemu/run-vm}"

# ---- Guest provisioning (Ansible) source ----
: "${ANSIBLE_REMOTE:=https://github.com/john00003/batesste-ansible}"
: "${ANSIBLE_BRANCH:=users/john00003/rocm-xio-kv-docker}"
: "${ANSIBLE_PLAYBOOK:=playbooks/rocm-xio-kv-guest.yml}"
: "${ANSIBLE_INVENTORY:=playbooks/rocm-xio-kv-hosts.yml}"

# ---- Component source pins (compiled in image via build-args; runtime echo only) ----
: "${SPDK_REMOTE:=https://github.com/mmgaggle/spdk}"
: "${SPDK_BRANCH:=rados-nkv}"
: "${ROCM_XIO_REMOTE:=https://github.com/mmgaggle/rocm-xio}"
: "${ROCM_XIO_BRANCH:=nvme-kv}"

# ---- Hardware (host-specific; required for GPU E2E) ----
: "${GPU_BDFS:=0000:0c:00.0,0000:0c:00.1}"
: "${NVME_BDF:=0000:04:00.0}"
: "${SSH_PORT:=2223}"
: "${VCPUS:=8}"
: "${VMEM:=15360}"
: "${NVME:=2}"
: "${IOMMU:=disable}"
: "${PCI_MMIO_BRIDGE:=enable}"
: "${VM_NAME:=kv-ceph-vm}"
# VRAM peer-DMA target selection for the launcher. ORDER-SENSITIVE & 1-based:
# it indexes into PCI_HOSTDEV. With NVMe-first ordering (NVME_BDF,GPU_BDFS),
# index 2 = the GPU VGA function. Required for the device-mem tests.
: "${VRAM_DEV_INDEX:=2}"
: "${VRAM_BAR:=0}"

# ---- Guest test knobs ----
: "${ROCXIO_NVME_DEVICE:=/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NC0RA03709B}"
: "${USE_PCI_MMIO_BRIDGE:=1}"
: "${TASKSET_CPUS:=0-4}"
: "${CTEST_LABEL_EXCLUDE:=rdma}"

# ---- KV / Ceph names ----
: "${KV_POOL:=kvpool}"
: "${KV_NS:=kvns}"
: "${NQN:=nqn.2026-06.io.spdk:kv-rados0}"
: "${SPDK_HUGE:=auto}"

# ---- Logging ----
# log <stage> <message...> -> timestamped line to stderr + $LOG_DIR/<stage>.log
log() {
  local stage="$1"; shift
  local line
  line="[$(date -u +%H:%M:%S)] [$stage] $*"
  printf '%s\n' "$line" | tee -a "$LOG_DIR/$stage.log" >&2
}
die() { log "${STAGE:-error}" "FATAL: $*"; exit 1; }

# ---- Pidfile tracking (cleanup only kills what we started) ----
track_pid() { echo "$2" > "$RUN_DIR/$1.pid"; }
kill_tracked() {
  local name pid f
  for f in "$RUN_DIR"/*.pid; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .pid)"; pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log cleanup "killing $name (pid $pid)"; kill "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  done
}

# ---- SPDK hugepage flag selection ----
# Echo "--no-huge -s 1024" unless hugepages are present or SPDK_HUGE forces yes.
spdk_huge_flags() {
  case "$SPDK_HUGE" in
    no|none|false|0) echo "--no-huge -s 1024"; return;;
    yes|true|1)      echo ""; return;;
  esac
  local nr; nr="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
  if [ "${nr:-0}" -gt 0 ] 2>/dev/null; then echo ""; else echo "--no-huge -s 1024"; fi
}
