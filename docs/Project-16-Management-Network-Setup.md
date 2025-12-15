---
title: "Project 16: Management Network Setup"
tags: [vpn, management, bastion, monitoring]
sites: [hq]
status: planned
---

## Goal

Establish the Management VLAN (99) as the dedicated network for administrative access by:

1. Moving Royal Server to Management VLAN 99 (bastion host model)
2. Restricting Road Warrior VPN to Management VLANs only (least privilege)
3. Documenting the foundation for future monitoring infrastructure

---

## Background & Concepts

**[View Background & Concepts](/concepts/project-16-concepts)**

For educational context about bastion host architecture, Zero Trust networking principles, management VLAN design, and why restricting VPN access improves security posture, see the dedicated concepts guide.

---

## Architecture Changes

### Before

```
┌─────────────────┐     ┌──────────────────────────────────┐
│ Admin PC        │     │ Full Network Access              │
│ 10.200.0.10     │────►│ 172.16.0.0/16, 172.17.0.0/16     │
│ (Road Warrior)  │     │ Can reach ALL VLANs directly     │
└─────────────────┘     └──────────────────────────────────┘
                                      │
                                      ▼
                        ┌──────────────────────────────────┐
                        │ Royal Server (VLAN 20)           │
                        │ 172.16.20.11                     │
                        │ Lives with application servers   │
                        └──────────────────────────────────┘
```

### After

```
┌─────────────────┐     ┌──────────────────────────────────┐
│ Admin PC        │     │ Management VLANs Only            │
│ 10.200.0.10     │────►│ 172.16.99.0/24, 172.17.99.0/24   │
│ (Road Warrior)  │     │ Restricted access (least priv.)  │
└─────────────────┘     └──────────────────────────────────┘
                                      │
                                      ▼
                        ┌──────────────────────────────────┐
                        │ Royal Server (VLAN 99)           │
                        │ 172.16.99.11                     │
                        │ Bastion host / secure gateway    │
                        └──────────────────────────────────┘
                                      │
                                      │ (Proxied connections)
                                      ▼
                        ┌──────────────────────────────────┐
                        │ All Other VLANs                  │
                        │ Infrastructure (5), Servers (20) │
                        │ Clients (10)                     │
                        └──────────────────────────────────┘
```

### IP Changes

| Component | Before | After |
|-----------|--------|-------|
| P-WIN-SRV1 IP | 172.16.20.11 | **172.16.99.11** |
| P-WIN-SRV1 VLAN | 20 (Servers) | **99 (Management)** |
| P-WIN-SRV1 Gateway | 172.16.20.1 | **172.16.99.1** |
| Road Warrior AllowedIPs | 172.16.0.0/16, 172.17.0.0/16, 10.200.0.0/24 | **172.16.99.0/24, 172.17.99.0/24, 10.200.0.0/24** |

---

## 1. Royal Server Migration

### A. Proxmox VLAN Tag Change

> [!IMPORTANT]
> Perform this step from the **Proxmox VM console** (noVNC or SPICE), **NOT RDP**.
> Changing the VLAN tag will immediately disconnect any existing RDP sessions.

1. Open Proxmox web interface
2. Select **P-WIN-SRV1** > **Hardware**
3. Double-click **Network Device**
4. Change **VLAN Tag** from `20` to `99`
5. Click **OK**

At this point, P-WIN-SRV1 is on VLAN 99 but still has the old IP address. It will be unreachable until the IP is updated.

> **Why does VLAN change break connectivity instantly?** The hypervisor applies VLAN tags at the virtual switch level. When you change the tag from 20 to 99, frames from the VM are now tagged with VLAN 99 - but the VM still has an IP from the VLAN 20 subnet (172.16.20.x). The VLAN 99 gateway (172.16.99.1) won't route packets with a source IP from a different subnet.

### B. Update Windows Server IP Configuration

**From the Proxmox console session:**

