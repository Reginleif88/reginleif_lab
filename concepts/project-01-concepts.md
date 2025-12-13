---
title: "Project 1: Installing OPNsense on Proxmox - Background & Concepts"
parent: "Project 1: Installing OPNsense on Proxmox"
tags: [opnsense, firewall, concepts, background, networking, nat, dns]
status: completed
---

# Background & Concepts: Installing OPNsense on Proxmox

## Overview

This project deploys OPNsense as a virtual firewall on Proxmox VE, providing network segmentation, NAT, and DNS services for your lab environment. Understanding how virtualized network infrastructure works (bridges, NAT translation, and DNS resolution) is essential for building isolated lab networks that can still reach the internet.

---

## The Problem: Your Lab Network is Isolated

Your lab VMs will live on a private network (`172.16.0.0/24`) that exists only inside Proxmox. Your home router has no idea this network exists. If a lab VM tries to reach `google.com`, the packets have nowhere to go:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                     THE PROBLEM: NO ROUTE TO INTERNET                       │
└─────────────────────────────────────────────────────────────────────────────┘

   Lab VM                                  Home Router              Internet
   172.16.0.10                             192.168.1.254
  ┌──────────┐     "ping google.com"      ┌──────────────┐        ┌─────────┐
  │   DC1    │ ─────────────────────────► │    ???       │   X    │ google  │
  └──────────┘                            └──────────────┘        └─────────┘
                                                 │
                                    "Who is 172.16.0.10?"
                                    "I don't know that network."
                                    (Packet dropped)
```

The home router only knows about `192.168.1.0/24`. When it sees a packet from `172.16.0.10`, it has no route back, so the packet is dropped.

## The Solution: OPNsense as Gateway

OPNsense sits between your lab network and home network, solving this problem with two mechanisms:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE SOLUTION: OPNSENSE GATEWAY                           │
└─────────────────────────────────────────────────────────────────────────────┘

  Lab VM               OPNsense               Home Router           Internet
  172.16.0.10          172.16.0.1 (LAN)       192.168.1.254
                       192.168.1.240 (WAN)

 ┌──────────┐         ┌──────────────┐        ┌──────────────┐     ┌─────────┐
 │   DC1    │────────►│  1. Route    │───────►│              │────►│ google  │
 └──────────┘         │  2. NAT      │        │              │     └─────────┘
                      └──────────────┘        └──────────────┘
      │                     │                        │
      │                     │                        │
      │                     ▼                        │
      │               ┌───────────┐                  │
      │               │ Rewrite   │                  │
      │               │ source IP │                  │
      │               └───────────┘                  │
      │                     │                        │
      ▼                     ▼                        ▼
 Src: 172.16.0.10    Src: 192.168.1.240    "I know 192.168.1.240!"
 Dst: 8.8.8.8        Dst: 8.8.8.8          (Routes reply back)
```

**Two critical functions:**

1. **Routing (Gateway)**: OPNsense knows both networks. It has one foot in `172.16.0.0/24` (LAN) and one foot in `192.168.1.0/24` (WAN), forwarding packets between them.

2. **NAT (Network Address Translation)**: OPNsense rewrites the source IP from `172.16.0.10` to `192.168.1.240` before sending packets upstream. Now the home router sees traffic from an IP it recognizes.

## Why OPNsense?

OPNsense is a FreeBSD-based firewall/router distribution. For this lab, it provides:

| Feature | How It's Used in This Lab |
|:--------|:--------------------------|
| **pf Firewall** | The same packet filter that powers OpenBSD. Stateful, fast, reliable. |
| **Outbound NAT** | Translates lab IPs to the WAN IP so traffic can reach the internet. |
| **Unbound DNS** | Local caching resolver. Lab VMs get fast, reliable DNS without depending on ISP servers. |
| **WireGuard VPN** | Site-to-site VPN (Project 7) and remote access (Project 9). |
| **Web Interface** | Configure everything through a browser instead of command-line only. |

### Services Used by Project

Not all OPNsense features are used immediately. Here's what gets enabled when:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│  PROJECT 1 (This Project)                  │   FUTURE PROJECTS              │
│  ─────────────────────────────────────────────────────────────────────────  │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐    ┌───────────┐ ┌───────────┐   │
│  │ Firewall  │ │    NAT    │ │    DNS    │    │    VPN    │ │  Routing  │   │
│  │   (pf)    │ │ (Outbound)│ │ (Unbound) │    │(WireGuard)│ │  (VLANs)  │   │
│  └───────────┘ └───────────┘ └───────────┘    └───────────┘ └───────────┘   │
│       ▲             ▲             ▲                 ▲             ▲         │
│       │             │             │                 │             │         │
│   Block/allow   Lab→Internet  Name resolution   Project 7,9   Project 11    │
│   traffic       connectivity  for lab VMs       (VPN tunnels) (VLANs)       │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!NOTE]
> **DHCP is intentionally disabled on OPNsense.** Domain Controllers will provide DHCP (Project 10) to enable Active Directory integration: dynamic DNS updates, DHCP options for PXE boot, and centralized IP management.

## How NAT Actually Works

