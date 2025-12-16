---
title: "Project 5: Installing OPNsense on HyperV (Branch) - Background & Concepts"
parent: "Project 5: Installing OPNsense on HyperV (Branch)"
tags: [concepts, background, opnsense, hyper-v, virtualization]
status: completed
---

# Background & Concepts: Installing OPNsense on Hyper-V (Branch)

## Overview

This guide deploys OPNsense on Microsoft Hyper-V to create a secure branch office firewall. While Project 1 covered OPNsense fundamentals on Proxmox, this project explores Hyper-V-specific considerations: different VM architectures, virtual networking models, and FreeBSD compatibility challenges.

**Why a separate branch firewall?**

- **Network segmentation:** Branch office (172.17.0.0/24) remains isolated from HQ (172.16.0.0/24) until site-to-site VPN is established (Project 7)
- **Local internet breakout:** Branch traffic exits locally rather than backhauling through HQ
- **Fault isolation:** Branch network failures don't impact HQ operations
- **Multi-site architecture:** Mirrors real-world enterprise deployments with geographically distributed offices

## Hyper-V Virtualization Platform

### Virtual Machine Generations

Hyper-V offers two distinct VM architectures with different capabilities and compatibility characteristics:

| Feature | Generation 1 (Legacy) | Generation 2 (Modern) |
|:--------|:----------------------|:----------------------|
| **Boot Firmware** | BIOS | UEFI |
| **Storage Controller** | IDE (boot), SCSI (data) | SCSI only (faster) |
| **Network Adapter** | Emulated + Fast | Fast only |
| **Secure Boot** | Not supported | Supported (Windows guests) |
| **Boot from SCSI** | No | Yes |
| **vTPM** | No | Yes (Windows 11 requirement) |
| **Performance** | Slower (legacy emulation) | Faster (paravirtualized drivers) |
| **Guest OS Support** | All Windows, older Linux | Windows 8+, modern Linux, limited FreeBSD |

> **Network Adapter Terms:**
> - **Emulated** = Legacy hardware emulation (slow, like an Intel e1000 NIC)
> - **Fast** = Paravirtualized/synthetic drivers (Hyper-V Integration Services, similar to VirtIO on Proxmox)
> - Gen 1 VMs support both types for compatibility; Gen 2 uses only fast adapters

**For OPNsense (FreeBSD), we use Generation 2 with Secure Boot disabled**

> **Why disable Secure Boot?** Microsoft's Secure Boot validates boot loaders against Microsoft's certificate authority. FreeBSD kernels are not signed by Microsoft, causing boot failure. In production, evaluate security trade-offs; in lab environments, this is acceptable.

### Virtual Switch Architecture

Hyper-V virtual switches function as software-defined network bridges, connecting VMs to each other and to external networks. Unlike Proxmox's Linux bridges (vmbr0, vmbr1), Hyper-V uses three distinct switch types:

**Virtual Switch Types:**

| Type | Host Access | VM-to-VM | External Network | Use Case |
|:-----|:------------|:---------|:-----------------|:---------|
| **External** | Yes | Yes | Yes (via physical NIC) | WAN connectivity, internet access |
| **Internal** | Yes | Yes | No | Host-VM communication, management networks |
| **Private** | No | Yes | No | Isolated VM networks, security zones |

**Branch Office Network Topology:**

```
                  Physical Network (Home/Internet)
                           │
                           │ Physical NIC
                           ▼
                  ┌────────────────────┐
                  │ External vSwitch   │ (WAN - 192.168.1.x)
                  └────────┬───────────┘
                           │
                    ┌──────▼─────────┐
                    │ OPNsenseBranch │
                    │   hn0 (WAN)    │
                    │   hn1 (LAN)    │
                    └──────┬─────────┘
                           │
                  ┌────────▼──────────┐
                  │ Private vSwitch   │ (Branch LAN - 172.17.0.0/24)
                  │   "Branch-LAN"    │
                  └────────┬──────────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
          ┌───▼───┐   ┌────▼───┐   ┌───▼───┐
          │ H-WIN │   │ H-WIN  │   │Future │
          │  -DC2 │   │ -SRV2  │   │  VMs  │
          └───────┘   └────────┘   └───────┘
```

