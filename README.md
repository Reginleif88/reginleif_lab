REGINLEIF.IO — Enterprise Homelab

> A multi-site Active Directory infrastructure simulating a corporate headquarters and branch office environment, built to demonstrate real-world sysadmin and network engineering skills. The project is evolving towards a cloud-hybrid architecture.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Status](https://img.shields.io/badge/Status-Active-green)
![Platform](https://img.shields.io/badge/Platform-Proxmox%20%7C%20Hyper--V-orange)

---

## Overview

This project implements a fully functional **multi-site enterprise network** with:

- **Site-to-Site VPN** connecting two physically separate sites
- **Active Directory** forest with cross-site replication
- **Centralized DHCP/DNS** with dynamic registration
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
┌───────────────────────┐                     ┌───────────────────────┐
│   SITE A: HQ          │                     │   SITE B: BRANCH      │
│   Proxmox VE          │                     │   Windows Hyper-V     │
│   172.16.0.0/24       │                     │   172.17.0.0/24       │
├───────────────────────┤                     ├───────────────────────┤
│ OPNsenseHQ            │◄═══ WireGuard ════►│ OPNsenseBranch        │
│   WAN: 192.168.1.240  │     VPN Tunnel      │   WAN: 192.168.1.245  │
│   LAN: 172.16.0.1     │   10.200.0.0/24     │   LAN: 172.17.0.1     │
├───────────────────────┤                     ├───────────────────────┤
│ P-WIN-DC1             │◄─── AD Replication ─►│ H-WIN-DC2             │
│   172.16.0.10         │                     │   172.17.0.10         │
│   Primary DC + DNS    │                     │   Secondary DC + DNS  │
├───────────────────────┤                     ├───────────────────────┤
│ P-WIN-SRV1            │                     │                       │
│   172.16.0.11         │                     │                       │
│   Royal Server GW     │                     │                       │
└───────────────────────┘                     └───────────────────────┘
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
| **Virtualization** | Proxmox VE, Windows Hyper-V, ESXi/vSphere |
| **Firewalls** | OPNsense (FreeBSD) |
| **Directory Services** | Windows Server 2022, Active Directory, Group Policy |
| **Networking** | WireGuard VPN, VLANs, NAT, DNS, DHCP |
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

---

## License

This project is licensed under the MIT License. Documentation and configurations are provided as-is for educational purposes.

---

## Author

**Daniel Deutsch**  
Operations Engineer | System & Network Administrator

[![LinkedIn](https://img.shields.io/badge/LinkedIn-daniel--deutsch25-blue?logo=linkedin)](https://linkedin.com/in/daniel-deutsch25)
[![GitHub](https://img.shields.io/badge/GitHub-Reginleif88-black?logo=github)](https://github.com/Reginleif88)