We've established that NAT rewrites source addresses. But how does OPNsense know where to send the *reply*? The answer is the **state table**.

### The State Table (Stateful NAT)

When DC1 (`172.16.0.10`) sends a packet to Google DNS (`8.8.8.8`), OPNsense creates a state entry:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OPNSENSE STATE TABLE                                │
├─────────────────────────────────────────────────────────────────────────────┤
│  Internal IP:Port    │  External IP:Port   │  Destination      │  State     │
│─────────────────────────────────────────────────────────────────────────────│
│  172.16.0.10:54321   │  192.168.1.240:54321│  8.8.8.8:53       │  ACTIVE    │
│  172.16.0.11:49152   │  192.168.1.240:49152│  1.1.1.1:443      │  ACTIVE    │
└─────────────────────────────────────────────────────────────────────────────┘
```

When Google replies to `192.168.1.240:54321`, OPNsense looks up the state table: "Ah, that's actually `172.16.0.10:54321`" and rewrites the destination before forwarding.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                    OUTBOUND: Lab VM → Internet                             │
│────────────────────────────────────────────────────────────────────────────│
│                                                                            │
│  DC1 (172.16.0.10)              OPNsense                  Google (8.8.8.8) │
│        │                           │                            │          │
│        │  Src: 172.16.0.10:54321   │                            │          │
│        │  Dst: 8.8.8.8:53          │                            │          │
│        │ ─────────────────────────►│                            │          │
│        │                           │  Src: 192.168.1.240:54321  │          │
│        │                           │  Dst: 8.8.8.8:53           │          │
│        │                 [create state entry]                   │          │
│        │                           │ ──────────────────────────►│          │
│                                                                            │
│────────────────────────────────────────────────────────────────────────────│
│                    INBOUND: Internet → Lab VM (reply)                      │
│────────────────────────────────────────────────────────────────────────────│
│                                                                            │
│        │                           │◄────────────────────────── │          │
│        │                           │  Src: 8.8.8.8:53           │          │
│        │                           │  Dst: 192.168.1.240:54321  │          │
│        │                 [lookup state table]                   │          │
│        │◄───────────────────────── │                            │          │
│        │  Src: 8.8.8.8:53          │                            │          │
│        │  Dst: 172.16.0.10:54321   │                            │          │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

This is **stateful NAT**: OPNsense remembers connections and handles replies automatically.

### NAT Types

| Type | Direction | What It Does | Lab Example |
|:-----|:----------|:-------------|:------------|
| **SNAT** (Source NAT) | Outbound | Rewrites source IP | Lab VMs accessing internet |
| **DNAT** (Destination NAT) | Inbound | Rewrites destination IP | Port forwarding to internal servers |
| **Masquerade** | Outbound | SNAT that auto-detects WAN IP | When WAN uses DHCP |

> [!NOTE]
> This lab uses **static WAN IP** (`192.168.1.240`), so we configure explicit SNAT rules. If your WAN used DHCP, you'd use Masquerade mode instead.

## Virtualization Networking

OPNsense runs as a VM inside Proxmox, but it needs to connect to two different networks: your home network (WAN) and the isolated lab network (LAN). Proxmox uses **Linux bridges** to make this possible.

### Virtual Bridges: Software Switches

Think of a bridge as a virtual network switch. Proxmox creates two:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                                PROXMOX HOST                                 │
│─────────────────────────────────────────────────────────────────────────────│
│                                                                             │
│  vmbr0 (WAN Bridge)                    vmbr1 (LAN Bridge)                   │
│  ┌─────────────────────────┐           ┌─────────────────────────┐          │
│  │                         │           │                         │          │
│  │   ┌───────────────┐     │           │   ┌───────────────┐     │          │
│  │   │  eno1         │     │           │   │   (none)      │     │          │
│  │   │  Physical NIC │     │           │   │   No physical │     │          │
│  │   │               │     │           │   │   port        │     │          │
│  │   └───────┬───────┘     │           │   └───────────────┘     │          │
│  │           │             │           │             │           │          │
│  └───────────┼─────────────┘           └─────────────┼───────────┘          │
│              │                                       │                      │
│     ┌────────┴──────────┐               ┌────────────┼────────────┐         │
│     │                   │               │            │            │         │
│  ┌──┴─────┐         ┌───┴──┐         ┌──┴─────┐    ┌─┴────┐     ┌─┴────┐    │
│  │vtnet0  │         │ ...  │         │vtnet1  │    │ eth0 │     │ eth0 │    │
│  │        │         │      │         │        │    │      │     │      │    │
│  │OPNsense│         │Other │         │OPNsense│    │ DC1  │     │ DC2  │    │
│  │(WAN)   │         │ VMs  │         │(LAN)   │    │      │     │      │    │
│  └────────┘         └──────┘         └────────┘    └──────┘     └──────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                │                                     │
                ▼                                     ▼
       To Home Network                      Isolated (VM-only)
       192.168.1.0/24                       172.16.0.0/24
```

