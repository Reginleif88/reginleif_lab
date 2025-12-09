---
title: "Project 3: Active Directory Bootstrap"
tags: [active-directory, powershell, setup, windows]
sites: [hq]
status: completed
---

## Goal

Promote the first Domain Controller from project 2 (P-WIN-DC1) using PowerShell.

---

## 1. Prerequisites

**VM Requirements:** Ensure P-WIN-DC1 was provisioned with at least 80 GB disk space per Project 2 specifications (AD database, SYSVOL, and logs require adequate storage).

### Enable Remote Desktop (sconfig)

From the console, use sconfig to enable RDP for easier management:

1. In sconfig, select **7** (Remote Desktop)
2. Select **E** to Enable
3. Select **1** for more secure (Network Level Authentication required)

### Configure Hostname and Network

In powershell or sconfig

```powershell
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

> **Note:** Interface name may vary. Run `Get-NetAdapter` to confirm.

---

## 2. Installation Script

Cab be executed via RDP to allow copy-paste.

```powershell
# Install AD Bits
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

# Promote to Forest Root
Install-ADDSForest `
    -DomainName "reginleif.io" `
    -DomainNetbiosName "REGINLEIF" `
    -InstallDns:$true `
    -Force
```

> **Note:** The command will prompt for the Directory Services Restore Mode (DSRM) password.

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

## 4. Disable Windows Update via GPO

Create a Group Policy to disable automatic updates for all domain-joined machines until centralized update management (WSUS) is configured.

```powershell
# Create new GPO
New-GPO -Name "Disable Windows Update" -Comment "Temporary: Disable updates until WSUS is configured"

# Configure the GPO to disable automatic updates
Set-GPRegistryValue -Name "Disable Windows Update" `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" `
    -ValueName "NoAutoUpdate" `
    -Type DWord `
    -Value 1

# Link GPO to domain root (applies to all domain-joined machines)
Get-GPO -Name "Disable Windows Update" | New-GPLink -Target "DC=reginleif,DC=io"
```

> **Why disable via GPO?** Centralized management ensures all domain-joined servers (P-WIN-SRV1, future servers) automatically inherit the policy. Remove or unlink this GPO once WSUS or another update solution is deployed.
