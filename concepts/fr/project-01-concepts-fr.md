---
title: "Projet 1 : Installation d'OPNsense sur Proxmox - Contexte et concepts"
parent: "Projet 1 : Installation d'OPNsense sur Proxmox"
tags: [opnsense, firewall, concepts, background, networking, nat, dns]
status: completed
---

# Contexte et concepts : Installation d'OPNsense sur Proxmox

## Vue d'ensemble

Ce projet déploie OPNsense en tant que pare-feu virtuel sur Proxmox VE, fournissant la segmentation réseau, le NAT et les services DNS pour votre environnement de lab. Comprendre le fonctionnement de l'infrastructure réseau virtualisée (ponts, traduction NAT et résolution DNS) est essentiel pour construire des réseaux de lab isolés qui peuvent tout de même accéder à Internet.

---

## Le problème : Votre réseau de lab est isolé

Vos VM de lab vivront sur un réseau privé (`172.16.0.0/24`) qui existe uniquement à l'intérieur de Proxmox. Votre routeur domestique ignore que ce réseau existe. Si une VM de lab tente d'atteindre `google.com`, les paquets n'ont nulle part où aller :

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                   LE PROBLÈME : AUCUNE ROUTE VERS INTERNET                  │
└─────────────────────────────────────────────────────────────────────────────┘

   VM de lab                              Routeur domestique          Internet
   172.16.0.10                            192.168.1.254
  ┌──────────┐     "ping google.com"      ┌──────────────┐        ┌─────────┐
  │   DC1    │ ─────────────────────────► │    ???       │   X    │ google  │
  └──────────┘                            └──────────────┘        └─────────┘
                                                 │
                                    « Qui est 172.16.0.10 ? »
                                    « Je ne connais pas ce réseau. »
                                    (Paquet abandonné)
```

Le routeur domestique ne connaît que `192.168.1.0/24`. Lorsqu'il voit un paquet provenant de `172.16.0.10`, il n'a pas de route de retour, donc le paquet est abandonné.

## La solution : OPNsense comme passerelle

OPNsense se positionne entre votre réseau de lab et votre réseau domestique, résolvant ce problème grâce à deux mécanismes :

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                      LA SOLUTION : PASSERELLE OPNSENSE                      │
└─────────────────────────────────────────────────────────────────────────────┘

  VM de lab            OPNsense             Routeur domestique        Internet
  172.16.0.10          172.16.0.1 (LAN)     192.168.1.254
                       192.168.1.240 (WAN)

 ┌──────────┐         ┌──────────────┐        ┌──────────────┐     ┌─────────┐
 │   DC1    │────────►│  1. Routage  │───────►│              │────►│ google  │
 └──────────┘         │  2. NAT      │        │              │     └─────────┘
                      └──────────────┘        └──────────────┘
      │                     │                        │
      │                     │                        │
      │                     ▼                        │
      │               ┌───────────┐                  │
      │               │ Réécriture│                  │
      │               │ IP source │                  │
      │               └───────────┘                  │
      │                     │                        │
      ▼                     ▼                        ▼
 Src: 172.16.0.10    Src: 192.168.1.240    « Je connais 192.168.1.240 ! »
 Dst: 8.8.8.8        Dst: 8.8.8.8          (Route la réponse)
```

**Deux fonctions critiques :**

1. **Routage (Passerelle)** : OPNsense connaît les deux réseaux. Il a un pied dans `172.16.0.0/24` (LAN) et un pied dans `192.168.1.0/24` (WAN), transférant les paquets entre eux.

2. **NAT (Network Address Translation)** : OPNsense réécrit l'IP source de `172.16.0.10` vers `192.168.1.240` avant d'envoyer les paquets en amont. Désormais, le routeur domestique voit du trafic provenant d'une IP qu'il reconnaît.

## Pourquoi OPNsense ?

OPNsense est une distribution pare-feu/routeur basée sur FreeBSD. Pour ce lab, il fournit :

| Fonctionnalité | Utilisation dans ce lab |
|:---------------|:------------------------|
| **Pare-feu pf** | Le même filtre de paquets qui équipe OpenBSD. Stateful, rapide, fiable. |
| **NAT sortant** | Traduit les IP du lab vers l'IP WAN pour que le trafic puisse atteindre Internet. |
| **DNS Unbound** | Résolveur local avec cache. Les VM du lab obtiennent un DNS rapide et fiable sans dépendre des serveurs du FAI. |
| **VPN WireGuard** | VPN site à site (Projet 7) et accès distant (Projet 9). |
| **Interface Web** | Configurez tout via un navigateur au lieu de la ligne de commande uniquement. |

