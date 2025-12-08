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

**Note:** Interface name may vary. Run `Get-NetAdapter` to confirm.

---

## 2. Installation Script

Executed via RDP to allow copy-paste.

```powershell
# Install AD Bits
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

# Promote to Forest Root
Install-ADDSForest -DomainName "reginleif.io" -DomainNetbiosName "REGINLEIF" -InstallDns:$true -SafeModeAdministratorPassword (ConvertTo-SecureString "<YourSafeModePassword>" -AsPlainText -Force) -Force
```

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
