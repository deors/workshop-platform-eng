output "web_app_name" {
  value = module.webapp.web_app_name
}

output "default_hostname" {
  value = module.webapp.default_hostname
}

output "staging_slot_hostname" {
  value = module.webapp.staging_slot_hostname
}

output "managed_identity_client_id" {
  value = module.webapp.managed_identity_client_id
}

output "private_endpoint_ip" {
  value = module.webapp.private_endpoint_ip
}
