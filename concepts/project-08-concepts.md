---
title: "Project 8: Multi-Site Active Directory Configuration - Background & Concepts"
parent: "Project 8: Multi-Site Active Directory Configuration"
tags: [concepts, background, active-directory, multi-site, replication, dns, time-sync]
status: completed
---

# Background & Concepts: Multi-Site Active Directory Configuration

## Overview

Multi-site Active Directory is one of the most complex and critical enterprise patterns to understand. This project brings together network connectivity (VPN), replication topology (AD Sites), time synchronization (Kerberos requirements), DNS architecture (forward/reverse zones), and firewall considerations (host vs network). Getting any piece wrong breaks authentication, replication, or both.

---

## Active Directory Sites and Services

### What is an AD Site?

An **AD Site** is a **logical grouping of subnets** that tells Active Directory:

- Which DCs are physically close to each other (fast LAN)
- Which DCs are separated by slow WAN links
- How clients should find their nearest DC
- How replication should be scheduled and optimized

**Important:** Sites are **not** physical locations, VLANs, or security boundaries. They exist purely to answer two questions: "Which DC should this client authenticate to?" and "How often should DCs sync with each other?"

### Without Sites (Single-Site Default)

When you promote the first DC in a forest, AD creates a site called `Default-First-Site-Name`. Until you configure additional sites:

- **All DCs are in the same site**
- **AD assumes all DCs are on a fast LAN** (intra-site replication)
- **Clients may authenticate across the WAN** (inefficient)
- **Replication happens immediately** (floods slow WAN links)

### With Sites (Multi-Site)

```text
┌─────────────────────────────────────────────────────────┐
│  AD Sites Topology                                      │
└─────────────────────────────────────────────────────────┘

Site: HQ-Proxmox                    Site: Branch-HyperV
Subnets: 172.16.0.0/24              Subnets: 172.17.0.0/24
┌──────────────┐                    ┌──────────────┐
│  P-WIN-DC1   │◄──────────────────►│  H-WIN-DC2   │
│              │  Site Link:        │              │
│              │  - Replicate every │              │
│              │    3 hours         │              │
│              │  - Compressed      │              │
└──────────────┘                    └──────────────┘
      ▲                                    ▲
      │                                    │
      │ Nearest DC                         │ Nearest DC
      │                                    │
┌──────────────┐                    ┌──────────────┐
│  HQ Client   │                    │Branch Client │
│  172.16.0.50 │                    │ 172.17.0.50  │
└──────────────┘                    └──────────────┘
```

**Benefits:**

1. **Client affinity**: Clients authenticate to nearest DC (based on subnet)
2. **Scheduled replication**: Changes replicate every N minutes (not immediately)
3. **Compressed replication**: Inter-site traffic is compressed to save WAN bandwidth
4. **DFS referrals**: Distributed File System uses site info to direct users to the nearest file server (reduces WAN traffic for shared folders)
5. **Application awareness**: Apps like Exchange understand site topology

### Subnets Define Sites

**How clients find their site:**

> **What's an SRV record?** DNS SRV (Service) records tell clients where to find specific services. AD registers SRV records so clients can discover Domain Controllers without hardcoding IP addresses.

1. Client boots, gets IP address `172.17.0.50`
2. Client queries DNS for DC locations (SRV record: `_ldap._tcp.dc._msdcs.reginleif.io`)
3. Client checks its IP against AD subnet definitions:
   - `172.17.0.0/24` → `Branch-HyperV` site
4. Client prioritizes DCs in `Branch-HyperV` site
5. Client authenticates to `H-WIN-DC2` (local DC)

**Without subnet configuration:**

- Client gets random DC (might be across WAN)
- Authentication is slower (WAN latency)
- WAN bandwidth wasted

---

## AD Replication Architecture

### Multi-Master Replication

Active Directory uses **multi-master replication** - every DC is **writable**:

```text
┌─────────────────────────────────────────────────────────┐
│  Multi-Master Model (Active Directory)                  │
└─────────────────────────────────────────────────────────┘

Admin creates user on DC1        Admin resets password on DC2
        ↓                                    ↓
   ┌─────────┐                          ┌─────────┐
   │  DC1    │◄────────────────────────►│  DC2    │
   │ (Write) │     Bidirectional        │ (Write) │
   └─────────┘     Replication          └─────────┘
        ↓                                    ↓
   Both changes propagate to all DCs in forest
```

