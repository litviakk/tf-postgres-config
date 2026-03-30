# Minimal Terraform config used only to render preflight.sh.tftpl for bats tests.
# No providers, no resources — just templatefile() outputs.
# Usage (from this directory):
#   terraform init && terraform apply -auto-approve
#   terraform output -raw preflight_auto_conf_d > /tmp/preflight.sh

terraform {
  required_version = ">= 1.6"
}

locals {
  managed_params = [
    "max_connections",
    "shared_buffers",
    "effective_cache_size",
    "maintenance_work_mem",
    "work_mem",
    "huge_pages",
    "wal_buffers",
    "min_wal_size",
    "max_wal_size",
    "checkpoint_completion_target",
    "default_statistics_target",
    "random_page_cost",
    "effective_io_concurrency",
    "max_worker_processes",
    "max_parallel_workers_per_gather",
    "max_parallel_workers",
    "max_parallel_maintenance_workers",
  ]

  tpl = "${path.module}/../../templates/preflight.sh.tftpl"

  base = {
    pg_version     = 17
    pg_user        = "postgres"
    pg_group       = "postgres"
    managed_params = local.managed_params
  }
}

# conf_d_dir = "" → preflight auto-discovers from include_dir
output "preflight_auto_conf_d" {
  value = templatefile(local.tpl, merge(local.base, { conf_d_dir = "" }))
}

# conf_d_dir set to a path that will not match the container's include_dir
output "preflight_mismatched_conf_d" {
  value = templatefile(local.tpl, merge(local.base, { conf_d_dir = "/wrong/conf.d" }))
}
