module "nxos" {
  source  = "netascode/nac-nxos/nxos"
  version = "0.2.0"

  # yaml_directories     = ["data", "data/spines/", "data/leafs/", "data/networks/"]
  yaml_directories     = ["data/"]
  template_directories = ["templates/"]
}
