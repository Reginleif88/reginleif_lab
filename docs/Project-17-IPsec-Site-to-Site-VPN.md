---
title: "Project 17: IPsec Site-to-Site VPN with Certificate Authentication"
tags: [ipsec, vpn, pki, certificate, opnsense, ikev2, site-to-site]
sites: [hq, branch]
status: planned
---

## Goal

Replace the WireGuard site-to-site VPN (Project 7) with **IPsec IKEv2** using **certificate-based authentication** from the internal PKI (Project 13). This provides enterprise-grade encryption with PKI-managed identity, eliminating pre-shared key management.

WireGuard remains in use for road warrior/client VPN access (Project 9).

---

## Background

### Why IPsec for Site-to-Site?

| Aspect | WireGuard | IPsec IKEv2 |
|:-------|:----------|:------------|
| **Code complexity** | ~4,000 lines | ~400,000 lines (strongSwan) |
| **Enterprise adoption** | Growing | Universal (Cisco, Fortinet, Palo Alto) |
| **Certificate auth** | Possible but uncommon | Native, industry standard |
| **Interoperability** | WireGuard-to-WireGuard only | Any IPsec-compliant device |
| **Compliance** | Limited audit trail | FIPS 140-2 certified options |
| **Configuration** | Simple | Complex (but more flexible) |

**Hybrid approach:** Use IPsec for infrastructure (site-to-site, where interoperability and PKI matter) and WireGuard for users (road warriors, where simplicity matters).

### IKEv2 Protocol Overview

IPsec negotiates two types of Security Associations (SAs):

1. **Phase 1 (IKE SA):** Authenticates peers and establishes encrypted control channel
   - Mutual authentication via certificates (or PSK)
   - Negotiates encryption, hash, and DH group
   - Lifetime: 8 hours (28800 seconds) typical

2. **Phase 2 (Child SA / ESP):** Protects actual data traffic
   - Negotiates encryption for user data
   - Defines traffic selectors (which subnets use this tunnel)
   - Lifetime: 1 hour (3600 seconds) typical
   - Perfect Forward Secrecy (PFS) renegotiates DH keys

### Certificate-Based Authentication Benefits

| Pre-Shared Key (PSK) | Certificates (PKI) |
|:---------------------|:-------------------|
| Shared secret on both ends | Unique identity per device |
| Manual rotation required | Automatic expiry and renewal |
| Compromised PSK affects all tunnels | Compromised cert affects one device |
| No identity verification | CA validates device identity |
| No revocation mechanism | CRL/OCSP for immediate revocation |

---

## Prerequisites

**Required infrastructure:**
- P-WIN-SRV3 (172.16.20.13) - Enterprise Subordinate CA operational
- P-WIN-ROOTCA - Root CA certificate exported
- OPNsenseHQ (192.168.1.240) - Accessible via web interface
- OPNsenseBranch (192.168.1.245) - Accessible via web interface
- DNS resolution for `pki.reginleif.io` from both OPNsense firewalls

---

## Firewall Requirements

> [!NOTE]
> If you implemented the permissive `Trusted_Lab_Networks` firewall rule in Project 11, IPsec traffic is already permitted. The rules below document what is required for production environments.

**Required firewall rules for IPsec (WAN interface):**

| Protocol | Port | Source | Destination | Purpose |
|:---------|:-----|:-------|:------------|:--------|
| UDP | 500 | Remote WAN IP | WAN address | IKE negotiation |
| UDP | 4500 | Remote WAN IP | WAN address | NAT Traversal (NAT-T) |
| ESP | - | Remote WAN IP | WAN address | Encrypted payload (protocol 50) |

> [!TIP]
> ESP is IP protocol 50, not a port number. In OPNsense, select "ESP" as the protocol type rather than TCP or UDP.

---

## 1. Certificate Preparation

### A. Create IPsec Gateway Certificate Template

The existing certificate templates ("Reginleif Computer Authentication" and "Reginleif Web Server") are not suitable for IPsec because:
- Computer Authentication is for auto-enrollment of domain-joined machines
- Web Server only has Server Authentication EKU

IPsec requires both **Server Authentication** and **Client Authentication** EKUs for mutual authentication.

**On P-WIN-SRV3 (Subordinate CA):**

```powershell
# [P-WIN-SRV3]
# Open Certificate Templates console
certtmpl.msc
```

