variable "name" {
  description = "Base name for all resources"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging, prod"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "vnet_address_space" {
  description = "Address space for the VNet (list of CIDRs)"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "webapp_integration_subnet_cidr" {
  description = "CIDR for the App Service VNet integration subnet (outbound)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_endpoint_subnet_cidr" {
  description = "CIDR for the private endpoint subnet (inbound)"
  type        = string
  default     = "10.0.2.0/24"
}
