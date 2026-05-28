# Leaf Templates — NaC for NX-OS VXLAN EVPN

Terraform templates (`.tftpl`) used by the [`netascode/nac-nxos/nxos`](https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest) module to render Network-as-Code (NaC) YAML configuration for **leaf** switches in a VXLAN EVPN fabric.

Each template emits a fragment of the `nxos.devices[*].configuration` document. At plan time, the NaC module renders every template assigned to a device (via `device_groups` → `templates` in `data/global.nac.yaml`), merges all fragments with the device's static YAML, and pushes the result to NX-OS.

## How rendering works

```
data/global.nac.yaml              templates/leafs/*.tftpl
    │                                       │
    │ device_groups + templates             │ Terraform template
    │ mapping                               │ interpolation
    ▼                                       ▼
data/leafs/leaf-XX.nac.yaml ──► netascode/nac-nxos/nxos ──► NX-OS device
       (per-device vars)               (merge + apply)
```

- Per-device variables (`vpc_domain_id`, `router_id`, `routing_loopback_ip`, …) come from `devices[*].variables` in each leaf's YAML.
- Global variables (`bgp_asn`, `ospf_area_id`, …) come from `nxos.global.variables`.
- `GLOBAL` exposes the merged top-level document inside templates (used by `bgp.yaml.tftpl` to iterate spines).

## Templates

| Template | Purpose | Required variables |
|---|---|---|
| `features.yaml.tftpl` | Enables NX-OS features required for VXLAN EVPN (`bgp`, `evpn`, `nv_overlay`, `fabric_forwarding`, `ospf`, `pim`, `vpc`, `lacp`, `lldp`, `bfd`, `udld`, `interface_vlan`, `vn_segment_vlan_based`). | none |
| `fabric-forwarding.yaml.tftpl` | Sets the fabric-wide anycast gateway MAC. | none (hard-coded) |
| `loopback-interfaces.yaml.tftpl` | Loopback 0 (routing/RID) and Loopback 1 (VTEP) with OSPF + PIM. Loopback 1 carries a secondary address for the vPC virtual VTEP. | `routing_loopback_ip`, `vtep_loopback_ip`, `vtep_loopback_secondary_ip`, `ospf_area_id` |
| `fabric-interfaces.yaml.tftpl` | Configures uplinks `Eth1/47` and `Eth1/48` as IP-unnumbered P2P OSPF interfaces with PIM. | `ospf_area_id` |
| `ospf.yaml.tftpl` | Underlay OSPF process `1`. | `router_id`, `ospf_area_id` |
| `pim.yaml.tftpl` | Anycast RP using Loopback 250 with two RP addresses (`10.250.250.1`, `10.250.250.2`). | none (hard-coded) |
| `nve-interface.yaml.tftpl` | NVE source on Loopback 1, BGP host reachability, virtual RMAC advertisement. | none |
| `bgp.yaml.tftpl` | iBGP overlay: `SPINE-PEERS` peer-template (L2VPN EVPN, route-reflector client, send-community), plus a `route-map` for subnet redistribution. Iterates `GLOBAL.devices` filtered to the `SPINES` device group to generate neighbors. | `bgp_asn`, `router_id`; spine devices must define `variables.route_peering_ip` |
| `vpc-domains.yaml.tftpl` | vPC domain with peer-gateway, peer-switch, L3 peer-router, ARP/ND sync, graceful consistency, and the peer-link port-channel on `Eth1/46`. | `vpc_domain_id`, `vpc_port_channel_id`, `vpc_local_ip`, `vpc_peer_ip` |
| `portchannel-interfaces.yaml.tftpl` | Renders downstream host-facing port-channels and their member ethernet ports as vPCs (trunk all VLANs, edge + BPDU guard). | `interface_port_channels` (list) |

## Variable reference

