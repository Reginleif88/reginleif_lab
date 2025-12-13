---
title: "Project 15: Windows Deployment Services + MDT"
tags: [wds, mdt, deployment, pxe, imaging, windows-adk, lite-touch]
sites: [hq]
status: planned
---

## Goal

Implement a **lite-touch deployment (LTD)** solution using Windows Deployment Services (WDS) and Microsoft Deployment Toolkit (MDT) to standardize OS installations across the environment:

- **WDS**: Provides PXE boot infrastructure for network-based OS deployment
- **MDT**: Orchestrates deployment task sequences, driver injection, and application installation
- **Windows ADK**: Provides tools for customizing Windows images and creating boot media

This enables consistent, repeatable deployments of Windows 10, Windows 11, and Windows Server 2022 with minimal manual intervention.

---

## Firewall Requirements

> [!NOTE]
> If you implemented the permissive `Trusted_Lab_Networks` firewall rule in Project 11, WDS/PXE traffic is already permitted between VLANs. The rules below document what is required for production environments with restrictive firewalls.

**Required firewall rules for WDS/MDT services:**

| Protocol | Port(s) | Source | Destination | Purpose |
|:---------|:--------|:-------|:------------|:--------|
| UDP | 67, 68 | Clients VLAN | 172.16.20.14 | DHCP/PXE discovery |
| UDP | 69 | Clients VLAN | 172.16.20.14 | TFTP (boot image transfer) |
| UDP | 4011 | Clients VLAN | 172.16.20.14 | PXE (alternate port) |
| TCP | 445 | Clients VLAN | 172.16.20.14 | SMB (deployment share access) |
| TCP | 9800-9801 | Admin Workstation | 172.16.20.14 | MDT Monitoring (optional) |

> [!TIP]
> For cross-VLAN PXE boot (deploying to VLAN 10 from WDS on VLAN 20), configure DHCP Options 66/67 or IP Helper on OPNsense. See Section 10 for detailed configuration.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-15-concepts)**

For educational context about deployment methods comparison (Manual/WDS/WDS+MDT/SCCM), PXE boot architecture, and why WDS + MDT provides the best balance for lite-touch deployment, see the dedicated concepts guide.

---

## VM Configuration

This project adds WDS + MDT roles to P-WIN-SRV4, which was created in Project 14 (RADIUS/NPS). WDS and NPS coexist without conflicts.

### VM Hardware (Proxmox)

| Setting | Value | Notes |
|:--------|:------|:------|
| **OS Type** | Microsoft Windows 2022 (Desktop Experience) | GUI recommended for MDT console |
| **Machine** | q35 | Native PCIe |
| **BIOS** | OVMF (UEFI) | |
| **CPU** | Type Host, 2 Cores | Minimal requirements |
| **RAM** | 8192 MB (8 GB) | Increased for concurrent deployments |
| **Controller** | VirtIO SCSI Single | IO Thread enabled |
| **Disk** | 120 GB (VirtIO SCSI) | Increased for OS images storage |
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

> [!NOTE]
> Follow Project 2 for Windows Server 2022 installation and VirtIO drivers. If P-WIN-SRV4 was already created in Project 14, you may need to expand the disk and add RAM to meet WDS requirements.

---

## 1. Install Windows ADK

The Windows Assessment and Deployment Kit (ADK) provides tools needed by MDT to create and customize deployment images.

### Download ADK

Download the Windows ADK for Windows 11, version 22H2 (or latest):

1. Download **Windows ADK**: [Microsoft Download](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
2. Download **Windows PE add-on for ADK**: Same page, separate download

> [!IMPORTANT]
> You need both the ADK and the WinPE add-on. The WinPE add-on is required to create boot images.

### Install ADK

```powershell
# Run adksetup.exe with these features selected:
# - Deployment Tools
# - User State Migration Tool (USMT)
# - Windows Preinstallation Environment (if available in main installer)

# Or silent install:
.\adksetup.exe /quiet /features OptionId.DeploymentTools OptionId.UserStateMigrationTool
```

### Install WinPE Add-on

```powershell
# Run adkwinpesetup.exe
# Select: Windows Preinstallation Environment

# Or silent install:
.\adkwinpesetup.exe /quiet /features OptionId.WindowsPreinstallationEnvironment
```

Verify installation:

```powershell
# Check ADK installation
Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots" |
    Select-Object KitsRoot10

# Should return something like: C:\Program Files (x86)\Windows Kits\10\
```

---

## 2. Install MDT

Microsoft Deployment Toolkit orchestrates the entire deployment process.

### Download MDT

Download MDT from: [Microsoft Download Center](https://www.microsoft.com/en-us/download/details.aspx?id=54259)

> [!NOTE]
> MDT 8456 is the current version. While it hasn't been updated recently, it's still fully supported and works with Windows 11 and Server 2022.

### Install MDT

```powershell
# Run MicrosoftDeploymentToolkit_x64.msi
# Accept defaults, install to C:\Program Files\Microsoft Deployment Toolkit

# Or silent install:
msiexec /i MicrosoftDeploymentToolkit_x64.msi /quiet
```

After installation, you'll have:

- **Deployment Workbench**: GUI console for managing deployments (`C:\Program Files\Microsoft Deployment Toolkit\Bin\DeploymentWorkbench.msc`)
- **PowerShell module**: `MicrosoftDeploymentToolkit` for automation

---

## 3. Install WDS Role

Windows Deployment Services provides the PXE boot infrastructure.

### Add WDS Role

```powershell
# Install WDS role with both sub-features
Install-WindowsFeature -Name WDS -IncludeManagementTools -IncludeAllSubFeature

# Verify installation
Get-WindowsFeature WDS*
```

### Configure WDS

Open **Windows Deployment Services** console (`wdsmgmt.msc`) or use PowerShell:

```powershell
# Initialize WDS
# -RemInst: Path to store boot images and install images
# -Authorize: Authorize in AD (required for DHCP to forward PXE requests)

wdsutil /Initialize-Server /RemInst:"D:\RemoteInstall" /Authorize

# Configure to respond to all clients (or known clients only for security)
wdsutil /Set-Server /AnswerClients:All

# Alternative: Only respond to known/prestaged clients
# wdsutil /Set-Server /AnswerClients:Known
```

> [!TIP]
> For a lab environment, "Respond to all client computers" is convenient. In production, consider prestaging computer accounts or requiring admin approval.

### WDS and DHCP on Different Servers

Since DHCP runs on the domain controllers (P-WIN-DC1/DC2) and WDS runs on P-WIN-SRV4, you need to configure DHCP options or IP Helper:

**Option A: DHCP Options (Recommended)**

On the DHCP server, configure scope options:

```powershell
# On P-WIN-DC1 (DHCP Server)
# Option 66: Boot Server Host Name
# Option 67: Boot File Name

# For VLAN 10 (Clients) scope:
Set-DhcpServerv4OptionValue -ScopeId 172.16.10.0 -OptionId 66 -Value "172.16.20.14"  # SRV4 IP
Set-DhcpServerv4OptionValue -ScopeId 172.16.10.0 -OptionId 67 -Value "boot\x64\wdsnbp.com"
```

**Option B: IP Helper on Router**

On OPNsense, configure DHCP relay/IP Helper to forward PXE requests:

1. **Services > DHCPv4 > Relay**
2. Enable relay on VLAN 10 interface
3. Add P-WIN-SRV4 (172.16.20.14) as destination

> [!NOTE]
> Option 66/67 is cleaner and doesn't require firewall changes. IP Helper is useful when you have multiple boot servers or complex routing.

---

## 4. Create Deployment Share

The deployment share is the central repository for OS images, drivers, applications, and task sequences.

### Create Share Using Deployment Workbench

1. Open **Deployment Workbench** (Start > Microsoft Deployment Toolkit > Deployment Workbench)
2. Right-click **Deployment Shares** > **New Deployment Share**
3. Configure:
   - **Path**: `D:\DeploymentShare`
   - **Share name**: `DeploymentShare$` ($ makes it hidden)
   - **Description**: `MDT Production Deployment Share`
4. Accept defaults for remaining options
5. Click **Finish**

### Create Share Using PowerShell

```powershell
# Import MDT module
Import-Module "C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1"

# Create the deployment share folder
New-Item -Path "D:\DeploymentShare" -ItemType Directory

# Create the MDT deployment share
New-PSDrive -Name "DS001" -PSProvider MDTProvider -Root "D:\DeploymentShare" -Description "MDT Production" |
    Add-MDTPersistentDrive

# Create the network share
New-SmbShare -Name "DeploymentShare$" -Path "D:\DeploymentShare" -FullAccess "Administrators" -ReadAccess "Everyone"
```

### Deployment Share Structure

After creation, the share has this structure:

```text
D:\DeploymentShare\
├── Applications\          # Software packages to deploy
├── Boot\                  # Boot images (LiteTouchPE_x64.wim)
├── Captures\              # Captured reference images
├── Control\               # Configuration files (CustomSettings.ini, Bootstrap.ini)
├── Logs\                  # Deployment logs
├── Operating Systems\     # Source OS images (WIM files)
├── Out-of-Box Drivers\    # Driver repository
├── Packages\              # Windows updates, language packs
├── Scripts\               # MDT scripts (don't modify)
├── Templates\             # Unattend.xml templates
└── Tools\                 # Deployment tools (USMT, etc.)
```

---

## 5. Import Operating Systems

Import the Windows images you want to deploy.

### Source Media

You'll need installation media (ISO files) for:

- Windows 10 Enterprise (22H2 or later)
- Windows 11 Enterprise (23H2 or later)
- Windows Server 2022

Mount the ISO or extract to a folder.

### Import Windows 10

1. In Deployment Workbench, expand your deployment share
2. Right-click **Operating Systems** > **Import Operating System**
3. Select **Full set of source files**
4. Browse to mounted ISO (e.g., `E:\` or extracted folder)
5. **Destination directory name**: `Windows 10 Enterprise x64`
6. Complete the wizard

### Import Windows 11

Same process:

1. Right-click **Operating Systems** > **Import Operating System**
2. **Full set of source files** > Browse to Windows 11 media
3. **Destination**: `Windows 11 Enterprise x64`

### Import Windows Server 2022

1. Right-click **Operating Systems** > **Import Operating System**
2. **Full set of source files** > Browse to Server 2022 media
3. **Destination**: `Windows Server 2022`

> [!NOTE]
> Windows Server media includes multiple editions (Standard, Datacenter, with/without Desktop Experience). All will be imported; you'll select the specific edition when creating task sequences.

### PowerShell Import

```powershell
# Import Windows 10
Import-MDTOperatingSystem -Path "DS001:\Operating Systems" `
    -SourcePath "E:\" `
    -DestinationFolder "Windows 10 Enterprise x64"

# Import Windows 11
Import-MDTOperatingSystem -Path "DS001:\Operating Systems" `
    -SourcePath "F:\" `
    -DestinationFolder "Windows 11 Enterprise x64"

# Import Server 2022
Import-MDTOperatingSystem -Path "DS001:\Operating Systems" `
    -SourcePath "G:\" `
    -DestinationFolder "Windows Server 2022"
```

---

## 6. Import Drivers

Proper driver management is crucial for successful deployments, especially with diverse hardware.

### Driver Organization Strategy

Organize drivers by manufacturer and model:

```text
Out-of-Box Drivers\
├── Windows 10 x64\
│   ├── Dell\
│   │   ├── OptiPlex 7090\
│   │   └── Latitude 5520\
│   └── HP\
│       └── ProDesk 400 G7\
├── Windows 11 x64\
│   ├── Dell\
│   │   └── OptiPlex 7090\
│   └── HP\
│       └── ProDesk 400 G7\
└── Windows Server 2022\
    └── VirtIO\
        ├── Network\
        ├── Storage\
        └── Balloon\
```

### Import VirtIO Drivers (For Proxmox VMs)

Since your HQ runs on Proxmox, you'll need VirtIO drivers for Windows VMs:

1. Download VirtIO drivers: [Fedora VirtIO Drivers](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/)
2. Extract the ISO
3. Import drivers:

```powershell
# Create driver folder structure
New-Item -Path "DS001:\Out-of-Box Drivers\Windows Server 2022\VirtIO" -ItemType Directory

# Import VirtIO drivers
Import-MDTDriver -Path "DS001:\Out-of-Box Drivers\Windows Server 2022\VirtIO" `
    -SourcePath "C:\Drivers\virtio-win\amd64\w2k22" `
    -Recurse
```

### Import Hyper-V Integration Drivers

For branch site VMs on Hyper-V, integration components are usually included in Windows, but you can import them explicitly:

```powershell
# Hyper-V integration drivers are built into Windows 10/11/Server 2022
# No import needed unless using older OS versions
```

### Create Driver Selection Profiles

Create selection profiles to target specific drivers to specific task sequences:

1. Right-click **Selection Profiles** > **New Selection Profile**
2. Name: `Windows Server 2022 Drivers`
3. Select only `Out-of-Box Drivers\Windows Server 2022`
4. Repeat for Windows 10 and Windows 11

---

## 7. Create Task Sequences

Task sequences define the deployment workflow: install OS, inject drivers, install apps, configure settings.

### Standard Workstation Task Sequence (Windows 10)

1. Right-click **Task Sequences** > **New Task Sequence**
2. Configure:
   - **ID**: `W10-STD`
   - **Name**: `Windows 10 Enterprise - Standard Workstation`
   - **Template**: `Standard Client Task Sequence`
   - **OS**: Select `Windows 10 Enterprise x64` image
   - **Product Key**: Leave blank (KMS/ADBA will activate)
   - **Admin Password**: Set local admin password or leave blank to prompt
3. Complete wizard

### Windows 11 Task Sequence

1. **ID**: `W11-STD`
2. **Name**: `Windows 11 Enterprise - Standard Workstation`
3. **Template**: `Standard Client Task Sequence`
4. **OS**: `Windows 11 Enterprise x64`

> [!NOTE]
> Windows 11 has hardware requirements (TPM 2.0, Secure Boot). For VMs, ensure these features are enabled or use registry bypasses in the task sequence.

### Windows Server 2022 Task Sequence

1. **ID**: `SRV2022-STD`
2. **Name**: `Windows Server 2022 Standard - GUI`
3. **Template**: `Standard Server Task Sequence`
4. **OS**: `Windows Server 2022 SERVERSTANDARD` (Desktop Experience)

### Server Core Task Sequence

1. **ID**: `SRV2022-CORE`
2. **Name**: `Windows Server 2022 Standard - Core`
3. **Template**: `Standard Server Task Sequence`
4. **OS**: `Windows Server 2022 SERVERSTANDARDCORE`

### Customize Task Sequences

Edit task sequences to add driver injection and domain join:

1. Right-click task sequence > **Properties** > **Task Sequence** tab

**Add Driver Injection:**

1. Find **Inject Drivers** step (under Preinstall)
2. Set **Selection profile**: Choose appropriate profile (e.g., `Windows 10 Drivers`)

**Configure Domain Join:**

1. Find **Recover From Domain** step (under State Restore)
2. The domain join is configured via CustomSettings.ini (see below)

---

## 8. Configure CustomSettings.ini

The `CustomSettings.ini` file controls deployment behavior and automation.

### Edit CustomSettings.ini

Located at: `D:\DeploymentShare\Control\CustomSettings.ini`

```ini
[Settings]
Priority=Default
Properties=MyCustomProperty

[Default]
; Deployment share path
DeployRoot=\\P-WIN-SRV4\DeploymentShare$

; Skip wizard pages for lite-touch automation
SkipBDDWelcome=YES
SkipTaskSequence=NO
SkipComputerName=NO
SkipDomainMembership=YES
SkipUserData=YES
SkipComputerBackup=YES
SkipProductKey=YES
SkipLocaleSelection=YES
SkipTimeZone=YES
SkipApplications=NO
SkipBitLocker=YES
SkipSummary=NO
SkipFinalSummary=NO
SkipCapture=YES

; Domain join settings
JoinDomain=reginleif.io
DomainAdmin=REGINLEIF\svc_mdt_domainjoin
DomainAdminPassword=<PASSWORD>
MachineObjectOU=OU=Workstations,OU=Computers,OU=HQ,DC=reginleif,DC=io

; Regional settings
TimeZoneName=Central Standard Time
UILanguage=en-US
UserLocale=en-US
KeyboardLocale=en-US

; Enable Windows Update during deployment (optional)
WSUSServer=http://wsus.reginleif.io:8530
WindowsUpdate=TRUE

; Logging
SLShare=\\P-WIN-SRV4\Logs$
SLShareDynamicLogging=\\P-WIN-SRV4\Logs$\%ComputerName%
```

> [!IMPORTANT]
> Create a dedicated service account (`svc_mdt_domainjoin`) with permissions to join computers to the specified OU. Don't use a privileged admin account.

### Create Domain Join Service Account

> [!NOTE]
> The `Service Accounts` OU was created in **Project 3, Section 6**. If you did not complete that step, create it now:
>
> ```powershell
> # [P-WIN-DC1]
> New-ADOrganizationalUnit -Name "Service Accounts" -Path "OU=HQ,DC=reginleif,DC=io" `
>     -ProtectedFromAccidentalDeletion $true -Description "Service and Application Accounts"
> ```

```powershell
# Create service account
New-ADUser -Name "svc_mdt_domainjoin" `
    -SamAccountName "svc_mdt_domainjoin" `
    -UserPrincipalName "svc_mdt_domainjoin@reginleif.io" `
    -Path "OU=Service Accounts,OU=HQ,DC=reginleif,DC=io" `
    -AccountPassword (ConvertTo-SecureString "SecurePassword123!" -AsPlainText -Force) `
    -Enabled $true `
    -PasswordNeverExpires $true

# Delegate "Join computers to domain" permission on target OU
# Use Active Directory Users and Computers > Delegate Control wizard
# Or use dsacls:
dsacls "OU=Workstations,OU=Computers,OU=HQ,DC=reginleif,DC=io" /G "REGINLEIF\svc_mdt_domainjoin:CA;Computer"
```

### Configure Bootstrap.ini

Located at: `D:\DeploymentShare\Control\Bootstrap.ini`

```ini
[Settings]
Priority=Default

[Default]
DeployRoot=\\P-WIN-SRV4\DeploymentShare$
SkipBDDWelcome=YES

; Credentials to access deployment share
UserDomain=REGINLEIF
UserID=svc_mdt_deploy
UserPassword=<PASSWORD>

; Keyboard layout for WinPE
KeyboardLocale=en-US
```

> [!NOTE]
> Bootstrap.ini credentials are embedded in the boot image. Use a dedicated read-only service account.

### Create Deployment Share Access Account

```powershell
# Create read-only deployment share access account
New-ADUser -Name "svc_mdt_deploy" `
    -SamAccountName "svc_mdt_deploy" `
    -UserPrincipalName "svc_mdt_deploy@reginleif.io" `
    -Path "OU=Service Accounts,OU=HQ,DC=reginleif,DC=io" `
    -AccountPassword (ConvertTo-SecureString "SecurePassword456!" -AsPlainText -Force) `
    -Enabled $true `
    -PasswordNeverExpires $true

# Grant read access to deployment share
Grant-SmbShareAccess -Name "DeploymentShare$" -AccountName "REGINLEIF\svc_mdt_deploy" -AccessRight Read -Force
```

---

## 9. Configure WDS Integration

Link the MDT boot image to WDS for PXE boot.

### Update Deployment Share

After configuring CustomSettings.ini and Bootstrap.ini, regenerate the boot image:

1. Right-click deployment share > **Update Deployment Share**
2. Select **Completely regenerate the boot images**
3. Wait for process to complete (creates `LiteTouchPE_x64.wim`)

### Add Boot Image to WDS

```powershell
# Import MDT boot image into WDS
Import-WdsBootImage -Path "D:\DeploymentShare\Boot\LiteTouchPE_x64.wim" `
    -NewImageName "MDT Lite Touch (x64)" `
    -NewDescription "MDT Production Boot Image"

# Verify
Get-WdsBootImage
```

Or via GUI:

1. Open **Windows Deployment Services** console
2. Expand server > **Boot Images**
3. Right-click > **Add Boot Image**
4. Browse to `D:\DeploymentShare\Boot\LiteTouchPE_x64.wim`
5. Name: `MDT Lite Touch (x64)`

---

## 10. Network Configuration

### Firewall Rules

Ensure these ports are open on P-WIN-SRV4:

| Port | Protocol | Service |
|:-----|:---------|:--------|
| 67/68 | UDP | DHCP (PXE) |
| 69 | UDP | TFTP |
| 4011 | UDP | PXE (alternate) |
| 445 | TCP | SMB (deployment share) |

```powershell
# Enable firewall rules for WDS
Enable-NetFirewallRule -DisplayGroup "Windows Deployment Services"

# Or create custom rules
New-NetFirewallRule -DisplayName "WDS - TFTP" -Direction Inbound -Protocol UDP -LocalPort 69 -Action Allow
New-NetFirewallRule -DisplayName "WDS - PXE" -Direction Inbound -Protocol UDP -LocalPort 67,68,4011 -Action Allow
```

### Cross-VLAN PXE Boot

For deploying to VLAN 10 (Clients) from WDS on VLAN 20 (Servers):

**Option 1: DHCP Options** (already configured above)

```powershell
# On DHCP server (P-WIN-DC1)
Set-DhcpServerv4OptionValue -ScopeId 172.16.10.0 -OptionId 66 -Value "172.16.20.14"
Set-DhcpServerv4OptionValue -ScopeId 172.16.10.0 -OptionId 67 -Value "boot\x64\wdsnbp.com"
```

**Option 2: OPNsense IP Helper**

If DHCP options don't work (some UEFI implementations ignore them):

1. OPNsense > **Services > DHCPv4 > Relay**
2. Enable on VLAN10 interface
3. Destination: `172.16.20.14` (P-WIN-SRV4)

### WDS Server Settings

Configure WDS to handle cross-subnet requests:

```powershell
# Configure WDS for known subnets
wdsutil /Set-Server /Server:P-WIN-SRV4 /Transport /EnableTftpVariableWindowExtension:Yes
wdsutil /Set-Server /Server:P-WIN-SRV4 /AnswerClients:All
```

---

## 11. Testing Deployment

### Create Test VM

Create a new VM for testing:

**Proxmox (HQ):**
```bash
# Create test VM
qm create 200 --name "Test-Deploy" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0,tag=10

# Add disk
qm set 200 --scsi0 local-lvm:32,discard=on

# Set boot order (network first)
qm set 200 --boot order=net0;scsi0

# Start VM
qm start 200
```

**Hyper-V (Branch):**
```powershell
# Create test VM
New-VM -Name "Test-Deploy" -MemoryStartupBytes 4GB -Generation 2 -NewVHDPath "C:\VMs\Test-Deploy.vhdx" -NewVHDSizeBytes 40GB

# Configure network
Connect-VMNetworkAdapter -VMName "Test-Deploy" -SwitchName "VLAN10-Clients"

# Enable PXE boot
Set-VMFirmware -VMName "Test-Deploy" -FirstBootDevice (Get-VMNetworkAdapter -VMName "Test-Deploy")

# Start VM
Start-VM -Name "Test-Deploy"
```

### PXE Boot Process

1. Start the test VM
2. VM broadcasts DHCP request with PXE option
3. DHCP server responds with IP and boot server info (Option 66/67)
4. VM contacts WDS server (P-WIN-SRV4)
5. WDS sends `wdsnbp.com` bootloader
6. VM downloads `LiteTouchPE_x64.wim` boot image
7. WinPE loads and connects to deployment share
8. MDT deployment wizard appears

### Deployment Wizard Flow

For a lite-touch deployment, the user will:

1. Select task sequence (Windows 10, 11, or Server)
2. Enter computer name
3. Select applications to install (if configured)
4. Confirm summary
5. Wait for deployment to complete

### Monitoring Deployment

Monitor progress via:

- **MDT Monitoring**: Enable in Deployment Workbench (right-click share > Properties > Monitoring tab)
- **Deployment logs**: `\\P-WIN-SRV4\Logs$\<ComputerName>\`
- **BDD.log**: Main deployment log in `C:\MININT\SMSOSD\OSDLOGS\` during deployment

```powershell
# Enable MDT monitoring
Set-ItemProperty -Path "DS001:" -Name MonitorHost -Value "P-WIN-SRV4"
Set-ItemProperty -Path "DS001:" -Name MonitorEventPort -Value 9800
Set-ItemProperty -Path "DS001:" -Name MonitorDataPort -Value 9801
```

---

## 12. Network Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PXE Boot Flow - WDS/MDT                             │
└─────────────────────────────────────────────────────────────────────────────┘

  VLAN 10 - Clients (172.16.10.0/24)              VLAN 5 - Infrastructure
  ┌─────────────────────────────┐                 ┌─────────────────────────┐
  │                             │                 │                         │
  │   New PC (No OS)            │                 │  P-WIN-DC1              │
  │   ┌───────────────┐         │                 │  172.16.5.10            │
  │   │  PXE Boot     │         │                 │  ├─ DHCP Server         │
  │   │  Client       │         │                 │  │  Option 66/67        │
  │   └───────────────┘         │                 │  └─ DNS                 │
  │          │                  │                 │                         │
  └──────────│──────────────────┘                 └─────────────────────────┘
             │                                               │
             │ 1. DHCP Discover (Broadcast)                  │
             │ ─────────────────────────────────────────────►│
             │                                               │
             │ 2. DHCP Offer (IP + PXE Options)             │
             │ ◄─────────────────────────────────────────────│
             │    Option 66: 172.16.20.14 (WDS)              │
             │    Option 67: boot\x64\wdsnbp.com             │
             │                                               │
             ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  VLAN 20 - Servers (172.16.20.0/24)                                     │
  │  ┌───────────────────────────────────────────────────────────────────┐  │
  │  │  P-WIN-SRV4 (172.16.20.14)                                        │  │
  │  │  WDS + MDT Server                                                 │  │
  │  │                                                                   │  │
  │  │  3. TFTP Download                                                 │  │
  │  │  ←─────────────────────── wdsnbp.com (bootloader)                 │  │
  │  │  ←─────────────────────── LiteTouchPE_x64.wim (boot image)        │  │
  │  │                                                                   │  │
  │  │  4. WinPE Boots                                                   │  │
  │  │     └─ Runs Bootstrap.ini                                         │  │
  │  │     └─ Connects to \\P-WIN-SRV4\DeploymentShare$                  │  │
  │  │                                                                   │  │
  │  │  5. MDT Wizard                                                    │  │
  │  │     └─ User selects Task Sequence                                 │  │
  │  │     └─ Enters Computer Name                                       │  │
  │  │                                                                   │  │
  │  │  6. Task Sequence Execution                                       │  │
  │  │     └─ Partitions disk                                            │  │
  │  │     └─ Applies OS image                                           │  │
  │  │     └─ Injects drivers                                            │  │
  │  │     └─ Installs applications                                      │  │
  │  │     └─ Joins domain (reginleif.io)                                │  │
  │  │     └─ Activates via ADBA/KMS (Project 12)                        │  │
  │  │                                                                   │  │
  │  └───────────────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────┘
             │
             │ 7. Deployed Workstation
             ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Completed Deployment                                                   │
  │  ├─ Windows 10/11/Server 2022 installed                                │
  │  ├─ Domain-joined to reginleif.io                                      │
  │  ├─ Correct drivers installed                                          │
  │  ├─ Applications configured                                             │
  │  └─ Ready for use                                                       │
  └─────────────────────────────────────────────────────────────────────────┘
```

---

## 13. Multi-Site Considerations

For deploying to branch site (Hyper-V), you have two options:

### Option A: Deploy Across WireGuard Tunnel

**Pros:** Single deployment share to maintain
**Cons:** Slower deployments over WAN, bandwidth consumption

This works automatically if:
- Branch can reach P-WIN-SRV4 via WireGuard tunnel
- DHCP at branch has correct Option 66/67 pointing to HQ server
- Firewall allows TFTP/SMB traffic through tunnel

### Option B: Replicate Deployment Share to Branch

**Pros:** Faster local deployments
**Cons:** Two shares to maintain, storage requirements

```powershell
# Create linked deployment share at branch
# On branch server (if you add one):
New-PSDrive -Name "DS002" -PSProvider MDTProvider -Root "D:\DeploymentShare"

# Use DFS-R or Robocopy to replicate
robocopy "\\P-WIN-SRV4\DeploymentShare$" "D:\DeploymentShare" /MIR /Z /R:3 /W:10
```

> [!TIP]
> For a small branch with infrequent deployments, Option A (deploying across WireGuard) is simpler. Reserve Option B for branches with frequent deployments or slow WAN links.

### Branch Deployment Validation Checklist

Before attempting branch deployments via Option A:

**Network Connectivity:**

- [ ] WireGuard VPN tunnel is active (Project 7)
- [ ] Branch can ping P-WIN-SRV4 (172.16.20.14)
- [ ] Branch can resolve `P-WIN-SRV4.reginleif.io` via DNS

**DHCP Configuration (H-WIN-DC2):**

- [ ] Option 66 (Boot Server) set to `172.16.20.14`
- [ ] Option 67 (Boot File) set to `boot\x64\wdsnbp.com`
- [ ] DHCP scope for Branch Clients VLAN (172.17.10.0/24) configured

**Firewall Rules:**

- [ ] OPNsenseBranch allows UDP 69 (TFTP) to 172.16.20.14
- [ ] OPNsenseBranch allows UDP 4011 (PXE) to 172.16.20.14
- [ ] OPNsenseBranch allows TCP 445 (SMB) to 172.16.20.14

**Test Deployment:**

- [ ] Branch test VM boots via PXE
- [ ] Boot image downloads successfully
- [ ] Deployment share connects
- [ ] Task sequence completes
- [ ] Machine joins domain

> [!NOTE]
> If Branch site experiences connectivity issues, verify:
> 1. WireGuard VPN tunnel status in OPNsenseBranch
> 2. Firewall rules permit traffic from Branch VLANs (172.17.x.x) to HQ Servers VLAN (172.16.20.x)
> 3. DNS forwarders are configured correctly (Project 11)

---

## 14. Security Hardening

### Limit PXE Responses

Configure WDS to only respond to known/prestaged computers:

```powershell
# Only respond to prestaged clients
wdsutil /Set-Server /AnswerClients:Known

# Or require admin approval
wdsutil /Set-Server /AnswerClients:None
wdsutil /Set-Server /PxePromptPolicy /Known:OptIn /New:OptIn
```

### Prestage Computer Accounts

Create computer accounts before deployment:

```powershell
# Prestage computer account with MAC address
New-ADComputer -Name "WKS-001" `
    -Path "OU=Workstations,OU=Computers,OU=HQ,DC=reginleif,DC=io" `
    -OtherAttributes @{"netbootGUID"=[GUID]"00000000-0000-0000-0000-001122334455"}

# Format: MAC address in GUID format (pad with zeros, reverse byte order for last 6 bytes)
```

### Secure Deployment Share (HTTPS)

Using your PKI from Project 13, configure HTTPS for the deployment share:

1. Request a web server certificate for P-WIN-SRV4
2. Configure IIS to host deployment share over HTTPS
3. Update Bootstrap.ini and CustomSettings.ini with HTTPS path

> [!NOTE]
> HTTPS deployment requires additional IIS configuration and is optional for lab environments. SMB with proper permissions is sufficient for most scenarios.

### Secure Credentials

Never store admin passwords in CustomSettings.ini. For domain join:

1. Use a dedicated service account with minimal permissions
2. Consider MDT database for per-machine credentials
3. Use secure password storage (LAPS integration post-deployment)

---

## 15. Validation

### A. Verify WDS Service

```powershell
# [P-WIN-SRV4]
# Check WDS service status
Get-Service WDSServer | Select-Object Status, StartType

# Verify WDS is listening
netstat -an | findstr ":69"
netstat -an | findstr ":4011"
```

### B. Verify MDT Deployment Share

```powershell
# [P-WIN-SRV4]
# Check deployment share is accessible
Test-Path "D:\DeploymentShare"

# Verify SMB share
Get-SmbShare | Where-Object Name -like "*Deployment*"

# Test network access to share
Test-Path "\\P-WIN-SRV4\DeploymentShare$"
```

### C. Verify PXE Boot Image

```powershell
# [P-WIN-SRV4]
# List boot images in WDS
Get-WdsBootImage | Select-Object ImageName, Architecture

# Verify boot image file exists
Test-Path "D:\DeploymentShare\Boot\LiteTouchPE_x64.wim"
```

### D. Validation Checklist

**WDS Server (P-WIN-SRV4):**

- [ ] WDS role installed and service running
- [ ] Boot image imported (`LiteTouchPE_x64.wim`)
- [ ] WDS configured to respond to clients
- [ ] Windows Firewall allows TFTP (UDP 69) and PXE (UDP 4011)

**MDT Deployment Share:**

- [ ] Deployment share created at `D:\DeploymentShare`
- [ ] SMB share accessible (`\\P-WIN-SRV4\DeploymentShare$`)
- [ ] At least one OS image imported
- [ ] At least one task sequence created
- [ ] CustomSettings.ini configured
- [ ] Bootstrap.ini configured with credentials

**DHCP Configuration:**

- [ ] Option 66 (Boot Server) set to 172.16.20.14
- [ ] Option 67 (Boot File) set to `boot\x64\wdsnbp.com`

**PXE Boot Test:**

- [ ] Test VM boots from network
- [ ] Boot image downloads successfully
- [ ] MDT wizard appears
- [ ] Deployment share connects
- [ ] Task sequence completes successfully
- [ ] Machine joins domain automatically

---

## 16. Troubleshooting

### Common Issues

| Symptom | Cause | Solution |
|:--------|:------|:---------|
| No PXE response | WDS not listening, firewall | Check WDS service, firewall rules |
| TFTP timeout | Network issue, cross-VLAN | Verify IP Helper or DHCP options |
| Access denied to share | Credentials | Verify svc_mdt_deploy permissions |
| Driver not installed | Wrong selection profile | Verify driver folder and profile |
| Domain join fails | OU path, credentials | Check OU path, svc_mdt_domainjoin permissions |

### Useful Logs

| Log | Location | Purpose |
|:----|:---------|:--------|
| BDD.log | C:\MININT\SMSOSD\OSDLOGS\ | Main deployment log |
| SMSTS.log | C:\MININT\SMSOSD\OSDLOGS\ | Task sequence engine log |
| MDT Event Log | Event Viewer > MDT | Server-side events |
| WDS Event Log | Event Viewer > WDS | PXE/TFTP events |

### Debug Mode

Enable verbose logging in CustomSettings.ini:

```ini
[Default]
SLShare=\\P-WIN-SRV4\Logs$
SLShareDynamicLogging=\\P-WIN-SRV4\Logs$\%ComputerName%
Debug=TRUE
```

---

## 17. Summary

This project established a complete lite-touch deployment infrastructure:

| Component | Purpose |
|:----------|:--------|
| **Windows ADK** | Image customization and WinPE tools |
| **MDT** | Deployment orchestration and task sequences |
| **WDS** | PXE boot infrastructure |
| **Deployment Share** | Central repository for OS, drivers, apps |

**Deployment capabilities:**

- Windows 10 Enterprise workstations
- Windows 11 Enterprise workstations
- Windows Server 2022 (Desktop and Core)
- Automatic domain join
- Automatic KMS/ADBA activation
- Driver injection based on hardware

**Integration points:**

- DHCP (Project 10) for PXE discovery
- Active Directory (Project 3) for domain join
- KMS/ADBA (Project 12) for activation
- PKI (Project 13) for secure deployments (optional)
