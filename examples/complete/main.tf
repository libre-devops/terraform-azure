resource "random_string" "sa_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = var.tags
}

# A storage account locked down to pass a trivy config scan: HTTPS only, TLS 1.2 or
# higher, no public network access, and no anonymous blob access.
resource "azurerm_storage_account" "this" {
  name                = substr("st${replace(var.name, "-", "")}${random_string.sa_suffix.result}", 0, 24)
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  account_tier             = "Standard"
  account_replication_type = var.account_replication_type
  account_kind             = "StorageV2"

  min_tls_version                 = var.min_tls_version
  https_traffic_only_enabled      = true
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false

  # Default-deny network rules so the account is not open by default (trivy AZU-0012).
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}
