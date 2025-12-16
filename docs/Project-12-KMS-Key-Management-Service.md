---
title: "Project 12: Volume Activation (ADBA + KMS)"
tags: [adba, kms, activation, volume-licensing, windows-server, office, active-directory]
sites: [hq]
status: completed
---

## Goal

Implement a hybrid volume activation strategy using both ADBA and KMS:

- **ADBA (Primary)**: Activate domain-joined Windows devices (servers and workstations) via Active Directory. No activation threshold, no renewal required, no server dependency.
- **KMS (Secondary)**: Activate Microsoft Office products, DMZ servers, workgroup machines, and any non-domain devices via P-WIN-SRV2.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-12-concepts)**

For educational context about volume licensing, MAK vs KMS vs ADBA activation methods, and CSVLK vs GVLK key types, see the dedicated concepts guide.

---

> [!NOTE]
> For educational purposes, we will configure both methods and demonstrate the activation flow for each scenario. We will use a "simulated" KMS Host and "simulated" ADBA provided by some GitHub projects

---

## 1. VM Hardware Configuration

*Settings configured in Proxmox:*

| Setting | Value | Notes |
| :--- | :--- | :--- |
| **OS Type** | Microsoft Windows 2022 (Desktop Experience) | |
| **Machine** | q35 | Native PCIe |
| **BIOS** | OVMF (UEFI) | |
| **CPU** | Type Host, 2 Cores | Enables AES-NI |
| **RAM** | 6144 MB (6 GB) | Desktop Experience requires more than Core |
| **Controller** | VirtIO SCSI Single | IO Thread enabled |
| **Network** | VirtIO (Paravirtualized), VLAN 20 | Servers VLAN |

---

## 2. Prerequisites

Before configuring KMS:

* **Hostname:** `P-WIN-SRV2`
* **IP Address:** `172.16.20.12` (Static)
* **DNS Servers:** `172.16.5.10`, `172.17.5.10` (P-WIN-DC1 and H-WIN-DC2)
* **Default Gateway:** `172.16.20.1`
* **Domain Join:** Server must be joined to `reginleif.io`
* **CSVLK Keys:** ...
* **Windows Update:** Once domain-joined, the GPO from Project 3 disables automatic updates

### Required CSVLK Keys from VLSC

You'll need separate KMS host keys for each product family:

| Product | VLSC Product Name |
|:--------|:------------------|
| Windows Server 2022 | Windows Srv 2022 DataCtr/Std KMS |
| Windows 10/11 | Windows 10/11 |
| Office LTSC 2024 | Office LTSC Professional Plus 2024 |

> [!IMPORTANT]
> CSVLK keys are different from retail or MAK keys. They can only be installed on a KMS host and enable that host to activate volume-licensed clients. Never install a CSVLK on a client machine.

---

## 3. Configure Windows Firewall

Before installing the KMS role, configure Windows Firewall to allow traffic from all lab subnets. Without this rule, clients on the same VLAN may be unable to reach the KMS server.

> [!NOTE]
> This is the same firewall configuration applied to other servers in Project 11. SRV2 needs it to allow both KMS activation traffic and general management access from lab subnets.

```powershell
# [P-WIN-SRV2]
$AllSubnets = @(
    "172.16.5.0/24",
    "172.16.10.0/24",
    "172.16.20.0/24",
    "172.16.99.0/24",
    "172.17.5.0/24",
    "172.17.10.0/24",
    "172.17.20.0/24",
    "172.17.99.0/24",
    "10.200.0.0/24"
)

# Create rule for all VLAN subnets
New-NetFirewallRule -DisplayName "Allow Lab Subnets - All" `
    -Direction Inbound -Protocol Any -Action Allow `
    -RemoteAddress $AllSubnets -Profile Domain,Private

# Verify rule exists (should show only "Allow Lab Subnets - All")
Get-NetFirewallRule -DisplayName "Allow Lab*" | Select-Object DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow Lab Subnets - All" | Get-NetFirewallAddressFilter
```