```powershell
# [P-WIN-SRV1 - via Proxmox Console]

# Add new IP address first (before removing old)
# Why add before remove? Ensures you never lose ALL connectivity - if something
# goes wrong with the new IP, you can still troubleshoot via the old one
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.99.11 -PrefixLength 24 -DefaultGateway 172.16.99.1

# Remove old IP address
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 172.16.20.11 -Confirm:$false

# Remove old default gateway route (if still present)
Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop 172.16.20.1 -Confirm:$false -ErrorAction SilentlyContinue

# Verify DNS servers are still correct (should point to DCs)
Get-DnsClientServerAddress -InterfaceAlias "Ethernet"
# Expected: 172.16.5.10, 172.17.5.10
```

**Verify connectivity:**

```powershell
# [P-WIN-SRV1]

# Test gateway
Test-NetConnection -ComputerName 172.16.99.1

# Test DC connectivity
Test-NetConnection -ComputerName 172.16.5.10

# Test DNS resolution
nslookup google.com
```

### C. Fix Network Profile (If Needed)

After an IP change, Windows may temporarily lose domain authentication:

> **Why does this happen?** Windows Network Location Awareness (NLA) service detects the domain by querying DNS for the `_ldap._tcp.dc._msdcs.<domain>` SRV record. When the IP changes, NLA may not immediately re-query, causing the network profile to fall back to "Public" or "Private" until a reboot triggers re-detection.

```powershell
# [P-WIN-SRV1]

# Check current network profile
Get-NetConnectionProfile

# If it shows "Public", set to Private temporarily
Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private

# Reboot to allow NLA to re-detect domain
Restart-Computer -Force
```

After reboot, verify domain authentication:

```powershell
# [P-WIN-SRV1]
Get-NetConnectionProfile
# Expected: Name = reginleif.io, NetworkCategory = DomainAuthenticated
```

---

## 2. DNS Record Update

> **Why is DNS update critical?** Other systems (Royal TS, monitoring tools, scripts) may reference `p-win-srv1.reginleif.io` by hostname. Without updating DNS, these will continue pointing to the old IP (172.16.20.11) which no longer exists. Additionally, Kerberos authentication relies on matching forward and reverse DNS lookups.

### A. Update Forward Lookup Zone (A Record)

```powershell
# [P-WIN-DC1]

# Remove old A record
Remove-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "P-WIN-SRV1" -RRType A -Force

# Add new A record with Management VLAN IP
Add-DnsServerResourceRecordA -ZoneName "reginleif.io" -Name "P-WIN-SRV1" -IPv4Address 172.16.99.11

# Verify the change
Get-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "P-WIN-SRV1"
```

### B. Update Reverse Lookup Zone (PTR Record)

```powershell
# [P-WIN-DC1]

# Verify VLAN 99 reverse zone exists (created in Project 11)
Get-DnsServerZone | Where-Object { $_.ZoneName -like "*99.16.172*" }

# Add PTR record for new IP
Add-DnsServerResourceRecordPtr -ZoneName "99.16.172.in-addr.arpa" -Name "11" -PtrDomainName "p-win-srv1.reginleif.io"

# Remove old PTR from VLAN 20 reverse zone
Remove-DnsServerResourceRecord -ZoneName "20.16.172.in-addr.arpa" -Name "11" -RRType PTR -Force -ErrorAction SilentlyContinue
```

### C. Clear DNS Caches

```powershell
# [P-WIN-DC1]
Clear-DnsServerCache
Clear-DnsClientCache

# [P-WIN-SRV1]
Clear-DnsClientCache

# [Admin PC - PowerShell or cmd]
ipconfig /flushdns
```

---

## 3. Road Warrior VPN Restriction

This is the key security change - restricting Road Warrior access to Management VLANs only.

> **Why restrict VPN access?** In enterprise security, this follows the **principle of least privilege** - users (even admins) should only have access to what they need. By limiting VPN to Management VLAN only, a compromised VPN credential cannot directly access Domain Controllers, application servers, or client workstations. The attacker would need to also compromise Royal Server to move laterally.

