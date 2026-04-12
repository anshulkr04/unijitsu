# Jitsu + Unikraft Hybrid Architecture — Deep Technical Roadmap

> **Goal:** Combine Jitsu's battle-tested wake/sleep orchestration with Unikraft's
> flexible, multi-language, modular unikernel toolkit to build a Vercel-like
> "Unikernel-as-a-Service" platform for AI agents on bare metal.

---

## Part 1 — Understanding The Two Systems

### 1A. Jitsu: The Orchestrator (Wake/Sleep Brain)

Jitsu is a **DNS-triggered lifecycle manager** for unikernels. It does NOT build or run
unikernels itself — it tells a hypervisor (Xen) when to boot/stop them.

**Core lifecycle loop (from `jitsu.ml` + `main.ml`):**

```
DNS query arrives
    │
    ├─ jitsu.ml:process()  — matches domain → VM UUID in Irmin DB
    │
    ├─ jitsu.ml:start_vm() — checks VM state via backend
    │   ├─ Off       → backend.start_vm()    (cold boot)
    │   ├─ Suspended → backend.resume_vm()   (warm resume)
    │   ├─ Paused    → backend.unpause_vm()
    │   └─ Running   → no-op
    │
    ├─ Waits for readiness (Xenstore key or sleep delay)
    │
    ├─ synjitsu.ml — sends GARP + caches SYN packets during boot
    │
    └─ Returns DNS A record with unikernel IP

Maintenance thread (every 5s):
    │
    └─ jitsu.ml:stop_expired_vms()
        ├─ For each VM where last_dns_request > TTL*2
        │   ├─ Destroy mode  → backend.destroy_vm()
        │   ├─ Suspend mode  → backend.suspend_vm()  (preserves memory)
        │   └─ Shutdown mode → backend.shutdown_vm()  (graceful)
        └─ VM goes back to Off/Suspended → zero resource consumption
```

**What Jitsu gives us:**
- Proven scale-to-zero pattern with configurable stop modes
- DNS-based service discovery (every request = heartbeat)
- Synjitsu for zero-downtime cold boots (TCP SYN caching + gratuitous ARP)
- Irmin (Git-based) state store for VM configs, stats, TTLs
- Pluggable backend interface (`backends.mli`) — we can write a Unikraft backend

**What Jitsu lacks:**
- Only works with MirageOS/Rumprun unikernels (OCaml ecosystem)
- No support for general-purpose languages (Python, Go, Node.js, Rust)
- DNS-only triggering (no HTTP-level request proxying)
- No multi-host / clustering
- No image build pipeline

---

### 1B. Unikraft: The Unikernel Builder (Flexible Runtime)

Unikraft is a **modular unikernel construction kit** — a library OS where you
pick exactly the components your application needs and compile them into a
single-purpose VM image.

**Architecture from the source tree:**

```
┌─────────────────────────────────────────────────────────────────┐
│                        APPLICATION                              │
│  (C, C++, Rust, Go, Python, Node.js — via POSIX compat layer)  │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│                    LIBRARY LAYER (lib/)                          │
│                                                                 │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐ ┌──────────────────┐  │
│  │ ukboot   │ │ uksched  │ │ uknetdev  │ │ posix-socket     │  │
│  │(boot seq)│ │(schedule)│ │(net abs.) │ │ posix-process    │  │
│  └──────────┘ └──────────┘ └───────────┘ │ posix-fd/vfs/... │  │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐ └──────────────────┘  │
│  │ ukalloc  │ │ ukpm     │ │ ukblkdev  │ ┌──────────────────┐  │
│  │(memory)  │ │(power mg)│ │(block I/O)│ │ nolibc / vfscore │  │
│  └──────────┘ └──────────┘ └───────────┘ └──────────────────┘  │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐                       │
│  │ ukstore  │ │ ukpod    │ │ syscall   │                       │
│  │(kv conf) │ │(paging)  │ │ _shim    │                       │
│  └──────────┘ └──────────┘ └───────────┘                       │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│                   DRIVER LAYER (drivers/)                        │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │ virtio/          │  │ xen/             │                     │
│  │  net, blk, 9p,   │  │  netfront,       │                     │
│  │  fs, pci, mmio   │  │  blkfront,       │                     │
│  │                  │  │  xenbus, console  │                     │
│  └──────────────────┘  └──────────────────┘                     │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│                  PLATFORM LAYER (plat/)                          │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐                        │
│  │   xen/  │  │  kvm/   │  │ native/  │                        │
│  │ PV,PVH  │  │ QEMU,   │  │ (Linux   │                        │
│  │ hyper-  │  │ Fire-   │  │  process) │                        │
│  │ calls,  │  │ cracker │  │          │                        │
│  │ events  │  │ EFI     │  │          │                        │
│  └─────────┘  └─────────┘  └──────────┘                        │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│              ARCHITECTURE LAYER (arch/)                          │
│          x86_64  │  arm64  │  arm  │  (risc-v soon)             │
└─────────────────────────────────────────────────────────────────┘
```

