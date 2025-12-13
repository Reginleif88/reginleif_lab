---
title: "Project 10: DHCP Migration to Domain Controllers"
tags: [dhcp, migration, active-directory, windows-server, powershell]
sites: [hq, branch]
status: completed
---

## Goal

Configure DHCP on both Domain Controllers to provide IP addresses with AD-integrated DNS registration. Each DC manages DHCP for its respective site.

---

The following table summarizes DHCP configuration per site:

| Site | DC | Subnet | DHCP Range | Reserved |
| :------ | :----- | :-------- | :------------ | :---------- |
| HQ | P-WIN-DC1 | 172.16.0.0/24 | .30 - .254 | .1 - .29 |
| Branch | H-WIN-DC2 | 172.17.0.0/24 | .30 - .254 | .1 - .29 |

> [!NOTE]
> Each site has a single DHCP server with no failover configured. This is acceptable for lab purposes where brief outages are tolerable. For production resilience, DHCP failover between partner servers would be implemented. A future project will add dedicated DHCP servers with failover at each site.

> [!TIP]
> This project demonstrates both configuration methods:
>
> - **DC1 (HQ)**: RSAT GUI from P-WIN-SRV1
> - **DC2 (Branch)**: PowerShell (core server)
>
> This approach lets you practice the same tasks using different tools.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-10-concepts)**

For educational context about DHCP, the DORA process, lease lifecycle, and DHCP relay, see the dedicated concepts guide.

---

## 1. Install DHCP Role

### Prerequisites - Install DHCP Management Tools (P-WIN-SRV1)

1. Open **Server Manager** on P-WIN-SRV1
2. Click **Manage** → **Add Roles and Features**
3. Select **P-WIN-SRV1.reginleif.io** from the server pool
4. Skip **Roles** (click Next)
5. In **Features**, expand **Remote Server Administration Tools** → **Role Administration Tools**
6. Check **DHCP Server Tools**
7. Complete the wizard

### DC1 - GUI Method (from P-WIN-SRV1)

1. Open **Server Manager** on P-WIN-SRV1
2. Click **Manage** → **Add Roles and Features**
3. Select **Role-based or feature-based installation**
4. Select **P-WIN-DC1.reginleif.io** from the server pool
5. Check **DHCP Server** under Roles
6. Complete the wizard and wait for installation
7. After installation, click the notification flag in Server Manager
8. Click **Complete DHCP configuration**
9. In the wizard, click **Commit** to authorize the server in AD

### DC2 - PowerShell Method

```powershell
# [H-WIN-DC2]
# Install DHCP Server role
Install-WindowsFeature DHCP -IncludeManagementTools
```

### Authorize DC2 in Active Directory

Only authorized DHCP servers can issue leases in an AD environment.

```powershell
# [H-WIN-DC2]
Add-DhcpServerInDC -DnsName "H-WIN-DC2.reginleif.io" -IPAddress 172.17.0.10

# Force AD replication so DC1 and SRV1 see the authorization immediately
repadmin /syncall /AdeP
```

### Verify Authorization

**GUI (from P-WIN-SRV1):**

1. Open **DHCP** management console (dhcpmgmt.msc)
2. Right-click **DHCP** → **Manage authorized servers**
3. Verify both DCs are listed

**PowerShell:**

```powershell
# [Either DC]
Get-DhcpServerInDC
```

---

## 2. Configure HQ Scope (DC1) - GUI Method

From **P-WIN-SRV1**:

1. Open **DHCP** management console (dhcpmgmt.msc)
2. Right-click **DHCP** → **Add Server**
3. Enter `P-WIN-DC1` and click **OK**
4. Expand **P-WIN-DC1** → **IPv4**
5. Right-click **IPv4** → **New Scope**

### New Scope Wizard

1. **Name**: `HQ-LAN`
2. **IP Address Range**:
   - Start IP: `172.16.0.30`
   - End IP: `172.16.0.254`
   - Subnet mask: `255.255.255.0`
3. **Add Exclusions**: Skip (none needed)
4. **Lease Duration**: `8 hours`
5. **Configure DHCP Options**: Yes, I want to configure these options now
6. **Router (Default Gateway)**: `172.16.0.1`
7. **Domain Name and DNS Servers**:
    - Parent domain: `reginleif.io`
    - DNS servers: `172.16.0.10` and `172.17.0.10`
8. **WINS Servers**: Skip
9. **Activate Scope**: Yes
10. Click **Finish**

> [!NOTE]
> Lease duration is set to 8 hours, suitable for a lab environment.

---

## 3. Configure Branch Scope (DC2) - PowerShell Method

Run on **H-WIN-DC2**:

