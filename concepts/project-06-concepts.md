---
title: "Project 6: Prepare DC2 on HyperV for Site-to-Site - Background & Concepts"
parent: "Project 6: Prepare DC2 on HyperV for Site-to-Site"
tags: [concepts, background, active-directory, hyper-v, multi-dc, replication]
status: completed
---

# Background & Concepts: Prepare DC2 on HyperV for Site-to-Site

## Overview

This project prepares the infrastructure for **multi-site Active Directory** by deploying a secondary domain controller at the branch office. Understanding why multiple DCs are critical, how AD replication works, and why certain configuration choices (like static memory) are non-negotiable will help you build reliable, production-like infrastructure.

---

## Why Multiple Domain Controllers?

### Single DC vs Multi-DC

A **single Domain Controller** environment is a **single point of failure**:

| Scenario | Single DC | Multi-DC |
|:---------|:----------|:---------|
| **DC crashes** | No authentication, network down | Other DCs handle auth, transparent to users |
| **DC patching** | Maintenance window = downtime | Patch DCs sequentially, zero downtime |
| **DC compromise** | Total domain compromise | Contain breach, isolate compromised DC |
| **Network partition** | Branch loses connectivity = no auth | Branch DC handles local auth |
| **Disaster** | Lose DC = lose domain | Rebuild from remaining DCs |

### Benefits of Multiple DCs

**High Availability:**

- **99.9% uptime**: With 2+ DCs, you can patch/reboot without downtime
- **Load balancing**: Clients spread auth requests across DCs
- **Fault tolerance**: One DC failure doesn't impact users

**Geographic Distribution:**

- **Local authentication**: Branch users authenticate to local DC (fast)
- **WAN resilience**: Branch operates during WAN outages
- **Reduced latency**: DNS queries, Group Policy updates happen locally

**Business Continuity:**

- **Disaster recovery**: Lose a data center? Other sites still have DCs
- **Ransomware resilience**: Isolated DC can restore domain after crypto-locker
- **Backup strategy**: Each DC is a live backup of the directory

### Recommended DC Count

| Environment | Minimum DCs | Recommended | Notes |
|:------------|:------------|:------------|:------|
| **Single site** | 2 | 2-3 | Two for HA, third for RODC/backup |
| **Two sites** | 2 | 3-4 | One per site + backup DC at main site |
| **Multiple sites** | N+1 | 2N | One per site + one backup per region |
| **Large enterprise** | 10+ | 20+ | DCs in every office, multiple per DC |

---

## Dynamic Memory vs Static Memory

### What is Dynamic Memory?

**Dynamic Memory** is a Hyper-V feature that allows VMs to share RAM:

```text
Without Dynamic Memory:
┌────────────────────────────────────┐
│  Host: 64 GB RAM                   │
│  ┌──────┐ ┌──────┐ ┌──────┐        │
│  │ VM1  │ │ VM2  │ │ VM3  │        │
│  │ 8 GB │ │ 8 GB │ │ 8 GB │        │  ← Each VM has fixed allocation
│  │(uses │ │(uses │ │(uses │        │    (24 GB total reserved)
│  │ 3 GB)│ │ 4 GB)│ │ 2 GB)│        │
│  └──────┘ └──────┘ └──────┘        │
│  40 GB RAM wasted!                 │
└────────────────────────────────────┘

With Dynamic Memory:
┌────────────────────────────────────┐
│  Host: 64 GB RAM                   │
│  ┌────┐   ┌────┐   ┌────┐          │
│  │VM1 │   │VM2 │   │VM3 │          │  ← VMs share RAM pool
│  │3GB │   │4GB │   │2GB │          │    (only 9 GB used)
│  └────┘   └────┘   └────┘          │
│  55 GB RAM available for other VMs │
└────────────────────────────────────┘
```

### Why Dynamic Memory is DANGEROUS for Domain Controllers

The warning in the project guide is **critical**:

> **Microsoft explicitly recommends against using Dynamic Memory for production Domain Controllers.**

**Reason #1: Database Corruption**

```text
┌──────────────────────────────────────────────────────────┐
│  Timeline of a Memory Ballooning Event                   │
├──────────────────────────────────────────────────────────┤
│  T+0s:  DC2 has 4 GB allocated                           │
│         NTDS.dit database write in progress              │
│                                                          │
│  T+1s:  Host detects memory pressure (another VM needs   │
│         RAM). Balloon driver reclaims 2 GB from DC2      │
│                                                          │
│  T+2s:  DC2 now has only 2 GB, NTDS.dit write is         │
│         interrupted mid-transaction                      │
│                                                          │
│  T+3s:  NTDS.dit database is now corrupted               │
│         AD replication fails, domain is unstable         │
└──────────────────────────────────────────────────────────┘
```

**Reason #2: Replication Failures**

AD replication involves:
- Reading large chunks of NTDS.dit into memory
- Compressing changes
- Transmitting to remote DCs
- Verifying checksums

**If memory is reclaimed mid-replication:**
- Replication fails with "not enough memory" errors
- Directory inconsistencies between sites
- Manual replication repairs required

**Reason #3: Authentication Delays**

Domain Controllers cache credentials, Kerberos tickets, and group membership in RAM:

| Scenario | Static Memory | Dynamic Memory |
|:---------|:--------------|:---------------|
| **Normal auth** | ~50ms (cached) | ~50ms (cached) |
| **Memory pressure** | Still ~50ms | Cache evicted, 2-10 seconds (re-query) |
| **Result** | Consistent performance | Random auth failures |

**Reason #4: Time Synchronization Issues**