**Unikraft's boot sequence (from `lib/ukboot/boot.c` + `early_init.c`):**

```
Platform entry (plat/xen/x86/setup.c or plat/kvm/x86/setup.c)
  │
  ├── Hardware setup (segments, traps, shared_info, event channels)
  ├── Build ukplat_bootinfo (memory map, cmdline, initrd)
  ├── uk_boot_early_init(bi)
  │     ├── Parse command line
  │     ├── Register PM ops (xen_pm_ops or qemu_pm_ops)
  │     └── Coalesce memory regions
  │
  └── uk_boot_entry()                    ← THE MAIN BOOTSTRAP
        ├── Run constructor table (uk_ctortab)
        ├── heap_init() — buddy allocator from free memory regions
        ├── Stack allocator init
        ├── TLS setup
        ├── Interrupt controller init
        ├── Timer init
        ├── Scheduler init (ukschedcoop — cooperative round-robin)
        ├── Init table (uk_inittab) — VFS, network stack, etc.
        ├── Print banner
        ├── do_main() → application main()
        └── uk_pm_shutdown()
```

**What Unikraft gives us:**
- Multi-language support: C, C++, Rust, Go, Python, Node.js, Java
- Multi-platform: Xen, KVM/QEMU, Firecracker, native Linux process
- Multi-arch: x86_64, arm64 (RISC-V coming)
- Modular: include only what you need (< 2MB images possible)
- POSIX compatibility layer (run existing Linux apps unmodified)
- `kraft` CLI: `kraft run`, `kraft build` — Docker-like workflow
- Kraftfile (like Dockerfile) for declarative unikernel builds
- Boot times in single-digit milliseconds

**What Unikraft lacks (that Jitsu provides):**
- No orchestration layer — no concept of "start VM when request arrives"
- No scale-to-zero lifecycle management
- **No suspend/resume implementation** — `uk_pm_syssuspend()` interface exists
  in `lib/ukpm/pm.c` but neither the Xen nor KVM platform fills in the
  `syssuspend` function pointer. The `xen_pm_ops` struct in
  `plat/xen/shutdown.c` only has `syshalt`, `sysrestart`, `syscrash`.
- No DNS/HTTP-triggered boot
- No request buffering during cold boot (Synjitsu pattern)
- No multi-instance management

---

## Part 2 — The Hybrid Architecture: Why This Combination Is Powerful

### The Key Insight

Jitsu's orchestration brain treats unikernels as opaque VMs. Its `backends.mli`
interface only needs: `start_vm`, `stop_vm`, `suspend_vm`, `resume_vm`,
`destroy_vm`, `get_state`, `get_mac`, `get_domain_id`. It doesn't care what's
inside the unikernel.

Unikraft produces standard Xen PV/PVH guests or KVM/QEMU VMs. These are
interchangeable with MirageOS from the hypervisor's perspective.

**The combination:**

