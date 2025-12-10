---
title: "Project 11: VLAN Network Segmentation"
tags: [vlan, network, opnsense, proxmox, hyper-v, segmentation]
sites: [hq, branch]
status: in-progress
---

## Goal

Implement VLAN segmentation at both sites, transforming the flat network into a properly segmented enterprise-style topology. This prepares the infrastructure for future client workstations (Project 16) by separating user traffic from infrastructure services.

---

## Why NOT Use VLAN 1 for Domain Controllers?

> [!WARNING]
> **VLAN 1 should never be used for production infrastructure, especially Domain Controllers.**

While it will technically "work," using VLAN 1 for your most critical assets is a significant security and management bad practice. Here's why:

### 1. The "Default Port" Risk

VLAN 1 is the factory default for every port on almost every switch (Cisco, HP, Ubiquiti, etc.).

- **The Scenario:** If you or a junior admin patches a device into a switch port that hasn't been configured yet, that device implicitly lands on VLAN 1.
- **The Risk:** If your Domain Controllers are on VLAN 1, that unconfigured port gives immediate network layer access to your most sensitive servers.

### 2. VLAN Hopping Attacks (Double Tagging)

VLAN 1 is typically the default "Native VLAN." In 802.1Q trunking, the Native VLAN is untagged.

- **The Risk:** Attackers can exploit the way switches handle untagged frames to "hop" from one VLAN to another. While modern switches have mitigations, keeping sensitive data (AD/DNS) on the Native VLAN unnecessarily increases your attack surface.

### 3. Control Plane Traffic Noise

VLAN 1 is used by switches to communicate with each other (CDP, VTP, PAgP, DTP, STP BPDUs).

- **The Issue:** Your Domain Controller traffic will be competing with a constant stream of switch-to-switch broadcast and multicast traffic. It is cleaner to separate "Switch Talk" from "Server Talk."

### The Fix

**Use VLAN 5 for Infrastructure instead of VLAN 1.** This project implements that best practice from the start.

---

## VLAN Architecture

| VLAN ID | Name | HQ Subnet | Branch Subnet | Purpose |
|:--------|:-----|:----------|:--------------|:--------|
| 1 (Native) | Default/Unused | N/A | N/A | Blackhole VLAN (untagged on trunks, no IPs assigned) |
| 5 | Infrastructure | 172.16.5.0/24 | 172.17.5.0/24 | Domain Controllers only |
| 10 | Clients | 172.16.10.0/24 | 172.17.10.0/24 | Windows 10/11 workstations |
| 20 | Servers | 172.16.20.0/24 | 172.17.20.0/24 | Member servers (Royal Server, WDS, etc.) |
| 99 | Management | 172.16.99.0/24 | 172.17.99.0/24 | Admin access, OOB management |

### IP Addressing Convention

Each VLAN follows a consistent scheme:

| Range | Purpose |
|:------|:--------|
| x.x.VLAN.1 | Gateway (OPNsense) |
| x.x.VLAN.2-29 | Reserved for static IPs |
| x.x.VLAN.30-254 | DHCP pool (Clients VLAN only) |

> [!NOTE]
> The third octet matches the VLAN ID for easy mental mapping:
> - VLAN 5 = 172.16.**5**.0/24 (HQ) or 172.17.**5**.0/24 (Branch)
> - VLAN 10 = 172.16.**10**.0/24 (HQ) or 172.17.**10**.0/24 (Branch)

### Design Decisions

| Decision | Choice | Rationale |
|:---------|:-------|:----------|
| Domain Controllers | Infrastructure VLAN (5) | Critical AD/DNS/DHCP services, avoids VLAN 1 security risks |
| P-WIN-SRV1 | Servers VLAN (20) | Proper segmentation, IP changes to 172.16.20.11 |
| WDS/MDT (Future Project) | Servers VLAN (20) | New W2022 server (172.16.20.12), DHCP relay configured for PXE |
| Firewall rules | Permissive initially | Allow all between trusted VLANs, tighten later |
| DHCP | Clients VLAN only | Servers and Management use static IPs |

---

## 1. OPNsense VLAN Configuration

Configure VLAN interfaces on both OPNsense firewalls. The process is identical at both sites, with different IP addresses.

### A. Create VLAN Interfaces

**On OPNsenseHQ:**

1. Navigate to **Interfaces > Other Types > VLAN**
2. Click **Add** for each VLAN:

