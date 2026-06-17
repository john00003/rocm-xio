# rocm-xio NVMe-KV Reproduction (Ceph + SPDK + QEMU fork)

A single self-contained container image that reproduces the rocm-xio NVMe
**Key-Value** result: a GPU-driven NVMe KV store/retrieve round-trip whose
backing store is Ceph RADOS, served to the guest through SPDK's `kvdev_rados`
namespace over a `vfio-user` socket.

The whole host-side stack (Ceph, SPDK `nvmf_tgt`, the QEMU launcher) runs
**inside the container**. The guest VM is launched **inside the container** too;
you reach it over SSH on port `2223`.

```
                          [ container ]
 guest /dev/nvme0 (KV)                                Ceph
   |   KV store/retrieve                              (RADOS)
   v                                                    ^
 QEMU vfio-user-pci client  --- vfio-user socket --->  SPDK nvmf_tgt
   |   (john00003/qemu fork)                            + kvdev_rados
   |                                                    (mmgaggle/spdk
   |  GPU rings the NVMe doorbells via pci-mmio-bridge   rados-nkv)
   |  KV value lands in VRAM via P2PDMA (vram-dev/BAR)
   v
 GPU (Navi 21) + real NVMe, passed through to the guest via VFIO
```

The container builds three things from source at image-build time: SPDK
(`mmgaggle/spdk@rados-nkv`), the QEMU fork
(`john00003/qemu@users/john00003/query-bar-address-for-p2p`, which carries the
`pci-mmio-bridge` and the client-side `vfio-user-pci`), and uses packaged Ceph.

Everything here is driven by `entrypoint.sh`, which dispatches one **stage** per
`docker run`. The real stages are: `selftest`, `shell`, `build-vm`, `serve`,
`gpu-e2e`, `cleanup`.

---

## 1. What you can run, at a glance

| Stage | Devices needed | What it proves |
|---|---|---|
| `selftest` | none (just `--privileged` + `/data`) | KV store/retrieve/delete round-trip through Ceph+SPDK, no VM, no GPU |
| `build-vm` | `/dev/kvm` | builds the guest qcow (rocm-xio @ nvme-kv + kmod), cached |
| `serve` | `/dev/kvm` + GPU + NVMe via VFIO | boots the guest with KV NVMe + GPU passthrough, blocks |
| `gpu-e2e` | (talks to a running `serve`) | runs the rocm-xio ctest suite in the guest |
| `cleanup` | none | kills only the pids this container started |
| `shell` | none | drops to a shell with Ceph already up (debugging) |

If you only want to confirm the KV data path works without any hardware, run
the **selftest** (section 4) and stop there.

---

## 2. Prerequisites (HOST)

You need a Linux host with:

- Docker, and your user in the `docker` and `kvm` groups.
- KVM available: `/dev/kvm` present.
- For the GPU E2E only: an AMD GPU (this work was validated on Navi 21 / gfx1030)
  and a **spare** NVMe SSD, both bound to `vfio-pci` *before* you run the
  container. The container never rebinds host drivers.

> Jira AC note: the Docker daemon must be allowed to access these device nodes.
> On a locked-down host you may need to grant the daemon device access (e.g. via
> the device cgroup / `--device` allowances) in addition to the `--device` flags
> shown below.

### Bind the GPU and NVMe to vfio-pci (HOST)

Replace the BDFs with your own. **Never** use your root disk's NVMe.

**HOST**
```bash
# Inspect first
lspci -nnk -s 0000:0c:00.0
lspci -nnk -s 0000:04:00.0

# Bind to vfio-pci (driverctl makes it persistent; modprobe vfio-pci first)
sudo modprobe vfio-pci
sudo driverctl set-override 0000:0c:00.0 vfio-pci   # GPU VGA function
sudo driverctl set-override 0000:0c:00.1 vfio-pci   # GPU audio function
sudo driverctl set-override 0000:04:00.0 vfio-pci   # spare NVMe
```

### Compute your per-device /dev/vfio/<N> group numbers (HOST)

The container needs each device's *VFIO group* node passed in explicitly. The
group numbers are **host-specific** — compute yours:

**HOST**
```bash
GPU_BDFS="0000:0c:00.0 0000:0c:00.1"
NVME_BDF="0000:04:00.0"
for bdf in $GPU_BDFS $NVME_BDF; do
  echo "$bdf -> $(readlink -f /sys/bus/pci/devices/$bdf/iommu_group)"
done
```

