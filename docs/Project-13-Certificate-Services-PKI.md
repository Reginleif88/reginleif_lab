---
title: "Project 13: Certificate Services (PKI)"
tags: [pki, certificate-authority, ad-cs, windows-server, security, active-directory]
sites: [hq]
status: planned
---

## Goal

Deploy a two-tier Public Key Infrastructure (PKI) for the reginleif.io domain:

- **Offline Root CA (P-WIN-ROOTCA)**: Standalone Root CA that signs the subordinate CA certificate, then remains powered off for security. Long validity (20 years) and infrequent CRL publication (52 weeks).
- **Enterprise Subordinate CA (P-WIN-SRV3)**: Dedicated online CA integrated with Active Directory that issues certificates to domain members. Supports auto-enrollment via Group Policy.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-13-concepts)**

For educational context about PKI architecture, two-tier hierarchies, certificate lifecycle, and Root CA vs Subordinate CA design, see the dedicated concepts guide.

---

## Firewall Requirements

> [!NOTE]
> If you implemented the permissive `Trusted_Lab_Networks` firewall rule in Project 11, PKI traffic is already permitted between VLANs. The rules below document what is required for production environments with restrictive firewalls.

**Required firewall rules for PKI services:**

| Protocol | Port(s) | Source | Destination | Purpose |
|:---------|:--------|:-------|:------------|:--------|
| TCP | 80 | All VLANs | 172.16.20.13 | HTTP CRL/AIA distribution |
| TCP | 135 | Domain Members | 172.16.20.13 | RPC endpoint mapper |
| TCP | 49152-65535 | Domain Members | 172.16.20.13 | RPC dynamic ports (DCOM for cert enrollment) |
| TCP/UDP | 389 | Domain Members | Domain Controllers | LDAP (CDP/AIA via AD) |
| TCP | 636 | Domain Members | Domain Controllers | LDAPS (secure LDAP queries) |

> [!TIP]
> For the Root CA (P-WIN-ROOTCA), only temporary network access is needed during initial setup and annual CRL renewal. Consider disconnecting its network adapter when powered off.

---

## 1. Root CA VM Configuration

The Root CA is a temporary VM that will be powered off after signing the subordinate CA certificate.

### VM Hardware (Proxmox)

| Setting | Value | Notes |
|:--------|:------|:------|
| **OS Type** | Microsoft Windows 2022 (Desktop Experience) | GUI needed for initial setup |
| **Machine** | q35 | Native PCIe |
| **BIOS** | OVMF (UEFI) | |
| **CPU** | Type Host, 2 Cores | Minimal requirements |
| **RAM** | 4096 MB (4 GB) | Minimal requirements |
| **Disk** | 60 GB (VirtIO SCSI) | CA database storage |
| **Network** | VirtIO (Paravirtualized), VLAN 20 | Temporary network access |

### Network Configuration

| Setting | Value |
|:--------|:------|
| **Hostname** | P-WIN-ROOTCA |
| **IP Address** | 172.16.20.15 (Static, temporary) |
| **Subnet Mask** | 255.255.255.0 |
| **Default Gateway** | 172.16.20.1 |
| **DNS Servers** | 172.16.5.10, 172.17.5.10 |
| **Domain Join** | **NO** - Standalone CA |

> [!IMPORTANT]
> The Root CA must NOT be joined to the domain. Standalone CAs operate independently and can function offline. Domain-joined Enterprise CAs require constant AD connectivity.

---

## 2. Root CA Initial Setup

### A. Windows Configuration

After installing Windows Server 2022 and VirtIO drivers (per Project 2):

```powershell
# [P-WIN-ROOTCA]
# Set hostname (will require restart)
Rename-Computer -NewName "P-WIN-ROOTCA" -Restart
```

After restart:

```powershell
# [P-WIN-ROOTCA]
# Configure static IP
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress "172.16.20.15" `
    -PrefixLength 24 `
    -DefaultGateway "172.16.20.1"

# Set DNS servers (needed for time sync)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses "172.16.5.10","172.17.5.10"

# Configure time synchronization with DC
w32tm /config /manualpeerlist:"172.16.5.10" /syncfromflags:manual /update
Restart-Service w32time
w32tm /resync /force

# Verify time is synchronized
w32tm /query /status
```

> [!NOTE]
> Time synchronization is critical for PKI. Certificate validity periods are time-based, and clock skew can cause certificates to appear invalid.

> [!TIP]
> Since the Root CA is standalone (not domain-joined), it won't receive the GPO that disables automatic Windows Updates. Before powering off the Root CA for long-term storage, manually disable Windows Update to prevent unexpected reboots during annual CRL renewal sessions:
> ```powershell
> # Disable Windows Update service
> Stop-Service wuauserv
> Set-Service wuauserv -StartupType Disabled
> ```

### B. Install AD CS Role

```powershell
# [P-WIN-ROOTCA]
# Install Certificate Services role
Install-WindowsFeature AD-Certificate -IncludeManagementTools

# Verify installation
Get-WindowsFeature AD-Certificate
```

### C. Configure Windows Firewall

Allow inbound traffic from P-WIN-SRV3 (for file transfers) and P-WIN-DC1 (for time sync):