**Contrast with Single-Master:**

| Model | Writes | Failure Impact | Example Systems |
|:------|:-------|:---------------|:----------------|
| **Single-Master** | One writable server | Writes fail if master is down | MySQL (traditional), DNS (primary) |
| **Multi-Master** | All servers writable | Writes continue on any DC | Active Directory, Cassandra |

**Conflict Resolution:**

If two admins modify the same attribute simultaneously:

1. Each DC assigns a **USN** (Update Sequence Number) and timestamp
2. Change with **higher USN wins** (later timestamp breaks ties)
3. Loser's change is discarded (logged to event log)
4. **Attribute-level conflict resolution**: Only conflicting attribute is overwritten, not entire object

### What Gets Replicated?

Active Directory database has multiple **naming contexts** (partitions):

| Partition | Contents | Replication Scope |
|:----------|:---------|:------------------|
| **Domain** | Users, computers, groups, OUs, GPO links | All DCs in domain |
| **Configuration** | Sites, subnets, site links, cross-refs | All DCs in forest |
| **Schema** | Object class definitions (user, computer, etc.) | All DCs in forest |
| **DomainDnsZones** | DNS records for domain (A, CNAME, PTR) | All DCs running DNS in domain |
| **ForestDnsZones** | DNS records for forest (root, _msdcs) | All DCs running DNS in forest |

**Example:**

When you create a user on DC1:
- **Domain partition**: User object replicates to DC2 (both DCs in `reginleif.io`)
- **Configuration partition**: No change (sites/subnets unchanged)
- **Schema partition**: No change (no new object classes)
- **DomainDnsZones**: User's computer account may register A record → replicates to DC2

> [!TIP]
> **Why 5 partitions instead of 1 database?**
>
> Different data has different audiences:
> - **Schema** changes affect entire forest (rare, but critical)
> - **Domain** data (users, groups) only matters to DCs in that domain
> - **DNS zones** only replicate to DCs running DNS
>
> **Practical tip:** When `repadmin /showrepl` shows errors, it tells you WHICH partition failed. Schema failures are forest-wide emergencies. Domain failures affect one domain.

### Update Sequence Numbers (USN)

Every change in Active Directory is tracked by a **USN**:

```text
┌─────────────────────────────────────────────────────────┐
│  USN-Based Replication                                  │
└─────────────────────────────────────────────────────────┘

DC1 makes change → USN increments:
    DC1 local USN: 1000 → 1001 (new user created)

DC1 notifies DC2: "I have changes up to USN 1001"

DC2 checks its bookmark (last USN received from DC1):
    "Last USN from DC1: 950"
    "Request USNs 951-1001 from DC1"

DC1 sends changes (USNs 951-1001) to DC2

DC2 applies changes, updates its bookmark:
    "Last USN from DC1: 1001"

Next replication: DC2 requests "USNs > 1001"
```

**Why USNs matter:**

- **Efficient replication**: Only changed objects replicate (not entire database)
- **Convergence detection**: When all DCs have same USNs, replication is complete
- **Troubleshooting**: `repadmin /showrepl` shows USN status for each partition

> [!TIP]
> **Key concept:** USNs are monotonically increasing counters (they only go up, never down). This allows efficient delta replication: DC2 tracks "last USN received from DC1" and requests only newer changes. When troubleshooting replication failures, comparing USN values between DCs reveals which DC has fallen behind.

### Intra-Site vs Inter-Site Replication

| Characteristic | Intra-Site (Same Site) | Inter-Site (Across Sites) |
|:---------------|:-----------------------|:--------------------------|
| **Trigger** | Near-instant notification (15 sec delay) | Scheduled intervals (default: 180 min) |
| **Compression** | No | Yes (saves WAN bandwidth) |
| **Optimization** | Assumes fast LAN (Gbps) | Assumes slow WAN (Mbps) |
| **Change notification** | Push (DC notifies partners immediately) | Pull (partner queries on schedule) |
| **Use case** | DCs in same datacenter | DCs across VPN/WAN |

**Why the delay matters:**

