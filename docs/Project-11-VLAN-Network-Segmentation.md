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
| 99 | Management | 172.16.99.0/24 | 172.17.99.0/24 | Admin access, out-of-band management |

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
| DHCP | Clients VLAN only | Infrastructure, Servers, and Management use static IPs |

---

## 1. OPNsense VLAN Configuration

Configure VLAN interfaces on both OPNsense firewalls. The process is identical at both sites, with different IP addresses.

### A. Create VLAN Interfaces

**On OPNsenseHQ:**

1. Navigate to **Interfaces > Devices > VLANs**

2. Click **Add** for each VLAN:

| Device | Parent Interface | VLAN Tag | Description |
|:-------|:-----------------|:---------|:------------|
| vlan0.5 | vtnet1 (LAN) | 5 | Infrastructure |
| vlan0.10 | vtnet1 (LAN) | 10 | Clients |
| vlan0.20 | vtnet1 (LAN) | 20 | Servers |
| vlan0.99 | vtnet1 (LAN) | 99 | Management |

**On OPNsenseBranch:**

Repeat using `hn1` as the parent interface:

| Device | Parent Interface | VLAN Tag | Description |
|:-------|:-----------------|:---------|:------------|
| vlan0.5 | hn1 (LAN) | 5 | Infrastructure |
| vlan0.10 | hn1 (LAN) | 10 | Clients |
| vlan0.20 | hn1 (LAN) | 20 | Servers |
| vlan0.99 | hn1 (LAN) | 99 | Management |

### B. Assign and Configure Interfaces

**On OPNsenseHQ:**

1. Navigate to **Interfaces > Assignments**
2. For each new VLAN, select from the dropdown and click **Add**
3. Click the new interface name (e.g., OPT2, etc.) to configure:

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

### C. Remove Old LAN Interface IP

> [!WARNING]
> **Before removing the LAN IP**, ensure WireGuard VPN is updated (Section 2) so you maintain remote access to OPNsense via the Road Warrior VPN.

The original LAN interface (vtnet1 on HQ, hn1 on Branch) now serves as a trunk port for all VLAN traffic and no longer needs an IP address. Remove the old flat network IP to avoid confusion.

**On both OPNsense firewalls:**

1. Navigate to **Interfaces > LAN**
2. Change **IPv4 Configuration Type** to **None**
3. Click **Save** and **Apply Changes**

> [!NOTE]
> The physical LAN interface will remain UP and active as a trunk port carrying all VLAN traffic. Removing the IP address (previously 172.16.0.1 at HQ, 172.17.0.1 at Branch) only removes the old flat network gateway that is no longer used.

### D. Update Firewall Alias

The `Trusted_Lab_Networks` alias must include all new VLAN subnets.

**On both OPNsense firewalls:**

1. Navigate to **Firewall > Aliases**
2. Edit `Trusted_Lab_Networks`
3. Replace the existing entries with the following:

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

### E. Configure Firewall Rules

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

### F. Verify Outbound NAT

OPNsense in Hybrid Outbound NAT mode should automatically create NAT rules for new interfaces.

**On both OPNsense firewalls:**

1. Navigate to **Firewall > NAT > Outbound**
2. Verify rules exist for each new VLAN subnet
3. If missing, add manual rules:

**OPNsenseHQ:**

| Interface | Source | Translation |
|:----------|:-------|:------------|
| WAN | 172.16.5.0/24 | Interface address |
| WAN | 172.16.10.0/24 | Interface address |
| WAN | 172.16.20.0/24 | Interface address |
| WAN | 172.16.99.0/24 | Interface address |

**OPNsenseBranch:**

| Interface | Source | Translation |
|:----------|:-------|:------------|
| WAN | 172.17.5.0/24 | Interface address |
| WAN | 172.17.10.0/24 | Interface address |
| WAN | 172.17.20.0/24 | Interface address |
| WAN | 172.17.99.0/24 | Interface address |

---

## 2. WireGuard VPN Updates

Update the site-to-site VPN and road warrior configuration to route traffic for the new VLAN subnets. This must be done early to ensure VPN access remains available after removing the old LAN interface IP.

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

> [!NOTE]
> **Hub-and-Spoke Design:** The tunnel AllowedIPs differ between sites because OPNsenseHQ acts as the hub. On HQ, each peer (Branch, Admin-PC) gets only its specific `/32` tunnel IP (e.g., `10.200.0.2/32`). On Branch, the entire tunnel subnet (`10.200.0.0/24`) routes to HQ, allowing Branch to reach road warriors via the hub.

### C. Road Warrior Configuration

Update the WireGuard client configuration on the Admin PC to use the new DNS servers and VLAN subnets:

```ini
[Interface]
PrivateKey = <Auto-Generated-Private-Key>
Address = 10.200.0.10/32
DNS = 172.16.5.10, 172.17.5.10

[Peer]
PublicKey = <HQ-public-key>
AllowedIPs = 172.16.0.0/16, 172.17.0.0/16, 10.200.0.0/24
Endpoint = 192.168.1.240:51820
PersistentKeepalive = 25
```

**Key changes:**
- **DNS servers** updated from `172.16.0.10, 172.17.0.10` to `172.16.5.10, 172.17.5.10` (DCs now on VLAN 5)
- **AllowedIPs** changed from `/24` to `/16` subnets to cover all current and future VLANs

> [!TIP]
> Using /16 subnets for AllowedIPs is simpler and covers all current and future VLANs in the 172.16.x.x and 172.17.x.x ranges.

---

## 3. Proxmox Configuration

Enable VLAN tagging on the internal bridge so VMs can be assigned to specific VLANs.

### A. Enable VLAN-Aware Bridge

1. Open Proxmox web interface
2. Navigate to **Node > Network**
3. Select `vmbr1` (the internal LAN bridge)
4. Click **Edit**
5. Check **VLAN aware**
6. Click **OK**
7. Click **Apply Configuration**

> [!WARNING]
> After enabling VLAN-aware and setting VLAN tags on VMs, you must **reboot the affected VMs** for changes to take full effect. VLAN tagging changes are applied to the virtual NIC configuration, but running VMs may retain the old NIC state in memory until restarted.

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

# Remove old default gateway route (prevents duplicate gateways)
Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop 172.16.0.1 -Confirm:$false

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

> [!NOTE]
> DNS replication between DCs won't work until the WireGuard VPN routes the new VLAN subnets (Section 2). You may need to **manually update P-WIN-DC1's A record on H-WIN-DC2** as well:
>
> ```powershell
> # [H-WIN-DC2]
> Remove-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "P-WIN-DC1" -RRType A -Force
> Add-DnsServerResourceRecordA -ZoneName "reginleif.io" -Name "P-WIN-DC1" -IPv4Address 172.16.5.10
> Clear-DnsClientCache
> ```

4. **Update Windows Firewall:**

> [!IMPORTANT]
> Windows Firewall must be updated to allow traffic from the new VLAN subnets **before AD replication can work**.

```powershell
# [P-WIN-DC1]
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

# Remove old lab rules
Get-NetFirewallRule -DisplayName "Allow Lab*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# Create rule for all VLAN subnets
New-NetFirewallRule -DisplayName "Allow Lab Subnets - All" `
    -Direction Inbound -Protocol Any -Action Allow `
    -RemoteAddress $AllSubnets -Profile Domain,Private

# Verify only new rule exists (should show only "Allow Lab Subnets - All")
Get-NetFirewallRule -DisplayName "Allow Lab*" | Select-Object DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow Lab Subnets - All" | Get-NetFirewallAddressFilter
```

5. **Fix Network Profile:**

> [!NOTE]
> **Why does this happen?** When DCs reboot with new IPs, the Network Location Awareness (NLA) service tries to contact a domain controller to verify domain membership. Since both DCs are migrating simultaneously and firewalls initially block traffic (Public profile), neither can reach the other - creating a chicken-and-egg problem where the network stays "Unidentified" / Public.

> [!WARNING]
> After VLAN migration, Windows may identify the network as "Unidentified network" with **Public** profile. Since firewall rules apply only to Domain/Private profiles, the rules won't work until this is fixed.

```powershell
# [P-WIN-DC1]
# Check current profile
Get-NetConnectionProfile

# If it shows "Public", set to Private
Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private

# Reboot to allow NLA to re-detect domain
Restart-Computer -Force
```

