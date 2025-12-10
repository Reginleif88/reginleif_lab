---
title: "Project 4: Deploy Royal Server Gateway"
tags: [royal-ts, deployment, windows-server, active-directory]
sites: [hq]
status: completed
---

## Goal

Deploy Royal Server on a domain-joined Windows Server 2022 (`P-WIN-SRV1`) to act as a secure gateway for RDP/SSH connections and a central management point for the homelab.

---

> [!NOTE]
> **Optional Project:** This project is useful for practicing enterprise remote access patterns such as bastion hosts, gateway-based access, and centralized credential management.

## 1. VM Hardware Configuration

*Settings configured in Proxmox:*

| Setting | Value | Notes |
| :--- | :--- | :--- |
| **OS Type** | Microsoft Windows 2022 (Desktop Experience) | |
| **Machine** | q35 | Native PCIe |
| **BIOS** | OVMF (UEFI) | |
| **CPU** | Type Host, 2 Cores | Enables AES-NI (Critical for encryption performance) |
| **RAM** | 4096 MB (4 GB) | Desktop Experience usually requires more than Core even if not DC|
| **Controller** | VirtIO SCSI Single | IO Thread enabled |
| **Network** | VirtIO (Paravirtualized) | Required for 10Gbps inter-VM speeds (LAN interface of OPNsense) |

---

## 2. Prerequisites

> [!NOTE]
> With the VirtIO ISO already mounted, run `virtio-win-gt-x64.msi` to install all drivers + networking, then run `virtio-win-guest-tools.exe` to install the QEMU Guest Agent and reboot. Enable the agent in Proxmox under **VM Options > QEMU Guest Agent** if needed.

* **Hostname:** `P-WIN-SRV1`
* **IP Address:** `172.16.0.11` (Static)
* **DNS Server:** `172.16.0.10` (`P-WIN-DC1`)
* **Default Gateway:** `172.16.0.1`
* **Domain Join:** Ensure server is joined to `reginleif.io`.
* **Features:** Install **RSAT** (Remote Server Administration Tools) on this server to easily manage AD users/groups without switching to the DC.
* **Windows Update:** Once domain-joined, the GPO from Project 3 disables automatic updates. If configuring before domain join, disable locally:

```powershell
# [P-WIN-SRV1]
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv
```

---

## 3. What is Royal Server?

**Royal Server** acts as a secure middleman between the Royal TS client and your infrastructure.

1. **Secure Gateway:** It tunnels RDP, VNC, and SSH traffic. This allows you to access internal resources without exposing them directly to the internet or opening multiple firewall ports.
2. **Management Endpoint:** It executes remote management tasks (checking Windows Services, Event Logs, Hyper-V status) locally on the server and sends the results back to your client, which is faster and more secure than direct WMI/PowerShell connections.

---

## 4. Active Directory Setup

*Perform via RSAT on `P-WIN-SRV1` or directly on the Domain Controller.*

### 1. Create Service Account

Create a dedicated service account in AD:

* **Name:** `svc_RoyalServer`
* **Password:** Set a strong password.
* **Settings:** Password never expires (enabled).

### 2. Create Security Groups

Create three **Global Security Groups** to manage access:

* `RoyalServer-Admins` (IT Ops: Full control over Royal Server configuration)
* `RoyalServer-Users` (Staff: Can read logs/status via Royal TS)
* `RoyalServer-GatewayUsers` (Users: Can tunnel SSH/RDP via this server)

### 3. Assign Memberships

* Add your **Domain Admin** (or personal admin account) to `RoyalServer-Admins`.
* Add relevant users to `RoyalServer-GatewayUsers`.

---

## 5. Server Preparation

### 1. Grant Local Admin Rights

The service account requires local administrative privileges to function correctly.

1. Run `compmgmt.msc`.
2. Navigate to **Local Users and Groups** > **Groups**.
3. Open **Administrators**.
4. Add `REGINLEIF\svc_RoyalServer`.

### 2. Install Royal Server

1. Download and run the Royal Server `.msi` installer.
2. Follow the wizard (accept defaults for now).
3. **Finish** the installation and launch the **Royal Server Configuration Tool**.

---

## 6. Service Configuration

### 1. Configure the Worker Account (Critical)

By default, the service runs as `Local System` and cannot read AD groups.

1. Open **Royal Server Configuration Tool**.
2. Go to **Service Configuration** > **Worker Account**.
3. Change the account to: `REGINLEIF\svc_RoyalServer`.
4. Enter the password and click **Test Credentials**.
5. **Save**.

### 2. Map Security Groups

Bridge the Active Directory groups to the Server's Local Groups.

1. Open `compmgmt.msc` > **Local Users and Groups** > **Groups**.
2. Locate the groups created by the installer and nest your AD groups inside them:

| Local Group (Server) | Action | Member to Add (AD Group) |
| :--- | :--- | :--- |
| **Royal Server Administrators** | Add -> | `REGINLEIF\RoyalServer-Admins` |
| **Royal Server Users** | Add -> | `REGINLEIF\RoyalServer-Users` |
| **Royal Server Gateway Users** | Add -> | `REGINLEIF\RoyalServer-GatewayUsers` |

### 3. Restart Service

1. Return to the Royal Server Configuration Tool.
2. Click **Restart Royal Server** to apply the Worker Account and Group changes.

---

## 7. Firewall Verification

The installer usually handles this, but verify the rules exist.

1. Open **Windows Defender Firewall with Advanced Security**.
2. Check **Inbound Rules** for:
    * `Royal Server (Management Endpoint)` - TCP `54899`
    * `Royal Server (Secure Gateway)` - TCP `22`

---

## 8. Royal TS Client Configuration

> [!NOTE]
> Full validation requires Road Warrior VPN access. Complete **Project 9 - Remote Access VPN** first, then return here.

### 1. Create Management Object

*Used for viewing server health, logs, and services.*

* **Type:** Royal Server

### 2. Validation

1. Right-click the **Management Object** > **Test**. (Should be Green).
2. Create a generic RDP connection, set **Secure Gateway** to the object created in step 1, and attempt connection.
