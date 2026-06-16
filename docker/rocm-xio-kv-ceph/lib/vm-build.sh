#!/usr/bin/env bash
# Clone qemu-minimal tooling + batesste-ansible, install the batesste collection,
# then run gen-vm WITH Ansible provisioning to build the guest qcow (rocm-xio @
# nvme-kv + kmod + GRUB cheats). Cached in /data/images; skip unless FORCE=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
TOOLING=/opt/qemu-minimal
ANSIBLE_SRC=/opt/batesste-ansible
# gen-vm writes the final image to ${IMAGES}/${VM_NAME}.qcow2 (see gen-vm tail:
# create_image_with_backing / NO_BACKING mv). Verified against the real gen-vm.
QCOW="$IMAGES_DIR/$VM_NAME.qcow2"

vm_build() {
  # STAGE is read by common.sh's die()/log() via ${STAGE:-error}; shellcheck
  # cannot follow that cross-function read.
  # shellcheck disable=SC2034
  local STAGE=build-vm
  if [ -f "$QCOW" ] && [ "${FORCE:-0}" != "1" ]; then
    log build-vm "qcow exists ($QCOW); skip (FORCE=1 to rebuild)"; return 0
  fi
  # --- tooling repo (gen-vm + launcher) ---
  if [ ! -d "$TOOLING/.git" ]; then
    log build-vm "cloning tooling $QEMU_MINIMAL_REMOTE@$QEMU_MINIMAL_BRANCH"
    GIT_TERMINAL_PROMPT=0 git clone --branch "$QEMU_MINIMAL_BRANCH" "$QEMU_MINIMAL_REMOTE" "$TOOLING" \
      || die "tooling clone failed (private? see README 'Private fork clone')"
  fi
  [ -f "$TOOLING/$GENVM_SCRIPT" ] || die "GENVM_SCRIPT $GENVM_SCRIPT not in tooling repo"
  # --- ansible provisioning repo (the batesste collection) ---
  if [ ! -d "$ANSIBLE_SRC/.git" ]; then
    log build-vm "cloning ansible $ANSIBLE_REMOTE@$ANSIBLE_BRANCH"
    GIT_TERMINAL_PROMPT=0 git clone --branch "$ANSIBLE_BRANCH" "$ANSIBLE_REMOTE" "$ANSIBLE_SRC" \
      || die "ansible clone failed"
  fi
  [ -f "$ANSIBLE_SRC/$ANSIBLE_PLAYBOOK" ]  || die "playbook $ANSIBLE_PLAYBOOK missing in ansible repo"
  [ -f "$ANSIBLE_SRC/$ANSIBLE_INVENTORY" ] || die "inventory $ANSIBLE_INVENTORY missing in ansible repo"
  # gen-vm hard-requires $ANSIBLE_DIR/requirements.yml (prepare_ansible_setup)
  # and installs sbates130272.batesste from it. Fail early with a clear message.
  [ -f "$ANSIBLE_SRC/requirements.yml" ] || die "requirements.yml missing in ansible repo (gen-vm requires it)"
  # Install the batesste collection itself so FQCN role lookups resolve, plus deps.
  log build-vm "installing batesste collection + requirements"
  ansible-galaxy collection install "$ANSIBLE_SRC" --force >>"$LOG_DIR/gen-vm.log" 2>&1 \
    || die "batesste collection install failed (see $LOG_DIR/gen-vm.log)"
  ansible-galaxy collection install -r "$ANSIBLE_SRC/requirements.yml" >>"$LOG_DIR/gen-vm.log" 2>&1 || true
  # gen-vm expects ansible.cfg AT $ANSIBLE_DIR (it cd's there + sets ANSIBLE_CONFIG).
  # The repo keeps it under playbooks/; synthesize a root cfg if absent.
  if [ ! -f "$ANSIBLE_SRC/ansible.cfg" ]; then
    cat >"$ANSIBLE_SRC/ansible.cfg" <<EOF
[defaults]
roles_path = $ANSIBLE_SRC/roles
collections_path = $HOME/.ansible/collections
host_key_checking = False
EOF
  fi
  # gen-vm hard-requires SSH_KEY_FILE (the PUBLIC key; default $HOME/.ssh/id_ed25519.pub)
  # and exits if absent. It also SSHes into the guest with the default identity (no -i),
  # so the matching private key must sit at the default $HOME/.ssh/id_ed25519. Generate an
  # ed25519 keypair if the public key is missing; never overwrite an existing key.
  local sshkey="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
  if [ ! -f "$sshkey" ]; then
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
    sshkey="$HOME/.ssh/id_ed25519.pub"
    log build-vm "generated ephemeral SSH keypair for guest provisioning"
  fi
  # --- run gen-vm WITH provisioning ---
  log build-vm "running $GENVM_SCRIPT with Ansible (playbook=$ANSIBLE_PLAYBOOK)"
  ( cd "$TOOLING/$(dirname "$GENVM_SCRIPT")" && \
    VM_NAME="$VM_NAME" RELEASE=noble VCPUS="$VCPUS" VMEM="$VMEM" \
    SSH_KEY_FILE="$sshkey" \
    SSH_PORT="$SSH_PORT" IMAGES="$IMAGES_DIR" \
    ANSIBLE_SETUP=true ANSIBLE_DIR="$ANSIBLE_SRC" \
    ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" ANSIBLE_INVENTORY="$ANSIBLE_INVENTORY" \
      "./$(basename "$GENVM_SCRIPT")" >>"$LOG_DIR/gen-vm.log" 2>&1 ) \
    || die "gen-vm failed (see $LOG_DIR/gen-vm.log)"
  [ -f "$QCOW" ] || die "gen-vm did not produce $QCOW (check IMAGES/VM_NAME in gen-vm.log)"
  log build-vm "qcow ready: $QCOW"
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then vm_build; fi
