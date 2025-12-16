---
title: "Project 6: Prepare DC2 on HyperV for Site-to-Site"
tags: [active-directory, configuration, windows-server, hyper-v]
sites: [branch]
status: completed
---

## Goal

Deploy and prepare the Windows Server 2022 Core VM H-WIN-DC2 on Hyper-V as the secondary Domain Controller for the branch office. This DC2 will later participate in site-to-site VPN routing and Directory Services replication.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-06-concepts)**

For educational context about Domain Controller requirements, static memory allocation, and AD replication preparation, see the dedicated concepts guide.

---

> [!NOTE]
> **Pre-VLAN Addressing:** This project uses flat network addressing (`172.17.0.0/24`). After VLAN segmentation in Project 11, H-WIN-DC2 moves to `172.17.5.10` on the Infrastructure VLAN, and the gateway changes from `172.17.0.1` to `172.17.5.1`.

## 1. VM Hardware Configuration

Configure the Hyper-V VM for the Branch domain controller.

* **Generation:** Generation 2 (UEFI)
* **Secure Boot:** Enabled (Windows Server supports Secure Boot on Hyper-V)
* **Processor:** 4 Virtual Processors
* **Memory:** 4096 MB (4 GB) - **Static Memory Required** (do not use Dynamic Memory for Domain Controllers)
* **Network Adapter 1:** "Branch-LAN" (Internal/Private vSwitch) --> OPNsense LAN
* **Disk:** 80 GB VHDX (or appropriate size)

> [!WARNING]
> **Why Static Memory for Domain Controllers?**
>
> Domain Controllers maintain an active directory database (NTDS.dit) that requires consistent memory allocation. Dynamic memory can cause serious issues:
>
> - **Database Corruption:** Memory ballooning events (when Hyper-V reclaims memory) can corrupt the NTDS.dit database during write operations
> - **AD Replication Failures:** Insufficient memory during replication cycles causes replication errors and inconsistent directory data across DCs
> - **Authentication Delays:** When memory is reclaimed, the DC may not have sufficient resources to handle authentication requests, causing login failures
> - **Kerberos Time Skew:** Memory pressure can cause time sync issues, leading to Kerberos authentication failures
>
> **Microsoft explicitly recommends against using Dynamic Memory for production Domain Controllers.** While Hyper-V dynamic memory is generally safe for application servers and workstations, it should **never be used** for DCs. Always allocate static memory for Domain Controllers in both production and lab environments to ensure AD stability.

---

## 2. Post-Installation

Since there is no GUI, ensure necessary drivers are loaded. Hyper-V Integration Services typically handle this automatically for Windows VMs.

### Enable Remote Desktop (sconfig)

From sconfig, enable RDP for easier management:

1. Select **7** (Remote Desktop)
2. Select **E** to Enable
3. Select **1** for more secure (Network Level Authentication required)

### Disable Windows Update

```powershell
# [H-WIN-DC2]
# Exit sconfig to PowerShell
exit #(option 15)

# Disable Windows Update (until centralized update management is configured)
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv
```

> **Why disable Windows Update?** Prevents unexpected reboots and bandwidth consumption during initial lab setup. Re-enable once centralized update management (WSUS, etc.) is configured.

---

## 3. Network Configuration

Configure the VM's hostname and network settings for the Branch office domain.

### Set Hostname

```powershell
# [H-WIN-DC2]
# Rename the computer and restart
Rename-Computer -NewName "H-WIN-DC2" -Restart
```

### Configure Static IP

After the restart, set a static IP address for the Branch LAN network.

> [!NOTE]
> Interface name may vary. Run `Get-NetAdapter` to confirm.

```powershell
# [H-WIN-DC2]
# Configure static IP address for Branch network
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress 172.17.0.10 -PrefixLength 24 -DefaultGateway 172.17.0.1
```

### Configure DNS (Temporary)

> [!NOTE]
> This DNS configuration is temporary. Initially, we point to the OPNsense gateway (`172.17.0.1`) which can provide basic name resolution. Once the site-to-site VPN is established (Project 7), this will be updated to point to the HQ Domain Controller (`172.16.0.10`) for proper Active Directory integration.

```powershell
# [H-WIN-DC2]
# Set DNS to OPNsense gateway (temporary configuration)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "172.17.0.1"
```

---

## 4. Pre-Promotion Requirements

Before this server can be promoted to a Domain Controller, understand the following critical prerequisites:

* **Cannot Promote Without Contacting Primary DC**: A domain controller cannot be promoted without contacting the existing Domain Controller at HQ (`172.16.0.10`). This requires site-to-site connectivity.
* **SYSVOL Replication**: The new DC must replicate the SYSVOL share from the primary DC.
* **NTDS Replication**: Active Directory database (NTDS) replication must occur between DCs.
* **Credential Validation**: The promotion process validates credentials against the HQ DC.
* **DNS Zone Synchronization**: DNS zones must synchronize between the two sites.

---

## 5. Validation

Verify the network configuration is correct before proceeding.

* **Ping Gateway:** From H-WIN-DC2, ping the gateway:

    ```powershell
    Test-Connection -ComputerName 172.17.0.1 -Count 4
    ```

* **Internet Connectivity:** Verify the VM can reach the internet:

    ```powershell
    Test-Connection -ComputerName 8.8.8.8 -Count 4
    ```

* **Verify Network Configuration:** Check the network adapter settings:

    ```powershell
    Get-NetIPAddress -InterfaceAlias "Ethernet"
    Get-DnsClientServerAddress -InterfaceAlias "Ethernet"
    ```

**Action Required:** Complete Project 7 (Site-to-Site VPN) before attempting to promote this server to a Domain Controller in Project 8.
