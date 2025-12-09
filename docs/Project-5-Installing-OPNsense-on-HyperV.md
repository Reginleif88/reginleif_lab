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

* **Generation:** Generation 2 (UEFI)
* **Secure Boot:** **Disabled** (Crucial: FreeBSD will not boot with Microsoft Secure Boot).
* **Processor:** 2 Virtual Processors.
* **Memory:** 4096 MB (4 GB) - **Dynamic Memory Disabled**.
* **Network Adapter 1:** "External Switch" (Bridged to Physical/Internet).
* **Network Adapter 2:** "Private/Internal Switch" (LAN - "172.17.0.0/24").
* **Disk:** 40 GB VHDX (Block size dynamic).

**Downloads:** OPNsense: <https://opnsense.org/download/>

---

## 2. Hyper-V Network Setup

Before booting, ensure Hyper-V has the correct Virtual Switches:

1. **External vSwitch:** Mapped to the Physical NIC (WAN).
2. **Private vSwitch:** Named `Branch-LAN` (Isolated, no host sharing required for pure isolation, or "Internal" if Host needs access).

---

## 3. Base Installation

1. Boot `OPNsense-dvd-amd64.iso`.
2. Login as `installer` / `opnsense`.
3. Select **ZFS** (or UFS) and install to the Virtual Disk.
4. **Eject** the ISO and **Reboot**.

---

## 4. Console Configuration (The "Bootstrap")

Configure the specific Branch IP details via the VM Console:

1. **Assign Interfaces:**
    * **WAN:** `hn0` (External/Home Network)
    * **LAN:** `hn1` (Branch-LAN)
2. **Set Interface IP Address (WAN):**
    * Select **WAN**.
    * IPv4 Configuration Type: `Static`
    * IPv4: `192.168.1.245`
    * Mask: `24`
    * Upstream Gateway: `192.168.1.254` (Home Router in our case)
    * IPv6: *None*
3. **Set Interface IP Address (LAN):**
    * Select **LAN**.
    * IPv4: `172.17.0.1`
    * Mask: `24`
    * Gateway: *None*
    * IPv6: *None*
    * DHCP Server: **Do not enable** - this can also be disabled during the first-time wizard in the GUI. (DHCP will be handled by Domain Controllers for AD integration - DNS/DHCP options, dynamic DNS updates, and centralized management).

---

## 5. Post-Installation Tuning (Hyper-V Specifics)

Once the Web UI is accessible at `https://172.17.0.1`:

1. **First-Time Wizard Configuration:**

    During the first-time wizard in the GUI:

    * On the **General** step, set **Hostname** to `OPNsenseBranch`.
    * On the **Interfaces** step, uncheck **Block private networks** and **Block bogon networks** for the WAN interface (since the lab's WAN connects to a private home LAN).

2. **Disable Hardware Offloading** if not by default (Interfaces > Settings):
    * [x] Disable Hardware Checksum Offload
    * [x] Disable Hardware TCP Segmentation Offload
    * [x] Disable Hardware Large Receive Offload
    * **Reboot** the VM after saving.

3. **Disable Hyper-V Time Synchronization:**
    * In VM Settings → Integration Services, uncheck **Time Synchronization**.
    * OPNsense uses its own NTP configuration and Hyper-V time sync can cause conflicts or clock drift.

> **Why disable hardware offloading?** Hyper-V virtual NICs can cause packet corruption with offloading enabled. Disabling ensures stability with minimal performance impact in virtualized environments.

> **Why allow private/bogon networks on WAN?** OPNsense treats RFC1918 addresses (10.x.x.x, 172.16-31.x.x, 192.168.x.x) as potentially spoofed when arriving on WAN. In production, this is a security feature. In a lab where your "internet" is actually a home network, you must disable these blocks to allow upstream connectivity.

---

## 6. Configure NAT (Outbound)

OPNsense enables NAT by default, but automatic rules may not generate in some configurations. Verify and configure manually if needed:

1. Navigate to **Firewall → NAT → Outbound**.
2. Check if **Hybrid outbound NAT rule generation** shows rules for `172.17.0.0/24`.
3. If automatic rules exist, you're done. If not, create a manual rule:

**Manual NAT Rule (Required if no automatic rules exist):**

1. Set mode to **Manual outbound NAT rule generation** and click **Save**.
2. Click **Add** (+ button).
3. Configure:
   * **Interface:** WAN
   * **Address Family:** IPv4
   * **Protocol:** any
   * **Source address:** `172.17.0.0/24`
   * **Source port:** any
   * **Destination address:** any
   * **Destination port:** any
   * **Translation / target:** Interface address
   * **Description:** `LAN to WAN NAT`
4. Click **Save** then **Apply Changes**.

> **Why might automatic rules not generate?** Common causes include: WAN interface missing a gateway definition, interface configuration order during setup, or OPNsense not recognizing the LAN interface type. Manual rules provide explicit control and are easier to troubleshoot.

---

## 7. Configure DNS Resolver (Unbound)

OPNsense runs Unbound as its DNS resolver. Configure it with reliable upstream DNS servers and prevent DHCP from overriding these settings.

### Prevent DHCP from Overriding DNS

If WAN uses DHCP, the upstream router may push its own DNS servers, overriding your configuration.

1. Navigate to **Interfaces → WAN**.
2. Scroll to **DHCP client configuration**.
3. Uncheck **Use DNS servers provided by the DHCP server** (or check "Reject" options).
4. Click **Save** and **Apply Changes**.

### Configure Upstream DNS Servers

1. Navigate to **System → Settings → General**.
2. Under **DNS servers**, add:
   * `1.1.1.1` (Cloudflare - primary)
   * `8.8.8.8` (Google - secondary)
3. For each DNS server, set **Use gateway:** to the WAN gateway (ensures DNS queries go out the correct interface).
4. Uncheck **Allow DNS server list to be overridden by DHCP/PPP on WAN**.
5. Click **Save**.

### Enable and Configure Unbound

1. Navigate to **Services → Unbound DNS → General**.
2. Ensure these settings:
   * **Enable Unbound:** Checked
   * **Listen Port:** 53
   * **Network Interfaces:** All
   * **DNSSEC:** Checked
3. Click **Save** and **Apply Changes**.

> **Why DNSSEC?** DNSSEC validates that DNS responses haven't been tampered with, protecting against cache poisoning and spoofing attacks.

### Verify DNS Resolution

From the OPNsense shell (console or SSH, or use GUI):

```sh
ping google.com
ping 1.1.1.1
```

> **Why configure DNS explicitly?** In lab environments where OPNsense's WAN connects to a home router via DHCP, the router often pushes its own DNS (e.g., ISP DNS or router IP). These may be slow, unreliable, or block certain queries. Using Cloudflare (1.1.1.1) and Google (8.8.8.8) ensures fast, reliable resolution for your lab VMs.