```
┌──────────────────────────────────────────────────────────┐
│                    CONTROL PLANE                          │
│              (always awake, always listening)              │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │   GATEWAY (HTTP reverse proxy)                    │    │
│  │   Receives: agent-x.platform.com/invoke           │    │
│  │   Buffers requests during boot (Synjitsu pattern) │    │
│  └─────────────────────┬────────────────────────────┘    │
│                        │                                  │
│  ┌─────────────────────▼────────────────────────────┐    │
│  │   ORCHESTRATOR (evolved Jitsu)                    │    │
│  │                                                   │    │
│  │   State DB (agent registry, TTLs, stop modes)     │    │
│  │   lifecycle_loop:                                  │    │
│  │     request → check state → boot/resume → proxy   │    │
│  │   maintenance_loop:                                │    │
│  │     sweep agents → stop idle ones → reclaim mem   │    │
│  │                                                   │    │
│  │   Talks to Xen via libxl (same as Jitsu backend)  │    │
│  └─────────────────────┬────────────────────────────┘    │
│                        │                                  │
└────────────────────────┼──────────────────────────────────┘
                         │
┌────────────────────────▼──────────────────────────────────┐
│                     DATA PLANE                             │
│           (Unikraft instances — sleep when idle)           │
│                                                           │
│  ┌─────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐     │
│  │ Agent A │ │ Agent B  │ │ Agent C  │ │    ...   │     │
│  │ Python  │ │ Node.js  │ │  Rust    │ │          │     │
│  │ Flask   │ │ Express  │ │  Axum    │ │          │     │
│  │  +LLM   │ │  +LLM    │ │  +LLM   │ │          │     │
│  │ 8MB img │ │ 12MB img │ │  4MB img │ │          │     │
│  │ SLEEPING│ │ RUNNING  │ │ SLEEPING │ │          │     │
│  └─────────┘ └──────────┘ └──────────┘ └──────────┘     │
│                                                           │
│  Each agent = Unikraft unikernel on Xen                   │
│  Boot time: 1-10ms | Memory: 2-64MB | Full POSIX compat   │
└───────────────────────────────────────────────────────────┘
```

### Why This Is Better Than Either System Alone

| Dimension | Jitsu + MirageOS (original) | Jitsu + Unikraft (hybrid) |
|-----------|-----------------------------|---------------------------|
| Languages | OCaml only | C, C++, Rust, Go, Python, Node.js, Java |
| Existing code | Must rewrite for MirageOS | Run unmodified Linux apps via POSIX shim |
| Build workflow | `mirage configure && make` | `kraft build` with Kraftfile (Dockerfile-like) |
| Image size | 2-10MB | 2-30MB (depends on included libs) |
| Boot time | ~5ms | ~2-10ms |
| Platforms | Xen only | Xen, KVM, Firecracker, native |
| Suspend/resume | Yes (MirageOS + Xen) | Needs implementation (interface exists) |
| Community | Small | Large (Linux Foundation, 100+ contributors) |
| AI agent support | Low (no Python/ML libs) | High (Python, PyTorch, HTTP frameworks) |

---

## Part 3 — Technical Roadmap

### Phase 0: Prove the Boot Loop (Weeks 1-3)

**Goal:** Run a Unikraft unikernel on Xen, managed by Jitsu's libxl backend.

#### 0.1 — Environment Setup

| Task | Details |
|------|---------|
| Bare-metal Xen host | Install Xen 4.17+ as Type-1 hypervisor on a dedicated server. Ubuntu 22.04+ as dom0. |
| Unikraft toolchain | Install `kraft` CLI, GCC cross-compiler, Xen dev headers. |
| OCaml toolchain | `opam`, `ocamlfind`, all Jitsu deps for building Jitsu itself. |

#### 0.2 — Build a Unikraft Xen Image

```bash
# Using kraft CLI
kraft init -t helloworld my-agent
cd my-agent

# Edit Kraftfile to target Xen:
# spec: v0.6
# unikraft: stable
# targets:
#   - platform: xen
#     architecture: x86_64

kraft build --plat xen --arch x86_64
```

This produces a `.xen` binary (e.g., `build/my-agent_xen-x86_64`). This file
format is identical to what Jitsu's libxl backend expects in the `kernel=`
config parameter.

#### 0.3 — Launch via Jitsu

```bash
sudo jitsu -x libxl \
  dns=my-agent.example.com,\
  ip=10.0.0.10,\
  kernel=build/my-agent_xen-x86_64,\
  memory=32000,\
  name=my-agent,\
  nic=br0
```

**Expected result:** DNS query for `my-agent.example.com` → Jitsu boots
the Unikraft unikernel via libxl → returns IP → client connects.

#### 0.4 — Benchmark Baseline

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Cold boot time | < 10ms | `time host my-agent.example.com 127.0.0.1` |
| Memory footprint | < 16MB | `xl list` |
| Image size | < 5MB | `ls -la build/` |
| First HTTP response | < 50ms | Stopwatch from DNS query to HTTP 200 |

**Deliverable:** Unikraft unikernel reliably managed by Jitsu on bare-metal Xen.

---

### Phase 1: Implement Suspend/Resume for Unikraft on Xen (Weeks 3-6)

