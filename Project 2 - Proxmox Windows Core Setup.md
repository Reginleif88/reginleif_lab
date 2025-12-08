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
*   **OS Type:** Microsoft Windows 11/2022
*   **Machine:** q35 (Native PCIe)
*   **BIOS:** OVMF (UEFI)
*   **Controller:** VirtIO SCSI Single + [x] IO Thread
*   **Network:** VirtIO (Paravirtualized) (Crucial for 10Gbps speed)
*   **CPU:** Type Host (Pass-through AES-NI)

**Downloads:** VirtIO Drivers: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/

---

## 2. The "Hidden Drive" Installation Trick
Running the installer requires loading drivers manually since Windows doesn't see VirtIO disks by default.

1.  Mount `virtio-win.iso` as CD-ROM 2.
2.  At disk selection screen, click **Load Driver**.
    *   **Storage Driver Path:** `E:\vioscsi\2k22\amd64`
    *   **Network Driver Path:** `E:\NetKVM\2k22\amd64` (Do this now to save time later).

---

## 3. Post-Installation (The "Black Box" Fixes)
Since there is no GUI, use these commands to finish the driver setup.

```powershell
# 1. Exit sconfig to PowerShell
exit #(option 15)
powershell

# 2. Install QEMU Agent & Balloon Service (Silent Install)
# Assuming E: is the VirtIO ISO
msiexec /i E:\virtio-win-gt-x64.msi /qn

# 3. Verify Network Driver is loaded
Get-NetAdapter
```