**Key Design Decisions:**

- **External vSwitch for WAN:** Bridges OPNsense to physical network for internet access
- **Private vSwitch for LAN:** Isolates branch network; host cannot accidentally interfere with branch traffic
- **No Internal switch needed:** Domain controllers handle inter-VM communication; host management happens via external network

### Dynamic Memory and Resource Management

Hyper-V's Dynamic Memory feature allows the hypervisor to adjust VM memory allocation based on demand, enabling memory overcommitment. However, this is **disabled for OPNsense**:

**Why Disable Dynamic Memory for Firewalls:**

| Reason | Impact |
|:-------|:-------|
| **State table consistency** | Firewalls maintain connection tracking tables; memory ballooning can evict active sessions |
| **Packet processing predictability** | Variable memory causes variable latency; unacceptable for routing/NAT |
| **FreeBSD balloon driver limitations** | Unlike Windows, FreeBSD's memory balloon driver is less mature |
| **Performance consistency** | Firewalls are network bottlenecks; resource contention is unacceptable |

**When to use Dynamic Memory:**

- Windows VMs with good balloon driver support (hv_balloon)
- Non-latency-sensitive workloads (file servers, domain controllers)
- Memory-constrained hosts requiring overcommitment

**For critical network infrastructure (firewalls, routers), always allocate static memory.**

### Integration Services and Time Synchronization

Hyper-V Integration Services provide enhanced VM functionality through the VMBus interface. However, **time synchronization must be disabled** for OPNsense:

**Why Disable Hyper-V Time Sync:**

```
┌──────────────────────────────────────────────────────────┐
│  Conflict: Two Time Sources                              │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Hyper-V Integration Services    FreeBSD NTP Daemon      │
│    (host clock sync)              (pool.ntp.org)         │
│           │                             │                │
│           └──────────┬──────────────────┘                │
│                      │                                   │
│                  VM System Clock                         │
│                      │                                   │
│            Result: Clock drift, time jumps               │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**Proper Configuration:**

1. Disable Hyper-V time sync in VM settings → Integration Services
2. Enable NTP in OPNsense: Services → Network Time → General
3. Use public NTP servers (pool.ntp.org, time.nist.gov)

**Other Integration Services (keep enabled):**

- **Heartbeat:** Allows host to monitor VM health
- **Guest services:** File copy between host and VM
- **Shutdown:** Graceful VM shutdown from host

> **Contrast with Proxmox:** Similar issue exists with QEMU Guest Agent time sync (Project 3, Section 4). Both hypervisors attempt to synchronize guest clocks, conflicting with guest-configured NTP. Best practice: disable hypervisor time sync for all non-Windows guests.

### Mapping Proxmox Concepts to Hyper-V

```
Proxmox                          Hyper-V Equivalent
───────────────────────────────────────────────────────────
vmbr0 (Bridge to physical)   →  External vSwitch
vmbr1 (Bridge, no physical)  →  Internal vSwitch
VirtIO-net driver            →  Hyper-V synthetic (hv_netvsc)
QEMU Guest Agent             →  Integration Services
OVMF (UEFI) firmware         →  Generation 2 VM
SeaBIOS (BIOS) firmware      →  Generation 1 VM
qcow2 disk                   →  VHDX (dynamic)
raw disk                     →  VHDX (fixed) or VHD
```

### Private Networks and Bogon Filtering

OPNsense includes anti-spoofing protections that block RFC1918 private addresses and bogon networks on WAN interfaces. In lab environments, these must be disabled.

**RFC1918 Private Address Space:**

```
┌─────────────────────────────────────────────────────────┐
│  Reserved Private Networks (Never on Public Internet)   │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  10.0.0.0/8        → 16,777,216 addresses               │
│  172.16.0.0/12     → 1,048,576 addresses                │
│  192.168.0.0/16    → 65,536 addresses                   │
│                                                         │
│  Why reserved? Conserve public IPv4 space; enable NAT   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Bogon Networks:**

"Bogon" (short for "bogus IP") refers to addresses that should never appear in internet routing:

