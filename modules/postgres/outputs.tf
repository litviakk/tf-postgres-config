output "pgtune_calculated" {
  description = "Raw pgtune values before override merge (contents of 01-pgtune.conf)."
  value       = local.pgtune
}

output "resolved_config" {
  description = "Effective parameter map after pgtune + pg_overrides merge."
  value       = local.resolved
}

output "effective_overrides" {
  description = "Per-key status of pg_overrides: pgtune, override, and active values."
  value = {
    for k, v in var.pg_overrides : k => {
      pgtune   = lookup(local.pgtune, k, null)
      override = v
      active   = v
    }
  }
}

output "config_file_paths" {
  description = "Absolute paths of both conf files on the target host."
  value = {
    tune      = "${coalesce(var.conf_d_dir, "/etc/postgresql/${var.pg_version}/main/conf.d")}/01-pgtune.conf"
    overrides = "${coalesce(var.conf_d_dir, "/etc/postgresql/${var.pg_version}/main/conf.d")}/02-overrides.conf"
  }
}
