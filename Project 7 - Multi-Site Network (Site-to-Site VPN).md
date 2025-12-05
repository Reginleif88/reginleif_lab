---
title: "Project 7: Multi-Site Network (Site-to-Site VPN)"
tags: [OPNsense, networking, vpn, proxmox, hyper-v, active-directory]
sites: [hq, branch]
status: in-progress
---

## Goal
Simulate a corporate **"Headquarters vs. Branch Office"** topology. Connect the Proxmox environment (HQ) and Hyper-V environment (Branch) via an encrypted **WireGuard Site-to-Site VPN** to allow secure Active Directory replication and transparent routing between sites.

---

## 1. Architecture Design

### Topology Overview

| Feature               | Site A (HQ)                | Site B (Branch)            |
| :-------------------- | :------------------------- | :------------------------- |
| **Hypervisor**        | Proxmox VE                 | Windows Hyper-V            |
| **Gateway VM**        | OPNsenseHQ                 | OPNsenseBranch             |
| **WAN IP**            | `192.168.1.240` (Home LAN) | `192.168.1.245` (Home LAN) |
| **LAN Subnet**        | **`172.16.0.0/24`**        | **`172.17.0.0/24`**        |
| **Gateway IP**        | `172.16.0.1`               | `172.17.0.1`               |
| **Domain Controller** | `P-WIN-DC1` (`172.16.0.10`)        | `H-WIN-DC2` (`172.17.0.10`)            |

---

## 2. OPNsense Configuration

### A. Interface Assignments
1.  **OPNsenseHQ:**
    * **WAN:** `vtnet0` (Bridged to Home Network/vmbr0).
    * **LAN:** `vtnet1` (Static `172.16.0.1/24`).
2.  **OPNsenseBranch:**
    * **WAN:** `hn0` (Bridged to Physical NIC/Default Switch).
    * **LAN:** `hn1` (Static `172.17.0.1/24`).

### B. WireGuard VPN Setup

**Pre-requisite:** Install `os-wireguard` plugin on both nodes.

#### Step 1: HQ Configuration (The Server)
* **Instance (Local):**
    * **Public Key:** (Generate & Save)
    * **Private Key:** (Generate & Save)
    * **Listen Port:** `51820`
    * **Tunnel Address:** `10.200.0.1/32`
