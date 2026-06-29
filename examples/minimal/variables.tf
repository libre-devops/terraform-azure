variable "location" {
  description = "Azure region for the resources. Example: uksouth."
  type        = string
  default     = "uksouth"
}

variable "name" {
  description = "Short name used to build the resource group name."
  type        = string
  default     = "ldo-tfaz-min"
}

variable "tags" {
  description = "Tags applied to every resource created by this example."
  type        = map(string)
  default = {
    managed-by = "terraform"
    example    = "minimal"
  }
}
