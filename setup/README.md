# Phase 0: Bare Metal Setup Guide

> **Starting point:** Fresh Ubuntu 22.04 on bare metal
> **End goal:** Unikraft unikernel booting on Xen, managed by Jitsu

This guide walks through every step. Scripts in this directory automate each stage.

> **IMPORTANT: You are accessing this server via SSH.**
> All scripts are designed to be SSH-safe. But read the SSH section below first.

---

## SSH Access: What You Need To Know

You're operating on a remote bare metal server with no physical access. Here's
what could go wrong and how we protect against it:

### The Risks

| Step | What Could Break SSH | Our Protection |
|------|---------------------|----------------|
| **Step 1 (Xen install + reboot)** | GRUB boots Xen, but Xen's network driver doesn't work with your NIC → no SSH | **Auto-recovery**: a systemd service checks network 3 min after boot. If it fails, the server auto-reboots to the non-Xen kernel. GRUB also has a 10s visible menu for manual IPMI/KVM recovery. |
| **Step 1 (bridge config)** | Bridge misconfigured → server gets a different IP or no IP | **IP preservation**: the script detects whether your IP is static or DHCP and writes the bridge config accordingly. Static IPs are explicitly assigned to xenbr0. |
| **Step 4 (xl console)** | `xl console` opens interactive terminal that freezes SSH | **Removed**: we use `xl dmesg` and log files instead. Console only shown as a manual debugging option. |
| **Step 6 (port 53)** | systemd-resolved already uses port 53 → Jitsu fails to bind | **Alternate port**: Jitsu defaults to port 5353. Use `USE_PORT_53=1` flag only if you explicitly want port 53. |

### Before You Reboot (Step 1)

1. **Note your server's current IP**: `ip addr show` — this IP will be on `xenbr0` after reboot
2. **Know your IPMI/iDRAC/iLO URL**: Ask your hosting provider if you don't have it. This is your emergency console if SSH dies.
3. **Consider a serial console**: Some providers offer serial over SSH (e.g., `ssh serial@provider`)

### If You Get Locked Out

```bash
# Option 1: Wait 3 minutes — auto-recovery will reboot to non-Xen kernel

# Option 2: Use IPMI/iDRAC to access GRUB menu
#   - Select the Ubuntu entry WITHOUT "Xen" in the name
#   - Boot into regular kernel, SSH back in, debug

# Option 3: Ask your hosting provider to reboot into rescue mode

# Option 4: If you have iDRAC/IPMI, set next boot to non-Xen:
#   ipmitool chassis bootdev disk  # resets to default boot
```

### Running Long Processes Over SSH

Use `tmux` or `nohup` to keep processes alive if your SSH disconnects:

```bash
# Install tmux (do this first, it's essential for remote work)
sudo apt-get install -y tmux

# Start a tmux session before running any script
tmux new -s setup

# If SSH disconnects, reconnect and reattach:
tmux attach -t setup

# For Jitsu (step 6), run in tmux or with nohup:
nohup sudo bash setup/06-run-jitsu.sh > /var/log/jitsu.log 2>&1 &
```

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
# SSH into your server, start a tmux session first!
sudo apt-get install -y tmux && tmux new -s setup

sudo bash setup/01-install-xen.sh
```

**What it does:**
- Installs Xen hypervisor 4.17+ packages
- Installs xl toolstack, Xen dev headers, bridge-utils
- Configures GRUB to boot Xen (with 10s timeout for recovery)
- Sets up dom0 memory limit (leaves rest for unikernels)
- Creates network bridge (xenbr0) — **preserves your SSH IP**
- Installs auto-recovery service (reboots to non-Xen if network fails)
- **Requires a REBOOT** — after reboot, Ubuntu runs as Xen dom0

**Reboot and reconnect:**
```bash
sudo reboot
# Wait ~2 minutes, then SSH back to the SAME IP
ssh user@your-server-ip

# Verify Xen is running:
xl info          # Should show Xen version, free memory, nr_cpus
xl list          # Should show Domain-0 running
brctl show       # Should show xenbr0 with your NIC attached
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

**Test the full loop (open a SECOND SSH session):**
```bash
# SSH session 1: Jitsu is running (from step above)
# SSH session 2: send test queries

# Trigger unikernel boot via DNS (port 5353 to avoid systemd-resolved):
dig @127.0.0.1 -p 5353 test-agent.unikernel.local

# Jitsu receives the query → boots the unikernel → returns IP
# Now test the unikernel directly:
curl http://10.0.0.100:8080/health
# → {"status":"ok","agent":"test-agent","runtime":"unikraft-xen"}

# Watch xl list — the domain exists while active:
xl list

# Wait 60s without any DNS queries...
sleep 65 && xl list
# → test-agent disappears (scale to zero!)

# To use port 53 instead (requires disabling systemd-resolved):
# USE_PORT_53=1 sudo bash setup/06-run-jitsu.sh
```

---

## Troubleshooting

### SSH / Connectivity

| Problem | Solution |
|---------|----------|
| Can't SSH after reboot | Wait 3 min — auto-recovery will reboot to non-Xen kernel. Or use IPMI to pick non-Xen boot entry. |
| SSH connects but `xl info` fails | Server booted non-Xen kernel. Check GRUB: `cat /etc/default/grub.d/xen.cfg`, run `update-grub`, reboot. |
| Server unreachable after bridge config | Bridge may have wrong IP. Use IPMI console to check `ip addr show xenbr0`. |
| Port 53 already in use | systemd-resolved uses it. Use `dig -p 5353` or set `USE_PORT_53=1` in step 6. |

### Xen

| Problem | Solution |
|---------|----------|
| `xl info` says "command not found" | Xen not installed or booted non-Xen kernel. Re-run step 1 and reboot. |
| `xl info` shows 0 free memory | dom0 is using all RAM. Check `dom0_mem` in `/etc/default/grub.d/xen.cfg`. |
| `xl create` fails with "kernel not found" | Check the path in the .cfg file points to the actual `.xen` binary. |
| `xl create` fails with "bridge not found" | Run `brctl show` to see bridges. Edit the .cfg to match your bridge name. |

### Build

| Problem | Solution |
|---------|----------|
| kraft build fails | Make sure all deps installed. Try `kraft build --log-level debug`. |
| Jitsu fails to compile | OCaml version or package mismatch. Check `opam list` for all dependencies. |
| Unikernel boots but no network | Check bridge config: unikernel NIC must be on the same bridge as dom0. |
| `xl console` freezes SSH | Use `xl console VM_NAME` in a separate SSH session. Press `Ctrl+]` to detach. |

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
