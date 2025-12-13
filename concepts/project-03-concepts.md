---
title: "Project 3: Active Directory Bootstrap - Background & Concepts"
parent: "Project 3: Active Directory Bootstrap"
tags: [concepts, background, active-directory, domain-controller, group-policy]
status: completed
---

# Background & Concepts: Active Directory Bootstrap

## Overview

This project establishes the foundation of your Windows domain by deploying the first Domain Controller and creating the `reginleif.io` forest. Understanding Active Directory's logical structure (forests, domains, OUs), physical components (DCs, NTDS.dit, SYSVOL), and authentication mechanisms (Kerberos) is critical for managing enterprise Windows environments.

---

## What is Active Directory?

Active Directory (AD) is Microsoft's directory service for Windows domain networks. At its core, AD is a centralized database that stores information about network resources (users, computers, groups, and policies) and provides authentication and authorization services.

**Why organizations need Active Directory:**

| Challenge | Without AD | With AD |
|:----------|:-----------|:--------|
| **User Management** | Local accounts on each machine | Single account works everywhere |
| **Authentication** | Users maintain separate passwords | Single Sign-On (SSO) across resources |
| **Configuration** | Manual settings per machine | Group Policy pushes settings centrally |
| **Security** | Inconsistent security baselines | Uniform policies enforced domain-wide |

AD builds on **LDAP** (Lightweight Directory Access Protocol), an industry-standard protocol for querying and modifying directory services over TCP/IP. LDAP provides the underlying structure for storing and retrieving objects (users, computers, groups), while AD extends it with Windows-specific features like Group Policy, Kerberos authentication, and DNS integration.

> **Why LDAP matters:**
>
> - AD troubleshooting tools query LDAP (port 389/636)
> - Third-party systems (Linux, macOS, applications) authenticate against AD via LDAP
> - Error messages and logs often reference LDAP operations

## AD Logical Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                        FOREST                                   │
│                    (reginleif.io)                               │
│         ┌─────────────────────────────────────────┐             │
│         │              DOMAIN                     │             │
│         │          (reginleif.io)                 │             │
│         │    ┌─────────────────────────────┐      │             │
│         │    │    Organizational Units     │      │             │
│         │    │  ┌─────┐ ┌─────┐ ┌───────┐  │      │             │
│         │    │  │Users│ │Comps│ │Servers│  │      │             │
│         │    │  └─────┘ └─────┘ └───────┘  │      │             │
│         │    └─────────────────────────────┘      │             │
│         └─────────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

**Hierarchy explained:**

| Level | Description | Key Characteristics |
|:------|:------------|:--------------------|
| **Forest** | Top-level container; security and schema boundary | All domains share one schema; trust is automatic within forest |
| **Domain** | Administrative boundary; replication unit | DNS namespace (e.g., `reginleif.io`); Kerberos realm |
| **OU** | Organizational Unit; logical container for objects | Primary target for Group Policy; delegation boundary |

> **This Lab:** We create a single-domain forest (`reginleif.io`). In enterprise environments, you might see child domains (e.g., `branch.reginleif.io`) or separate forests for acquisitions.

## AD Physical Components

While the logical structure defines *how* resources are organized, physical components determine *where* the directory service runs:

**Domain Controller (DC):**
A Windows Server running AD Domain Services. The DC hosts a replica of the directory database and handles authentication requests. Unlike a single primary/secondary model, AD uses **multi-master replication**: any DC can accept changes, and changes propagate to all others.

**NTDS.dit Database:**
The heart of Active Directory. This Extensible Storage Engine (ESE) database stores:

- User and computer accounts (with password hashes)
- Group memberships
- Schema definitions
- Configuration data

Located at `C:\Windows\NTDS\ntds.dit`, it's protected and can only be accessed through AD tools or in Directory Services Restore Mode (DSRM).

**SYSVOL and NETLOGON Shares:**

| Share | Purpose | Contents |
|:------|:--------|:---------|
| **SYSVOL** | Group Policy distribution | GPO files, scripts, policies |
| **NETLOGON** | Legacy logon script location | Login scripts, policy files |

SYSVOL replicates between all DCs using DFS-R (Distributed File System Replication), ensuring consistent policy application.

**Global Catalog (GC):**
A partial replica of all objects in the forest, containing the most frequently searched attributes. The GC enables:

