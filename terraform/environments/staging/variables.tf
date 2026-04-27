variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "app_name" {
  description = "Application name (short, lowercase, no spaces)"
  type        = string
}

variable "container_image" {
  description = "Container image reference (repository/image:tag)"
  type        = string
}

variable "container_registry_url" {
  description = "Container registry URL. Leave empty for public Docker Hub images."
  type        = string
  default     = ""
}

variable "app_settings" {
  description = "Additional application settings / environment variables"
  type        = map(string)
  default     = {}
}