- Unallocated address space (IANA reserved)
- Documentation networks (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)
- Loopback (127.0.0.0/8)
- Link-local (169.254.0.0/16)
- Multicast (224.0.0.0/4)
- Reserved for future use (240.0.0.0/4)

**Anti-Spoofing Protection (Why OPNsense Blocks These):**

```
┌──────────────────────────────────────────────────────────┐
│  Production Firewall: Block Private IPs on WAN           │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Internet (Public IPs only)                              │
│         │                                                │
│         ▼                                                │
│  ┌─────────────┐                                         │
│  │   WAN       │  Packet from 192.168.1.1?               │
│  │ OPNsense    │  → DROP (likely spoofed)                │
│  └─────────────┘                                         │
│                                                          │
│  Legitimate: Public IP (e.g., 8.8.8.8)    ✓ Allow       │
│  Malicious: Private IP (e.g., 192.168.1.1) ✗ Block      │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**Lab Environment Exception:**

```
┌──────────────────────────────────────────────────────────┐
│  Lab: Home Network Acts as "Internet"                    │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Home Router (192.168.1.254) ← This is "the internet"    │
│         │                                                │
│         ▼                                                │
│  ┌─────────────┐                                         │
│  │   WAN       │  Packet from 192.168.1.254?             │
│  │ OPNsense    │  → Must ALLOW (it's our gateway!)       │
│  └─────────────┘                                         │
│                                                          │
│  Solution: Uncheck "Block private networks on WAN"       │
│           Uncheck "Block bogon networks on WAN"          │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**When to disable these protections:**

- Lab environments where WAN connects to private network
- Site-to-site VPNs that use private addressing
- Testing and development

**When to keep them enabled:**

- Production firewalls with direct internet connection
- Edge security devices
- Any deployment where WAN receives public IP from ISP

> **Security Note:** Disabling these protections in production exposes you to IP spoofing attacks. In BCP 38 (Best Current Practice), edge routers should perform ingress filtering to prevent spoofed source addresses.

### NAT Configuration Strategies

Network Address Translation (NAT) allows multiple devices on a private network to share a single public IP address. OPNsense supports automatic and manual NAT rule generation.

**OPNsense NAT Modes:**

| Mode | Description | When to Use |
|:-----|:------------|:------------|
| **Automatic (Hybrid)** | OPNsense generates rules based on interface config | Default; works for most deployments |
| **Manual** | Administrator creates explicit rules | Troubleshooting, complex multi-WAN, policy routing |

> **Troubleshooting Tip:** If NAT works from OPNsense itself (can ping 8.8.8.8 from firewall) but not from LAN clients, the issue is NAT rules, not WAN connectivity.

## DNS Resolution Strategy

### Unbound DNS Resolver

OPNsense includes Unbound, a validating, recursive, caching DNS resolver. Understanding recursive resolution is key to DNS troubleshooting.

**Recursive vs Forwarding:**

| Mode | How It Works | Pros | Cons |
|:-----|:-------------|:-----|:-----|
| **Recursive** | Queries root servers directly | Privacy (no third party sees all queries), educational | Slower initial queries, more bandwidth |
| **Forwarding** | Sends queries to upstream resolver (1.1.1.1, 8.8.8.8) | Faster (leverages upstream cache), less bandwidth | Privacy concern (upstream sees all queries) |

**OPNsense Default:** Forwarding mode with configurable upstream resolvers (Cloudflare 1.1.1.1, Google 8.8.8.8).

**Why override DHCP-provided DNS:**

```
┌──────────────────────────────────────────────────────────┐
│  Problem: Home Router Pushes Its Own DNS                 │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Home Router DHCP:                                       │
│    "Use me (192.168.1.254) for DNS"                      │
│         │                                                │
│         ▼                                                │
│  ┌─────────────────┐                                     │
│  │   OPNsense      │  Accepts 192.168.1.254 as upstream  │
│  │   (if allowed)  │  → Slow, unreliable ISP DNS         │
│  └─────────────────┘                                     │
│                                                          │
│  Solution: Disable DHCP DNS override                     │
│           Configure explicit upstreams: 1.1.1.1, 8.8.8.8 │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### DNSSEC Validation

DNSSEC (DNS Security Extensions) provides cryptographic validation of DNS responses, protecting against cache poisoning and spoofing attacks.

> [!TIP]
> **Simple analogy:** DNSSEC works like a notary chain. Each level (Root → .com → google.com) signs a certificate saying "the level below me is legitimate." If any signature is missing or invalid, the whole lookup fails with SERVFAIL.

**How DNSSEC Works:**

```
┌──────────────────────────────────────────────────────────┐
│  DNSSEC Chain of Trust                                   │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Root Zone (.) - signed by ICANN                         │
│      │  ✓ Signature valid                               │
│      ▼                                                   │
│  .com TLD - signed by Verisign                           │
│      │  ✓ Signature valid                               │
│      ▼                                                   │
│  example.com - signed by domain owner                    │
│      │  ✓ Signature valid                               │
│      ▼                                                   │
│  www.example.com → 93.184.216.34                         │
│                                                          │
│  If ANY signature fails → SERVFAIL (reject response)     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**DNSSEC Benefits:**

- **Prevents cache poisoning:** Attackers cannot inject fake DNS records
- **Authenticity guarantee:** DNS responses provably came from authoritative source
- **Integrity protection:** Responses haven't been tampered with in transit

**DNSSEC Limitations:**

- **Not universal:** Only ~35% of domains use DNSSEC
- **Breaks unsigned domains:** If parent zone is signed but child isn't, resolution fails
- **Doesn't provide privacy:** DNS queries still visible (use DoT/DoH for privacy)

> **Best practice for labs:** Enable DNSSEC. If a domain fails validation, that's useful information: either the domain is misconfigured, or you're experiencing a DNS attack. Failure to resolve is safer than accepting potentially malicious responses.

## Branch Office Architecture

### Network Design Principles

The branch office network mirrors HQ architecture but with simplified topology:

**Branch Network (172.17.0.0/24):**

```
Internet (192.168.1.0/24)
        │
        ▼
┌────────────────┐
│ OPNsenseBranch │  WAN: 192.168.1.245
│  172.17.0.1    │  LAN: 172.17.0.1
└───────┬────────┘
        │
   Branch LAN (172.17.0.0/24)
        │
  ┌─────┴──────┐
  │            │
H-WIN-DC2  H-WIN-SRV2
172.17.0.10  (future)
```

**Why Different Subnets:**

Non-overlapping address space enables site-to-site routing:
```
HQ (172.16.0.0/24) ←→ [VPN Tunnel] ←→ Branch (172.17.0.0/24)
```

If both sites used 172.16.0.0/24, routing would be impossible. Which 172.16.0.10 do you want? HQ's or Branch's?

## Key Terms Glossary

| Term | Definition |
|:-----|:-----------|
| **Generation 1 VM** | Hyper-V VM type using legacy BIOS boot and IDE controllers |
| **Generation 2 VM** | Hyper-V VM type using UEFI boot and SCSI controllers; faster but less compatible |
| **Secure Boot** | UEFI feature that validates boot loaders; incompatible with FreeBSD |
| **External vSwitch** | Hyper-V virtual switch bridged to physical NIC; provides external connectivity |
| **Internal vSwitch** | Hyper-V virtual switch accessible by VMs and host; no external network |
| **Private vSwitch** | Hyper-V virtual switch for VM-to-VM communication only; host cannot access |
| **Integration Services** | Hyper-V guest enhancements (time sync, heartbeat, file copy) |
| **hv_netvsc** | FreeBSD driver for Hyper-V synthetic network adapters |
| **Hardware Offloading** | Moving packet processing tasks from CPU to NIC; often broken in VMs |
| **RFC1918** | Private address space (10.x, 172.16-31.x, 192.168.x); not routable on internet |
| **Bogon Network** | IP address that should never appear on public internet (reserved, unallocated) |
| **NAT (Network Address Translation)** | Translating private IPs to public IP for internet access |
| **Unbound** | Recursive DNS resolver included with OPNsense |
| **DNSSEC** | DNS Security Extensions; cryptographic validation of DNS responses |
| **Dynamic Memory** | Hyper-V feature to adjust VM memory on-the-fly; should be disabled for firewalls |