| Parent Interface | VLAN Tag | Description |
|:-----------------|:---------|:------------|
| vtnet1 (LAN) | 5 | Infrastructure |
| vtnet1 (LAN) | 10 | Clients |
| vtnet1 (LAN) | 20 | Servers |
| vtnet1 (LAN) | 99 | Management |

3. Click **Save** after each entry

**On OPNsenseBranch:**

Repeat using `hn1` as the parent interface.

### B. Assign and Configure Interfaces

**On OPNsenseHQ:**

1. Navigate to **Interfaces > Assignments**
2. For each new VLAN, select from the dropdown and click **Add**
3. Click the new interface name (e.g., OPT1, OPT2, etc.) to configure:

**VLAN 5 - Infrastructure:**

| Setting | Value |
|:--------|:------|
| Enable | Checked |
| Description | INFRA |
| IPv4 Configuration Type | Static IPv4 |
| IPv4 Address | 172.16.5.1/24 |

**VLAN 10 - Clients:**

| Setting | Value |
|:--------|:------|
| Enable | Checked |
| Description | CLIENTS |
| IPv4 Configuration Type | Static IPv4 |
| IPv4 Address | 172.16.10.1/24 |

**VLAN 20 - Servers:**

| Setting | Value |
|:--------|:------|
| Enable | Checked |
| Description | SERVERS |
| IPv4 Configuration Type | Static IPv4 |
| IPv4 Address | 172.16.20.1/24 |

**VLAN 99 - Management:**

| Setting | Value |
|:--------|:------|
| Enable | Checked |
| Description | MGMT |
| IPv4 Configuration Type | Static IPv4 |
| IPv4 Address | 172.16.99.1/24 |

4. Click **Save** and **Apply Changes** after each interface

**On OPNsenseBranch:**

Configure with 172.17.x.1/24 addresses.

| Interface | VLAN | IP Address |
|:----------|:-----|:-----------|
| INFRA | 5 | 172.17.5.1/24 |
| CLIENTS | 10 | 172.17.10.1/24 |
| SERVERS | 20 | 172.17.20.1/24 |
| MGMT | 99 | 172.17.99.1/24 |

### C. Update Firewall Alias

The `Trusted_Lab_Networks` alias must include all new VLAN subnets.

**On both OPNsense firewalls:**

1. Navigate to **Firewall > Aliases**
2. Edit `Trusted_Lab_Networks`
3. Add the following entries:

```text
172.16.5.0/24     HQ Infrastructure
172.16.10.0/24    HQ Clients
172.16.20.0/24    HQ Servers
172.16.99.0/24    HQ Management
172.17.5.0/24     Branch Infrastructure
172.17.10.0/24    Branch Clients
172.17.20.0/24    Branch Servers
172.17.99.0/24    Branch Management
10.200.0.0/24     WireGuard Tunnel
```

4. Click **Save** and **Apply Changes**

### D. Configure Firewall Rules

Add permissive rules to each new VLAN interface allowing traffic between trusted networks.

**On both OPNsense firewalls, for each new interface (INFRA, CLIENTS, SERVERS, MGMT):**

1. Navigate to **Firewall > Rules > [Interface Name]**
2. Click **Add** to create a new rule:

**Rule 1 - Allow Trusted Traffic:**

| Setting | Value |
|:--------|:------|
| Action | Pass |
| Interface | [Current VLAN interface] |
| Direction | in |
| Protocol | any |
| Source | Trusted_Lab_Networks |
| Destination | Trusted_Lab_Networks |
| Description | Allow all trusted inter-VLAN traffic |

**Rule 2 - Allow Internet:**

| Setting | Value |
|:--------|:------|
| Action | Pass |
| Interface | [Current VLAN interface] |
| Direction | in |
| Protocol | any |
| Source | [Interface] net |
| Destination | any |
| Description | Allow internet access |

3. Click **Save** and **Apply Changes**

> [!TIP]
> The permissive rules mirror current flat network behavior. After validating connectivity, you can tighten rules to allow only specific ports between VLANs.

### E. Verify Outbound NAT

OPNsense in Hybrid Outbound NAT mode should automatically create NAT rules for new interfaces.

1. Navigate to **Firewall > NAT > Outbound**
2. Verify rules exist for each new VLAN subnet
3. If missing, add manual rules:

