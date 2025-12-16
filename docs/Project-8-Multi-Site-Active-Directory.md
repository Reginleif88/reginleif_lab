---
title: "Project 8: Multi-Site Active Directory Configuration"
tags: [active-directory, integration, windows-server, dns]
sites: [hq, branch]
status: completed
---

## Goal

Configure Active Directory for multi-site operation after the WireGuard VPN tunnel is established (Project 7). This includes Windows firewall rules, AD Sites and Services, promoting the Branch DC, and configuring DNS for proper replication.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-08-concepts)**

For educational context about multi-site Active Directory, Windows host firewall vs network firewall, and AD Sites and Services, see the dedicated concepts guide.

---

> [!NOTE]
> **Pre-VLAN Addressing:** This project uses flat network addressing. After VLAN segmentation in Project 11:
> - P-WIN-DC1: `172.16.0.10` → `172.16.5.10`, gateway `172.16.0.1` → `172.16.5.1`
> - H-WIN-DC2: `172.17.0.10` → `172.17.5.10`, gateway `172.17.0.1` → `172.17.5.1`
> - DNS forwarders update from `172.16.0.1`/`172.17.0.1` to `172.16.5.1`/`172.17.5.1`
> - AD Sites subnets are updated for all VLAN ranges

## Prerequisites

* Project 7 completed (Site-to-Site VPN working)
* P-WIN-DC1 (HQ) is already a Domain Controller for `reginleif.io`
* H-WIN-DC2 (Branch) is a Windows Server ready for promotion

---

## 1. Windows Host Firewall Configuration

> [!IMPORTANT]
> OPNsense firewall rules control traffic at the network gateway level, but Windows Server has its own host-based firewall that applies independently. By default, Windows blocks SMB (File Sharing), RPC (AD Replication), and ICMP (Ping) from "foreign" subnets.

**The Issue:** Even with a perfectly configured VPN, Windows will block:

* ICMP Echo Requests (ping) from remote subnets
* SMB (TCP 445) for file shares and SYSVOL replication
* RPC (Dynamic ports) for AD replication
* LDAP, Kerberos, and other AD protocols

| Protocol | Why AD Needs It |
|----------|-----------------|
| **SMB** | Server Message Block (port 445) — replicates SYSVOL (Group Policy files, logon scripts) and NETLOGON share between DCs. Without SMB, GPOs won't update across sites. |
| **RPC** | Remote Procedure Call (port 135 + dynamic 49152-65535) — AD replication, remote registry, and management tools use RPC to communicate between DCs. |
| **LDAP** | Lightweight Directory Access Protocol (port 389) — queries and updates the AD database (users, groups, computer objects). |
| **Kerberos** | Authentication protocol (ports 88, 464) — authenticates users and computers. Cross-site logins fail if Kerberos traffic is blocked. |

This is the **#1 reason** site-to-site VPN labs fail validation tests.

### Configure Windows Firewall (Both DCs)

**On P-WIN-DC1 (HQ) and H-WIN-DC2 (Branch):**

```powershell
# [Both DCs]
# Allow all TCP traffic from lab subnets (covers SMB, RPC, LDAP, Kerberos)
New-NetFirewallRule -DisplayName "Allow Lab Subnets - TCP" -Direction Inbound `
    -LocalPort Any -Protocol TCP -Action Allow `
    -RemoteAddress 172.16.0.0/24,172.17.0.0/24,10.200.0.0/24

# Allow all UDP traffic from lab subnets (covers DNS, Kerberos, NTP)
New-NetFirewallRule -DisplayName "Allow Lab Subnets - UDP" -Direction Inbound `
    -LocalPort Any -Protocol UDP -Action Allow `
    -RemoteAddress 172.16.0.0/24,172.17.0.0/24,10.200.0.0/24

# Allow ICMP (Ping) - often blocked by default on all profiles
New-NetFirewallRule -DisplayName "Allow ICMPv4 - Ping" -Protocol ICMPv4 `
    -IcmpType 8 -Enabled True -Profile Any -Action Allow
