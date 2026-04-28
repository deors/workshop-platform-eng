locals {
  # Normalised prefix used across all resource names
  prefix = lower("${var.name}-${var.environment}")

  # Merge caller tags with mandatory platform tags
  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })

  # Key Vault references for secrets: @Microsoft.KeyVault(SecretUri=…)
  kv_app_settings = {
    for setting_name, secret_name in var.key_vault_secrets :
    setting_name => "@Microsoft.KeyVault(VaultName=${local.kv_name};SecretName=${secret_name})"
    if var.key_vault_id != ""
  }

  kv_name = var.key_vault_id != "" ? reverse(split("/", var.key_vault_id))[0] : ""

  # Create a local Application Insights resource only when no external one is provided
  create_app_insights = var.application_insights_connection_string == ""

  appinsights_connection_string = local.create_app_insights ? (
    azurerm_application_insights.this[0].connection_string
  ) : var.application_insights_connection_string

  # Whether to provision a Private Endpoint. Driven by an explicit flag so the
  # value is known at plan time (subnet IDs are computed and would force the
  # count to "known after apply").
  create_private_endpoint = var.private_endpoint_enabled

  # Only bind custom hostname when one is given
  create_custom_domain = var.custom_domain != ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Managed Identity
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring: Log Analytics + Application Insights
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_application_insights" "this" {
  count = local.create_app_insights ? 1 : 0

  name                = "appi-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = var.log_analytics_workspace_id
  application_type    = "web"
  tags                = local.base_tags

  # Disable legacy ingestion key – use connection string only
  disable_ip_masking = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Key Vault access policy: allow the managed identity to read secrets
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_key_vault_access_policy" "webapp" {
  count = var.key_vault_id != "" ? 1 : 0

  key_vault_id = var.key_vault_id
  tenant_id    = azurerm_user_assigned_identity.this.tenant_id
  object_id    = azurerm_user_assigned_identity.this.principal_id

  secret_permissions = ["Get", "List"]
}