| Interface | Source | Translation |
|:----------|:-------|:------------|
| WAN | 172.16.10.0/24 | Interface address |
| WAN | 172.16.20.0/24 | Interface address |
| WAN | 172.16.99.0/24 | Interface address |

---

## 2. Proxmox Configuration

Enable VLAN tagging on the internal bridge so VMs can be assigned to specific VLANs.

### A. Enable VLAN-Aware Bridge

1. Open Proxmox web interface
2. Navigate to **Node > Network**
3. Select `vmbr1` (the internal LAN bridge)
4. Click **Edit**
5. Check **VLAN aware**
6. Click **OK**
7. Click **Apply Configuration**

> [!IMPORTANT]
> P-WIN-DC1 should be tagged with VLAN 5 (Infrastructure). OPNsenseHQ's LAN interface (vtnet1) should remain untagged to serve as the router-on-a-stick for all VLANs. P-WIN-SRV1 will be migrated to VLAN 20.

### B. Migrate P-WIN-DC1 to VLAN 5

P-WIN-DC1 (Domain Controller) moves from the native VLAN to the Infrastructure VLAN:

1. **Update VM Network Settings:**
   - Select P-WIN-DC1 > **Hardware**
   - Double-click **Network Device**
   - Set **VLAN Tag** to `5`
   - Click **OK**

2. **Update IP Address (inside VM):**

```powershell
# [P-WIN-DC1]
# Change IP from 172.16.0.10 to 172.16.5.10
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.5.10 -PrefixLength 24 -DefaultGateway 172.16.5.1
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.0.10 -Confirm:$false

# Update DNS to point to itself and H-WIN-DC2
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 172.16.5.10,172.17.5.10
```

3. **Update DNS Records:**

```powershell
# [P-WIN-DC1]
# Update A record for P-WIN-DC1
Remove-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "P-WIN-DC1" -RRType A -Force
Add-DnsServerResourceRecordA -ZoneName "reginleif.io" -Name "P-WIN-DC1" -IPv4Address 172.16.5.10

# Update reverse zone (PTR record)
Add-DnsServerPrimaryZone -NetworkID "172.16.5.0/24" -ReplicationScope "Forest"
```

### C. Migrate P-WIN-SRV1 to VLAN 20

P-WIN-SRV1 (Royal Server) moves from Infrastructure to the Servers VLAN:

1. **Update VM Network Settings:**
   - Select P-WIN-SRV1 > **Hardware**
   - Double-click **Network Device**
   - Set **VLAN Tag** to `20`
   - Click **OK**

2. **Update IP Address (inside VM):**

```powershell
# [P-WIN-SRV1]
# Change IP from 172.16.5.11 to 172.16.20.11
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.20.11 -PrefixLength 24 -DefaultGateway 172.16.20.1
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.5.11 -Confirm:$false

# Update DNS to point to DCs (new VLAN 5 IPs)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 172.16.5.10,172.17.5.10
```

3. **Update DNS Record:**

```powershell
# [P-WIN-DC1]
# Update A record for SRV1
Remove-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "P-WIN-SRV1" -RRType A -Force
Add-DnsServerResourceRecordA -ZoneName "reginleif.io" -Name "P-WIN-SRV1" -IPv4Address 172.16.20.11
```

4. **Update Royal Server connections** (if any saved connections reference the old IP)

### D. Assigning VMs to VLANs

For future VMs, set the VLAN tag in the network device configuration:

1. Select the VM > **Hardware**
2. Double-click the **Network Device**
3. Set **VLAN Tag** to the desired VLAN ID:

| VM Purpose | Bridge | VLAN Tag |
|:-----------|:-------|:---------|
| Domain Controllers | vmbr1 | 5 |
| Windows 10/11 Clients | vmbr1 | 10 |
| Member Servers | vmbr1 | 20 |
| Management Appliances | vmbr1 | 99 |

4. Click **OK**

---

## 3. Hyper-V Configuration

Hyper-V handles VLANs differently than Proxmox. The OPNsense VM processes VLAN tags internally.

### A. Current Configuration

OPNsenseBranch is connected to the Private vSwitch (Branch-LAN) on interface `hn1`. The VLAN interfaces created within OPNsense (in Section 1) handle all VLAN tagging.

No changes are needed to the existing virtual switch configuration.

### B. Migrate H-WIN-DC2 to VLAN 5

H-WIN-DC2 (Domain Controller) moves from the native VLAN to the Infrastructure VLAN:

1. **Update VM Network Settings:**