```

**Verify the rules were created:**

```powershell
# [Both DCs]
Get-NetFirewallRule -DisplayName "Allow Lab*" | Format-Table Name, DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow ICMPv4*" | Format-Table Name, DisplayName, Enabled
```

> [!NOTE]
> In production environments, you would create granular rules for specific ports (53, 88, 135, 389, 445, 464, 636, 3268, 3269, 49152-65535) rather than allowing all TCP/UDP. For lab purposes, the broad rule simplifies troubleshooting.

---

## 2. Active Directory Sites Configuration

> **Why Sites Matter:** Without site configuration, Active Directory assumes all Domain Controllers are on the same fast LAN. This causes problems in multi-site environments:

| Without Sites | With Sites |
| --------------- | ------------ |
| Clients may authenticate against DCs across slow VPN links | Clients find the nearest DC in their subnet |
| Replication happens immediately (floods WAN) | Replication is scheduled and compressed for WAN links |
| DFS/SYSVOL referrals ignore network topology | Clients access local file servers first |

### Understanding AD Replication

Active Directory uses **multi-master replication** - any Domain Controller can accept changes (new users, password resets, GPO edits), and those changes automatically propagate to all other DCs. This differs from single-master systems where only one server accepts writes.

**What gets replicated:**

| Partition | Contents | Scope |
|-----------|----------|-------|
| Domain | Users, computers, groups, GPOs | All DCs in the domain |
| Configuration | Sites, subnets, replication topology | All DCs in the forest |
| Schema | Object classes, attributes definitions | All DCs in the forest |
| DomainDnsZones | AD-integrated DNS records for domain | All DCs running DNS in the domain |
| ForestDnsZones | AD-integrated DNS records for forest | All DCs running DNS in the forest |

**How replication works:**

1. A change is made on DC1 (e.g., new user created)
2. DC1 assigns the change a **USN** (Update Sequence Number) and timestamp
3. DC1 notifies its replication partners that changes are available
4. Partner DCs request the changes and apply them locally
5. Each DC tracks what it has received using **high watermark vectors**

**Intra-site vs Inter-site replication:**

| Intra-site (same site) | Inter-site (across sites) |
|------------------------|---------------------------|
| Near-instant notification | Scheduled intervals (default: 180 min) |
| Uncompressed traffic | Compressed to save bandwidth |
| Assumes fast LAN | Assumes slow WAN link |

**Troubleshooting commands:**

```powershell
# Force replication across all partitions and sites
repadmin /syncall /AdeP

# Show replication status and partners
repadmin /showrepl

# Show replication summary for all DCs
repadmin /replsummary
```

> **AD Sites and Services** (`dssite.msc`) tells AD which subnets belong to which physical locations, so it can make intelligent routing decisions.

### Site Configuration (RSAT from Windows 11)

**From your Windows 11 management workstation** (with RSAT installed - see Project 4):

1. **Open AD Sites and Services (`dssite.msc`):**
    * Rename `Default-First-Site-Name` to **`HQ-Proxmox`**.
    * Right-click Sites > New Site > Name: **`Branch-HyperV`** > Select `DEFAULTIPSITELINK` > OK.
2. **Define Subnets:**
    * Right-click Subnets > New Subnet > Prefix: `172.16.0.0/24` > Select **`HQ-Proxmox`** > OK.
    * Right-click Subnets > New Subnet > Prefix: `172.17.0.0/24` > Select **`Branch-HyperV`** > OK.
3. **Configure Site Link Replication:**
    * Expand Sites > Inter-Site Transports > IP.
    * Right-click **DEFAULTIPSITELINK** > Properties.
    * Change "Replicate every" from 180 to **15 minutes** (for lab testing).
    * Click OK.

> [!NOTE]
> `H-WIN-DC2` will automatically be placed in the `Branch-HyperV` site during DC promotion (Section 5) when you specify `-SiteName "Branch-HyperV"`. No manual server move is required.

---

## 3. Prepare DC2 for Domain Join

After VPN is established, configure DC2's timezone and DNS settings before joining the domain.

### Set Timezone DC2

**On H-WIN-DC2:**

```powershell
# [H-WIN-DC2]
# Check current timezone
Get-TimeZone