### Services utilisés par projet

Toutes les fonctionnalités d'OPNsense ne sont pas utilisées immédiatement. Voici ce qui est activé et quand :

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│  PROJET 1 (Ce projet)                      │   PROJETS FUTURS               │
│  ─────────────────────────────────────────────────────────────────────────  │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐    ┌───────────┐ ┌───────────┐   │
│  │ Pare-feu  │ │    NAT    │ │    DNS    │    │    VPN    │ │  Routage  │   │
│  │   (pf)    │ │ (Sortant) │ │ (Unbound) │    │(WireGuard)│ │  (VLAN)   │   │
│  └───────────┘ └───────────┘ └───────────┘    └───────────┘ └───────────┘   │
│       ▲             ▲             ▲                 ▲             ▲         │
│       │             │             │                 │             │         │
│   Bloquer/         Lab→Internet  Résolution de   Projet 7,9    Projet 11    │
│   autoriser        connectivité  noms pour       (Tunnels VPN) (VLAN)       │
│   le trafic                      les VM du lab                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!NOTE]
> **Le DHCP est intentionnellement désactivé sur OPNsense.** Les contrôleurs de domaine fourniront le DHCP (Projet 10) pour permettre l'intégration Active Directory : mises à jour DNS dynamiques, options DHCP pour le démarrage PXE et gestion centralisée des IP.

## Comment fonctionne réellement le NAT

Nous avons établi que le NAT réécrit les adresses sources. Mais comment OPNsense sait-il où envoyer la *réponse* ? La réponse est la **table d'état**.

### La table d'état (NAT stateful)

Lorsque DC1 (`172.16.0.10`) envoie un paquet vers Google DNS (`8.8.8.8`), OPNsense crée une entrée d'état :

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TABLE D'ÉTAT OPNSENSE                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  IP interne:Port       │  IP externe:Port      │  Destination    │  État    │
│─────────────────────────────────────────────────────────────────────────────│
│  172.16.0.10:54321     │  192.168.1.240:54321  │  8.8.8.8:53     │  ACTIF   │
│  172.16.0.11:49152     │  192.168.1.240:49152  │  1.1.1.1:443    │  ACTIF   │
└─────────────────────────────────────────────────────────────────────────────┘
```

Lorsque Google répond à `192.168.1.240:54321`, OPNsense consulte la table d'état : « Ah, c'est en fait `172.16.0.10:54321` » et réécrit la destination avant de transférer.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                    SORTANT : VM de lab → Internet                          │
│────────────────────────────────────────────────────────────────────────────│
│                                                                            │
│  DC1 (172.16.0.10)              OPNsense                  Google (8.8.8.8) │
│        │                           │                            │          │
│        │  Src: 172.16.0.10:54321   │                            │          │
│        │  Dst: 8.8.8.8:53          │                            │          │
│        │ ─────────────────────────►│                            │          │
│        │                           │  Src: 192.168.1.240:54321  │          │
│        │                           │  Dst: 8.8.8.8:53           │          │
│        │                 [crée une entrée d'état]               │          │
│        │                           │ ──────────────────────────►│          │
│                                                                            │
│────────────────────────────────────────────────────────────────────────────│
│                    ENTRANT : Internet → VM de lab (réponse)                │
│────────────────────────────────────────────────────────────────────────────│
│                                                                            │
│        │                           │◄────────────────────────── │          │
│        │                           │  Src: 8.8.8.8:53           │          │
│        │                           │  Dst: 192.168.1.240:54321  │          │
│        │                 [consulte la table d'état]             │          │
│        │◄───────────────────────── │                            │          │
│        │  Src: 8.8.8.8:53          │                            │          │
│        │  Dst: 172.16.0.10:54321   │                            │          │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

C'est le **NAT stateful** : OPNsense mémorise les connexions et gère automatiquement les réponses.

### Types de NAT

| Type | Direction | Ce qu'il fait | Exemple dans le lab |
|:-----|:----------|:--------------|:--------------------|
| **SNAT** (Source NAT) | Sortant | Réécrit l'IP source | VM du lab accédant à Internet |
| **DNAT** (Destination NAT) | Entrant | Réécrit l'IP de destination | Redirection de port vers des serveurs internes |
| **Masquerade** | Sortant | SNAT qui détecte automatiquement l'IP WAN | Lorsque le WAN utilise DHCP |

> [!NOTE]
> Ce lab utilise une **IP WAN statique** (`192.168.1.240`), donc nous configurons des règles SNAT explicites. Si votre WAN utilisait DHCP, vous utiliseriez plutôt le mode Masquerade.

## Réseau de virtualisation

OPNsense s'exécute en tant que VM à l'intérieur de Proxmox, mais il doit se connecter à deux réseaux différents : votre réseau domestique (WAN) et le réseau de lab isolé (LAN). Proxmox utilise des **ponts Linux** pour rendre cela possible.

### Ponts virtuels : Commutateurs logiciels

Considérez un pont comme un commutateur/switch réseau virtuel. Proxmox en crée deux :

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                               HÔTE PROXMOX                                  │
│─────────────────────────────────────────────────────────────────────────────│
│                                                                             │
│  vmbr0 (Pont WAN)                        vmbr1 (Pont LAN)                   │
│  ┌─────────────────────────┐           ┌─────────────────────────┐          │
│  │                         │           │                         │          │
│  │   ┌───────────────┐     │           │   ┌───────────────┐     │          │
│  │   │  eno1         │     │           │   │   (aucun)     │     │          │
│  │   │  NIC physique │     │           │   │   Pas de port │     │          │
│  │   │               │     │           │   │   physique    │     │          │
│  │   └───────┬───────┘     │           │   └───────────────┘     │          │
│  │           │             │           │             │           │          │
│  └───────────┼─────────────┘           └─────────────┼───────────┘          │
│              │                                       │                      │
│     ┌────────┴──────────┐               ┌────────────┼────────────┐         │
│     │                   │               │            │            │         │
│  ┌──┴─────┐         ┌───┴──┐         ┌──┴─────┐    ┌─┴────┐     ┌─┴────┐    │
│  │vtnet0  │         │ ...  │         │vtnet1  │    │ eth0 │     │ eth0 │    │
│  │        │         │      │         │        │    │      │     │      │    │
│  │OPNsense│         │Autres│         │OPNsense│    │ DC1  │     │ DC2  │    │
│  │(WAN)   │         │ VM   │         │(LAN)   │    │      │     │      │    │
│  └────────┘         └──────┘         └────────┘    └──────┘     └──────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                │                                     │
                ▼                                     ▼
       Vers réseau domestique              Isolé (VM uniquement)
       192.168.1.0/24                      172.16.0.0/24
```

