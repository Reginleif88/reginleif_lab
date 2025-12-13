---
title: "Project 14: RADIUS/NPS Authentication"
tags: [radius, nps, opnsense, authentication, active-directory, aaa, network-security]
sites: [hq]
status: planned
---

## Goal

Deploy a dedicated NPS (Network Policy Server) for centralized RADIUS authentication in the reginleif.io domain:

- **P-WIN-SRV4 (172.16.20.14)**: Dedicated RADIUS server integrated with Active Directory
- **OPNsense Integration**: Enable AD-based authentication for firewall administration at both sites
- **Centralized Audit Trail**: Track all administrative access through RADIUS accounting

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-14-concepts)**

For educational context about RADIUS protocol, AAA framework, authentication methods (PAP/CHAP/PEAP/EAP-TLS), NPS architecture, and RADIUS vs TACACS+ comparison, see the dedicated concepts guide.

---

## Firewall Requirements

> [!NOTE]
> If you implemented the permissive `Trusted_Lab_Networks` firewall rule in Project 11, RADIUS traffic is already permitted between VLANs. The rules below document what is required for production environments with restrictive firewalls.

**Required firewall rules for RADIUS services:**

| Protocol | Port(s) | Source | Destination | Purpose |
|:---------|:--------|:-------|:------------|:--------|
| UDP | 1812 | 172.16.5.1 (OPNsenseHQ) | 172.16.20.14 | RADIUS Authentication |
| UDP | 1812 | 172.17.5.1 (OPNsenseBranch) | 172.16.20.14 | RADIUS Authentication |
| UDP | 1813 | 172.16.5.1 (OPNsenseHQ) | 172.16.20.14 | RADIUS Accounting |
| UDP | 1813 | 172.17.5.1 (OPNsenseBranch) | 172.16.20.14 | RADIUS Accounting |
| TCP/UDP | 389 | 172.16.20.14 | Domain Controllers | LDAP (AD authentication) |
| TCP | 636 | 172.16.20.14 | Domain Controllers | LDAPS (secure LDAP) |

> [!NOTE]
> The source IPs (172.16.5.1 and 172.17.5.1) are the OPNsense firewalls' Infrastructure VLAN interfaces, as these are the RADIUS clients sending authentication requests to NPS.

> [!TIP]
> Legacy RADIUS implementations used ports 1645 (authentication) and 1646 (accounting). Modern implementations use 1812/1813 as defined in RFC 2865/2866. OPNsense defaults to 1812/1813.

---

## Use Cases in This Lab

With NPS configured, you gain the following capabilities:

| Use Case | Benefit |
|:---------|:--------|
| **OPNsense Web GUI Login** | Admins authenticate with AD credentials instead of local OPNsense accounts |
| **OPNsense SSH Access** | SSH to firewalls using AD credentials |
| **Centralized Access Control** | Add/remove admin access by modifying AD group membership |
| **Audit Trail** | All login attempts logged in Windows Event Log and NPS accounting |
| **Single Sign-On** | Same credentials across all firewalls (HQ and Branch) |
| **Account Policies** | AD password policies, lockout, expiration apply to firewall access |

---

## 1. NPS Server VM Configuration

Create a new dedicated server for NPS following the same approach as other member servers.

### VM Hardware (Proxmox)

| Setting | Value | Notes |
|:--------|:------|:------|
| **OS Type** | Microsoft Windows 2022 (Desktop Experience) | GUI recommended for NPS console |
| **Machine** | q35 | Native PCIe |
| **BIOS** | OVMF (UEFI) | |
| **CPU** | Type Host, 2 Cores | Minimal requirements |
| **RAM** | 4096 MB (4 GB) | Sufficient for dedicated NPS |
| **Controller** | VirtIO SCSI Single | IO Thread enabled |
| **Disk** | 60 GB (VirtIO SCSI) | OS and logs |
| **Network** | VirtIO (Paravirtualized), VLAN 20 | Servers VLAN |

### Network Configuration

| Setting | Value |
|:--------|:------|
| **Hostname** | P-WIN-SRV4 |
| **IP Address** | 172.16.20.14 (Static) |
| **Subnet Mask** | 255.255.255.0 |
| **Default Gateway** | 172.16.20.1 |
| **DNS Servers** | 172.16.5.10, 172.17.5.10 |
| **Domain Join** | Yes - `reginleif.io` |