# ──────────────────────────────────────────────────────────────────────────────
# ACR pull role for the managed identity
# (only when using managed identity to pull from a private registry)
# ──────────────────────────────────────────────────────────────────────────────
data "azurerm_container_registry" "this" {
  count = var.container_registry_url != "" && var.container_registry_use_managed_identity ? 1 : 0

  # Derive the registry name from the URL: <name>.azurecr.io → <name>
  name                = split(".", var.container_registry_url)[0]
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "acr_pull" {
  count = var.container_registry_url != "" && var.container_registry_use_managed_identity ? 1 : 0

  scope                = data.azurerm_container_registry.this[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ──────────────────────────────────────────────────────────────────────────────
# App Service Plan
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_service_plan" "this" {
  name                   = "asp-${local.prefix}"
  resource_group_name    = var.resource_group_name
  location               = var.location
  os_type                = var.os_type
  sku_name               = var.sku_name
  worker_count           = var.worker_count
  zone_balancing_enabled = var.zone_balancing_enabled
  tags                   = local.base_tags

  # Autoscale manages dynamic count after creation; ignore drift on worker_count
  # so terraform plans stay clean once the autoscale rules take over.
  lifecycle {
    ignore_changes = [worker_count]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_linux_web_app" "this" {
  name                = "app-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id
  tags                = local.base_tags

  # ── Security ──────────────────────────────────────────────────────────────
  https_only                    = true
  public_network_access_enabled = var.public_network_access_enabled
  client_affinity_enabled       = false # stateless; sticky sessions via load balancer if needed

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  # ── Site configuration ────────────────────────────────────────────────────
  site_config {
    always_on                         = true
    http2_enabled                     = true
    minimum_tls_version               = var.minimum_tls_version
    ftps_state                        = "Disabled"
    use_32_bit_worker                 = false
    worker_count                      = 1
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min

    # IP restrictions apply only to the public endpoint. When the public
    # endpoint is closed, the rules are moot (no traffic arrives via that
    # path); when it's open, allowed_ip_ranges tightens which sources reach it.
    dynamic "ip_restriction" {
      for_each = var.public_network_access_enabled ? var.allowed_ip_ranges : []
      content {
        ip_address = ip_restriction.value
        action     = "Allow"
        priority   = 100
        name       = "allow-${ip_restriction.key}"
      }
    }

    # Deny all other inbound traffic when IP restrictions are configured
    dynamic "ip_restriction" {
      for_each = var.public_network_access_enabled && length(var.allowed_ip_ranges) > 0 ? [1] : []
      content {
        ip_address = "Any"
        action     = "Deny"
        priority   = 2147483647
        name       = "deny-all"
      }
    }

    # Container image
    application_stack {
      docker_image_name        = var.container_image
      docker_registry_url      = var.container_registry_url != "" ? "https://${var.container_registry_url}" : "https://index.docker.io"
      docker_registry_username = null
      docker_registry_password = null
    }

    # Managed identity for ACR pull
    container_registry_use_managed_identity       = var.container_registry_use_managed_identity && var.container_registry_url != ""
    container_registry_managed_identity_client_id = var.container_registry_use_managed_identity && var.container_registry_url != "" ? azurerm_user_assigned_identity.this.client_id : null
  }

  # ── Application settings ──────────────────────────────────────────────────
  app_settings = merge(
    {
      # Observability
      APPLICATIONINSIGHTS_CONNECTION_STRING      = local.appinsights_connection_string
      ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
      APPLICATIONINSIGHTS_ROLE_NAME              = "${local.prefix}"

      # Avoid credential-based deployments
      WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
      DOCKER_ENABLE_CI                    = "false"
    },
    var.app_settings,
    local.kv_app_settings,
  )

  # ── Logging ───────────────────────────────────────────────────────────────
  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  # ── VNet integration ──────────────────────────────────────────────────────
  virtual_network_subnet_id = var.virtual_network_subnet_id != "" ? var.virtual_network_subnet_id : null

  lifecycle {
    ignore_changes = [
      # Allow external CI/CD to update the container image without Terraform drift
      site_config[0].application_stack[0].docker_image_name,
    ]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Deployment slot (staging) for zero-downtime swap
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_linux_web_app_slot" "staging" {
  count          = var.deployment_slot_enabled ? 1 : 0
  name           = "staging"
  app_service_id = azurerm_linux_web_app.this.id
  tags           = local.base_tags

  https_only                    = true
  public_network_access_enabled = false
  client_affinity_enabled       = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  site_config {
    always_on           = false # staging slot does not need to stay warm
    http2_enabled       = true
    minimum_tls_version = var.minimum_tls_version
    ftps_state          = "Disabled"

    application_stack {
      docker_image_name        = var.container_image
      docker_registry_url      = var.container_registry_url != "" ? "https://${var.container_registry_url}" : "https://index.docker.io"
      docker_registry_username = null
      docker_registry_password = null
    }

    container_registry_use_managed_identity       = var.container_registry_use_managed_identity && var.container_registry_url != ""
    container_registry_managed_identity_client_id = var.container_registry_use_managed_identity && var.container_registry_url != "" ? azurerm_user_assigned_identity.this.client_id : null
  }

  app_settings = merge(
    {
      APPLICATIONINSIGHTS_CONNECTION_STRING      = local.appinsights_connection_string
      ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
      APPLICATIONINSIGHTS_ROLE_NAME              = "${local.prefix}-staging"
      WEBSITES_ENABLE_APP_SERVICE_STORAGE        = "false"

    },
    var.app_settings,
    local.kv_app_settings,
  )

  lifecycle {
    ignore_changes = [
      site_config[0].application_stack[0].docker_image_name,
    ]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Custom domain + managed TLS certificate
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_app_service_custom_hostname_binding" "this" {
  count               = local.create_custom_domain ? 1 : 0
  hostname            = var.custom_domain
  app_service_name    = azurerm_linux_web_app.this.name
  resource_group_name = var.resource_group_name
}

resource "azurerm_app_service_managed_certificate" "this" {
  count                      = local.create_custom_domain && var.managed_certificate ? 1 : 0
  custom_hostname_binding_id = azurerm_app_service_custom_hostname_binding.this[0].id
  tags                       = local.base_tags
}

resource "azurerm_app_service_certificate_binding" "this" {
  count               = local.create_custom_domain && var.managed_certificate ? 1 : 0
  hostname_binding_id = azurerm_app_service_custom_hostname_binding.this[0].id
  certificate_id      = azurerm_app_service_managed_certificate.this[0].id
  ssl_state           = "SniEnabled"
}

# ──────────────────────────────────────────────────────────────────────────────
# Private endpoint (inbound)
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_private_endpoint" "this" {
  count               = local.create_private_endpoint ? 1 : 0
  name                = "pe-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.base_tags

  private_service_connection {
    name                           = "psc-${local.prefix}"
    private_connection_resource_id = azurerm_linux_web_app.this.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = var.private_dns_zone_id != "" ? [1] : []
    content {
      name                 = "dns-${local.prefix}"
      private_dns_zone_ids = [var.private_dns_zone_id]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Autoscale settings
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_monitor_autoscale_setting" "this" {
  count               = var.autoscale_enabled ? 1 : 0
  name                = "autoscale-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_service_plan.this.id
  tags                = local.base_tags

  profile {
    name = "default"

    capacity {
      default = var.autoscale_default_count
      minimum = var.autoscale_min_count
      maximum = var.autoscale_max_count
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "MemoryPercentage"
        metric_resource_id = azurerm_service_plan.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 80
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Diagnostic settings → Log Analytics
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "webapp" {
  name                       = "diag-${local.prefix}"
  target_resource_id         = azurerm_linux_web_app.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }
  enabled_log {
    category = "AppServiceConsoleLogs"
  }
  enabled_log {
    category = "AppServiceAppLogs"
  }
  enabled_log {
    category = "AppServiceAuditLogs"
  }
  enabled_log {
    category = "AppServiceIPSecAuditLogs"
  }
  enabled_log {
    category = "AppServicePlatformLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "plan" {
  name                       = "diag-plan-${local.prefix}"
  target_resource_id         = azurerm_service_plan.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
}
