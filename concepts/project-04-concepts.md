---
title: "Project 4: Deploy Royal Server Gateway - Background & Concepts"
parent: "Project 4: Deploy Royal Server Gateway"
tags: [concepts, background, royal-ts, remote-access, bastion-host, gateway]
status: completed
---

# Background & Concepts: Deploy Royal Server Gateway

## Overview

**Royal TS** is a remote connection management client (like mRemoteNG or RDCMan) that stores and organizes your RDP, SSH, VNC, and other remote connections. **Royal Server** is its companion server component that acts as a secure gateway and management endpoint.

This project implements an enterprise remote access pattern using Royal Server as a **bastion host** - a hardened server that acts as a single point of entry for accessing internal infrastructure.

---

## Royal TS vs Royal Server

### Royal TS (Client)

- **Desktop application** (Windows/macOS)
- Organizes connection documents (credentials, server lists, folders)
- Supports RDP, SSH, VNC, HTTP, PowerShell, and custom protocols
- Think: "fancy RDP client with folders and saved credentials"

### Royal Server (Gateway)

- **Windows service** that runs on a domain-joined server
- Acts as a **secure gateway** for tunneling connections
- Acts as a **management endpoint** for executing remote tasks
- Integrates with Active Directory for authentication/authorization

---

## Gateway Architecture

### Direct Connection Model (Traditional)

```text
┌──────────────┐                           ┌──────────────┐
│   Your PC    │────────────────────────►  │  Target VM   │
│  Royal TS    │   Direct RDP/SSH          │  (Internal)  │
└──────────────┘                           └──────────────┘

Problems:
- Must expose every VM to your network (or VPN)
- Firewall rules for each VM
- No centralized audit trail
- Credential sprawl (passwords everywhere)
```

### Gateway Model (Royal Server)

```text
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Your PC    │────────►│ Royal Server │────────►│  Target VM   │
│  Royal TS    │  HTTPS  │   Gateway    │  RDP    │  (Internal)  │
└──────────────┘  Tunnel └──────────────┘         └──────────────┘
                          P-WIN-SRV1
                          172.16.0.11

Benefits:
- Single point of entry (one firewall rule)
- Royal Server initiates outbound connections to targets
- Centralized credential management
- Audit logging of all connections
- Can reach VMs that aren't directly routable
```

---

## Why Use a Gateway?

### Security Benefits

| Concern | Direct Connection | Gateway Pattern |
|:--------|:-----------------|:----------------|
| **Attack Surface** | Every VM exposed | Only gateway exposed |
| **Credential Exposure** | Stored on client | Stored on gateway (or vault) |
| **Audit Trail** | Per-VM logs | Centralized logging |
| **Network Segmentation** | Requires complex routing | Gateway bridges networks |
| **Compromise Scope** | Full network access | Limited to gateway permissions |

### Operational Benefits

1. **Simplified Firewall Rules**: One rule to Royal Server (TCP 54899, TCP 22) instead of rules for every VM
2. **Credential Rotation**: Update passwords on Royal Server once, not on every client
3. **Jumpbox Replacement**: No need to RDP to a jumpbox, then RDP again to targets
4. **Cross-Network Access**: Gateway can reach VLANs/subnets client can't directly access
5. **Management Tasks**: Execute PowerShell, check services, read event logs without direct WinRM

---

## Enterprise Remote Access Patterns

### Pattern Comparison

| Pattern | Implementation | Use Case |
|:--------|:---------------|:---------|
| **Direct Access** | VPN to network, connect directly | Small networks, trusted users |
| **Bastion Host** | SSH to bastion, then SSH to targets | Linux-heavy environments |
| **Jump Server** | RDP to jump server, then RDP to targets | Windows environments (manual) |
| **Gateway Service** | Client connects via gateway service | Automated, audited access |
| **Zero Trust** | Identity-aware proxy (BeyondCorp) | Modern cloud-native architectures |

**Royal Server** implements the **Gateway Service** pattern, which is more automated and user-friendly than manual jump servers but simpler than full zero-trust architectures.

---

## Security Model

### Authentication & Authorization Flow

```text
1. User opens Royal TS client
   │
   ├─► Connects to Royal Server (HTTPS/54899)
   │   └─► Royal Server authenticates via AD
   │
2. Royal Server checks AD group membership
   │
   ├─► Is user in "RoyalServer-GatewayUsers"?
   │   └─► YES: Allow gateway tunneling
   │   └─► NO:  Deny connection
   │
3. User initiates RDP via gateway
   │
   ├─► Royal Server receives request
   │   └─► Opens RDP connection to target VM
   │   └─► Tunnels traffic back to client
   │
4. Target VM sees connection from Royal Server (not client)
   └─► Logs show 172.16.0.11 (P-WIN-SRV1) as source
```