# Set timezone to Paris
Set-TimeZone -Id "Romance Standard Time"
```

> [!NOTE]
> Timezone does not sync via Active Directory. Each server must be configured individually based on its physical location. In multi-site deployments, DCs in different regions may have different timezones - this is normal and does not affect AD replication (which uses UTC internally).

### Configure DNS

**On H-WIN-DC2:**

> [!NOTE]
> Interface name may vary. Run `Get-NetAdapter` to confirm.

```powershell
# [H-WIN-DC2]
# Update DNS to HQ DC (required for domain operations)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.16.0.10"

# Verify DNS change
Get-DnsClientServerAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4

# Test AD DNS resolution
nslookup reginleif.io 172.16.0.10
```

> [!NOTE]
> DNS was initially set to `172.17.0.1` (OPNsense) in Project 6 for basic connectivity. Now that the VPN tunnel is active, DC2 can reach the HQ DC for Active Directory DNS.

---

## 4. Configure DC1 Time Settings (Before Promotion)

### Set Timezone DC1

Before configuring NTP, ensure DC1 has the correct timezone set. While AD uses UTC internally for Kerberos and replication, proper timezone configuration ensures accurate local timestamps in logs, event viewer, and scheduled tasks.

**On DC1 (`P-WIN-DC1`):**

```powershell
# [P-WIN-DC1]
# Check current timezone
Get-TimeZone

# Set timezone to Paris
Set-TimeZone -Id "Romance Standard Time"
```

> [!WARNING]
> Windows expects the hardware clock (RTC) to use local time, but Proxmox defaults to UTC. This mismatch causes Kerberos time skew errors, breaking RDP and domain authentication. Additionally, the QEMU Guest Agent can interfere with Windows time synchronization. On your **Proxmox host**, enable local time for all Windows VMs:
>
> ```bash
> # [Proxmox Host]
> # Replace VMID with your VM ID (e.g., 100)
> qm set VMID -localtime 1
> ```
>
> Reboot the VM after applying this change. If issues persist, check if the QEMU Guest Agent is installed and consider disabling its time sync functionality.

> [!NOTE]
> This Proxmox time configuration was also documented in **Project 3, Section 4** for P-WIN-DC1. If you're experiencing time sync issues on DC1, refer back to Project 3, Section 4 for detailed instructions and troubleshooting steps.

### Why Time Sync Must Be Configured First

Kerberos authentication, the backbone of Active Directory security, uses timestamps to prevent replay attacks. By default, Kerberos allows a maximum **5-minute time skew** between a client and the authenticating DC. If clocks drift beyond this threshold:

* DC promotion fails with authentication errors
* Domain joins fail
* AD replication breaks with "access denied" errors
* Users cannot log in

**This must be configured before promoting DC2**, otherwise the promotion may fail due to time skew between the servers.

**Active Directory Time Hierarchy (Enterprise Pattern):**

```text
   External NTP (pool.ntp.org)
        ↓
   OPNsense (172.16.0.1) ── Internal NTP server
        ↓
   PDC Emulator (DC1) ───── Authoritative time source for domain
        ↓
   Other DCs (DC2) ──────── Sync from PDC Emulator
        ↓
   Domain Members ───────── Sync from authenticating DC
```

The **PDC Emulator** (by default, the first DC in the forest - `P-WIN-DC1`) is the authoritative time source for the domain. In enterprise environments, it syncs from an **internal NTP server** (OPNsense) rather than directly to the internet. This follows the security principle that Domain Controllers should not communicate directly with external networks.

> [!NOTE]
> **Why OPNsense as Internal NTP?** Enterprise environments use internal NTP servers for security (DCs don't talk to internet), compliance (auditable time sources), and reliability (no internet dependency). Using your firewall/router as the internal NTP source mirrors what large organizations do with dedicated NTP appliances.

### Configure OPNsense as NTP Server

Before configuring DC1, ensure OPNsense is serving NTP to the LAN:

1. **OPNsense Web UI:** Services → Network Time → General
2. **Enable:** Check "Enable" checkbox
3. **Interfaces:** Select LAN (and any other internal interfaces)
4. **Time Servers:** Default NTP pools are pre-configured (0.opnsense.pool.ntp.org, etc.)
5. **Save** and **Apply**

OPNsense will now sync to external NTP pools and serve time to internal clients on `172.16.0.1`.

### Configure DC1 (PDC Emulator) for Internal NTP

**On DC1 (`P-WIN-DC1`):**

```powershell
# [P-WIN-DC1]
# Configure OPNsense as NTP server (internal time source)
w32tm /config /manualpeerlist:"172.16.0.1" /syncfromflags:manual /reliable:yes /update

