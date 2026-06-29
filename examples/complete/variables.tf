variable "location" {
  description = "Azure region for the resources. Example: uksouth."
  type        = string
  default     = "uksouth"
}

variable "name" {
  description = "Short name used to build the resource names."
  type        = string
  default     = "ldo-tfaz-cmp"
}

variable "account_replication_type" {
  description = "Storage account replication type."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type must be one of: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "min_tls_version" {
  description = "Minimum TLS version for the storage account."
  type        = string
  default     = "TLS1_2"

  validation {
    condition     = contains(["TLS1_2", "TLS1_3"], var.min_tls_version)
    error_message = "min_tls_version must be TLS1_2 or TLS1_3."
  }
}

variable "tags" {
  description = "Tags applied to every resource created by this example."
  type        = map(string)
  default = {
    managed-by = "terraform"
    example    = "complete"
  }
}
