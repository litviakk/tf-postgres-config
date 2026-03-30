terraform {
  required_version = ">= 1.6"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

variable "ssh_host" {
  type = string
}

variable "ssh_port" {
  type    = number
  default = 22
}

variable "ssh_user" {
  type    = string
  default = "postgres"
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "pg_version" {
  type    = number
  default = 18
}

variable "pg_total_memory_gb" {
  type    = number
  default = 2
}

variable "pg_cpu_num" {
  type    = number
  default = 2
}

variable "pg_hd_type" {
  type    = string
  default = "ssd"
}

variable "pg_overrides" {
  type    = map(string)
  default = {}
}

variable "pg_force_restart" {
  type    = bool
  default = false
}

variable "pg_skip_restart" {
  type    = bool
  default = false
}

variable "conf_d_dir" {
  type    = string
  default = ""
}

module "postgres" {
  source = "../../../../modules/postgres"

  pg_version         = var.pg_version
  pg_total_memory_gb = var.pg_total_memory_gb
  pg_cpu_num         = var.pg_cpu_num
  pg_hd_type         = var.pg_hd_type
  pg_overrides       = var.pg_overrides
  pg_force_restart   = var.pg_force_restart
  pg_skip_restart    = var.pg_skip_restart
  conf_d_dir         = var.conf_d_dir

  ssh_host        = var.ssh_host
  ssh_port        = var.ssh_port
  ssh_user        = var.ssh_user
  ssh_private_key = var.ssh_private_key

  pg_user  = "postgres"
  pg_group = "postgres"
}

output "resolved_config" {
  value = module.postgres.resolved_config
}

output "pgtune_calculated" {
  value = module.postgres.pgtune_calculated
}

output "effective_overrides" {
  value = module.postgres.effective_overrides
}

output "config_file_paths" {
  value = module.postgres.config_file_paths
}
