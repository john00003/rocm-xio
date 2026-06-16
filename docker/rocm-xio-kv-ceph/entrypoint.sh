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
  build-vm|serve|gpu-e2e|cleanup)
    die "stage '$stage' not implemented until Chunk 3" ;;
  *) die "unknown stage: $stage (use: selftest|shell|build-vm|serve|gpu-e2e|cleanup)" ;;
esac