---

## 2. Initial Windows Configuration

After installing Windows Server 2022 and VirtIO drivers (per Project 2):

```powershell
# [P-WIN-SRV4]
# Set hostname (will require restart)
Rename-Computer -NewName "P-WIN-SRV4" -Restart
```

After restart, configure network and join domain:

```powershell
# [P-WIN-SRV4]
# Configure static IP
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress "172.16.20.14" `
    -PrefixLength 24 `
    -DefaultGateway "172.16.20.1"

# Set DNS servers
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses "172.16.5.10","172.17.5.10"

# Verify DNS resolution
Resolve-DnsName reginleif.io

# Join domain (will require restart)
Add-Computer -DomainName "reginleif.io" -Credential (Get-Credential) -Restart
```

---

## 3. Install NPS Role

```powershell
# [P-WIN-SRV4]
# Install Network Policy and Access Services role
Install-WindowsFeature NPAS -IncludeManagementTools

# Verify installation
Get-WindowsFeature NPAS
```

**Expected output:**

```
Display Name                                            Name                       Install State
------------                                            ----                       -------------
[X] Network Policy and Access Services                  NPAS                           Installed
```

---

## 4. Register NPS in Active Directory

NPS must be registered in Active Directory to have permission to read user account properties (including group membership and dial-in permissions):

```powershell
# [P-WIN-SRV4]
# Register NPS server in Active Directory
netsh ras add registeredserver domain=reginleif.io server=P-WIN-SRV4

# Verify registration
netsh ras show registeredserver
```

**Alternative (GUI):**

1. Open **Network Policy Server** console (nps.msc)
2. Right-click **NPS (Local)** > **Register server in Active Directory**
3. Click **OK** on the confirmation dialogs

> [!NOTE]
> Registering NPS adds the computer account to the **RAS and IAS Servers** security group in AD. This group has permission to read remote access properties of user accounts.

---

## 5. Configure Windows Firewall

Allow RADIUS traffic from OPNsense firewalls:

```powershell
# [P-WIN-SRV4]
# Define RADIUS client IPs
$RadiusClients = @(
    "172.16.5.1",   # OPNsenseHQ
    "172.17.5.1"    # OPNsenseBranch
)

# Create firewall rule for RADIUS Authentication
New-NetFirewallRule -DisplayName "RADIUS Authentication (UDP 1812)" `
    -Direction Inbound -Protocol UDP -LocalPort 1812 `
    -Action Allow -RemoteAddress $RadiusClients `
    -Profile Domain,Private

# Create firewall rule for RADIUS Accounting
New-NetFirewallRule -DisplayName "RADIUS Accounting (UDP 1813)" `
    -Direction Inbound -Protocol UDP -LocalPort 1813 `
    -Action Allow -RemoteAddress $RadiusClients `
    -Profile Domain,Private

# Verify rules
Get-NetFirewallRule -DisplayName "RADIUS*" |
    Select-Object DisplayName, Enabled, Direction, Action
```

---

## 6. Create AD Security Groups

Create security groups to control who can authenticate to OPNsense:

```powershell
# [P-WIN-DC1]
# Create OU for RADIUS groups (optional, for organization)
New-ADOrganizationalUnit -Name "RADIUS Groups" -Path "DC=reginleif,DC=io"

# Create security group for OPNsense administrators
New-ADGroup -Name "RADIUS-OPNsense-Admins" `
    -GroupScope Global `
    -GroupCategory Security `
    -Path "OU=RADIUS Groups,DC=reginleif,DC=io" `
    -Description "Members can authenticate to OPNsense firewalls with admin privileges"

# Add your admin account to the group
Add-ADGroupMember -Identity "RADIUS-OPNsense-Admins" -Members "Administrator"

# Verify group membership
Get-ADGroupMember -Identity "RADIUS-OPNsense-Admins"
```

> [!TIP]
> For production environments, consider creating multiple groups for different access levels:
> - `RADIUS-OPNsense-Admins`: Full administrative access
> - `RADIUS-OPNsense-ReadOnly`: View-only access (if OPNsense supports it)

---

## 7. Configure RADIUS Clients

A **RADIUS client** is any device that sends authentication requests to the RADIUS server. In our case, both OPNsense firewalls are RADIUS clients.

