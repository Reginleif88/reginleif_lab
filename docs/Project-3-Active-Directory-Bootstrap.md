---
title: "Project 3: Active Directory Bootstrap"
tags: [active-directory, deployment, windows-server, powershell]
sites: [hq]
status: completed
---

## Goal

Promote the first Domain Controller from project 2 (P-WIN-DC1) using PowerShell.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-03-concepts)**

For educational context about Active Directory, Domain Controllers, and Group Policy, see the dedicated concepts guide.

---

> [!NOTE]
> **Pre-VLAN Addressing:** This project uses flat network addressing (`172.16.0.0/24`). After VLAN segmentation in Project 11, P-WIN-DC1 moves to `172.16.5.10` on the Infrastructure VLAN, and the gateway changes from `172.16.0.1` to `172.16.5.1`.

## 1. Prerequisites

**VM Requirements:** Ensure P-WIN-DC1 was provisioned with at least 80 GB disk space per Project 2 specifications (AD database, SYSVOL, and logs require adequate storage).

### Enable Remote Desktop (sconfig)

From the console, use sconfig to enable RDP for easier management:

1. In sconfig, select **7** (Remote Desktop)
2. Select **E** to Enable
3. Select **1** for more secure (Network Level Authentication required)

### Configure Hostname and Network

In PowerShell or sconfig

```powershell
# [P-WIN-DC1]
# Set hostname
Rename-Computer -NewName "P-WIN-DC1" -Restart

# After restart, configure static IP with gateway
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress "172.16.0.10" `
    -PrefixLength 24 `
    -DefaultGateway "172.16.0.1"

# Set DNS to localhost (will host AD DNS after promotion)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses "127.0.0.1"
```

> [!NOTE]
> Interface name may vary. Run `Get-NetAdapter` to confirm.

> [!WARNING]
> **DNS Timing:** Setting DNS to `127.0.0.1` before AD promotion means external DNS resolution will fail until the promotion completes and the DNS Server service starts. This is expected behavior. If the promotion fails partway through, temporarily set DNS to the gateway (`172.16.0.1`) or a public DNS (`8.8.8.8`) to restore connectivity for troubleshooting.

---

## 2. Installation Script

Can be executed via RDP to allow copy-paste.

```powershell
# [P-WIN-DC1]
# Install AD Bits
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

# Promote to Forest Root
Install-ADDSForest `
    -DomainName "reginleif.io" `
    -DomainNetbiosName "REGINLEIF" `
    -InstallDns:$true `
    -Force
```

> [!NOTE]
> The command will prompt for the Directory Services Restore Mode (DSRM) password.

---

## 3. Post-Validation

Verify the Domain Controller is functioning correctly after promotion.

* **Ping Gateway:** Confirm network connectivity:

    ```powershell
    Test-Connection -ComputerName 172.16.0.1 -Count 4
    ```

* **Check AD Services:** Verify core services are running:

    ```powershell
    Get-Service ADWS, DNS, Netlogon, NTDS | Select Name, Status
    ```

    | Service | Purpose |
    |---------|---------|
    | **ADWS** | Active Directory Web Services — provides a web service interface (TCP 9389) that PowerShell's AD module uses to communicate with AD. If this service is stopped, cmdlets like `Get-ADUser` will fail. |
    | **DNS** | Provides name resolution for the domain. AD is tightly integrated with DNS for locating domain controllers and services. |
    | **Netlogon** | Handles domain authentication, secure channel maintenance, and replication of the NETLOGON share (logon scripts, GPO files). |
    | **NTDS** | The core AD database engine (ntds.dit). This is the actual directory service that stores all AD objects. |

* **Check Shares:** Confirm SYSVOL and NETLOGON exist:

    ```powershell
    Get-SmbShare | Where-Object { $_.Name -in 'SYSVOL', 'NETLOGON' }
    ```

* **Check Domain Mode:** Verify domain functional level:

    ```powershell
    Get-ADDomain | Select DomainMode
    ```

* **DNS Resolution:** Verify DNS is resolving the domain:

    ```powershell
    Resolve-DnsName reginleif.io
    ```

---

## 4. Time Synchronization (Proxmox)

Kerberos authentication requires time synchronization between domain controllers and clients within a 5-minute tolerance. If you experience authentication failures, time skew issues, or DC promotion errors, verify the hardware clock (RTC) is configured correctly.

**Verify RTC configuration:**

```bash
# [Proxmox Host]
qm config <VMID> | grep localtime
```

If `localtime: 1` is missing (should be auto-configured when "Microsoft Windows" OS type is selected):

```bash
# [Proxmox Host]
qm set <VMID> -localtime 1
# Requires full VM shutdown and restart (not reboot)
```

> [!NOTE]
> Proper NTP time synchronization for the domain will be configured in Project 8.

---

## 5. Disable Windows Update via GPO

Create a Group Policy to disable automatic updates for all domain-joined machines until centralized update management (WSUS) is configured.

```powershell
# [P-WIN-DC1]
# Create new GPO
New-GPO -Name "Disable Windows Update" -Comment "Temporary: Disable updates until WSUS is configured"

# Disable automatic updates
Set-GPRegistryValue -Name "Disable Windows Update" `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" `
    -ValueName "NoAutoUpdate" `
    -Type DWord `
    -Value 1

