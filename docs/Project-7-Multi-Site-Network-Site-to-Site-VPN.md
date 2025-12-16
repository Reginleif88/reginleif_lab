---
title: "Project 7: Multi-Site Network (Site-to-Site VPN)"
tags: [vpn, integration, opnsense, proxmox, hyper-v, active-directory]
sites: [hq, branch]
status: completed
---

## Goal

Simulate a corporate **"Headquarters vs. Branch"** topology. Connect the Proxmox environment (HQ) and Hyper-V environment (Branch) via an encrypted **WireGuard Site-to-Site VPN** to allow secure Active Directory replication and transparent routing between sites.

---

## Background & Concepts

📚 **[View Background & Concepts](/concepts/project-07-concepts)**

For educational context about VPNs, WireGuard, NAT traversal, and cryptokey routing, see the dedicated concepts guide.

---

> [!NOTE]
> **Pre-VLAN Addressing:** This project uses flat network addressing (`172.16.0.0/24` for HQ, `172.17.0.0/24` for Branch). After VLAN segmentation in Project 11:
> - HQ gateway moves from `172.16.0.1` to VLAN-specific addresses (e.g., `172.16.5.1`)
> - Branch gateway moves from `172.17.0.1` to VLAN-specific addresses (e.g., `172.17.5.1`)
> - The `Trusted_Lab_Networks` alias is updated to include all VLAN subnets

## 1. Architecture Design

### Topology Overview

| Feature               | Site A (HQ)                   | Site B (Branch)               |
| :-------------------- | :---------------------------- | :---------------------------- |
| **Hypervisor**        | Proxmox VE                    | Windows Hyper-V               |
| **Gateway VM**        | OPNsenseHQ                    | OPNsenseBranch                |
| **WAN IP**            | `192.168.1.240` (Home LAN)    | `192.168.1.245` (Home LAN)    |
| **LAN Subnet**        | **`172.16.0.0/24`**           | **`172.17.0.0/24`**           |
| **Gateway IP**        | `172.16.0.1`                  | `172.17.0.1`                  |
| **Domain Controller** | `P-WIN-DC1` (`172.16.0.10`)   | `H-WIN-DC2` (`172.17.0.10`)   |

---

## 2. OPNsense Configuration

### A. Interface Assignments

1. **OPNsenseHQ:**
    * **WAN:** `vtnet0` (Bridged to Home Network/vmbr0).
    * **LAN:** `vtnet1` (Static `172.16.0.1/24`).
2. **OPNsenseBranch:**
    * **WAN:** `hn0` (Bridged to Physical NIC/Default Switch).
    * **LAN:** `hn1` (Static `172.17.0.1/24`).

### B. WireGuard VPN Setup

**Pre-requisite:** `os-wireguard` is installed by default on modern OPNsense

---

### Step 0: Create Firewall Alias (Both Sites)

Before configuring WireGuard, create an alias to represent all trusted lab networks. This follows enterprise best practices for zone-based firewall management and will be used in firewall rules throughout this project.

**On both OPNsenseHQ and OPNsenseBranch:**

1. **Navigate to:** Firewall > Aliases
2. **Add New Alias:**
   * **Name:** `Trusted_Lab_Networks`
   * **Type:** Network(s)
   * **Content:**
     * `172.16.0.0/24` (HQ LAN)
     * `172.17.0.0/24` (Branch LAN)
     * `10.200.0.0/24` (WireGuard Tunnel)
   * **Description:** All trusted internal networks for inter-site communication
3. **Click Save**
4. **Click Apply**

> **Why use an alias?** In enterprise environments, firewall rules reference aliases (or "address groups") rather than hardcoded subnets. This makes rules easier to audit, update, and maintain. When you add a new site or VPN subnet, you update the alias once rather than modifying multiple rules.

> [!NOTE]
> **Permissive Firewall Rules:** This project uses broad "allow any" rules between trusted networks for simplicity during initial setup. These permissive rules will be replaced with granular, service-specific port rules in **Project 18: Firewall Hardening**.

