#!/usr/bin/env bash
# Start SPDK nvmf_tgt + expose a kvdev_rados KV namespace as a vfio-user socket.
# Ported from the proven deploy/kv-target.sh. Returns once the socket is up
# (does NOT foreground); nvmf_tgt pid tracked via common.sh for cleanup.
# NOTE: this stage only RECORDS the pid; reaping is the caller's job. The serve
# stage MUST install `trap 'kill_tracked' EXIT INT TERM` so a signal during the
# socket-wait window does not orphan nvmf_tgt (see entrypoint serve stage).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
: "${SPDK_DIR:=/opt/spdk}"
: "${CEPH_CONF:=/etc/ceph/ceph.conf}"
: "${CEPH_KEYRING:=/etc/ceph/ceph.client.admin.keyring}"
RPC_SOCK="$RUN_DIR/spdk.rpc.sock"
MUSER="$RUN_DIR/muser"; mkdir -p "$MUSER"
rpc() { python3 "$SPDK_DIR/scripts/rpc.py" -s "$RPC_SOCK" "$@"; }

spdk_kv_up() {
  # STAGE is read by common.sh's die()/log() via ${STAGE:-error}; shellcheck
  # cannot follow that cross-function read.
  # shellcheck disable=SC2034
  local STAGE=spdk-kv
  # hugepage auto-selection from common.sh (echoes "--no-huge -s 1024" if no hugepages).
  local hugeflags; hugeflags="$(spdk_huge_flags)"
  log spdk-kv "starting nvmf_tgt (-m 0x1 ${hugeflags:-<hugepages>})"
  # word-splitting of $hugeflags is intentional (it is a flag list, not one arg).
  # shellcheck disable=SC2086
  "$SPDK_DIR/build/bin/nvmf_tgt" -r "$RPC_SOCK" -m 0x1 $hugeflags \
    >"$LOG_DIR/nvmf_tgt.log" 2>&1 &
  track_pid nvmf_tgt $!
  local _
  for _ in $(seq 1 80); do
    [ -S "$RPC_SOCK" ] && rpc rpc_get_methods >/dev/null 2>&1 && break
    sleep 0.25
  done
  rpc rpc_get_methods >/dev/null 2>&1 || die "nvmf_tgt failed to come up (see $LOG_DIR/nvmf_tgt.log)"
  rpc nvmf_create_transport -t VFIOUSER -q 1024 -m 16
  rpc kvdev_rados_register_cluster ceph0 --user admin \
      --config-file "$CEPH_CONF" --key-file "$CEPH_KEYRING" || die "kvdev_rados_register_cluster failed"
  rpc kvdev_rados_create KvRados0 ceph0 "$KV_POOL" --namespace "$KV_NS" || die "kvdev_rados_create failed"
  rpc nvmf_create_subsystem "$NQN" -s SPDKKVR01 -a
  rpc nvmf_subsystem_add_kv_ns "$NQN" KvRados0 || die "nvmf_subsystem_add_kv_ns failed"
  rpc nvmf_subsystem_add_listener "$NQN" -t VFIOUSER -a "$MUSER" -s 0
  for _ in $(seq 1 40); do [ -S "$MUSER/cntrl" ] && break; sleep 0.25; done
  [ -S "$MUSER/cntrl" ] || die "vfio-user cntrl socket never created"
  echo "$MUSER/cntrl" > "$RUN_DIR/vfio_user_sock"
  log spdk-kv "KV namespace up on $NQN; vfio-user socket=$MUSER/cntrl"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then spdk_kv_up; fi