### Service Account Design

Royal Server runs as a **domain service account** (`svc_RoyalServer`):

- **Why not Local System?** Local System cannot read AD groups or authenticate to remote systems
- **Why not Domain Admin?** Least privilege - service account only needs specific permissions
- **What permissions does it need?**
  - Local Admin on P-WIN-SRV1 (to read security groups)
  - Read access to AD (automatic for any domain account)
  - Delegated permissions to target VMs (for management tasks)

### Group-Based Access Control

Three-tier permission model:

| AD Group | Local Group | Permissions |
|:---------|:------------|:------------|
| `RoyalServer-Admins` | Royal Server Administrators | Configure gateway, manage connections, view all logs |
| `RoyalServer-Users` | Royal Server Users | Read-only access to server status, logs, services |
| `RoyalServer-GatewayUsers` | Royal Server Gateway Users | Tunnel RDP/SSH through gateway |

**Why nest AD groups in local groups?**

- Royal Server's permission system is based on local Windows groups
- Nesting AD groups inside local groups bridges the two systems
- Change AD membership, no need to reconfigure Royal Server

---

## Bastion Host Considerations

### Why P-WIN-SRV1 is a Bastion

A **bastion host** is a server specifically designed to withstand attacks and provide controlled access to internal resources:

1. **Hardened**: Minimal services, regular patching, restricted local admin access
2. **Logged**: All connections audited and logged
3. **Isolated**: Lives in a DMZ or management VLAN, not general-purpose server VLAN
4. **Single-Purpose**: Doesn't host unrelated services (web, DB, file shares)

### Security Hardening (Beyond This Project)

Production bastion hosts typically include:

- **Multi-factor authentication** (MFA) for gateway access
- **Just-in-time access** (temporary privilege elevation)
- **Session recording** (video recording of RDP sessions)
- **IP whitelisting** (only accept connections from known IPs)
- **Threat detection** (intrusion detection on gateway traffic)

For a homelab, the current design (AD authentication + group-based access) is sufficient. In production, you'd layer on additional controls.

---

## When to Use Royal Server Gateway

### Good Use Cases

✅ **Accessing VMs across VLANs/subnets** - Gateway bridges network segments
✅ **Remote access without VPN** - Expose only gateway, not entire network
✅ **Centralized credential management** - Store creds on server, not client
✅ **Management tasks** - Check services, event logs without WinRM
✅ **Audit trail** - See who connected to what and when

### When Not to Use It

❌ **Direct network access required** - Some apps need direct routing, not tunneling
❌ **High-bandwidth workloads** - Video streaming, large file transfers (tunneling adds overhead)
❌ **Many concurrent users** - Gateway becomes bottleneck (consider multiple gateways or VPN)
❌ **Non-Windows environments** - Royal Server is Windows-only (use OpenSSH bastion instead)

---

## Alternative Solutions

If Royal Server doesn't fit your needs:

| Solution | Platform | Cost | Best For |
|:---------|:---------|:-----|:---------|
| **Royal Server** | Windows | $$ | Mixed environments, Windows-heavy |
| **Guacamole** | Linux | Free | Web-based access, no client install |
| **Teleport** | Linux | Free/$$$ | Modern SSH/Kubernetes access |
| **OpenSSH Bastion** | Linux | Free | SSH-only environments |
| **Azure Bastion** | Cloud | $$$ | Azure-native VMs |
| **VPN (WireGuard/OpenVPN)** | Any | Free | Full network access, not just remote desktop |

**Why Royal Server for this lab?**

- Integrates with Active Directory (good practice for AD authentication patterns)
- Commercial product (learn enterprise tooling, not just open source)
- Gateway pattern is common in enterprise environments
- Optional project - demonstrates advanced remote access concepts

---

## Key Terms Glossary

| Term | Definition |
|:-----|:-----------|
| **Royal TS** | Desktop client for managing remote connections (RDP, SSH, VNC, and more) |
| **Royal Server** | Windows service acting as secure gateway and management endpoint |
| **Bastion host** | Hardened server providing controlled, audited access to internal resources |
| **Gateway** | Intermediary server that tunnels connections to internal targets |
| **Jump server** | Server used as stepping stone to access other systems (manual RDP-to-RDP) |
| **Service account** | Domain account running Windows services with specific, limited permissions |
| **Zero Trust** | Security model requiring identity verification for every access request, regardless of network location |