| Pont | Port physique | Objectif |
|:-----|:--------------|:---------|
| **vmbr0** | `eno1` (votre NIC) | Se connecte au réseau domestique (WAN d'OPNsense) |
| **vmbr1** | Aucun | Interne uniquement. Les VM du lab communiquent entre elles et avec le LAN d'OPNsense |

**Point clé** : `vmbr1` n'a pas de port physique. C'est un réseau complètement isolé qui existe uniquement à l'intérieur de Proxmox. C'est exactement ce que nous voulons, car les VM du lab ne peuvent pas accidentellement atteindre votre réseau domestique directement.

### VirtIO : Pourquoi nous l'utilisons (et ses particularités)

Les VM peuvent utiliser différents types d'adaptateurs réseau virtuels, par exemple :

| Type | Fonctionnement | Performance | Compatibilité |
|:-----|:---------------|:------------|:--------------|
| **VirtIO** | L'invité sait qu'il est virtualisé, coopère avec l'hyperviseur | Excellente | Nécessite un support pilote |
| **e1000** | Émule du vrai matériel NIC Intel | Faible | Fonctionne avec tout |

VirtIO est **paravirtualisé** : le système d'exploitation invité et l'hyperviseur travaillent ensemble efficacement. OPNsense (FreeBSD) intègre nativement les pilotes VirtIO, donc nous l'utilisons pour de meilleures performances.

> [!WARNING]
> **Le déchargement matériel doit être désactivé dans les VM.**
>
> **Ce que vous devez savoir :** Le réglage post-installation d'OPNsense désactivera automatiquement le déchargement matériel. S'il est activé, votre pare-feu abandonnera ou corrompra aléatoirement des paquets.

## DNS : Pourquoi OPNsense exécute son propre résolveur

Vos VM de lab ont besoin du DNS pour résoudre des noms comme `google.com`. Vous pourriez les pointer directement vers `8.8.8.8`, mais OPNsense exécute son propre résolveur DNS (**Unbound**) pour de bonnes raisons.

### Le problème avec le DNS direct

Si les VM du lab interrogent directement le DNS externe :

1. **Chaque requête va sur Internet**, même les recherches répétées pour le même domaine
2. **Pas de cache** : lent, gaspillage de ressources
3. **Pas de contrôle local** : impossible d'ajouter des entrées DNS personnalisées pour les hôtes du lab
4. **Détournement DNS du FAI** : certains FAI interceptent le DNS pour la publicité/le pistage

### La solution : Résolveur récursif local

OPNsense exécute Unbound, qui effectue une résolution récursive complète et met en cache les résultats :

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    RÉSOLUTION DNS AVEC UNBOUND                              │
└─────────────────────────────────────────────────────────────────────────────┘

Première requête pour "google.com" :

  DC1                 OPNsense              Serveurs racine        Google NS
  │                   (Unbound)             (.)(.com)              (ns1.google.com)
  │                      │                      │                       │
  │ "google.com?"        │                      │                       │
  │─────────────────────►│                      │                       │
  │                      │ "Où est .com ?"      │                       │
  │                      │─────────────────────►│                       │
  │                      │◄─────────────────────│                       │
  │                      │ "Demandez à 192.5.6.30"                      │
  │                      │                      │                       │
  │                      │ "Où est google.com ?"                        │
  │                      │─────────────────────────────────────────────►│
  │                      │◄─────────────────────────────────────────────│
  │                      │ "142.250.185.46"                             │
  │                      │                                              │
  │◄─────────────────────│  [Cache : google.com = 142.250.185.46]       │
  │ "142.250.185.46"     │                                              │

Deuxième requête (depuis n'importe quelle VM du lab) :

  DC2                 OPNsense
  │                   (Unbound)
  │                      │
  │ "google.com?"        │
  │─────────────────────►│
  │◄─────────────────────│   [Cache trouvé ! Pas de requête Internet nécessaire]
  │ "142.250.185.46"     │
```

### Pourquoi c'est important pour le lab

| Avantage | Impact sur le lab |
|:---------|:------------------|
| **Cache** | Recherches répétées plus rapides. Windows fait *beaucoup* de requêtes DNS |
| **DNSSEC** | Valide que les réponses DNS ne sont pas usurpées (important pour AD) |
| **Contrôle local** | Plus tard : intégrer avec le DNS AD pour la résolution de `reginleif.io` |
| **Serveurs amont fiables** | Utiliser Cloudflare (1.1.1.1) et Google (8.8.8.8) au lieu du DNS instable du FAI |

> [!NOTE]
> **Ceci est une configuration DNS temporaire.** Dans le Projet 3, vous déploierez Active Directory avec son propre DNS. OPNsense transférera alors les requêtes `reginleif.io` aux contrôleurs de domaine tout en continuant à gérer la résolution externe.

## Glossaire des termes clés

| Terme | Définition | Utilisation dans ce projet |
|:------|:-----------|:---------------------------|
| **Passerelle** | Dispositif qui route le trafic entre les réseaux | OPNsense route entre le lab (172.16.0.0/24) et le réseau domestique |
| **NAT** | Network Address Translation : réécrit les IP pour que les réseaux privés puissent atteindre Internet | OPNsense réécrit les IP du lab vers son IP WAN |
| **Table d'état** | Mémoire des connexions actives du NAT/pare-feu, permettant le trafic de retour | Comment OPNsense sait où envoyer les réponses |
| **Pont** | Commutateur virtuel connectant les VM | `vmbr0` (WAN) et `vmbr1` (LAN) dans Proxmox |
| **VirtIO** | Pilotes paravirtualisés où le système d'exploitation invité coopère avec l'hyperviseur pour l'efficacité | OPNsense utilise des NIC VirtIO pour de meilleures performances |
| **pf** | Packet Filter : moteur de pare-feu stateful FreeBSD/OpenBSD | Technologie de pare-feu sous-jacente d'OPNsense |
| **Règle anti-verrouillage** | Règle de sécurité intégrée garantissant l'accès LAN à la gestion du pare-feu | Empêche le verrouillage accidentel lors de la configuration |
| **Unbound** | Résolveur DNS récursif avec cache | Service DNS d'OPNsense |
| **DNSSEC** | Extensions de sécurité DNS qui valident cryptographiquement les réponses DNS | Activé dans Unbound pour empêcher l'usurpation DNS |
| **Résolution récursive** | Serveur DNS qui interroge les serveurs racine/TLD/autoritatifs au nom des clients | Unbound fait une récursion complète (pas seulement du transfert) |