1. **Find the "Web Server" template** in the list
2. **Right-click > Duplicate Template**
3. **General tab:**
   - Template display name: `Reginleif IPsec Gateway`
   - Template name: `ReginleifIPsecGateway`
   - Validity period: `2 years`
   - Renewal period: `6 weeks`

4. **Request Handling tab:**
   - Purpose: `Signature and encryption`
   - Check: `Allow private key to be exported`

5. **Cryptography tab:**
   - Provider Category: `Key Storage Provider`
   - Algorithm name: `RSA`
   - Minimum key size: `2048`
   - Request hash: `SHA256`

6. **Extensions tab:**
   - Select **Application Policies** > Edit
   - Remove existing policies
   - Add: `Server Authentication` (1.3.6.1.5.5.7.3.1)
   - Add: `Client Authentication` (1.3.6.1.5.5.7.3.2)

7. **Subject Name tab:**
   - Select: `Supply in the request`
   - Check: `Use subject information from existing certificates for autoenrollment renewal requests`

8. **Security tab:**
   - Add: `Domain Admins` with `Read` and `Enroll` permissions

9. **Click OK** to save the template

**Publish the template:**

```powershell
# [P-WIN-SRV3]
# Open Certification Authority console
certsrv.msc
```

1. Expand **REGINLEIF-SUB-CA**
2. Right-click **Certificate Templates > New > Certificate Template to Issue**
3. Select **Reginleif IPsec Gateway**
4. Click **OK**

---

### B. Request HQ Gateway Certificate

Since OPNsense is not domain-joined, we must create a manual certificate request.

**On P-WIN-DC1 or any domain-joined workstation:**

1. **Open MMC:** `mmc.exe`
2. **File > Add/Remove Snap-in > Certificates > Computer account > Local computer**
3. **Right-click Personal > All Tasks > Request New Certificate**
4. **Select:** Active Directory Enrollment Policy
5. **Select:** Reginleif IPsec Gateway template
6. Click **"More information is required"** link

**Configure certificate properties:**

| Field | Value |
|:------|:------|
| **Subject name type** | Common name |
| **Common name value** | `ipsec.hq.reginleif.io` |
| **Alternative name (DNS)** | `opnsense-hq.reginleif.io` |
| **Alternative name (IP)** | `192.168.1.240` |

7. **Click OK > Enroll**

---

### C. Request Branch Gateway Certificate

Repeat the same process for the Branch firewall:

| Field | Value |
|:------|:------|
| **Common name** | `ipsec.branch.reginleif.io` |
| **Alternative name (DNS)** | `opnsense-branch.reginleif.io` |
| **Alternative name (IP)** | `192.168.1.245` |

---

### D. Export Certificates as PKCS#12

OPNsense requires certificates with private keys in PKCS#12 (.p12/.pfx) format.

**For each certificate (HQ and Branch):**

1. **In MMC Certificates snap-in:** Personal > Certificates
2. **Right-click the certificate > All Tasks > Export**
3. **Export Private Key:** Yes, export the private key
4. **Format:** Personal Information Exchange - PKCS #12 (.PFX)
   - Check: `Include all certificates in the certification path if possible`
   - Check: `Export all extended properties`
