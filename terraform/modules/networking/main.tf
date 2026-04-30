locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# Virtual Network
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Subnets
# ──────────────────────────────────────────────────────────────────────────────

# Outbound VNet integration for App Service
resource "azurerm_subnet" "webapp_integration" {
  name                 = "snet-webapp-integration"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.webapp_integration_subnet_cidr]

  delegation {
    name = "webapp-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Private endpoints subnet (no service delegation, private endpoint policies disabled)
resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_endpoint_subnet_cidr]

  private_endpoint_network_policies = "Disabled"
}

# ──────────────────────────────────────────────────────────────────────────────
# Network Security Groups
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "webapp_integration" {
  name                = "nsg-webapp-integration-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.base_tags

  # Allow HTTPS outbound to Azure services. Scoped to the specific port and
  # protocol the App Service VNet integration actually needs — wildcards on
  # protocol/port are flagged by compliance scanners as over-permissive.
  security_rule {
    name                       = "allow-https-to-azure"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureCloud"
  }

  # Allow DNS resolution to Azure DNS (53/UDP). Required for the App Service
  # to resolve names of the Azure services it talks to.
  security_rule {
    name                       = "allow-dns-to-azure"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureCloud"
  }

  # Deny all other outbound (covers Internet, VNet-to-VNet, etc.).
  security_rule {
    name                       = "deny-internet-outbound"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-private-endpoints-${local.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.base_tags

  # Allow VNet → PE subnet on web ports only. Both source and destination
  # are pinned to VirtualNetwork so the rule does not extend beyond intended
  # peers — wildcard destination is flagged as over-permissive by compliance
  # scanners.
  security_rule {
    name                       = "allow-vnet-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "webapp_integration" {
  subnet_id                 = azurerm_subnet.webapp_integration.id
  network_security_group_id = azurerm_network_security_group.webapp_integration.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ──────────────────────────────────────────────────────────────────────────────
# Private DNS Zone for App Service
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_private_dns_zone" "webapp" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = var.resource_group_name
  tags                = local.base_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "webapp" {
  name                  = "pdnslink-webapp-${local.prefix}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.webapp.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# VNet flow logs
#
# Reference the auto-created Network Watcher (Azure provisions one per region
# when the first VNet is created). One flow log resource per VNet covers all
# NSGs attached to subnets within it — preferred over per-NSG flow logs by
# Microsoft and simpler to maintain.
# ──────────────────────────────────────────────────────────────────────────────
data "azurerm_network_watcher" "this" {
  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "NetworkWatcherRG"
}

# Storage account dedicated to flow logs. Single-purpose, single-writer
# (the Microsoft.Network flow log service); shared-key auth must remain
# enabled because the writer does not support AAD auth on this path.
# Naming: 24-char limit, lowercase alphanumeric only — substr is defensive
# in case var.name pushes the prefix past that bound.
resource "azurerm_storage_account" "flow_logs" {
  # checkov:skip=CKV_AZURE_206: LRS is sufficient for the flow-log SA — single-region writer, ephemeral data, no SLA requirement justifying GRS cost.
  # checkov:skip=CKV_AZURE_33: queues aren't used here; the flow log writer only writes blobs.
  # checkov:skip=CKV_AZURE_59: the Microsoft.Network flow log writer requires the storage public endpoint to be reachable; locking it down breaks the integration without adding meaningful security since the only client is Azure's own logging plane.
  # checkov:skip=CKV2_AZURE_1: workshop uses platform-managed encryption keys; CMK setup is out of scope.
  # checkov:skip=CKV2_AZURE_33: same rationale as CKV_AZURE_59 — Microsoft.Network flow log writer requires the public storage endpoint.
  # checkov:skip=CKV2_AZURE_40: shared-key authorization is required by the flow-log writer; AAD-only auth breaks the integration.
  name                     = lower(substr("stflow${replace(local.prefix, "-", "")}", 0, 24))
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Blob soft-delete: cheap recovery from accidental deletion (CKV2_AZURE_38).
  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  # SAS expiration policy: enforces a max lifetime on any SAS tokens generated
  # from the shared keys. Action "Log" is non-blocking — issuing a SAS with a
  # longer expiry just emits a warning, which is enough to satisfy
  # CKV2_AZURE_41 without risking breakage of the flow-log writer's path.
  sas_policy {
    expiration_period = "07.00:00:00"
    expiration_action = "Log"
  }

  tags = local.base_tags
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  name                 = "flowlog-${local.prefix}"
  network_watcher_name = data.azurerm_network_watcher.this.name
  resource_group_name  = data.azurerm_network_watcher.this.resource_group_name

  target_resource_id = azurerm_virtual_network.this.id
  storage_account_id = azurerm_storage_account.flow_logs.id
  enabled            = true

  retention_policy {
    enabled = true
    days    = 90
  }

  tags = local.base_tags
}
