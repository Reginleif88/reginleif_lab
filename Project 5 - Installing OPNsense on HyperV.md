---
title: "Project 5: Installing OPNsense on HyperV (Branch)"
tags: [OPNsense, networking, hyper-v, setup, branch]
sites: [branch]
status: completed
---

## Goal
Deploy OPNsense (`OPNsenseBranch`) on Hyper-V to serve as the secure gateway and firewall for the Branch Office domain (`172.17.0.0/24`).

---

## 1. VM Hardware Configuration
*   **Generation:** Generation 2 (UEFI)
*   **Secure Boot:** **Disabled** (Crucial: FreeBSD will not boot with Microsoft Secure Boot).
*   **Processor:** 2 Virtual Processors.
*   **Memory:** 4096 MB (4 GB) - **Dynamic Memory Disabled**.
*   **Network Adapter 1:** "External Switch" (Bridged to Physical/Internet).
*   **Network Adapter 2:** "Private/Internal Switch" (LAN - "172.17.0.0/24").
*   **Disk:** 20 GB VHDX (Block size dynamic).

**Downloads:** OPNsense: https://opnsense.org/download/

---

## 2. Hyper-V Network Setup
Before booting, ensure Hyper-V has the correct Virtual Switches:
1.  **External vSwitch:** Mapped to the Physical NIC (WAN).
2.  **Private vSwitch:** Named `Branch-LAN` (Isolated, no host sharing required for pure isolation, or "Internal" if Host needs access).

---

## 3. Base Installation
1.  Boot `OPNsense-dvd-amd64.iso`.
2.  Login as `installer` / `opnsense`.
3.  Select **ZFS** (or UFS) and install to the Virtual Disk.
4.  **Eject** the ISO and **Reboot**.

---

## 4. Console Configuration (The "Bootstrap")
Configure the specific Branch IP details via the VM Console:

1.  **Assign Interfaces:**
    *   **WAN:** `hn0` (External/Home Network)
    *   **LAN:** `hn1` (Branch-LAN)
2.  **Set Interface IP Address:**
    *   Select **LAN**.
    *   IPv4: `172.17.0.1`
    *   Mask: `24`
    *   Gateway: *None*
    *   IPv6: *None*
    *   DHCP Server: **Do not enable** (DHCP will be handled by Domain Controllers for AD integration - DNS/DHCP options, dynamic DNS updates, and centralized management).

---

## 5. Post-Installation Tuning (Hyper-V Specifics)
Once the Web UI is accessible at `https://172.17.0.1`:

1.  **Disable Hardware Offloading** (Interfaces > Settings):
    *   [x] Disable Hardware Checksum Offload
    *   [x] Disable Hardware TCP Segmentation Offload
    *   [x] Disable Hardware Large Receive Offload
    *   **Reboot** the VM after saving.

2.  **Allow Private Networks on WAN (Lab Environment):**

    Since the lab's WAN connects to a private network (e.g., home LAN), OPNsense will block this traffic by default.

    *   Navigate to **Interfaces → [WAN]**.
    *   Scroll to **Generic configuration** at the bottom.
    *   Uncheck **Block private networks**.
    *   Uncheck **Block bogon networks**.
    *   Click **Save** and **Apply Changes**.

3.  **Allow ICMP on WAN (Ping Accessibility):**

    *   Navigate to **Firewall → Rules → WAN**.
    *   Click **Add** (+ button).
    *   Configure the rule:
        *   **Action:** Pass
        *   **Interface:** WAN
        *   **TCP/IP Version:** IPv4
        *   **Protocol:** ICMP
        *   **ICMP type:** any
        *   **Source:** any
        *   **Destination:** WAN address
        *   **Description:** `Allow ICMP (Ping)`
    *   Click **Save** and **Apply Changes**.

4.  **Hyper-V Integration Services:**
    *   Ensure "Time Synchronization" is enabled in the VM Settings on the Host.

**Why disable hardware offloading?**
Hyper-V virtual NICs can cause packet corruption with offloading enabled. Disabling ensures stability with minimal performance impact in virtualized environments.

**Why allow private/bogon networks on WAN?**
OPNsense treats RFC1918 addresses (10.x.x.x, 172.16-31.x.x, 192.168.x.x) as potentially spoofed when arriving on WAN. In production, this is a security feature. In a lab where your "internet" is actually a home network, you must disable these blocks to allow upstream connectivity.

---

## 6. Configure NAT (Outbound)

OPNsense enables NAT by default, but verify the configuration:

1.  Navigate to **Firewall → NAT → Outbound**.
2.  Mode should be: **Automatic outbound NAT rule generation**.
3.  Verify automatic rules exist for LAN → WAN translation.

**Manual Rule (if needed):**
*   Interface: `WAN`
*   Source: `LAN net`
*   Translation/target: `Interface address`

---

## 7. Validation
*   **Ping:** From a Windows VM on the `Branch-LAN` switch, ping `172.17.0.1`.
*   **Internet:** Verify the VM can browse the internet (NAT through OPNsense).
*   **Post-Setup:** Finish setting up in the web GUI of OPNsense