---

### Step 1: HQ Configuration (The Server)

**Navigate to OPNsenseHQ (`172.16.0.1`) Web Interface:**

1. **VPN > WireGuard > Instances > Add**

2. **Configure Local Instance (HQ's WireGuard Interface):**
   * **Enabled:** ✓
   * **Name:** `HQ_Instance`
   * **Public Key:** Click **Generate** button - this will auto-populate both Public and Private keys
     * **Save this Public Key** - you'll need to paste it into the Branch configuration later
   * **Private Key:** Auto-generated when you clicked Generate
   * **Listen Port:** `51820`
     * This is the standard WireGuard port
     * Must match the port you open in firewall rules
   * **Tunnel Address:** `10.200.0.1/24`
     * This is HQ's virtual IP address inside the WireGuard tunnel
     * The `/24` represents the entire VPN subnet - this ensures OPNsense creates proper routing table entries
     * Both HQ (`.1`) and Branch (`.2`) use `/24` even though they each have only one IP
   * **Peers:** Leave empty for now (we'll add the peer next)
   * **Disable Routes:** Leave unchecked (we want automatic route injection)

3. **Click Save** - The instance is now created but not yet connected to anything

4. **VPN > WireGuard > Peers > Add**

5. **Configure Peer (Branch):**
   * **Enabled:** ✓
   * **Name:** `Branch`
   * **Public Key:** *Leave blank for now*
     * **You must configure the Branch first (Step 2) and generate its keys**
     * Then return here and paste Branch's Public Key
     * Without this, the tunnel cannot establish - WireGuard uses public key cryptography
   * **Shared Secret:** Leave empty (optional additional layer of security)
   * **Allowed IPs:** `172.17.0.0/24, 10.200.0.2/32`
     * **Critical:** This tells HQ's WireGuard what traffic to send through the tunnel
     * `172.17.0.0/24` - Branch's LAN subnet (all traffic destined for Branch LAN goes through tunnel)
     * `10.200.0.2/32` - Branch's tunnel IP (allows communication with the Branch gateway itself)
     * These IPs act as both routing policy and firewall allowlist
   * **Endpoint Address:** `192.168.1.245`
     * Branch's public WAN IP address (reachable from HQ)
     * In production: this would be Branch's public internet IP or FQDN
   * **Endpoint Port:** `51820`
     * Must match the Listen Port configured on Branch's instance
   * **Instance:** Select `HQ_Instance` from dropdown
     * This associates the peer with the local instance you created
   * **Keepalive Interval:** `25` (seconds)
     * Recommended for site-to-site VPNs behind NAT
     * Sends periodic keepalive packets to maintain the tunnel even when idle
     * Prevents NAT session timeout (most home routers timeout after 30-60 seconds)

   > **Why asymmetric Allowed IPs?**
   >
   > HQ's peer entry for Branch uses `10.200.0.2/32` because HQ only needs to reach Branch's specific tunnel endpoint. Branch's peer entry for HQ (Step 2) uses `10.200.0.0/24` for the tunnel subnet so that road warrior clients (Project 9) can access Branch resources through the site-to-site tunnel chain.
   >
   > Traffic flow for road warrior → Branch: `Admin PC (10.200.0.10) → HQ tunnel → Branch tunnel → Branch LAN (172.17.0.0/24)`

6. **Click Save**

7. **Enable the WireGuard Service:**
   * Navigate to **VPN > WireGuard > General**
   * **Enable WireGuard:** ✓
   * **Click Apply**

8. **Configure WAN Firewall Rule:**
   * Navigate to **Firewall > Rules > WAN**
   * **Click Add**
   * Configure the rule:
     * **Action:** Pass
     * **Interface:** WAN
     * **Direction:** in
     * **TCP/IP Version:** IPv4
     * **Protocol:** UDP
     * **Source:** any
     * **Destination:** WAN address
     * **Destination Port Range:** `51820` to `51820`
     * **Description:** `Allow WireGuard VPN`
   * **Why `any` source is safe:** WireGuard is secured by public key cryptography. Only peers with valid public keys configured in OPNsense can establish a tunnel. The WAN rule simply allows the encrypted UDP traffic to reach the WireGuard service - unauthorized clients cannot connect even if they reach port 51820. Using `any` allows both the Branch site and road warrior clients (Project 9) to connect.
   * **Click Save**
   * **Click Apply Changes**
   * **Why this is needed:** Without this rule, incoming WireGuard handshake packets from Branch will be blocked by the default WAN deny rule

9. **Assign WireGuard Interface:**
   * Navigate to **Interfaces > Assignments**
   * In the "New interface" dropdown, select `wg0` (or your instance device name)
   * Click the **+** button to add
   * Click on the new interface name (e.g., "OPT1")
   * Configure:
     * **Enable:** ✓ (Check "Enable Interface")
     * **IPv4 Configuration Type:** None (IP is managed at WireGuard instance level)
     * **IPv6 Configuration Type:** None
     * **MSS:** `1380`
       * **Why MSS clamping?** WireGuard adds ~60-80 bytes overhead per packet. Without this, large TCP packets cause fragmentation, resulting in "zombie connections" where ping works but file transfers or AD replication hang.
   * Click **Save** and **Apply Changes**
   * **Why assign the interface?** Creates a dedicated firewall rules tab, enables RRD traffic graphs, and allows gateway creation for advanced routing scenarios

10. **Configure WireGuard Interface Firewall Rule:**
    * Navigate to **Firewall > Rules > OPT1**
    * **Click Add**
    * Configure the rule:
      * **Action:** Pass
      * **Interface:** OPT1
      * **Direction:** in
      * **TCP/IP Version:** IPv4
      * **Protocol:** any
      * **Source:** `Trusted_Lab_Networks` (select from dropdown)
      * **Destination:** `Trusted_Lab_Networks` (select from dropdown)
      * **Description:** `Allow all inter-site traffic through VPN tunnel`
    * **Click Save**
    * **Click Apply Changes**
    * **Why this is critical:** Without this rule, the tunnel handshake succeeds but NO traffic flows through it. OPNsense blocks all traffic on new interfaces by default.

11. **Verify Instance is Running:**
    * Navigate to **VPN > WireGuard > Status**
    * You should see `HQ_Instance` listed with status information

---

### Step 2: Branch Configuration (The Client)

**Navigate to OPNsenseBranch (`172.17.0.1`) Web Interface:**

1. **VPN > WireGuard > Instances > Add**

2. **Configure Local Instance (Branch's WireGuard Interface):**
   * **Enabled:** ✓
   * **Name:** `Branch_Instance`
   * **Public Key:** Click **Generate** button
     * **Important:** Copy this Public Key - you'll paste it into HQ's peer configuration
     * Return to HQ Web UI > VPN > WireGuard > Peers > Edit `Branch` peer
     * Paste this key into the **Public Key** field on HQ
   * **Private Key:** Auto-generated (stored securely by OPNsense)
   * **Listen Port:** `51820`
     * Must match the port HQ expects (configured in HQ's peer endpoint port)
   * **Tunnel Address:** `10.200.0.2/24`
     * Branch's virtual IP inside the WireGuard tunnel
     * The `/24` ensures proper routing table entries (same rationale as HQ)
     * Different from HQ's tunnel IP (`.1` vs `.2`)
   * **Peers:** Leave empty for now
   * **Disable Routes:** Leave unchecked

3. **Click Save**

4. **VPN > WireGuard > Peers > Add**

5. **Configure Peer (HQ):**
   * **Enabled:** ✓
   * **Name:** `HQ`
   * **Public Key:** Paste HQ's Public Key here
     * This is the key you saved from Step 1 when configuring HQ
   * **Shared Secret:** Leave empty
   * **Allowed IPs:** `172.16.0.0/24, 10.200.0.0/24`
     * `172.16.0.0/24` - HQ's LAN subnet (route HQ LAN traffic through tunnel)
     * `10.200.0.0/24` - Entire WireGuard tunnel subnet (allows future clients)
     * **Why `/24` instead of `/32`?** This allows Branch to reach both HQ's tunnel IP and any future VPN clients
   * **Endpoint Address:** `192.168.1.240`
     * HQ's WAN IP address (reachable from Branch)
   * **Endpoint Port:** `51820`
     * Must match HQ's Listen Port
   * **Instance:** Select `Branch_Instance` from dropdown
   * **Keepalive Interval:** `25` (seconds)
     * Same rationale as HQ - prevents NAT timeout

6. **Click Save**

7. **Enable the WireGuard Service:**
   * Navigate to **VPN > WireGuard > General**
   * **Enable WireGuard:** ✓
   * **Click Apply**

8. **Configure WAN Firewall Rule:**
   * Navigate to **Firewall > Rules > WAN**
   * **Click Add**
   * Configure the rule:
     * **Action:** Pass
     * **Interface:** WAN
     * **Direction:** in
     * **TCP/IP Version:** IPv4
     * **Protocol:** UDP
     * **Source:** `192.168.1.240`
     * **Destination:** WAN address
     * **Destination Port Range:** `51820` to `51820`
     * **Description:** `Allow WireGuard from HQ`
   * **Click Save**
   * **Click Apply Changes**
   * **Why this is needed:** Without this rule, incoming WireGuard handshake packets from HQ will be blocked by the default WAN deny rule

9. **Assign WireGuard Interface:**
   * Navigate to **Interfaces > Assignments**
   * In the "New interface" dropdown, select `wg0` (or your instance device name)
   * Click the **+** button to add
   * Click on the new interface name (e.g., "OPT1")
   * Configure:
     * **Enable:** ✓ (Check "Enable Interface")
     * **IPv4 Configuration Type:** None (IP is managed at WireGuard instance level)
     * **IPv6 Configuration Type:** None
     * **MSS:** `1380`
       * **Why MSS clamping?** WireGuard adds ~60-80 bytes overhead per packet. Without this, large TCP packets cause fragmentation, resulting in "zombie connections" where ping works but file transfers or AD replication hang.
   * Click **Save** and **Apply Changes**
   * **Why assign the interface?** Creates a dedicated firewall rules tab, enables RRD traffic graphs, and allows gateway creation for advanced routing scenarios

10. **Configure WireGuard Interface Firewall Rule:**
    * Navigate to **Firewall > Rules > OPT1**
    * **Click Add**
    * Configure the rule:
      * **Action:** Pass
      * **Interface:** OPT1
      * **Direction:** in
      * **TCP/IP Version:** IPv4
      * **Protocol:** any
      * **Source:** `Trusted_Lab_Networks` (select from dropdown)
      * **Destination:** `Trusted_Lab_Networks` (select from dropdown)
      * **Description:** `Allow all inter-site traffic through VPN tunnel`
    * **Click Save**
    * **Click Apply Changes**
    * **Why this is critical:** Without this rule, the tunnel handshake succeeds but NO traffic flows through it. OPNsense blocks all traffic on new interfaces by default.

11. **Verify Tunnel Establishment:**
    * Navigate to **VPN > WireGuard > Status**
    * Look for `Branch_Instance` with a **Last Handshake** timestamp
    * If it shows "Never" or a time >2 minutes ago:
      * Verify endpoint IPs are correct and reachable
      * Check that both instances have each other's correct public keys

---

### Step 3: Initial Tunnel Testing

After both sides are configured, verify connectivity:

**From OPNsenseHQ:**

1. Navigate to **Interfaces > Diagnostics > Ping**
2. **Hostname:** `10.200.0.2` (Branch's tunnel IP)
3. **Source Address:** `10.200.0.1` (HQ's tunnel IP)
4. **Click Ping** - You should see replies

**From OPNsenseBranch:**

1. Navigate to **Interfaces > Diagnostics > Ping**
2. **Hostname:** `10.200.0.1` (HQ's tunnel IP)
3. **Source Address:** `10.200.0.2` (Branch's tunnel IP)
4. **Click Ping** - You should see replies

**Troubleshooting:**

* **No handshake:** Check firewall WAN rules allow UDP/51820
* **Handshake successful but no ping:** Check WireGuard interface firewall rules
* **Asymmetric routing:** Verify "Allowed IPs" are correctly configured on both sides

---

### Step 4: Gateway Configuration (Optional)

> [!NOTE]
> Interface assignment and MSS clamping were completed in Step 1 (HQ) and Step 2 (Branch) during step 9. This section covers optional gateway configuration for advanced routing scenarios.

**On both OPNsenseHQ and OPNsenseBranch:**

1. **Configure Dynamic Gateway (Optional):**
   * Navigate to **Interfaces > [OPT1]**
   * **Dynamic gateway:** ✓ (Check this to auto-create a gateway)
   * Click **Save** and **Apply Changes**

2. **Gateway Monitoring (Optional):**

   After enabling "Dynamic gateway" on the interface, OPNsense creates a gateway entry. **Gateway monitoring is disabled by default** for WireGuard gateways in OPNsense 25.x, which is the recommended setting for this lab.

   **If no gateway was created:** Navigate to **System > Gateways > Configuration**, click **Add**, select your OPT1 interface, and set the gateway IP to the remote peer's tunnel IP (e.g., `10.200.0.2` for HQ, `10.200.0.1` for Branch).

   **What is gateway monitoring for?**

   Gateway monitoring enables **automatic failover** in multi-WAN scenarios. For example: "If the VPN tunnel goes down, automatically route traffic through a backup WAN connection."

   OPNsense uses `dpinger` to ping a "Monitor IP" and determine if the gateway is healthy. If dpinger can't reach the Monitor IP, it marks the gateway as "Down" and OPNsense removes all routes using that gateway.

   **Do you need it?**

   | Scenario | Recommendation |
   | :---------- | :---------------- |
   | Simple site-to-site VPN (this lab) | **Leave disabled** (default) - simpler, avoids potential issues |
   | Multi-WAN with automatic failover | **Enable monitoring** - required for failover logic |
   | Production with SLA requirements | **Enable monitoring** - enables health dashboards and alerts |

   **Verify Monitoring is Disabled (Default - Recommended for this lab)**

   * Navigate to **System > Gateways > Configuration**
   * Find the gateway (e.g., `OPT1_GWv4`)
   * Click **Edit** (pencil icon)
   * Verify **"Disable Gateway Monitoring"** is checked (should be by default)

   This prevents dpinger from marking the gateway as "Down" and removing routes. The VPN works as long as WireGuard maintains its handshake.

   **Enable Gateway Monitoring (For failover scenarios)**

   * Navigate to **System > Gateways > Configuration**
   * Find the gateway (e.g., `OPT1_GWv4`)
   * Click **Edit** (pencil icon)
   * Click **Advanced Mode** (toggle at top of page) to reveal monitoring options
   * Uncheck **"Disable Gateway Monitoring"**
   * **Monitor IP:** Set to the remote peer's tunnel IP
     * **On HQ:** `10.200.0.2` (Branch's tunnel IP)
     * **On Branch:** `10.200.0.1` (HQ's tunnel IP)
   * Click **Save** and **Apply Changes**

   > **Troubleshooting tip:** If the tunnel handshake is working (check VPN > WireGuard > Status) but no traffic flows, check that gateway monitoring is either disabled or has a valid Monitor IP configured.
   >
   > [!WARNING]
   > There are [active bugs in OPNsense 25.x](https://github.com/opnsense/core/issues/8990) related to gateway monitoring and WireGuard failover. In multi-WAN scenarios, gateways may incorrectly report as "up" when down, or disabled gateways may be selected as default. If you experience unexpected failover behavior, a firewall reboot may be required as a temporary workaround.

---

#### Important Notes

**Understanding "Allowed IPs":**

* This field serves **two purposes** in WireGuard:
  1. **Routing Policy:** "Send traffic destined for these IPs through this peer"
  2. **Source Validation:** "Only accept packets from this peer if they originate from these IPs"
* Common mistake: Forgetting to include the peer's tunnel IP (`10.200.0.x/32`) results in inability to ping the remote gateway

> **Why HQ uses `10.200.0.0/24` in Allowed IPs (Branch → HQ):** Project 9 (Road Warrior VPN) will allocate client IPs from `10.200.0.0/24`. By including the `/24` on Branch, road warrior clients can access Branch resources transparently. HQ uses specific `/24` entries because it only needs to route known subnets.

### C. Firewall Rules Summary

> [!NOTE]
> Detailed step-by-step firewall configuration is provided in Section B above (Steps 0, 1, and 2). This section serves as a reference summary of all required firewall rules.

#### Prerequisites

* **Firewall Alias:** The `Trusted_Lab_Networks` alias was created in **Section B, Step 0**
* This alias includes: `172.16.0.0/24` (HQ LAN), `172.17.0.0/24` (Branch LAN), `10.200.0.0/24` (WireGuard Tunnel)

#### Required Firewall Rules

##### 1. WAN Interface (Both Sites)

* **Location:** Firewall > Rules > WAN
* **Action:** Pass
* **Protocol:** UDP
* **Source:** `any` on HQ (allows Branch + road warriors), `192.168.1.240` on Branch (HQ only)
* **Destination:** WAN address
* **Destination Port:** `51820`
* **Description:** Allow WireGuard VPN
* **Configured in:** Step 1 (HQ) and Step 2 (Branch), step 8

##### 2. WireGuard Interface (Both Sites)

* **Location:** Firewall > Rules > OPT1
* **Action:** Pass
* **Protocol:** IPv4 (Any)
* **Source:** `Trusted_Lab_Networks`
* **Destination:** `Trusted_Lab_Networks`
* **Description:** Allow all inter-site traffic through VPN tunnel
* **Configured in:** Step 1 (HQ) and Step 2 (Branch), step 10

> [!NOTE]
> The WireGuard interface rule permits all inter-site traffic including AD replication (LDAP, Kerberos, RPC), file sharing (SMB), DNS queries, and road warrior VPN access. The alias ensures traffic from any trusted network can reach any other trusted network.
>
> **Protocol Reference:**
> | Protocol | Port(s) | Purpose |
> |----------|---------|---------|
> | **LDAP** | 389 | Lightweight Directory Access Protocol — queries AD for users, groups, and other directory objects |
> | **Kerberos** | 88, 464 | Authentication protocol — provides secure identity verification using tickets instead of passwords over the network |
> | **RPC** | 135 + dynamic | Remote Procedure Call — enables AD replication, Group Policy, and remote management between DCs |
> | **SMB** | 445 | Server Message Block — file sharing for SYSVOL, NETLOGON, and GPO distribution |

---

## 3. Validation

### VPN Tunnel Validation Checklist

* [ ] **WireGuard Status:** Both OPNsense instances show "Last Handshake" within the last 2 minutes
* [ ] **Tunnel Ping (HQ):** From OPNsenseHQ, ping `10.200.0.2` (Branch tunnel IP)
* [ ] **Tunnel Ping (Branch):** From OPNsenseBranch, ping `10.200.0.1` (HQ tunnel IP)
* [ ] **Cross-Site Ping (HQ → Branch):** From OPNsenseHQ, ping `172.17.0.1` (Branch LAN gateway)
* [ ] **Cross-Site Ping (Branch → HQ):** From OPNsenseBranch, ping `172.16.0.1` (HQ LAN gateway)

### Troubleshooting

| Symptom | Likely Cause | Solution |
| :--------- | :-------------- | :---------- |
| No handshake | WAN firewall rule missing | Check UDP 51820 is allowed on WAN |
| Handshake OK, no ping | WireGuard interface rule missing | Add rule on WireGuard (Group) or assigned interface |
| Ping gateway OK, can't reach LAN hosts | Windows firewall blocking | Continue to Project 8 for Windows firewall config |