```powershell
# [P-WIN-ROOTCA]
# Create rule for Subordinate CA server and DC1 (time sync)
New-NetFirewallRule -DisplayName "Allow PKI Setup" `
    -Direction Inbound -Protocol Any -Action Allow `
    -RemoteAddress "172.16.20.13","172.16.5.10" -Profile Private

# Verify rule exists
Get-NetFirewallRule -DisplayName "Allow PKI Setup" | Select-Object DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Allow PKI Setup" | Get-NetFirewallAddressFilter
```

> [!NOTE]
> The Root CA needs to communicate with:
> - **P-WIN-SRV3 (172.16.20.13):** Certificate request/response file transfers
> - **P-WIN-DC1 (172.16.5.10):** NTP time synchronization (configured in Section 2.A)
>
> Since the Root CA will be powered off after configuration, this minimal rule is sufficient.

---

## 3. Configure Root CA

### A. CA Configuration Wizard (GUI)

After installing the role, configure through Server Manager:

1. Click the **notification flag** > **Configure Active Directory Certificate Services**
2. **Credentials**: Use local Administrator account (not domain)
3. **Role Services**: Check **Certification Authority** only
4. **Setup Type**: Select **Standalone CA**
5. **CA Type**: Select **Root CA**
6. **Private Key**: Select **Create a new private key**
7. **Cryptography**:
   - Provider: `RSA#Microsoft Software Key Storage Provider`
   - Key length: `4096` bits
   - Hash algorithm: `SHA256`
8. **CA Name**:
   - Common name: `REGINLEIF-ROOT-CA`
   - Distinguished name suffix: `DC=reginleif,DC=io`
   - Preview: `CN=REGINLEIF-ROOT-CA,DC=reginleif,DC=io`
9. **Validity Period**: `20 years`
10. **Database**: Accept defaults (`C:\Windows\System32\CertLog`)
11. Click **Configure**

> [!TIP]
> The 20-year validity for the Root CA ensures you won't need to renew it frequently. The subordinate CA (10 years) can be renewed once within the Root CA's lifetime.

### B. Configure CRL Settings

Open the CA management console:

```powershell
# [P-WIN-ROOTCA]
certsrv.msc
```

**Configure CRL Distribution Points (CDP):**

1. Right-click **REGINLEIF-ROOT-CA** > **Properties**
2. Go to **Extensions** tab
3. Select **CRL Distribution Point (CDP)** from dropdown
4. Remove all entries except the local file path:
   - Keep: `C:\Windows\System32\CertSrv\CertEnroll\<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl`
5. Click **Add** to add HTTP CDP:
   - Location: `http://pki.reginleif.io/CertEnroll/<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl`
   - Check: **Include in CRLs. Clients use this to find Delta CRL locations.**
   - Check: **Include in the CDP extension of issued certificates**
6. Click **OK**

**Configure Authority Information Access (AIA):**

1. Select **Authority Information Access (AIA)** from dropdown
2. Remove all entries except the local file path
3. Click **Add** to add HTTP AIA:
   - Location: `http://pki.reginleif.io/CertEnroll/<ServerDNSName>_<CaName><CertificateName>.crt`
   - Check: **Include in the AIA extension of issued certificates**
4. Click **OK**
5. Click **Yes** when prompted to restart the CA service

**Configure CRL Publication Interval:**

```powershell
# [P-WIN-ROOTCA]
# Set CRL validity to 52 weeks (1 year)
certutil -setreg CA\CRLPeriodUnits 52
certutil -setreg CA\CRLPeriod "Weeks"

# Disable Delta CRL (not needed for offline Root CA)
# Setting units to 0 disables Delta CRL; period value is ignored but required
certutil -setreg CA\CRLDeltaPeriodUnits 0
certutil -setreg CA\CRLDeltaPeriod "Days"

# Set overlap period (ensures new CRL available before old expires)
certutil -setreg CA\CRLOverlapUnits 2
certutil -setreg CA\CRLOverlapPeriod "Weeks"

# Restart CA service to apply changes
Restart-Service certsvc

# Publish initial CRL
certutil -crl
```

> [!WARNING]
> The Root CA must be powered on at least once per year to publish a new CRL. If the CRL expires, certificate validation will fail for the entire PKI hierarchy.

---

## 4. Export Root CA Files

Before configuring the subordinate CA, export the Root CA certificate and CRL:

```powershell
# [P-WIN-ROOTCA]
# Create export directory
New-Item -Path "C:\PKIExport" -ItemType Directory -Force

# Export Root CA certificate
certutil -ca.cert "C:\PKIExport\REGINLEIF-ROOT-CA.cer"

# Copy CRL to export directory
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crl" "C:\PKIExport\"

# List exported files
Get-ChildItem "C:\PKIExport\"
```

**Expected output:**

```
Mode                 LastWriteTime         Length Name
----                 -------------         ------ ----
-a----         [date]   [time]           1842 REGINLEIF-ROOT-CA.cer
-a----         [date]   [time]            573 REGINLEIF-ROOT-CA.crl
```

**Transfer files to P-WIN-SRV3:**

Copy the contents of `C:\PKIExport\` to P-WIN-SRV3 using one of these methods:
- **Network share** (if still connected)
- **Remote Desktop file copy** (drag and drop)
- **USB drive** (most secure for offline CA)

---

## 5. DNS Configuration

Create the DNS record for the PKI HTTP distribution point before configuring the subordinate CA:

```powershell
# [P-WIN-DC1]
# Create A record for PKI distribution point
Add-DnsServerResourceRecordA -ZoneName "reginleif.io" `
    -Name "pki" `
    -IPv4Address "172.16.20.13"