After reboot, verify the network is recognized as domain:

```powershell
# [P-WIN-DC1]
Get-NetConnectionProfile
# Should show: Name = reginleif.io, NetworkCategory = DomainAuthenticated
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
# Change IP from 172.16.0.11 to 172.16.20.11
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.20.11 -PrefixLength 24 -DefaultGateway 172.16.20.1
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.0.11 -Confirm:$false

# Remove old default gateway route (prevents duplicate gateways)
Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop 172.16.0.1 -Confirm:$false

# Update DNS to point to DCs (new VLAN 5 IPs)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 172.16.5.10,172.17.5.10
```

3. **Update DNS Record:**

```powershell
# [P-WIN-DC1]
# Update A record for SRV1
Remove-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "P-WIN-SRV1" -RRType A -Force
Add-DnsServerResourceRecordA -ZoneName "reginleif.io" -Name "P-WIN-SRV1" -IPv4Address 172.16.20.11

# The new PTR record will be created in the reverse lookup zone defined in Section 6.
# You may need to manually remove the old PTR record from the old "0.16.172.in-addr.arpa" zone.
```

4. **Update Windows Firewall:**

```powershell
# [P-WIN-SRV1]
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

# Remove old lab rules
Get-NetFirewallRule -DisplayName "Allow Lab*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# Create rule for all VLAN subnets
New-NetFirewallRule -DisplayName "Allow Lab Subnets - All" `
    -Direction Inbound -Protocol Any -Action Allow `
    -RemoteAddress $AllSubnets -Profile Domain,Private

# Verify only new rule exists
Get-NetFirewallRule -DisplayName "Allow Lab*" | Select-Object DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow Lab Subnets - All" | Get-NetFirewallAddressFilter
```

5. **Fix Network Profile:**

> [!WARNING]
> After VLAN migration, Windows may identify the network as "Unidentified network" with **Public** profile. Since firewall rules apply only to Domain/Private profiles, the rules won't work until this is fixed.

```powershell
# [P-WIN-SRV1]
# Check current profile
Get-NetConnectionProfile

# If it shows "Public", set to Private
Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private

# Reboot to allow NLA to re-detect domain
Restart-Computer -Force
```

After reboot, verify the network is recognized as domain:

```powershell
# [P-WIN-SRV1]
Get-NetConnectionProfile
# Should show: Name = reginleif.io, NetworkCategory = DomainAuthenticated
```

6. **Update Royal Server connections** (if any saved connections reference the old IP)

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

## 4. Hyper-V Configuration

Hyper-V handles VLANs differently than Proxmox:

| Hypervisor | Bridge/Switch | Router VM | VMs |
|------------|---------------|-----------|-----|
| **Proxmox** | vmbr1 set to VLAN-aware | OPNsenseHQ: Untagged | Tag set per VM |
| **Hyper-V** | Private vSwitch | OPNsenseBranch: **Trunk mode** | Access mode per VM |

In Proxmox, the VLAN-aware bridge handles tagging so OPNsenseHQ stays untagged. In Hyper-V, the private switch doesn't have this mode, so OPNsenseBranch itself must be in Trunk mode to receive VLAN-tagged frames from other VMs.

### A. Configure OPNsenseBranch for VLAN Trunking

> [!IMPORTANT]
> OPNsenseBranch's LAN adapter must be set to **Trunk mode** to receive VLAN-tagged traffic from other VMs. Without this, VMs on VLANs (like H-WIN-DC2 on VLAN 5) cannot reach OPNsenseBranch.

**On the Hyper-V host:**

1. **Set the LAN adapter (Branch-LAN) to Trunk mode:**

```powershell
# [Hyper-V Host]
# Set Trunk mode on the LAN adapter connected to Branch-LAN
Get-VMNetworkAdapter -VMName "OPNsenseBranch" |
    Where-Object { $_.SwitchName -eq "Branch-LAN" } |
    Set-VMNetworkAdapterVlan -Trunk -AllowedVlanIdList "1-100" -NativeVlanId 1
```

2. **Ensure the WAN adapter remains Untagged:**

```powershell
# [Hyper-V Host]
# WAN adapter should be Untagged (replace "Bridge" with your WAN switch name)
Get-VMNetworkAdapter -VMName "OPNsenseBranch" |
    Where-Object { $_.SwitchName -eq "Bridge" } |
    Set-VMNetworkAdapterVlan -Untagged
```