```powershell
# [H-WIN-DC2]
# Create the scope
Add-DhcpServerv4Scope -Name "Branch-LAN" `
    -StartRange 172.17.0.30 `
    -EndRange 172.17.0.254 `
    -SubnetMask 255.255.255.0 `
    -LeaseDuration 0.08:00:00 `
    -State Active

# Set scope options (Gateway, DNS, Domain)
Set-DhcpServerv4OptionValue -ScopeId 172.17.0.0 `
    -Router 172.17.0.1 `
    -DnsServer 172.17.0.10,172.16.0.10 `
    -DnsDomain "reginleif.io"
```

> [!NOTE]
> DNS order is reversed - local DC first for faster resolution.

---

## 4. DNS Dynamic Update Settings

Configure DHCP to register DNS records for clients automatically.

### Why DNS Dynamic Updates Matter

When clients receive DHCP leases, they need corresponding DNS records so other systems can resolve their hostnames to IP addresses. Without dynamic DNS updates:

- **Manual overhead**: Administrators would need to create and maintain DNS records for every DHCP client
- **Stale records**: When leases expire or renew with different IPs, DNS records would become outdated
- **Name resolution failures**: Computers couldn't reliably find each other by hostname

With Active Directory-integrated DHCP and DNS:

- **Automatic registration**: DHCP registers both forward (A) and reverse (PTR) records as leases are assigned
- **Automatic cleanup**: Records are removed when leases expire, keeping DNS clean
- **Secure updates**: Only authorized DHCP servers can update DNS in AD-integrated zones
- **Legacy support**: The server can register records even for clients that don't support dynamic DNS (older OS, non-Windows devices)

### Configure DC1 (GUI Method from P-WIN-SRV1)

1. In DHCP console, expand **P-WIN-DC1** → **IPv4**
2. Right-click **IPv4** → **Properties**
3. Go to the **DNS** tab
4. Configure:
   - Check **Enable DNS dynamic updates according to the settings below**
   - Select **Always dynamically update DNS records**
   - Check **Discard A and PTR records when lease is deleted**
   - Check **Dynamically update DNS records for DHCP clients that do not request updates**
5. Click **OK**

### Configure DC2 (PowerShell Method)

```powershell
# [H-WIN-DC2]
# Enable dynamic DNS updates
Set-DhcpServerv4DnsSetting -ComputerName localhost `
    -DynamicUpdates "Always" `
    -DeleteDnsRROnLeaseExpiry $true `
    -UpdateDnsRRForOlderClients $true
```

### Understanding DNS Registration

| Client Type | DNS Registration |
| :------------- | :------------------ |
| Domain-joined Windows | Client registers A record, DHCP registers PTR |
| Non-domain Windows | DHCP registers both A and PTR (if enabled) |
| Linux/Other | DHCP registers both A and PTR (if enabled) |

> [!NOTE]
> `UpdateDnsRRForOlderClients` allows DHCP to register records for non-Windows clients.

### Enable Conflict Detection (Optional)

Configure DHCP to check for IP conflicts before assigning addresses. This prevents duplicate IP assignment if a static IP is accidentally configured within the DHCP range.

**DC1 - GUI Method (from P-WIN-SRV1):**

1. In DHCP console, expand **P-WIN-DC1** → **IPv4**
2. Right-click **IPv4** → **Properties**
3. Go to the **Advanced** tab
4. Set **Conflict detection attempts** to `2`
5. Click **OK**

**DC2 - PowerShell Method:**

```powershell
# [H-WIN-DC2]
# Enable conflict detection with 2 ping attempts before assignment
Set-DhcpServerSetting -ComputerName localhost -ConflictDetectionAttempts 2
```

> [!NOTE]
> Conflict detection adds ~2 seconds to lease acquisition (time for ping attempts). For lab environments with few static IPs, this minor delay provides worthwhile protection against misconfigurations.

> [!NOTE]
> **After implementing VLAN segmentation (Project 11)**, DHCP clients on different VLANs than the DHCP server will require DHCP relay configuration. See **Project 11** for DHCP relay setup on OPNsense.

---

## 5. Validation

### Check DHCP Server Status

**GUI (from P-WIN-SRV1):**

1. In DHCP console, expand each server → **IPv4**
2. View scopes under each server
3. Right-click a scope → **Display Statistics** to see lease information

**PowerShell:**

```powershell
# View all scopes
Get-DhcpServerv4Scope

# View scope statistics
Get-DhcpServerv4ScopeStatistics
```

### View Active Leases (when we have some clients)

**GUI (from P-WIN-SRV1):**

1. In DHCP console, expand the server → **IPv4** → scope
2. Click **Address Leases** to view all active leases

**PowerShell:**

```powershell
# On DC1
Get-DhcpServerv4Lease -ScopeId 172.16.0.0

# On DC2
Get-DhcpServerv4Lease -ScopeId 172.17.0.0
```
