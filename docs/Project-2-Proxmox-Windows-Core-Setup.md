---
title: "Project 2: Proxmox Windows Core Setup"
tags: [proxmox, windows-server, virtio]
sites: [hq]
status: completed
---

## Goal

Create a repeatable process for deploying high-performance Windows Server Core VMs on Proxmox.

---

## 1. VM Hardware Configuration

* **OS Type:** Microsoft Windows 11/2022
* **Machine:** q35 (Native PCIe)
* **BIOS:** OVMF (UEFI)
* **CPU:** Type Host (Pass-through AES-NI) | 4 Cores
* **RAM:** 4096 MB (4 GB)
* **Controller:** VirtIO SCSI Single + [x] IO Thread
* **Disk:** 80 GB (Recommended for Domain Controllers - AD database, SYSVOL, and logs)
* **Network:** VirtIO (Paravirtualized) (LAN interface of OPNsense) (Crucial for 10Gbps speed)

**Downloads:** VirtIO Drivers: <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/>

---

## 2. The "Hidden Drive" Installation Trick

Running the installer requires loading drivers manually since Windows doesn't see VirtIO disks by default.

1. Mount `virtio-win.iso` as CD-ROM 2.
2. At disk selection screen, click **Load Driver**.
    * **Storage Driver Path:** `E:\vioscsi\2k22\amd64`
    * **Network Driver Path:** `E:\NetKVM\2k22\amd64` (Do this now to save time later).

---

## 3. Post-Installation

Since there is no GUI, use these commands to finish the driver setup.

```powershell
# 1. Exit sconfig to PowerShell
exit #(option 15)

# 2. Find the VirtIO ISO drive letter
Get-Volume

# 3. Install VirtIO drivers + QEMU Guest Agent (adjust drive letter if needed)
msiexec /i D:\virtio-win-gt-x64.msi

# 4. Verify Network Driver is loaded
Get-NetAdapter

# 5. Disable Windows Update (until centralized update management is configured)
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv
```

> **Why disable Windows Update?** Prevents unexpected reboots and bandwidth consumption during initial lab setup. Re-enable once centralized update management (WSUS, etc.) is configured.