### A. Open NPS Console

```powershell
# [P-WIN-SRV4]
nps.msc
```

### B. Add OPNsenseHQ as RADIUS Client

1. Expand **RADIUS Clients and Servers**
2. Right-click **RADIUS Clients** > **New**
3. Configure:

| Field | Value |
|:------|:------|
| **Enable this RADIUS client** | Checked |
| **Friendly name** | OPNsenseHQ |
| **Address (IP or DNS)** | 172.16.5.1 |
| **Shared secret** | Generate or enter a strong secret (20+ characters) |
| **Confirm shared secret** | Same as above |

4. Click **OK**

> [!IMPORTANT]
> **Save the shared secret securely!** You'll need to enter the same secret in OPNsense. Use a password manager or secure note. Example format: `Rad!us$ecret#HQ2024!` (but generate your own unique secret).

### C. Add OPNsenseBranch as RADIUS Client

Repeat the above steps:

| Field | Value |
|:------|:------|
| **Friendly name** | OPNsenseBranch |
| **Address (IP or DNS)** | 172.17.5.1 |
| **Shared secret** | Use a different secret than HQ (best practice) |

### D. Verify RADIUS Clients (PowerShell)

```powershell
# [P-WIN-SRV4]
# List configured RADIUS clients
Get-NpsRadiusClient | Select-Object Name, Address, Enabled
```

**Expected output:**

```
Name            Address      Enabled
----            -------      -------
OPNsenseHQ      172.16.5.1      True
OPNsenseBranch  172.17.5.1      True
```

---

## 8. Create Connection Request Policy

Connection Request Policies determine how NPS handles incoming RADIUS requests. For a single NPS server, we process requests locally.

### A. Create Policy (GUI)

1. In NPS console, expand **Policies**
2. Right-click **Connection Request Policies** > **New**
3. **Policy name**: `OPNsense Authentication`
4. **Type of network access server**: `Unspecified`
5. Click **Next**

### B. Specify Conditions

1. Click **Add**
2. Select **Client Friendly Name**
3. Click **Add**
4. Enter: `OPNsense*` (matches both OPNsenseHQ and OPNsenseBranch)
5. Click **OK**, then **Next**

### C. Specify Connection Request Forwarding

1. Select **Authenticate requests on this server**
2. Click **Next**

### D. Configure Authentication Methods