* **Peer (The Branch):**
    * **Public Key:** (Paste Branch's Public Key)
    * **Endpoint Address:** `192.168.1.245`
    * **Endpoint Port:** `51820`
    * **Allowed IPs:** `172.17.0.0/24`, `10.200.0.2/32`
    * *(Note: This tells HQ to route traffic for 172.17.0.x into the tunnel)*

#### Step 2: Branch Configuration (The Client)
* **Instance (Local):**
    * **Public Key:** (Generate & Save)
    * **Private Key:** (Generate & Save)
    * **Listen Port:** `51820`
    * **Tunnel Address:** `10.200.0.2/32`
* **Peer (The HQ):**
    * **Public Key:** (Paste HQ's Public Key)
    * **Endpoint Address:** `192.168.1.240`
    * **Endpoint Port:** `51820`
    * **Allowed IPs:** `172.16.0.0/24`, `10.200.0.0/24`
    * *(Note: This tells Branch to route traffic for 172.16.0.x and Road Warrior clients into the tunnel)*

### C. Firewall Rules

#### Prerequisite: Create Firewall Alias (Both Sites)

Before configuring rules, create an alias to represent all trusted lab networks. This follows enterprise best practices for zone-based firewall management.

1. **Navigate to:** Firewall > Aliases
2. **Add New Alias:**
    * **Name:** `Trusted_Lab_Networks`
    * **Type:** Network(s)
    * **Content:**
        * `172.16.0.0/24` (HQ LAN)
        * `172.17.0.0/24` (Branch LAN)
        * `10.200.0.0/24` (WireGuard Tunnel)
    * **Description:** All trusted internal networks for inter-site communication

> **Why use an alias?** In enterprise environments, firewall rules reference aliases (or "address groups") rather than hardcoded subnets. This makes rules easier to audit, update, and maintain. When you add a new site or VPN subnet, you update the alias once rather than modifying multiple rules.

#### 1. WAN Interface (Both Sites)
* **Action:** Pass
* **Protocol:** UDP
* **Destination Port:** 51820
* **Description:** Allow WireGuard Handshake

#### 2. WireGuard Interface (Both Sites)
* **Action:** Pass
* **Protocol:** IPv4 (Any)
* **Source:** `Trusted_Lab_Networks`
* **Destination:** `Trusted_Lab_Networks`
* **Description:** Allow all traffic between trusted lab networks

> **Note:** This single rule permits all inter-site traffic including AD replication (LDAP, Kerberos, RPC), file sharing (SMB), DNS queries, and road warrior VPN access. The alias ensures traffic from any trusted network (`172.16.0.x`, `172.17.0.x`, or `10.200.0.x`) can reach any other trusted network.

---

## 3. Active Directory Configuration (AZ-800 Focus)

**Crucial:** AD must be aware of the physical network topology to optimize replication.

1.  **Open AD Sites and Services (`dssite.msc`):**
    * Rename `Default-First-Site-Name` to **`HQ-Proxmox`**.
    * Create New Site named **`Branch-HyperV`**.
2.  **Define Subnets:**
    * Create Subnet `172.16.0.0/24` -> Associate with **`HQ-Proxmox`**.
    * Create Subnet `172.17.0.0/24` -> Associate with **`Branch-HyperV`**.
3.  **Assign Servers:**
    * Move `H-WIN-DC2` object into the **`Branch-HyperV`** site.
4.  **Configure Transports:**
    * Ensure the IP link is created and replication schedule is set (default is 180 mins; lower this to 15 mins for lab testing).

---

## 4. Prepare DC2 for Domain Join

After VPN is established, reconfigure DC2's DNS to point to the HQ Domain Controller.

**On H-WIN-DC2:**

**Note:** Interface name may vary. Run `Get-NetAdapter` to confirm.

```powershell
# Update DNS to HQ DC (required for domain operations)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.16.0.10"

# Verify DNS change
Get-DnsClientServerAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4

# Test AD DNS resolution
nslookup reginleif.io 172.16.0.10
```

**Note:** DNS was initially set to `172.17.0.1` (OPNsense) in Project 6 for basic connectivity. Now that the VPN tunnel is active, DC2 can reach the HQ DC for Active Directory DNS.

---

## 5. Promote DC2 to Domain Controller

**On H-WIN-DC2:**

```powershell
# Install AD Domain Services role
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Promote to Domain Controller (Branch site)
Install-ADDSDomainController `
    -DomainName "reginleif.io" `
    -SiteName "Branch-HyperV" `
    -InstallDns:$true `
    -Credential (Get-Credential "REGINLEIF\Administrator") `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "<YourSafeModePassword>" -AsPlainText -Force) `
    -Force
```

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
- During boot, the local DNS Server service may not be running yet
- The DC cannot resolve SRV records for other Domain Controllers
- It may register itself as authoritative for zones incorrectly
- AD replication fails because it can't discover replication partners

**Current DC1 Configuration (Problematic):**
- Primary DNS: `127.0.0.1` (loopback)
- Secondary DNS: `172.17.0.10` (DC2)

**Microsoft Best Practice:** DCs should point to a partner DC first, then optionally to themselves as secondary.

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
# Update DNS server addresses - partner DC first, loopback second
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.17.0.10", "127.0.0.1"

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

---

## 7. Server Migration & Validation

### IP Configuration
| Setting | P-WIN-DC1 (HQ) | H-WIN-DC2 (Branch) |
| :--- | :--- | :--- |
| **IP Address** | `172.16.0.10` | `172.17.0.10` |
| **Subnet Mask** | `255.255.255.0` | `255.255.255.0` |
| **Gateway** | `172.16.0.1` | `172.17.0.1` |
| **DNS 1** | `172.17.0.10` | `172.16.0.10` |
| **DNS 2** | `127.0.0.1` | `127.0.0.1` |

### Validation Checklist
- [ ] **VPN Handshake:** Check OPNsense Dashboard -> WireGuard widget for "Last Handshake" time.
- [ ] **Ping Test:** Ping `172.17.0.10` from `P-WIN-DC1`. (Should be <10ms if local).
- [ ] **DNS Resolution:** `nslookup h-win-dc2.reginleif.io` from HQ should resolve to `172.17.0.10`.
- [ ] **AD Replication:** Run PowerShell:
    ```powershell
    Get-ADReplicationPartnerMetadata -Target P-WIN-DC1
    repadmin /showrepl
    ```
