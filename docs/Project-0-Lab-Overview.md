---
title: "Project 0: Lab Overview"
tags: [overview, architecture, reference]
sites: [hq, branch]
status: completed
---

## Goal

Provide a comprehensive introduction to the reginleif.io enterprise homelab, including network architecture, machine inventory, and a roadmap of all projects. Use this document as your starting point and reference guide.

---

## What is This Lab?

This lab implements a fully functional **multi-site enterprise network** simulating a corporate headquarters and branch office environment. The goal is to mirror real corporate infrastructure patterns, not just "spin up a VM," but architect, secure, and document a production-grade environment.

**Key features:**

- Site-to-Site VPN connecting two physically separate sites
- Active Directory forest with cross-site replication
- VLAN segmentation for network isolation and security
- Centralized DHCP/DNS with dynamic registration
- Volume activation using hybrid ADBA/KMS strategy
- Secure remote access for road warrior administration

**Future direction:** The lab is evolving towards a cloud-hybrid architecture with Azure AD integration, hybrid identity, and cloud-based services extending the on-premises infrastructure.

---

## Architecture Overview

### Technology Stack

| Category | Technologies |
|----------|-------------|
| **Virtualization** | Proxmox VE, Windows Hyper-V |
| **Firewalls** | OPNsense (FreeBSD) |
| **Directory Services** | Windows Server 2022, Active Directory, Group Policy |
| **Networking** | WireGuard VPN, VLANs, NAT, DNS, DHCP |
| **Licensing** | KMS (Key Management Service), ADBA (Active Directory Based Activation) |
| **Automation** | PowerShell, Bash scripting |
| **Remote Access** | Royal Server, RDP, SSH |

### Quick Reference (ASCII)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Home Network (WAN)                                │
│                           192.168.1.0/24                                    │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
        ┌───────────────────────────┴───────────────────────┐
        │                                                   │
        ▼                                                   ▼
┌───────────────────────────────┐         ┌───────────────────────────────┐
│   SITE A: HQ (Proxmox)        │         │   SITE B: BRANCH (Hyper-V)    │
│   OPNsenseHQ                  │◄═══════►│   OPNsenseBranch              │
│   WAN: 192.168.1.240          │WireGuard│   WAN: 192.168.1.245          │
├───────────────────────────────┤  VPN    ├───────────────────────────────┤
│                               │         │                               │
│ VLAN 1 (Native) - Unused      │         │ VLAN 1 (Native) - Unused      │
│   Blackhole (no IPs)          │         │   Blackhole (no IPs)          │
│                               │         │                               │
│ VLAN 5 - Infrastructure       │         │ VLAN 5 - Infrastructure       │
│   172.16.5.0/24               │         │   172.17.5.0/24               │
│   ├─ .1  Gateway              │         │   ├─ .1  Gateway              │
│   └─ .10 P-WIN-DC1            │         │   └─ .10 H-WIN-DC2            │
│                               │         │                               │
│ VLAN 10 - Clients             │         │ VLAN 10 - Clients             │
│   172.16.10.0/24              │         │   172.17.10.0/24              │
│   ├─ .1  Gateway              │         │   ├─ .1  Gateway              │
│   └─ .30-.254 DHCP            │         │   └─ .30-.254 DHCP            │
│                               │         │                               │
│ VLAN 20 - Servers             │         │ VLAN 20 - Servers             │
│   172.16.20.0/24              │         │   172.17.20.0/24              │
│   ├─ .1  Gateway              │         │   └─ .1  Gateway              │
│   ├─ .12 P-WIN-SRV2           │         │                               │
│   ├─ .13 P-WIN-SRV3           │         │                               │
│   ├─ .14 P-WIN-SRV4           │         │                               │
│   └─ .15 P-WIN-ROOTCA         │         │                               │
│                               │         │                               │
│ VLAN 99 - Management          │         │ VLAN 99 - Management          │
│   172.16.99.0/24              │         │   172.17.99.0/24              │
│   ├─ .1  Gateway              │         │   └─ .1  Gateway              │
│   └─ .11 P-WIN-SRV1           │         │                               │
│                               │         │                               │
└───────────────────────────────┘         └───────────────────────────────┘
        ▲
        │ WireGuard (Road Warrior)
        │