**Goal:** This is the critical missing piece. Unikraft has the `uk_pm_syssuspend()`
interface but no platform implements it. We need to build it.

#### 1.1 — Understand the Gap

From the Unikraft source:

**`plat/xen/shutdown.c`** — current state:
```c
static const struct uk_pm_ops xen_pm_ops = {
    .syshalt = xen_halt,       // HYPERVISOR_sched_op(SCHEDOP_shutdown, SHUTDOWN_poweroff)
    .sysrestart = xen_restart, // SHUTDOWN_reboot
    .syscrash = xen_crash      // SHUTDOWN_crash
    // .syssuspend = ???       ← MISSING
};
```

**`lib/ukpm/pm.c`** — the suspend path:
```c
int uk_pm_syssuspend(void) {
    uk_raise_event(UK_PM_EVENT_SYSSUSPEND, NULL);  // notify all listeners
    if (!pm_ops || !pm_ops->syssuspend)
        _uk_pm_syshalt_fallback();  // no driver → hangs forever
    return pm_ops->syssuspend();    // returns 0 on resume!
}
```

The suspend function is supposed to **return** after resume. This is how
Xen suspend works: `HYPERVISOR_sched_op(SCHEDOP_shutdown, SHUTDOWN_suspend)`
freezes the VM, dom0 saves its memory to disk, and later restores it. The
hypercall returns as if nothing happened.

#### 1.2 — Implement `xen_suspend()` in Unikraft

The implementation requires these steps (in `plat/xen/`):

```
xen_suspend()
  │
  ├── 1. Raise UK_PM_EVENT_SYSSUSPEND (already done by ukpm)
  │      → Notifies drivers to quiesce (flush buffers, drain queues)
  │
  ├── 2. Disable all event channels
  │      (plat/xen/events.c — unbind all non-essential channels)
  │
  ├── 3. Suspend all Xen frontends
  │      (drivers/xen/netfront, blkfront — disconnect from backends)
  │
  ├── 4. Issue the hypercall:
  │      HYPERVISOR_sched_op(SCHEDOP_shutdown, SHUTDOWN_suspend)
  │      ← VM FROZEN HERE — Dom0 saves memory state →
  │      → RETURNS HERE ON RESUME
  │
  ├── 5. Re-map shared_info page (may have moved)
  │      HYPERVISOR_update_va_mapping(shared_info_page, ...)
  │
  ├── 6. Re-initialize event channels
  │      init_events() — rebind virqs and pirqs
  │
  ├── 7. Re-initialize timer
  │      ukplat_time_init() — Xen wall clock may have changed
  │
  ├── 8. Reconnect Xen frontends
  │      netfront/blkfront — re-negotiate with backends via XenBus
  │
  └── 9. Return 0 (resume successful)
```

#### 1.3 — Wire It Into the PM Ops

In `plat/xen/shutdown.c`:
```c
__isr static int xen_suspend(void)
{
    // steps 2-8 above
    struct sched_shutdown sched_shutdown = { .reason = SHUTDOWN_suspend };

    // pre-suspend: quiesce devices
    xen_pre_suspend();

    // the actual suspend hypercall — blocks until resume
    HYPERVISOR_sched_op(SCHEDOP_shutdown, &sched_shutdown);

    // post-resume: reinitialize
    xen_post_resume();

    return 0;  // means "we resumed successfully"
}

static const struct uk_pm_ops xen_pm_ops = {
    .syshalt = xen_halt,
    .sysrestart = xen_restart,
    .syssuspend = xen_suspend,    // ← NEW
    .syscrash = xen_crash
};
```

#### 1.4 — Test Suspend/Resume

```bash
# From dom0, while the Unikraft unikernel is running:
xl save my-agent /tmp/my-agent.checkpoint

# Later:
xl restore /tmp/my-agent.checkpoint

# Verify the unikernel resumes and responds to requests
```

#### 1.5 — Integrate with Jitsu's Stop Modes

Jitsu already supports `-m suspend`. Once `xen_suspend()` works, Jitsu can:
- Suspend idle Unikraft unikernels (preserving memory state)
- Resume them in ~1ms instead of cold-booting (~5-10ms)
- This is the **warm pool** optimization

**Deliverable:** Unikraft unikernels suspend/resume cleanly on Xen, managed by Jitsu.

---

### Phase 2: Multi-Language Agent Runtime (Weeks 6-10)

**Goal:** Build standardized Unikraft base images for each language, with a
common HTTP server contract for AI agents.

