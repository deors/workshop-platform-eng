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

  # Allow outbound to Azure services
  security_rule {
    name                       = "allow-azure-outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureCloud"
  }

  # Deny all other outbound (default Azure rule override not needed; explicit deny below)
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

  security_rule {
    name                       = "allow-vnet-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
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