3. **Verify the configuration:**

```powershell
# [Hyper-V Host]
Get-VMNetworkAdapter -VMName "OPNsenseBranch" |
    Select-Object Name, SwitchName, @{N='VlanMode';E={$_.VlanSetting.OperationMode}}
```

**Expected output:**
```
Name            SwitchName  VlanMode
----            ----------  --------
Network Adapter Bridge      Untagged
Network Adapter Branch-LAN  Trunk
```

### B. Migrate H-WIN-DC2 to VLAN 5

H-WIN-DC2 (Domain Controller) moves from the native VLAN to the Infrastructure VLAN:

1. **Update VM Network Settings (on Hyper-V host):**

```powershell
# [Hyper-V Host]
# Set VLAN 5 for H-WIN-DC2's network adapter
Set-VMNetworkAdapterVlan -VMName "H-WIN-DC2" -Access -VlanId 5

# Verify VLAN assignment
Get-VMNetworkAdapterVlan -VMName "H-WIN-DC2"
```

> [!TIP]
> While Hyper-V VLAN changes usually take effect immediately, **reboot H-WIN-DC2** if you experience connectivity issues after applying the VLAN tag and IP changes.

2. **Update IP Address (inside H-WIN-DC2 VM):**

```powershell
# [H-WIN-DC2]
# Change IP from 172.17.0.10 to 172.17.5.10
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.17.5.10 -PrefixLength 24 -DefaultGateway 172.17.5.1
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.17.0.10 -Confirm:$false

# Remove old default gateway route (prevents duplicate gateways)
Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop 172.17.0.1 -Confirm:$false

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

4. **Update Windows Firewall:**

```powershell
# [H-WIN-DC2]
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

# Remove old lab rules
Get-NetFirewallRule -DisplayName "Allow Lab*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# Create rule for all VLAN subnets
New-NetFirewallRule -DisplayName "Allow Lab Subnets - All" `
    -Direction Inbound -Protocol Any -Action Allow `
    -RemoteAddress $AllSubnets -Profile Domain,Private

# Verify only new rule exists (should show only "Allow Lab Subnets - All")
Get-NetFirewallRule -DisplayName "Allow Lab*" | Select-Object DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow Lab Subnets - All" | Get-NetFirewallAddressFilter
```

5. **Fix Network Profile:**

> [!WARNING]
> After VLAN migration, Windows may identify the network as "Unidentified network" with **Public** profile. Since firewall rules apply only to Domain/Private profiles, the rules won't work until this is fixed.

```powershell
# [H-WIN-DC2]
# Check current profile
Get-NetConnectionProfile

# If it shows "Public", set to Private
Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private

# Reboot to allow NLA to re-detect domain
Restart-Computer -Force
```

After reboot, verify the network is recognized as domain:

```powershell
# [H-WIN-DC2]
Get-NetConnectionProfile
# Should show: Name = reginleif.io, NetworkCategory = DomainAuthenticated
```

6. **Verify AD Replication:**

```powershell
# [Either DC]
# Force replication between sites
repadmin /syncall /AdeP

# Check replication summary (should show 0 failures)
repadmin /replsummary
```

### C. Assigning VMs to VLANs

For future VMs at the Branch site, assign VLANs using PowerShell on the Hyper-V host:

```powershell
# [Hyper-V Host]
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

## 5. DHCP Configuration

Create DHCP scopes for the Clients VLAN at each site. Infrastructure, Server, and Management VLANs use static IP assignment only.

> [!NOTE]
> DHCP scopes are server-specific and not replicated between domain controllers. Each DC manages its own scopes - P-WIN-DC1's scopes must be verified on P-WIN-DC1, and H-WIN-DC2's scopes must be verified on H-WIN-DC2.

### A. HQ Client VLAN Scope (P-WIN-DC1)

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

# Verify scope configuration
Get-DhcpServerv4Scope -ScopeId 172.16.10.0
Get-DhcpServerv4OptionValue -ScopeId 172.16.10.0
```

### B. Branch Client VLAN Scope (H-WIN-DC2)

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

# Verify scope configuration
Get-DhcpServerv4Scope -ScopeId 172.17.10.0
Get-DhcpServerv4OptionValue -ScopeId 172.17.10.0
```

