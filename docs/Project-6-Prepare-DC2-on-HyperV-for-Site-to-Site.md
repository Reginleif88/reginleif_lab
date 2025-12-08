---
title: "Project 6: Prepare DC2 on HyperV for Site-to-Site"
tags: [active-directory, hyper-v, windows-server, site-to-site]
sites: [branch]
status: completed
---

## Goal

Deploy and prepare the Windows Server 2022 Core VM H-WIN-DC2 on Hyper-V as the secondary Domain Controller for the branch office. This DC2 will later participate in site-to-site VPN routing and Directory Services replication.

---

## 1. VM Hardware Configuration

* **Generation:** Generation 2 (UEFI)
* **Secure Boot:** Enabled (Windows Server supports Secure Boot on Hyper-V)
* **Processor:** 2 Virtual Processors
* **Memory:** 4096 MB (4 GB) - Dynamic Memory Recommended for efficiency.
* **Network Adapter 1:** "Branch-LAN" (Internal/Private vSwitch) --> OPNsense LAN
* **Disk:** 60 GB VHDX (or appropriate size)

---

## 2. Post-Installation (Driver Setup)

Since there is no GUI, ensure necessary drivers are loaded. Hyper-V Integration Services typically handle this automatically for Windows VMs.

```powershell
# Exit sconfig to PowerShell
exit #(option 15)
powershell
```

### Hyper-V Integration Services

On our HyperV Host :

```powershell
# Check Integration Services status (optional, usually managed by Hyper-V)
Get-VMIntegrationService -VMName "H-WIN-DC2"
```

### Verify Network Driver is loaded

```powershell
Get-NetAdapter
```

---

## 3. Network Configuration

Configure the VM's hostname and network settings for the Branch office domain.

### Set Hostname

```powershell
# Rename the computer and restart
Rename-Computer -NewName "H-WIN-DC2" -Restart
```

### Configure Static IP

After the restart, set a static IP address for the Branch LAN network.

**Note:** Interface name may vary. Run `Get-NetAdapter` to confirm.

```powershell
# Configure static IP address for Branch network
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress 172.17.0.10 -PrefixLength 24 -DefaultGateway 172.17.0.1
```

### Configure DNS (Temporary)

**Note:** This DNS configuration is temporary. Initially, we point to the OPNsense gateway (`172.17.0.1`) which can provide basic name resolution. Once the site-to-site VPN is established (Project 7), this will be updated to point to the HQ Domain Controller (`172.16.0.10`) for proper Active Directory integration.

```powershell
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

**Action Required:** Complete Project 7 (Site-to-Site VPN) before attempting to promote this server to a Domain Controller.