```powershell
# Set VLAN 5 for H-WIN-DC2's network adapter
Set-VMNetworkAdapterVlan -VMName "H-WIN-DC2" -Access -VlanId 5

# Verify VLAN assignment
Get-VMNetworkAdapterVlan -VMName "H-WIN-DC2"
```

2. **Update IP Address (inside H-WIN-DC2 VM):**

```powershell
# [H-WIN-DC2]
# Change IP from 172.17.0.10 to 172.17.5.10
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.17.5.10 -PrefixLength 24 -DefaultGateway 172.17.5.1
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.17.0.10 -Confirm:$false

# Update DNS to point to itself and P-WIN-DC1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 172.17.5.10,172.16.5.10
```

3. **Update DNS Records:**

```powershell
# [H-WIN-DC2]
# Update A record for H-WIN-DC2
Remove-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "H-WIN-DC2" -RRType A -Force
Add-DnsServerResourceRecordA -ZoneName "reginleif.io" -Name "H-WIN-DC2" -IPv4Address 172.17.5.10

# Update reverse zone (PTR record)
Add-DnsServerPrimaryZone -NetworkID "172.17.5.0/24" -ReplicationScope "Forest"
```

### C. Assigning VMs to VLANs

For future VMs at the Branch site, assign VLANs using PowerShell:

```powershell
# Set VLAN for a VM's network adapter
Set-VMNetworkAdapterVlan -VMName "ClientVM" -Access -VlanId 10

# Verify VLAN assignment
Get-VMNetworkAdapterVlan -VMName "ClientVM"
```

Or via GUI:

1. Open **Hyper-V Manager**
2. Right-click VM > **Settings**
3. Select **Network Adapter > Advanced Features**
4. Check **Enable virtual LAN identification**
5. Enter the VLAN ID

---

## 4. DHCP Configuration

Create DHCP scopes for the Clients VLAN at each site. Update existing Infrastructure VLAN scopes to use the new VLAN 5 subnet.

### A. Update Infrastructure VLAN Scope (P-WIN-DC1)

```powershell
# [P-WIN-DC1]
# Remove old Infrastructure scope (172.16.0.0/24)
Remove-DhcpServerv4Scope -ScopeId 172.16.0.0 -Force

# Create new Infrastructure scope (172.16.5.0/24)
Add-DhcpServerv4Scope -Name "HQ-Infrastructure-VLAN5" `
    -StartRange 172.16.5.30 `
    -EndRange 172.16.5.254 `
    -SubnetMask 255.255.255.0 `
    -LeaseDuration 0.08:00:00 `
    -State Active

# Set scope options
Set-DhcpServerv4OptionValue -ScopeId 172.16.5.0 `
    -Router 172.16.5.1 `
    -DnsServer 172.16.5.10,172.17.5.10 `
    -DnsDomain "reginleif.io"
```

### B. HQ Client VLAN Scope (P-WIN-DC1)

```powershell
# [P-WIN-DC1]
# Create VLAN 10 (Clients) scope
Add-DhcpServerv4Scope -Name "HQ-Clients-VLAN10" `
    -StartRange 172.16.10.30 `
    -EndRange 172.16.10.254 `
    -SubnetMask 255.255.255.0 `
    -LeaseDuration 0.08:00:00 `
    -State Active

# Set scope options
Set-DhcpServerv4OptionValue -ScopeId 172.16.10.0 `
    -Router 172.16.10.1 `
    -DnsServer 172.16.5.10,172.17.5.10 `
    -DnsDomain "reginleif.io"
```

### C. Update Infrastructure VLAN Scope (H-WIN-DC2)

```powershell
# [H-WIN-DC2]
# Remove old Infrastructure scope (172.17.0.0/24)
Remove-DhcpServerv4Scope -ScopeId 172.17.0.0 -Force

# Create new Infrastructure scope (172.17.5.0/24)
Add-DhcpServerv4Scope -Name "Branch-Infrastructure-VLAN5" `
    -StartRange 172.17.5.30 `
    -EndRange 172.17.5.254 `
    -SubnetMask 255.255.255.0 `
    -LeaseDuration 0.08:00:00 `
    -State Active

# Set scope options
Set-DhcpServerv4OptionValue -ScopeId 172.17.5.0 `
    -Router 172.17.5.1 `
    -DnsServer 172.17.5.10,172.16.5.10 `
    -DnsDomain "reginleif.io"
```