**Expected output:**

```
DisplayName             Enabled
-----------             -------
Allow Lab Subnets - All    True

LocalAddress  : Any
RemoteAddress : {172.16.5.0/24, 172.16.10.0/24, 172.16.20.0/24, ...}
```

---

## 4. Install Volume Activation Services Role

### A. GUI Method (on P-WIN-SRV2)

1. Open **Server Manager** on P-WIN-SRV2
2. Click **Manage** > **Add Roles and Features**
3. Select **Role-based or feature-based installation**
4. Keep default (local server)
5. Check **Volume Activation Services** under Roles
6. Click **Add Features** when prompted for dependencies
7. Complete the wizard and wait for installation
8. After installation, click the notification flag in Server Manager
9. Click **Configure Volume Activation Services** to launch the wizard

### B. PowerShell Method

```powershell
# [P-WIN-SRV2]
# Install the Volume Activation Services role
Install-WindowsFeature -Name VolumeActivation -IncludeManagementTools

# Verify installation
Get-WindowsFeature -Name VolumeActivation

# Start the Software Protection service
Start-Service sppsvc

# Verify service is running
Get-Service sppsvc
```

> [!IMPORTANT]
> The Software Protection service (`sppsvc`) must be running for KMS to function. By default, it starts on-demand.

---

## 5. Configure ADBA (Active Directory-Based Activation)

ADBA stores activation objects directly in Active Directory. Domain-joined computers inherit activation automatically without needing to contact a KMS server.

> [!NOTE]
> ADBA configuration is performed from the same Volume Activation Tools used for KMS. You can configure both on P-WIN-SRV2, but ADBA activation objects are stored in AD, not on the server itself.

### A. GUI Method

1. Open **Server Manager** on P-WIN-SRV2
2. Click **Tools** > **Volume Activation Tools**
3. On the welcome page, click **Next**
4. Select **Active Directory-Based Activation** and click **Next**
5. Verify your domain (`reginleif.io`) is selected and click **Next**
6. Enter your **Windows Server CSVLK** (KMS Host Key from VLSC)
7. Provide a friendly name (e.g., "Windows Server 2022 ADBA")
8. Click **Commit** to activate the key online with Microsoft
9. Review the summary showing the activation object was created
10. Click **Close**

Repeat steps 4-10 for Windows Client (10/11) CSVLK if you have one.

### B. Verify ADBA Configuration

**Check activation objects in Active Directory:**

```powershell
# [P-WIN-DC1 or any DC]
# List all ADBA activation objects
Get-ADObject -Filter 'objectClass -eq "msSPP-ActivationObject"' `
    -SearchBase "CN=Activation Objects,CN=Microsoft SPP,CN=Services,CN=Configuration,DC=reginleif,DC=io" `
    -Properties DisplayName | Select-Object DisplayName
```

**Using Volume Activation Tools GUI:**

1. Open **Volume Activation Tools** on any domain-joined server
2. Select **Active Directory-Based Activation**
3. Click **Next** to view existing activation objects
4. You should see your configured products listed

> [!TIP]
> Unlike KMS, ADBA has **no activation threshold**. A single domain-joined computer can be activated immediately. There's also **no renewal period** - activation persists as long as the computer remains domain-joined.

---

## 6. Configure KMS Host Keys

After installing the role, install your CSVLK keys. The KMS host must be activated with Microsoft before it can activate clients.

### A. Windows Server CSVLK

```powershell
# [P-WIN-SRV2]
# Install the Windows Server KMS host key
slmgr /ipk <YOUR-WINDOWS-SERVER-CSVLK>

# Activate the KMS host with Microsoft (requires internet)
slmgr /ato

# Verify KMS host status
slmgr /dlv
```

