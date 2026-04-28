locals {
  environment = "dev"

  common_tags = {
    application = var.app_name
    environment = local.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Resource Group
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.app_name}-${local.environment}"
  location = var.location
  tags     = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring (Log Analytics)
# ──────────────────────────────────────────────────────────────────────────────
module "monitoring" {
  source = "../../modules/monitoring"

  name                         = var.app_name
  resource_group_name          = azurerm_resource_group.this.name
  location                     = var.location
  environment                  = local.environment
  tags                         = local.common_tags
  log_analytics_retention_days = 30
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  name                           = var.app_name
  resource_group_name            = azurerm_resource_group.this.name
  location                       = var.location
  environment                    = local.environment
  tags                           = local.common_tags
  vnet_address_space             = ["10.10.0.0/16"]
  webapp_integration_subnet_cidr = "10.10.1.0/24"
  private_endpoint_subnet_cidr   = "10.10.2.0/24"
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App
# ──────────────────────────────────────────────────────────────────────────────
module "webapp" {
  source = "../../modules/webapp"

  name                = var.app_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  environment         = local.environment
  tags                = local.common_tags

  # Dev: smallest Premium v3 SKU for VNet integration support
  sku_name = "P0v3"

  container_image                         = var.container_image
  container_registry_url                  = var.container_registry_url
  container_registry_use_managed_identity = var.container_registry_url != ""

  app_settings = var.app_settings

  # Networking – VNet integration + private endpoint AND public endpoint open.
  # Dev allows public ingress so GitHub-hosted runners (no fixed IP, not in
  # the VNet) can reach the deployed app for HTTP smoke tests in CI/CD.
  # Staging and prod keep the public endpoint closed and rely on
  # control-plane validation instead — see docs/SETUP.md.
  virtual_network_subnet_id     = module.networking.webapp_integration_subnet_id
  private_endpoint_subnet_id    = module.networking.private_endpoint_subnet_id
  private_dns_zone_id           = module.networking.webapp_private_dns_zone_id
  public_network_access_enabled = true

  # Observability
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  # Dev: no zone redundancy, no autoscale, no staging slot
  zone_balancing_enabled  = false
  autoscale_enabled       = false
  deployment_slot_enabled = false

  health_check_path = "/health"
}