# Verify record
Resolve-DnsName pki.reginleif.io
```

**Expected output:**

```
Name                           Type   TTL   Section    IPAddress
----                           ----   ---   -------    ---------
pki.reginleif.io               A      3600  Answer     172.16.20.13
```

---

## 6. Subordinate CA VM Configuration

Create a new dedicated server for the Enterprise Subordinate CA.

### VM Hardware (Proxmox)

*Settings configured in Proxmox:*

| Setting | Value | Notes |
| :--- | :--- | :--- |
| **OS Type** | Microsoft Windows 2022 (Desktop Experience) | GUI needed for CA management |
| **Machine** | q35 | Native PCIe |
| **BIOS** | OVMF (UEFI) | |
| **CPU** | Type Host, 2 Cores | Enables AES-NI |
| **RAM** | 4096 MB (4 GB) | Sufficient for dedicated CA |
| **Controller** | VirtIO SCSI Single | IO Thread enabled |
| **Network** | VirtIO (Paravirtualized), VLAN 20 | Servers VLAN |

### Prerequisites

Before configuring the Subordinate CA:

* **Hostname:** `P-WIN-SRV3`
* **IP Address:** `172.16.20.13` (Static)
* **DNS Servers:** `172.16.5.10`, `172.17.5.10` (P-WIN-DC1 and H-WIN-DC2)
* **Default Gateway:** `172.16.20.1`
* **Domain Join:** Server must be joined to `reginleif.io`
* **Windows Update:** Once domain-joined, the GPO from Project 3 disables automatic updates

> [!NOTE]
> P-WIN-SRV3 is a dedicated Certificate Authority server, separate from P-WIN-SRV2 (KMS). This follows enterprise best practice of separating CA from other services.

**Initial Windows Configuration:**

Follow Project 2 for Windows Server 2022 installation and VirtIO drivers, then:

```powershell
# [P-WIN-SRV3]
# Set hostname (will require restart)
Rename-Computer -NewName "P-WIN-SRV3" -Restart
```

After restart, configure network and join domain:

```powershell
# [P-WIN-SRV3]
# Configure static IP
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress "172.16.20.13" `
    -PrefixLength 24 `
    -DefaultGateway "172.16.20.1"

# Set DNS servers
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses "172.16.5.10","172.17.5.10"

# Join domain (will require restart)
Add-Computer -DomainName "reginleif.io" -Credential (Get-Credential) -Restart
```

---

## 7. Install Roles on Subordinate CA

Install AD CS and IIS for CRL/AIA distribution:

```powershell
# [P-WIN-SRV3]
# Install Certificate Services and Web Server roles
Install-WindowsFeature AD-Certificate, Web-Server -IncludeManagementTools

# Verify installation
Get-WindowsFeature AD-Certificate, Web-Server
```

**Expected output:**

```
Display Name                                    Name                       Install State
------------                                    ----                       -------------
[X] Active Directory Certificate Services       AD-Certificate                 Installed
[X] Web Server (IIS)                           Web-Server                     Installed
```

### Configure Windows Firewall

Allow inbound traffic from all lab subnets for PKI services:

```powershell
# [P-WIN-SRV3]
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

# Verify rule exists
Get-NetFirewallRule -DisplayName "Allow Lab Subnets - All" | Select-Object DisplayName, Enabled
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

> [!NOTE]
> This permissive rule allows all domain members to reach the CA for certificate enrollment (RPC/DCOM) and CRL/AIA distribution (HTTP). In production, create specific rules per the Firewall Requirements section.

---

## 8. Configure IIS for CRL Distribution

### A. Create Web Directory

```powershell
# [P-WIN-SRV3]
# Create physical directory for PKI files
New-Item -Path "C:\PKIWeb\CertEnroll" -ItemType Directory -Force

# Create IIS virtual directory
New-WebVirtualDirectory -Site "Default Web Site" `
    -Name "CertEnroll" `
    -PhysicalPath "C:\PKIWeb\CertEnroll"

# Enable directory browsing (helpful for troubleshooting)
Set-WebConfigurationProperty -Filter /system.webServer/directoryBrowse `
    -Name enabled -Value True `
    -PSPath "IIS:\Sites\Default Web Site\CertEnroll"

# Enable double escaping (required for delta CRLs with + character)
Set-WebConfigurationProperty -Filter /system.webServer/security/requestFiltering `
    -Name allowDoubleEscaping -Value True `
    -PSPath "IIS:\Sites\Default Web Site\CertEnroll"
```

### B. Copy Root CA Files

```powershell
# [P-WIN-SRV3]
# Create setup directory
New-Item -Path "C:\PKISetup" -ItemType Directory -Force

# Copy Root CA files here (transferred from P-WIN-ROOTCA)
# Files should be: REGINLEIF-ROOT-CA.cer, REGINLEIF-ROOT-CA.crl

# Copy to IIS web directory
Copy-Item "C:\PKISetup\REGINLEIF-ROOT-CA.cer" "C:\PKIWeb\CertEnroll\"
Copy-Item "C:\PKISetup\REGINLEIF-ROOT-CA.crl" "C:\PKIWeb\CertEnroll\"

# Verify files are accessible
Get-ChildItem "C:\PKIWeb\CertEnroll\"
```

### C. Verify HTTP Access

```powershell
# [P-WIN-SRV3]
# Test local HTTP access
Invoke-WebRequest -Uri "http://localhost/CertEnroll/REGINLEIF-ROOT-CA.cer" `
    -OutFile "$env:TEMP\test-root.cer"