> [!NOTE]
> Replace `<YOUR-WINDOWS-SERVER-CSVLK>` with your actual CSVLK from VLSC. The key format is `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.

### B. Windows 10/11 Client CSVLK

To activate Windows 10/11 clients, install the Windows client CSVLK:

```powershell
# [P-WIN-SRV2]
# Install the Windows Client KMS host key
slmgr /ipk <YOUR-WINDOWS-CLIENT-CSVLK>

# Activate with Microsoft
slmgr /ato

# Verify - should show "Windows(R), ServerStandard edition" for Server
# and additional entries for client activation capability
slmgr /dlv
```

> [!WARNING]
> Each `slmgr /ipk` command replaces the previous product key for that license family. A single KMS host can hold keys for multiple product families (Server, Client, Office) simultaneously, but only one key per family.

### C. Office Volume License Pack and CSVLK

Before configuring Office KMS activation, you must install the **Office Volume License Pack** for the Office version you're activating. This pack adds the necessary licensing components to the KMS host.

#### Step 1: Install Office Volume License Pack

Download and install the appropriate Volume License Pack from Microsoft:

| Office Version | Download Link | Architecture |
|:---------------|:--------------|:-------------|
| Office LTSC 2024 | [x64](https://download.microsoft.com/download/1/4/0/140c97ae-7360-4dfc-9ba0-5f509600a06e/Office2024VolumeLicensePack_x64.exe) / [x86](https://download.microsoft.com/download/1/4/0/140c97ae-7360-4dfc-9ba0-5f509600a06e/Office2024VolumeLicensePack_x86.exe) | 64-bit / 32-bit |

**Installation:**

```powershell
# [P-WIN-SRV2]
# Download the appropriate pack for your Office version and KMS host architecture
# Most modern servers are 64-bit

# Example for Office 2024:
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
Invoke-WebRequest -Uri "https://download.microsoft.com/download/1/4/0/140c97ae-7360-4dfc-9ba0-5f509600a06e/Office2024VolumeLicensePack_x64.exe" `
    -OutFile "C:\Temp\Office2024VolumeLicensePack_x64.exe"

# Run the installer (silent installation)
C:\Temp\Office2024VolumeLicensePack_x64.exe /quiet

# Or run with GUI
Start-Process "C:\Temp\Office2024VolumeLicensePack_x64.exe" -Wait
```

> [!IMPORTANT]
> The Volume License Pack **does not install Office applications**. It only adds licensing components to enable the KMS host to activate Office clients. You can install multiple packs if you need to support different Office versions.

#### Step 2: Install Office CSVLK

After installing the Volume License Pack, configure Office KMS activation:

**Using Volume Activation Tools (GUI):**

1. Open **Volume Activation Tools** from Server Manager > Tools
2. Select **Key Management Service (KMS)**
3. Click **Install your KMS host key**
4. Enter your Office CSVLK
5. Click **Commit** then **Activate**

**Using PowerShell (Office must be installed on the KMS host):**

```powershell
# [P-WIN-SRV2]
# Navigate to Office installation directory
cd "$env:ProgramFiles\Microsoft Office\Office16"

# Install Office KMS host key
cscript ospp.vbs /inpkey:<YOUR-OFFICE-CSVLK>

# Activate the Office KMS host
cscript ospp.vbs /act

# Verify Office KMS status
cscript ospp.vbs /dstatus
```

#### Step 3: Verify Office KMS Configuration

After installing the Volume License Pack and CSVLK, verify that Office KMS is correctly configured:

**Check installed Office KMS products:**

```powershell
# [P-WIN-SRV2]
# Method 1: View in PowerShell console (recommended - easier to read)
Get-CimInstance -ClassName SoftwareLicensingProduct |
    Where-Object {$_.Description -like "*Office*" -and $_.LicenseStatus -eq 1} |
    Select-Object Name, Description, LicenseStatus, KeyManagementServiceProductKeyID |
    Format-List

# Method 2: Use slmgr with popup dialogs (can be multiple large windows)
slmgr /dlv all

# Look for Office-related entries in the output with:
# - Description: "Office 21, OfficeProPlus2024-KMSHost edition" (or similar)
# - License Status: Licensed (1)
# - Key Management Service Product Key ID: (your Office CSVLK partial key)
```