5. **Password:** Set a strong password (you'll need this when importing to OPNsense)
6. **Filename:** `ipsec-hq.pfx` or `ipsec-branch.pfx`

**Also export the CA certificates (without private keys):**

```powershell
# [P-WIN-SRV3]
# The Root CA certificate (REGINLEIF-ROOT-CA.cer) must be retrieved from the
# offline Root CA machine, as mentioned in the prerequisites.

# Export the Subordinate CA certificate from P-WIN-SRV3:
certutil -ca.cert C:\Certs\REGINLEIF-SUB-CA.cer
```

**Transfer files to OPNsense:**
- Use SCP, WinSCP, or copy via the OPNsense web interface
- Files needed on each OPNsense:
  - `REGINLEIF-ROOT-CA.cer`
  - `REGINLEIF-SUB-CA.cer`
  - `ipsec-hq.pfx` (HQ only)
  - `ipsec-branch.pfx` (Branch only)

---

## 2. OPNsenseHQ Configuration

### A. Import PKI Components

**Navigate to:** System > Trust > Authorities

1. **Import Root CA:**
   - Click **+ Add**
   - Descriptive name: `REGINLEIF-ROOT-CA`
   - Method: `Import an existing Certificate Authority`
   - Certificate data: Paste contents of `REGINLEIF-ROOT-CA.cer` (or upload file)
   - Click **Save**

2. **Import Subordinate CA:**
   - Click **+ Add**
   - Descriptive name: `REGINLEIF-SUB-CA`
   - Method: `Import an existing Certificate Authority`
   - Certificate data: Paste contents of `REGINLEIF-SUB-CA.cer`
   - Click **Save**

**Navigate to:** System > Trust > Certificates

3. **Import HQ Gateway Certificate:**
   - Click **+ Add**
   - Method: `Import an existing Certificate`
   - Descriptive name: `ipsec.hq.reginleif.io`
   - PKCS#12 file: Upload `ipsec-hq.pfx`
   - PKCS#12 password: Enter the password you set during export
   - Click **Save**

**Verify the certificate shows:**
- Valid dates
- Issuer: REGINLEIF-SUB-CA
- Purpose: Server Authentication, Client Authentication

---

### B. Configure Phase 1 (IKE)

**Navigate to:** VPN > IPsec > Connections

> [!NOTE]
> OPNsense has both "Tunnel Settings [Legacy]" and the newer "Connections" interface. Use **Connections** for IKEv2 with certificates.

1. **Click + Add**
2. **General Settings:**

| Setting | Value |
|:--------|:------|
| Enabled | Checked |
| Description | `Branch-Site-IPsec` |
| Local addresses | Leave empty (uses WAN) |
| Remote addresses | `192.168.1.245` |
| Connection mode | `IKEv2` |

3. **Authentication Settings (Local):**

| Setting | Value |
|:--------|:------|
| Authentication | `Certificate` |
| Certificate | `ipsec.hq.reginleif.io` |
| ID type | `Distinguished name` or `IP address` |
| ID value | Leave empty (auto from certificate) |

4. **Authentication Settings (Remote):**

| Setting | Value |
|:--------|:------|
| Authentication | `Certificate` |
| Remote Certificate Authorities | `REGINLEIF-SUB-CA` |
| ID type | `Distinguished name` or `IP address` |

5. **Proposals (Phase 1):**

| Setting | Value |
|:--------|:------|
| Encryption algorithms | `AES-GCM-256` with 128-bit ICV |
| Hash algorithms | `SHA512` |
| DH Key Groups | `21 (ecp521)` or `19 (ecp256)` |
| Key lifetime | `28800` seconds (8 hours) |

6. **Advanced Settings:**

| Setting | Value |
|:--------|:------|
| Dead Peer Detection | Enabled |
| DPD delay | `60` seconds |
| DPD timeout | `180` seconds |

7. **Click Save**

---

### C. Configure Phase 2 (Child SA)

Phase 2 defines which traffic flows through the tunnel. Create entries for each subnet pair.

**Navigate to:** VPN > IPsec > Connections > [Branch-Site-IPsec] > Children

For each VLAN pair, add a Child SA:

**Example: Infrastructure VLAN (5)**

| Setting | Value |
|:--------|:------|
| Enabled | Checked |
| Description | `VLAN5-Infrastructure` |
| Mode | `Tunnel` |
| Local networks | `172.16.5.0/24` |
| Remote networks | `172.17.5.0/24` |
| Encryption algorithms | `AES-GCM-256` |
| PFS Key Groups | `21 (ecp521)` |
| Key lifetime | `3600` seconds (1 hour) |

**Repeat for remaining VLANs:**

| Child SA | Local Network | Remote Network |
|:---------|:--------------|:---------------|
| VLAN5-Infrastructure | 172.16.5.0/24 | 172.17.5.0/24 |
| VLAN10-Clients | 172.16.10.0/24 | 172.17.10.0/24 |
| VLAN20-Servers | 172.16.20.0/24 | 172.17.20.0/24 |
| VLAN99-Management | 172.16.99.0/24 | 172.17.99.0/24 |

> [!TIP]
> For full mesh connectivity (any HQ VLAN to any Branch VLAN), you would need 16 Child SAs (4x4). For simpler configurations, create SAs only for matching VLANs (4 total).

---

### D. Configure Firewall Rules

**Navigate to:** Firewall > Rules > WAN

Create rules to allow IPsec traffic from the Branch site:

1. **IKE (UDP 500):**
   - Action: Pass
   - Protocol: UDP
   - Source: `192.168.1.245` (single host)
   - Destination: `WAN address`
   - Destination port: `500`
   - Description: `Allow IPsec IKE from Branch`

2. **NAT-T (UDP 4500):**
   - Action: Pass
   - Protocol: UDP
   - Source: `192.168.1.245`
   - Destination: `WAN address`
   - Destination port: `4500`
   - Description: `Allow IPsec NAT-T from Branch`

3. **ESP (Protocol 50):**
   - Action: Pass
   - Protocol: `ESP`
   - Source: `192.168.1.245`
   - Destination: `WAN address`
   - Description: `Allow IPsec ESP from Branch`

**Navigate to:** Firewall > Rules > IPsec

Create a rule to allow traffic through the tunnel:

- Action: Pass
- Protocol: Any
- Source: `Trusted_Lab_Networks` (alias)
- Destination: `Trusted_Lab_Networks`
- Description: `Allow inter-site traffic via IPsec`

---

## 3. OPNsenseBranch Configuration

Mirror the HQ configuration with swapped values.

### A. Import PKI Components

Same process as HQ:
1. Import Root CA (REGINLEIF-ROOT-CA)
2. Import Subordinate CA (REGINLEIF-SUB-CA)
3. Import Branch certificate (`ipsec-branch.pfx`)

### B. Configure Phase 1 (IKE)

| Setting | HQ Value | Branch Value |
|:--------|:---------|:-------------|
| Remote addresses | 192.168.1.245 | **192.168.1.240** |
| Certificate | ipsec.hq.reginleif.io | **ipsec.branch.reginleif.io** |
| Description | Branch-Site-IPsec | **HQ-Site-IPsec** |

All other Phase 1 settings remain identical.

### C. Configure Phase 2 (Child SA)

Swap local and remote networks:

| Child SA | Local Network | Remote Network |
|:---------|:--------------|:---------------|
| VLAN5-Infrastructure | **172.17.5.0/24** | **172.16.5.0/24** |
| VLAN10-Clients | **172.17.10.0/24** | **172.16.10.0/24** |
| VLAN20-Servers | **172.17.20.0/24** | **172.16.20.0/24** |
| VLAN99-Management | **172.17.99.0/24** | **172.16.99.0/24** |

### D. Configure Firewall Rules

Same rules as HQ, but source IP is `192.168.1.240`.

---

## 4. Migration from WireGuard

### A. Pre-Migration Checklist

Before starting migration, verify:

- [ ] PKI certificates issued and tested for both OPNsense firewalls
- [ ] IPsec Phase 1 configuration documented (not yet applied)
- [ ] Backup of WireGuard configuration exported from both firewalls
- [ ] Console access available (SSH or physical) in case web interface becomes unreachable
- [ ] Maintenance window scheduled (AD replication may be briefly interrupted)

### B. Parallel Testing

Run both VPNs simultaneously to validate IPsec without disrupting production traffic.

1. **Apply IPsec configuration** on both OPNsense firewalls
2. **Create Phase 2 for test subnet only** (e.g., VLAN 99 Management)
3. **Do NOT create Phase 2 entries for VLANs currently on WireGuard**
4. **Verify Phase 1 establishes:**

   ```
   # OPNsense Shell (via SSH or console)
   ipsec statusall
   ```

   Expected output shows `IKE_SA ... ESTABLISHED`

5. **Test connectivity** through IPsec (from Management VLAN):

   ```powershell
   # From a device on 172.16.99.x
   Test-NetConnection -ComputerName 172.17.99.11 -Port 445
   ```

### C. Cutover Procedure

Migrate one VLAN pair at a time:

1. **On OPNsenseHQ:** VPN > WireGuard > Peers > Branch_Peer
   - Remove `172.17.5.0/24` from Allowed IPs
   - Save and Apply

2. **On OPNsenseHQ:** VPN > IPsec > Connections > Branch-Site-IPsec > Children
   - Create Child SA for VLAN 5 (172.16.5.0/24 <-> 172.17.5.0/24)
   - Save and Apply

3. **On OPNsenseBranch:** Repeat for WireGuard and IPsec

4. **Verify connectivity:**

   ```powershell
   # From P-WIN-DC1 (172.16.5.10)
   Test-NetConnection -ComputerName 172.17.5.10 -Port 389

   # Check AD replication
   repadmin /replsummary
   ```

5. **Repeat for remaining VLANs:** 10, 20, 99

### D. Cleanup

After all VLANs are migrated to IPsec:

1. **Disable WireGuard S2S instance** (keep road warrior instance!):
   - VPN > WireGuard > Instances
   - Uncheck "Enabled" on the HQ_Instance that has Branch peer
   - Or remove only the Branch peer from the instance

2. **Remove Branch peer from WireGuard:**
   - VPN > WireGuard > Peers
   - Delete the Branch_Peer entry

3. **Update Trusted_Lab_Networks alias:**
   - Remove `10.200.0.2/32` (Branch tunnel IP no longer needed)
   - Keep `10.200.0.0/24` for road warrior clients

4. **Verify road warrior VPN still works** (if applicable)

### E. Rollback Procedure

If IPsec fails and connectivity is lost:

1. **Re-enable WireGuard instance:**
   - VPN > WireGuard > Instances > Check "Enabled"

2. **Restore Branch peer Allowed IPs:**
   - Add back all Branch subnets to the peer's Allowed IPs

3. **Disable IPsec Phase 2 entries:**
   - VPN > IPsec > Connections > Branch-Site-IPsec > Children
   - Uncheck "Enabled" on all Child SAs

4. **Verify WireGuard connectivity restored:**
   - Ping between DCs
   - Check AD replication

---

## 5. Validation

### A. IPsec Status Verification

**OPNsense Web Interface:**

1. Navigate to: VPN > IPsec > Status Overview
2. Verify:
   - Phase 1 shows "Established"
   - Phase 2 entries show "Installed" with bytes in/out

**OPNsense Shell:**

```bash
# Connect via SSH or console
ipsec statusall
```

Expected output:
```
Branch-Site-IPsec: IKEv2
  ESTABLISHED 5 minutes ago, 192.168.1.240[CN=ipsec.hq.reginleif.io]...192.168.1.245[CN=ipsec.branch.reginleif.io]
  local: [CN=ipsec.hq.reginleif.io] uses certificate "ipsec.hq.reginleif.io"
  remote: [CN=ipsec.branch.reginleif.io] uses certificate "ipsec.branch.reginleif.io"
  AES_GCM_256, SHA512, ECP521
```

### B. Connectivity Tests

**From P-WIN-DC1 (172.16.5.10):**

```powershell
# Basic connectivity
Test-NetConnection -ComputerName 172.17.5.10

# LDAP (AD replication)
Test-NetConnection -ComputerName 172.17.5.10 -Port 389

# DNS
Resolve-DnsName H-WIN-DC2.reginleif.io

# AD Replication
repadmin /replsummary
repadmin /showrepl

# All VLANs
Test-NetConnection -ComputerName 172.17.10.1  # Branch Clients gateway
Test-NetConnection -ComputerName 172.17.20.1  # Branch Servers gateway
Test-NetConnection -ComputerName 172.17.99.1  # Branch Management gateway
```

### C. Certificate Validation

Verify certificates are correctly validated:

```bash
# OPNsense shell
ipsec listcerts

# Should show:
# - ipsec.hq.reginleif.io (local)
# - ipsec.branch.reginleif.io (remote)
# - REGINLEIF-SUB-CA (issuer)
# - REGINLEIF-ROOT-CA (root)
```

### D. Validation Checklist

- [ ] Phase 1 (IKE SA) established between HQ and Branch
- [ ] Phase 2 (Child SA) established for all VLAN pairs (5, 10, 20, 99)
- [ ] Firewall rules allow UDP 500, UDP 4500, ESP on both sites
- [ ] Ping between P-WIN-DC1 (172.16.5.10) and H-WIN-DC2 (172.17.5.10) succeeds
- [ ] AD replication shows no errors (`repadmin /replsummary`)
- [ ] DNS cross-site resolution works (`Resolve-DnsName` from both sites)
- [ ] All VLAN pairs can communicate through the IPsec tunnel
- [ ] WireGuard road warrior VPN still functions (Project 9)
- [ ] WireGuard S2S disabled/removed
- [ ] Certificate chain validates correctly (Root CA → Sub CA → Gateway cert)
- [ ] CRL is accessible from OPNsense (`http://pki.reginleif.io/CertEnroll/`)

---

## Network Diagram

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    Home Network                         │
                    │                   192.168.1.0/24                        │
                    └────────────┬──────────────────────────┬─────────────────┘
                                 │                          │
                    ┌────────────┴────────────┐  ┌─────────┴────────────┐
                    │      OPNsenseHQ         │  │    OPNsenseBranch    │
                    │    192.168.1.240        │  │    192.168.1.245     │
                    │  cert: ipsec.hq.*       │  │  cert: ipsec.branch.*│
                    └────────────┬────────────┘  └─────────┬────────────┘
                                 │                          │
                                 │    IPsec IKEv2 Tunnel    │
                                 │  ═══════════════════════ │
                                 │   UDP 500, 4500 + ESP    │
                                 │  Mutual RSA (PKI certs)  │
                                 │                          │
              ┌──────────────────┴──────────────────┐       │
              │           HQ Site VLANs             │       │
              │  VLAN 5:  172.16.5.0/24  (Infra)   │       │
              │  VLAN 10: 172.16.10.0/24 (Clients) │       │
              │  VLAN 20: 172.16.20.0/24 (Servers) │       │
              │  VLAN 99: 172.16.99.0/24 (Mgmt)    │       │
              └─────────────────────────────────────┘       │
                                                            │
                              ┌──────────────────────────────┴──────────────────┐
                              │             Branch Site VLANs                   │
                              │  VLAN 5:  172.17.5.0/24  (Infra)               │
                              │  VLAN 10: 172.17.10.0/24 (Clients)             │
                              │  VLAN 20: 172.17.20.0/24 (Servers)             │
                              │  VLAN 99: 172.17.99.0/24 (Mgmt)                │
                              └─────────────────────────────────────────────────┘


    Road Warrior VPN (WireGuard - unchanged from Project 9):

    Admin PC ─────── WireGuard ───────► OPNsenseHQ ───► Management VLANs only
    10.200.0.10         UDP 51820        10.200.0.1      172.16.99.0/24
                                                         172.17.99.0/24 (via IPsec)
```

---

## Troubleshooting

### Phase 1 (IKE) Failures

| Symptom | Possible Cause | Solution |
|:--------|:---------------|:---------|
| "No proposal chosen" | Crypto mismatch | Verify both sides have identical encryption, hash, DH group |
| "Certificate validation failed" | Missing CA | Import both Root CA and Sub CA |
| "Peer not responding" | Firewall blocking | Check UDP 500 is open on WAN |
| "Authentication failed" | Wrong certificate | Verify correct certificate is selected |

**Debug commands:**

```bash
# OPNsense shell
ipsec statusall
swanctl --log
tail -f /var/log/ipsec.log
```

### Phase 2 (ESP) Failures

| Symptom | Possible Cause | Solution |
|:--------|:---------------|:---------|
| "No proposal chosen" | PFS mismatch | Match PFS group on both sides |
| "Traffic selector mismatch" | Subnet typo | Verify local/remote networks match |
| Phase 1 up, Phase 2 down | No traffic | Send ping to trigger SA negotiation |

### Certificate Issues

| Symptom | Possible Cause | Solution |
|:--------|:---------------|:---------|
| "Unable to verify certificate" | CRL unreachable | Verify `http://pki.reginleif.io/` accessible |
| "Certificate expired" | Validity period | Re-issue certificate from CA |
| "Chain incomplete" | Missing intermediate | Import Sub CA as well as Root CA |

**Verify certificate chain:**

```bash
# OPNsense shell
openssl verify -CAfile /path/to/chain.pem /path/to/gateway.pem
```

### Traffic Not Flowing

1. **Check Security Associations:**
   ```bash
   ipsec statusall | grep CHILD_SA
   ```

2. **Check Firewall Rules:**
   - Is IPsec interface rule permitting traffic?
   - Is there a floating rule blocking traffic?

3. **Check Routing:**
   ```bash
   netstat -rn | grep 172.17
   ```

4. **Packet capture:**
   - Diagnostics > Packet Capture
   - Interface: IPsec (enc0)
   - Verify packets are being encrypted/decrypted

---

## Summary

This project demonstrates enterprise VPN architecture:

1. **IPsec IKEv2 for site-to-site:** Industry-standard protocol for infrastructure connectivity
2. **PKI-based authentication:** Certificates eliminate PSK management overhead
3. **WireGuard for users:** Simpler protocol retained for road warrior access
4. **Controlled migration:** Parallel operation and rollback capability

The hybrid approach (IPsec + WireGuard) reflects real-world enterprise patterns where different VPN technologies serve different use cases.