### A. Update WireGuard Client Configuration

On the **Admin PC**, edit the WireGuard configuration file (`reginleif-lab.conf`):

**Before:**

```ini
[Interface]
PrivateKey = <your-private-key>
Address = 10.200.0.10/32
DNS = 172.16.5.10, 172.17.5.10

[Peer]
PublicKey = <HQ-public-key>
AllowedIPs = 172.16.0.0/16, 172.17.0.0/16, 10.200.0.0/24
Endpoint = 192.168.1.240:51820
PersistentKeepalive = 25
```

**After:**

```ini
[Interface]
PrivateKey = <your-private-key>
Address = 10.200.0.10/32
DNS = 172.16.5.10, 172.17.5.10

[Peer]
PublicKey = <HQ-public-key>
AllowedIPs = 172.16.99.0/24, 172.17.99.0/24, 10.200.0.0/24
Endpoint = 192.168.1.240:51820
PersistentKeepalive = 25
```

**Key changes:**

- `172.16.0.0/16` becomes `172.16.99.0/24` (HQ Management VLAN only)
- `172.17.0.0/16` becomes `172.17.99.0/24` (Branch Management VLAN only)
- `10.200.0.0/24` remains unchanged (WireGuard tunnel subnet)

> **How does AllowedIPs enforce this?** WireGuard's `AllowedIPs` controls the client's routing table. Only traffic destined for these subnets is sent through the VPN tunnel. If you try to reach `172.16.5.10` (DC1), the client has no matching route through the tunnel - the packet goes to your home network's default gateway instead, which cannot reach the lab's private IPs. This is **client-side enforcement**, not firewall blocking.

> [!NOTE]
> DNS queries still work because they route through the VPN tunnel to OPNsense, which forwards them to the DCs. However, direct access to DC IPs is no longer routed.

### B. Restart WireGuard Tunnel

1. Deactivate the tunnel in the WireGuard client
2. Reactivate the tunnel
3. Verify handshake establishes successfully

---

## 4. Royal TS Client Update

Update the Royal Server connection in Royal TS:

1. Open Royal TS
2. Edit the Royal Server object
3. Change **Computer Name** to `172.16.99.11` (or `p-win-srv1.reginleif.io`)
4. **Port** remains `54899`
5. Right-click > **Test** - Should show green/success

---

## 5. Validation

### A. Connectivity Tests

```powershell
# [Admin PC - via WireGuard VPN]

# Should SUCCEED - Royal Server on Management VLAN
Test-NetConnection -ComputerName 172.16.99.11 -Port 54899

# Should SUCCEED - Management VLAN gateway
Test-NetConnection -ComputerName 172.16.99.1

# Should FAIL - Servers VLAN (no route through VPN)
Test-NetConnection -ComputerName 172.16.20.12 -Port 3389

# Should FAIL - Infrastructure VLAN (no route through VPN)
Test-NetConnection -ComputerName 172.16.5.10 -Port 3389

# Should FAIL - Clients VLAN (no route through VPN)
Test-NetConnection -ComputerName 172.16.10.1
```

### B. Gateway Access Test

> **Why is this test important?** This validates the entire bastion model works end-to-end. Even though your VPN can't reach DC1 directly, Royal Server CAN - because Royal Server is on the internal network with full routing to all VLANs. This proves the "funnel all access through the bastion" architecture is working.

Using Royal TS, verify that proxied connections work:

1. Connect to Royal Server (`172.16.99.11:54899`)
2. Create an RDP connection to P-WIN-DC1 (`172.16.5.10`)
3. Set **Secure Gateway** to Royal Server
4. Connect and verify RDP session establishes

This confirms:
- Road Warrior can reach Royal Server on Management VLAN
- Royal Server can reach Infrastructure VLAN (and all others)
- All admin access properly funnels through the gateway

### C. Validation Checklist

