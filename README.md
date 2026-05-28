[![Terraform Version](https://img.shields.io/badge/terraform-%5E1.8-blue)](https://www.terraform.io)

# Network-as-Code NX-OS Terraform

Use Terraform to operate and manage Cisco NX-OS devices using purpose built modules. Everything can also be executed locally (without CI/CD) following the instructions below.

## Setup

Install [Terraform](https://www.terraform.io/downloads) (> 1.9.0), and the following Python tools:

- [nac-validate](https://github.com/netascode/nac-validate)
- [nac-test](https://github.com/netascode/nac-test)

```shell
pip install nac-validate nac-test
```

Set environment variables with credentials:

```shell
export NXOS_USERNAME=admin
export NXOS_PASSWORD=Cisco123
```

## Initialization

```shell
terraform init
```

This command will download all the required providers and modules from the public Terraform Registry ([https://registry.terraform.io](https://registry.terraform.io)).

## Pre-Change Validation

```shell
terraform apply -target=module.nxos.local_sensitive_file.model
nac-validate model.yaml
```

The first command renders the YAML input files located in `data/` into a `model.yaml` file which contains the complete device configuration. The second command performs syntactic and semantic validation of the rendered configuration.

## Terraform Plan/Apply

```shell
terraform apply
```

This command will apply/deploy the desired configuration.

## Testing

```shell
nac-test --data model.yaml --templates tests/templates --filters tests/filters --output tests/results
```

This command will render and execute a set of tests and provide the results in a report (`tests/results/log.html`).

## Terraform Destroy

```shell
terraform destroy
```

This command will delete all the previously created configuration.

## Documentation

Further documentation is available [here](https://netascode.cisco.com).