#### 2.1 — Agent Contract

Every agent, regardless of language, must:
```
1. Listen on port 8080 (configurable via env var)
2. Expose POST /invoke — receives JSON input, returns JSON output
3. Expose GET  /health — returns 200 when ready
4. Read config from environment variables (API keys, model params)
5. Exit cleanly on SIGTERM (graceful shutdown for suspend)
```

#### 2.2 — Base Images

Build these Unikraft base images targeting Xen:

| Runtime | Kraftfile Base | Included Libraries | Image Size |
|---------|---------------|-------------------|------------|
| **Python 3.12** | `unikraft.org/python3:latest` | Flask/FastAPI, requests, json | ~15MB |
| **Node.js 20** | `unikraft.org/node:20` | Express, node-fetch | ~18MB |
| **Go 1.22** | `unikraft.org/go:1.22` | net/http (stdlib) | ~8MB |
| **Rust** | `unikraft.org/base:latest` + Rust app | axum, reqwest, serde | ~5MB |
| **C/C++** | `unikraft.org/base:latest` | libcurl, cJSON | ~3MB |

Each base image is a pre-compiled Unikraft kernel with POSIX compat. The
agent code is loaded via:
- **Compiled languages (Rust/Go/C):** Linked into the unikernel at build time
- **Interpreted languages (Python/Node):** Loaded from a 9pfs/virtiofs mount
  or baked into an initrd

#### 2.3 — Build Pipeline

```
Developer writes agent code
    │
    ├── agent.py / index.js / main.go / main.rs
    ├── agent.yaml (manifest: runtime, env vars, memory, timeout)
    │
    ▼
Build Service (kraft build)
    │
    ├── Selects base Unikraft image for runtime
    ├── Compiles or packages agent code
    ├── Produces: agent-image.xen (unikernel binary)
    │             agent-rootfs.img (if interpreted: code + deps)
    │
    ▼
Image Registry (MinIO/S3)
    │
    └── Stores versioned images, addressable by agent UUID
```

#### 2.4 — Agent Manifest

```yaml
# agent.yaml
name: summarizer-agent
runtime: python3.12
entrypoint: agent.py
memory: 32MB
timeout: 300   # seconds before scale-to-zero
env:
  OPENAI_API_KEY: "${secrets.OPENAI_API_KEY}"
  MODEL: "gpt-4"
scaling:
  min: 0       # scale to zero
  max: 10      # max concurrent instances
```

**Deliverable:** AI agents written in Python/Node/Go/Rust deploy as Unikraft
unikernels on Xen.

---

### Phase 3: The New Orchestrator — HTTP-Triggered Lifecycle (Weeks 10-16)

**Goal:** Replace Jitsu's DNS triggering with HTTP, keeping its lifecycle patterns.

#### 3.1 — Architecture

```
                Client: POST agent-x.platform.com/invoke
                              │
                ┌─────────────▼──────────────────────┐
                │       API GATEWAY (Rust/axum)       │
                │                                     │
                │  1. Parse hostname → agent ID        │
                │  2. Check agent state in DB          │
                │  3. If SLEEPING:                     │
                │     a. Queue this request            │
                │     b. Tell orchestrator to WAKE     │
                │     c. Wait for health check pass    │
                │     d. Replay queued request         │
                │  4. If RUNNING:                      │
                │     a. Proxy request directly        │
                │  5. Update last_request_timestamp    │
                │                                      │
                └─────────────┬──────────────────────┘
                              │
                ┌─────────────▼──────────────────────┐
                │     ORCHESTRATOR (Rust/Go)           │
                │                                      │
                │  Evolved from Jitsu's core logic:    │
                │                                      │
                │  wake(agent_id):                     │
                │    state = get_state(uuid)            │
                │    if Off → libxl.create_domain()     │
                │    if Suspended → libxl.restore()     │
                │    poll /health until 200             │
                │    return RUNNING                     │
                │                                      │
                │  sleep_sweep() [every 5s]:           │
                │    for agent where now - last_req     │
                │         > ttl * 2:                    │
                │      if mode=suspend → xl save        │
                │      if mode=destroy → xl destroy     │
                │                                      │
                │  State DB: PostgreSQL                 │
                │  Image Store: MinIO/S3               │
                │  Xen Control: libxl FFI bindings     │
                │                                      │
                └──────────────────────────────────────┘
```

