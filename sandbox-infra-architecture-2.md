# Unikernel Sandbox Infrastructure — Production Architecture

> **Stack**: Hetzner bare metal → KVM + Firecracker microVMs → Unikraft bincompat unikernels (ELF loader + CPIO initrd) → Snapshot/CoW clone pool → Custom control plane

---

## Table of Contents

1. [System Mental Model](#1-system-mental-model)
2. [Host OS Layer](#2-host-os-layer)
3. [Firecracker + Jailer Layer](#3-firecracker--jailer-layer)
4. [Unikraft Bincompat Layer](#4-unikraft-bincompat-layer)
5. [Snapshot + Copy-on-Write Engine](#5-snapshot--copy-on-write-engine)
6. [Control Plane Architecture](#6-control-plane-architecture)
7. [API Layer](#7-api-layer)
8. [Networking Architecture](#8-networking-architecture)
9. [Lifecycle: Boot, Run, Teardown](#9-lifecycle-boot-run-teardown)
10. [Scale-to-Zero + Warm Pool Strategy](#10-scale-to-zero--warm-pool-strategy)
11. [Scheduler Design](#11-scheduler-design)
12. [Node Agent Design](#12-node-agent-design)
13. [Storage + Snapshot Registry](#13-storage--snapshot-registry)
14. [Security Model](#14-security-model)
15. [Observability Stack](#15-observability-stack)
16. [Hetzner Bare Metal Setup](#16-hetzner-bare-metal-setup)
17. [Implementation Sequence](#17-implementation-sequence)
18. [Key Numbers + SLAs](#18-key-numbers--slas)

---

## 1. System Mental Model

The fundamental idea is a three-tier isolation + speed stack:

```
External Request
      ↓
  API Gateway  (auth, rate limit, routing)
      ↓
  Control Plane Scheduler  (bin-pack, placement)
      ↓
  Node Agent on a Bare Metal Host
      ↓
  Firecracker microVM  (KVM, hardware isolation)
      ↓
  Unikraft ELF Loader unikernel  (minimal OS, <5MB)
      ↓
  CPIO rootfs  (Python/Node runtime + user packages)
```

**The key insight for boot speed**: Cold booting from scratch — even Firecracker + Unikraft — takes ~500-800ms because the kernel must initialize devices, mount initrd, and start the runtime interpreter (Python startup alone is ~300ms). We kill this cold path entirely using **snapshot + CoW cloning**:

1. Once per runtime version, boot a "template" microVM fully to the point where Python/Node is loaded in memory, idle, ready.
2. Snapshot this VM (memory state + CPU registers + device state → files on disk).
3. For every sandbox request: create a new Firecracker process, `mmap(MAP_PRIVATE)` the snapshot memory file, restore CPU state → process-private copy-on-write pages from the first write. The VM is live in **~20-50ms**.

This is exactly how AWS Lambda operates at scale (per the NSDI'20 Firecracker paper and the 2021 "Restoring Uniqueness" paper). We replicate it on our own bare metal.

---

## 2. Host OS Layer

### 2.1 Recommended OS: Debian 12 (Bookworm)

**Why not Alpine**: Alpine uses musl libc and a minimal kernel config. Firecracker + Unikraft need a host with:
- KVM module loaded (`/dev/kvm` available)
- cgroups **v2** unified hierarchy (critical for snapshot latency — cgroups v1 adds ~50ms to snapshot restore)
- `io_uring` support (kernel ≥ 5.10, for async I/O between control plane and Firecracker API sockets)
- `userfaultfd` (kernel ≥ 5.7, for lazy memory restore on snapshot load)
- `memfd_create` (for anonymous memory-backed snapshot files)
- `MADV_POPULATE_READ` / `MADV_WIPEONSUSPEND` (for snapshot uniqueness restoration)

Debian 12 ships kernel 6.1 LTS — covers all of these. Stick with Debian.

### 2.2 Kernel Boot Parameters

```
/etc/default/grub:
GRUB_CMDLINE_LINUX="
  cgroup_no_v1=all
  systemd.unified_cgroup_hierarchy=1
  hugepages=2048
  hugepagesz=2M
  transparent_hugepage=never
  elevator=none
  mitigations=auto
  # ↑ DO NOT set mitigations=off on multi-tenant nodes running untrusted code.
  # See §2.2a for the full security reasoning and a performance-aware alternative.
  amd_iommu=off
  iommu=off
  nohz_full=2-63
  isolcpus=2-63
  irqaffinity=0-1
  rcu_nocbs=2-63
  nosoftlockup
"
```

**Rationale**:
- `cgroup_no_v1=all` — forces cgroups v2, removes v1 overhead from snapshot restore.
- `hugepages=2048` at 2MB each = 4GB pre-allocated. Firecracker guests can use these, reducing TLB pressure.
- `transparent_hugepage=never` — THP causes unpredictable latency spikes during CoW.
- `nohz_full=2-63` + `isolcpus=2-63` — dedicate CPUs 2-63 to sandbox VMs, CPUs 0-1 for OS/control plane. Zero timer interrupts on VM CPUs = more consistent latency.
- **CPU mitigations** — covered in §2.2a below. Never disable globally on a multi-tenant node.

### 2.2a CPU Mitigations: Security vs. Performance Trade-off

> **⚠ Architectural correction**: An earlier version of this document recommended `mitigations=off`. This is only safe for single-tenant or fully-trusted workloads. If you are executing arbitrary code from paying customers, disabling CPU mitigations exposes you to Spectre v2 (Branch Target Injection) and MDS (Microarchitectural Data Sampling) cross-VM memory leakage attacks. Firecracker's KVM boundary is a strong process isolation guarantee; it does not eliminate hardware side-channel attacks that operate below the hypervisor level. These attacks are real, have working exploits, and have been used against cloud providers.

**The threat model decision tree:**

```
Q: Are you running code from mutually distrusting tenants on the same physical host?

YES (production sandbox service for customers):
  → mitigations=auto   (kernel default, covers Spectre v1/v2, Meltdown, MDS, L1TF)
  → Performance cost: 8–20% on KVM exits (most visible in syscall-heavy workloads)
  → Accept this. Your contractual liability and reputation are worth more than 15%.

NO (internal tooling, single-tenant, your own code only):
  → mitigations=off is reasonable
  → Document this explicitly in your threat model
```

**Performance recovery without disabling mitigations globally:**

The biggest mitigation overhead in a Firecracker setup is **Retpoline** (Spectre v2 indirect branch speculation). You can get most of the performance back with fine-grained controls:

```
# Safe partial recovery — only disable mitigations proven low-risk for KVM hosts:
spectre_v2=retpoline,lfence   # use lfence instead of full IBRS (~5% faster than IBRS)
spec_store_bypass_disable=prctl  # only mitigate processes that opt in via prctl
kvm-intel.vmentry_l1d_flush=cond  # L1TF flush only when needed (Intel only)
```

On AMD EPYC (Hetzner AX102): Spectre v2 and Meltdown are significantly less exposed than Intel due to architectural differences in branch prediction isolation. AMD EPYC 9454P (Zen 4) is not vulnerable to MDS at all. The net mitigation overhead on this specific hardware is closer to **5–8%**, not 15–20%. AMD bare metal is the right choice for a performance-conscious multi-tenant setup.

**Summary:** Ship with `mitigations=auto` on day one. Profile your actual P99 latency under load. If you need to claw back performance later, apply the targeted AMD-specific overrides above — measured and documented, not a blanket off switch.

### 2.3 System Tuning

```bash
# /etc/sysctl.d/99-sandbox.conf
kernel.pid_max = 4194304
kernel.threads-max = 4194304
vm.max_map_count = 16777216
vm.swappiness = 0
vm.overcommit_memory = 1           # allow mmap overcommit for CoW snapshots
net.core.somaxconn = 65535
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
fs.inotify.max_user_instances = 65536
fs.file-max = 26214400
kernel.perf_event_paranoid = -1    # for profiling (tighten in prod)
```

```bash
# /etc/security/limits.d/sandbox.conf
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     unlimited
*    hard    nproc     unlimited
```

### 2.4 Storage Layout

```
/                        # OS root, SSD (200GB)
/var/lib/snapshots/      # Snapshot registry — NVMe, RAID-1 mirrored (see §2.4a)
/var/lib/rootfs/         # Base rootfs CPIO archives per runtime version
/var/run/firecracker/    # Per-VM runtime sockets and ephemeral state — tmpfs
/var/log/sandbox/        # Structured logs
```

### 2.4a RAID Strategy and Snapshot Storage Blast Radius

> **⚠ Architectural correction**: An earlier version of this document specified RAID-0 across 2× NVMe for the snapshot registry. This was wrong. RAID-0 provides zero redundancy — a single drive failure destroys all local snapshots and takes the entire node down hard, with no recovery path short of rebuilding templates from scratch. The IOPS argument doesn't hold up in practice: snapshot memory files are read via `mmap(MAP_PRIVATE)`, meaning each file is read exactly once per node and then lives in the Linux page cache indefinitely. Subsequent clone restores hit the page cache, not the disk, regardless of RAID level.

**Phase 1 (first node, now):** RAID-1 mirror across both NVMe drives via Linux `mdadm`:

```bash
mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/nvme0n1 /dev/nvme1n1
mkfs.ext4 -F /dev/md0
mount /dev/md0 /var/lib/snapshots

# /etc/mdadm/mdadm.conf — add array config + install initramfs hook
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u
```

Write latency doubles on RAID-1 (two disks must confirm each write). This only hits the template snapshot build path (~once per runtime version update) and the diff checkpoint path (~once per minute per long-running VM). Neither is on the sub-50ms hot path. Read performance is identical to a single disk — and reads are almost entirely served from page cache anyway.

**Phase 6 (multi-node, stateless nodes):** Once you treat bare metal nodes as cattle (any node can be wiped and re-provisioned), you can switch to RAID-0 on each node because snapshot templates live in object storage (MinIO/Ceph/S3) as the authoritative source. Local NVMe becomes a write-through cache. Node failure = re-download templates from object store + rebuild warm pool (~60s). At that point the IOPS argument for RAID-0 is legitimate.

---

`/var/run/firecracker` on `tmpfs` is critical: Firecracker UNIX domain socket creation and the API calls over it are on the critical path. tmpfs eliminates fs journal latency.

---

## 3. Firecracker + Jailer Layer

### 3.1 What Firecracker provides

- A KVM-based VMM that emulates exactly 4 virtual devices: vCPU(s), virtio-net, virtio-block, serial console.
- A REST API on a UNIX domain socket for lifecycle management: configure → boot → pause → snapshot → restore → resume → shutdown.
- A `jailer` binary that wraps each Firecracker process in a chroot + seccomp-bpf + cgroup sandbox.
- Snapshot/restore: pause → dump (vmstate + memory) → resume; or load from snapshot files.

### 3.2 Jailer Configuration

Each microVM gets its own jailer invocation:

```bash
/usr/bin/jailer \
  --id "${VM_ID}" \
  --uid 10000 \
  --gid 10000 \
  --chroot-base-dir /srv/jailer \
  --exec-file /usr/bin/firecracker \
  --cgroup-version 2 \
  --resource-limit nofile=4096 \
  -- \
  --api-sock /run/firecracker.sock \
  --config-file /etc/firecracker/vm-${VM_ID}.json \
  --log-path /var/log/sandbox/${VM_ID}.log \
  --level Warn \
  --show-log-origin
```

The jailer:
- Creates `/srv/jailer/${VM_ID}/root/` as the Firecracker chroot.
- Drops all capabilities except `CAP_NET_ADMIN` (for TAP device creation).
- Applies seccomp-bpf filter allowing only the ~50 syscalls Firecracker needs.
- Assigns VM to a dedicated cgroup (`/sys/fs/cgroup/sandbox/${VM_ID}/`).

### 3.3 VM Configuration JSON (template for snapshot restore)

```json
{
  "boot-source": {
    "kernel_image_path": "/var/lib/rootfs/unikraft-base-x86_64",
    "boot_args": "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules random.trust_cpu=on"
  },
  "drives": [],
  "machine-config": {
    "vcpu_count": 1,
    "mem_size_mib": 256,
    "smt": false,
    "track_dirty_pages": true
  },
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "host_dev_name": "tap-${VM_ID}",
      "guest_mac": "AA:FC:00:00:${OCTET3}:${OCTET4}"
    }
  ],
  "logger": {
    "log_path": "/dev/null",
    "level": "Warning"
  }
}
```

`track_dirty_pages: true` is required for diff (incremental) snapshots — only pages written since the last snapshot are saved, enabling fast checkpointing of long-running sandboxes.

### 3.4 Firecracker API Calls via UNIX Socket

The node agent communicates with Firecracker exclusively via its UNIX socket. Key calls:

```
PUT /snapshot/load          → restore from snapshot, start paused
PATCH /vm { "state": "Resumed" } → unpause, VM is running
PATCH /vm { "state": "Paused" }  → pause for new snapshot
PUT /snapshot/create        → create snapshot (diff or full)
PUT /actions { "action_type": "SendCtrlAltDel" } → graceful shutdown
DELETE /                    → force-kill the VM
```

---

## 4. Unikraft Bincompat Layer

### 4.1 How bincompat works

In Unikraft "base compat mode" (the `unikraft.org/base:latest` runtime), the kernel image is the **ELF Loader application** (`app-elfloader`). Here's the full chain:

```
Unikraft kernel (KVM platform)
  └── libkvmplat         (KVM I/O, boot protocol)
  └── libvfscore          (virtual filesystem core)
  └── lib9pfs / initrd   (rootfs mounting)
  └── libsyscall_shim    (Linux syscall interception)
  └── app-elfloader      (main "application": loads user ELF)
        └── user ELF binary (e.g. /usr/bin/python3)
              └── depends on libc.so, libz.so, etc. (in rootfs)
```

The `boot_args` passed to QEMU/Firecracker tell the ELF loader what binary to execute:
```
/usr/bin/python3 /sandbox/run.py
```

The rootfs (CPIO initrd) contains the entire Python (or Node) installation: interpreter binary, standard library, shared libs, pip-installed packages.

### 4.2 Build Pipeline for a Runtime Image

This runs once per runtime version, not per sandbox request:

```bash
# Step 1: Build rootfs from Dockerfile via BuildKit
export KRAFTKIT_BUILDKIT_HOST=docker-container://buildkitd
kraft pkg pull unikraft.org/base:latest

# Step 2: Generate rootfs for Python runtime
cat > Kraftfile << 'EOF'
spec: v0.6
runtime: base:latest
rootfs: ./Dockerfile.python311
cmd: ["/usr/bin/python3"]
EOF

# Dockerfile.python311:
# FROM python:3.11-slim
# RUN pip install numpy pandas requests  # base packages
# COPY entrypoint.py /sandbox/entrypoint.py

kraft build --plat kvm --arch x86_64
# Produces:
#   .unikraft/build/base-kvm-x86_64     ← kernel ELF (Unikraft + ELF loader)
#   .unikraft/build/initramfs-x86_64.cpio ← rootfs CPIO archive
```

For **user-specific packages**: Instead of rebuilding the unikernel kernel, add an overlay CPIO. The base rootfs gets Python + common packages; user packages are in a second CPIO that gets merged at runtime (Unikraft supports multi-CPIO via the initrd chaining mechanism or overlay mount).

### 4.3 Kernel Image Variants

```
/var/lib/rootfs/
├── unikraft-python311-x86_64      # Unikraft kernel ELF (same for all Python 3.11 sandboxes)
├── unikraft-node20-x86_64         # Unikraft kernel ELF for Node.js 20
├── initrd-python311-base.cpio     # Base Python 3.11 rootfs
├── initrd-node20-base.cpio        # Base Node.js 20 rootfs
└── user-overlays/
    └── {user_id}-{hash}.cpio      # Per-user package overlay (generated once, cached)
```

---

## 5. Snapshot + Copy-on-Write Engine

This is the core of the fast-boot system. Understanding it deeply is critical.

### 5.1 The Template Snapshot Process

Run once per runtime version (Python 3.11, Node 20, etc.) or when packages change:

```
1. Boot a Firecracker microVM with the Unikraft kernel + base initrd
   → Unikraft boots (~100ms)
   → ELF loader mounts initrd, starts Python (~300ms)
   → Python imports sys, os, common stdlib → bytecode cached to memory (~200ms)
   → Python sits idle, waiting at input() / select() on stdin

2. PAUSE the VM:
   PUT /vm {"state": "Paused"}

3. CREATE FULL SNAPSHOT:
   PUT /snapshot/create {
     "snapshot_type": "Full",
     "snapshot_path": "/var/lib/snapshots/python311-base.vmstate",
     "mem_file_path": "/var/lib/snapshots/python311-base.mem"
   }

4. RESUME and DESTROY the template VM (it's no longer needed)

Total template creation time: ~600-800ms, one-time cost.
```

The snapshot produces two files:
- `python311-base.vmstate` (~4KB) — CPU registers, device state, VM metadata
- `python311-base.mem` (~100-200MB) — full guest memory dump

### 5.2 CoW Clone Launch (the hot path, ~20-50ms)

```
For each sandbox request:

1. Create a new jailer+Firecracker process (fork-exec): ~5ms

2. Load snapshot via Firecracker API:
   PUT /snapshot/load {
     "snapshot_path": "/var/lib/snapshots/python311-base.vmstate",
     "mem_file_path": "/var/lib/snapshots/python311-base.mem",
     "enable_diff_snapshots": true,
     "resume_vm": false         ← start paused, configure network first
   }
   
   Internally, Firecracker does:
     mmap(python311-base.mem, MAP_PRIVATE | MAP_POPULATE)
   The MAP_PRIVATE flag means: the mem file is the read-only backing store.
   Any write by the guest creates a private copy of that page (CoW).
   The original .mem file is NEVER modified.
   
   Cost: ~15ms (page tables set up, no physical page copies yet)

3. Attach TAP device + configure network: ~3ms

4. RESUME:
   PATCH /vm {"state": "Resumed"}
   
   The VM wakes up exactly where the template was — Python is already
   loaded, stdlib is imported, bytecode caches are warm.
   
5. Inject the sandbox code via the guest agent (virtio-vsock or serial):
   → Send: {"code": "import numpy; print(numpy.random.rand(3))"}
   → Receive: {"stdout": "[0.42 0.17 0.88]", "stderr": "", "exit_code": 0}

Total wall-clock from request to first output: ~50-100ms
(20-50ms restore + 10-30ms code execution for simple scripts)
```

### 5.3 CoW Memory Isolation

A critical property: each clone's memory pages are **private**. When Python in clone A writes to heap memory, it gets its own physical page. Clone B continues reading from the original snapshot-backed page. The Linux page cache manages this transparently via `copy_on_write` page faults.

This gives us:
- **Memory deduplication for free**: 100 simultaneous sandboxes all running Python 3.11 share the read-only pages (Python binary, stdlib bytecode, loaded .so files). Only the dirty pages (heap allocations, user data) are private. A 200MB snapshot backing 100 VMs uses ~200MB + (N × dirty_pages) — vs 100 × 200MB = 20GB without CoW.
- **Zero explicit synchronization**: the kernel's VM subsystem handles all of this.

### 5.4 CSPRNG / Uniqueness Restoration

A critical correctness issue: all clones start from the same snapshot, so they have the same CSPRNG state. This means `uuid.uuid4()`, `secrets.token_hex()`, `os.urandom()` would return **the same values** in every clone.

Fix: immediately after `resume_vm`, inject into the guest kernel's entropy pool via the guest agent:

```go
// Guest agent (runs inside the unikernel as PID 1 helper)
// At startup, receive fresh entropy from host via virtio-vsock:
hostEntropy := receiveFromHost()  // 64 bytes from /dev/urandom on host
syscall.IoctlSetInt(fd_urandom, RNDADDENTROPY, hostEntropy)
```

The host control plane generates fresh entropy per clone and sends it as the first message over the vsock channel.

Additionally, re-seed Python's random:
```python
import os, random
random.seed(os.urandom(32))
```

### 5.5 Diff Snapshots for Long-Running Sandboxes

For sandboxes that run for minutes (e.g. a data pipeline), periodic diff snapshots allow:
- Fast resume if the sandbox crashes or the host reboots
- Checkpointing before expensive operations

```
Every 60s (or on explicit checkpoint request):
  PUT /vm {"state": "Paused"}
  PUT /snapshot/create {
    "snapshot_type": "Diff",
    "snapshot_path": "/var/lib/snapshots/{vm_id}/checkpoint-{ts}.vmstate",
    "mem_file_path": "/var/lib/snapshots/{vm_id}/checkpoint-{ts}.diff"
  }
  PATCH /vm {"state": "Resumed"}

The diff file contains only dirty pages since the last snapshot.
Typical diff size: 5-30MB (vs 200MB for full snapshot).
Pause time: <50ms.
```

---

## 6. Control Plane Architecture

### 6.1 Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                    CONTROL PLANE                         │
│                                                         │
│  ┌──────────────┐   ┌─────────────┐   ┌─────────────┐  │
│  │  API Server  │   │  Scheduler  │   │ Snapshot     │  │
│  │  (Go/Gin)    │──▶│  (Go)       │──▶│ Manager     │  │
│  │  Port 8080   │   │             │   │ (Go)         │  │
│  └──────────────┘   └──────┬──────┘   └─────────────┘  │
│                            │                            │
│  ┌──────────────┐          │          ┌─────────────┐  │
│  │  State Store │◀─────────┘          │  Image      │  │
│  │  (etcd/Redis)│                     │  Registry   │  │
│  └──────────────┘                     └─────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │                  Node Registry                    │  │
│  │  node_id → {host, port, cpu_free, mem_free,      │  │
│  │             warm_pool_count, status, last_seen}   │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │  gRPC (internal)
         ▼
┌─────────────────────────────────┐
│          NODE AGENT             │  ← One per bare metal host
│          (Go binary)            │
│                                 │
│  ┌─────────────────────────┐   │
│  │   VM Lifecycle Manager  │   │
│  │   (creates, monitors,   │   │
│  │    destroys FCs)        │   │
│  └─────────────────────────┘   │
│                                 │
│  ┌─────────────────────────┐   │
│  │   Warm Pool Manager     │   │
│  │   (pre-warmed clones)   │   │
│  └─────────────────────────┘   │
│                                 │
│  ┌─────────────────────────┐   │
│  │   Network Manager       │   │
│  │   (TAP devices, routes) │   │
│  └─────────────────────────┘   │
│                                 │
│  ┌─────────────────────────┐   │
│  │   Resource Monitor      │   │
│  │   (CPU, mem, I/O per VM)│   │
│  └─────────────────────────┘   │
└─────────────────────────────────┘
```

### 6.2 State Machine for a Sandbox

```
REQUESTED
    │ scheduler assigns node
    ▼
SCHEDULED
    │ node agent picks from warm pool
    ▼
CLONING  (~20ms)
    │ Firecracker restores snapshot
    ▼
CONFIGURING  (~5ms)
    │ TAP device attached, network configured
    │ entropy injected
    │ user code staged to vsock
    ▼
RUNNING
    │ code executes
    ├──▶ CHECKPOINTING (optional, periodic)
    │
    ▼ (on completion or timeout)
DRAINING
    │ stdout/stderr flushed to caller
    ▼
TEARING_DOWN
    │ Firecracker process killed
    │ TAP device removed
    │ cgroup cleaned up
    │ tmpfs runtime dir wiped
    ▼
DESTROYED
    │ warm pool replenished (+1 clone pre-warmed)
    ▼
BILLED / LOGGED
```

### 6.3 Control Plane Data Model (Go structs)

```go
type SandboxRequest struct {
    ID          string            `json:"id"`
    Runtime     RuntimeType       `json:"runtime"`   // python311, node20
    Code        string            `json:"code"`
    Stdin       string            `json:"stdin,omitempty"`
    Env         map[string]string `json:"env,omitempty"`
    Timeout     time.Duration     `json:"timeout"`   // max execution time
    MemoryMiB   int               `json:"memory_mib"`
    VCPUs       int               `json:"vcpus"`
    Packages    []string          `json:"packages,omitempty"` // extra pip/npm packages
}

type SandboxResult struct {
    ID         string        `json:"id"`
    Stdout     string        `json:"stdout"`
    Stderr     string        `json:"stderr"`
    ExitCode   int           `json:"exit_code"`
    WallTime   time.Duration `json:"wall_time"`
    CPUTime    time.Duration `json:"cpu_time"`
    MemoryUsed int64         `json:"memory_bytes"`
    Error      string        `json:"error,omitempty"`
}

type VMState struct {
    VMID        string
    NodeID      string
    Status      VMStatus
    Runtime     RuntimeType
    SnapshotID  string
    TAPID       string
    GuestIP     net.IP
    VsockCID    uint32
    CPUThrottle float64
    MemLimitMiB int
    CreatedAt   time.Time
    StartedAt   time.Time
    ActiveAt    time.Time
    DeadlineAt  time.Time
    PID         int
}
```

---

## 7. API Layer

### 7.1 API Server (Go + Gin)

```go
// Routes
POST   /v1/sandbox/run          → sync execution, waits for result
POST   /v1/sandbox/create       → async, returns sandbox_id
GET    /v1/sandbox/:id/status   → poll status
GET    /v1/sandbox/:id/result   → fetch result when done
DELETE /v1/sandbox/:id          → force terminate
POST   /v1/sandbox/:id/stdin    → inject stdin to running sandbox
GET    /v1/sandbox/:id/stream   → SSE stream of stdout/stderr

// Internal
GET    /internal/nodes          → node list + health
GET    /internal/snapshots      → snapshot registry
POST   /internal/snapshots/build → trigger snapshot rebuild
GET    /metrics                 → Prometheus metrics
GET    /healthz                 → liveness
GET    /readyz                  → readiness
```

### 7.2 Request Flow (sync run)

```
Client → POST /v1/sandbox/run
  │
  ├── Auth middleware (API key / JWT)
  ├── Rate limit middleware (per-tenant token bucket)
  ├── Request validation (code size, timeout bounds, runtime enum)
  │
  ├── Scheduler.Schedule(req) → NodeID, SnapshotID
  │
  ├── NodeAgent.RunSandbox(nodeID, req)   [gRPC call, deadline = req.Timeout + 5s]
  │     ├── Pick VM from warm pool
  │     ├── Configure VM (network, entropy, code)
  │     ├── Resume VM
  │     ├── Stream stdout/stderr via vsock
  │     └── Return SandboxResult
  │
  └── HTTP 200 { result }  OR  HTTP 408 { timeout }  OR  HTTP 500 { error }
```

### 7.3 SSE Streaming

For long-running sandboxes, stream stdout/stderr in real time:

```
Client → GET /v1/sandbox/{id}/stream
  → HTTP 200, Content-Type: text/event-stream
  
data: {"type":"stdout","data":"Processing row 1...\n","ts":1234567890}
data: {"type":"stdout","data":"Processing row 2...\n","ts":1234567891}
data: {"type":"stderr","data":"WARNING: deprecated\n","ts":1234567892}
data: {"type":"exit","exit_code":0,"wall_time_ms":1240}
```

The node agent bridges vsock output to a Redis pub/sub channel. The API server subscribes and fans out to SSE connections. This decouples the API server from the node agent (different hosts possible).

### 7.4 Package Installation Flow

If `packages` is non-empty in the request:

```
1. Compute overlay hash: sha256(sorted(packages) + runtime_version)

2. Check overlay cache:
   - HIT: use cached overlay CPIO at /var/lib/rootfs/user-overlays/{hash}.cpio
   - MISS: 
     a. Spin up a privileged "build VM" (not the sandbox VM):
        - Full Linux guest (Alpine) with pip/npm
        - Install requested packages
        - Package /usr/local/lib/python3.11/site-packages/ → CPIO
        - Store at /var/lib/rootfs/user-overlays/{hash}.cpio
        - Build time: 5-60s depending on packages
     b. Use the new overlay CPIO

3. On sandbox boot, the initrd is: base.cpio + overlay.cpio
   (Unikraft's multi-initrd support merges them at mount time)
```

---

## 8. Networking Architecture

### 8.1 Per-VM TAP Device

Each Firecracker microVM gets one TAP device on the host:

```bash
# Created by node agent before VM boot:
ip tuntap add tap-${VM_ID} mode tap
ip link set tap-${VM_ID} up
ip link set tap-${VM_ID} master br-sandbox

# Deleted after VM teardown:
ip link del tap-${VM_ID}
```

### 8.2 Bridge + IPAM

```
Host
  └── br-sandbox (bridge, 172.20.0.1/16)
       ├── tap-vm001 → VM001 (172.20.1.1)
       ├── tap-vm002 → VM002 (172.20.1.2)
       └── tap-vm003 → VM003 (172.20.1.3)
```

IP allocation: the node agent maintains a simple bitmap allocator over 172.20.0.0/16 = 65534 addresses. Allocation = `O(1)`, stored in memory + persisted to a small file for restart recovery.

### 8.2a IPv6 Strategy

> **⚠ Gap in original design**: The architecture was entirely IPv4-only. Hetzner provides a `/64` IPv6 subnet per server (e.g. `2a01:4f8:xxxx:xxxx::/64`). Ignoring this creates real operational friction: modern APIs (Cloudflare, some Google APIs, certain CDNs) increasingly require or prefer IPv6. More concretely, as IPv4 exhaustion continues, some services are moving to IPv6-only. Sandboxes that can only speak IPv4 will silently fail to reach those services.

**The two problems to solve:**

1. **Outbound IPv6 from sandboxes** — sandboxes need to be able to initiate IPv6 connections to the internet.
2. **IPv6 for the guest network** — guests need IPv6 addresses (ULA or GUA).

**Solution: NAT66 + ULA internal addressing**

Use a `fd00::/8` ULA (Unique Local Address) block internally for the sandbox bridge, and NAT66 outbound to the host's Hetzner IPv6 allocation:

```bash
# Internal sandbox IPv6 subnet (ULA — not routable externally)
# fd20::/64 for sandbox VMs (analogous to 172.20.0.0/16)
ip -6 addr add fd20::1/64 dev br-sandbox

# NAT66: translate outbound from sandbox ULA to host's public IPv6
# Requires ip6tables (or nftables with masquerade support)
ip6tables -t nat -A POSTROUTING \
    -s fd20::/64 \
    -o eth0 \
    -j MASQUERADE

# Enable IPv6 forwarding
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.br-sandbox.forwarding=1
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.d/99-sandbox.conf
```

**IPAM for IPv6 (node agent):**

Extend the existing IPAM bitmap allocator to assign a `/128` per VM from the `fd20::/64` pool:

```go
type IPAM struct {
    v4Pool  *bitmap.Allocator  // 172.20.0.0/16
    v6Pool  *bitmap.Allocator  // fd20::/64 (but only hand out /128 per VM)
}

func (a *IPAM) Allocate() (net.IP, net.IP, error) {
    v4, err := a.v4Pool.Next()
    if err != nil { return nil, nil, err }
    v6, err := a.v6Pool.Next()
    if err != nil { return nil, nil, err }
    return v4, v6, nil
}
```

**Guest network configuration:**

The Unikraft guest gets both addresses via the Firecracker network interface configuration. Add the IPv6 address to the `boot_args` passed to the unikernel:

```
# Firecracker boot_args (Unikraft network config):
netdev.ipv4_addr=172.20.1.5 netdev.ipv4_gw=172.20.0.1 netdev.ipv4_mask=16
netdev.ipv6_addr=fd20::5 netdev.ipv6_gw=fd20::1 netdev.ipv6_prefix=64
```

**IPv6 isolation rules (mirror the IPv4 rules):**

```bash
# Block VM-to-VM IPv6 traffic
ip6tables -A FORWARD -i br-sandbox -o br-sandbox -j DROP

# Block sandbox → host metadata (IPv6 link-local range used by cloud providers)
ip6tables -A FORWARD -i br-sandbox -d fe80::/10 -j DROP

# Block sandbox → internal infrastructure on IPv6
ip6tables -A FORWARD -i br-sandbox -d fc00::/7 ! -s fd20::/64 -j DROP

# Allow outbound IPv6 to internet
ip6tables -A FORWARD -i br-sandbox -o eth0 -j ACCEPT
ip6tables -A FORWARD -i eth0 -o br-sandbox -m state --state RELATED,ESTABLISHED -j ACCEPT
```

**Caveats:**
- NAT66 is controversial (breaks IPv6's end-to-end principle) but is the pragmatic choice here since sandbox VMs should not be directly reachable from the internet anyway.
- Hetzner's `/64` gives you 2⁶⁴ addresses — far more than you will ever need for sandbox VMs.
- The CPS tracking in §8.3a applies equally to IPv6 traffic — ensure your eBPF program handles both `ETH_P_IP` and `ETH_P_IPV6` in the XDP/TC hooks.

NAT outbound (if sandboxes need internet access):
```bash
iptables -t nat -A POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE
```

### 8.3 Network Policy + Rate Limiting (tc + eBPF)

**Per-VM bandwidth limiting** using tc HTB:

```bash
# Rate limit egress to 50Mbps, burst 100Mbps
tc qdisc add dev tap-${VM_ID} root handle 1: htb default 10
tc class add dev tap-${VM_ID} parent 1: classid 1:10 htb \
    rate 50mbit ceil 100mbit burst 15k

# Rate limit ingress (requires IFB or ingress qdisc)
tc qdisc add dev tap-${VM_ID} handle ffff: ingress
tc filter add dev tap-${VM_ID} parent ffff: matchall \
    action police rate 50mbit burst 1mb drop
```

**eBPF for syscall-level egress filtering** (block sandboxes from calling back to metadata services, internal control plane, etc.):

```c
// XDP program attached to br-sandbox:
// Drop packets destined for 169.254.169.254 (cloud metadata)
// Drop packets destined for 10.0.0.0/8 (internal infrastructure)
// Allow everything else → forward to host NAT
```

### 8.3a Abuse and Egress Control: DDoS + Crypto-Mining Mitigation

> **⚠ Gap in original design**: Raw bandwidth limiting via `tc HTB` is necessary but not sufficient. Because sandboxes boot in 30ms, a bad actor can spawn hundreds of sandboxes and generate outbound DDoS traffic or crypto-mining connections faster than bandwidth aggregation metrics can surface the problem. By the time a `rate_bytes_per_second` alert fires, the outbound SYN flood has already run for multiple monitoring intervals.

**The attack surface:**
- **Outbound DDoS**: A script that opens 10,000 UDP sockets to a target IP. Bandwidth per VM is capped, but 100 VMs × 50Mbps = 5Gbps aggregate — enough to saturate the Hetzner uplink and get the entire server null-routed.
- **Crypto-mining**: Connects to a mining pool (a few specific IPs on port 3333/14444), trickles out low-bandwidth but long-lived connections. Stays below bandwidth thresholds indefinitely.
- **Port scanning / recon**: Thousands of SYN packets to a broad IP range. High CPS, low bytes.

All three are invisible to a pure bandwidth limiter. The key metric to track is **connections per second (CPS)** and **distinct destination IPs per time window**, not bytes.

**Fix: eBPF connection tracker (attach to `br-sandbox` TC ingress/egress):**

```c
// SPDX-License-Identifier: GPL-2.0
// tc eBPF program — attach to br-sandbox egress
// Tracks CPS per source IP (= per VM) using a sliding window

struct conn_counter {
    __u64 window_start_ns;
    __u32 conns_in_window;
    __u32 distinct_dst_ips;   // approximate via HyperLogLog or fixed-size set
};

// Map: guest_ip → conn_counter
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4096);
    __type(key, __u32);       // guest IPv4
    __type(value, struct conn_counter);
} conn_track SEC(".maps");

// Limits (tunable via BPF map updates without reloading program)
#define MAX_CPS_PER_VM       200   // connections/second per sandbox
#define MAX_DISTINCT_DST     50    // unique destination IPs per 10s window
#define WINDOW_NS            1000000000ULL  // 1 second

SEC("tc")
int egress_filter(struct __sk_buff *skb) {
    // ... parse IP header, extract src_ip, dst_ip, protocol
    // On TCP SYN or UDP new flow:
    //   1. Look up conn_counter for src_ip
    //   2. If outside current window: reset counter
    //   3. Increment conns_in_window
    //   4. Add dst_ip to distinct set (cuckoo filter or fixed array)
    //   5. If conns_in_window > MAX_CPS_PER_VM → TC_ACT_SHOT + event to userspace
    //   6. If distinct_dst > MAX_DISTINCT_DST → TC_ACT_SHOT + event to userspace
    return TC_ACT_OK;
}
```

**Wiring into the node agent:**

```go
// Node agent subscribes to the eBPF perf event ring buffer.
// When a VM trips the CPS or distinct-dst threshold:

func (a *NodeAgent) OnAbuseDetected(vmID string, reason AbuseReason) {
    log.Warn().Str("vm_id", vmID).Str("reason", string(reason)).Msg("abuse detected")
    
    // 1. Immediately isolate: drop all outbound traffic from this VM
    a.netMgr.IsolateVM(vmID)  // iptables -I FORWARD -i tap-{vmid} -j DROP
    
    // 2. Notify control plane (async — don't block)
    go a.reportAbuse(vmID, reason)
    
    // 3. Terminate the VM
    a.TeardownVM(vmID)
    
    // 4. Flag the API key / tenant for review
    // Control plane marks the tenant as SUSPENDED pending review
}
```

**Per-VM connection limits using `nftables` as a secondary hard cap:**

```bash
# At VM creation time: add nftables rule limiting new connections from this VM's IP
nft add rule ip sandbox-filter forward \
    ip saddr ${VM_IP} ct state new \
    limit rate over 200/second burst 400 packets \
    counter drop
    
# Also limit distinct destination IPs using nftables sets with timeouts:
nft add set ip sandbox-filter dsts-${VM_ID} \
    { type ipv4_addr; flags dynamic,timeout; timeout 10s; size 64; }
nft add rule ip sandbox-filter forward \
    ip saddr ${VM_IP} \
    update @dsts-${VM_ID} { ip daddr } \
    @dsts-${VM_ID} ge 50 elements drop
```

**Mining-specific: blocklist known pool ports and ASNs:**

```bash
# Block outbound connections to known mining pool ports
nft add rule ip sandbox-filter forward \
    ip saddr ${SANDBOX_SUBNET} \
    tcp dport { 3333, 14444, 45560, 8333, 9999 } \
    drop

# Optional: integrate with threat intel feed (e.g. abuse.ch) to block
# known mining pool IPs via a periodically-updated nftables set
```

The combination of eBPF CPS tracking + nftables distinct-IP set + port blocklist covers all three attack classes and responds within the **same kernel packet processing cycle** — no userspace round-trip, no monitoring interval delay.

### 8.4 Guest-to-Host Communication: virtio-vsock

For code injection and result streaming, use virtio-vsock (AF_VSOCK). This avoids using the network stack entirely — it's a direct memory channel between guest and host:

```
Host side:
  VSOCK CID 2 (host)
  Listen on vsock port 1024

Guest side (guest agent inside unikernel):
  Connect to CID 2, port 1024
  Protocol: length-prefixed JSON frames

  Frame: [4-byte LE length][JSON payload]
  
  Host→Guest: {"type":"exec","code":"print(1+1)","env":{},"timeout_ms":5000}
  Guest→Host: {"type":"stdout","data":"2\n"}
  Guest→Host: {"type":"exit","code":0,"cpu_ns":1234567,"mem_bytes":8192000}
```

The vsock channel bypasses all iptables/nftables rules — it can't be affected by network policy. The guest agent runs as PID 1 inside the unikernel (it's the first binary the ELF loader executes; it then exec's the user code as a child process).

---

## 9. Lifecycle: Boot, Run, Teardown

### 9.1 Full Timeline (happy path, cold start with warm pool)

```
t=0ms     API server receives POST /v1/sandbox/run
t=1ms     Auth validated, scheduler called
t=2ms     Scheduler picks node, sends gRPC to node agent
t=3ms     Node agent picks a pre-warmed clone from warm pool
          (A pre-warmed clone is a paused VM already restored from snapshot,
           sitting idle, waiting to be assigned work)
t=5ms     TAP device and IP already allocated (done during warm-up)
t=6ms     Entropy injected via vsock
t=8ms     User code sent via vsock
t=10ms    VM resumed (PATCH /vm {"state":"Resumed"})
t=30ms    Python executes, stdout arrives
t=35ms    Result returned via gRPC to API server
t=36ms    HTTP response sent to client
t=37ms    VM teardown begins (async, doesn't block response)
t=38ms    Warm pool replenished: node agent launches new clone
```

**End-to-end latency: ~35ms** for a trivial `print(1+1)`. Real code adds execution time.

### 9.2 Cold Start Path (warm pool exhausted)

```
t=0ms     API server receives request, warm pool empty
t=2ms     Scheduler sends to node agent
t=5ms     Jailer+Firecracker process spawned
t=20ms    Snapshot loaded (mmap MAP_PRIVATE)
t=23ms    TAP device created, IP allocated
t=25ms    Firecracker resumed from snapshot
t=30ms    Guest agent connects via vsock
t=33ms    Entropy injected
t=35ms    Code sent
t=55ms    Execution result received
t=56ms    Response to client

End-to-end: ~56ms.
```

### 9.3 Teardown Protocol

```go
func (a *NodeAgent) TeardownVM(vmID string) {
    vm := a.vmRegistry.Get(vmID)
    
    // 1. Send graceful shutdown to guest agent
    a.vsock.Send(vmID, ShutdownMsg{})
    waitWithTimeout(vm.vsock, 500*time.Millisecond)
    
    // 2. Send Ctrl+Alt+Del via Firecracker API (graceful guest shutdown)
    a.fcAPI.SendCtrlAltDel(vmID)
    waitWithTimeout(vm.pid, 1*time.Second)
    
    // 3. Force-kill if still alive
    if vm.IsRunning() {
        syscall.Kill(vm.pid, syscall.SIGKILL)
    }
    
    // 4. Clean up TAP device
    a.netMgr.Release(vm.tapID)
    
    // 5. Clean up cgroup (force-kill any stragglers)
    cgroupKillAll(vm.cgroupPath)
    os.RemoveAll(vm.cgroupPath)
    
    // 6. Clean up tmpfs runtime directory
    os.RemoveAll(filepath.Join("/var/run/firecracker", vmID))
    
    // 7. Release IP
    a.ipam.Release(vm.guestIP)
    
    // 8. Decrement resource counters
    a.resources.Release(vm.vcpus, vm.memMiB)
    
    // 9. Replenish warm pool (async)
    go a.warmPool.Replenish(vm.runtime)
}
```

---

## 10. Scale-to-Zero + Warm Pool Strategy

### 10.1 Warm Pool Design

The warm pool is the key mechanism for sub-50ms P99 latency. Each node agent maintains a pool of pre-warmed (restored but paused) VMs per runtime:

```go
type WarmPool struct {
    mu       sync.Mutex
    queues   map[RuntimeType]chan *WarmVM   // per-runtime queues
    config   WarmPoolConfig
}

type WarmPoolConfig struct {
    MinWarm       int           // minimum pre-warmed VMs per runtime (default: 2)
    MaxWarm       int           // maximum pre-warmed VMs (default: 10)
    RefillBelow   int           // refill when pool falls below this (default: 3)
    MaxIdleTime   time.Duration // evict idle warm VMs after this (default: 5m)
    ScaleUpBatch  int           // how many to pre-warm at once on load spike
}
```

**Warm pool lifecycle**:
1. On node agent startup: pre-warm `MinWarm` VMs per enabled runtime.
2. When a sandbox is served: pop from the warm pool queue.
3. After teardown: push a new warm VM back (1:1 replacement).
4. On traffic spike: if pool depth < `RefillBelow`, pre-warm `ScaleUpBatch` more.
5. On traffic drop: if pool depth > `MaxWarm`, evict the oldest (FIFO).

### 10.2 Scale-to-Zero

For the overall system (not per-node), scale-to-zero means: if a node has had zero sandbox requests for N minutes, it should release resources. Since we're on bare metal (not VMs), "scaling down" a node means:
1. Draining: control plane marks node as `DRAINING`, stops sending new requests.
2. The node agent teardowns its warm pool, completing any in-flight VMs.
3. The node is marked `IDLE` and its host can be put in a low-power state or reassigned.
4. On first request after idle: the control plane triggers `WAKE` on the node (the node agent is still running; it just spins up its warm pool on demand).

**Warm pool scale-to-zero**: warm VMs that have been idle longer than `MaxIdleTime` (5 minutes) are evicted:
```go
func (p *WarmPool) EvictionLoop() {
    for range time.Tick(30 * time.Second) {
        for runtime, queue := range p.queues {
            for len(queue) > p.config.MinWarm {
                oldest := peek(queue)
                if time.Since(oldest.CreatedAt) > p.config.MaxIdleTime {
                    vm := pop(queue)
                    vm.Destroy()
                } else {
                    break  // queue is FIFO, rest are newer
                }
            }
        }
    }
}
```

### 10.3 Predictive Pre-warming

Use request history to pre-warm more aggressively before anticipated load spikes:

```go
// Simple exponential moving average of request rate per runtime
// If rate is increasing, pre-warm ahead of demand
type LoadPredictor struct {
    emaRate     map[RuntimeType]float64
    lastRequests map[RuntimeType]int64
}

func (lp *LoadPredictor) SuggestedWarmCount(rt RuntimeType) int {
    rate := lp.emaRate[rt]  // requests/second
    // Assume ~50ms to serve from warm pool + ~50ms restore latency
    // We want zero cold starts → pre-warm = rate × restore_latency
    desiredWarm := int(math.Ceil(rate * 0.05))  // 50ms in seconds
    return max(desiredWarm, MinWarm)
}
```

---

## 11. Scheduler Design

### 11.1 Scheduling Algorithm: Bin-Packing with Warm Pool Awareness

The scheduler does NOT just find the node with the lowest CPU. It optimizes for **lowest cold-start probability**. Concretely:

```go
func (s *Scheduler) Schedule(req *SandboxRequest) (nodeID string, err error) {
    nodes := s.registry.ListHealthy()
    
    // Score each node
    type candidate struct {
        node  *Node
        score float64
    }
    
    var candidates []candidate
    for _, n := range nodes {
        if !n.CanAccept(req) { continue }  // insufficient CPU/RAM
        
        score := 0.0
        
        // Strongly prefer nodes with warm pool for this runtime
        warmCount := n.WarmPoolSize(req.Runtime)
        score += float64(warmCount) * 100.0
        
        // Prefer nodes with headroom (not overloaded)
        cpuFree := n.CPUFree()
        memFree := n.MemFreeMiB()
        score += (cpuFree / n.CPUTotal()) * 30.0
        score += (float64(memFree) / float64(n.MemTotalMiB())) * 20.0
        
        // Penalize nodes with too many active VMs (hot nodes)
        if n.ActiveVMs() > n.OptimalLoad() {
            score -= 50.0
        }
        
        // Prefer same-datacenter node for network affinity (if multi-DC)
        if n.DatacenterID == req.PreferredDC {
            score += 10.0
        }
        
        candidates = append(candidates, candidate{n, score})
    }
    
    sort.Slice(candidates, func(i, j int) bool {
        return candidates[i].score > candidates[j].score
    })
    
    if len(candidates) == 0 {
        return "", ErrNoCapacity
    }
    
    return candidates[0].node.ID, nil
}
```

### 11.2 Node Health and State

Nodes report health to the control plane every **2 seconds** via gRPC streaming (not polling):

```proto
service NodeRegistry {
  rpc Heartbeat(stream NodeStats) returns (stream ControlMsg);
}

message NodeStats {
  string node_id = 1;
  int64 cpu_idle_percent = 2;
  int64 mem_free_mib = 3;
  map<string, int32> warm_pool_sizes = 4;  // runtime → count
  int32 active_vms = 5;
  repeated VMMetric vm_metrics = 6;
  int64 timestamp_ns = 7;
}
```

A node is marked `UNHEALTHY` if no heartbeat for 10 seconds. The scheduler stops routing to it. The node agent on the host attempts self-healing.

### 11.3 Overload Shedding

```go
// Node agent: refuse new VMs if resources are insufficient
func (a *NodeAgent) CanAccept(req *SandboxRequest) bool {
    available := a.resources.Available()
    return available.CPUs >= req.VCPUs &&
           available.MemMiB >= req.MemoryMiB &&
           a.activeVMs.Load() < MaxVMsPerNode
}
```

Control plane: if ALL nodes are full, return HTTP 503 with `Retry-After` header. The client SDK handles backoff and retry automatically.

---

## 12. Node Agent Design

### 12.1 Architecture

The node agent is a single Go binary running as a systemd service on each bare metal host. It manages the full lifecycle of VMs on that host.

```go
type NodeAgent struct {
    config      Config
    fcMgr       *FirecrackerManager    // manages FC processes
    netMgr      *NetworkManager        // TAP devices, IPAM
    snapMgr     *SnapshotManager       // loads/creates snapshots
    warmPool    *WarmPool              // pre-warmed VM pool
    vmRegistry  *VMRegistry            // active VMs state
    resources   *ResourceTracker       // CPU/mem accounting
    vsockMgr    *VsockManager          // host-side vsock server
    grpcServer  *grpc.Server           // control plane communication
    metrics     *prometheus.Registry   // per-node metrics
}
```

### 12.2 VM Execution Protocol (vsock)

The guest agent (runs inside the unikernel) and the node agent communicate over vsock:

```
Node Agent (host)           Guest Agent (inside VM)
     │                              │
     │──HELLO──────────────────────▶│  connection established
     │◀─READY──────────────────────│  guest agent ready
     │                              │
     │──ENTROPY {64 bytes}─────────▶│  re-seed CSPRNG
     │◀─OK─────────────────────────│
     │                              │
     │──EXEC {code, env, timeout}──▶│  dispatch execution
     │◀─STDOUT {data}──────────────│  streaming stdout
     │◀─STDOUT {data}──────────────│
     │◀─STDERR {data}──────────────│
     │◀─EXIT {code, cpu_ns, mem}───│  execution complete
     │                              │
     │──SHUTDOWN───────────────────▶│  teardown
     │◀─BYE────────────────────────│
     │                              │  [VM halts]
```

### 12.3 Resource Accounting

Each VM is tracked with real-time metrics:

```go
type VMMetrics struct {
    VMID        string
    CPUTimeNs   atomic.Int64  // from /sys/fs/cgroup/sandbox/{vmid}/cpu.stat
    MemBytes    atomic.Int64  // from /sys/fs/cgroup/sandbox/{vmid}/memory.current
    DirtyPages  atomic.Int64  // from KVM dirty page tracking
    NetTxBytes  atomic.Int64  // from netlink stats on TAP device
    NetRxBytes  atomic.Int64  // from netlink stats on TAP device
    WallTime    time.Duration
}
```

**CPU throttling**: if a VM exceeds its allocated CPU time by >20% over a 1s window, apply cgroup CPU throttle:
```bash
echo "100000 500000" > /sys/fs/cgroup/sandbox/${VM_ID}/cpu.max
# 100ms quota per 500ms period = 20% of one CPU
```

**Memory hard limit**: set in cgroup at VM creation:
```bash
echo $((req.MemoryMiB * 1024 * 1024)) > /sys/fs/cgroup/sandbox/${VM_ID}/memory.max
```

If the VM hits the memory limit, it gets OOM-killed by the kernel. The node agent detects this via the cgroup events file and reports `OOMKilled` in the sandbox result.

---

## 13. Storage + Snapshot Registry

### 13.1 Snapshot Storage Layout

```
/var/lib/snapshots/
├── templates/
│   ├── python311/
│   │   ├── v1.vmstate           (4KB, CPU state)
│   │   ├── v1.mem               (180MB, guest memory)
│   │   └── metadata.json        {runtime, version, packages_hash, created_at}
│   ├── node20/
│   │   ├── v1.vmstate
│   │   └── v1.mem
│   └── python311-numpy/         (custom snapshot with numpy pre-imported)
│       ├── v1.vmstate
│       └── v1.mem
│
└── running/
    └── {vm_id}/
        ├── checkpoint-1700000000.vmstate   (diff snapshot)
        └── checkpoint-1700000000.diff      (dirty pages only)
```

### 13.2 Snapshot Integrity

Each snapshot file has a corresponding SHA-256 checksum:
```
v1.mem.sha256
v1.vmstate.sha256
```

The node agent verifies checksums before loading a snapshot. If corrupted: rebuild from the ELF loader + base rootfs (one-time 600ms cost).

### 13.3 Snapshot Distribution (Multi-Node)

If you have multiple bare metal hosts, snapshots need to be on every host. Options:

**Option A: NFS mount** — `/var/lib/snapshots` is an NFS export from a dedicated storage node. Simple but adds ~5ms to snapshot load latency (NFS page cache cold miss). For MAP_PRIVATE mmap, the memory file is read entirely into page cache on first load per node — subsequent clones on the same node are instant (already in page cache).

**Option B: rsync on update** — snapshot builder pushes to each node via rsync when a new template is built. Nodes store snapshots locally. No network latency on the hot path.

**Option C: Object storage (S3-compatible)** — snapshots stored in MinIO/Ceph. Node agent downloads and caches locally on first use. Cache invalidation via etag/version check. Best for many nodes + infrequent snapshot updates.

Recommendation: Option B for up to ~5 nodes, Option C for more.

---

## 14. Security Model

### 14.1 Defense in Depth

```
Layer 0: Network — sandboxes cannot reach the internal control plane,
         cloud metadata service (169.254.169.254), or other VMs' IPs.
         Enforced by iptables + eBPF XDP.

Layer 1: KVM hardware boundary — the VM cannot escape to the host kernel
         without a KVM hypervisor vulnerability. The VM runs in ring 0
         within its own virtual address space. Host ring 0 is inaccessible.

Layer 2: Firecracker minimal device model — only 4 virtual devices.
         No DMA, no IOMMU attacks, no complex device drivers that could
         be exploited (contrast with QEMU's 200+ device emulators).

Layer 3: Jailer chroot + seccomp-bpf — even if Firecracker is compromised,
         the attacker is inside a chroot with ~50 allowed syscalls.
         No `fork`, no `exec`, no `open` outside the chroot.

Layer 4: Cgroups v2 resource limits — a runaway VM cannot consume
         all host memory or CPU.

Layer 5: Unikraft unikernel — single address space, no user/kernel boundary,
         no setuid binaries, no login shell, no SSH daemon.
         Attack surface is the syscall shim (160 syscalls vs Linux's 350+).

Layer 6: Guest agent PID 1 — the guest agent is the only process running
         with access to the vsock. User code is exec'd as an unprivileged
         child process inside the unikernel.
```

### 14.2 Network Isolation Rules

```bash
# Isolation chain: drop all VM-to-VM traffic
iptables -A FORWARD -i br-sandbox -o br-sandbox -j DROP

# Allow VM → internet (outbound)
iptables -A FORWARD -i br-sandbox -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o br-sandbox -m state --state RELATED,ESTABLISHED -j ACCEPT

# Block VM → metadata service
iptables -A FORWARD -i br-sandbox -d 169.254.169.254 -j DROP

# Block VM → internal infrastructure (10.x, 172.16-31.x)
iptables -A FORWARD -i br-sandbox -d 10.0.0.0/8 -j DROP
iptables -A FORWARD -i br-sandbox -d 172.16.0.0/12 -j DROP
```

### 14.3 Snapshot Uniqueness (Avoid Secret Leakage)

Before taking a template snapshot, wipe sensitive memory:
- `/dev/urandom` entropy pool: use `MADV_WIPEONSUSPEND` on the pool pages so they're zeroed in the snapshot.
- Any pre-loaded TLS certificates or keys: purge before snapshot.
- After clone, inject fresh entropy as described in §5.4.

---

## 15. Observability Stack

### 15.1 Metrics (Prometheus)

```
sandbox_requests_total{runtime, status}          counter
sandbox_duration_seconds{runtime, percentile}    histogram (P50, P95, P99)
sandbox_cold_starts_total{runtime}               counter
sandbox_warm_starts_total{runtime}               counter
sandbox_oom_kills_total{runtime}                 counter
sandbox_timeout_total{runtime}                   counter

vm_boot_duration_seconds{type}                   histogram (type: cold|warm)
vm_active_count{runtime, node}                   gauge
vm_warm_pool_size{runtime, node}                 gauge

node_cpu_available{node}                         gauge
node_mem_available_mib{node}                     gauge
snapshot_load_duration_seconds{runtime}          histogram
snapshot_dirty_pages{vm_id}                      gauge

fc_api_latency_seconds{endpoint}                 histogram
vsock_message_latency_seconds{type}              histogram
```

### 15.2 Structured Logging (Go + zerolog)

```json
{
  "level": "info",
  "time": "2026-04-11T12:00:00.123Z",
  "component": "node_agent",
  "event": "sandbox_complete",
  "vm_id": "vm-abc123",
  "sandbox_id": "sb-xyz789",
  "runtime": "python311",
  "boot_type": "warm",
  "boot_ms": 23,
  "exec_ms": 47,
  "total_ms": 70,
  "exit_code": 0,
  "cpu_ns": 1234567,
  "mem_peak_bytes": 12582912,
  "node": "htz-bm-01"
}
```

### 15.3 Tracing (OpenTelemetry)

Trace spans across the full path:
```
[api_handler] → [scheduler.schedule] → [node_agent.run_sandbox]
                                              ├─ [warm_pool.acquire]
                                              ├─ [fc.resume]
                                              ├─ [vsock.exec]
                                              └─ [vm.teardown]
```

Export to Jaeger or Tempo for latency analysis.

---

## 16. Hetzner Bare Metal Setup

### 16.1 Recommended Server

**Hetzner AX102** (AMD EPYC 9454P):
- 48 cores / 96 threads
- 192GB DDR5 ECC RAM
- 2× 1.92TB NVMe SSD (RAID-1 mirrored via mdadm — see §2.4a)
- 25GbE network
- ~€350/month

**Capacity estimate per AX102**:
- Each sandbox: 1 vCPU + 256MB RAM (minimum)
- 96 hyperthreads → ~80 usable (reserve 16 for host)
- 192GB RAM → ~170GB usable
- Concurrent sandboxes: min(80, 170×1024/256) = min(80, 680) = **80 concurrent**
- But with CoW memory dedup: 200MB snapshot × 80 VMs ≈ 200MB shared + 80×dirty → actual: ~20-40GB for 80 VMs
- With CoW: potentially **200+ concurrent** depending on per-VM dirty footprint

### 16.2 Provisioning Script (key steps)

```bash
# 1. Install Debian 12 via Hetzner installimage
# 2. Enable KVM
apt install -y qemu-kvm libvirt-daemon linux-headers-$(uname -r)
modprobe kvm_amd  # or kvm_intel
echo 'kvm_amd' >> /etc/modules

# 3. Install Firecracker
FIRECRACKER_VERSION=1.8.0
wget https://github.com/firecracker-microvm/firecracker/releases/download/\
v${FIRECRACKER_VERSION}/firecracker-v${FIRECRACKER_VERSION}-x86_64.tgz
tar xf firecracker-*.tgz
cp release-*/firecracker-v*-x86_64 /usr/bin/firecracker
cp release-*/jailer-v*-x86_64 /usr/bin/jailer

# 4. Set up RAID-1 for snapshot storage
mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/nvme0n1 /dev/nvme1n1
mkfs.ext4 -F /dev/md0
mkdir -p /var/lib/snapshots
echo '/dev/md0 /var/lib/snapshots ext4 defaults 0 2' >> /etc/fstab
mount /var/lib/snapshots
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u

# 5. Set up bridge (IPv4 + IPv6)
cat > /etc/network/interfaces.d/br-sandbox << 'EOF'
auto br-sandbox
iface br-sandbox inet static
    address 172.20.0.1/16
    bridge_ports none
    bridge_stp off
    bridge_fd 0

iface br-sandbox inet6 static
    address fd20::1/64
EOF

# 5. Enable IP forwarding + NAT (IPv4 + IPv6)
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-sandbox.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.d/99-sandbox.conf
sysctl --system
iptables  -t nat -A POSTROUTING -s 172.20.0.0/16 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s fd20::/64 -o eth0 -j MASQUERADE
apt install -y iptables-persistent && netfilter-persistent save

# 6. Set up /var/run/firecracker as tmpfs
echo 'tmpfs /var/run/firecracker tmpfs rw,nosuid,noexec,size=2G 0 0' >> /etc/fstab
mount /var/run/firecracker

# 7. Install node agent binary (built from your repo)
cp node-agent /usr/bin/sandbox-node-agent
cp sandbox-node.service /etc/systemd/system/
systemctl enable --now sandbox-node-agent
```

---

## 17. Implementation Sequence

### Phase 0 — Foundation (Week 1-2)
- [ ] Hetzner bare metal provisioned, Debian 12 installed, kernel tuned
- [ ] Firecracker installed, jailer configured
- [ ] Basic Firecracker microVM boots with Unikraft kernel + CPIO initrd manually
- [ ] Python/Node executes correctly inside the unikernel
- [ ] Guest agent prototype (Go) communicating over vsock

### Phase 1 — Snapshot Engine (Week 3-4)
- [ ] Template snapshot pipeline (boot → pause → snapshot)
- [ ] Clone launch from snapshot (MAP_PRIVATE)
- [ ] CoW validation (confirm original snapshot unchanged after clone writes)
- [ ] Entropy injection protocol
- [ ] Benchmark: measure P50/P99 clone restore latency

### Phase 2 — Node Agent (Week 5-6)
- [ ] Node agent with VM lifecycle management
- [ ] TAP device management + IPAM
- [ ] Warm pool implementation
- [ ] Resource tracking (cgroup CPU, memory)
- [ ] Per-VM network policy (iptables/ip6tables, tc rate limiting)
- [ ] eBPF CPS tracker + distinct-IP abuse detection (§8.3a)
- [ ] IPv6 bridge config + NAT66 (§8.2a)

### Phase 3 — Control Plane (Week 7-9)
- [ ] gRPC protocol definitions (scheduler ↔ node agent)
- [ ] Scheduler with bin-packing + warm pool awareness
- [ ] Node registry + heartbeat
- [ ] State store (Redis or etcd)
- [ ] REST API server (sync run, async create, SSE stream)

### Phase 4 — Package Overlay (Week 10)
- [ ] Overlay CPIO generation pipeline
- [ ] Content-addressed cache (hash of package list)
- [ ] Integration with sandbox request flow

### Phase 5 — Observability + Hardening (Week 11-12)
- [ ] Prometheus metrics endpoints
- [ ] Structured logging (zerolog)
- [ ] OpenTelemetry tracing
- [ ] Network isolation rules (iptables + ip6tables, eBPF CPS tracking)
- [ ] Load testing (target: 100 concurrent sandboxes, P99 <100ms cold start)

### Phase 6 — Multi-Node + HA (Week 13-14)
- [ ] Second bare metal node
- [ ] Snapshot distribution (rsync or object storage)
- [ ] Control plane HA (two API server instances, Redis Sentinel or etcd cluster)
- [ ] Node failure handling + workload redistribution

---

## 18. Key Numbers + SLAs

| Metric | Target | Notes |
|--------|--------|-------|
| Warm start latency (P50) | 30ms | Restore snapshot + exec |
| Warm start latency (P99) | 80ms | Includes scheduling overhead |
| Cold start latency (P50) | 60ms | Firecracker spawn + snapshot load |
| Cold start latency (P99) | 150ms | Under heavy load |
| Template snapshot build | <1s | One-time per runtime version |
| Concurrent VMs per AX102 | 80-200 | Depends on dirty page footprint |
| Memory overhead per VM | ~5MB | Firecracker process overhead |
| Snapshot load (200MB) | ~15ms | Via mmap MAP_PRIVATE |
| VM teardown time | <100ms | Kill + cleanup |
| Warm pool refill | <100ms | Async, doesn't block response |
| Max execution timeout | 300s | Configurable per tenant |
| Network throughput per VM | 50Mbps | tc HTB rate limit |
| Snapshot CoW dedup ratio | ~10x | For identical-runtime VMs |

---

*Architecture version 1.0 — April 2026*
*Designed for Unikraft bincompat + Firecracker + Hetzner bare metal*