**Using Volume Activation Tools (GUI):**

1. Open **Volume Activation Tools** from Server Manager > Tools
2. Select **Key Management Service (KMS)**
3. Review the **Product Key ID** and **Description**
4. Verify the Office product appears with:
   - **License Status**: Licensed
   - **Current Count**: Shows activation attempts from Office clients

**Check Windows Event Log:**

```powershell
# [P-WIN-SRV2]
# View recent KMS activation events for Office
Get-WinEvent -FilterHashtable @{
    LogName = 'Key Management Service'
} -MaxEvents 20 | Where-Object {$_.Message -like "*Office*"} |
    Format-Table TimeCreated, Id, Message -Wrap
```

**Verify Office activation from a client:**

```powershell
# [Any machine with Office installed]
cd "$env:ProgramFiles\Microsoft Office\Office16"

# Set KMS server
cscript ospp.vbs /sethst:P-WIN-SRV2.reginleif.io

# Attempt activation
cscript ospp.vbs /act

# Check status - should show:
# LICENSE STATUS: ---LICENSED---
cscript ospp.vbs /dstatus
```

> [!NOTE]
> If Office activation fails, verify:
> 1. The correct Volume License Pack is installed for your Office version
> 2. The Office CSVLK is activated on the KMS host (`slmgr /dlv all`)
> 3. The KMS host is reachable on TCP port 1688
> 4. The Office client has a valid GVLK installed

> [!TIP]
> **Alternative methods if you don't want to install full Office on the KMS server:**
>
> 1. **Volume Activation Tools (GUI)** - Use the method above (simplest, no Office needed)
> 2. **VAMT (Volume Activation Management Tool)** - Centralized activation management
> 3. **Office Deployment Tool (ODT)** - Lightweight Office installer/configurator from Microsoft
> 4. **Registry edits** - Manual configuration (advanced)
>
> The GUI method above using Volume Activation Tools is the recommended approach as it doesn't require Office installation and provides a simple interface for managing Office KMS activation.

---

## 7. DNS Configuration for Auto-Discovery (KMS Only)

> [!NOTE]
> **ADBA does not require DNS configuration.** Domain-joined clients automatically discover ADBA activation objects through Active Directory. This DNS SRV record is only needed for KMS activation (Office, DMZ servers, workgroup machines).

KMS clients automatically look for a DNS SRV record to find the KMS host. Creating this record enables automatic activation without manual configuration on each client.

> **Port 1688** is the well-known port for KMS (Key Management Service). When a Windows client with a GVLK attempts activation, it connects to TCP port 1688 on the KMS host. The `_vlmcs._tcp` SRV record tells clients where to find this service (VLMCS = Volume License Management Client Service).

### A. Create SRV Record

```powershell
# [P-WIN-DC1]
# Create the KMS auto-discovery SRV record
Add-DnsServerResourceRecord -ZoneName "reginleif.io" `
    -Name "_vlmcs._tcp" `
    -Srv `
    -DomainName "P-WIN-SRV2.reginleif.io" `
    -Priority 0 `
    -Weight 0 `
    -Port 1688

# Verify the record was created
Get-DnsServerResourceRecord -ZoneName "reginleif.io" -Name "_vlmcs._tcp" -RRType SRV
```

### B. GUI Method

1. Open **DNS Manager** (dnsmgmt.msc) on P-WIN-SRV2 or any server with RSAT
2. Connect to **P-WIN-DC1**
3. Expand **Forward Lookup Zones** > **reginleif.io**
4. Right-click the zone > **Other New Records**
5. Select **Service Location (SRV)** > **Create Record**
6. Configure:
   - **Service:** `_vlmcs`
   - **Protocol:** `_tcp`
   - **Priority:** `0`
   - **Weight:** `0`
   - **Port number:** `1688`
   - **Host offering this service:** `P-WIN-SRV2.reginleif.io`
