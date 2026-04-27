output "vnet_id" {
  description = "Resource ID of the Virtual Network"
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the Virtual Network"
  value       = azurerm_virtual_network.this.name
}

output "webapp_integration_subnet_id" {
  description = "Subnet ID for App Service VNet integration (outbound)"
  value       = azurerm_subnet.webapp_integration.id
}

output "private_endpoint_subnet_id" {
  description = "Subnet ID for private endpoints (inbound)"
  value       = azurerm_subnet.private_endpoints.id
}

output "webapp_private_dns_zone_id" {
  description = "Resource ID of the privatelink.azurewebsites.net DNS zone"
  value       = azurerm_private_dns_zone.webapp.id
}

output "webapp_private_dns_zone_name" {
  description = "Name of the privatelink.azurewebsites.net DNS zone"
  value       = azurerm_private_dns_zone.webapp.name
}
