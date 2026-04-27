output "web_app_id" {
  description = "Resource ID of the Web App"
  value       = azurerm_linux_web_app.this.id
}

output "web_app_name" {
  description = "Name of the Web App"
  value       = azurerm_linux_web_app.this.name
}

output "default_hostname" {
  description = "Default *.azurewebsites.net hostname"
  value       = azurerm_linux_web_app.this.default_hostname
}

output "outbound_ip_addresses" {
  description = "Comma-separated list of possible outbound IP addresses"
  value       = azurerm_linux_web_app.this.outbound_ip_addresses
}

output "possible_outbound_ip_addresses" {
  description = "Comma-separated list of all possible outbound IP addresses (including future ones)"
  value       = azurerm_linux_web_app.this.possible_outbound_ip_addresses
}

output "service_plan_id" {
  description = "Resource ID of the App Service Plan"
  value       = azurerm_service_plan.this.id
}

output "managed_identity_id" {
  description = "Resource ID of the user-assigned managed identity"
  value       = azurerm_user_assigned_identity.this.id
}

output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity"
  value       = azurerm_user_assigned_identity.this.client_id
}

output "managed_identity_principal_id" {
  description = "Object (principal) ID of the user-assigned managed identity"
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string (sensitive)"
  value       = local.appinsights_connection_string
  sensitive   = true
}

output "application_insights_id" {
  description = "Resource ID of the Application Insights component (empty when an external one is provided)"
  value       = local.create_app_insights ? azurerm_application_insights.this[0].id : ""
}

output "private_endpoint_id" {
  description = "Resource ID of the private endpoint (empty when not created)"
  value       = local.create_private_endpoint ? azurerm_private_endpoint.this[0].id : ""
}

output "private_endpoint_ip" {
  description = "Private IP address of the private endpoint NIC"
  value = local.create_private_endpoint ? (
    azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address
  ) : ""
}

output "staging_slot_hostname" {
  description = "Hostname of the staging deployment slot (empty when not created)"
  value       = var.deployment_slot_enabled ? azurerm_linux_web_app_slot.staging[0].default_hostname : ""
}