# Verify certificate
certutil -dump "$env:TEMP\test-root.cer"
```

---

## 9. Publish Root CA to Active Directory

Before configuring the subordinate CA, publish the Root CA certificate to AD so all domain members trust it:

```powershell
# [P-WIN-SRV3]
# Publish Root CA certificate to AD (NTAuth and Root stores)
certutil -dspublish -f "C:\PKISetup\REGINLEIF-ROOT-CA.cer" RootCA

# Publish Root CRL to AD
certutil -dspublish -f "C:\PKISetup\REGINLEIF-ROOT-CA.crl" REGINLEIF-ROOT-CA

# Add to local machine trusted root store
certutil -addstore Root "C:\PKISetup\REGINLEIF-ROOT-CA.cer"

# Verify Root CA is published to AD
certutil -viewstore "ldap:///CN=REGINLEIF-ROOT-CA,CN=Certification Authorities,CN=Public Key Services,CN=Services,CN=Configuration,DC=reginleif,DC=io?cACertificate"
```

> [!NOTE]
> Publishing to AD automatically distributes the Root CA certificate to all domain members via Group Policy. This happens during the next GPO refresh (90 minutes by default) or immediately with `gpupdate /force`.

---

## 10. Configure Enterprise Subordinate CA

### A. CA Configuration Wizard (GUI)

1. Open **Server Manager** on P-WIN-SRV3
2. Click the **notification flag** > **Configure Active Directory Certificate Services**
3. **Credentials**: Use Domain Administrator (REGINLEIF\Administrator)
4. **Role Services**: Check **Certification Authority** only
5. **Setup Type**: Select **Enterprise CA** (AD-integrated)
6. **CA Type**: Select **Subordinate CA**
7. **Private Key**: Select **Create a new private key**
8. **Cryptography**:
   - Provider: `RSA#Microsoft Software Key Storage Provider`
   - Key length: `2048` bits (sufficient for subordinate)
   - Hash algorithm: `SHA256`
9. **CA Name**:
   - Common name: `REGINLEIF-SUB-CA`
   - Distinguished name suffix: Auto-populated from AD
10. **Certificate Request**: Select **Save a certificate request to file**
    - Path: `C:\PKISetup\REGINLEIF-SUB-CA.req`
11. **Database**: Accept defaults
12. Click **Configure**

> [!IMPORTANT]
> The wizard will show a warning that the CA is not operational. This is expected - the subordinate CA needs its certificate signed by the Root CA before it can issue certificates.

---

## 11. Sign Subordinate CA Certificate

Transfer the `.req` file to the Root CA and sign it.

### A. On Root CA (P-WIN-ROOTCA)

Power on the Root CA VM and create a directory for incoming files:

```powershell
# [P-WIN-ROOTCA]
# Create setup directory for incoming certificate requests
New-Item -Path "C:\PKISetup" -ItemType Directory -Force
```

Transfer the `.req` file from P-WIN-SRV3 to `C:\PKISetup\` on the Root CA.

**Set subordinate CA certificate validity:**

```powershell
# [P-WIN-ROOTCA]
# Set validity period for subordinate CA certificates to 10 years
certutil -setreg CA\ValidityPeriodUnits 10
certutil -setreg CA\ValidityPeriod "Years"

# Restart CA service
Restart-Service certsvc
```

**Submit and issue the certificate:**

```powershell
# [P-WIN-ROOTCA]
# Open CA console
certsrv.msc
```

**GUI Steps:**

1. Right-click **REGINLEIF-ROOT-CA** > **All Tasks** > **Submit new request...**
2. Select `C:\PKISetup\REGINLEIF-SUB-CA.req`
3. Navigate to **Pending Requests** folder
4. Right-click the pending request > **All Tasks** > **Issue**
5. Navigate to **Issued Certificates** folder
6. Double-click the issued certificate > **Details** tab > **Copy to File...**
7. Export Wizard:
   - Format: **Cryptographic Message Syntax Standard - PKCS #7 (.P7B)**
   - Check: **Include all certificates in the certification path if possible**
   - Save as: `C:\PKIExport\REGINLEIF-SUB-CA.p7b`

**Also export as CER:**

1. Double-click the certificate again > **Details** tab > **Copy to File...**
2. Format: **DER encoded binary X.509 (.CER)**
3. Save as: `C:\PKIExport\REGINLEIF-SUB-CA.cer`

### B. Update Root CA CRL

```powershell
# [P-WIN-ROOTCA]
# Publish fresh CRL
certutil -crl

# Copy new CRL to export folder
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crl" "C:\PKIExport\" -Force

# List all files for transfer
Get-ChildItem "C:\PKIExport\"
```

Transfer all files from `C:\PKIExport\` back to P-WIN-SRV3.

---

## 12. Complete Subordinate CA Installation

### A. Install Signed Certificate

```powershell
# [P-WIN-SRV3]
# Copy transferred files to PKISetup folder
# Files: REGINLEIF-SUB-CA.p7b, REGINLEIF-SUB-CA.cer, updated CRL

# Install the signed subordinate CA certificate
certutil -installcert "C:\PKISetup\REGINLEIF-SUB-CA.p7b"

# Start the CA service
Start-Service certsvc