# Disable access to Windows Update (prevents manual checks too)
Set-GPRegistryValue -Name "Disable Windows Update" `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -ValueName "DisableWindowsUpdateAccess" `
    -Type DWord `
    -Value 1

# Remove access to "Check for updates" in Settings
Set-GPRegistryValue -Name "Disable Windows Update" `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -ValueName "SetDisableUXWUAccess" `
    -Type DWord `
    -Value 1

# Prevent connecting to Windows Update Internet locations
Set-GPRegistryValue -Name "Disable Windows Update" `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -ValueName "DoNotConnectToWindowsUpdateInternetLocations" `
    -Type DWord `
    -Value 1

# Link GPO to domain root (applies to all domain-joined machines)
Get-GPO -Name "Disable Windows Update" | New-GPLink -Target "DC=reginleif,DC=io"
```

> **Why disable via GPO?** Centralized management ensures all domain-joined servers (P-WIN-SRV1, future servers) automatically inherit the policy. Remove or unlink this GPO once WSUS or another update solution is deployed.

---

## 6. Organizational Unit Structure

> [!NOTE]
> **Why create OUs now?** Organizational Units provide a logical structure for Active Directory objects and serve as the boundary for Group Policy application and administrative delegation. Creating a basic OU structure during AD bootstrap establishes best practices from the start.

Create a standardized OU structure for the reginleif.io domain:

```powershell
# [P-WIN-DC1]
# Create site-based organizational structure
New-ADOrganizationalUnit -Name "HQ" -Path "DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Headquarters (Proxmox)"

New-ADOrganizationalUnit -Name "Branch" -Path "DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Branch Office (Hyper-V)"

# Create functional OUs under HQ
New-ADOrganizationalUnit -Name "Computers" -Path "OU=HQ,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "HQ Computer Accounts"

New-ADOrganizationalUnit -Name "Workstations" -Path "OU=Computers,OU=HQ,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Client Workstations"

New-ADOrganizationalUnit -Name "Servers" -Path "OU=Computers,OU=HQ,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Member Servers"

New-ADOrganizationalUnit -Name "Users" -Path "OU=HQ,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "HQ User Accounts"

New-ADOrganizationalUnit -Name "Service Accounts" -Path "OU=HQ,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Service and Application Accounts"

New-ADOrganizationalUnit -Name "Groups" -Path "OU=HQ,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Security and Distribution Groups"

# Create functional OUs under Branch
New-ADOrganizationalUnit -Name "Computers" -Path "OU=Branch,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Branch Computer Accounts"

New-ADOrganizationalUnit -Name "Workstations" -Path "OU=Computers,OU=Branch,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Client Workstations"

New-ADOrganizationalUnit -Name "Users" -Path "OU=Branch,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Branch User Accounts"

New-ADOrganizationalUnit -Name "Groups" -Path "OU=Branch,DC=reginleif,DC=io" `
    -ProtectedFromAccidentalDeletion $true -Description "Security and Distribution Groups"

# Verify OU structure
Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName | Sort-Object DistinguishedName
```

**Expected output:**

```
Name              DistinguishedName
----              -----------------
Branch            OU=Branch,DC=reginleif,DC=io
Computers         OU=Computers,OU=Branch,DC=reginleif,DC=io
Groups            OU=Groups,OU=Branch,DC=reginleif,DC=io
Users             OU=Users,OU=Branch,DC=reginleif,DC=io
Workstations      OU=Workstations,OU=Computers,OU=Branch,DC=reginleif,DC=io
HQ                OU=HQ,DC=reginleif,DC=io
Computers         OU=Computers,OU=HQ,DC=reginleif,DC=io
Groups            OU=Groups,OU=HQ,DC=reginleif,DC=io
Service Accounts  OU=Service Accounts,OU=HQ,DC=reginleif,DC=io
Users             OU=Users,OU=HQ,DC=reginleif,DC=io
Servers           OU=Servers,OU=Computers,OU=HQ,DC=reginleif,DC=io
Workstations      OU=Workstations,OU=Computers,OU=HQ,DC=reginleif,DC=io
```

### OU Structure Diagram

```text
DC=reginleif,DC=io
├── OU=HQ
│   ├── OU=Computers
│   │   ├── OU=Workstations    (Win10/11 clients)
│   │   └── OU=Servers         (Member servers)
│   ├── OU=Users               (Regular user accounts)
│   ├── OU=Service Accounts    (Application/service accounts)
│   └── OU=Groups              (Security/distribution groups)
└── OU=Branch
    ├── OU=Computers
    │   └── OU=Workstations    (Win10/11 clients)
    ├── OU=Users               (Regular user accounts)
    └── OU=Groups              (Security/distribution groups)
```

> [!NOTE]
> **Why no Service Accounts OU at Branch?** Service accounts are typically created at HQ and used across all sites via replication. If the Branch site requires site-specific service accounts, create `OU=Service Accounts,OU=Branch` as needed.

> [!TIP]
> **ProtectedFromAccidentalDeletion:** The `-ProtectedFromAccidentalDeletion $true` flag prevents administrators from accidentally deleting OUs that contain objects. This is a production best practice and is enabled by default in the Active Directory Administrative Center GUI.
