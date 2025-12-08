---
title: "Project 1: OPNsense Gateway Deployment (HQ)"
tags: [OPNsense, networking, proxmox, setup]
sites: [hq]
status: completed
---

## Goal

Deploy OPNsense (`OPNsenseHQ`) on Proxmox to serve as the secure gateway and firewall for the `reginleif.io` domain (`172.16.0.0/24`).

---

## 1. VM Hardware Configuration

* **OS Type:** Other / Unknown (FreeBSD-based)
* **Machine:** q35 (Native PCIe)
* **BIOS:** OVMF (UEFI)
* **CPU:** Type Host (Passthrough AES-NI) | 2 Cores
* **RAM:** 4096 MB (4 GB)
* **Controller:** VirtIO SCSI Single + [x] IO Thread
* **Network:** VirtIO (Paravirtualized) x2
  * *Net0:* Bridge `vmbr0` (WAN)
  * *Net1:* Bridge `vmbr1` (LAN - Isolated)
* **QEMU Guest Agent:** Enabled

**Downloads:** OPNsense: <https://opnsense.org/download/>

---

## 2. Proxmox Network Setup

Before booting, ensure the Proxmox host has the correct bridges:

* **vmbr0:** Connected to Physical LAN (WAN for the Lab).
* **vmbr1:** Linux Bridge (No Physical Port) -> Acts as the "Switch" for `172.16.0.0/24`.

**Creating vmbr1 (if not exists):**

1. Navigate to Proxmox Node → Network.
2. Create → Linux Bridge.
3. Name: `vmbr1`, No physical port (isolated bridge).
4. Apply Configuration.

---

## 3. Base Installation

1. Boot `OPNsense-dvd-amd64.iso`.
2. Login as `installer` / `opnsense`.
3. Select **ZFS** (or UFS) and install to the VirtIO disk.
4. Reboot and remove ISO.

---

## 4. Console Configuration (The "Bootstrap")

Since the web UI isn't reachable yet, configure via the VM Console:

1. **Assign Interfaces:**
    * **WAN:** `vtnet0` (Upstream/Home Network)
    * **LAN:** `vtnet1` (Lab Network)
2. **Set Interface IP Address:**
    * Select **LAN**.
    * IPv4: `172.16.0.1`
    * Mask: `24`
    * Gateway: *None* (This *is* the gateway)
    * IPv6: *None*
    * DHCP Server: **Do not enable** (DHCP will be handled by Domain Controllers for AD integration - DNS/DHCP options, dynamic DNS updates, and centralized management).

---

## 5. Post-Installation Tuning (Critical for VirtIO)

Once the Web UI is accessible at `https://172.16.0.1`:

1. **Disable Hardware Offloading** (Interfaces > Settings):
    * [x] Disable Hardware Checksum Offload
    * [x] Disable Hardware TCP Segmentation Offload
    * [x] Disable Hardware Large Receive Offload
    * **Reboot** the VM after saving.

2. **Allow Private Networks on WAN (Lab Environment):**

    Since the lab's WAN connects to a private network (e.g., home LAN), OPNsense will block this traffic by default.

    * Navigate to **Interfaces → [WAN]**.
    * Scroll to **Generic configuration** at the bottom.
    * Uncheck **Block private networks**.
    * Uncheck **Block bogon networks**.
    * Click **Save** and **Apply Changes**.

3. **Allow ICMP on WAN (Ping Accessibility):**

    * Navigate to **Firewall → Rules → WAN**.
    * Click **Add** (+ button).
    * Configure the rule:
        * **Action:** Pass
        * **Interface:** WAN
        * **TCP/IP Version:** IPv4
        * **Protocol:** ICMP
        * **ICMP type:** any
        * **Source:** any
        * **Destination:** WAN address
        * **Description:** `Allow ICMP (Ping)`
    * Click **Save** and **Apply Changes**.

**Why disable hardware offloading?**
VirtIO virtual NICs can cause packet corruption with offloading enabled. Disabling ensures stability with minimal performance impact in virtualized environments.

**Why allow private/bogon networks on WAN?**
OPNsense treats RFC1918 addresses (10.x.x.x, 172.16-31.x.x, 192.168.x.x) as potentially spoofed when arriving on WAN. In production, this is a security feature. In a lab where your "internet" is actually a home network, you must disable these blocks to allow upstream connectivity.

---

## 6. Configure NAT (Outbound)

OPNsense enables NAT by default, but verify the configuration:

1. Navigate to **Firewall → NAT → Outbound**.
2. Mode should be: **Automatic outbound NAT rule generation**.
3. Verify automatic rules exist for LAN → WAN translation.

**Manual Rule (if needed):**

* Interface: `WAN`
* Source: `LAN net`
* Translation/target: `Interface address`

---

## 7. Validation

* **Ping:** From a VM on `vmbr1`, ping `172.16.0.1`.
* **Internet:** Verify VMs can route to the internet (NAT).