# Restart the Windows Time service
Restart-Service w32time

# Force immediate sync
w32tm /resync /rediscover

# Verify configuration
w32tm /query /configuration
w32tm /query /status
```

**Expected output from `/query/status`:**

```text
Source: 172.16.0.1
Stratum: 3 or 4
```

> [!NOTE]
> **What is Stratum?** NTP uses a hierarchy called "stratum" to indicate distance from an authoritative time source. Stratum 0 is an atomic clock, Stratum 1 is directly connected to it, Stratum 2 syncs from Stratum 1, etc. With OPNsense as an intermediate layer, your DC will typically be Stratum 3-4, which is normal and well within acceptable range (problems only start at Stratum 10+).

> [!TIP]
> **VLAN Environments (Project 11+):** If your DCs are on segmented VLANs, use the **DC's default gateway IP** instead of `172.16.0.1`. Each VLAN has its own OPNsense interface that serves NTP. For example, if DC1 is on VLAN 5 with gateway `172.16.5.1`, use that IP for NTP:
> ```powershell
> w32tm /config /manualpeerlist:"172.16.5.1" /syncfromflags:manual /reliable:yes /update
> ```

---

## 5. Promote DC2 to Domain Controller

**On H-WIN-DC2:**

```powershell
# [H-WIN-DC2]
# Install AD Domain Services role
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Promote to Domain Controller (Branch site)
Install-ADDSDomainController `
    -DomainName "reginleif.io" `
    -Credential (Get-Credential "REGINLEIF\Administrator") `
    -SiteName "Branch-HyperV" `
    -InstallDns `
    -Force
```

> [!NOTE]
> The command will prompt for the Directory Services Restore Mode (DSRM) password.

**Post-Reboot:** Server restarts automatically. DC2 is now a fully functional domain controller in the Branch site.

**Verify Promotion:**

```powershell
# Check DC status
Get-ADDomainController -Identity H-WIN-DC2

# Verify SYSVOL/NETLOGON shares
Get-SmbShare | Where-Object { $_.Name -match "SYSVOL|NETLOGON" }
```

### Configure DC2 Time Synchronization

After promotion, DC2 must sync time from the domain hierarchy (PDC Emulator on DC1), not an external source or local clock.

**On DC2 (`H-WIN-DC2`):**

```powershell
# [H-WIN-DC2]
# Configure DC2 to sync from domain hierarchy
w32tm /config /syncfromflags:DOMHIER /update

# Restart the Windows Time service
Restart-Service w32time

# Force immediate sync
w32tm /resync /force

# Verify configuration
w32tm /query /status
```

**Expected output:**

```text
Source: P-WIN-DC1.reginleif.io
Stratum: 3 or 4 (one level higher than DC1)
```

> **Why DOMHIER?** The `DOMHIER` (domain hierarchy) flag tells the Windows Time service to find and sync from the PDC Emulator role holder. This ensures all DCs maintain consistent time through the AD hierarchy rather than independently syncing to external sources, which could cause clock drift between DCs.
>
> **Hyper-V Warning:** If DC2 shows `Source: VM IC Time Synchronization Provider`, Hyper-V Integration Services is overriding domain time sync. Disable it in Hyper-V Manager → VM Settings → Integration Services → uncheck **Time Synchronization**, then run `Restart-Service w32time` and `w32tm /resync /force` inside the VM.

---

## 6. Post-Promotion DNS Configuration

After DC2 (`H-WIN-DC2`) is promoted and its DNS service is operational, you must reconfigure DC1's DNS settings to prevent the **AD Island problem**.