┌───────────────────────┐
│ Admin PC              │
│ 10.200.0.10           │
└───────────────────────┘
```

## Hardware & Software

| Component | HQ Site | Branch Site |
|-----------|---------|-------------|
| **Hypervisor** | Proxmox VE 8.x | Windows Hyper-V |
| **Firewall** | OPNsense (FreeBSD) | OPNsense (FreeBSD) |
| **Server OS** | Windows Server 2022 | Windows Server 2022 |
| **Client OS** | Windows 10/11 | Windows 10/11 |
| **Productivity** | Office LTSC 2024 | Office LTSC 2024 |

---

## Network Architecture

### Site Summary

| Site | Hypervisor | WAN IP | Subnet Range | Gateway |
|------|------------|--------|--------------|---------|
| HQ | Proxmox VE | 192.168.1.240 | 172.16.0.0/16 | OPNsenseHQ |
| Branch | Hyper-V | 192.168.1.245 | 172.17.0.0/16 | OPNsenseBranch |
| WireGuard Tunnel | — | — | 10.200.0.0/24 | — |

### VLAN Architecture

| VLAN | Name | HQ Subnet | Branch Subnet | Purpose | DHCP |
|------|------|-----------|---------------|---------|------|
| 1 | Default/Unused | N/A | N/A | Blackhole VLAN (untagged on trunks) | No |
| 5 | Infrastructure | 172.16.5.0/24 | 172.17.5.0/24 | Domain Controllers, DNS, DHCP, Gateways | No |
| 10 | Clients | 172.16.10.0/24 | 172.17.10.0/24 | Windows 10/11 workstations | Yes (.30-.254) |
| 20 | Servers | 172.16.20.0/24 | 172.17.20.0/24 | Member servers (Royal Server, KMS, CA, NPS/RADIUS, WDS/MDT) | No |
| 99 | Management | 172.16.99.0/24 | 172.17.99.0/24 | Admin access, out-of-band management | No |

### IP Addressing Convention

- **Gateway:** x.x.VLAN.1
- **Static IPs:** x.x.VLAN.2-29
- **DHCP Pool:** x.x.VLAN.30-254 (Clients VLAN only)
- **Third octet = VLAN ID** (e.g., VLAN 5 uses .5.x, VLAN 20 uses .20.x)

---

## Machine Inventory

### HQ Site (Proxmox)

| Hostname | IP Address | VLAN | Role | Description |
|----------|------------|------|------|-------------|
| OPNsenseHQ | 172.16.5.1 | 5 | Gateway/Firewall | Primary firewall and router for HQ site |
| P-WIN-DC1 | 172.16.5.10 | 5 | Domain Controller | Primary DC, DNS, DHCP, Forest Root |
| P-WIN-SRV1 | 172.16.99.11 | 99 | Royal Server | Remote access gateway (bastion host) |
| P-WIN-SRV2 | 172.16.20.12 | 20 | KMS | Key Management Service (Volume Activation) |
| P-WIN-SRV3 | 172.16.20.13 | 20 | Enterprise Subordinate CA | Enterprise Subordinate CA (REGINLEIF-SUB-CA) |
| P-WIN-SRV4 | 172.16.20.14 | 20 | NPS (RADIUS), WDS/MDT | Network Policy Server, OS deployment |
| P-WIN-ROOTCA | 172.16.20.15 | 20 | Offline Root CA | Standalone Root CA (REGINLEIF-ROOT-CA) - Offline |

### Branch Site (Hyper-V)

| Hostname | IP Address | VLAN | Role | Description |
|----------|------------|------|------|-------------|
| OPNsenseBranch | 172.17.5.1 | 5 | Gateway/Firewall | Primary firewall for Branch site |
| H-WIN-DC2 | 172.17.5.10 | 5 | Domain Controller | Secondary DC, DNS, DHCP for Branch site |

### WireGuard Peers

| Hostname | IP Address | Role | Description |
|----------|------------|------|-------------|
| Admin PC | 10.200.0.10 | Road Warrior | Admin Workstation (Home LAN) |

---

## Project Roadmap

### Dependency Overview

```
Foundation (Single Site)
┌─────┐   ┌─────┐   ┌─────┐   ┌─────┐
│ P1  │──►│ P2  │──►│ P3  │──►│ P4  │
└─────┘   └─────┘   └─────┘   └─────┘
OPNsense   WinVM     AD        Royal
  HQ       Setup   Bootstrap   Server

Multi-Site
┌─────┐   ┌─────┐   ┌─────┐   ┌─────┐   ┌─────┐
│ P5  │──►│ P6  │──►│ P7  │──►│ P8  │──►│ P9  │
└─────┘   └─────┘   └─────┘   └─────┘   └─────┘
OPNsense   DC2      Site-to   Multi     Road
 Branch    Prep     Site VPN  Site AD   Warrior