# Verify CA is operational
certutil -ping
```

**Expected output:**

```
Connecting to P-WIN-SRV3.reginleif.io\REGINLEIF-SUB-CA ...
Server "REGINLEIF-SUB-CA" ICertRequest2 interface is alive
CertUtil: -ping command completed successfully.
```

### B. Configure CDP and AIA

Open the CA management console:

```powershell
# [P-WIN-SRV3]
certsrv.msc
```

**Configure CRL Distribution Points (CDP):**

1. Right-click **REGINLEIF-SUB-CA** > **Properties**
2. Go to **Extensions** tab
3. Select **CRL Distribution Point (CDP)**
4. Verify/configure these entries:

**Entry 1 - Local Path (keep default):**
- `C:\Windows\System32\CertSrv\CertEnroll\<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl`
- Check: **Publish CRLs to this location**
- Check: **Publish Delta CRLs to this location**

**Entry 2 - LDAP (keep default):**
- `ldap:///CN=<CATruncatedName><CRLNameSuffix>,CN=<ServerShortName>,CN=CDP,CN=Public Key Services,CN=Services,<ConfigurationContainer><CDPObjectClass>`
- Check: **Publish CRLs to this location**
- Check: **Include in CRLs. Clients use this to find Delta CRL locations.**
- Check: **Include in the CDP extension of issued certificates**

**Entry 3 - HTTP (Add new):**
- Click **Add**
- Location: `http://pki.reginleif.io/CertEnroll/<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl`
- Check: **Include in CRLs. Clients use this to find Delta CRL locations.**
- Check: **Include in the CDP extension of issued certificates**

**Configure Authority Information Access (AIA):**

1. Select **Authority Information Access (AIA)**
2. Verify/configure:

**Entry 1 - LDAP (keep default):**
- `ldap:///CN=<CATruncatedName>,CN=AIA,CN=Public Key Services,CN=Services,<ConfigurationContainer><CAObjectClass>`
- Check: **Include in the AIA extension of issued certificates**

**Entry 2 - HTTP (Add new):**
- Click **Add**
- Location: `http://pki.reginleif.io/CertEnroll/<ServerDNSName>_<CaName><CertificateName>.crt`
- Check: **Include in the AIA extension of issued certificates**

3. Click **OK** and **Yes** to restart the CA service

### C. Configure CRL Publication Interval

```powershell
# [P-WIN-SRV3]
# Set base CRL validity to 1 week
certutil -setreg CA\CRLPeriodUnits 1
certutil -setreg CA\CRLPeriod "Weeks"

# Enable Delta CRLs (published daily)
certutil -setreg CA\CRLDeltaPeriodUnits 1
certutil -setreg CA\CRLDeltaPeriod "Days"

# Set overlap period
certutil -setreg CA\CRLOverlapUnits 12
certutil -setreg CA\CRLOverlapPeriod "Hours"

# Restart CA service
Restart-Service certsvc

# Publish initial CRL
certutil -crl
```

### D. Copy CA Files to IIS

```powershell
# [P-WIN-SRV3]
# Copy subordinate CA certificate to web directory
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crt" "C:\PKIWeb\CertEnroll\" -Force

# Copy CRLs to web directory
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crl" "C:\PKIWeb\CertEnroll\" -Force

# Verify files
Get-ChildItem "C:\PKIWeb\CertEnroll\"
```

### E. Create Scheduled Task for CRL Copy

```powershell
# [P-WIN-SRV3]
# Create scheduled task to copy CRLs to IIS directory daily
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument @"
-NoProfile -Command "Copy-Item 'C:\Windows\System32\CertSrv\CertEnroll\*.crl' 'C:\PKIWeb\CertEnroll\' -Force; Copy-Item 'C:\Windows\System32\CertSrv\CertEnroll\*.crt' 'C:\PKIWeb\CertEnroll\' -Force"
"@

$trigger = New-ScheduledTaskTrigger -Daily -At "3:00 AM"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount

Register-ScheduledTask -TaskName "PKI-CRL-Copy" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description "Copy CRL and CA certificate files to IIS web directory"

# Run task immediately to verify
Start-ScheduledTask -TaskName "PKI-CRL-Copy"
Start-Sleep -Seconds 5
Get-ChildItem "C:\PKIWeb\CertEnroll\"
```

---

## 13. Certificate Templates

### A. Create Computer Authentication Template

Open the Certificate Templates console:

```powershell
# [P-WIN-SRV3]
certtmpl.msc
```

**Duplicate and customize the Computer template:**

1. Find **Computer** template > Right-click > **Duplicate Template**
2. **Compatibility** tab:
   - Certification Authority: `Windows Server 2016`
   - Certificate recipient: `Windows 10 / Windows Server 2016`
3. **General** tab:
   - Template display name: `Reginleif Computer Authentication`
   - Template name: `ReginleifComputerAuth`
   - Validity period: `1 year`
   - Renewal period: `6 weeks`
   - Check: **Publish certificate in Active Directory**
4. **Request Handling** tab:
   - Purpose: `Signature and encryption`
5. **Subject Name** tab:
   - Select: **Build from this Active Directory information**
   - Subject name format: `Common name`
   - Check: **DNS name**
   - Check: **Include e-mail name in subject name** (optional)
6. **Extensions** tab:
   - Select **Application Policies** > **Edit**
   - Verify **Client Authentication** is present (OID: 1.3.6.1.5.5.7.3.2)
7. **Security** tab:
   - Click **Add** > Type `Domain Computers` > **OK**
   - Select **Domain Computers**:
     - Check: **Read**
     - Check: **Enroll**
     - Check: **Autoenroll**