The basename of each path is the group number `N`; you pass `/dev/vfio/N`. On
the reference host this resolved to: GPU `0c:00.0 -> 27`, GPU `0c:00.1 -> 28`,
NVMe `04:00.0 -> 22`, i.e. `/dev/vfio/27`, `/dev/vfio/28`, `/dev/vfio/22`. Use
**your** numbers below.

### The host data directory (HOST)

A single host directory is bind-mounted to `/data` in every stage. It holds the
cached guest image, per-stage logs, the Ceph config/state, and the runtime
sockets. Create it once:

**HOST**
```bash
export DATA_DIR="$HOME/.local/share/rocm-xio-kv"
mkdir -p "$DATA_DIR"
```

---

## 3. Build the image (HOST)

**HOST**
```bash
docker build -t rocm-xio-kv-ceph:dev docker/rocm-xio-kv-ceph
```

This compiles SPDK **and** the QEMU fork from source plus pulls packaged Ceph,
so it takes roughly **4–30 minutes** depending on the machine. The image tag
`rocm-xio-kv-ceph:dev` is used throughout this README.

To override a source pin at build time, pass `--build-arg` (see the `ARG` lines
in the `Dockerfile`), e.g. `--build-arg QEMU_FORK_REF=<ref>`.

---

## 4. Quick validation — device-free selftest (HOST -> CONTAINER)

This is the fastest way to prove the KV data path. It brings up Ceph + SPDK +
`kvdev_rados` **inside the container** and performs a real KV
store / retrieve / delete round-trip. **No VM, no GPU, no host devices.** It
needs `--privileged` (SPDK/DPDK EAL) and the `/data` bind mount.

**HOST**
```bash
docker run --rm -it --privileged \
  -v "$DATA_DIR":/data \
  rocm-xio-kv-ceph:dev selftest
```

A **PASS** ends with a line from the fork self-test:

```
kv_rados_vfio_user: PASS
```

The full transcript is written on the host at
`$DATA_DIR/log/selftest.log` (and Ceph bring-up at `$DATA_DIR/log/ceph-up.log`).

---

## 5. Build the guest image (HOST -> CONTAINER)

