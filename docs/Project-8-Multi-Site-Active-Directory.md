---
title: "Project 8: Multi-Site Active Directory Configuration"
tags: [active-directory, windows-server, dns, replication]
sites: [hq, branch]
status: planned
---

## Goal

Configure Active Directory for multi-site operation after the WireGuard VPN tunnel is established (Project 7). This includes Windows firewall rules, AD Sites and Services, promoting the Branch DC, and configuring DNS for proper replication.

---

## Prerequisites

* Project 7 completed (Site-to-Site VPN working)
* P-WIN-DC1 (HQ) is already a Domain Controller for `reginleif.io`
* H-WIN-DC2 (Branch) is a Windows Server ready for promotion

---

## 1. Windows Host Firewall Configuration

> **Important:** OPNsense firewall rules control traffic at the network gateway level, but Windows Server has its own host-based firewall that applies independently. By default, Windows blocks SMB (File Sharing), RPC (AD Replication), and ICMP (Ping) from "foreign" subnets.

**The Issue:** Even with a perfectly configured VPN, Windows will block:

* ICMP Echo Requests (ping) from remote subnets
* SMB (TCP 445) for file shares and SYSVOL replication
* RPC (Dynamic ports) for AD replication
* LDAP, Kerberos, and other AD protocols

This is the **#1 reason** site-to-site VPN labs fail validation tests.

### Configure Windows Firewall (Both DCs)

**On P-WIN-DC1 (HQ) and H-WIN-DC2 (Branch):**

```powershell
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
Get-NetFirewallRule -DisplayName "Allow Lab*" | Format-Table Name, DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow ICMPv4*" | Format-Table Name, DisplayName, Enabled
```

> **Production Note:** In production environments, you would create granular rules for specific ports (53, 88, 135, 389, 445, 464, 636, 3268, 3269, 49152-65535) rather than allowing all TCP/UDP. For lab purposes, the broad rule simplifies troubleshooting.

---

## 2. Active Directory Sites Configuration

> **Why Sites Matter:** Without site configuration, Active Directory assumes all Domain Controllers are on the same fast LAN. This causes problems in multi-site environments:

| Without Sites | With Sites |
| --------------- | ------------ |
| Clients may authenticate against DCs across slow VPN links | Clients find the nearest DC in their subnet |
| Replication happens immediately (floods WAN) | Replication is scheduled and compressed for WAN links |
| DFS/SYSVOL referrals ignore network topology | Clients access local file servers first |

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

> **Note:** `H-WIN-DC2` will automatically be placed in the `Branch-HyperV` site during DC promotion (Section 5) when you specify `-SiteName "Branch-HyperV"`. No manual server move is required.

---

## 3. Prepare DC2 for Domain Join

After VPN is established, reconfigure DC2's DNS to point to the HQ Domain Controller.

**On H-WIN-DC2:**

> **Note:** Interface name may vary. Run `Get-NetAdapter` to confirm.

```powershell
# Update DNS to HQ DC (required for domain operations)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.16.0.10"

# Verify DNS change
Get-DnsClientServerAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4

# Test AD DNS resolution
nslookup reginleif.io 172.16.0.10
```

> **Note:** DNS was initially set to `172.17.0.1` (OPNsense) in Project 6 for basic connectivity. Now that the VPN tunnel is active, DC2 can reach the HQ DC for Active Directory DNS.

---

## 4. Configure DC1 NTP (Before Promotion)

### Why Time Sync Must Be Configured First

Kerberos authentication, the backbone of Active Directory security, uses timestamps to prevent replay attacks. By default, Kerberos allows a maximum **5-minute time skew** between a client and the authenticating DC. If clocks drift beyond this threshold:

* DC promotion fails with authentication errors
* Domain joins fail
* AD replication breaks with "access denied" errors
* Users cannot log in

**This must be configured before promoting DC2**, otherwise the promotion may fail due to time skew between the servers.

**Active Directory Time Hierarchy:**

```
External NTP (pool.ntp.org)
        ↓
   PDC Emulator (DC1) ─── Authoritative time source for domain
        ↓
   Other DCs (DC2) ─────── Sync from PDC Emulator
        ↓
   Domain Members ──────── Sync from authenticating DC
```

The **PDC Emulator** (by default, the first DC in the forest - `P-WIN-DC1`) is the authoritative time source. It must sync to a reliable external source. All other DCs and domain members automatically sync through the AD hierarchy once joined.

### Configure DC1 (PDC Emulator) for External NTP

**On DC1 (`P-WIN-DC1`):**

```powershell
# Configure external NTP servers (pool.ntp.org recommended)
w32tm /config /manualpeerlist:"0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org" /syncfromflags:manual /reliable:yes /update

# Restart the Windows Time service
Restart-Service w32time

# Force immediate sync
w32tm /resync /rediscover

# Verify configuration
w32tm /query /configuration
w32tm /query /status
```