- **Intra-site**: User password reset → Replicated in 15 seconds → User can log in
- **Inter-site**: User password reset → Replicated in 180 minutes → User waits up to 3 hours

**Lab configuration:**

The project sets replication interval to **15 minutes** (instead of default 180) for faster testing. Production environments balance replication frequency against WAN bandwidth.

---

## Network Firewall vs Host-Based Firewall

Many admins configure site-to-site VPN tunnels, verify routing works, and then **cannot understand why AD replication fails**. A common culprit: **Windows host-based firewall**.

Windows Firewall has **network profiles** (Domain, Private, Public):

| Network Profile | Applied When | Default Behavior |
|:----------------|:-------------|:-----------------|
| **Domain** | Computer is domain-joined and can contact DC | Allows most traffic |
| **Private** | User-designated trusted network | Allows file sharing, discovery |
| **Public** | Unknown/untrusted network | **Blocks almost everything** |

**The problem:**

- Windows sees traffic from `172.17.0.0/24` (Branch subnet)
- Branch subnet is not in the local "Domain" network profile
- Windows treats it as **foreign traffic** and applies strict blocking
- Even though the VPN tunnel works, SMB (445), RPC (135+dynamic), and ICMP are blocked

**Production considerations:**

For our lab, we created broad permissive rules.
In production, you'd create granular rules for specific ports (53, 88, 135, 389, 445, 464, 636, 3268, 3269, 49152-65535) and specific source IPs, not "Allow Any" rules. But for lab troubleshooting, broad rules eliminate variables.

---

## Time Synchronization and Kerberos

### Why Time Sync is Critical