#### 3.2 — Request Buffering (The HTTP Synjitsu)

This is the critical UX feature — hiding cold-boot latency from clients:

```
Request arrives for sleeping agent
    │
    ├── Gateway adds request to per-agent buffer queue
    ├── Gateway sends WAKE signal to orchestrator
    ├── Orchestrator starts/resumes unikernel
    ├── Gateway polls agent's /health endpoint
    │   ├── Retry every 2ms for up to 500ms
    │   └── Unikraft boots in ~5ms, app starts in ~10-50ms
    ├── /health returns 200 → agent is ready
    ├── Gateway drains buffer: replays all queued requests
    └── Client receives response (total latency: 15-100ms)
```

For suspend/resume (warm start), the total latency drops to ~5-15ms because
memory state is already loaded.

#### 3.3 — State Machine Per Agent

```
              deploy
    ┌─────────────────────────────┐
    │                             ▼
    │    ┌───────┐  wake()  ┌─────────┐
    │    │ OFF   │─────────→│ BOOTING │
    │    └───┬───┘          └────┬────┘
    │        │                   │ /health → 200
    │  destroy/timeout           ▼
    │        │              ┌─────────┐
    │        ├──────────────│ RUNNING │←──── resume()
    │        │   sleep()    └────┬────┘         │
    │        │                   │              │
    │        │    suspend()      ▼              │
    │        │              ┌──────────┐        │
    │        │              │SUSPENDED │────────┘
    │        │              └──────────┘
    │        ▼
    │   ┌──────────┐
    └───│ DELETED  │
        └──────────┘
```

#### 3.4 — Dual-Mode Stop Strategy

