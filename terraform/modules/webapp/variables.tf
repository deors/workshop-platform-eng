variable "name" {
  description = "Base name for all resources (used as prefix)"
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
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# App Service Plan
variable "sku_name" {
  description = "App Service Plan SKU (e.g. P1v3, P2v3, P3v3)"
  type        = string
  default     = "P1v3"
}

variable "os_type" {
  description = "OS type for App Service Plan: Linux or Windows"
  type        = string
  default     = "Linux"
  validation {
    condition     = contains(["Linux", "Windows"], var.os_type)
    error_message = "os_type must be Linux or Windows."
  }
}

variable "zone_balancing_enabled" {
  description = "Enable zone redundancy for the App Service Plan"
  type        = bool
  default     = false
}

variable "worker_count" {
  description = "Initial number of workers for the App Service Plan. Set to ≥2 in prod for failover; autoscale manages dynamic count after creation."
  type        = number
  default     = 1
}

# Container image
variable "container_image" {
  description = "Full container image reference (e.g. mcr.microsoft.com/appsvc/staticsite:latest)"
  type        = string
}

variable "container_registry_url" {
  description = "Container registry server URL (leave empty for public registries)"
  type        = string
  default     = ""
}

variable "container_registry_use_managed_identity" {
  description = "Use managed identity to pull from the container registry"
  type        = bool
  default     = true
}

# App settings
variable "app_settings" {
  description = "Application settings (environment variables). Do not put secrets here; use key_vault_secrets instead."
  type        = map(string)
  default     = {}
}

variable "key_vault_id" {
  description = "ID of the Key Vault where secrets are stored"
  type        = string
  default     = ""
}

variable "key_vault_secrets" {
  description = "Map of app setting name to Key Vault secret name. Resolved as Key Vault references."
  type        = map(string)
  default     = {}
}

# Networking
variable "virtual_network_subnet_id" {
  description = "Subnet ID for VNet integration (outbound traffic)"
  type        = string
  default     = ""
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for the private endpoint (inbound traffic). Empty = public access allowed."
  type        = string
  default     = ""
}

variable "private_dns_zone_id" {
  description = "ID of the privatelink.azurewebsites.net private DNS zone for the private endpoint"
  type        = string
  default     = ""
}

variable "allowed_ip_ranges" {
  description = "List of CIDRs allowed to reach the Web App. Only used when private_endpoint_subnet_id is empty."
  type        = list(string)
  default     = []
}

# TLS / HTTPS
variable "minimum_tls_version" {
  description = "Minimum TLS version: 1.2 or 1.3"
  type        = string
  default     = "1.3"
  validation {
    condition     = contains(["1.2", "1.3"], var.minimum_tls_version)
    error_message = "minimum_tls_version must be 1.2 or 1.3."
  }
}

variable "custom_domain" {
  description = "Custom hostname to bind (optional)"
  type        = string
  default     = ""
}

variable "managed_certificate" {
  description = "Create a managed TLS certificate for the custom domain"
  type        = bool
  default     = true
}

# Observability
variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for diagnostic settings"
  type        = string
}

variable "application_insights_connection_string" {
  description = "Application Insights connection string. Leave empty to create a new Application Insights resource."
  type        = string
  default     = ""
}

# Autoscale
variable "autoscale_enabled" {
  description = "Enable autoscale rules on the App Service Plan"
  type        = bool
  default     = false
}

variable "autoscale_min_count" {
  description = "Minimum number of instances for autoscale"
  type        = number
  default     = 1
}

variable "autoscale_max_count" {
  description = "Maximum number of instances for autoscale"
  type        = number
  default     = 3
}

variable "autoscale_default_count" {
  description = "Default number of instances for autoscale"
  type        = number
  default     = 1
}

# Slot (staging slot for zero-downtime deployments)
variable "deployment_slot_enabled" {
  description = "Create a 'staging' deployment slot for zero-downtime swaps"
  type        = bool
  default     = false
}

# Health check
variable "health_check_path" {
  description = "Path for the App Service health check probe"
  type        = string
  default     = "/health"
}

variable "health_check_eviction_time_in_min" {
  description = "Time in minutes before an unhealthy instance is evicted"
  type        = number
  default     = 10
}