### Understanding the AD Island Problem

When a Domain Controller has `127.0.0.1` (loopback) as its primary DNS:

* During boot, the local DNS Server service may not be running yet
* The DC cannot resolve SRV records for other Domain Controllers
* It may register itself as authoritative for zones incorrectly
* AD replication fails because it can't discover replication partners

**Current DC1 Configuration (Before Fix):**

* Primary DNS: `127.0.0.1` (loopback - problematic)
* Secondary DNS: None or `172.17.0.10` (DC2)

**Microsoft Best Practice:** DCs should point to a partner DC first, then to their own static IP as secondary (not loopback).

### Verify DC2 DNS is Ready

Before changing DC1, confirm DC2's DNS service is operational.

**On DC2 (`H-WIN-DC2`):**

```powershell
# [H-WIN-DC2]
# Check DNS Server service is running
Get-Service -Name DNS

# Verify AD-integrated zones exist
Get-DnsServerZone | Where-Object {$_.ZoneType -eq 'Primary' -and $_.IsDsIntegrated}

# Test forward lookup for the domain
Resolve-DnsName -Name "reginleif.io" -Server 172.17.0.10

# Test DC SRV record resolution
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.reginleif.io" -Type SRV -Server 172.17.0.10
```

### Reconfigure DC1 DNS

Once DC2 DNS is verified, update DC1 to use the reciprocal configuration.

**On DC1 (`P-WIN-DC1`):**

```powershell
# [P-WIN-DC1]
# Update DNS server addresses - partner DC first, own static IP second
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.17.0.10", "172.16.0.10"

# Verify the change
Get-DnsClientServerAddress -InterfaceAlias "Ethernet"
```

**On DC2 (`H-WIN-DC2`):**

```powershell
# [H-WIN-DC2]
# Update DNS server addresses - partner DC first, own static IP second
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.16.0.10", "172.17.0.10"

# Verify the change
Get-DnsClientServerAddress -InterfaceAlias "Ethernet"
```

### Validation

Confirm both DCs can resolve each other and replication works:

```powershell
# On DC1 - Test DNS resolution
Resolve-DnsName -Name "H-WIN-DC2.reginleif.io"

# On DC1 - Force replication and check status
repadmin /syncall /AdeP
repadmin /showrepl
```

> **Why static IP instead of 127.0.0.1?** Microsoft recommends using the server's actual static IP rather than loopback because `127.0.0.1` doesn't bind to the network stack the same way. During boot or service restart scenarios, loopback may not resolve correctly. Using the static IP ensures consistent DNS behavior and aligns with enterprise best practices.

> [!NOTE]
> **DNS Order Evolution:** This project uses "partner DC first, self second" to resolve the immediate AD Island problem when DC2 is newly promoted. Project 11 (VLAN Segmentation) will reconfigure DNS to "self first, partner second" which is appropriate once both DCs have stable, production-ready DNS services. Both approaches are valid - the key fix here is eliminating `127.0.0.1` (loopback).

### Create Reverse DNS Zones

Before finalizing DNS configuration, create reverse lookup zones to enable PTR record registration. Without these zones, DHCP dynamic DNS updates (Project 10) will silently fail for reverse lookups.

**On DC1 (`P-WIN-DC1`):**

```powershell
# [P-WIN-DC1]
# Create reverse zones for both subnets with Forest-wide replication
Add-DnsServerPrimaryZone -NetworkID "172.16.0.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.17.0.0/24" -ReplicationScope "Forest"

# Verify zones were created
Get-DnsServerZone | Where-Object { $_.IsReverseLookupZone -eq $true }
```

> **Why Forest replication scope?** Creating both reverse zones on DC1 with `-ReplicationScope "Forest"` ensures DC2 automatically receives the zones through AD replication. No manual zone creation is required on DC2.
>
> **What are reverse DNS zones and PTR records?** Forward DNS uses A records to resolve names to IPs (`p-win-dc1.reginleif.io` → `172.16.0.10`). Reverse DNS uses PTR (Pointer) records to resolve IPs back to names (`172.16.0.10` → `p-win-dc1.reginleif.io`). PTR records are stored in reverse lookup zones. Many applications and security tools rely on reverse lookups for validation, logging, and spam filtering.

