locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.base_tags
}