- Cross-domain searches without querying each domain
- Universal group membership resolution during logon
- User Principal Name (UPN) authentication

### Physical Components Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                       AD PHYSICAL ARCHITECTURE                              │
└─────────────────────────────────────────────────────────────────────────────┘

    Site A (Proxmox)                              Site B (Hyper-V)
   ┌────────────────────────┐                   ┌────────────────────────┐
   │      P-WIN-DC1         │                   │      H-WIN-DC2         │
   │    (Domain Controller) │  ◄── DFS-R ───►   │    (Domain Controller) │
   │  ┌──────────────────┐  │   Replication     │  ┌──────────────────┐  │
   │  │    NTDS.dit      │  │                   │  │    NTDS.dit      │  │
   │  │  (AD Database)   │  │                   │  │  (AD Database)   │  │
   │  └──────────────────┘  │                   │  └──────────────────┘  │
   │  ┌──────────────────┐  │                   │  ┌──────────────────┐  │
   │  │     SYSVOL       │  │                   │  │     SYSVOL       │  │
   │  │  (GPO Storage)   │  │                   │  │  (GPO Storage)   │  │
   │  └──────────────────┘  │                   │  └──────────────────┘  │
   │  ┌──────────────────┐  │                   │  ┌──────────────────┐  │
   │  │  Global Catalog  │  │                   │  │  Global Catalog  │  │
   │  │    (GC Server)   │  │                   │  │    (GC Server)   │  │
   │  └──────────────────┘  │                   │  └──────────────────┘  │
   └────────────────────────┘                   └────────────────────────┘
            │                                            │
            │         Multi-Master Replication           │
            │  ◄─────────────────────────────────────►   │
            │     (Changes can be made on ANY DC)        │
            │                                            │
```

Both DCs hold a complete, writable copy of the directory. Changes made on either DC replicate to the other. This is **multi-master replication**, unlike traditional primary/secondary models.

## Kerberos Authentication

Kerberos is the default authentication protocol in Active Directory, replacing the older NTLM protocol. Named after the three-headed dog guarding the gates of Hades in Greek mythology, Kerberos involves three parties in every authentication: the client, the server, and a trusted third party (the Key Distribution Center).

**How Kerberos Works (Simplified):**

> **KDC** = Key Distribution Center, the service on every Domain Controller that issues authentication tickets.

```
┌─────────────────────────────────────────────────────────────┐
│                    Kerberos Authentication Flow             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Client → KDC (DC):  "I need to access FileServer"       │
│     • Sends username (not password!)                        │
│     • Encrypted with user's password hash                   │
│                                                             │
│  2. KDC → Client:  Ticket-Granting Ticket (TGT)             │
│     • Encrypted with KDC's secret key                       │
│     • Valid for 10 hours by default                         │
│     • Contains user's identity and privileges               │
│                                                             │
│  3. Client → KDC:  "Use my TGT to access FileServer"        │
│     • Presents TGT to request service ticket                │
│                                                             │
│  4. KDC → Client:  Service Ticket                           │
│     • Encrypted with FileServer's secret key                │
│     • Valid for specific service only                       │
│                                                             │
│  5. Client → FileServer:  Service Ticket                    │
│     • Server decrypts ticket and grants access              │
│     • No DC contact needed!                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Components:**

| Component | Role |
|:----------|:-----|
| **KDC (Key Distribution Center)** | Service running on every DC; issues tickets |
| **TGT (Ticket-Granting Ticket)** | Proof of identity; used to request service tickets |
| **Service Ticket** | Grants access to specific resource (file share, web app, etc.) |
| **Ticket Lifetime** | Default 10 hours for TGT, prevents indefinite access |

**Time Synchronization Requirement:**

Kerberos tickets include timestamps to prevent replay attacks (reusing captured tickets). All systems must have synchronized time within **5 minutes** of each other. If clocks drift beyond this threshold:

- Authentication fails with "time skew too great" errors
- Domain joins fail
- AD replication breaks
- RDP and other services become inaccessible