7. Click **OK**

### C. Verify DNS Resolution

```powershell
# From any domain-joined machine
nslookup -type=srv _vlmcs._tcp.reginleif.io

# Expected output:
# _vlmcs._tcp.reginleif.io  SRV service location:
#           priority       = 0
#           weight         = 0
#           port           = 1688
#           svr hostname   = P-WIN-SRV2.reginleif.io
```

---

## 8. OPNsense Firewall (Optional)

> [!NOTE]
> Windows Firewall on P-WIN-SRV2 was already configured in Section 3 to allow all traffic from lab subnets, including KMS activation on TCP port 1688. This section only applies if you have restrictive OPNsense firewall rules.

If you've implemented VLAN segmentation (Project 11) with restrictive firewall rules, ensure clients can reach the KMS server:

**Required rule (if not using permissive inter-VLAN rules):**

| Setting | Value |
|:--------|:------|
| Interface | CLIENTS (VLAN 10) |
| Protocol | TCP |
| Source | CLIENTS net |
| Destination | 172.16.20.12 (P-WIN-SRV2) |
| Port | 1688 |
| Description | Allow KMS activation |

> [!NOTE]
> If you're using the permissive `Trusted_Lab_Networks` rules from Project 11, KMS traffic is already allowed between VLANs.

---

## 9. Convert Evaluation Editions to Volume

If your Windows Server VMs were installed using evaluation media, you must convert them to volume-licensed editions before KMS activation will work. Evaluation editions cannot be activated via KMS.

### A. Check Current Edition

```powershell
# [Any Windows Server VM]
# View current edition
DISM /online /Get-CurrentEdition

# View available upgrade paths
DISM /online /Get-TargetEditions
```

**Example output for evaluation:**

```
Current Edition : ServerStandardEval

Target Edition : ServerStandard
Target Edition : ServerDatacenter
```

> [!NOTE]
> If the current edition shows `ServerStandard` or `ServerDatacenter` (without "Eval"), you're already on a volume-capable edition. Skip to Section 10 and just install the GVLK with `slmgr /ipk`.

### B. Convert to Volume Edition

Use DISM with the appropriate GVLK to convert the edition:

**Windows Server 2022 Datacenter:**

```powershell
# [Any Windows Server 2022 Eval VM]
DISM /online /Set-Edition:ServerDatacenter /ProductKey:WX4NM-KYWYW-QJJR4-XV3QB-6VM33 /AcceptEula
```

> [!WARNING]
> The server will **reboot automatically** after the edition change. Save your work and plan for downtime. For Domain Controllers, ensure AD replication is healthy before converting.

> [!IMPORTANT]
> Edition conversions can only go sideways or up:
> - Standard Eval → Standard (OK)
> - Standard Eval → Datacenter (OK)
> - Datacenter Eval → Datacenter (OK)
> - Datacenter Eval → Standard (NOT POSSIBLE)

### C. Verify Conversion

After reboot, confirm the edition changed:

```powershell
# [Any Windows Server VM]
DISM /online /Get-CurrentEdition

# Should now show:
# Current Edition : ServerDatacenter
# or
# Current Edition : ServerDatacenterCor
```

The server is now ready for activation. Proceed to Section 10 to activate via ADBA or KMS.

---

## 10. Configure Clients for Activation

This section covers activation for different device types in the hybrid strategy.

### A. Domain-Joined Windows (ADBA - Automatic)

**Domain-joined devices activate automatically via ADBA.** Once ADBA is configured (Section 5) and a GVLK is installed, domain-joined computers are activated instantly.

```powershell
# [Any domain-joined Windows Server or Client]
# Install GVLK for your edition (see Section 11 for keys)
slmgr /ipk WX4NM-KYWYW-QJJR4-XV3QB-6VM33   # Server 2022 Datacenter

# Trigger activation (will use ADBA automatically for domain-joined)
slmgr /ato

# Verify activation - should show "VOLUME_KMSCLIENT channel"
slmgr /dlv
```

