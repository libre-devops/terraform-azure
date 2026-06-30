<div align="center">

<a href="https://libredevops.org">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
    <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
  </picture>
</a>

# Terraform for Azure

A single GitHub Action to plan, apply, and destroy Terraform on Azure, with tflint and trivy gating.

[![CI](https://github.com/libre-devops/terraform-azure/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/terraform-azure/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/libre-devops/terraform-azure?sort=semver&label=release)](https://github.com/libre-devops/terraform-azure/releases/latest)
[![Last commit](https://img.shields.io/github/last-commit/libre-devops/terraform-azure)](https://github.com/libre-devops/terraform-azure/commits)
[![License](https://img.shields.io/github/license/libre-devops/terraform-azure)](./LICENSE)

</div>

---

> **Status: active development.** This action is the v-next replacement for the separate
> `terraform-plan-azure`, `terraform-plan-destroy-azure`, `terraform-apply-azure`, and
> `terraform-destroy-azure` actions, collapsed into one. Interfaces may change until the first
> tagged release.

## Overview

`terraform-azure` is one composite GitHub Action that runs the full Terraform lifecycle against
Azure: init, validate, lint, scan, plan, apply, and destroy. It replaces the four older
single-purpose Libre DevOps actions with a single action driven by `run-*` toggles, authenticates
to Azure with OIDC, and gates configuration with [tflint](https://github.com/terraform-linters/tflint)
and [trivy](https://github.com/aquasecurity/trivy). It builds on the
[LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers) PowerShell
module and follows the [Libre DevOps Terraform standard](https://libredevops.org/docs/documents/terraform-standards).

## Usage

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # required for Azure OIDC
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Terraform plan
        uses: libre-devops/terraform-azure@v1
        with:
          terraform-code-location: examples
          terraform-stack-to-run-json: '["complete"]'
          run-terraform-plan: true
          arm-client-id: ${{ vars.AZURE_CLIENT_ID }}
          arm-tenant-id: ${{ vars.AZURE_TENANT_ID }}
          arm-subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
          # The remote state account is firewalled. The action opens this runner's IP before the
          # run and always closes it after (on by default). These come from the org secrets the
          # tenant bootstrap sets.
          firewall-storage-account-name: ${{ secrets.TFSTATE_STORAGE_ACCOUNT }}
          firewall-storage-resource-group: ${{ secrets.TFSTATE_RESOURCE_GROUP }}
```

## Inputs

The full input reference is documented below once the interface settles. Key toggles:
`run-terraform-init`, `run-terraform-validate`, `run-terraform-plan`, `run-terraform-apply`,
`run-terraform-plan-destroy`, `run-terraform-destroy`, `run-tflint`, and `run-trivy`.

## Requirements

- An Azure identity federated for OIDC (no stored secrets), with the roles its Terraform needs.
- Terraform (installed by the action via tenv) and, when scanning, tflint and trivy.

## Developing and releasing

Local development and releases use **PowerShell 7+** and **[`just`](https://github.com/casey/just)**
(`brew install just`, or `uv tool add rust-just` then `uv run just <recipe>`), since the recipes
wrap the same [LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers)
module the action runs. `just update-ldo-pwsh` installs or force-updates that module from PSGallery;
`just validate` and `just test` run the checks (with `just scan` for Trivy only and `just pwsh-analyze`
for PSScriptAnalyzer only); to release, bump and
publish with `just increment-release [patch|minor|major]`, then move the major alias with
`just force-push-tag v1`.

## Contributing

Issues and pull requests are welcome. Please read the
[Libre DevOps standards](https://libredevops.org/docs/documents) and keep changes consistent with
them. Run the repository checks before opening a pull request.

## License

Released under the [MIT License](./LICENSE).

---

<div align="center">
<sub>
Part of <a href="https://libredevops.org">Libre DevOps</a>: free, open, and opinionated DevOps
tooling and standards. This project is provided as-is, without warranty; review and test it
against your own requirements before use in production.
</sub>
</div>