Infrastructure Services
┌─────┐   ┌─────┐   ┌─────┐
│ P10 │──►│ P11 │──►│ P12 │
└─────┘   └─────┘   └─────┘
DHCP       VLANs    Volume
Migration           Activation

Enterprise Services
┌─────┐   ┌─────┐   ┌─────┐
│ P13 │──►│ P14 │──►│ P15 │
└─────┘   └─────┘   └─────┘
 PKI      RADIUS     WDS
          /NPS       MDT

Operations
┌─────┐
│ P16 │
└─────┘
Management
Network
```

### Project Summary

| # | Project | Key Technologies | Status |
|---|---------|------------------|--------|
| 1 | [OPNsense Gateway (HQ)](Project-1-Installing-OPNsense-on-Proxmox.md) | OPNsense, Proxmox, NAT | Completed |
| 2 | [Windows Core VM Setup](Project-2-Proxmox-Windows-Core-Setup.md) | Windows Server, VirtIO | Completed |
| 3 | [Active Directory Bootstrap](Project-3-Active-Directory-Bootstrap.md) | AD DS, DNS, DCPROMO | Completed |
| 4 | [Royal Server Gateway](Project-4-Deploy-Royal-Server-Gateway.md) | Royal Server, AD Integration | Completed |
| 5 | [OPNsense on Hyper-V (Branch)](Project-5-Installing-OPNsense-on-HyperV.md) | OPNsense, Hyper-V | Completed |
| 6 | [Prepare DC2 for Site-to-Site](Project-6-Prepare-DC2-on-HyperV-for-Site-to-Site.md) | Windows Server, Hyper-V | Completed |
| 7 | [Site-to-Site VPN](Project-7-Multi-Site-Network-Site-to-Site-VPN.md) | WireGuard, Routing | Completed |
| 8 | [Multi-Site AD Configuration](Project-8-Multi-Site-Active-Directory.md) | AD Sites & Services, Replication | Completed |
| 9 | [Road Warrior VPN](Project-9-Remote-Access-VPN-Road-Warrior.md) | WireGuard, Remote Access | Completed |
| 10 | [DHCP Migration to DCs](Project-10-DHCP-Migration-to-Domain-Controllers.md) | AD-integrated DHCP, Dynamic DNS | Completed |
| 11 | [VLAN Network Segmentation](Project-11-VLAN-Network-Segmentation.md) | VLANs, Inter-VLAN Routing | Completed |
| 12 | [Volume Activation (ADBA + KMS)](Project-12-KMS-Key-Management-Service.md) | KMS, ADBA, VAMT | Completed |
| 13 | [Certificate Services (PKI)](Project-13-Certificate-Services-PKI.md) | Two-tier PKI, Offline Root CA | Planned |
| 14 | [RADIUS/NPS Authentication](Project-14-RADIUS-NPS-Authentication.md) | NPS, RADIUS, EAP | Planned |
| 15 | [Windows Deployment Services](Project-15-Windows-Deployment-Services-MDT.md) | WDS, MDT, PXE Boot | Planned |
| 16 | [Management Network Setup](Project-16-Management-Network-Setup.md) | Bastion Host, VPN Restriction, Monitoring Prep | In Progress |

### Learning Paths

| Path | Projects | Description |
|------|----------|-------------|
| **Minimal Lab** | P1, P2, P3 | Single-site AD with firewall |
| **Full Multi-Site** | P1-P9 | Complete two-site infrastructure with VPN |
| **Complete Enterprise** | P1-P15 | All services including PKI and deployment |
| **PKI Focus** | P1-P3, P11, P13 | Certificate infrastructure path |
| **Deployment Focus** | P1-P3, P11, P15 | OS deployment infrastructure |

> [!TIP]
> Projects are designed to be completed in order. Each builds on previous configurations and knowledge.

---

## Domain Information

| Property | Value |
|----------|-------|
| Forest/Domain Name | reginleif.io |
| NetBIOS Name | REGINLEIF |
| Forest Functional Level | Windows Server 2016 |

### Naming Conventions

| Prefix | Meaning | Examples |
|--------|---------|----------|
| P- | Proxmox VM | P-WIN-DC1, P-WIN-SRV1 |
| H- | Hyper-V VM | H-WIN-DC2 |
| DC | Domain Controller | P-WIN-DC1, H-WIN-DC2 |
| SRV | Member Server | P-WIN-SRV1 through P-WIN-SRV4 |
| ROOTCA | Root Certificate Authority | P-WIN-ROOTCA |

---

## Additional Resources

### Concepts
Background reading for each project is available in the `/concepts` directory.