> For detailed coverage of AD time sync hierarchy, NTP configuration, and hypervisor clock issues, see [Project 8 Concepts: Time Synchronization and Kerberos](./project-08-concepts.md#time-synchronization-and-kerberos).

This is why configuring accurate time synchronization (covered in the main project guide) is critical for Active Directory environments.

**Security Benefits:**

- **No password transmission:** Passwords never travel across the network, even in encrypted form during authentication
- **Mutual authentication:** Clients verify the server's identity, preventing man-in-the-middle attacks
- **Limited ticket lifetime:** Compromised tickets expire, limiting damage window
- **Privilege isolation:** Service tickets are specific to one resource, limiting lateral movement

> **In This Lab:** When P-WIN-DC1 is promoted, the KDC service automatically starts. All domain-joined machines will use Kerberos to authenticate to the DC and access network resources.

> [!TIP]
> **TL;DR:** Kerberos is why time sync matters. If clocks are off by more than 5 minutes, authentication fails completely. That's the single most important takeaway.
>
> **Common failure:** "Clock skew too great" error = check your NTP configuration.

## Group Policy Fundamentals

Group Policy Objects (GPOs) are collections of settings that control the working environment of user accounts and computer accounts. GPOs can configure:

- Security settings (password policies, audit policies)
- Software installation and restrictions
- Desktop and Start menu configurations
- Registry-based preferences

**GPO Processing Order (LSDOU):**

```
┌─────────────────────────────────────────────────┐
│                                                 │
│    Local Policy    ───────────────────┐         │
│         ↓                             │         │
│    Site Policy     ───────────────────┤         │
│         ↓                             │ Higher  │
│    Domain Policy   ───────────────────┤ priority│
│         ↓                             │    ↓    │
│    OU Policy       ───────────────────┘         │
│         ↓                                       │
│    Nested OU Policy (if applicable)             │
│                                                 │
└─────────────────────────────────────────────────┘
```

> **What are Nested OUs?** OUs can contain other OUs (like folders inside folders). Example: `Domain → IT Department OU → Servers OU → Web Servers OU`. Each level can have its own GPO, and policies apply from top to bottom. A computer in `Web Servers OU` receives policies from all parent OUs above it. If the same setting is configured at multiple levels, the closest OU wins (Web Servers OU overrides Servers OU).

**Key principle:** Later policies override earlier ones. A setting in a Domain GPO is overwritten by the same setting in an OU GPO, unless inheritance is blocked or enforced.

**Where are GPOs stored?**

| Location | Purpose |
|:---------|:--------|
| **SYSVOL** (`\\domain\SYSVOL\domain\Policies\`) | GPO files (scripts, preferences, registry.pol). Replicated between all DCs via DFS-R |
| **Active Directory** | GPO metadata (links, permissions, version numbers) |
| **Central Store** (optional) | Shared ADMX templates at `\\domain\SYSVOL\domain\Policies\PolicyDefinitions\` |

> **What is the Central Store?**
>
> ADMX files are the templates that define available GPO settings (what you see in Group Policy Editor). By default, each admin workstation uses its own local ADMX files (`C:\Windows\PolicyDefinitions\`), which can lead to version mismatches.
>
> In enterprise environments, the **Central Store** solves this by placing ADMX files in SYSVOL. All administrators then see the same GPO settings, and new templates (for Office, Chrome, etc.) only need to be added once.
>
> To create: copy `C:\Windows\PolicyDefinitions\` to `\\domain\SYSVOL\domain\Policies\PolicyDefinitions\`

## Key Terms Glossary

| Term | Definition |
|:-----|:-----------|
| **DC** | Domain Controller: server hosting AD DS and handling authentication |
| **NTDS** | NT Directory Services: the AD database engine and `ntds.dit` file |
| **SYSVOL** | System Volume: replicated share containing GPO data and scripts |
| **NETLOGON** | Network logon share for legacy scripts and policies |
| **GPO** | Group Policy Object: collection of configuration settings |
| **OU** | Organizational Unit: container for organizing AD objects |
| **Forest** | Top-level AD structure; schema and security boundary |
| **Domain** | DNS namespace and Kerberos realm within a forest |
| **FSMO** | Flexible Single Master Operations: special DC roles (covered in Project 8) |
| **DSRM** | Directory Services Restore Mode: offline DC recovery mode |
| **GC** | Global Catalog: forest-wide partial replica for searches |
| **LDAP** | Lightweight Directory Access Protocol: industry-standard protocol for querying directories |
| **Kerberos** | Ticket-based authentication protocol; replaces NTLM in AD environments |

