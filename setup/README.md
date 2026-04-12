# Phase 0: Bare Metal Setup Guide

> **Starting point:** Fresh Ubuntu 22.04 on bare metal
> **End goal:** Unikraft unikernel booting on Xen, managed by Jitsu

This guide walks through every step. Scripts in this directory automate each stage.

---

## Overview — What We're Building

```
Your bare metal server (Ubuntu 22.04)
  │
  ├── Xen Hypervisor (Type-1, boots first)
  │     └── dom0 (your Ubuntu becomes the Xen control domain)
  │           ├── Jitsu (DNS-triggered unikernel lifecycle manager)
  │           ├── kraft CLI (Unikraft build toolchain)
  │           └── xl toolstack (Xen VM management)
  │
  └── domU instances (Unikraft unikernels — created/destroyed by Jitsu)
        ├── agent-1 (e.g., Python HTTP server unikernel)
        ├── agent-2 (e.g., Node.js unikernel)
        └── ...
```

After this setup, a DNS query to your server will automatically boot a
Unikraft unikernel and return its IP address. When it's idle, Jitsu will
shut it down. That's scale-to-zero on bare metal.

---

## Step-by-Step Execution Order

### Step 1: Install Xen Hypervisor

```bash
# Run this ON the bare metal server (SSH in or local terminal)
sudo bash setup/01-install-xen.sh
```

**What it does:**
- Installs Xen hypervisor 4.17+ packages
- Installs xl toolstack, Xen dev headers, bridge-utils
- Configures GRUB to boot Xen as Type-1 hypervisor
- Sets up dom0 memory limit (leaves rest for unikernels)
- Configures a network bridge (xenbr0) for unikernel networking
- **Requires a REBOOT** — after reboot, Ubuntu runs as Xen dom0

**After reboot, verify:**
```bash
xl info          # Should show Xen version, free memory, nr_cpus
xl list          # Should show Domain-0 running
sudo xl dmesg    # Xen boot messages
```

### Step 2: Install Unikraft Toolchain

```bash
sudo bash setup/02-install-unikraft.sh
```

**What it does:**
- Installs build dependencies (GCC, make, flex, bison, etc.)
- Installs kraft CLI (Unikraft's Docker-like build tool)
- Installs QEMU (needed by kraft even for Xen targets — used for testing)
- Verifies kraft installation

**Verify:**
```bash
kraft --version
kraft pkg list --update
```

### Step 3: Build a Test Unikraft Unikernel for Xen

```bash
bash setup/03-build-test-unikernel.sh
```

**What it does:**
- Creates a simple C HTTP server unikernel
- Builds it targeting Xen x86_64
- Produces a bootable `.xen` image

**Output:**
```
build/test-agent_xen-x86_64    # The unikernel binary
```

### Step 4: Test Boot via xl (without Jitsu, just raw Xen)

```bash
sudo bash setup/04-test-xen-boot.sh
```

**What it does:**
- Creates a Xen domain config for the test unikernel
- Boots it with `xl create`
- Checks it's running with `xl list`
- Pings the unikernel
- Destroys it with `xl destroy`

This validates the data plane works before we add orchestration.

### Step 5: Install OCaml + Build Jitsu

```bash
bash setup/05-install-jitsu.sh
```

**What it does:**
- Installs opam (OCaml package manager)
- Sets up OCaml 4.14 compiler
- Installs Jitsu's OCaml dependencies (lwt, dns, irmin, xenctrl, etc.)
- Builds Jitsu binary

**Verify:**
```bash
./bin/jitsu --help
```

### Step 6: Wire It All Together — DNS-Triggered Boot

```bash
sudo bash setup/06-run-jitsu.sh
```

**What it does:**
- Starts Jitsu with the libxl backend
- Registers the test unikernel with a DNS name
- Configures Jitsu as a DNS server on port 53

**Test the full loop:**
```bash
# From another terminal on the same machine (or any machine pointing DNS here):
dig @127.0.0.1 test-agent.unikernel.local

# This triggers Jitsu to:
# 1. Receive the DNS query
# 2. Look up test-agent → unikernel config
# 3. Boot the Unikraft image via xl
# 4. Return the IP address
# 5. After TTL expires with no queries → destroy the unikernel
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `xl info` says "command not found" | Xen not installed. Re-run step 1 and reboot. |
| `xl info` shows 0 free memory | dom0 is using all RAM. Check `/etc/default/grub` for `dom0_mem` setting. |
| `xl create` fails with "kernel not found" | Check the path in the .cfg file points to the actual `.xen` binary. |
| `xl create` fails with "bridge not found" | Run `brctl show` to see bridges. Edit the .cfg to match your bridge name. |
| kraft build fails | Make sure all build deps are installed. Try `kraft build --log-level debug`. |
| Jitsu fails to compile | OCaml version or package mismatch. Check `opam list` for all dependencies. |
| Unikernel boots but no network | Check bridge config: unikernel NIC must be on the same bridge as dom0's NIC. |

---

## Directory Structure After Setup

```
/Users/anshulkumar/jitsu/
├── setup/                    # ← You are here
│   ├── README.md             # This file
│   ├── 01-install-xen.sh
│   ├── 02-install-unikraft.sh
│   ├── 03-build-test-unikernel.sh
│   ├── 04-test-xen-boot.sh
│   ├── 05-install-jitsu.sh
│   ├── 06-run-jitsu.sh
│   └── test-agent/           # Simple test unikernel source
│       ├── Kraftfile
│       ├── Makefile.uk
│       └── main.c
├── src/                      # Jitsu source (OCaml)
├── Unikraft/                 # Unikraft source tree
├── roadmap.md                # Full roadmap
└── bin/jitsu                 # Built Jitsu binary (after step 5)
```
