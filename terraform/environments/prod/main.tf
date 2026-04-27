locals {
  environment = "prod"

  common_tags = {
    application = var.app_name
    environment = local.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.app_name}-${local.environment}"
  location = var.location
  tags     = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                         = var.app_name
  resource_group_name          = azurerm_resource_group.this.name
  location                     = var.location
  environment                  = local.environment
  tags                         = local.common_tags
  log_analytics_retention_days = 90
}

module "networking" {
  source = "../../modules/networking"

  name                           = var.app_name
  resource_group_name            = azurerm_resource_group.this.name
  location                       = var.location
  environment                    = local.environment
  tags                           = local.common_tags
  vnet_address_space             = ["10.30.0.0/16"]
  webapp_integration_subnet_cidr = "10.30.1.0/24"
  private_endpoint_subnet_cidr   = "10.30.2.0/24"
}

module "webapp" {
  source = "../../modules/webapp"

  name                = var.app_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  environment         = local.environment
  tags                = local.common_tags

  # Prod: zone-redundant P2v3 (minimum 3 instances for AZ redundancy)
  sku_name               = "P2v3"
  zone_balancing_enabled = true
  worker_count           = 3 # min 3 for zone redundancy and failover baseline

  container_image                         = var.container_image
  container_registry_url                  = var.container_registry_url
  container_registry_use_managed_identity = var.container_registry_url != ""

  app_settings  = var.app_settings
  custom_domain = var.custom_domain

  virtual_network_subnet_id  = module.networking.webapp_integration_subnet_id
  private_endpoint_subnet_id = module.networking.private_endpoint_subnet_id
  private_dns_zone_id        = module.networking.webapp_private_dns_zone_id

  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  autoscale_enabled       = true
  autoscale_min_count     = 3 # min 3 for zone redundancy
  autoscale_default_count = 3
  autoscale_max_count     = 10

  # Staging slot mandatory in production for zero-downtime blue/green swaps
  deployment_slot_enabled = true

  minimum_tls_version = "1.3"
  health_check_path   = "/health"
}