8. Click **OK** to save

### B. Create Web Server Template

1. Find **Web Server** template > Right-click > **Duplicate Template**
2. **Compatibility** tab:
   - Certification Authority: `Windows Server 2016`
   - Certificate recipient: `Windows Server 2016`
3. **General** tab:
   - Template display name: `Reginleif Web Server`
   - Template name: `ReginleifWebServer`
   - Validity period: `2 years`
   - Renewal period: `6 weeks`
4. **Request Handling** tab:
   - Purpose: `Signature and encryption`
   - Check: **Allow private key to be exported**
5. **Subject Name** tab:
   - Select: **Supply in the request**
6. **Extensions** tab:
   - Verify **Server Authentication** is present (OID: 1.3.6.1.5.5.7.3.1)
7. **Security** tab:
   - Add **Domain Admins** with **Read** and **Enroll** permissions
   - Add **Domain Computers** with **Read** and **Enroll** permissions (for server auto-requests)
8. Click **OK** to save

### C. Enable Templates on CA

```powershell
# [P-WIN-SRV3]
# Open CA console
certsrv.msc
```

1. Expand **REGINLEIF-SUB-CA**
2. Right-click **Certificate Templates** > **New** > **Certificate Template to Issue**
3. Select **Reginleif Computer Authentication** > **OK**
4. Repeat: Right-click **Certificate Templates** > **New** > **Certificate Template to Issue**
5. Select **Reginleif Web Server** > **OK**

**Verify templates are published:**

```powershell
# [P-WIN-SRV3]
# List published templates
certutil -CATemplates
```

---

## 14. Auto-Enrollment GPO

### A. Create GPO

```powershell
# [P-WIN-DC1]
# Create new GPO for certificate auto-enrollment
New-GPO -Name "Certificate Auto-Enrollment" `
    -Comment "Enables automatic certificate enrollment for domain computers"

# Link GPO to domain root (applies to all computers)
Get-GPO -Name "Certificate Auto-Enrollment" |
    New-GPLink -Target "DC=reginleif,DC=io"
```

### B. Configure Auto-Enrollment (GUI)

1. Open **Group Policy Management** (gpmc.msc)
2. Find **Certificate Auto-Enrollment** GPO > Right-click > **Edit**
3. Navigate to: **Computer Configuration** > **Policies** > **Windows Settings** > **Security Settings** > **Public Key Policies**
4. Double-click **Certificate Services Client - Auto-Enrollment**
5. Configure:
   - Configuration Model: `Enabled`
   - Check: **Renew expired certificates, update pending certificates, and remove revoked certificates**
   - Check: **Update certificates that use certificate templates**
6. Click **OK**

### C. Configure via PowerShell (Alternative)

```powershell
# [P-WIN-DC1]
# Enable auto-enrollment via registry in GPO
Set-GPRegistryValue -Name "Certificate Auto-Enrollment" `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" `
    -ValueName "AEPolicy" `
    -Type DWord `
    -Value 7

# Value breakdown:
# 1 = Enroll certificates automatically
# 2 = Renew expired, update pending, remove revoked
# 4 = Update certificates that use certificate templates
# 7 = All of the above (1+2+4)
```

---

## 15. Shutdown Root CA

With the subordinate CA operational, the Root CA should be powered off.

### A. Final CRL Publication

```powershell
# [P-WIN-ROOTCA]
# Publish final CRL before shutdown
certutil -crl

# Copy to export folder
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crl" "C:\PKIExport\" -Force
Copy-Item "C:\Windows\System32\CertSrv\CertEnroll\*.crt" "C:\PKIExport\" -Force

# List files for final transfer
Get-ChildItem "C:\PKIExport\"
```

Transfer any updated files to P-WIN-SRV3's IIS directory.

### B. Shutdown and Preserve

```powershell
# [P-WIN-ROOTCA]
# Clean shutdown
Stop-Computer -Force
```

**In Proxmox:**

1. Wait for VM to fully stop
2. Right-click VM > **Snapshot**
3. Name: `Initial-Setup-Complete`
4. Description: `Root CA configured, subordinate CA signed, CRL valid until [date + 52 weeks]`
5. Click **Take Snapshot**

> [!IMPORTANT]
> **Root CA Maintenance Schedule:**
> - Power on annually (before CRL expires) to publish new CRL
> - Power on if subordinate CA certificate needs renewal
> - Power on if subordinate CA needs to be revoked
> - Document the CRL expiration date and set a calendar reminder

---

## 16. Backup Configuration

### A. Subordinate CA Database Backup

```powershell
# [P-WIN-SRV3]
# Create backup directory
New-Item -Path "C:\CABackup" -ItemType Directory -Force

# Backup CA database and private key
# IMPORTANT: Store this password securely!
$backupPassword = ConvertTo-SecureString -String "<PASSWORD>" -AsPlainText -Force
Backup-CARoleService -Path "C:\CABackup" -Password $backupPassword -Force

