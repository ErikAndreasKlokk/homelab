output "talosconfig" {
  description = "talosctl client config: tofu output -raw talosconfig > ~/.talos/config"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "machine_configs" {
  description = "Rendered machine configs, for `talosctl apply-config --dry-run` diffs."
  value       = { for k, v in data.talos_machine_configuration.this : k => v.machine_configuration }
  sensitive   = true
}

output "installer_images" {
  value = {
    for k, id in local.schematic_ids : k => "factory.talos.dev/installer/${id}:${var.talos_version}"
  }
}