The orchestrator supports two tiers of idleness (inspired by Jitsu's TTL model):

| Tier | Condition | Action | Resume Time |
|------|-----------|--------|-------------|
| **Warm idle** | No requests for `TTL` seconds | Suspend (save memory to disk) | ~2-5ms |
| **Cold idle** | No requests for `TTL * 10` seconds | Destroy (free all resources) | ~5-50ms |
| **Active** | Receiving requests | Keep running | 0ms (already up) |

This two-tier approach means:
- Agents that get sporadic traffic stay "warm" (suspended, fast resume)
- Agents that haven't been used in ages get fully destroyed (zero resources)
- The threshold between tiers is configurable per agent in the manifest

**Deliverable:** HTTP-triggered orchestrator with request buffering, two-tier
idle management, and health-check-based readiness.

---

### Phase 4: Dual-Platform Support — Xen + KVM/Firecracker (Weeks 16-20)

**Goal:** Leverage Unikraft's multi-platform support to run on both Xen and
KVM/Firecracker, choosing the best platform per workload.

#### 4.1 — Why Both?

| Property | Xen | Firecracker (KVM) |
|----------|-----|-------------------|
| Boot time | ~5ms | ~5ms (with snapshot) |
| Suspend/resume | Yes (dom0 xl save/restore) | Yes (snapshot/restore) |
| Memory overhead | ~2MB per VM | ~5MB per VM |
| Networking | Xen netfront (PV) | virtio-net (MMIO) |
| Density | Higher (PV overhead is lower) | Good (microVM optimized) |
| Tooling | xl, libxl | firecracker API (REST) |
| Ecosystem | Mature, battle-tested | AWS-backed, modern |

Unikraft already builds for both (`plat/xen/` and `plat/kvm/` with
`CONFIG_PLAT_KVM_VMM_FIRECRACKER`). The same agent code compiles to either
platform.

#### 4.2 — Orchestrator Backend Interface

Generalize Jitsu's `backends.mli` pattern to support multiple hypervisors:

```
trait VmBackend {
    fn create_vm(config: &AgentConfig) -> Result<VmId>;
    fn destroy_vm(id: VmId) -> Result<()>;
    fn suspend_vm(id: VmId) -> Result<SnapshotHandle>;
    fn resume_vm(handle: SnapshotHandle) -> Result<VmId>;
    fn get_state(id: VmId) -> Result<VmState>;
    fn get_ip(id: VmId) -> Result<IpAddr>;
}

// Implementations:
struct XenLibxlBackend { ... }       // xl create/save/restore
struct FirecrackerBackend { ... }    // REST API + snapshot
```

#### 4.3 — Platform Selection Per Agent

```yaml
# agent.yaml
name: my-agent
runtime: python3.12
platform: auto    # or "xen" or "firecracker"
# auto = orchestrator picks based on:
#   - available capacity
#   - expected latency requirements
#   - agent's resource profile
```

**Deliverable:** Agents deploy seamlessly on Xen or Firecracker, orchestrator
picks the optimal platform.

---

### Phase 5: Multi-Node Clustering & Auto-Scaling (Weeks 20-28)

**Goal:** Scale beyond a single bare-metal host.

#### 5.1 — Cluster Architecture

```
                        ┌─────────────────────┐
                        │   GLOBAL GATEWAY     │
                        │   (anycast/LB)       │
                        └─────────┬───────────┘
                                  │
                  ┌───────────────┼───────────────┐
                  │               │               │
          ┌───────▼──────┐ ┌─────▼───────┐ ┌─────▼───────┐
          │   Node 1     │ │   Node 2    │ │   Node 3    │
          │   (Xen)      │ │(Firecracker)│ │   (Xen)     │
          │              │ │             │ │             │
          │ Agent A (run)│ │ Agent B(run)│ │ Agent C(sus)│
          │ Agent D (sus)│ │ Agent E(off)│ │ Agent A(sus)│
          │              │ │             │ │             │
          │ Local orch.  │ │ Local orch. │ │ Local orch. │
          └──────────────┘ └─────────────┘ └─────────────┘
                  │               │               │
                  └───────────────┼───────────────┘
                                  │
                        ┌─────────▼───────────┐
                        │   CLUSTER STATE      │
                        │   (etcd/consul)      │
                        │                      │
                        │ Agent placement map   │
                        │ Node health/capacity  │
                        │ Image distribution    │
                        └──────────────────────┘
```

#### 5.2 — Scheduling Policy

When a request arrives for a sleeping agent:

```
1. Check cluster state: where was this agent last running?
2. If the node still has a suspended snapshot → resume there (fastest)
3. If not, pick the node with:
   a. Most free memory
   b. Agent image already cached locally
   c. Lowest current load
4. Cold-boot on selected node
5. Update placement map
```

#### 5.3 — Auto-Scaling

```
Per-agent scaling:
  if concurrent_requests > threshold AND instances < max:
      spawn new instance on least-loaded node

  if concurrent_requests drops AND instances > 1:
      drain one instance (stop accepting new requests)
      wait for in-flight to complete
      suspend/destroy it

  if concurrent_requests = 0 for TTL seconds:
      suspend last instance (scale to zero)
```

**Deliverable:** Multi-node cluster with intelligent placement and per-agent
horizontal auto-scaling.

---

### Phase 6: Self-Service Platform (Weeks 28-36)

**Goal:** Developer-facing product — the "Vercel for AI Agents" experience.

#### 6.1 — CLI

```bash
# Initialize a new agent project
unictl init --runtime python3.12 my-agent

# Deploy
unictl deploy ./my-agent
# → Building Unikraft image...
# → Uploading to registry...
# → Agent live at: https://my-agent.platform.com

# Check status
unictl status my-agent
# → Status: SUSPENDED (last request: 2 min ago)
# → Instances: 0/10
# → Total invocations: 1,247

# View logs
unictl logs my-agent --follow

# Set secrets
unictl secret set OPENAI_API_KEY=sk-...

# Scale settings
unictl scale my-agent --min 0 --max 20
```

#### 6.2 — Web Dashboard

- Deploy agents via drag-and-drop or Git integration
- Real-time metrics: cold starts, p50/p95/p99 latency, invocation count
- Per-agent logs with search
- Environment variable / secret management
- Custom domain mapping with automatic TLS
- Usage-based billing dashboard

#### 6.3 — Git Integration

```
Push to main branch → GitHub webhook → Build pipeline:
  1. Pull agent code
  2. kraft build --plat xen --arch x86_64
  3. Push image to registry
  4. Rolling update: new requests go to new version
  5. Drain old instances gracefully
```

**Deliverable:** Full self-service platform with CLI, web UI, Git-based deploys.

---

### Phase 7: Production Hardening (Ongoing)

| Area | Implementation |
|------|---------------|
| **Observability** | Agent stdout → centralized logging (Loki). Per-agent Prometheus metrics. OpenTelemetry tracing through gateway → agent. |
| **Security** | Network isolation per tenant (Xen domU firewall rules). Agent images are read-only. No shell, no filesystem write (unikernel property). |
| **Cold-start optimization** | Pre-warm pools: keep N suspended "template" instances per popular runtime. On deploy, fork from template instead of cold-booting. |
| **Snapshot cloning** | Suspend a "warm" agent after initialization (imports loaded, connections ready). Clone this snapshot for each new instance — skip initialization entirely. |
| **Rate limiting** | Per-agent, per-user token bucket at the gateway. Configurable in agent manifest. |
| **Billing** | Meter: boot-seconds, memory-MB-seconds, request count. Charge only for RUNNING time (scale-to-zero = no cost when idle). |
| **Edge** | Deploy gateway nodes at multiple PoPs. Route to nearest bare-metal cluster. Agent images replicated across regions. |

---

## Part 4 — What Needs To Be Built (Engineering Work Breakdown)

### New Code To Write

| Component | Language | Effort | Description |
|-----------|----------|--------|-------------|
| **Unikraft Xen suspend/resume** | C | 2-3 weeks | Implement `xen_suspend()` in `plat/xen/shutdown.c`, handle device quiesce/reconnect. This is the single most important contribution. |
| **Unikraft agent base images** | Kraftfile/Docker | 2 weeks | Pre-built Unikraft images per runtime (Python, Node, Go, Rust) with HTTP server + POSIX compat. |
| **API Gateway** | Rust (axum) | 3-4 weeks | HTTP reverse proxy with request buffering, health-check polling, subdomain routing. |
| **Orchestrator** | Rust or Go | 4-6 weeks | Lifecycle manager: wake/sleep/destroy, state DB, libxl/Firecracker backends, maintenance sweeper. Incorporates Jitsu's core logic. |
| **Build service** | Go | 3 weeks | `kraft build` wrapper, image registry (MinIO), manifest parser. |
| **CLI (`unictl`)** | Go (cobra) | 2 weeks | Deploy, status, logs, secrets, scale commands. |
| **Web dashboard** | Next.js | 4 weeks | Agent management UI, metrics, logs. |
| **Cluster scheduler** | Rust/Go | 4-6 weeks | Multi-node placement, auto-scaling, etcd integration. |

### Jitsu Code To Reuse (Patterns, Not Literal Code)

| Jitsu Pattern | Where It Goes |
|---------------|---------------|
| `jitsu.ml:start_vm` state machine (Off→boot, Suspended→resume, Running→noop) | Orchestrator `wake()` function |
| `jitsu.ml:stop_expired_vms` TTL sweep | Orchestrator `sleep_sweep()` maintenance loop |
| `backends.mli` pluggable VM interface | Orchestrator `VmBackend` trait |
| `synjitsu.ml` GARP + SYN caching | Gateway request buffering |
| `irmin_backend.ml` state storage pattern | PostgreSQL state schema |
| `main.ml` maintenance_thread + DNS thread model | Orchestrator async task model |
| `xenstore.ml` readiness waiting | Health-check polling loop |
| `vm_stop_mode.ml` Destroy/Suspend/Shutdown modes | Two-tier idle strategy |

---

## Part 5 — Priority Ordering

```
WEEK  1-3:  Phase 0 — Get Unikraft running on Xen, managed by Jitsu
                       (PROVES: Unikraft images work with Jitsu's libxl backend)

WEEK  3-6:  Phase 1 — Implement suspend/resume in Unikraft for Xen
                       (PROVES: warm start works, ~2ms resume)

WEEK  6-10: Phase 2 — Multi-language agent base images
                       (PROVES: Python/Node/Rust agents run as unikernels)

WEEK 10-16: Phase 3 — HTTP orchestrator + request buffering
                       (PROVES: Vercel-like experience, not just DNS)

WEEK 16-20: Phase 4 — Add Firecracker support
                       (PROVES: platform flexibility, not locked to Xen)

WEEK 20-28: Phase 5 — Multi-node clustering
                       (PROVES: horizontal scaling story)

WEEK 28-36: Phase 6 — Self-service platform
                       (PROVES: product-market fit)

ONGOING:    Phase 7 — Production hardening
```

**The most critical single task is Phase 1 — implementing `xen_suspend()` in
Unikraft.** Without it, you only get cold-boot scale-to-zero (5-10ms). With it,
you get warm resume (1-2ms) which makes the platform indistinguishable from
"always on" for end users. This is the killer feature that neither plain Jitsu
(MirageOS-only) nor plain Unikraft (no lifecycle management) provides alone.