# Verify backup contents
Get-ChildItem "C:\CABackup" -Recurse
```

> [!WARNING]
> The backup password protects the CA private key. Store this password securely (password manager, sealed envelope in safe). Loss of this password means inability to restore the CA from backup.

> [!IMPORTANT]
> **Security Note for Production:** The examples above use a plaintext password for lab simplicity. In production environments, consider:
> - Using Windows Credential Manager to store the password securely
> - Encrypting the password using DPAPI and storing in a protected file
> - Using a secrets management solution (e.g., Azure Key Vault, HashiCorp Vault)
> - Running the backup interactively with `Read-Host -AsSecureString` for the password

### B. Scheduled Backup Task

```powershell
# [P-WIN-SRV3]
# Create scheduled task for weekly CA backup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument @"
-NoProfile -Command "Backup-CARoleService -Path 'C:\CABackup' -Password (ConvertTo-SecureString -String '<PASSWORD>' -AsPlainText -Force) -Force"
"@

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "2:00 AM"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount

Register-ScheduledTask -TaskName "CA-Weekly-Backup" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description "Weekly backup of Certificate Authority database and private key"
```

> [!TIP]
> Consider copying backups to a separate location (file server, cloud storage) for disaster recovery. The `C:\CABackup` folder should also be included in your regular server backup routine.

---

## 17. Validation

### A. Verify CDP/AIA HTTP Accessibility

```powershell
# [Any domain-joined computer]
# Test Root CA certificate via HTTP
Invoke-WebRequest -Uri "http://pki.reginleif.io/CertEnroll/REGINLEIF-ROOT-CA.cer" `
    -OutFile "$env:TEMP\root-test.cer"
certutil -dump "$env:TEMP\root-test.cer" | Select-String "Subject:"

# Test Subordinate CA CRL via HTTP
Invoke-WebRequest -Uri "http://pki.reginleif.io/CertEnroll/REGINLEIF-SUB-CA.crl" `
    -OutFile "$env:TEMP\sub-crl-test.crl"
certutil -dump "$env:TEMP\sub-crl-test.crl" | Select-String "Issuer:"

# Test complete URL validation
certutil -verify -urlfetch "$env:TEMP\root-test.cer"
```

### B. Verify Root CA Trust

```powershell
# [Any domain-joined computer]
# Force GPO update
gpupdate /force

# Check Root CA is in Trusted Root store
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*REGINLEIF-ROOT-CA*"

# Verify via certutil
certutil -viewstore Root | Select-String "REGINLEIF"
```

### C. Test Certificate Enrollment

```powershell
# [Any domain-joined computer]
# Trigger auto-enrollment
certutil -pulse

# Request certificate manually
certreq -q -machine -enroll "Reginleif Computer Authentication"

# Verify certificate was issued
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {$_.Subject -like "*$env:COMPUTERNAME*"} |
    Select-Object Subject, Issuer, NotAfter, Thumbprint
```

**Expected output:**

```
Subject    : CN=P-WIN-DC1.reginleif.io
Issuer     : CN=REGINLEIF-SUB-CA, DC=reginleif, DC=io
NotAfter   : [date + 1 year]
Thumbprint : A1B2C3D4E5F6...
```

### D. Verify Certificate Chain

```powershell
# [Any domain-joined computer]
# Get the machine certificate
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {$_.Subject -like "*$env:COMPUTERNAME*"} |
    Select-Object -First 1

# Build and verify chain
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.Build($cert)

# Display chain
$chain.ChainElements | ForEach-Object {
    Write-Host "Certificate: $($_.Certificate.Subject)"
    Write-Host "  Issuer: $($_.Certificate.Issuer)"
    Write-Host "  Valid Until: $($_.Certificate.NotAfter)"
    Write-Host ""
}
```

**Expected chain:**

```
Certificate: CN=P-WIN-DC1.reginleif.io
  Issuer: CN=REGINLEIF-SUB-CA, DC=reginleif, DC=io
  Valid Until: [date + 1 year]

Certificate: CN=REGINLEIF-SUB-CA, DC=reginleif, DC=io
  Issuer: CN=REGINLEIF-ROOT-CA, DC=reginleif, DC=io
  Valid Until: [date + 10 years]

Certificate: CN=REGINLEIF-ROOT-CA, DC=reginleif, DC=io
  Issuer: CN=REGINLEIF-ROOT-CA, DC=reginleif, DC=io
  Valid Until: [date + 20 years]