### Configure DNS Forwarders for External Resolution

AD DNS servers are authoritative for the `reginleif.io` zone but cannot resolve external domains (like `google.com`) without forwarders.

**How DNS resolution works with forwarders:**

```text
Domain client queries "google.com"
        ↓
    Local DC (DNS Server)
        ↓
    "Is this reginleif.io?" → No
        ↓
    Forward to OPNsense (Unbound)
        ↓
    OPNsense resolves via root servers
        ↓
    Response returned to client
```

**Why OPNsense instead of public DNS?**

* Keeps external DNS traffic local to each site (no WAN dependency)
* OPNsense runs Unbound, a full recursive resolver
* Enables DNS filtering/logging at the gateway if needed
* Each site is self-sufficient for external resolution

**On DC1 (`P-WIN-DC1`):**

```powershell
# [P-WIN-DC1]
# Add OPNsense as DNS forwarder
Add-DnsServerForwarder -IPAddress "172.16.0.1"

# Verify forwarder configuration
Get-DnsServerForwarder
```

**On DC2 (`H-WIN-DC2`):**

```powershell
# [H-WIN-DC2]
# Add OPNsense as DNS forwarder
Add-DnsServerForwarder -IPAddress "172.17.0.1"

# Verify forwarder configuration
Get-DnsServerForwarder
```

**Test external resolution:**

```powershell
# Should resolve to external IP
Resolve-DnsName google.com

# Verify internet connectivity
Test-Connection 1.1.1.1
```

---

## 7. Verify DC2 Time Synchronization

Confirm DC2 is syncing from DC1 (configured in Section 5).

**On DC2 (`H-WIN-DC2`):**

```powershell
# [H-WIN-DC2]
# Verify time source
w32tm /query /source

# Check time offset between DCs (should be < 1 second)
w32tm /stripchart /computer:P-WIN-DC1 /samples:3 /dataonly
```

**Expected output:**

```text
P-WIN-DC1.reginleif.io
```

> **Troubleshooting:** If DC2 shows "Local CMOS Clock" or "Free-running System Clock", re-run the configuration commands from Section 5.

---

## 8. Final Validation

### IP Configuration Summary

| Setting | P-WIN-DC1 (HQ) | H-WIN-DC2 (Branch) |
| :--- | :--- | :--- |
| **IP Address** | `172.16.0.10` | `172.17.0.10` |
| **Subnet Mask** | `255.255.255.0` | `255.255.255.0` |
| **Gateway** | `172.16.0.1` | `172.17.0.1` |
| **DNS 1** | `172.17.0.10` (Partner DC) | `172.16.0.10` (Partner DC) |
| **DNS 2** | `172.16.0.10` (Self) | `172.17.0.10` (Self) |
| **DNS Forwarder** | `172.16.0.1` (OPNsense HQ) | `172.17.0.1` (OPNsense Branch) |
| **NTP Source** | `172.16.0.1` (OPNsense) | `P-WIN-DC1` (Domain Hierarchy) |

### Validation Checklist

* [ ] **VPN Handshake:** Check OPNsense Dashboard -> WireGuard widget for "Last Handshake" time.
* [ ] **Ping Test:** Ping `172.17.0.10` from `P-WIN-DC1`. (Should be <10ms if local).
* [ ] **DNS Resolution:** `nslookup h-win-dc2.reginleif.io` from HQ should resolve to `172.17.0.10`.
* [ ] **AD Replication:** Run PowerShell:

    ```powershell
    Get-ADReplicationPartnerMetadata -Target P-WIN-DC1
    repadmin /showrepl
    ```

* [ ] **NTP Time Sync:** Verify both DCs have correct time sources:

    ```powershell
    # On DC1 - Should show external NTP source
    w32tm /query /source

    # On DC2 - Should show DC1 as source
    w32tm /query /source
    ```

* [ ] **External DNS Resolution:** Verify both DCs can resolve external domains:

    ```powershell
    Resolve-DnsName google.com
    Test-Connection 1.1.1.1
    ```