### C. Verify All DHCP Scopes

After configuring all scopes, verify the complete DHCP configuration on each server:

```powershell
# [P-WIN-DC1]
# List all scopes
Get-DhcpServerv4Scope | Format-Table ScopeId, Name, State, StartRange, EndRange

# Expected output:
# ScopeId       Name              State  StartRange     EndRange
# -------       ----              -----  ----------     --------
# 172.16.10.0   HQ-Clients-VLAN10 Active 172.16.10.30   172.16.10.254
```

```powershell
# [H-WIN-DC2]
# List all scopes
Get-DhcpServerv4Scope | Format-Table ScopeId, Name, State, StartRange, EndRange

# Expected output:
# ScopeId       Name                  State  StartRange     EndRange
# -------       ----                  -----  ----------     --------
# 172.17.10.0   Branch-Clients-VLAN10 Active 172.17.10.30   172.17.10.254
```

> [!NOTE]
> Infrastructure, Server, and Management VLANs use static IP assignment only. No DHCP scopes are needed for VLAN 5, 20, and 99.

---

## 6. DNS Reverse Zones

Create reverse lookup zones for all new VLAN subnets to enable PTR record registration. Remove old Infrastructure zones.

```powershell
# [P-WIN-DC1]
# Remove old Infrastructure reverse zone (if it exists)
Remove-DnsServerZone -Name "0.16.172.in-addr.arpa" -Force -ErrorAction SilentlyContinue
Remove-DnsServerZone -Name "0.17.172.in-addr.arpa" -Force -ErrorAction SilentlyContinue

# Create reverse zones with Forest-wide replication
# Note: 172.16.5.0/24 and 172.17.5.0/24 may already exist from DC migration steps
Add-DnsServerPrimaryZone -NetworkID "172.16.5.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.16.10.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.16.20.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.16.99.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.17.5.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.17.10.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.17.20.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue
Add-DnsServerPrimaryZone -NetworkID "172.17.99.0/24" -ReplicationScope "Forest" -ErrorAction SilentlyContinue

# Verify zones were created
Get-DnsServerZone | Where-Object { $_.ZoneName -like "*.in-addr.arpa" }
```

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

## 8. Windows Firewall Notes

> [!NOTE]
> Windows Firewall updates are performed inline during each VM migration to ensure connectivity before AD replication:
> - **P-WIN-DC1:** Section 3.B Step 4
> - **P-WIN-SRV1:** Section 3.C Step 4
> - **H-WIN-DC2:** Section 4.B Step 4

> [!TIP]
> **Production Consideration:** The `Allow Lab Subnets - All` rule is extremely permissive, allowing all protocols from trusted subnets. While acceptable for a lab environment, a production deployment should implement granular rules based on the principle of least privilege. For example:
>
> - Domain Controllers: Allow only AD-specific ports (TCP/UDP 53 for DNS, TCP/UDP 88 for Kerberos, TCP 135/389/636/3268/3269 for LDAP, TCP 445 for SMB, etc.)
> - Member Servers: Restrict to only required service ports (e.g., TCP 443 for Royal Server HTTPS)
> - Management interfaces: Limit to administrative protocols (RDP, WinRM, etc.) from specific management subnets only

---

## 9. Validation

### A. OPNsense Verification

1. **Check VLAN interfaces exist:**
   - Navigate to **Interfaces > Overview**
   - Verify INFRA, CLIENTS, SERVERS, and MGMT interfaces show UP status

2. **Check routing table:**
   - Navigate to **System > Routes > Status**
   - Verify routes exist for all VLAN subnets

### B. Validation Checklist

- [ ] VLAN interfaces visible in OPNsense at both sites (INFRA, CLIENTS, SERVERS, MGMT)
- [ ] Proxmox vmbr1 shows VLAN-aware enabled
- [ ] P-WIN-DC1 on VLAN 5 with IP 172.16.5.10
- [ ] H-WIN-DC2 on VLAN 5 with IP 172.17.5.10
- [ ] P-WIN-SRV1 on VLAN 20 with IP 172.16.20.11
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