**Kerberos** (Active Directory's authentication protocol) embeds **timestamps** in every ticket to prevent **replay attacks**:

```text
┌─────────────────────────────────────────────────────────┐
│  Kerberos Authentication Flow                           │
└─────────────────────────────────────────────────────────┘

1. Client requests ticket from DC
   └─► Timestamp: 2024-01-15 10:00:00

2. DC issues ticket (TGT)
   └─► Valid from: 2024-01-15 10:00:00
   └─► Valid until: 2024-01-15 20:00:00 (10 hour lifetime)

3. Client presents ticket to file server
   └─► File server checks timestamp against its clock

4. If time difference > 5 minutes:
   └─► "KRB_AP_ERR_SKEW: Clock skew too great"
   └─► Authentication fails
```

**The 5-Minute Rule:**

Kerberos allows maximum **5-minute clock skew** between client and server. Beyond that:

- ❌ Domain joins fail
- ❌ Authentication fails
- ❌ AD replication breaks
- ❌ GPO application fails
- ❌ Remote management fails (RDP, WinRM)

### AD Time Hierarchy (Enterprise Pattern)

Active Directory establishes a **time synchronization hierarchy**. In enterprise environments, Domain Controllers sync from an **internal NTP server** rather than directly to the internet:

```text
┌─────────────────────────────────────────────────────────┐
│  AD Time Hierarchy (Enterprise)                         │
└─────────────────────────────────────────────────────────┘

External NTP (pool.ntp.org)     ← Stratum 1-2 (GPS/atomic)
        ↓
   OPNsense (172.16.0.1)        ← Stratum 2-3 (internal NTP)
   └─► Syncs to external NTP pools
   └─► Serves time to internal network
        ↓
   PDC Emulator (DC1)           ← Stratum 3-4 (domain root)
   └─► Syncs from OPNsense
   └─► Authoritative for domain
        ↓
   Other DCs (DC2, DC3...)      ← Stratum 4-5
   └─► Sync from PDC Emulator
        ↓
   Domain Members (workstations, servers)  ← Stratum 5-6
   └─► Sync from authenticating DC
```

### Why Use Internal NTP (Enterprise Pattern)

In production environments, DCs should **not** sync directly to internet NTP pools:

| Concern | Enterprise Approach |
|:--------|:--------------------|
| **Security** | DCs shouldn't communicate directly with the internet |
| **Compliance** | Auditors want controlled, documented time sources |
| **Reliability** | Internal NTP = no external dependency |
| **Consistency** | All systems use the same internal source |
| **Monitoring** | Easier to track and alert on internal NTP servers |

**Common internal NTP sources:**

- **Firewall/router** (OPNsense, Palo Alto, Cisco) - our approach
- **Dedicated NTP appliances** (Meinberg, Spectracom) - enterprise datacenters
- **GPS receivers** - finance, healthcare, government (highest accuracy)
- **Core switches** - large network infrastructures

**Key roles:**

| Role | Configuration | Purpose |
|:-----|:--------------|:--------|
| **OPNsense** | Services → Network Time → General | Internal NTP server, syncs to external pools |
| **PDC Emulator** | `w32tm /config /manualpeerlist:"172.16.0.1"` | Syncs from OPNsense |
| **Other DCs** | `w32tm /config /syncfromflags:DOMHIER` | Sync from PDC Emulator via AD |
| **Domain Members** | Automatic (NT5DS provider) | Sync from authenticating DC |

**What is Stratum?**

NTP uses **stratum** to indicate distance from authoritative time source:

- **Stratum 0**: Atomic clock, GPS (reference hardware)
- **Stratum 1**: Directly connected to Stratum 0 (e.g., `time.nist.gov`)
- **Stratum 2**: Syncs from Stratum 1 (e.g., `pool.ntp.org` servers)
- **Stratum 3**: Syncs from Stratum 2 (e.g., OPNsense)
- **Stratum 4**: Syncs from Stratum 3 (e.g., your DC1)
- **Stratum 5**: Syncs from Stratum 4 (e.g., your DC2, member servers)

**Normal ranges:**

- DCs: Stratum 3-5 (acceptable with internal NTP)
- Stratum 10+: Problem - too far from authoritative source

### Proxmox RTC Clock Issue

**The problem:**

- **Proxmox hypervisor** keeps hardware clock (RTC) in **UTC** (Coordinated Universal Time, the global reference timezone with no offset)
- **Windows** expects hardware clock in **local time** (your timezone, e.g., UTC+1 for Paris)
- **Mismatch** causes Windows to boot with wrong time
- **Kerberos fails** if offset > 5 minutes

**The fix (Proxmox):**

This is a possible cause of time offset issues from what we saw in the lab even if Proxmox should set it up by default for Windows VMs.

```bash
# On Proxmox host (not Windows VM)
qm set <VMID> -localtime 1
```

This tells QEMU to present the hardware clock as local time to the guest OS.

### Hyper-V Integration Services Time Sync Conflict

**The problem:**

Hyper-V Integration Services include **Time Synchronization**, which forces VM to sync with Hyper-V host. This **overrides** Windows Time service (w32time) trying to sync from PDC Emulator.

**Symptom:**

```powershell
w32tm /query /source
# Expected: P-WIN-DC1.reginleif.io
# Actual:   VM IC Time Synchronization Provider
```

**The fix:**

Disable Hyper-V time sync in VM settings:
1. Hyper-V Manager → VM → Settings
2. Integration Services → **Uncheck "Time synchronization"**
3. Inside VM: `Restart-Service w32time; w32tm /resync /force`

---

## The AD Island Problem

### What is an "AD Island"?

An **AD Island** occurs when a Domain Controller cannot discover or replicate with other DCs, even though network connectivity exists.

**Common cause: DNS misconfiguration**

### Why 127.0.0.1 is Problematic

Many admins configure DCs with DNS pointing to **loopback (127.0.0.1)**:

```text
❌ Problematic Configuration:
┌──────────────────────────────┐
│  DC1                         │
│  Primary DNS: 127.0.0.1      │ ← Loopback
│  Secondary DNS: None         │
└──────────────────────────────┘

Problem Timeline:
1. DC1 reboots
2. Windows loads → DNS client starts
3. DNS client queries 127.0.0.1 for SRV records
4. DNS Server service NOT YET STARTED
5. Query fails → DC1 thinks it's isolated
6. DC1 may register itself as sole DC
7. Replication breaks
```

**During boot:**

Services start in this order:
1. **Network stack** (TCP/IP, DNS client)
2. **Windows firewall**
3. **Netlogon** (queries DNS for DC SRV records)
4. **DNS Server** (loads zones from AD)

**Race condition:**

If Netlogon queries DNS before DNS Server is ready, `127.0.0.1` query fails. DC thinks no other DCs exist.

### Microsoft Best Practice

**Proper DNS configuration for DCs:**

```text
✅ Correct Configuration:
┌──────────────────────────────┐
│  DC1                         │
│  Primary DNS: 172.17.0.10    │  ← Partner DC (DC2)
│  Secondary DNS: 172.16.0.10  │  ← Self (static IP)
└──────────────────────────────┘

┌──────────────────────────────┐
│  DC2                         │
│  Primary DNS: 172.16.0.10    │  ← Partner DC (DC1)
│  Secondary DNS: 172.17.0.10  │  ← Self (static IP)
└──────────────────────────────┘
```

**Why this works:**

1. DC1 boots → Queries DC2 for SRV records (DC2 is already running)
2. DC2 responds with list of all DCs
3. DC1 discovers full replication topology
4. Replication starts normally

**Why not loopback:**

- `127.0.0.1` binds to loopback interface, not real network interface
- During service startup, loopback may not resolve correctly
- Using static IP ensures consistent DNS behavior

### Self First vs Partner First

**Two valid approaches:**

| Configuration | Use Case | Benefits | Drawbacks |
|:--------------|:---------|:---------|:----------|
| **Partner first, self second** | Newly promoted DC, unstable DNS | Prevents AD Island during boot | Slight dependency on partner |
| **Self first, partner second** | Stable production DCs | Faster local queries, less network traffic | Possible race condition during boot |

**Project evolution:**

- **Project 8**: Uses "partner first, self second" (DC2 just promoted, DNS may be unstable)
- **Project 11**: Switches to "self first, partner second" (both DCs stable, production-ready)

Both are valid. Key principle: **NEVER use 127.0.0.1 on a DC**.

---

## DNS in Multi-Site Active Directory

### Forward vs Reverse DNS

**Forward DNS (A records):**

```text
Hostname → IP Address
p-win-dc1.reginleif.io → 172.16.0.10
```

**Reverse DNS (PTR records):**

```text
IP Address → Hostname
172.16.0.10 → p-win-dc1.reginleif.io
```

### Why Reverse DNS Matters

Many protocols and applications rely on reverse DNS:

| Use Case | Why PTR Records Matter |
|:---------|:-----------------------|
| **Email servers** | Spam filters reject mail from IPs without PTR records |
| **Kerberos** | SPNs (Service Principal Names) may validate reverse lookups |
| **DHCP** | Dynamic DNS updates register both A and PTR records |
| **Logging** | Security logs show hostnames, not just IPs |
| **Auditing** | Compliance tools validate forward/reverse DNS match |

**Without reverse zones:**

DHCP dynamic DNS updates **silently fail** for PTR records. You'll have A records but no PTR records. Some apps will work, others will fail mysteriously.

### AD-Integrated DNS Zones

**Two zone types:**

| Zone Type | Storage | Replication | Use Case |
|:----------|:--------|:------------|:---------|
| **Primary (File-based)** | `%SystemRoot%\System32\dns\` | Manual (zone transfer) | Legacy DNS servers |
| **AD-Integrated** | Active Directory database | Automatic (AD replication) | Domain Controllers |

**AD-Integrated benefits:**

- **Automatic replication**: Zones replicate via AD (no zone transfer config)
- **Secure updates**: Only domain members can register DNS records
- **Multi-master**: All DCs can accept DNS updates
- **No zone transfer overhead**: DNS changes piggyback on AD replication

**Replication scopes:**

| Scope | Replicates To | Use Case |
|:------|:--------------|:---------|
| **Forest** | All DCs in forest | Forest root zones (e.g., `_msdcs.reginleif.io`) |
| **Domain** | All DCs in domain | Domain zones (e.g., `reginleif.io`) |

### DNS Forwarders

**Problem:**

AD DNS servers are **authoritative** for `reginleif.io` but **cannot resolve** external domains (`google.com`, `microsoft.com`) without help.

**Solution: Forwarders**

```text
┌─────────────────────────────────────────────────────────┐
│  DNS Resolution Flow                                    │
└─────────────────────────────────────────────────────────┘

Client queries "reginleif.io"
        ↓
    DC1 DNS Server
        ↓
    "I'm authoritative for reginleif.io"
        ↓
    Returns answer from AD database ✓

Client queries "google.com"
        ↓
    DC1 DNS Server
        ↓
    "Not authoritative for google.com"
        ↓
    Forward to 172.16.0.1 (OPNsense)
        ↓
    OPNsense (Unbound)
        ↓
    Recursive query to root servers
        ↓
    Returns answer ✓
```

**Why OPNsense instead of 8.8.8.8 (Google DNS)?**

- **Local caching**: OPNsense caches external queries (faster repeat lookups)
- **Site resilience**: Each site forwards to local OPNsense (no WAN dependency)
- **Privacy**: Queries stay within your network (no external tracking)
- **Filtering**: OPNsense can implement DNS-based filtering (ads, malware)

> **Note:** OPNsense uses **Unbound** as its DNS resolver (covered in Project 5). Unbound is a validating, recursive, caching DNS resolver that can operate in forwarding mode (sending queries to upstream servers like 8.8.8.8) or recursive mode (querying root servers directly). In this multi-site setup, Unbound at each site provides local DNS caching and resilience.

---

## FSMO Roles in Multi-Site Environments

### What are FSMO Roles?

**FSMO** = **Flexible Single Master Operations**

While AD uses multi-master replication for most operations, **some operations must be single-master** to prevent conflicts:

| FSMO Role | Scope | Responsibilities |
|:----------|:------|:-----------------|
| **Schema Master** | Forest | Controls schema changes (new object classes) |
| **Domain Naming Master** | Forest | Controls domain creation/deletion |
| **RID Master** | Domain | Allocates RID pools (for SID generation) |
| **PDC Emulator** | Domain | Time sync, password changes, Group Policy, legacy clients |
| **Infrastructure Master** | Domain | Updates cross-domain group membership references |

> **Note:** **All five roles above are single-master operations** - only ONE domain controller can hold each role at any given time. This prevents conflicts like duplicate RIDs or schema inconsistencies. The "Flexible" part means you can transfer these roles between DCs as needed.

> [!TIP]
> **Priority for this project:** The **PDC Emulator** is the most operationally critical role (time sync, password changes, Group Policy). If AD authentication fails, verify DC1 (which holds all FSMO roles) is online and reachable first.
>
> Understanding all five roles becomes important when scaling to larger environments or performing DC migrations.

### Understanding RIDs and SIDs (Deep Dive)

**RID** = **Relative Identifier** - A unique number assigned to each user, group, or computer in a domain.

**SID** = **Security Identifier** - The complete unique ID combining your domain's ID with the object's RID.

**Simple Example:**

```
Your domain has an ID: S-1-5-21-1234567890-9876543210-1122334455

When you create users, they get unique RIDs:
├─ Administrator: S-1-5-21-1234567890-9876543210-1122334455-500
├─ Alice:         S-1-5-21-1234567890-9876543210-1122334455-1001
└─ Bob:           S-1-5-21-1234567890-9876543210-1122334455-1002
                  └────────────────┬────────────────────────┘ └──┬──┘
                              Domain SID (same for all)        RID (unique)
```

**Why the RID Master Matters:**

In multi-DC environments, each DC can create users. Without coordination, two DCs might assign the same RID to different users:

```
Problem:  DC1 creates "Alice" with RID 1005
          DC2 creates "Bob" with RID 1005   ← Conflict!

Solution: RID Master gives each DC a pool of RIDs:
          DC1 gets: 1000-1499
          DC2 gets: 1500-1999
          Now they can't conflict!
```

> **Note:** Each DC gets 500 RIDs at a time from the RID Master. When it runs out, it requests another pool. If the RID Master is offline temporarily, DCs continue using their existing pools - only a long-term outage causes problems.

### FSMO Placement in Multi-Site

**Single-site (default):**

- All FSMO roles on first DC (e.g., DC1)

**Multi-site (considerations):**

| Role | Recommended Placement | Reason |
|:-----|:----------------------|:-------|
| **PDC Emulator** | Central site (HQ) | Authoritative time source, clients prefer PDC for password changes |
| **RID Master** | Central site (HQ) | Less critical, but keep with PDC for simplicity |
| **Infrastructure Master** | Site with most users (HQ) | Frequently updates cross-domain references |
| **Schema Master** | Central site (HQ) | Rarely used, low traffic |
| **Domain Naming Master** | Central site (HQ) | Rarely used, low traffic |

**For this lab:**

All roles remain on **DC1 (HQ)** for now - this is fine for a 2-DC environment. Large enterprises might split roles across DCs.

### PDC Emulator Special Responsibilities

The **PDC Emulator** is the **most critical FSMO role**:

1. **Time synchronization**: Authoritative time source for domain (syncs to NTP)
2. **Password changes**: Preferred DC for password changes (urgent replication)
3. **Group Policy**: Authoring GPOs should be done on PDC Emulator
4. **Account lockout**: Tracks failed login attempts across all DCs

**If PDC Emulator is down:**

- Time sync may drift (DCs sync to each other, but drift over time)
- Password changes take longer to replicate (no urgent replication)
- Group Policy changes may have issues
- Account lockouts may not enforce correctly

---

## Replication Troubleshooting

### Common Commands

| Command | Purpose |
|:--------|:--------|
| `repadmin /syncall /AdeP` | Force immediate replication (all partitions) |
| `repadmin /showrepl` | Show replication status and partners |
| `repadmin /replsummary` | Summary of replication health across all DCs |
| `dcdiag /v` | Comprehensive DC health check |
| `nltest /dsgetdc:reginleif.io` | Test DC discovery (Netlogon) |

### Replication Status Interpretation

**Healthy replication:**

```text
repadmin /showrepl

Source: P-WIN-DC1
    DC=reginleif,DC=io
        Default-First-Site-Name\H-WIN-DC2
            Last attempt @ 2024-01-15 10:00:00 was successful.
            USN: 12345 -> 12350 (5 changes)
```

**Problem indicators:**

- **Last attempt failed**: Network/firewall issue
- **Access denied**: Time skew (Kerberos failure)
- **RPC server unavailable**: Firewall blocking high ports (49152-65535)
- **USN not advancing**: DC not replicating changes

### Common Failure Modes

| Symptom | Likely Cause | Fix |
|:--------|:-------------|:----|
| **Access denied** | Time skew > 5 minutes | Fix NTP sync, check RTC clock |
| **RPC unavailable** | Windows firewall blocking dynamic ports | Add firewall rules |
| **DC not found** | DNS misconfiguration | Check SRV records, DNS forwarders |
| **No replication partners** | AD Sites not configured | Create sites, define subnets |

---

## Key Takeaways

1. **Two firewall layers**: Network firewall (OPNsense) AND host firewall (Windows) - both must allow traffic
2. **AD Sites define topology**: Subnets → Sites → Client affinity + scheduled replication
3. **Multi-master replication**: All DCs are writable, USNs track changes, conflicts resolved by timestamp
4. **Time sync hierarchy (enterprise)**: OPNsense → external NTP, PDC Emulator → OPNsense, other DCs → PDC Emulator, members → authenticating DC
5. **5-minute Kerberos rule**: Clock skew > 5 minutes breaks all authentication
6. **No loopback DNS**: DCs should point to partner DC first, self second (never 127.0.0.1)
7. **Forward + Reverse DNS**: Both A records and PTR records required for proper DNS operation
8. **DNS forwarders**: AD DNS forwards external queries to OPNsense (local recursive resolver)
9. **FSMO roles**: PDC Emulator is critical (time sync, password changes, Group Policy)
10. **Replication troubleshooting**: `repadmin` commands show replication status, `dcdiag` validates DC health

---

## Key Terms Glossary

| Term | Definition |
|:-----|:-----------|
| **AD Site** | Logical grouping of subnets for DC affinity and replication scheduling |
| **Site Link** | Connection defining replication schedule and cost between AD sites |
| **Intra-site replication** | Near-instant (15-second) replication between DCs in the same site |
| **Inter-site replication** | Scheduled, compressed replication between DCs in different sites |
| **FSMO** | Flexible Single Master Operations: roles requiring single-DC ownership |
| **PDC Emulator** | FSMO role for time sync, password changes, and Group Policy |
| **RID Master** | FSMO role allocating RID pools for SID generation |
| **Stratum** | NTP hierarchy level indicating distance from authoritative time source |
| **Forward DNS** | Hostname to IP resolution (A records) |
| **Reverse DNS** | IP to hostname resolution (PTR records) |
| **AD-Integrated DNS** | DNS zones stored in Active Directory database, replicated via AD |