Memory pressure can cause CPU starvation, leading to:
- Time sync service (W32Time) missing ticks
- Clock drift on DC
- Kerberos tickets rejected (5-minute tolerance exceeded)
- **Entire domain authentication breaks**

### When Dynamic Memory IS Safe

Dynamic Memory works well for:

✅ **Application servers** (IIS, SQL with proper config)
✅ **Workstations** (VDI desktops)
✅ **Development VMs** (non-critical)
✅ **Linux VMs** (generally handle memory pressure better)

**NEVER use for:**

❌ **Domain Controllers**
❌ **Database servers** (unless specifically configured for it)
❌ **Clustered services** (failover cluster nodes)
❌ **Exchange servers**
❌ **Critical infrastructure** (DHCP, DNS when tightly coupled with AD)

---

## Active Directory Replication Process

```text
┌─────────────────────────────────────────────────────────┐
│  DC Promotion Process                                   │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  1. Verify domain exists                                │
│                                                         │
│  2. Authenticate with domain admin credentials          │
│                                                         │
│  3. Create computer account in Domain Controllers OU    │
│                                                         │
│  4. Replicate NTDS.dit database                         │
│                                                         │
│  5. Replicate SYSVOL (Group Policy files)               │
│                                                         │
│  6. Update DNS records                                  │
│                                                         │
│  7. Establish replication agreements                    │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Network Requirements:**

| Protocol | Port | Purpose |
|:---------|:-----|:--------|
| **DNS** | 53/TCP+UDP | Locate existing DCs |
| **Kerberos** | 88/TCP+UDP | Authentication |
| **RPC** | 135/TCP + dynamic | AD replication |
| **LDAP** | 389/TCP+UDP | Directory queries/writes |
| **LDAPS** | 636/TCP | Secure LDAP (optional) |
| **SMB** | 445/TCP | SYSVOL replication |
| **Global Catalog** | 3268/TCP | Cross-domain queries |
| **RPC Dynamic** | 49152-65535/TCP | Replication traffic |

---

## NTDS.dit and SYSVOL Replication

### What is NTDS.dit?

**NTDS.dit** is the Active Directory database file:

```text
Location: C:\Windows\NTDS\ntds.dit

Contains:
├── User accounts (sAMAccountName, UPN, SID, password hashes)
├── Computer accounts (hostname, SID, DNS records)
├── Group membership (nested groups, group SIDs)
├── Organizational Units (OU structure, GPO links)
├── Schema (object classes, attributes, syntax)
├── Configuration (sites, subnets, replication topology)
└── Metadata (replication vectors, USN, timestamps)
```

**Size:**
- Empty domain: ~40 MB
- Small (<100 users): ~500 MB
- Medium (<1000 users): ~2 GB
- Large (>10,000 users): 10+ GB

### What is SYSVOL?

**SYSVOL** is a file share replicated between all DCs:

```text
Location: C:\Windows\SYSVOL\sysvol

Contains:
├── Group Policy Objects (GPOs)
│   ├── Machine settings (registry, scripts, software)
│   └── User settings (redirects, logon scripts)
├── Logon scripts (.bat, .vbs, .ps1)
├── Group Policy templates (ADMX/ADML files)
└── Netlogon share (legacy logon scripts)
```

**Replication Method:** Windows 2000/2003 used FRS (File Replication Service) - deprecated; Windows 2008+ uses DFSR (DFS Replication) - current standard.

**Why SYSVOL matters:**

- **Group Policy deployment**: Changes to GPOs are replicated via SYSVOL
- **Logon scripts**: Users authenticate to local DC, get scripts from local SYSVOL
- **Consistency**: All DCs must have identical SYSVOL or GPOs don't apply correctly

### Replication Topology

```text
┌─────────────────────────────────────────────────────────┐
│  Multi-Master Replication (All DCs are Equal)           │
└─────────────────────────────────────────────────────────┘

HQ Site                        Branch Site
┌──────────────┐              ┌──────────────┐
│  P-WIN-DC1   │◄────────────►│  H-WIN-DC2   │
│              │  Replication │              │
│  NTDS.dit    │ (Every 180m) │  NTDS.dit    │
│  SYSVOL      │              │  SYSVOL      │
└──────────────┘              └──────────────┘
      ▲                              ▲
      │ Write                        │ Write
      │                              │
┌──────────────┐              ┌──────────────┐
│  User makes  │              │  User makes  │
│  change at   │              │  change at   │
│  HQ          │              │  Branch      │
└──────────────┘              └──────────────┘

Both changes replicate bidirectionally
```

**Replication Conflicts:**

If two admins edit the same object on different DCs simultaneously:

1. **Last Writer Wins**: Change with highest USN (Update Sequence Number) wins
2. **Conflict resolution**: Loser's change is discarded (logged for auditing)
3. **Attribute-level**: Only conflicting attributes are overwritten, not entire object

---

## Key Takeaways

1. **Multiple DCs**: Essential for high availability, load balancing, and disaster recovery
2. **Static Memory**: NEVER use Dynamic Memory for DCs - causes database corruption and replication failures
3. **Hyper-V vs Proxmox**: Both are production-ready; Hyper-V has native Windows support via Integration Services
4. **Generation 2 VMs**: Modern UEFI-based VMs with Secure Boot and better performance
5. **Replication prerequisites**: DC promotion requires network connectivity to existing DC (VPN must be established first)
6. **NTDS.dit + SYSVOL**: Two replication streams - database changes and Group Policy files
7. **Temporary DNS**: Point to gateway initially, switch to HQ DC after VPN is ready