### D. Branch Client VLAN Scope (H-WIN-DC2)

```powershell
# [H-WIN-DC2]
# Create VLAN 10 (Clients) scope
Add-DhcpServerv4Scope -Name "Branch-Clients-VLAN10" `
    -StartRange 172.17.10.30 `
    -EndRange 172.17.10.254 `
    -SubnetMask 255.255.255.0 `
    -LeaseDuration 0.08:00:00 `
    -State Active

# Set scope options
Set-DhcpServerv4OptionValue -ScopeId 172.17.10.0 `
    -Router 172.17.10.1 `
    -DnsServer 172.17.5.10,172.16.5.10 `
    -DnsDomain "reginleif.io"
```

> [!NOTE]
> Server and Management VLANs use static IP assignment, so no DHCP scopes are needed for VLAN 20 and 99.

---

## 5. DNS Reverse Zones

Create reverse lookup zones for all new VLAN subnets to enable PTR record registration. Remove old Infrastructure zones.

```powershell
# [P-WIN-DC1]
# Remove old Infrastructure reverse zone (if it exists)
Remove-DnsServerZone -Name "0.16.172.in-addr.arpa" -Force -ErrorAction SilentlyContinue

# Create reverse zones with Forest-wide replication
Add-DnsServerPrimaryZone -NetworkID "172.16.5.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.16.10.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.16.20.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.16.99.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.17.5.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.17.10.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.17.20.0/24" -ReplicationScope "Forest"
Add-DnsServerPrimaryZone -NetworkID "172.17.99.0/24" -ReplicationScope "Forest"

# Verify zones were created
Get-DnsServerZone | Where-Object { $_.ZoneName -like "*.in-addr.arpa" }
```

---

## 6. WireGuard VPN Updates

Update the site-to-site VPN to route traffic for the new VLAN subnets.

### A. OPNsenseHQ - Update Branch Peer

1. Navigate to **VPN > WireGuard > Peers**
2. Edit the Branch peer
3. Update **Allowed IPs**:

```text
172.17.5.0/24, 172.17.10.0/24, 172.17.20.0/24, 172.17.99.0/24, 10.200.0.2/32
```

4. Click **Save** and **Apply**

### B. OPNsenseBranch - Update HQ Peer

1. Navigate to **VPN > WireGuard > Peers**
2. Edit the HQ peer
3. Update **Allowed IPs**:

```text
172.16.5.0/24, 172.16.10.0/24, 172.16.20.0/24, 172.16.99.0/24, 10.200.0.0/24
```

4. Click **Save** and **Apply**

### C. Road Warrior Configuration

Update the WireGuard client configuration on the Admin PC:

```ini
[Peer]
PublicKey = <HQ-public-key>
AllowedIPs = 172.16.0.0/16, 172.17.0.0/16, 10.200.0.0/24
Endpoint = 192.168.1.240:51820
```

> [!TIP]
> Using /16 subnets for AllowedIPs is simpler and covers all current and future VLANs in the 172.16.x.x and 172.17.x.x ranges.

---

## 7. AD Sites and Subnets

Register the new VLAN subnets in Active Directory Sites and Services so clients authenticate against the correct DC. Update the old Infrastructure subnet to the new VLAN 5 subnet.

```powershell
# [P-WIN-DC1]
# Remove old Infrastructure subnets (if they exist)
Remove-ADReplicationSubnet -Identity "172.16.0.0/24" -Confirm:$false -ErrorAction SilentlyContinue
Remove-ADReplicationSubnet -Identity "172.17.0.0/24" -Confirm:$false -ErrorAction SilentlyContinue

# Register HQ VLAN subnets
New-ADReplicationSubnet -Name "172.16.5.0/24" -Site "HQ-Proxmox"
New-ADReplicationSubnet -Name "172.16.10.0/24" -Site "HQ-Proxmox"
New-ADReplicationSubnet -Name "172.16.20.0/24" -Site "HQ-Proxmox"
New-ADReplicationSubnet -Name "172.16.99.0/24" -Site "HQ-Proxmox"

# Register Branch VLAN subnets
New-ADReplicationSubnet -Name "172.17.5.0/24" -Site "Branch-HyperV"
New-ADReplicationSubnet -Name "172.17.10.0/24" -Site "Branch-HyperV"
New-ADReplicationSubnet -Name "172.17.20.0/24" -Site "Branch-HyperV"
New-ADReplicationSubnet -Name "172.17.99.0/24" -Site "Branch-HyperV"

# Verify subnets
Get-ADReplicationSubnet -Filter * | Format-Table Name, Site
```