> [!TIP]
> Domain-joined devices with a GVLK will automatically try ADBA first. If ADBA activation objects exist in AD for that product, activation succeeds immediately. No KMS server contact is needed.

**Verify ADBA is being used:**

```powershell
# Check activation channel
slmgr /dli

# For ADBA-activated machines, you'll see:
# - License Status: Licensed
# - No "KMS machine name" entry (ADBA doesn't use KMS server)
```

### B. Non-Domain Windows (KMS)

For DMZ servers, workgroup machines, or any non-domain-joined Windows:

```powershell
# [Non-domain Windows Server or Client]
# Install GVLK
slmgr /ipk WX4NM-KYWYW-QJJR4-XV3QB-6VM33   # Server 2022 Datacenter

# Set KMS server (required for non-domain machines)
slmgr /skms P-WIN-SRV2.reginleif.io

# Activate via KMS
slmgr /ato

# Verify - should show KMS machine name
slmgr /dlv
```

> [!NOTE]
> Non-domain machines cannot use ADBA and will always use KMS. These machines need network access to P-WIN-SRV2 on TCP port 1688 and must renew activation every 180 days (attempted automatically every 7 days).

### C. Windows Clients (Group Policy for KMS Fallback)

For domain-joined clients, ADBA is automatic. However, you can configure GPO to ensure KMS fallback works if ADBA fails:

1. Open **Group Policy Management** on P-WIN-DC1
2. Create a new GPO: `Volume Activation Settings`
3. Link to the appropriate OU (e.g., `Workstations`)
4. Edit the GPO and navigate to:
   - **Computer Configuration** > **Policies** > **Administrative Templates** > **Windows Components** > **Software Protection Platform**

5. Configure:

| Setting | Value |
|:--------|:------|
| Turn on KMS client online activation | Enabled |

**Optional: Specify KMS server for fallback:**

6. Navigate to: **Computer Configuration** > **Preferences** > **Windows Settings** > **Registry**
7. Create two registry entries:

| Setting | Value |
|:--------|:------|
| Hive | HKEY_LOCAL_MACHINE |
| Key Path | SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform |
| Value name | KeyManagementServiceName |
| Value type | REG_SZ |
| Value data | P-WIN-SRV2.reginleif.io |

| Setting | Value |
|:--------|:------|
| Hive | HKEY_LOCAL_MACHINE |
| Key Path | SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform |
| Value name | KeyManagementServicePort |
| Value type | REG_SZ |
| Value data | 1688 |

> [!NOTE]
> These GPO settings only affect KMS fallback. Domain-joined machines will still try ADBA first automatically.

### D. Microsoft Office (KMS Only)

**Office does not support ADBA** and must use KMS activation:

```powershell
# [Any machine with Office installed]
# Navigate to Office installation
cd "$env:ProgramFiles\Microsoft Office\Office16"

# Set KMS server (if auto-discovery doesn't work)
cscript ospp.vbs /sethst:P-WIN-SRV2.reginleif.io
cscript ospp.vbs /setprt:1688

# Activate
cscript ospp.vbs /act

# Verify activation
cscript ospp.vbs /dstatus
```

> [!TIP]
> For mass deployment, include KMS server in your Office Deployment Tool (ODT) configuration:
> ```xml
> <Configuration>
>   <Add OfficeClientEdition="64">
>     <Product ID="ProPlus2024Volume">
>       <Language ID="en-us" />
>     </Product>
>   </Add>
>   <Property Name="KMSClientHostedLicensing" Value="0" />
>   <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
> </Configuration>
> ```

### E. Activation Summary by Device Type