**Expected output from `/query/status`:**

```
Source: 0.pool.ntp.org (or similar)
Stratum: 2 or 3
```

> **What is Stratum?** NTP uses a hierarchy called "stratum" to indicate distance from an authoritative time source. Stratum 0 is an atomic clock, Stratum 1 is directly connected to it, Stratum 2 syncs from Stratum 1, etc. Your DC will typically be Stratum 2-4, which is normal.

---

## 5. Promote DC2 to Domain Controller

**On H-WIN-DC2:**

```powershell
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

> **Note:** The command will prompt for the Directory Services Restore Mode (DSRM) password.

**Post-Reboot:** Server restarts automatically. DC2 is now a fully functional domain controller in the Branch site.

**Verify Promotion:**

```powershell
# Check DC status
Get-ADDomainController -Identity H-WIN-DC2

# Verify SYSVOL/NETLOGON shares
Get-SmbShare | Where-Object { $_.Name -match "SYSVOL|NETLOGON" }
```

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
# Update DNS server addresses - partner DC first, own static IP second
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.17.0.10", "172.16.0.10"

# Verify the change
Get-DnsClientServerAddress -InterfaceAlias "Ethernet"
```

**On DC2 (`H-WIN-DC2`):**

```powershell
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

### Create Reverse DNS Zones

Before finalizing DNS configuration, create reverse lookup zones to enable PTR record registration. Without these zones, DHCP dynamic DNS updates (Project 10) will silently fail for reverse lookups.

**On DC1 (`P-WIN-DC1`):**

```powershell
# Create reverse zones for both subnets with Forest-wide replication
Add-DnsServerPrimaryZone -NetworkID "172.16.0.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.17.0.0/24" -ReplicationScope "Forest"

# Verify zones were created
Get-DnsServerZone | Where-Object { $_.IsReverseLookupZone -eq $true }
```

> **Why Forest replication scope?** Creating both reverse zones on DC1 with `-ReplicationScope "Forest"` ensures DC2 automatically receives the zones through AD replication. No manual zone creation is required on DC2.

> **What are reverse DNS zones and PTR records?** Forward DNS uses A records to resolve names to IPs (`p-win-dc1.reginleif.io` → `172.16.0.10`). Reverse DNS uses PTR (Pointer) records to resolve IPs back to names (`172.16.0.10` → `p-win-dc1.reginleif.io`). PTR records are stored in reverse lookup zones. Many applications and security tools rely on reverse lookups for validation, logging, and spam filtering.

### Configure DNS Forwarders for External Resolution

AD DNS servers are authoritative for the `reginleif.io` zone but cannot resolve external domains (like `google.com`) without forwarders. Configure each DC to forward external queries to its local OPNsense gateway, which runs Unbound DNS resolver.

**On DC1 (`P-WIN-DC1`):**

```powershell
# Add OPNsense as DNS forwarder
Add-DnsServerForwarder -IPAddress "172.16.0.1"

# Verify forwarder configuration
Get-DnsServerForwarder
```

**On DC2 (`H-WIN-DC2`):**

```powershell
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

> **Why use OPNsense as forwarder?** Each DC forwards to its local OPNsense gateway rather than directly to public DNS (8.8.8.8, 1.1.1.1). This keeps external DNS traffic local to each site, reduces WAN dependency, and allows OPNsense to provide DNS filtering/logging if configured. OPNsense runs Unbound, a full recursive resolver, so it can resolve any public domain.

---

## 7. Verify DC2 Time Synchronization

After promotion, DC2 should automatically sync time from the domain hierarchy (ultimately from DC1, the PDC Emulator configured in Section 4).

**On DC2 (`H-WIN-DC2`):**

```powershell
# Check current time source
w32tm /query /status

# Force rediscovery of time source
w32tm /resync /rediscover

# Verify it syncs from domain hierarchy
w32tm /query /source
```

**Expected output:**

```
P-WIN-DC1.reginleif.io
```

If DC2 shows "Local CMOS Clock" or "Free-running System Clock", force it to use the domain hierarchy:

```powershell
# Reset DC2 to use domain hierarchy (NT5DS = domain hierarchy for DCs)
w32tm /config /syncfromflags:domhier /update
Restart-Service w32time
w32tm /resync /rediscover
```

**Verify time offset between DCs (should be < 1 second):**

```powershell
w32tm /stripchart /computer:P-WIN-DC1 /samples:3 /dataonly
```

> **Hyper-V Time Sync Warning:** Hyper-V has a "Time Synchronization" integration service that can conflict with AD time sync. For DC2 running on Hyper-V, consider disabling this in the VM settings (Integration Services → uncheck Time Synchronization) to let AD control time. Alternatively, leave it enabled but understand that AD time sync takes precedence for domain-joined machines.

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
| **NTP Source** | `pool.ntp.org` (External) | `P-WIN-DC1` (Domain Hierarchy) |

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