1. Leave defaults (we'll configure in Network Policy)
2. Click **Next** through remaining screens
3. Click **Finish**

### E. Set Policy Order

1. Right-click the new policy > **Move Up** (if needed)
2. Ensure it's processed before any default "deny" policies

---

## 9. Create Network Policy

Network Policies determine **who** can connect and **what access** they receive. This is where we grant access to the RADIUS-OPNsense-Admins group.

### A. Create Policy (GUI)

1. In NPS console, expand **Policies**
2. Right-click **Network Policies** > **New**
3. **Policy name**: `OPNsense Admin Access`
4. **Type of network access server**: `Unspecified`
5. Click **Next**

### B. Specify Conditions

Add conditions that must be met for the policy to apply:

**Condition 1 - Windows Group:**
1. Click **Add**
2. Select **Windows Groups** > **Add**
3. Click **Add Groups**
4. Enter: `RADIUS-OPNsense-Admins`
5. Click **OK** until back at conditions screen

**Condition 2 - Client Friendly Name (optional but recommended):**
1. Click **Add**
2. Select **Client Friendly Name** > **Add**
3. Enter: `OPNsense*`
4. Click **OK**

5. Click **Next**

### C. Specify Access Permission

1. Select **Access granted**
2. Click **Next**

### D. Configure Authentication Methods

1. **Uncheck** "Microsoft Encrypted Authentication version 2 (MS-CHAPv2)" if you don't need it
2. **Check** "Unencrypted authentication (PAP, SPAP)"
   - Required because OPNsense web GUI uses PAP
3. Click **Next**

> [!WARNING]
> PAP transmits passwords in a reversible format. This is acceptable because:
> 1. Browser → OPNsense is encrypted via HTTPS
> 2. OPNsense → NPS should be on trusted internal network
> 3. RADIUS uses the shared secret to encrypt the password attribute
>
> For higher security, ensure strong shared secrets and consider network encryption (IPsec) between OPNsense and NPS.

### E. Configure Constraints

1. Leave defaults or configure as needed:
   - **Idle Timeout**: Optional session idle timeout
   - **Session Timeout**: Maximum session length
2. Click **Next**

### F. Configure Settings

1. Under **RADIUS Attributes** > **Standard**:
   - Optionally add **Service-Type** = `Administrative` (helps identify admin logins in logs)
2. Click **Next**

### G. Complete the Policy

1. Review settings
2. Click **Finish**

### H. Set Policy Order

**Critical:** Network policies are evaluated in order. Ensure your policy is processed before any deny policies:

1. Right-click `OPNsense Admin Access` > **Move Up**
2. It should be at or near the top of the list

### I. Disable Default Policies (Optional)

NPS comes with default policies that may interfere. Consider disabling them:

1. Right-click "Connections to Microsoft Routing and Remote Access server" > **Disable**
2. Right-click "Connections to other access servers" > **Disable**

---

## 10. Configure OPNsense RADIUS Server

Now configure OPNsense to use NPS for authentication.

### A. Add RADIUS Server (OPNsenseHQ)

1. Log into OPNsenseHQ web GUI
2. Navigate to **System > Access > Servers**
3. Click **+ Add**
4. Configure:

| Field | Value |
|:------|:------|
| **Descriptive name** | NPS-RADIUS |
| **Type** | RADIUS |
| **Hostname or IP address** | 172.16.20.14 |
| **Shared secret** | (Same secret entered in NPS for OPNsenseHQ) |
| **Services offered** | Authentication and Accounting |
| **Authentication port** | 1812 |
| **Accounting port** | 1813 |
| **Authentication Timeout** | 5 |
| **RADIUS NAS IP Attribute** | (Leave default or set to OPNsense LAN IP) |

5. Click **Save**

### B. Test RADIUS Connectivity

1. In OPNsense, go to **System > Access > Tester**
2. Select **Authentication server**: `NPS-RADIUS`
3. Enter credentials of a user in the `RADIUS-OPNsense-Admins` group
4. Click **Test**

**Expected result:** "User [username] authenticated successfully"

If authentication fails, check:
- Shared secret matches exactly (case-sensitive)
- Firewall allows UDP 1812 from OPNsense to NPS
- User is member of `RADIUS-OPNsense-Admins` group
- NPS policies are correctly ordered

---

## 11. Create OPNsense Group for RADIUS Users

OPNsense requires a local group to map RADIUS users to privileges.

### A. Create Admin Group

1. Navigate to **System > Access > Groups**
2. Click **+ Add**
3. Configure:

| Field | Value |
|:------|:------|
| **Group name** | admins |
| **Description** | RADIUS Administrators |
| **Member(s)** | (Leave empty - RADIUS users are mapped dynamically) |

4. Click **Save**

### B. Assign Privileges

1. Click the **pencil icon** to edit the `admins` group
2. Click **+ Add** under **Assigned Privileges**
3. Select **GUI - All pages** (or specific pages for limited access)
4. Click **Save**

---

## 12. Enable RADIUS Authentication for Web GUI

### A. Configure Authentication Settings

1. Navigate to **System > Settings > Administration**
2. Scroll to **Authentication** section
3. Configure:

| Field | Value |
|:------|:------|
| **Server** | NPS-RADIUS |
| **Group** | admins |

4. Click **Save**

### B. Test RADIUS Login

1. **Keep your current session open** (in case RADIUS fails)
2. Open a new private/incognito browser window
3. Navigate to OPNsense web GUI
4. Log in with AD credentials (username without domain prefix)
5. Verify you have admin access

> [!WARNING]
> **Do not log out of your local admin session until you've verified RADIUS login works!** If RADIUS is misconfigured, you could lock yourself out. Local accounts still work as fallback.

---

## 13. Enable RADIUS Authentication for SSH (Optional)

If you want to SSH to OPNsense using AD credentials:

### A. Enable SSH (if not already)

1. Navigate to **System > Settings > Administration**
2. Under **Secure Shell**:
   - **Enable Secure Shell**: Checked
   - **Root Login**: Permit root user login (for local fallback)
   - **Authentication Method**: Permit password login
3. Click **Save**

### B. Configure SSH RADIUS

SSH authentication in OPNsense uses the same authentication server configured in System > Access > Servers. Once RADIUS is configured for web GUI, SSH will also use it.

Test SSH access:

```bash
# From Admin PC or another machine
ssh your_ad_username@172.16.5.1
```

Enter your AD password when prompted.

---

## 14. Configure Branch OPNsense

Repeat the OPNsense configuration for the Branch firewall.

### A. Add RADIUS Server (OPNsenseBranch)

1. Log into OPNsenseBranch web GUI
2. Navigate to **System > Access > Servers**
3. Click **+ Add**
4. Configure:

| Field | Value |
|:------|:------|
| **Descriptive name** | NPS-RADIUS |
| **Type** | RADIUS |
| **Hostname or IP address** | 172.16.20.14 |
| **Shared secret** | (Same secret entered in NPS for OPNsenseBranch) |
| **Services offered** | Authentication and Accounting |
| **Authentication port** | 1812 |
| **Accounting port** | 1813 |

5. Click **Save**

### B. Create Admin Group

Follow the same steps as Section 11 to create the `admins` group with appropriate privileges.

### C. Enable RADIUS Authentication

1. Navigate to **System > Settings > Administration**
2. Configure Authentication to use **NPS-RADIUS** server with **admins** group
3. Click **Save**
4. Test login from a new browser session

> [!NOTE]
> Branch OPNsense connects to NPS (172.16.20.14) through the WireGuard site-to-site VPN tunnel established in Project 7. Ensure the tunnel is active before testing.

---

## 15. NPS Logging and Accounting

### A. View Authentication Logs

NPS logs authentication events to the Windows Event Log:

```powershell
# [P-WIN-SRV4]
# View recent NPS authentication events
Get-WinEvent -LogName "Security" -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and (EventID=6272 or EventID=6273)]]" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message
```

| Event ID | Meaning |
|:---------|:--------|
| 6272 | Network Policy Server granted access to a user |
| 6273 | Network Policy Server denied access to a user |
| 6274 | Network Policy Server discarded the request |
| 6278 | Network Policy Server granted full access (EAP) |

### B. Configure RADIUS Accounting

For detailed session logging:

1. In NPS console, expand **Accounting**
2. Right-click **Configure Accounting**
3. Select **Log to a text file on the local computer**
4. Configure log location (default: `C:\Windows\System32\LogFiles`)
5. Click **Next** and configure log settings
6. Click **Finish**

### C. View Accounting Logs

```powershell
# [P-WIN-SRV4]
# View accounting log files
Get-ChildItem "C:\Windows\System32\LogFiles\IN*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5
```

---

## 16. Validation

### A. Test Authentication from Both Sites

**From HQ:**
```powershell
# Test RADIUS from HQ OPNsense
# Use the OPNsense tester or try logging in via web GUI
```

**From Branch:**
```powershell
# Ensure VPN tunnel is active
ping 172.16.20.14

# Test RADIUS from Branch OPNsense
# Use the OPNsense tester or try logging in via web GUI
```

### B. Verify NPS Event Logs

```powershell
# [P-WIN-SRV4]
# Check for recent successful authentications
Get-WinEvent -LogName "Security" -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-Security-Auditing'] and EventID=6272]]" -MaxEvents 5 |
    ForEach-Object {
        Write-Host "Time: $($_.TimeCreated)"
        Write-Host "Message: $($_.Message.Substring(0, [Math]::Min(500, $_.Message.Length)))..."
        Write-Host ""
    }
```

### C. Verify Group Membership

```powershell
# [P-WIN-DC1]
# Confirm user is in the RADIUS group
Get-ADGroupMember -Identity "RADIUS-OPNsense-Admins" |
    Select-Object Name, SamAccountName
```

### D. Validation Checklist

**NPS Server (P-WIN-SRV4):**
- [ ] NPS role installed
- [ ] NPS registered in Active Directory
- [ ] Windows Firewall rules allow UDP 1812/1813
- [ ] RADIUS client for OPNsenseHQ configured (172.16.5.1)
- [ ] RADIUS client for OPNsenseBranch configured (172.17.5.1)
- [ ] Connection Request Policy created
- [ ] Network Policy created with RADIUS-OPNsense-Admins condition
- [ ] PAP authentication enabled in policy

**Active Directory:**
- [ ] RADIUS-OPNsense-Admins security group created
- [ ] Admin users added to the group

**OPNsenseHQ:**
- [ ] RADIUS server configured (NPS-RADIUS)
- [ ] RADIUS tester shows successful authentication
- [ ] Admin group created with GUI privileges
- [ ] RADIUS authentication enabled for web GUI
- [ ] Login with AD credentials successful

**OPNsenseBranch:**
- [ ] RADIUS server configured (NPS-RADIUS)
- [ ] RADIUS tester shows successful authentication
- [ ] Admin group created with GUI privileges
- [ ] RADIUS authentication enabled for web GUI
- [ ] Login with AD credentials successful (via VPN tunnel)

**Logging:**
- [ ] NPS Event Log shows authentication events (6272/6273)
- [ ] (Optional) Accounting log file configured

---

## Network Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    RADIUS Authentication Infrastructure                      │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  VLAN 20 - Servers (172.16.20.0/24)                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  P-WIN-SRV4 (172.16.20.14)                                             │ │
│  │  NPS (Network Policy Server)                                           │ │
│  │                                                                         │ │
│  │  RADIUS Clients:                                                       │ │
│  │  ├─ OPNsenseHQ (172.16.5.1)                                           │ │
│  │  └─ OPNsenseBranch (172.17.5.1)                                       │ │
│  │                                                                         │ │
│  │  Policies:                                                              │ │
│  │  ├─ Connection Request: OPNsense Authentication                        │ │
│  │  └─ Network Policy: OPNsense Admin Access                              │ │
│  │      └─ Condition: Windows Group = RADIUS-OPNsense-Admins             │ │
│  │                                                                         │ │
│  │  Ports:                                                                 │ │
│  │  ├─ UDP 1812 (Authentication)                                          │ │
│  │  └─ UDP 1813 (Accounting)                                              │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
           │                                               │
           │ LDAP (389/636)                                │ UDP 1812/1813
           │ Query AD for user/group                       │ RADIUS Auth
           ▼                                               ▼
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│  VLAN 5 - Infrastructure (HQ)    │    │  VLAN 5 - Infrastructure         │
│  172.16.5.0/24                   │    │  172.16.5.0/24 & 172.17.5.0/24   │
│                                  │    │                                  │
│  P-WIN-DC1 (172.16.5.10)        │    │  OPNsenseHQ (172.16.5.1)        │
│  ├─ Active Directory            │    │  ├─ RADIUS Client               │
│  ├─ DNS                          │    │  ├─ Web GUI Auth → NPS          │
│  └─ User accounts/groups         │    │  └─ SSH Auth → NPS              │
│                                  │    │                                  │
│  Security Groups:                │    │  OPNsenseBranch (172.17.5.1)    │
│  └─ RADIUS-OPNsense-Admins      │    │  ├─ RADIUS Client               │
│      └─ Administrator            │    │  ├─ Web GUI Auth → NPS          │
│                                  │    │  └─ (via WireGuard VPN)         │
└──────────────────────────────────┘    └──────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                        AUTHENTICATION FLOW                                   │
└─────────────────────────────────────────────────────────────────────────────┘

  Admin Browser              OPNsense                 NPS                    AD
       │                        │                      │                      │
       │  1. HTTPS Login        │                      │                      │
       │  (username/password)   │                      │                      │
       │ ─────────────────────► │                      │                      │
       │                        │                      │                      │
       │                        │  2. Access-Request   │                      │
       │                        │  UDP 1812            │                      │
       │                        │ ───────────────────► │                      │
       │                        │                      │                      │
       │                        │                      │  3. LDAP Query       │
       │                        │                      │ ───────────────────► │
       │                        │                      │                      │
       │                        │                      │  4. User valid,      │
       │                        │                      │  Group member        │
       │                        │                      │ ◄─────────────────── │
       │                        │                      │                      │
       │                        │  5. Access-Accept    │                      │
       │                        │ ◄─────────────────── │                      │
       │                        │                      │                      │
       │  6. Login successful   │                      │                      │
       │ ◄───────────────────── │                      │                      │
       │                        │                      │                      │
```

---

## Cross-Site Considerations

The NPS server is hosted at HQ (P-WIN-SRV4 on VLAN 20). Branch OPNsense authenticates through the WireGuard site-to-site VPN established in Project 7.

**Branch Site RADIUS Authentication:**

- RADIUS traffic from OPNsenseBranch (172.17.5.1) traverses the VPN tunnel to reach NPS (172.16.20.14)
- If the VPN tunnel is down, Branch OPNsense cannot authenticate via RADIUS
- Local OPNsense accounts remain as fallback for emergency access

> [!TIP]
> For production environments with strict uptime requirements, consider:
> - Deploying a second NPS server at the Branch site
> - Configuring OPNsense to use multiple RADIUS servers with failover
> - Ensuring local admin accounts exist for emergency access

---

## Troubleshooting

### Authentication Fails - "Access Denied"

**Check NPS Event Log:**
```powershell
# [P-WIN-SRV4]
Get-WinEvent -LogName "Security" -FilterXPath "*[System[EventID=6273]]" -MaxEvents 5 |
    ForEach-Object { $_.Message }
```

Common causes:
- User not in `RADIUS-OPNsense-Admins` group
- Network policy order incorrect (deny policy processed first)
- PAP not enabled in network policy
- Account locked out or disabled in AD

### Authentication Fails - "No Response from Server"

**Check connectivity:**
```powershell
# From OPNsense (Diagnostics > Ping)
# Ping NPS server
ping 172.16.20.14

# From NPS, check if RADIUS is listening
netstat -an | findstr 1812
```

Common causes:
- Windows Firewall blocking UDP 1812/1813
- Wrong IP address in RADIUS client configuration
- Branch site: VPN tunnel down

### Authentication Fails - "Shared Secret Mismatch"

**Symptoms:**
- NPS Event Log shows event 6273 with reason "The shared secret is incorrect"
- OPNsense tester shows authentication failure

**Solution:**
- Re-enter the shared secret in both NPS and OPNsense
- Shared secrets are case-sensitive
- Avoid special characters that might be interpreted differently

### User Can Authenticate But No Access

**Check OPNsense group mapping:**
1. Verify the `admins` group exists in OPNsense
2. Verify the group has appropriate privileges assigned
3. Verify RADIUS authentication is set to use the correct group

### NPS Not Processing Requests

**Check NPS service:**
```powershell
# [P-WIN-SRV4]
Get-Service -Name "IAS" | Select-Object Status, StartType

# Restart if needed
Restart-Service -Name "IAS"
```

**Check NPS registration:**
```powershell
# Verify NPS is registered in AD
Get-ADGroupMember -Identity "RAS and IAS Servers" |
    Where-Object Name -like "*SRV4*"
```

### Branch OPNsense Cannot Reach NPS

**Verify VPN tunnel:**
1. Check WireGuard status in OPNsenseBranch
2. Verify handshake is recent
3. Test ping to 172.16.20.14 from Branch

**Check routing:**
- Ensure 172.16.20.0/24 is in the allowed IPs for the WireGuard tunnel
- Check OPNsense firewall rules allow RADIUS traffic

### Useful Diagnostic Commands

**On NPS Server:**
```powershell
# Check NPS configuration
netsh nps show config

# Export NPS configuration (for backup/review)
netsh nps export filename="C:\NPSConfig.xml" exportPSK=YES

# Check RADIUS clients
Get-NpsRadiusClient | Format-List *

# Check network policies
Get-NpsNetworkPolicy | Select-Object Name, ProcessingOrder, Enabled
```

**On OPNsense:**
- **System > Access > Tester**: Test RADIUS authentication
- **Diagnostics > Ping**: Test connectivity to NPS
- **System > Log Files > General**: Check for authentication errors

---

## Security Considerations

### Shared Secret Strength

- Use at least 20 characters
- Include uppercase, lowercase, numbers, and symbols
- Use different secrets for each RADIUS client
- Store secrets securely (password manager)

### Network Isolation

- RADIUS traffic should stay on trusted internal networks
- Consider IPsec encryption between OPNsense and NPS for additional security
- Branch traffic traverses VPN tunnel (already encrypted)

### Account Security

- Enable account lockout policies in AD
- Use strong password policies
- Consider implementing MFA for highly privileged accounts
- Regular review of RADIUS-OPNsense-Admins group membership

### Audit and Monitoring

- Regularly review NPS Event Logs
- Configure alerts for failed authentication attempts
- Enable RADIUS accounting for session tracking
- Export and archive logs for compliance