### Per-device (`devices[*].variables`)
- `router_id` — BGP/OSPF router-id (typically the routing loopback IP without prefix).
- `routing_loopback_ip` — Loopback 0 address with mask, e.g. `10.0.0.21/32`.
- `vtep_loopback_ip` — Loopback 1 primary address (per-switch unique VTEP IP).
- `vtep_loopback_secondary_ip` — Loopback 1 secondary, shared between vPC peers (virtual VTEP).
- `vpc_domain_id`, `vpc_port_channel_id` — vPC domain id and peer-link PC id.
- `vpc_local_ip`, `vpc_peer_ip` — vPC keepalive source/destination (uses `management` VRF).
- `interface_port_channels` — list of `{ pc_id, ports: [<eth ids>] }` consumed by `portchannel-interfaces.yaml.tftpl`.

### Global (`nxos.global.variables`)
- `bgp_asn` — Fabric ASN (iBGP).
- `ospf_area_id` — Underlay OSPF area (e.g. `0.0.0.0`).
- `anycast_ip`, `l2vni_base`, `l3vni_base` — Available for downstream templates.

### Implicit / GLOBAL
- `GLOBAL.devices` — the full merged device list. `bgp.yaml.tftpl` filters `device_groups` for `SPINES` and reads each spine's `variables.route_peering_ip` to build the EVPN neighbor list.

## Wiring templates to devices

Templates are attached to devices through `device_groups` in `data/global.nac.yaml`. Example:

```yaml
nxos:
  device_groups:
    - name: LEAFS
      templates:
        - leaf-bgp-template
        - leaf-nve-interface-template
        - leaf-features-template
    - name: VPC
      templates:
        - vpc-domain-template

  templates:
    - name: leaf-bgp-template
      type: file
      file: templates/leafs/bgp.yaml.tftpl
    # ...
```

A leaf device picks up template fragments by listing the appropriate group(s) in its YAML:

```yaml
nxos:
  devices:
    - name: leaf01
      device_groups: [LEAFS, VPC]
      variables:
        router_id: 10.0.0.21
        routing_loopback_ip: 10.0.0.21/32
        vtep_loopback_ip: 10.100.100.1/32
        vtep_loopback_secondary_ip: 10.100.101.11/32
        vpc_domain_id: 901
        vpc_port_channel_id: 1
        vpc_local_ip: 10.15.37.73
        vpc_peer_ip: 10.15.37.74
```

The `LEAFS-AUTO` device group in `data/global.nac.yaml` shows the full template set required to bring up a leaf end-to-end from templates alone (features, BGP, NVE, OSPF, PIM, loopbacks, fabric interfaces, fabric-forwarding, port-channels, plus VRF/networks templates).

## Conventions & assumptions

- **Uplinks** are fixed on `Eth1/47–1/48`; **vPC peer-link** is fixed on `Eth1/46` with PC id supplied by `vpc_port_channel_id`.
- **Underlay**: OSPF process `1`, IP-unnumbered to Loopback 0, area from `ospf_area_id`.
- **Multicast**: PIM sparse with anycast RP on Loopback 250 (`10.250.250.1/.2`). Adjust `pim.yaml.tftpl` if your RP topology differs.
- **Overlay**: iBGP L2VPN-EVPN to spines acting as route reflectors; leaves are RR-clients via the `SPINE-PEERS` template.
- **Anycast GW MAC**: `20:20:00:00:10:12` (single value across fabric — fabric-forwarding template).
- **MTU**: 9216 on fabric/host ports; 1500 on the vPC peer-link.

## Adding a new template

1. Create `templates/leafs/<name>.yaml.tftpl` rendering a fragment under the `nxos.devices[*].configuration` schema (mirror the structure of `data/leafs/leaf-01.nac.yaml`).
2. Reference any per-device or global variables with `${var_name}`. Use `%{ for ... }` / `%{ endfor }` for iteration and `GLOBAL.*` for cross-device data.
3. Register the template in `data/global.nac.yaml` under `nxos.templates` and attach it to a `device_group`.
4. Run `terraform plan` from the repo root to validate rendering before `apply`.

## Related

- Root module: `../../main.tf`
- Spine templates: `../spines/`
- Per-device data: `../../data/leafs/`, `../../data/spines/`
- Interface groups: `../../data/leafs/leaf_interface_groups.nac.yaml`
- NaC module docs: https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest
