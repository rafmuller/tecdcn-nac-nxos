# Network Templates — NaC for NX-OS VXLAN EVPN

Terraform templates (`.tftpl`) used by the [`netascode/nac-nxos/nxos`](https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest) module to render Network-as-Code (NaC) YAML configuration for **VRFs** and **L2 VXLAN networks** on leaf switches in a VXLAN EVPN fabric.

Unlike the per-role templates in `templates/leafs/` (which build the fabric underlay/overlay infrastructure), these templates are **tenant-facing**: they instantiate VRFs and Layer-2 segments on the set of leaves where a tenant lives. They are typically attached to **tenant-scoped device groups** (e.g. `VRF_DVS1`, `ENGNET`) that enumerate the leaves participating in the VRF / network.

Each template emits a fragment of the `nxos.devices[*].configuration` document. At plan time, the NaC module renders every template assigned to a device (via `device_groups` → `templates` in `data/global.nac.yaml`), merges all fragments with the device's static YAML, and pushes the result to NX-OS.

## How rendering works

```
data/networks/*.yaml              templates/networks/*.tftpl
    │                                       │
    │ tenant device_groups with             │ Terraform template
    │ devices + variables (vrfs,            │ interpolation
    │ vxlan_networks) + templates           │
    ▼                                       ▼
data/leafs/leaf-XX.nac.yaml ──► netascode/nac-nxos/nxos ──► NX-OS device
       (leaf membership)                (merge + apply)
```

- **Tenant variables** (`vrfs`, `vxlan_networks`) come from a tenant device-group's `variables` block in `data/networks/*.yaml`, not from the per-device files.
- **Global variables** (`l2vni_base`, `l3vni_base`, …) come from `nxos.global.variables` and act as fallback defaults via `try(...)` inside the templates.
- A leaf inherits these templates by being listed in the tenant device-group's `devices:` list.

## Templates

| Template | Purpose | Required input |
|---|---|---|
| `vrfs.yaml.tftpl` | Instantiates one or more tenant VRFs end-to-end: the VRF object (RD/RT auto, IPv4 + IPv6), the L3VNI VLAN, the L3VNI SVI (`ip forward`, IPv6 link-local), the NVE L3VNI binding (`associate_vrf: true`), and per-VRF BGP with `advertise_l2vpn_evpn`, `maximum_paths: 2`, and `direct` redistribution via the `fabric-rmap-redist-subnet` route-map (defined in `templates/leafs/bgp.yaml.tftpl`). | `vrfs` (list) |
| `networks.yaml.tftpl` | Instantiates L2 VXLAN networks (anycast-GW SVIs): the access VLAN with L2VNI mapping, the NVE L2VNI binding (ARP suppression, multicast group), the SVI with anycast-GW and tag `12345` (matched by the redistribution route-map), and the EVPN VNI (auto RD + RT). | `vxlan_networks` (list) |

## Input schema

### `vrfs` — consumed by `vrfs.yaml.tftpl`
List of VRF objects. Per entry:

| Field | Required | Notes |
|---|---|---|
| `vrf_name` | yes | VRF name (e.g. `VRF_DVS1`). |
| `vrf_vni` | yes | L3VNI for the VRF (e.g. `51000`). |
| `vrf_vlan` | yes | VLAN id carrying the L3VNI SVI (e.g. `2001`). |
| `vrf_description` | no | Defaults to `"VRF for <vrf_name>"`. |
| `vrf_l3vni` | no | Currently commented out in the template; reserved for future use. |

### `vxlan_networks` — consumed by `networks.yaml.tftpl`
List of L2 network objects. Per entry:

| Field | Required | Notes |
|---|---|---|
| `vlan` | yes | Access VLAN id (e.g. `30`). |
| `vrf` | yes | Owning VRF name (must match a `vrf_name` rendered by `vrfs.yaml.tftpl`). |
| `ip` | yes | Anycast-GW SVI address with mask (e.g. `192.168.88.1/24`). |
| `net_name` | no | Defaults to `VLAN_<vlan>`. |
| `l2vni` | no | Defaults to `l2vni_base + vlan` (and falls back to `20000 + vlan` if `l2vni_base` is not defined globally). |
| `mcast_group` | no | Defaults to `239.1.1.1` for the NVE underlay multicast group. |

> Heads-up: in `networks.yaml.tftpl` the NVE and EVPN VNI fallback expression uses `l3vni_base` rather than `l2vni_base`. Always pass `l2vni` explicitly (as `net1.yaml` does) to avoid base-confusion edge cases.

## Wiring templates to devices

Templates here are wired up via **tenant-scoped device groups** that explicitly enumerate which leaves run the tenant. Example (`data/networks/vrfs.yaml`):

```yaml
nxos:
  device_groups:
    - name: VRF_DVS1
      devices: [leaf03, leaf04]
      templates:
        - leaf-vrfs-template
      variables:
        vrfs:
          - vrf_name: VRF_DVS1
            vrf_description: VRF for DVS1
            vrf_vni: 51000
            vrf_vlan: 2001
            vrf_l3vni: true
```

And `data/networks/net1.yaml`:

```yaml
nxos:
  device_groups:
    - name: ENGNET
      devices: [leaf03, leaf04]
      templates:
        - leaf-networks-template
      variables:
        vxlan_networks:
          - net_name: Net1
            vrf: VRF_DVS1
            vlan: 30
            l2vni: 20030
            ip: 192.168.88.1/24
          - net_name: Net2
            vrf: VRF_DVS1
            vlan: 40
            l2vni: 20040
            ip: 192.168.89.1/24
```

The templates themselves are registered in `data/global.nac.yaml`:

```yaml
nxos:
  templates:
    - name: leaf-vrfs-template
      type: file
      file: templates/networks/vrfs.yaml.tftpl
    - name: leaf-networks-template
      type: file
      file: templates/networks/networks.yaml.tftpl
```

## Conventions & assumptions

- **Layered tenancy**: VRFs are deployed first (`vrfs.yaml.tftpl`); networks (`networks.yaml.tftpl`) reference an existing VRF by name. Always include both the VRF tenant group and the network tenant group on the same set of leaves.
- **Per-leaf scope**: A leaf only renders these fragments if it appears in the tenant device-group's `devices` list — keep the list of leaves consistent between the VRF and the networks that live in it.
- **Route advertisement**: SVIs are tagged `12345`, matched by the `fabric-rmap-redist-subnet` route-map defined in `templates/leafs/bgp.yaml.tftpl`. Removing or changing that tag breaks subnet redistribution into EVPN.
- **Address families**: VRFs and per-VRF BGP are dual-stack (IPv4 + IPv6); SVIs use IPv6 link-local only by default — add explicit IPv6 addressing in static YAML if required.
- **Defaults via `try(...)`**: Most optional fields fall back to sensible values (anycast multicast group, derived VNI, derived names). Pass explicit values when fabric-wide consistency matters.

## Adding a new tenant

1. Decide which leaves host the tenant.
2. Add a new file under `data/networks/` (or extend an existing one) that defines:
   - a device-group for the VRF (`devices`, `templates: [leaf-vrfs-template]`, `variables.vrfs`).
   - a device-group for the L2 networks (`devices`, `templates: [leaf-networks-template]`, `variables.vxlan_networks`).
3. Make sure the underlying leaves are already configured with the fabric-level templates from `templates/leafs/` (features, BGP, NVE, etc.).
4. Run `terraform plan` from the repo root to validate rendering before `apply`.

## Adding a new template

1. Create `templates/networks/<name>.yaml.tftpl` rendering a fragment under the `nxos.devices[*].configuration` schema (mirror the structure of `data/leafs/leaf-01.nac.yaml`).
2. Use `${var}` for scalars and `%{ for ... }` / `%{ endfor }` for iteration over tenant lists; favour `try(...)` for optional fields so tenant YAML stays terse.
3. Register the template in `data/global.nac.yaml` under `nxos.templates` and attach it to a tenant device-group in `data/networks/`.
4. Run `terraform plan` from the repo root to validate rendering before `apply`.

## Related

- Root module: `../../main.tf`
- Leaf fabric templates: `../leafs/`
- Spine templates: `../spines/`
- Tenant data: `../../data/networks/`
- NaC module docs: https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest
