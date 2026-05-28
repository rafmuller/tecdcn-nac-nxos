# Spine Templates — NaC for NX-OS VXLAN EVPN

Terraform templates (`.tftpl`) used by the [`netascode/nac-nxos/nxos`](https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest) module to render Network-as-Code (NaC) YAML configuration for **spine** switches in a VXLAN EVPN fabric.

Spines in this design act as **route reflectors** for the L2VPN-EVPN overlay and as transit routers in the OSPF underlay. They do not run vPC, NVE, or fabric-forwarding — those concerns live on leaves.

Each template emits a fragment of the `nxos.devices[*].configuration` document. At plan time, the NaC module renders every template assigned to a device (via `device_groups` → `templates` in `data/global.nac.yaml`), merges all fragments with the device's static YAML, and pushes the result to NX-OS.

## How rendering works

```
data/global.nac.yaml              templates/spines/*.tftpl
    │                                       │
    │ device_groups + templates             │ Terraform template
    │ mapping                               │ interpolation
    ▼                                       ▼
data/spines/spine-XX.nac.yaml ──► netascode/nac-nxos/nxos ──► NX-OS device
       (per-device vars)                (merge + apply)
```

- Per-device variables (`route_peering_ip`, …) come from `devices[*].variables` in each spine's YAML.
- Global variables (`bgp_asn`, `ospf_area_id`, …) come from `nxos.global.variables`.
- `GLOBAL` exposes the merged top-level document inside templates (used by `bgp.yaml.tftpl` to iterate leaves).

## Templates

| Template | Purpose | Required variables |
|---|---|---|
| `features.yaml.tftpl` | Enables NX-OS features required on a spine: `bgp`, `evpn`, `nv_overlay`, `fabric_forwarding`, `ospf`, `pim`, `bfd`, `udld`. Note: no `vpc`, `lacp`, `interface_vlan`, or `vn_segment_vlan_based` — spines stay L3-only. | none |
| `bgp.yaml.tftpl` | iBGP overlay route reflector: defines the `LEAF-PEERS` peer-template (L2VPN-EVPN, send-community standard/extended, `route_reflector_client: true`, `advertise_gateway_ip: true`). Iterates `GLOBAL.devices` filtered to the `LEAFS` **or** `LEAFS-AUTO` device groups, and creates one neighbor per leaf using each leaf's `variables.routing_loopback_ip`. | `bgp_asn`; every leaf must define `variables.routing_loopback_ip` |

## Variable reference

### Per-device (`devices[*].variables`)
- `route_peering_ip` — Spine's BGP/loopback peering address advertised to leaves (referenced from the leaf `bgp.yaml.tftpl` template when it iterates `SPINES`).

> Note: the spine `bgp.yaml.tftpl` template here does **not** set `router_id` directly — the router-id is typically configured on the OSPF process in the spine's static YAML (see `data/spines/spine-01.nac.yaml`).

### Global (`nxos.global.variables`)
- `bgp_asn` — Fabric ASN used for both the local ASN and the `remote_as` on `LEAF-PEERS` (iBGP).
- `ospf_area_id` — Available for underlay configuration in static YAML or future templates.

### Implicit / GLOBAL
- `GLOBAL.devices` — the full merged device list. `bgp.yaml.tftpl` filters `device_groups` for `LEAFS` or `LEAFS-AUTO` and reads each leaf's `variables.routing_loopback_ip` to build the EVPN neighbor list. This means: **adding a new leaf to `data/leafs/` automatically adds it as a neighbor on every spine** — no spine YAML change required.

## Wiring templates to devices

Templates are attached to devices through `device_groups` in `data/global.nac.yaml`. Example:

```yaml
nxos:
  device_groups:
    - name: SPINES
      templates:
        - spine-features-template
        - bgp-spines-template

  templates:
    - name: spine-features-template
      type: file
      file: templates/spines/spine-features.yaml.tftpl
    - name: bgp-spines-template
      type: file
      file: templates/spines/bgp.yaml.tftpl
```

A spine device picks up template fragments by listing the `SPINES` group:

```yaml
nxos:
  devices:
    - name: spine01
      device_groups: [SPINES]
      variables:
        route_peering_ip: 10.0.0.11
      configuration:
        # OSPF, PIM, loopbacks (0 and 250), fabric ethernets via interface_groups,
        # etc. live in static YAML — see data/spines/spine-01.nac.yaml
```

## Conventions & assumptions

- **Role**: Pure L3 transit + EVPN route reflector. No vPC, no NVE, no anycast gateway.
- **Underlay**: OSPF process `1`, area from global `ospf_area_id`, configured in the spine's static YAML.
- **Multicast**: PIM sparse with anycast RP on Loopback 250 (`10.250.250.1` on spine01, `10.250.250.2` on spine02) — the RP pair the leaf `pim.yaml.tftpl` template points to.
- **Overlay**: iBGP L2VPN-EVPN; spines are route reflectors (`route_reflector_client: true`) for all leaves discovered dynamically via `GLOBAL.devices`.
- **Fabric interfaces**: Defined per-device via the `SPINE_FABRIC_INTERFACES` interface group, not via a template.

## Adding a new template

1. Create `templates/spines/<name>.yaml.tftpl` rendering a fragment under the `nxos.devices[*].configuration` schema (mirror the structure of `data/spines/spine-01.nac.yaml`).
2. Reference any per-device or global variables with `${var_name}`. Use `%{ for ... }` / `%{ endfor }` for iteration and `GLOBAL.*` for cross-device data.
3. Register the template in `data/global.nac.yaml` under `nxos.templates` and attach it to the `SPINES` device group.
4. Run `terraform plan` from the repo root to validate rendering before `apply`.

## Related

- Root module: `../../main.tf`
- Leaf templates: `../leafs/`
- Per-device data: `../../data/spines/`, `../../data/leafs/`
- Interface groups: `../../data/spines/spine_interface_groups.nac.yaml`
- NaC module docs: https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest
