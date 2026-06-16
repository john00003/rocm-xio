#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lib/common.sh"

stage="${1:-serve}"; shift || true
case "$stage" in
  selftest)
    # STAGE is read by common.sh's die()/log() via ${STAGE:-error}; shellcheck
    # cannot follow that cross-file read.
    # shellcheck disable=SC2034
    STAGE=selftest
    # shellcheck source=/dev/null
    source "$HERE/lib/ceph-up.sh"; ceph_up
    log selftest "running fork self-test: test/nvmf/kv_rados/kv_rados_vfio_user.sh"
    cd "$SPDK_DIR/test/nvmf/kv_rados"
    export CEPH_CONF CEPH_KEYRING RADOS_BIN=rados KV_POOL KV_NS CEPH_USER=admin
    # Run the --no-huge sed variant if hugepages are absent (mirrors deploy).
    script=kv_rados_vfio_user.sh
    if [ "$(spdk_huge_flags)" != "" ]; then
      sed 's#-m 0x3 --iova-mode=va#-m 0x3 --no-huge -s 1024#' \
        kv_rados_vfio_user.sh > kv_rados_selftest.sh
      chmod +x kv_rados_selftest.sh; script=kv_rados_selftest.sh
    fi
    ./"$script" | tee -a "$LOG_DIR/selftest.log"
    log selftest "DONE (see $LOG_DIR/selftest.log for PASS/FAIL)"
    ;;
  shell)
    # shellcheck source=/dev/null
    source "$HERE/lib/ceph-up.sh"; ceph_up; exec /bin/bash ;;
  build-vm)
    # shellcheck disable=SC2034
    STAGE=build-vm
    # shellcheck source=/dev/null
    source "$HERE/lib/guard.sh"; guard_nvme_bdf; guard_no_clobber
    # shellcheck source=/dev/null
    source "$HERE/lib/vm-build.sh"; vm_build ;;

  serve)
    # shellcheck disable=SC2034
    STAGE=serve
    # shellcheck source=/dev/null
    source "$HERE/lib/guard.sh"; guard_all
    # shellcheck source=/dev/null
    source "$HERE/lib/ceph-up.sh"
    # shellcheck source=/dev/null
    source "$HERE/lib/spdk-kv.sh"
    # shellcheck source=/dev/null
    source "$HERE/lib/vm-build.sh"
    # shellcheck source=/dev/null
    source "$HERE/lib/vm-run.sh"
    # vm_run blocks in the foreground (no exec), so this trap survives and reaps
    # the backgrounded nvmf_tgt (+ any tracked pid) when QEMU exits or on signal.
    trap 'kill_tracked' EXIT INT TERM
    ceph_up
    spdk_kv_up
    vm_build
    vm_run ;;

  gpu-e2e)
    # shellcheck disable=SC2034
    STAGE=gpu-e2e
    SSHOPT=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
    log gpu-e2e "waiting for guest SSH on $SSH_PORT"
    up=0
    for _ in $(seq 1 90); do
      ssh "${SSHOPT[@]}" ubuntu@localhost 'echo ok' >/dev/null 2>&1 && { up=1; break; }
      sleep 2
    done
    [ "$up" = 1 ] || die "guest SSH never came up on $SSH_PORT"
    # Preflight: fail fast with a clear message if provisioning did not land.
    ssh "${SSHOPT[@]}" ubuntu@localhost 'test -d ~/src/rocm-xio && test -e /dev/rocm-xio && lsmod | grep -q rocm' \
      || die "guest not provisioned: ~/src/rocm-xio / /dev/rocm-xio / kmod missing (check build-vm Ansible)"
    log gpu-e2e "running ctest (taskset -c $TASKSET_CPUS, -LE $CTEST_LABEL_EXCLUDE)"
    # Host-side expansion of the env vars into the remote command is intentional.
    # shellcheck disable=SC2029
    ssh "${SSHOPT[@]}" ubuntu@localhost \
      "cd ~/src/rocm-xio && sudo env ROCXIO_NVME_DEVICE=$ROCXIO_NVME_DEVICE \
        NVME_DEVICE=$ROCXIO_NVME_DEVICE USE_PCI_MMIO_BRIDGE=$USE_PCI_MMIO_BRIDGE \
        taskset -c $TASKSET_CPUS ctest --test-dir build -LE $CTEST_LABEL_EXCLUDE --output-on-failure" \
      2>&1 | tee -a "$LOG_DIR/gpu-e2e.log"
    log gpu-e2e "DONE (see $LOG_DIR/gpu-e2e.log for the NN/NN result)" ;;

  cleanup)
    # shellcheck disable=SC2034
    STAGE=cleanup
    kill_tracked
    log cleanup "done" ;;
  *) die "unknown stage: $stage (use: selftest|shell|build-vm|serve|gpu-e2e|cleanup)" ;;
esac