| Device | Method | Action Required |
|:-------|:-------|:----------------|
| Domain-joined server | ADBA | Install GVLK, run `slmgr /ato` |
| Domain-joined workstation | ADBA | Install GVLK, run `slmgr /ato` |
| DMZ server | KMS | Install GVLK, set KMS server, run `slmgr /ato` |
| Workgroup machine | KMS | Install GVLK, set KMS server, run `slmgr /ato` |
| Office (any machine) | KMS | Set KMS server via ospp.vbs, run `/act` |

---

## 11. GVLK Reference Table (some examples)

Generic Volume License Keys (GVLKs) are public and tell the client to seek KMS activation:

### Windows Server 2022

| Edition | GVLK |
|:--------|:-----|
| Datacenter | WX4NM-KYWYW-QJJR4-XV3QB-6VM33 |
| Standard | VDYBN-27WPP-V4HQT-9VMD4-VMK7H |

### Windows Server 2019

| Edition | GVLK |
|:--------|:-----|
| Datacenter | WMDGN-G9PQG-XVVXX-R3X43-63DFG |
| Standard | N69G4-B89J2-4G8F4-WWYCC-J464C |

### Windows 11

| Edition | GVLK |
|:--------|:-----|
| Pro | W269N-WFGWX-YVC9B-4J6C9-T83GX |
| Enterprise | NPPR9-FWDCX-D2C8J-H872K-2YT43 |
| Education | NW6C2-QMPVW-D7KKK-3GKT6-VCFB2 |

### Windows 10

| Edition | GVLK |
|:--------|:-----|
| Pro | W269N-WFGWX-YVC9B-4J6C9-T83GX |
| Enterprise | NPPR9-FWDCX-D2C8J-H872K-2YT43 |
| Education | NW6C2-QMPVW-D7KKK-3GKT6-VCFB2 |

### Office LTSC 2024

| Product | GVLK |
|:--------|:-----|
| Professional Plus | XJ2XN-FW8RK-P4HMP-DKDBV-GCVGB |
| Standard | V28N4-JG22K-W66P8-VTMGK-H6HGR |

