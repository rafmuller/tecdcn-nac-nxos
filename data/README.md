# Data — Network as Code (NaC) Data Model for NX-OS

This directory contains the **Network-as-Code (NaC) data model** instances consumed by the [`netascode/nac-nxos/nxos`](https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest) Terraform module. The YAML here is the **source of truth** for the fabric: every device, variable, VRF, VLAN, and interface group rendered onto NX-OS originates from these files.

The model, schema, and validation rules are documented upstream:

- Network as Code home: <https://netascode.cisco.com>
- NX-OS data model reference: <https://netascode.cisco.com/docs/data_models/nxos/overview/>

> All keys used in this directory live under the top-level `nxos:` root and conform to the schema published at the link above. When in doubt about a field name, attribute, or allowed value, treat the upstream documentation as authoritative.

## How the module consumes this directory

The root module (`../main.tf`) is configured as:

```hcl
module "nxos" {
  source  = "netascode/nac-nxos/nxos"
  version = "0.2.0"

  yaml_directories     = ["data/"]
  template_directories = ["templates/"]
}
```

At plan time the module:

1. **Recursively reads every `*.yaml` / `*.nac.yaml`** file under `data/` and **deep-merges** them into a single `nxos` document.
2. **Renders templates** referenced from `nxos.templates` (paths under `templates/`) using the per-device, per-group, and global `variables` blocks as input.
3. **Resolves `device_groups`** — each device receives the union of template fragments attached to every group it belongs to.
4. **Applies the merged configuration** to each device defined under `nxos.devices` via the underlying NX-OS providers.

See the official model overview for the full merge / precedence behavior: <https://netascode.cisco.com/docs/data_models/nxos/overview/>.

## Directory layout

```
data/
├── global.nac.yaml             # Fabric-wide variables, device_groups, and template registry
├── spines/                     # Spine devices and shared spine interface groups
│   ├── spine-01.nac.yaml
│   ├── spine-02.nac.yaml
│   └── spine_interface_groups.nac.yaml
├── leafs/                      # Leaf devices and shared leaf interface groups
│   ├── leaf-01.nac.yaml
│   ├── leaf-02.nac.yaml
│   ├── leaf-03.nac.yaml
│   ├── leaf-04.nac.yaml
│   └── leaf_interface_groups.nac.yaml
├── networks/                   # Tenant VRFs and L2 VXLAN networks (tenant-scoped device groups)
│   ├── vrfs.yaml
│   └── net1.yaml
└── borders/                    # Reserved for border-leaf devices (currently empty)
```

Subdirectory layout is **organizational only** — the module does not infer roles from paths. Roles are expressed through `device_groups`.

## Top-level keys in this model

All files merge into a single document rooted at `nxos:`. The model surfaces the following top-level keys:

| Key | Used in | Purpose |
|---|---|---|
| `nxos.global.variables` | `global.nac.yaml` | Fabric-wide variables (`bgp_asn`, `ospf_area_id`, `l2vni_base`, `l3vni_base`, …) available as inputs to every template. |
| `nxos.device_groups` | `global.nac.yaml`, `networks/*.yaml` | Named groups that attach templates and/or variables to a set of devices. Devices may be listed inline (`devices: [...]`) or attach themselves by referencing the group in their own `device_groups`. |
| `nxos.templates` | `global.nac.yaml` | Registry mapping template names (referenced by `device_groups[*].templates`) to files under `templates/`. |
| `nxos.interface_groups` | `leafs/leaf_interface_groups.nac.yaml`, `spines/spine_interface_groups.nac.yaml` | Reusable per-interface configuration blocks attached to ethernet / loopback / port-channel entries via `interface_groups: [<name>]`. |
| `nxos.devices` | `spines/*.nac.yaml`, `leafs/*.nac.yaml` | Per-device definitions: `name`, `url`, `device_groups`, `variables`, and a `configuration` block that mirrors the full NX-OS data-model schema. |

Refer to <https://netascode.cisco.com/docs/data_models/nxos/overview/> for the complete list of nested attributes under `configuration` (system, feature, routing, vrfs, vlan, evpn, interfaces, vpc, fabric_forwarding, …).

