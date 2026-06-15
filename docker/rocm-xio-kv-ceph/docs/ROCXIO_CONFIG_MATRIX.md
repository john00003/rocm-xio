> Vendored 2026-06-15 from ~/code/qemu-minimal/qemu/ROCXIO_CONFIG_MATRIX.md. Absolute host paths within (e.g. ~/code/qemu-mmio-bridge/build/) refer to the original author's environment, not container paths.

# rocm-xio Test Configuration Matrix

Consolidated from the repo reports (`ROCXIO_ALL_PASS_REPRO.md`,
`ROCXIO_EMULATED_NVME_TEST_REPORT.md`, `DEVICE_MEM_FIX_AUDIT.md`,
`QID8_RACE_REPORT.md`, `QID8_WEDGE_EXPLAINER.md`) and the auto-memory
references. Captured 2026-06-13.

## The three independent failure classes (and what each knob targets)

| Failure class | Affected tests | Root cause | Working mitigation |
|---|---|---|---|
| **GPU wave fault on all hardware nvme tests** | ~17 | vIOMMU isolates GPU from NVMe DMA pages; doorbells never route | `IOMMU=disable` + `USE_PCI_MMIO_BRIDGE=1` |
| **NVMe→VRAM peer DMA (device-mem)** | 5 (#26/27/29/38/44, modes 8/11/3/multi-LBA) | q35 `pcie.0` won't peer-route; GPU L2 holds writes, no PCIe snoop in QEMU | QEMU `vram-dev` prop (`VRAM_DEV_INDEX`) + rocm-xio `XIO_DEVICE_MEM_UNCACHED` |
| **QID-8 wedge (30s timeout flakes)** | #25/28/29/44 intermittently | xio-tester deletes kernel-owned QID, never restores it | `nvme.poll_queues=1` + `taskset -c 0-4` (partial); real fix = `fix/qid8-restore-kernel-queue` |

## QEMU / launcher options tried

| Knob | Values tried | Verdict |
|---|---|---|
| `IOMMU` | `enable` / `disable` | **`disable`** — vIOMMU regresses 46→28/48 (rocm-axiio hands raw GPAs, not IOVAs) |
| `PCI_MMIO_BRIDGE` | enable / disable | **`enable`** required — bridges doorbells across root ports |
| `poll-interval-ns` | 1ms (upstream) / **10µs** | 10µs shrinks the DELETE-vs-replay race 100× (doesn't eliminate) |
| `PCI_SWITCH` (xio3130) | enable / disable | **DEAD** — amdgpu refuses multi-hop (`AtomicOpsCap: Routing-`) |
| Emulated NVMe placement | bare `pci.0` / **own pcie-root-port** | own root-port required, else Navi 21 BAR0 can't 16GiB-align |
| QEMU build | stock 8.2.2 / **`~/code/qemu-mmio-bridge`** | custom fork required (ships `pci-mmio-bridge` + VRAM-DMA) |
| QEMU VRAM detect | hardcoded range / **`vram-dev`/`vram-bar` props** | fork dropped the `[0xc000…,0xc800…)` range 2026-05-28; now `nvme_addr_is_vram()` reads the live BAR of the device named by `VRAM_DEV_INDEX`. Must set `VRAM_DEV_INDEX` or fast path is off |
| Test device | emulated `/dev/nvme1n1` / **real 980 PRO** | emulated path stuck at 46/48 (#46 NVMe→VRAM unfixable); real NVMe enables 48/48 |
| `taskset` | none / `0-6` / **`0-4`** | tighter pin dodges the QID-6 wedge migration too |
| `nvme.io_queue_count` | tried | **doesn't exist** as a kernel param — use `poll_queues` |

---

# Best Known Configuration (48/48 passing)

This is the `DEVICE_MEM_FIX_AUDIT.md` config — `ROCXIO_ALL_PASS_REPRO.md`
plus the two device-mem patches that close the final 5.

**1. Launch the VM** (host `cgy-decidueye`, custom QEMU via `QEMU_PATH` default):
```bash
cd ~/code/qemu-minimal/qemu
VM_NAME=rocm-passthrough SSH_PORT=2222 UEFI=enable \
  PCI_HOSTDEV=0000:04:00.0,0000:0c:00.0,0000:0c:00.1 \
  VRAM_DEV_INDEX=2 VRAM_BAR=0 \
  VCPUS=8 VMEM=15360 NVME=2 IOMMU=disable \
  ./run-vm-modified
```
Relies on `run-vm-modified` defaults: `QEMU_PATH=~/code/qemu-mmio-bridge/build/`,
`PCI_MMIO_BRIDGE=enable` (`poll-interval-ns=10000`). The real Samsung 980 PRO
at `0000:04:00.0` comes up as `/dev/nvme2n1`.

`VRAM_DEV_INDEX=2` is **required** for the 5 device-mem tests: it points the
emulated NVMe's `vram-dev` link at the 2nd `PCI_HOSTDEV` entry — the Navi 21
GPU **VGA function** at `0000:0c:00.0` (the `04:00.0` NVMe is entry 1).
`VRAM_BAR=0` selects BAR0 (the 16 GiB VRAM aperture). The Navi 21 is a
multi-function device: `0c:00.0` (VGA, fn0) carries the 16 GiB BAR0; the
sibling `0c:00.1` (HDMI/DP audio, fn1, entry 3) only has a 16 KiB BAR and is
the **wrong** target — pointing `vram-dev` there silently disables the fast
path. Always target fn0. The QEMU fork no longer hardcodes the VRAM
GPA range (that was replaced 2026-05-28 by the `vram-dev`/`vram-bar`
properties — commits `251cf60c57`, `623a7fab89`), so `nvme_addr_is_vram()`
returns false and the VRAM-P2P fast path is dead unless `vram-dev` is set.
Without `VRAM_DEV_INDEX` this config regresses to 43/48. The index is
order-sensitive — if you reorder `PCI_HOSTDEV` (e.g. GPU first), update it.

**2. Env / state inside the VM:**
- GRUB drop-in `/etc/default/grub.d/99-rocm-xio.cfg`:
  `... pci=realloc=on intel_iommu=on iommu=pt nvme.poll_queues=1`
- `/etc/profile.d/rocm-xio.sh` exports `ROCXIO_NVME_DEVICE` + `NVME_DEVICE` =
  `/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NC0RA03709B`
- `rocm-xio` kmod auto-loaded (`/etc/modules-load.d/rocm-xio.conf`)
- rocm-xio source patched: two call sites `XIO_DEVICE_MEM_HIP` →
  `XIO_DEVICE_MEM_UNCACHED` (`xio-common.hip:766` SQ/CQ, `:2531` data buffer)

**3. Run the tests:**
```bash
cd ~/src/rocm-xio
sudo env ROCXIO_NVME_DEVICE=$ROCXIO_NVME_DEVICE \
         NVME_DEVICE=$ROCXIO_NVME_DEVICE \
         USE_PCI_MMIO_BRIDGE=1 \
  taskset -c 0-4 ctest --test-dir build -LE rdma --output-on-failure
```

**Result:** `100% tests passed, 0 tests failed out of 48`.

---

## Two fallback tiers if you can't carry all patches

| Tier | Config delta | Result |
|---|---|---|
| **48/48** | above (real NVMe + `VRAM_DEV_INDEX` set + UNCACHED patch) | all pass |
| **43/48** | real NVMe, `IOMMU=disable`, **no** device-mem patches | 5 device-mem fail |
| **46/48** | emulated NVMe + bridge + 3 test-infra patches | #25 flaky + #46 deterministic |

## The "cheats" (re-validate these first if it regresses)

`taskset -c 0-4` · `nvme.poll_queues=1` · `IOMMU=disable` ·
`XIO_DEVICE_MEM_UNCACHED` · `poll-interval-ns=10000` — each hides a real
defect (QID wedge, raw-GPA IOVA gap, L2-snoop gap, bridge replay race).
Real fixes live in rocm-xio's kmod (`fix/qid8-restore-kernel-queue`),
rocm-axiio IOVA mapping, and a `hipDeviceFlushGpuDCache` before doorbell.

The `XIO_DEVICE_MEM_UNCACHED` patch is RDNA2-specific — a colleague's
RX 9070 XT (RDNA4, gfx1200) passes the device-mem tests unpatched because
gfx12 stores carry `scope:SCOPE_SYS`, forcing system-scope visibility that
gfx1030 lacks.