```

### E. Validation Checklist

**Root CA (P-WIN-ROOTCA):**
- [ ] Root CA certificate generated (20-year validity)
- [ ] Root CA CRL published (52-week validity)
- [ ] Root CA certificate exported and available at HTTP endpoint
- [ ] Root CA published to AD (trusted by all domain members)
- [ ] Windows Firewall rule configured (Allow P-WIN-SRV3)
- [ ] Windows Update service disabled
- [ ] Root CA VM snapshot created
- [ ] Root CA VM powered off

**Subordinate CA (P-WIN-SRV3):**
- [ ] AD CS role installed
- [ ] IIS role installed
- [ ] Windows Firewall rule configured (Allow Lab Subnets - All)
- [ ] Subordinate CA certificate signed by Root CA (10-year validity)
- [ ] CA service running (`certutil -ping` succeeds)
- [ ] CDP configured (LDAP + HTTP)
- [ ] AIA configured (LDAP + HTTP)
- [ ] CRL published and accessible via HTTP
- [ ] Delta CRL published
- [ ] CRL copy scheduled task configured
- [ ] CA backup scheduled task configured

**Certificate Templates:**
- [ ] Reginleif Computer Authentication template created
- [ ] Reginleif Web Server template created
- [ ] Both templates enabled on CA

**Auto-Enrollment:**
- [ ] GPO created and linked to domain
- [ ] Auto-enrollment settings enabled
- [ ] Test computer receives certificate automatically

**DNS:**
- [ ] `pki.reginleif.io` resolves to 172.16.20.13

---

## Network Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PKI Infrastructure - reginleif.io                        │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  P-WIN-ROOTCA (172.16.20.15) - OFFLINE                                      │
│  Standalone Root CA                                                          │
│  ├─ REGINLEIF-ROOT-CA                                                       │
│  ├─ 20-year validity                                                        │
│  ├─ 52-week CRL (annual renewal)                                            │
│  └─ RSA 4096-bit / SHA256                                                   │
│                                                                              │
│  Status: Powered OFF (Proxmox snapshot preserved)                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Signs (one-time)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  VLAN 20 - Servers (172.16.20.0/24)                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  P-WIN-SRV3 (172.16.20.13)                                             │ │
│  │  ├─ Enterprise Subordinate CA (REGINLEIF-SUB-CA)                       │ │
│  │  │   ├─ 10-year validity                                               │ │
│  │  │   ├─ 1-week CRL (LDAP + HTTP)                                       │ │
│  │  │   └─ RSA 2048-bit / SHA256                                          │ │
│  │  └─ IIS Web Server (CRL/AIA Distribution)                              │ │
│  │      └─ http://pki.reginleif.io/CertEnroll/                            │ │
│  │          ├─ REGINLEIF-ROOT-CA.cer                                      │ │
│  │          ├─ REGINLEIF-ROOT-CA.crl                                      │ │
│  │          ├─ REGINLEIF-SUB-CA.crl                                       │ │
│  │          └─ P-WIN-SRV3.reginleif.io_REGINLEIF-SUB-CA.crt              │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
           │                                           │
           │ RPC/DCOM                                  │ HTTP :80
           │ Certificate Enrollment                    │ CRL/AIA Distribution
           ▼                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  VLAN 5 - Infrastructure                  VLAN 10 - Clients                 │
│  172.16.5.0/24 (HQ)                       172.16.10.0/24 (HQ)               │
│  172.17.5.0/24 (Branch)                   172.17.10.0/24 (Branch)           │
│                                                                              │
│  P-WIN-DC1 (172.16.5.10)                  Domain Workstations               │
│  H-WIN-DC2 (172.17.5.10)                  └─ Auto-enrollment via GPO        │
│  └─ GPO: Certificate Auto-Enrollment          for Computer Authentication   │
│      └─ Distributes Root CA trust             certificates                  │
│      └─ Enables auto-enrollment                                             │
└─────────────────────────────────────────────────────────────────────────────┘

Certificate Templates Published:
┌─────────────────────────────────────────────────────────────────────────────┐
│  Template                        │ Purpose            │ Auto-Enroll        │
│  ────────────────────────────────┼────────────────────┼─────────────────── │
│  Reginleif Computer Authentication│ 802.1X/EAP-TLS    │ Yes (Domain Comps) │
│  Reginleif Web Server            │ Internal HTTPS     │ No (Manual)        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Cross-Site Considerations

The PKI infrastructure is hosted at HQ (P-WIN-SRV3 on VLAN 20). Branch site clients can access PKI services via the WireGuard site-to-site VPN established in Project 7.

**Branch Site Access:**

- **Certificate Enrollment:** Branch computers connect to P-WIN-SRV3 via RPC/DCOM through the VPN tunnel for auto-enrollment
- **CRL/AIA Distribution:** HTTP requests to `pki.reginleif.io` (172.16.20.13) traverse the VPN
- **DNS Resolution:** Branch DNS (H-WIN-DC2) forwards queries to HQ DNS (P-WIN-DC1), which resolves `pki.reginleif.io`

> [!NOTE]
> If Branch site experiences connectivity issues to the PKI server, verify:
> 1. WireGuard VPN tunnel is active (Project 7)
> 2. Firewall rules permit traffic from Branch VLANs (172.17.x.x) to HQ Servers VLAN (172.16.20.x)
> 3. DNS forwarders are configured correctly (Project 11)

---

## Troubleshooting

### Certificate Enrollment Fails

**Symptom:** `certreq` returns error or no certificate appears.

**Check:**
```powershell
# Verify CA is reachable
certutil -ping

# Check template permissions
certutil -CATemplates | findstr "Reginleif"

# View enrollment errors
Get-WinEvent -LogName "Application" -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-CertificationAuthority']]]" -MaxEvents 10
```

### CRL Check Fails

**Symptom:** Certificate validation fails with CRL errors.

**Check:**
```powershell
# Test HTTP CRL access
Invoke-WebRequest "http://pki.reginleif.io/CertEnroll/REGINLEIF-SUB-CA.crl"

# Verify CRL is current
certutil -dump "C:\PKIWeb\CertEnroll\REGINLEIF-SUB-CA.crl" | Select-String "Next Update"

# Force CRL republish
certutil -crl
Start-ScheduledTask -TaskName "PKI-CRL-Copy"
```

### Root CA Not Trusted

**Symptom:** Certificate chain cannot be built, Root CA not in trust store.

**Check:**
```powershell
# Verify Root CA in AD
certutil -viewstore "ldap:///CN=Certification Authorities,CN=Public Key Services,CN=Services,CN=Configuration,DC=reginleif,DC=io"

# Force GPO update
gpupdate /force

# Manually add to trust store (temporary fix)
certutil -addstore Root "C:\PKIWeb\CertEnroll\REGINLEIF-ROOT-CA.cer"
```
