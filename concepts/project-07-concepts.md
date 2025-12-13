---
title: "Project 7: Multi-Site Network Site-to-Site VPN - Background & Concepts"
parent: "Project 7: Multi-Site Network Site-to-Site VPN"
tags: [concepts, background, vpn, wireguard, site-to-site]
status: completed
---

# Background & Concepts: Multi-Site Network Site-to-Site VPN

## Overview

This project establishes a secure WireGuard VPN tunnel between HQ (Proxmox) and Branch (Hyper-V) sites, enabling Active Directory replication and cross-site communication. Understanding VPN fundamentals, WireGuard's cryptokey routing model, and hub-and-spoke topology is essential for building reliable multi-site infrastructure.

---

## What is a VPN?

A **VPN (Virtual Private Network)** creates an encrypted tunnel over an untrusted network (like the internet), allowing remote sites to communicate as if they were on the same local network.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Without VPN                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   HQ (172.16.0.0/24)              Branch (172.17.0.0/24)        │
│   ┌──────────┐                    ┌──────────┐                  │
│   │   DC1    │      Internet      │   DC2    │                  │
│   │          │ ══════════════════ │          │                  │
│   └──────────┘    (unencrypted,   └──────────┘                  │
│                   AD traffic       │                            │
│                   exposed!)        │                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    With VPN                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   HQ (172.16.0.0/24)              Branch (172.17.0.0/24)        │
│   ┌──────────┐    ┌─────────┐     ┌──────────┐                  │
│   │   DC1    │───►│ Tunnel  │◄────│   DC2    │                  │
│   │          │    │ (enc)   │     │          │                  │
│   └──────────┘    └─────────┘     └──────────┘                  │
│                    │       │                                    │
│                    ▼       ▼                                    │
│                 ╔═══════════╗                                   │
│                 ║ Internet  ║  (only encrypted packets visible) │
│                 ╚═══════════╝                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**VPN Types:**

| Type | Use Case | Example |
|:-----|:---------|:--------|
| **Site-to-Site** | Connect entire networks | HQ ↔ Branch (this project) |
| **Remote Access** | Individual users to network | Road warrior VPN (Project 9) |
| **Hub-and-Spoke** | Multiple sites through central hub | HQ as hub, branches as spokes |

## WireGuard vs Traditional VPNs

WireGuard is a modern VPN protocol designed for simplicity and security. Unlike IPsec (complex, legacy) or OpenVPN (userspace, slower), WireGuard is built into the Linux kernel and uses state-of-the-art cryptography.

| Aspect | WireGuard | IPsec | OpenVPN |
|:-------|:----------|:------|:--------|
| **Released** | 2020 | 1990s | 2001 |
| **Code Size** | ~4,000 lines | ~400,000+ lines | ~100,000 lines |
| **Audit Surface** | Small, easily audited | Complex, many CVEs | Moderate |
| **Performance** | Near wire-speed | Good | Slower (userspace) |
| **Handshake** | 1 round-trip | Multiple exchanges | TLS handshake |
| **Crypto** | Modern (Curve25519, ChaCha20) | Negotiable (risk of weak ciphers) | Configurable |
| **NAT Traversal** | Built-in | Requires NAT-T | Usually works |
| **State** | Stateless protocol | IKE state machine | TLS session |

## VPN Topologies

**Hub-and-Spoke (This Lab):**

```
                    ┌─────────────┐
                    │     HQ      │
                    │   (Hub)     │
                    │ 172.16.0.0  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌────▼────┐ ┌─────▼─────┐
        │  Branch   │ │  Road   │ │  Future   │
        │  (Spoke)  │ │ Warrior │ │   Site    │
        │172.17.0.0 │ │10.200.x │ │           │
        └───────────┘ └─────────┘ └───────────┘
```

| Topology | Pros | Cons |
|:---------|:-----|:-----|
| **Hub-and-Spoke** | Simple config, central control, easy to add sites | Hub is single point of failure, inter-spoke traffic routes through hub |
| **Full Mesh** | Direct site-to-site paths, no hub dependency | Complex (N×(N-1)/2 tunnels), harder to manage |

This lab uses **hub-and-spoke** with HQ as the hub. Branch connects to HQ, and road warrior clients (Project 9) also connect to HQ. Inter-site traffic flows: `Branch → HQ → Destination`.

## NAT Traversal

Most home networks use NAT (Network Address Translation), which can block incoming VPN connections. WireGuard handles this with two mechanisms:

**PersistentKeepalive:**

When a peer is behind NAT, it sends periodic keepalive packets (every 25 seconds by default) to maintain the NAT mapping. Without this, the NAT table entry expires and incoming packets are dropped.

> **Note:** For a detailed explanation of PersistentKeepalive with NAT timeout diagrams, see **Project 9 concepts**. This project covers the basics needed for site-to-site configuration.

**UDP-based protocol:**

WireGuard uses UDP (not TCP), which traverses NAT more reliably. UDP packets don't require connection state, so NAT devices handle them more predictably.

**Lab configuration:**

- HQ OPNsense has a static IP (or port forward from home router)
- Branch OPNsense initiates the connection to HQ's endpoint
- Branch uses `PersistentKeepalive = 25` to maintain the tunnel

---

## Cryptokey Routing

> [!TIP]
> **TL;DR:** In WireGuard, "Allowed IPs" does TWO jobs with ONE setting:
> 1. **Routing:** "Send traffic for these IPs through this tunnel"
> 2. **Filtering:** "Only accept traffic FROM this peer if it claims these source IPs"
>
> This is why WireGuard config is 20 lines instead of IPsec's hundreds.

WireGuard has a unique concept: the **Allowed IPs** field serves two purposes simultaneously.

```
┌──────────────────────────────────────────────────────────────────┐
│                    Allowed IPs Dual Purpose                      │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  HQ → Branch peer has: Allowed IPs = 172.17.0.0/24, 10.200.0.2   │
│                                                                  │
│  1. ROUTING (outbound):                                          │
│     "Send packets destined for 172.17.0.0/24 through Branch"     │
│                                                                  │
│  2. FILTERING (inbound):                                         │
│     "Only accept packets FROM Branch if source is 172.17.x.x"    │
│                                                                  │
│  Result: Simple config = routing table + ACL in one field        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

This is called **cryptokey routing**: the public key (which identifies the peer) is directly associated with allowed IP ranges.

## Key Terms Glossary

| Term | Definition |
|:-----|:-----------|
| **Tunnel** | Encrypted path between two VPN endpoints |
| **Peer** | Remote VPN endpoint (site or client) |
| **Handshake** | Initial key exchange to establish tunnel |
| **Allowed IPs** | WireGuard's combined routing table and ACL |
| **Endpoint** | Public IP:Port where a peer can be reached |
| **Keepalive** | Periodic packets to maintain NAT mappings |
| **MSS Clamping** | Reducing TCP segment size to avoid fragmentation |
| **Cryptokey Routing** | WireGuard's association of public keys with IP ranges |
| **Hub-and-Spoke** | Topology where all sites connect to a central hub |
| **Site-to-Site** | VPN connecting two entire networks |

