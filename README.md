REGINLEIF.IO — Enterprise Homelab

> A multi-site Active Directory infrastructure simulating a corporate headquarters and branch office environment, built to demonstrate real-world sysadmin and network engineering skills, evolving towards a cloud-hybrid architecture.

[![Live Site](https://img.shields.io/badge/Live%20Site-lab.reginleif.io-brightgreen?logo=vercel)](https://lab.reginleif.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Status](https://img.shields.io/badge/Status-Active-green)
![Platform](https://img.shields.io/badge/Platform-Proxmox%20%7C%20Hyper--V-orange)

<br>

<p align="center">
  <strong>
    <a href="https://lab.reginleif.io/">Explore the full documentation at lab.reginleif.io</a>
  </strong>
</p>

---

## Overview

This project implements a fully functional **multi-site enterprise network** with:

- **Site-to-Site VPN** connecting two physically separate sites
- **Active Directory** forest with cross-site replication
- **VLAN segmentation** for network isolation and security
- **Centralized DHCP/DNS** with dynamic registration
- **Volume activation** using hybrid ADBA/KMS strategy
- **Secure remote access** for road warrior administration

The goal is to mirror real corporate infrastructure patterns and not just "spin up a VM," but architect, secure, and document a production-grade environment.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Home Network (WAN)                                │
│                           192.168.1.0/24                                    │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │
        ┌───────────────────────┴───────────────────────┐
        │                                               │
        ▼                                               ▼
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
│   ├─ .11 P-WIN-SRV1           │         │                               │
│   ├─ .12 P-WIN-SRV2           │         │                               │
│   ├─ .13 P-WIN-SRV3           │         │                               │
│   ├─ .14 P-WIN-SRV4           │         │                               │
│   └─ .15 P-WIN-ROOTCA         │         │                               │
│                               │         │                               │
│ VLAN 99 - Management          │         │ VLAN 99 - Management          │
│   172.16.99.0/24              │         │   172.17.99.0/24              │
│   └─ .1  Gateway              │         │   └─ .1  Gateway              │
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

---

## Technology Stack

| Category | Technologies |
|----------|-------------|
| **Virtualization** | Proxmox VE, Windows Hyper-V |
| **Firewalls** | OPNsense (FreeBSD) |
| **Directory Services** | Windows Server 2022, Active Directory, Group Policy |
| **Networking** | WireGuard VPN, VLANs, NAT, DNS, DHCP |
| **Licensing** | KMS (Key Management Service), ADBA (Active Directory Based Activation) |
| **Automation** | PowerShell, Bash scripting |
| **Remote Access** | Royal Server, RDP, SSH |

---

## Project Documentation

Each component is documented as a standalone project with step-by-step instructions and some insights:

| # | Project | Description |
|:---|:---|:---|
| 1 | [OPNsense Gateway (HQ)](docs/Project-1-Installing-OPNsense-on-Proxmox.md) | Deploy OPNsense on Proxmox as HQ firewall |
| 2 | [Windows Core VM Setup](docs/Project-2-Proxmox-Windows-Core-Setup.md) | High-performance Windows Server VMs with VirtIO |
| 3 | [Active Directory Bootstrap](docs/Project-3-Active-Directory-Bootstrap.md) | Promote first DC, create forest root |
| 4 | [Royal Server Gateway](docs/Project-4-Deploy-Royal-Server-Gateway.md) | Secure management gateway with AD integration |
| 5 | [OPNsense on Hyper-V (Branch)](docs/Project-5-Installing-OPNsense-on-HyperV.md) | Deploy OPNsense on Hyper-V for branch site |
| 6 | [Prepare DC2 for Site-to-Site](docs/Project-6-Prepare-DC2-on-HyperV-for-Site-to-Site.md) | Configure branch DC before VPN establishment |
| 7 | [Site-to-Site VPN](docs/Project-7-Multi-Site-Network-Site-to-Site-VPN.md) | WireGuard tunnel connecting both sites |
| 8 | [Multi-Site AD Configuration](docs/Project-8-Multi-Site-Active-Directory.md) | AD Sites & Services, cross-site replication |
| 9 | [Road Warrior VPN](docs/Project-9-Remote-Access-VPN-Road-Warrior.md) | Remote admin access via WireGuard |
| 10 | [DHCP Migration to DCs](docs/Project-10-DHCP-Migration-to-Domain-Controllers.md) | AD-integrated DHCP with dynamic DNS |
| 11 | [VLAN Network Segmentation](docs/Project-11-VLAN-Network-Segmentation.md) | Implement VLANs for network segmentation |
| 12 | [Volume Activation (ADBA + KMS)](docs/Project-12-KMS-Key-Management-Service.md) | Hybrid activation using ADBA and KMS |
| 13 | [Certificate Services (PKI)](docs/Project-13-Certificate-Services-PKI.md) | Two-tier PKI with offline Root CA |
| 14 | [RADIUS/NPS Authentication](docs/Project-14-RADIUS-NPS-Authentication.md) | Centralized firewall authentication via AD |
| 15 | [Windows Deployment Services + MDT](docs/Project-15-Windows-Deployment-Services-MDT.md) | Lite-touch OS deployment infrastructure |

---

## Documentation Structure

This repository separates **procedural documentation** from **conceptual education** to support both learning and execution workflows.

### Project Files (`docs/Project-*.md`)
Step-by-step procedural guides for implementing each project. Focus on execution and configuration.

### Concept Files (`concepts/project-*-concepts.md`)
Educational background content explaining the "why" and "what" behind each project.

**Why separate concepts from procedures?**
- **Focused learning:** Read concepts when learning, skip when executing
- **Maintainability:** Update conceptual content without touching procedures
- **Reusability:** Reference concepts across multiple projects
- **Clarity:** Main project files focus on "how to do," concept files explain "why and what"

---

## License

This project is licensed under the MIT License. Documentation and configurations are provided as-is for educational purposes.

---

## Author

**Daniel Deutsch**  
Operations Engineer | System & Network Administrator

[![LinkedIn](https://img.shields.io/badge/LinkedIn-daniel--deutsch25-blue?logo=linkedin)](https://linkedin.com/in/daniel-deutsch25)
[![GitHub](https://img.shields.io/badge/GitHub-Reginleif88-black?logo=github)](https://github.com/Reginleif88)