---

## 8. Windows Firewall Updates

Update Windows Firewall rules on all servers to allow traffic from the new VLAN subnets.

```powershell
# [Both DCs: P-WIN-DC1 and H-WIN-DC2]
# Define all trusted subnets
$AllSubnets = @(
    "172.16.5.0/24",
    "172.16.10.0/24",
    "172.16.20.0/24",
    "172.16.99.0/24",
    "172.17.5.0/24",
    "172.17.10.0/24",
    "172.17.20.0/24",
    "172.17.99.0/24",
    "10.200.0.0/24"
)

# Remove old lab rules (if they exist)
Get-NetFirewallRule -DisplayName "Allow Lab*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# Create comprehensive rule for all lab traffic
New-NetFirewallRule -DisplayName "Allow Lab Subnets - All" `
    -Direction Inbound `
    -Protocol Any `
    -Action Allow `
    -RemoteAddress $AllSubnets `
    -Profile Domain,Private

# Verify rule
Get-NetFirewallRule -DisplayName "Allow Lab Subnets - All" |
    Get-NetFirewallAddressFilter
```

> [!NOTE]
> Run this on P-WIN-SRV1 as well if Royal Server needs to accept connections from the new VLANs.

> [!TIP]
> **Production Consideration:** The `Allow Lab Subnets - All` rule is extremely permissive, allowing all protocols from trusted subnets. While acceptable for a lab environment, a production deployment should implement granular rules based on the principle of least privilege. For example:
> - Domain Controllers: Allow only AD-specific ports (TCP/UDP 53 for DNS, TCP/UDP 88 for Kerberos, TCP 135/389/636/3268/3269 for LDAP, TCP 445 for SMB, etc.)
> - Member Servers: Restrict to only required service ports (e.g., TCP 443 for Royal Server HTTPS)
> - Management interfaces: Limit to administrative protocols (RDP, WinRM, etc.) from specific management subnets only

---

## 9. Validation

### A. OPNsense Verification

1. **Check VLAN interfaces exist:**
   - Navigate to **Interfaces > Overview**
   - Verify CLIENTS, SERVERS, and MGMT interfaces show UP status

2. **Check routing table:**
   - Navigate to **System > Routes > Status**
   - Verify routes exist for all VLAN subnets

### B. Connectivity Tests

Create a temporary test VM on VLAN 10 to validate the configuration:

**On Proxmox (HQ):**

1. Create a small Linux VM (Alpine or similar)
2. Set Network Device VLAN Tag to `10`
3. Boot and verify:

```bash
# Check DHCP assignment
ip addr show

# Should show 172.16.10.x address

# Test gateway
ping 172.16.10.1

# Test DC (cross-VLAN)
ping 172.16.5.10

# Test DNS
nslookup reginleif.io 172.16.5.10

# Test cross-site (via VPN)
ping 172.17.5.10
```

### C. Validation Checklist

- [ ] VLAN interfaces visible in OPNsense at both sites (INFRA, CLIENTS, SERVERS, MGMT)
- [ ] Proxmox vmbr1 shows VLAN-aware enabled
- [ ] P-WIN-DC1 on VLAN 5 with IP 172.16.5.10
- [ ] H-WIN-DC2 on VLAN 5 with IP 172.17.5.10
- [ ] Test VM on VLAN 10 gets DHCP address (172.16.10.x)
- [ ] Test VM can ping gateway (172.16.10.1)
- [ ] Test VM can ping DC (172.16.5.10)
- [ ] Test VM can resolve DNS (nslookup reginleif.io)
- [ ] Cross-site: HQ VLAN 10 can ping Branch DC (172.17.5.10)
- [ ] Road Warrior can reach new VLANs
- [ ] AD subnets registered in Sites and Services

---

## Network Diagram

```text
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
│   └─ .11 P-WIN-SRV1           │         │                               │
│                               │         │                               │
│ VLAN 99 - Management          │         │ VLAN 99 - Management          │
│   172.16.99.0/24              │         │   172.17.99.0/24              │
│   └─ .1  Gateway              │         │   └─ .1  Gateway              │
│                               │         │                               │
└───────────────────────────────┘         └───────────────────────────────┘
```