- [ ] P-WIN-SRV1 IP changed to 172.16.99.11
- [ ] P-WIN-SRV1 VLAN tag changed to 99 in Proxmox
- [ ] DNS A record updated (p-win-srv1.reginleif.io = 172.16.99.11)
- [ ] Network profile shows "DomainAuthenticated" after reboot
- [ ] WireGuard client AllowedIPs restricted to Management VLANs
- [ ] Can connect to Royal Server via VPN
- [ ] **Cannot** directly reach Servers VLAN (172.16.20.x) via VPN
- [ ] **Cannot** directly reach Infrastructure VLAN (172.16.5.x) via VPN
- [ ] Royal TS gateway connections work through Royal Server

---

## 6. Reserved IP Addresses

The Management VLAN is now established for administrative access. The following addresses are reserved for future monitoring and logging infrastructure.

| IP | Reserved For | Status |
|----|--------------|--------|
| 172.16.99.1 | Gateway (OPNsense) | In use |
| 172.16.99.11 | Royal Server (P-WIN-SRV1) | In use |
| 172.16.99.20 | Monitoring Server (future) | Reserved |
| 172.16.99.21 | Syslog/SIEM (future) | Reserved |
| 172.16.99.22-29 | Additional monitoring tools | Reserved |

### Integration Points

When implementing monitoring, consider:

- **OPNsense:** Syslog export to centralized collector
- **Windows Servers:** Event forwarding to WEC collector
- **SNMP:** Network device monitoring (switches if physical)
- **Firewall logging:** Traffic analysis and threat detection

> [!TIP]
> Monitoring implementation will be covered in a future project. This section documents the architectural foundation.

---

## Network Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Management VLAN Access Architecture                     │
└─────────────────────────────────────────────────────────────────────────────┘

                           ┌──────────────────────┐
                           │   Internet / Home    │
                           │      Network         │
                           └──────────┬───────────┘
                                      │
                           ┌──────────┴───────────┐
                           │   OPNsenseHQ         │
                           │   WireGuard VPN      │
                           └──────────┬───────────┘
                                      │
                           ┌──────────┴───────────┐
                           │   Admin PC           │
                           │   10.200.0.10        │
                           │   AllowedIPs:        │
                           │   172.16.99.0/24     │
                           │   172.17.99.0/24     │
                           └──────────┬───────────┘
                                      │
                                      │ (Management VLANs only)
                                      ▼
                    ┌─────────────────────────────────────┐
                    │        VLAN 99 - Management         │
                    │        172.16.99.0/24               │
                    │  ┌───────────────────────────────┐  │
                    │  │  P-WIN-SRV1 (Royal Server)    │  │
                    │  │  172.16.99.11                 │  │
                    │  │  Bastion Host / Gateway       │  │
                    │  └───────────────┬───────────────┘  │
                    └──────────────────┼──────────────────┘
                                       │
                                       │ (Proxied via Royal Server)
                                       ▼
          ┌────────────────────────────┼────────────────────────────┐
          │                            │                            │
          ▼                            ▼                            ▼
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ VLAN 5           │     │ VLAN 20          │     │ VLAN 10          │
│ Infrastructure   │     │ Servers          │     │ Clients          │
│ 172.16.5.0/24    │     │ 172.16.20.0/24   │     │ 172.16.10.0/24   │
│                  │     │                  │     │                  │
│ P-WIN-DC1        │     │ P-WIN-SRV2       │     │ Workstations     │
│ 172.16.5.10      │     │ 172.16.20.12     │     │ (DHCP)           │
└──────────────────┘     └──────────────────┘     └──────────────────┘

Access Flow:
  1. Admin connects via WireGuard VPN (limited to VLAN 99 only)
  2. Admin reaches Royal Server (172.16.99.11) on Management VLAN
  3. Royal Server proxies connections to all other VLANs
  4. Direct access to Infrastructure/Servers/Clients VLANs is blocked
```
