---
title: "Project 10: DHCP Migration to Domain Controllers"
tags: [dhcp, active-directory, powershell, networking]
sites: [hq, branch]
status: planned
---

## Goal
Configure DHCP on both Domain Controllers to provide IP addresses with AD-integrated DNS registration. Each DC manages DHCP for its respective site.

---

| Site | DC | Subnet | DHCP Range | Reserved |
|------|-----|--------|------------|----------|
| HQ | P-WIN-DC1 | 172.16.0.0/24 | .30 - .254 | .1 - .29 |
| Branch | H-WIN-DC2 | 172.17.0.0/24 | .30 - .254 | .1 - .29 |

---

## 1. Install DHCP Role

Run on **both** Domain Controllers:

```powershell
# Install DHCP Server role
Install-WindowsFeature DHCP -IncludeManagementTools

# Restart if required
Restart-Computer -Force
```

### Authorize DHCP Servers in Active Directory

Only authorized DHCP servers can issue leases in an AD environment.

**On DC1 (P-WIN-DC1):**
```powershell
Add-DhcpServerInDC -DnsName "P-WIN-DC1.reginleif.io" -IPAddress 172.16.0.10
```

**On DC2 (H-WIN-DC2):**
```powershell
Add-DhcpServerInDC -DnsName "H-WIN-DC2.reginleif.io" -IPAddress 172.17.0.10
```

### Verify Authorization
```powershell
Get-DhcpServerInDC
```

---

## 2. Configure HQ Scope (DC1)

Run on **P-WIN-DC1**:

```powershell
# Create the scope
Add-DhcpServerv4Scope -Name "HQ-LAN" `
    -StartRange 172.16.0.30 `
    -EndRange 172.16.0.254 `
    -SubnetMask 255.255.255.0 `
    -LeaseDuration 0.08:00:00 `
    -State Active

# Set scope options (Gateway, DNS, Domain)
Set-DhcpServerv4OptionValue -ScopeId 172.16.0.0 `
    -Router 172.16.0.1 `
    -DnsServer 172.16.0.10,172.17.0.10 `
    -DnsDomain "reginleif.io"
```

**Note:** Lease duration is set to 8 hours, suitable for a lab environment.

---

## 3. Configure Branch Scope (DC2)

Run on **H-WIN-DC2**:

```powershell
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

**Note:** DNS order is reversed - local DC first for faster resolution.

---

## 4. DNS Dynamic Update Settings

Configure DHCP to register DNS records for clients automatically.

Run on **both** DCs:

```powershell
# Enable dynamic DNS updates
Set-DhcpServerv4DnsSetting -ComputerName localhost `
    -DynamicUpdates "Always" `
    -DeleteDnsRROnLeaseExpiry $true `
    -UpdateDnsRRForOlderClients $true
```

### Understanding DNS Registration

| Client Type | DNS Registration |
|-------------|------------------|
| Domain-joined Windows | Client registers A record, DHCP registers PTR |
| Non-domain Windows | DHCP registers both A and PTR (if enabled) |
| Linux/Other | DHCP registers both A and PTR (if enabled) |

**Note:** `UpdateDnsRRForOlderClients` allows DHCP to register records for non-Windows clients.

---

## 5. Validation

### Check DHCP Server Status
```powershell
# View all scopes
Get-DhcpServerv4Scope

# View scope statistics
Get-DhcpServerv4ScopeStatistics
```

### Test DHCP Lease Acquisition

From a client on the network:

**Windows:**
```powershell
# Release current lease
ipconfig /release

# Request new lease
ipconfig /renew

# Verify IP and DNS settings
ipconfig /all
```

**Linux:**
```bash
# Release and renew (varies by distro)
sudo dhclient -r
sudo dhclient

# Verify
ip addr show
cat /etc/resolv.conf
```

### Verify DNS Registration

On a Domain Controller:
```powershell
# Check if client hostname appears in DNS
Get-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "<client-hostname>"

# List all A records in the zone
Get-DnsServerResourceRecord -ZoneName "reginleif.io" -RRType A
```

### View Active Leases
```powershell
# On DC1
Get-DhcpServerv4Lease -ScopeId 172.16.0.0

# On DC2
Get-DhcpServerv4Lease -ScopeId 172.17.0.0
```