> [!NOTE]
> For a complete list of GVLKs, see [Microsoft's official documentation](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys).

---

## 12. Validation

### A. Check KMS Server Status

```powershell
# [P-WIN-SRV2]
# Display detailed license information
slmgr /dlv

# Key information to look for:
# - License Status: Licensed
# - KMS machine name: P-WIN-SRV2
# - Current count: Shows how many unique clients have contacted this KMS host
```

### B. View KMS Activation Count

```powershell
# [P-WIN-SRV2]
# Quick license info
slmgr /dli

# Check the "Current count" value:
# - Need 5+ for Windows Server to activate servers
# - Need 25+ for Windows Client to activate desktops
```

### C. Verify DNS Auto-Discovery

```powershell
# [From any client]
nslookup -type=srv _vlmcs._tcp.reginleif.io

# Should return:
# svr hostname = P-WIN-SRV2.reginleif.io
# port = 1688
```

### D. Test Client Activation

```powershell
# [From a client with GVLK installed]
# Force activation attempt
slmgr /ato

# Check activation status
slmgr /dlv

# Verify KMS server being used
slmgr /dlv | findstr "KMS"
```

### E. Check Windows Event Log

```powershell
# [P-WIN-SRV2]
# View KMS host events
Get-WinEvent -FilterHashtable @{
    LogName = 'Application'
    ProviderName = 'Microsoft-Windows-Security-SPP'
} -MaxEvents 20 | Format-Table TimeCreated, Message -Wrap
```

### F. Validation Checklist

**ADBA Configuration:**

- [ ] Volume Activation Services role installed on P-WIN-SRV2
- [ ] ADBA activation objects created in Active Directory
- [ ] Windows Server ADBA activation object exists (verify via Volume Activation Tools)
- [ ] Windows Client ADBA activation object exists (if configured)
- [ ] Domain-joined server activates via ADBA (`slmgr /dlv` shows Licensed, no KMS machine name)
- [ ] Domain-joined workstation activates via ADBA

**KMS Configuration:**

- [ ] Windows Server CSVLK installed and activated on KMS host (`slmgr /dlv` shows Licensed)
- [ ] Windows Client CSVLK installed and activated on KMS host
- [ ] Office CSVLK installed and activated (if applicable)
- [ ] DNS SRV record `_vlmcs._tcp` resolves to P-WIN-SRV2
- [ ] Firewall rule allows TCP 1688 inbound
- [ ] Non-domain server can activate against KMS
- [ ] Office activates against KMS (`cscript ospp.vbs /dstatus` shows Licensed)

---

## Network Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Hybrid ADBA + KMS Activation Flow                        │
└─────────────────────────────────────────────────────────────────────────────┘

                         ┌──────────────────────┐
                         │  Microsoft VLSC      │
                         │  (One-time CSVLK     │
                         │   activation)        │
                         └──────────┬───────────┘
                                    │ Internet
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
┌───────────────────────────────┐   ┌───────────────────────────────────────┐
│  Active Directory             │   │  VLAN 20 - Servers (172.16.20.0/24)   │
│  (ADBA Activation Objects)    │   │  ┌─────────────────────────────────┐  │
│                               │   │  │  P-WIN-SRV2 (KMS Host)          │  │
│  Stored in:                   │   │  │  172.16.20.12:1688              │  │
│  CN=Activation Objects,       │   │  │                                 │  │
│  CN=Microsoft SPP,            │   │  │  KMS Keys:                      │  │
│  CN=Services,                 │   │  │  - Windows Server 2022 CSVLK   │  │
│  CN=Configuration,DC=...      │   │  │  - Windows 10/11 CSVLK         │  │
│                               │   │  │  - Office 2024 CSVLK           │  │
│  ADBA Keys:                   │   │  └─────────────────────────────────┘  │
│  - Windows Server 2022        │   └───────────────────────────────────────┘
│  - Windows 10/11              │                   ▲
└───────────────────────────────┘                   │ TCP 1688 (KMS only)
           ▲                                        │
           │ LDAP (Automatic)           ┌───────────┴───────────┐
           │                            │                       │
┌──────────┴────────────────────────────┴───┐   ┌───────────────┴───────────┐
│  Domain-Joined Devices (ADBA)             │   │  Non-Domain / Office      │
│                                           │   │  (KMS)                    │
│  ┌─────────────────────────────────────┐  │   │                           │
│  │ VLAN 5 - Infrastructure             │  │   │  DMZ Servers              │
│  │ P-WIN-DC1, P-WIN-DC2 (DC)           │  │   │  - Windows via KMS        │
│  │ → Activated via ADBA (no renewal)   │  │   │  - Renew every 180 days   │
│  └─────────────────────────────────────┘  │   │                           │
│  ┌─────────────────────────────────────┐  │   │  Workgroup Machines       │
│  │ VLAN 10 - Clients                   │  │   │  - Windows via KMS        │
│  │ Domain-joined Workstations          │  │   │                           │
│  │ → Activated via ADBA (no renewal)   │  │   │  Office Products          │
│  └─────────────────────────────────────┘  │   │  - All machines via KMS   │
│  ┌─────────────────────────────────────┐  │   │  - ADBA not supported     │
│  │ VLAN 20 - Servers                   │  │   │                           │
│  │ P-WIN-SRV2 and other servers        │  │   └───────────────────────────┘
│  │ → Activated via ADBA (no renewal)   │  │
│  └─────────────────────────────────────┘  │
└───────────────────────────────────────────┘

Activation Priority (Automatic):
  1. ADBA  - Domain-joined checks AD first (instant, no threshold, no renewal)
  2. KMS   - Falls back to KMS if ADBA unavailable (threshold required, 180-day renewal)

DNS Auto-Discovery (KMS only):
  Client queries: _vlmcs._tcp.reginleif.io
  DNS returns:    P-WIN-SRV2.reginleif.io:1688
```