This clones the VM tooling + the Ansible provisioning repo and runs `gen-vm`
**with** Ansible to produce the guest qcow. The guest checks out
`mmgaggle/rocm-xio@nvme-kv`, builds the kmod, and applies the GRUB/device cheats.
It needs `/dev/kvm` and an SSH key (it generates an ephemeral
`~/.ssh/id_ed25519` if you don't mount one).

It is heavy: it downloads a ~600 MB Ubuntu cloud image and runs a full Ansible
play. The result is **cached** at
`$DATA_DIR/images/kv-ceph-vm.qcow2` and **skipped on re-run** unless you pass
`-e FORCE=1`.

The commands below include the **recommended fork override** for the tuned
launcher (`run-vm-modified`). The image defaults to the *upstream* VM tooling
(`sbates130272/qemu-minimal`), which boots a VM but will **not** reach the full
GPU pass; the override is what enables it.

**HOST**
```bash
docker run --rm -it \
  --device /dev/kvm --group-add kvm \
  -v "$DATA_DIR":/data \
  -v "$HOME/.ssh":/root/.ssh:ro \
  -e QEMU_MINIMAL_REMOTE=https://github.com/john00003/qemu-minimal \
  -e QEMU_MINIMAL_BRANCH=users/john00003/john-modifications \
  -e RUNVM_SCRIPT=qemu/run-vm-modified \
  rocm-xio-kv-ceph:dev build-vm
```

(The `~/.ssh` read-only mount lets `gen-vm` reuse your existing key and is also
how you supply credentials for a private fork — see section 11. `build-vm`
does **not** claim the GPU or NVMe.)

Progress and any failures are logged on the host at
`$DATA_DIR/log/gen-vm.log`.

---

## 6. Full GPU E2E (HOST -> CONTAINER -> VM)

> **SAFETY:** this stage claims the **real GPU and the real NVMe** via VFIO.
> Confirm no other VM or process is using them first. The NVMe you name **must
> not** be your root disk — `guard.sh` refuses `0000:01:00.0` outright.

### 6a. Start `serve` (HOST -> CONTAINER)

`serve` runs the guards, brings up Ceph + the SPDK KV target, ensures the guest
qcow exists, then **launches the VM in the foreground** (it blocks). Use **your**
`/dev/vfio/<N>` numbers from section 2.

The in-container SPDK target uses DPDK EAL the same way `selftest` does, so the
container needs `--privileged` (or at least the DPDK-required caps) **and** the
explicit `--device` flags for KVM + VFIO passthrough, **and** the SSH port map.
The practical, working invocation is `--privileged` + the `--device` flags +
`-p 2223:2223`:

**HOST**
```bash
docker run --rm -it --name kv-serve \
  --privileged \
  --device /dev/kvm \
  --device /dev/vfio/vfio \
  --device /dev/vfio/22 \
  --device /dev/vfio/27 \
  --device /dev/vfio/28 \
  --group-add kvm --cap-add IPC_LOCK \
  -p 2223:2223 \
  -v "$DATA_DIR":/data \
  -v "$HOME/.ssh":/root/.ssh:ro \
  -e QEMU_MINIMAL_REMOTE=https://github.com/john00003/qemu-minimal \
  -e QEMU_MINIMAL_BRANCH=users/john00003/john-modifications \
  -e RUNVM_SCRIPT=qemu/run-vm-modified \
  rocm-xio-kv-ceph:dev serve
```

> Least-privilege goal: the GPU/NVMe passthrough needs only the `--device` flags
> plus `--cap-add IPC_LOCK`, not full `--privileged`. If you can get the
> in-container SPDK target to start without `--privileged`, prefer dropping it.
> In practice the DPDK EAL wants `--privileged`, so it is documented here.

Leave this terminal running (QEMU is in the foreground).

### 6b. Confirm the guest is up (HOST -> VM)

In a second terminal, SSH into the guest and check the KV NVMe is present:

**HOST**
```bash
ssh -p 2223 -o StrictHostKeyChecking=no ubuntu@localhost
```

**VM**
```bash
ls -l /dev/nvme0          # the SPDK kvdev_rados KV namespace
lsblk
```

### 6c. Run the test suite (HOST -> CONTAINER)

With `serve` still running, drive the `gpu-e2e` stage in the **same** running
container via `docker exec`. It waits for guest SSH on 2223, preflights that the
guest is provisioned (`~/src/rocm-xio`, `/dev/rocm-xio`, the kmod), then runs the
rocm-xio ctest suite over SSH.

**HOST**
```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh gpu-e2e
```

The result and full ctest output are logged on the host at
`$DATA_DIR/log/gpu-e2e.log`.

**Validated result (Navi 21 / gfx1030, real Samsung 980 PRO): 90/93 tests pass**
(`ctest -LE rdma`). Three tests remain failing — `test-doorbell-coherence`,
`nvme-verify-seq-device-mem-queues`, `nvme-smoke-memmode-3` — all in the
multi-queue device-memory + doorbell-coherence path (a GPU HSA exception, code
`0x1016`). These are deep device-write/multi-queue faults, documented as a
known follow-up; they are independent of the container plumbing.

**Two things are required for this result and are baked into the provisioning**
(`john00003/batesste-ansible @ users/john00003/rocm-xio-kv-docker`):

1. **GPU code-object arch must match the runtime GPU.** The guest qcow is built
   in a GPU-less builder VM, so rocm-xio's CMake auto-detect finds no GPU and
   falls back to `gfx906`; the resulting `xio-tester` then **segfaults on every
   kernel launch** against a `gfx1030` card. The role pins
   `rocm_xio_setup_offload_arch` (default `gfx1030`, override via
   `guest_gpu_arch`) → `cmake -DOFFLOAD_ARCH=`. Match this to YOUR GPU.
2. **GPU-passthrough boot params.** The role applies a GRUB drop-in
   (`pci=realloc=on intel_iommu=on iommu=pt nvme.poll_queues=1`) via
   `rocm_xio_setup_grub_cmdline`.

Note: Kyle's `nvme-kv` branch already incorporates the `XIO_DEVICE_MEM_UNCACHED`
device-mem fix (in `allocateGpuAccessibleBuffer`), so the basic NVMe→VRAM
device-mem tests pass without a manual patch — only the 3 multi-queue/doorbell
cases above remain. `docs/ROCXIO_CONFIG_MATRIX.md` describes the older
bare-metal tiers (48/48 etc.) for historical reference.

---

## 7. Inside the VM — manual runs (VM)

Once SSH'd into the guest (section 6b), you can run the matrix's exact command
yourself. This is what `gpu-e2e` runs for you:

**VM**
```bash
cd ~/src/rocm-xio
sudo env ROCXIO_NVME_DEVICE="$ROCXIO_NVME_DEVICE" \
         NVME_DEVICE="$ROCXIO_NVME_DEVICE" \
         USE_PCI_MMIO_BRIDGE=1 \
  taskset -c 0-4 ctest --test-dir build -LE rdma --output-on-failure
```

`ROCXIO_NVME_DEVICE` is exported in the guest by
`/etc/profile.d/rocm-xio.sh` (the by-id path of the real NVMe). `-LE rdma`
excludes the RDMA-labelled tests. The `taskset -c 0-4` pin and
`nvme.poll_queues=1` GRUB cheat dodge the QID-wedge flake (see the matrix
"cheats" section).

---

## 8. Volume layout (HOST)

Everything persistent lives under `$DATA_DIR` (`$HOME/.local/share/rocm-xio-kv`),
bind-mounted to `/data` in the container:

```
$DATA_DIR/
  images/        cached guest qcow (kv-ceph-vm.qcow2) + the Ubuntu cloud image
  log/           per-stage logs:
                   ceph-up.log    Ceph mon/mgr/osd bring-up
                   nvmf_tgt.log   SPDK target stdout/stderr
                   gen-vm.log     build-vm tooling clone + Ansible + gen-vm
                   selftest.log   the KV round-trip self-test transcript
                   gpu-e2e.log    the guest ctest output (NN/NN result)
  ceph/          Ceph data dir (bind-mounted state)
  run/           runtime sockets + pidfiles:
                   spdk.rpc.sock      SPDK JSON-RPC socket
                   muser/cntrl        the vfio-user control socket QEMU attaches
                   vfio_user_sock     file recording the socket path
                   *.pid              tracked pids (cleanup kills only these)
```

---

## 9. Configuration reference

All tunables are documented in `.env.example`. Copy it to `.env` and edit, or
pass individual vars with `docker run -e NAME=value` (as shown above), or use
`--env-file .env`.

**Upstream default vs. recommended fork override:**

| Variable | Upstream default (boots, no full GPU pass) | Recommended override (full GPU pass) |
|---|---|---|
| `QEMU_MINIMAL_REMOTE` | `https://github.com/sbates130272/qemu-minimal` | `https://github.com/john00003/qemu-minimal` |
| `QEMU_MINIMAL_BRANCH` | `master` | `users/john00003/john-modifications` |
| `RUNVM_SCRIPT` | `qemu/run-vm` | `qemu/run-vm-modified` |

The guest provisioning Ansible already defaults to a fork
(`john00003/batesste-ansible@users/john00003/rocm-xio-kv-docker`) because the
proven KV config was uncommitted upstream (see section 12).

**Vars that MUST match your host hardware (GPU E2E):**

| Variable | Meaning |
|---|---|
| `GPU_BDFS` | GPU VGA + audio function BDFs (comma-separated) |
| `NVME_BDF` | the spare NVMe BDF (never the root disk) |
| `ROCXIO_NVME_DEVICE` | the guest by-id path of that NVMe |
| `VRAM_DEV_INDEX` | 1-based index into `PCI_HOSTDEV` of the GPU VGA fn (NVMe-first ordering → `2`); required for the device-mem tests |
| `SSH_PORT` | guest SSH port (default `2223`; `2222` is refused) |

`VRAM_DEV_INDEX` is **order-sensitive**: the launcher builds `PCI_HOSTDEV` as
`NVME_BDF,GPU_BDFS`, so index `2` is the GPU VGA function (fn0). Pointing it at
the GPU audio function (fn1) silently disables the VRAM fast path.

---

## 10. Safety

The container is deliberately conservative:

- **`guard.sh` refusals** (run before every device-touching stage):
  - `NVME_BDF=0000:01:00.0` is refused — it is the reference host's **root
    disk**. Any NVMe whose namespace is a *mounted* block device is also refused.
  - `SSH_PORT=2222` is refused (reserved by the author's parallel session) — use
    `2223`+. An already-bound port is refused too.
  - `VM_NAME=rocm-passthrough*` is refused so it cannot clobber a normal VM; use
    `kv-ceph-vm`.
  - It also asserts `/dev/kvm` and the `/dev/vfio/*` nodes are present and tells
    you the exact `--device` flags to add if they are missing.
- **No host driver rebinds.** The container never touches host driver bindings;
  you bind the GPU/NVMe to `vfio-pci` yourself (section 2).
- **Devices only via explicit `--device`.** The container claims a device only if
  you passed its node on `docker run`.
- **Scoped teardown.** The `serve` stage installs `trap kill_tracked` and the
  `cleanup` stage calls it; `kill_tracked` kills **only** the pids this container
  recorded (`/data/run/*.pid`) — it never sweeps host processes.

To tear down explicitly:

**HOST**
```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh cleanup
# then Ctrl-C the serve terminal (or: docker rm -f kv-serve)
```

---

## 11. Private fork clone

Both forks default to **public HTTPS**, so no credentials are needed for the
defaults. If you point any source var at a **private** fork, mount an SSH key (or
agent) into the container and use an SSH remote URL. The `build-vm` / `serve`
examples already mount `~/.ssh` read-only:

**HOST**
```bash
docker run --rm -it \
  --device /dev/kvm --group-add kvm \
  -v "$DATA_DIR":/data \
  -v "$HOME/.ssh":/root/.ssh:ro \
  -e QEMU_MINIMAL_REMOTE=git@github.com:youruser/qemu-minimal.git \
  -e QEMU_MINIMAL_BRANCH=your-branch \
  -e RUNVM_SCRIPT=qemu/run-vm-modified \
  rocm-xio-kv-ceph:dev build-vm
```

---

## 12. Deviations from AICOMXIO-84

- **Packaged Ceph, not the Ceph fork built from source.** SPDK links the system
  `librados` (19.2.3); mixing in a source-built Ceph broke `nvmf_tgt`. The image
  uses Ubuntu's packaged Ceph + `librados-dev`, which the verified `selftest`
  exercises end-to-end.
- **Upstream VM tooling by default.** The image defaults to
  `sbates130272/qemu-minimal@master`. It boots a VM but does not reach the full
  GPU pass; the tuned launcher is the documented override (sections 5/6/9).
- **Ansible provisioning from a fork.** The proven KV guest config
  (`rocm-xio@nvme-kv` checkout, kmod build, GRUB/device-mem cheats) was
  uncommitted upstream, so the image clones
  `john00003/batesste-ansible@users/john00003/rocm-xio-kv-docker` by default.

---

## 13. Troubleshooting

All stages log to `/data/log/<stage>.log` on the host (`$DATA_DIR/log/`). Start
there.

| Symptom | Where to look / fix |
|---|---|
| `build-vm` fails | `gen-vm.log` — Ansible clone/collection install or the `gen-vm` run; a private fork without a mounted key shows a clone failure |
| Ceph never ready | `ceph-up.log` — `ceph_up` dies loudly if mon quorum, OSD up/in, or `active+clean` PGs don't form in time |
| `nvmf_tgt` won't start | `nvmf_tgt.log` — usually missing `--privileged` (DPDK EAL) for `selftest`/`serve` |
| `vfio device node missing` | the guard prints the exact `--device /dev/vfio/<N>` flags to add; recompute your group numbers (section 2) |
| guest SSH never comes up | `serve` terminal (QEMU console) + `gen-vm.log`; `gpu-e2e` dies with "guest SSH never came up on 2223" after ~3 min |
| guest "not provisioned" | the Ansible play didn't land `~/src/rocm-xio` / `/dev/rocm-xio` / the kmod — check `gen-vm.log`, rebuild with `-e FORCE=1` |
| port already in use | `guard.sh` refuses a bound `SSH_PORT`; pick a free port (not `2222`) and re-map `-p` |
| ALL hardware/nvme tests SEGFAULT | GPU code-object mismatch: the qcow's `xio-tester` was built for the wrong arch. Set `guest_gpu_arch` / `rocm_xio_setup_offload_arch` to your GPU (e.g. `gfx1030`) and rebuild the qcow (`-e FORCE=1`). |
| 3 device-mem/doorbell tests fail (90/93) | known deep multi-queue device-mem + doorbell-coherence faults (GPU HSA `0x1016`); documented follow-up, independent of the container |