## Subdirectories

### `global.nac.yaml`
Defines the **fabric scaffolding**:
- `nxos.global.variables` — fabric ASN, OSPF area, VNI base values, anycast IP.
- `nxos.device_groups` — role groups (`SPINES`, `LEAFS`, `VPC`, `LEAFS-AUTO`) and the templates each role receives.
- `nxos.templates` — the file registry that gives a name to every `.yaml.tftpl` under `templates/`.

Group `LEAFS-AUTO` aggregates every template needed to bring up a leaf end-to-end from templates alone (features, BGP, NVE, OSPF, PIM, loopbacks, fabric interfaces, fabric-forwarding, port-channels, VRFs, networks).

### `spines/`
- `spine-01.nac.yaml`, `spine-02.nac.yaml` — per-device files. Each defines `name`, management `url`, `device_groups: [SPINES]`, per-device `variables` (e.g. `route_peering_ip`), and a `configuration` block for static (non-templated) elements (OSPF process, PIM RP, loopbacks, fabric ethernets via `interface_groups`).
- `spine_interface_groups.nac.yaml` — shared interface groups (`SPINE_FABRIC_INTERFACES`, `SPINE_LOOPBACK_INTERFACES`) attached to ethernet / loopback entries by name.

### `leafs/`
- `leaf-01.nac.yaml` … `leaf-04.nac.yaml` — per-device files. Each declares `device_groups: [LEAFS, VPC]` (or similar), per-device `variables` (`router_id`, `routing_loopback_ip`, `vtep_loopback_ip`, `vtep_loopback_secondary_ip`, `vpc_*`, `interface_port_channels`, …), and a `configuration` block that may statically include VRFs, VLANs, NVE bindings, SVIs, port-channels, and downlink ethernets.
- `leaf_interface_groups.nac.yaml` — shared groups (`LEAF_FABRIC_INTERFACES`, `LEAF_LOOPBACK_INTERFACES`, `VMWARE_DVS_STACK1_INTERFACES`) attached to interfaces by name.

### `networks/`
**Tenant-facing** data — VRFs and L2 VXLAN networks deployed on a subset of leaves through tenant device-groups:
- `vrfs.yaml` — declares device-group `VRF_DVS1` (devices `leaf03`, `leaf04`) with `variables.vrfs[*]` describing the VRF; rendered by the `leaf-vrfs-template`.
- `net1.yaml` — declares device-group `ENGNET` (same leaves) with `variables.vxlan_networks[*]` describing L2 segments; rendered by the `leaf-networks-template`.

This is how the model expresses *"which tenant lives on which leaves"* without modifying per-leaf YAML.

### `borders/`
Reserved for border-leaf devices (external connectivity, route leaking, VRF-Lite). Currently empty (`.gitkeep` only).

## Adding to the model

- **A new device** → add a file under `data/spines/`, `data/leafs/`, or `data/borders/`. Set `nxos.devices[*].name`, `url`, and the appropriate `device_groups`. Provide all `variables` consumed by the templates attached to those groups.
- **A new fabric-wide template** → add the `.yaml.tftpl` under `templates/`, register it under `nxos.templates` in `global.nac.yaml`, and attach it to the relevant role group.
- **A new tenant (VRF / networks)** → add YAML under `data/networks/` declaring a tenant device-group with `devices`, `templates`, and `variables` (`vrfs` and/or `vxlan_networks`).
- **A new shared interface configuration** → add it under `nxos.interface_groups` in the appropriate `*_interface_groups.nac.yaml`, then reference the name from any interface entry.

Validate with `terraform plan` from the repo root before applying.

## References

- Network as Code: <https://netascode.cisco.com>
- NX-OS data model overview: <https://netascode.cisco.com/docs/data_models/nxos/overview/>
- Terraform module: <https://registry.terraform.io/modules/netascode/nac-nxos/nxos/latest>
- Rendered templates: `../templates/` (`leafs/`, `spines/`, `networks/`)
