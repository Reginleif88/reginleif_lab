---
title: "Project 2: Proxmox Windows Core Setup - Background & Concepts"
parent: "Project 2: Proxmox Windows Core Setup"
tags: [concepts, background, windows-server, proxmox, virtio, paravirtualization]
status: completed
---

# Background & Concepts: Proxmox Windows Core Setup

## Overview

This project establishes the foundation for all Windows-based infrastructure by creating high-performance Windows Server Core virtual machines on Proxmox VE. Understanding the concepts behind Server Core, Proxmox virtualization, and paravirtualized drivers is essential for building efficient, production-like lab environments.

---

## Windows Server Core vs Desktop Experience

### What is Server Core?

**Windows Server Core** is a minimal installation option that:

- Has **no GUI** (no Start menu, no File Explorer, no taskbar)
- Provides only a command-line interface (PowerShell and cmd)
- Boots directly to `sconfig.cmd` (Server Configuration utility)
- Installs only the components needed to run server roles

### Comparison Table

| Aspect | Server Core | Desktop Experience (GUI) |
|:-------|:------------|:-------------------------|
| **Disk Footprint** | ~10 GB | ~20-30 GB |
| **RAM Usage (Idle)** | ~800 MB | ~2 GB |
| **Attack Surface** | Minimal | Larger (IE, Explorer, etc.) |
| **Patch Frequency** | Lower | Higher (GUI components need patches) |
| **Management** | PowerShell, remote tools | Local GUI + PowerShell |
| **Reboot Frequency** | Lower (fewer updates) | Higher |
| **Best For** | Domain Controllers, file servers, Hyper-V hosts | Admin workstations, learning environments |

### Why Use Server Core?

**Production Best Practice:**

Microsoft recommends Server Core for all production roles, especially:

- **Domain Controllers** - Fewer moving parts = more stable AD
- **File Servers** - Lower overhead = better performance
- **Hyper-V Hosts** - Minimal host OS = more resources for VMs
- **Container Hosts** - Windows containers require Server Core

**Security Benefits:**

- **Reduced attack surface**: No Internet Explorer, no Windows Search, fewer services
- **Fewer vulnerabilities**: GUI components like Explorer have historically had security issues
- **Compliance**: Many security frameworks (CIS, DISA STIGs) recommend or require Server Core

**Operational Benefits:**

- **Faster patching**: Fewer updates to install, faster reboot times
- **Lower resource usage**: More RAM/CPU available for workloads
- **Automated management**: Forces you to learn PowerShell (good for automation)

### When to Use Desktop Experience

- **Learning environments** - GUI makes it easier to explore features
- **Admin workstations** - Need GUI tools like RSAT, ADUC, etc.
- **Application compatibility** - Some legacy apps require GUI components

For this lab, we use **Server Core for infrastructure servers** (DCs, DNS, DHCP) and **Desktop Experience for admin/gateway servers** (Royal Server, WDS/MDT).

---

## Proxmox VE Overview

### What is Proxmox VE?

**Proxmox Virtual Environment (VE)** is a **Debian-based Linux distribution** that provides:

- **KVM hypervisor** - Full hardware virtualization (like ESXi, Hyper-V)
- **LXC containers** - Lightweight Linux containers (like Docker, but system containers)
- **Web-based management** - No separate management server needed
- **Clustering** - Multi-host high availability and live migration
- **Software-defined storage** - ZFS, Ceph integration

### Proxmox vs Alternatives

| Feature | Proxmox VE | VMware ESXi | Hyper-V | Xen |
|:--------|:-----------|:------------|:--------|:----|
| **Cost** | Free (open source) | $$$ (licensing) | Free (with Windows) | Free (open source) |
| **Management** | Web UI | vCenter ($$) | Hyper-V Manager | XenCenter |
| **VMs + Containers** | Yes (KVM + LXC) | VMs | VMs | VMs |
| **Clustering** | Built-in | vCenter required | Failover Cluster | XenServer Pool |
| **Storage** | ZFS, Ceph, NFS | VMFS, vSAN | VHDX, CSV | LVM, GFS2 |
| **Linux Friendliness** | Excellent | Good | Poor | Excellent |
| **Windows Friendliness** | Good (with VirtIO) | Excellent | Excellent | Good |

### Proxmox Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                     Proxmox VE Host                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         Web UI (Port 8006 - https)                     │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Proxmox Management Layer (pveproxy, pvedaemon)        │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌──────────────────────┐  ┌──────────────────────────────┐ │
│  │   KVM/QEMU           │  │   LXC                        │ │
│  │   (Full VMs)         │  │   (Containers examples)      │ │
│  │  ┌────────┐ ┌─────┐  │  │  ┌─────┐ ┌─────┐             │ │
│  │  │Windows │ │Linux│  │  │  │nginx│ │mysql│             │ │
│  │  │  VM    │ │ VM  │  │  │  └─────┘ └─────┘             │ │
│  │  └────────┘ └─────┘  │  │                              │ │
│  └──────────────────────┘  └──────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │          Debian Linux Kernel (KVM module)              │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │            Hardware (CPU, RAM, Disks, NICs)            │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Key Components:**

- **KVM (Kernel-based Virtual Machine)**: Linux kernel module that turns Linux into a hypervisor
- **QEMU**: Emulates hardware devices for VMs (disks, network cards, etc.)
- **Libvirt**: API for managing VMs (not directly used by Proxmox, but similar concepts)

---

## VirtIO and Paravirtualization

### Virtualization Models

There are two main approaches to virtualization:

#### 1. Full Virtualization (Emulation)

```text
┌───────────────────────────────┐
│     Guest OS (Windows)        │
│  "I see an Intel e1000 NIC"   │
└───────────────────────────────┘
             ↓
┌───────────────────────────────┐
│  Hypervisor (QEMU)            │
│  Emulates Intel e1000 hardware│  ← Slow: Must emulate every
│  Translates to real hardware  │    hardware register access
└───────────────────────────────┘
             ↓
┌───────────────────────────────┐
│  Real Hardware (VirtIO NIC)   │
└───────────────────────────────┘
```

**Pros:** Guest OS needs no modifications (any OS works)
**Cons:** Slow - emulation has significant overhead

#### 2. Paravirtualization (VirtIO)

```text
┌───────────────────────────────┐
│     Guest OS (Windows)        │
│  VirtIO driver installed      │  ← Guest knows it's in a VM
│  "I'm virtualized, use API"   │
└───────────────────────────────┘
             ↓ (VirtIO API)
┌───────────────────────────────┐
│  Hypervisor (QEMU)            │
│  VirtIO backend               │  ← Fast: Direct API calls,
│  Direct memory sharing        │    no emulation needed
└───────────────────────────────┘
             ↓
┌───────────────────────────────┐
│  Real Hardware                │
└───────────────────────────────┘
```

**Pros:** Near-native performance (80-95% of bare metal)
**Cons:** Requires guest OS driver support

### What is VirtIO?

**VirtIO** is a **standardized paravirtualization framework** developed by Red Hat for KVM:

- **Open standard** - Works across KVM, QEMU, VirtualBox, and cloud platforms
- **High performance** - Used by AWS, Google Cloud, Azure for Linux VMs
- **Multiple device types** - Storage (vioscsi), network (NetKVM), balloon memory, RNG devices

**Why does Windows need VirtIO drivers?**

- Windows doesn't include VirtIO drivers by default (unlike Linux)
- Without drivers, Windows can't see VirtIO disks or network adapters
- Fedora Project maintains `virtio-win` package with Windows drivers

---

## The "Hidden Drive" Problem

### Why Windows Can't See the Disk

When you boot the Windows installer on a Proxmox VM with VirtIO SCSI:

1. Windows installer loads minimal drivers from the ISO
2. These drivers include support for IDE, SATA, and some common RAID controllers
3. VirtIO SCSI is **not** included in the Windows ISO
4. Installer can't see any disks → Installation fails

### The Solution: Manual Driver Injection

The "trick" is to inject drivers **during** installation:

```text
┌─────────────────────────────────────────────────────────┐
│  Windows Installer                                       │
│  "Where should I install Windows?"                       │
│  [ ] No drives found                                     │
│                                                          │
│  [Load Driver] ← Click here                             │
└─────────────────────────────────────────────────────────┘
             ↓
┌─────────────────────────────────────────────────────────┐
│  Browse to E:\vioscsi\2k22\amd64                        │
│  (virtio-win.iso mounted as second CD-ROM)              │
└─────────────────────────────────────────────────────────┘
             ↓
┌─────────────────────────────────────────────────────────┐
│  Windows loads VirtIO SCSI driver                       │
│  Disk suddenly appears!                                  │
│  [●] 80 GB VirtIO SCSI Disk                             │
└─────────────────────────────────────────────────────────┘
```

**Why is this necessary?**

- Windows Setup has no network access during early boot (can't download drivers)
- Windows doesn't support "driver injection" from the same ISO (security measure)
- Must provide drivers via a second media source (floppy, USB, or second ISO)

**Why mount `virtio-win.iso` as CD-ROM 2?**

- CD-ROM 1: Windows Server installation ISO
- CD-ROM 2: VirtIO drivers ISO
- Installer can access both simultaneously during setup

---

## Q35 Machine Type and UEFI

**Q35** is a modern chipset emulation (vs legacy i440fx) that provides native PCIe support, which is required for modern Windows features like GPU passthrough and NVMe drives. It also supports more devices (32+ vs ~12 on legacy PCI).

**UEFI** (vs legacy BIOS) enables GPT disks >2TB, Secure Boot, TPM 2.0, and faster boot times. Microsoft is phasing out BIOS support, so UEFI is the standard for Windows Server 2019+.

Both Q35 and UEFI are best practice for any modern Windows VM.

---

## QEMU Guest Agent

### What is the Guest Agent?

The **QEMU Guest Agent** is a background service that runs inside the VM and communicates with the Proxmox host via a virtual serial channel.

### What It Does

| Feature | Without Agent | With Agent |
|:--------|:--------------|:-----------|
| **VM Shutdown** | Hard power-off (like pulling plug) | Graceful shutdown (like clicking "Shut Down") |
| **IP Address Display** | Not shown in Proxmox UI | Shown in VM summary |
| **Snapshots** | Crash-consistent only | Application-consistent (VSS integration) |
| **Time Sync** | NTP only | Host can sync time to guest |
| **File Operations** | Not possible | Host can read/write guest files |

**Why install it?**

- **Backup integrity**: Application-consistent snapshots ensure databases aren't corrupted
- **Operational visibility**: See VM IP addresses without logging in
- **Graceful shutdowns**: Prevents filesystem corruption during host maintenance

---

## Why Disable Windows Update?

In production, automatic updates are disabled to ensure controlled change management: updates must be tested, approved, and scheduled. Unexpected reboots can break AD replication or cluster quorum. Updates are deployed centrally via **WSUS** or **ConfigMgr** in maintenance windows.

For the lab, disabling updates prevents surprises during initial configuration. Re-enable (via WSUS) once core infrastructure is stable.

---

## Key Terms Glossary

| Term | Definition |
|:-----|:-----------|
| **Server Core** | Minimal Windows Server installation without GUI. Smaller footprint, fewer patches, reduced attack surface |
| **Desktop Experience** | Full Windows Server installation with GUI. Used for admin workstations and learning |
| **Proxmox VE** | Open-source Debian-based hypervisor using KVM for VMs and LXC for containers |
| **KVM** | Kernel-based Virtual Machine: Linux kernel module enabling hardware virtualization |
| **QEMU** | Quick Emulator: provides hardware emulation for VMs (disks, NICs, etc.) |
| **VirtIO** | Paravirtualized I/O framework where guest cooperates with hypervisor for near-native performance |
| **Paravirtualization** | Virtualization approach where guest OS knows it's virtualized and uses optimized drivers |
| **Q35** | Modern QEMU machine type with PCIe support (vs legacy i440fx) |
| **UEFI/OVMF** | Modern firmware replacing legacy BIOS. Enables GPT, Secure Boot, TPM 2.0 |
| **QEMU Guest Agent** | Service inside VM enabling graceful shutdown, IP display, and application-consistent snapshots |
| **vioscsi** | VirtIO SCSI driver for Windows. Enables high-performance disk access |
| **NetKVM** | VirtIO network driver for Windows. Enables high-performance networking |
| **WSUS** | Windows Server Update Services: centralized update management for Windows environments |