| Bridge | Physical Port | Purpose |
|:-------|:--------------|:--------|
| **vmbr0** | `eno1` (your NIC) | Connects to home network (OPNsense's WAN) |
| **vmbr1** | None | Internal-only. Lab VMs talk to each other and OPNsense's LAN |

**Key insight**: `vmbr1` has no physical port. It's a completely isolated network that exists only inside Proxmox. This is exactly what we want, since lab VMs can't accidentally reach your home network directly.

### VirtIO: Why We Use It (and Its Quirks)

VMs can use different types of virtual network adapters, for example:

| Type | How It Works | Performance | Compatibility |
|:-----|:-------------|:------------|:--------------|
| **VirtIO** | Guest knows it's virtualized, cooperates with hypervisor | Excellent | Requires driver support |
| **e1000** | Emulates real Intel NIC hardware | Poor | Works with anything |

VirtIO is **paravirtualized**: the guest OS and hypervisor work together efficiently. OPNsense (FreeBSD) has VirtIO drivers built-in, so we use it for best performance.

> [!WARNING]
> **Hardware offloading must be disabled in VMs.**
>
> **What you need to know:** OPNsense's post-installation tuning will automatically disable hardware offloading. If it's activated, your firewall will randomly drop or corrupt packets.

## DNS: Why OPNsense Runs Its Own Resolver

Your lab VMs need DNS to resolve names like `google.com`. You could point them directly at `8.8.8.8`, but OPNsense runs its own DNS resolver (**Unbound**) for good reasons.

### The Problem with Direct DNS

If lab VMs query external DNS directly:

1. **Every query goes to the internet**, even repeated lookups for the same domain
2. **No caching**: slow, wasteful
3. **No local control**: can't add custom DNS entries for lab hosts
4. **ISP DNS hijacking**: some ISPs intercept DNS for ads/tracking

### The Solution: Local Recursive Resolver

OPNsense runs Unbound, which performs full recursive resolution and caches results:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    DNS RESOLUTION WITH UNBOUND                              │
└─────────────────────────────────────────────────────────────────────────────┘

First query for "google.com":

  DC1                 OPNsense              Root Servers           Google NS
  │                   (Unbound)             (.)(.com)              (ns1.google.com)
  │                      │                      │                       │
  │ "google.com?"        │                      │                       │
  │─────────────────────►│                      │                       │
  │                      │ "Where is .com?"     │                       │
  │                      │─────────────────────►│                       │
  │                      │◄─────────────────────│                       │
  │                      │ "Ask 192.5.6.30"     │                       │
  │                      │                      │                       │
  │                      │ "Where is google.com?"                       │
  │                      │─────────────────────────────────────────────►│
  │                      │◄─────────────────────────────────────────────│
  │                      │ "142.250.185.46"                             │
  │                      │                                              │
  │◄─────────────────────│  [Cache: google.com = 142.250.185.46]        │
  │ "142.250.185.46"     │                                              │

Second query (from any lab VM):

  DC2                 OPNsense
  │                   (Unbound)
  │                      │
  │ "google.com?"        │
  │─────────────────────►│
  │◄─────────────────────│   [Cache hit! No internet query needed]
  │ "142.250.185.46"     │
```

### Why This Matters for the Lab

| Benefit | Lab Impact |
|:--------|:-----------|
| **Caching** | Faster repeated lookups. Windows does a *lot* of DNS queries |
| **DNSSEC** | Validates DNS responses aren't spoofed (important for AD) |
| **Local control** | Later: integrate with AD DNS for `reginleif.io` resolution |
| **Reliable upstreams** | Use Cloudflare (1.1.1.1) and Google (8.8.8.8) instead of flaky ISP DNS |

> [!NOTE]
> **This is temporary DNS configuration.** In Project 3, you'll deploy Active Directory with its own DNS. OPNsense will then forward `reginleif.io` queries to the Domain Controllers while still handling external resolution.

## Key Terms Glossary

| Term | Definition | Used In This Project |
|:-----|:-----------|:---------------------|
| **Gateway** | Device that routes traffic between networks | OPNsense routes between lab (172.16.0.0/24) and home network |
| **NAT** | Network Address Translation: rewrites IPs so private networks can reach the internet | OPNsense rewrites lab IPs to its WAN IP |
| **State Table** | NAT/firewall's memory of active connections, enabling return traffic | How OPNsense knows where to send replies |
| **Bridge** | Virtual switch connecting VMs | `vmbr0` (WAN) and `vmbr1` (LAN) in Proxmox |
| **VirtIO** | Paravirtualized drivers where guest OS cooperates with hypervisor for efficiency | OPNsense uses VirtIO NICs for best performance |
| **pf** | Packet Filter: FreeBSD/OpenBSD stateful firewall engine | OPNsense's underlying firewall technology |
| **Anti-lockout Rule** | Built-in safety rule ensuring LAN access to firewall management | Prevents accidental lockout during configuration |
| **Unbound** | Recursive, caching DNS resolver | OPNsense's DNS service |
| **DNSSEC** | DNS Security Extensions that cryptographically validate DNS responses | Enabled in Unbound to prevent DNS spoofing |
| **Recursive Resolution** | DNS server queries root/TLD/authoritative servers on behalf of clients | Unbound does full recursion (not just forwarding) |

