variable "pg_version" {
  type        = number
  nullable    = false
  description = "PostgreSQL major version. Controls pg_ctl version arg and conf.d path."

  validation {
    condition     = contains([16, 17, 18], var.pg_version)
    error_message = "pg_version must be 16, 17, or 18."
  }
}

variable "pg_total_memory_gb" {
  type        = number
  nullable    = false
  description = "Total system RAM in GB. Primary sizing input. Fractional values OK."

  validation {
    condition     = var.pg_total_memory_gb > 0
    error_message = "pg_total_memory_gb must be greater than 0."
  }
}

variable "pg_cpu_num" {
  type        = number
  nullable    = false
  default     = 2
  description = "Number of CPUs. When 1, all parallelism params are omitted entirely."

  validation {
    condition     = var.pg_cpu_num >= 1 && var.pg_cpu_num == floor(var.pg_cpu_num)
    error_message = "pg_cpu_num must be a positive integer >= 1."
  }
}

variable "pg_connection_num" {
  type        = number
  nullable    = false
  default     = 0
  description = "Max connections override. 0 = auto (RAM-based). Explicit value bypasses RAM-based limiting."

  validation {
    condition     = var.pg_connection_num >= 0 && var.pg_connection_num == floor(var.pg_connection_num)
    error_message = "pg_connection_num must be a non-negative integer."
  }
}

variable "pg_hd_type" {
  type        = string
  nullable    = false
  default     = "ssd"
  description = "Storage type. Controls random_page_cost and effective_io_concurrency."

  validation {
    condition     = contains(["hdd", "ssd", "san"], var.pg_hd_type)
    error_message = "pg_hd_type must be hdd, ssd, or san."
  }
}

variable "pg_overrides" {
  type        = map(string)
  nullable    = false
  default     = {}
  description = "Manual parameter overrides. Written to 02-overrides.conf. Unrecognised keys emit a warning."
}

variable "ssh_host" {
  type        = string
  nullable    = false
  description = "IP or hostname of the target PostgreSQL instance."
}

variable "ssh_user" {
  type        = string
  nullable    = false
  default     = "ubuntu"
  description = "SSH user. Must have passwordless sudo for file ops and pg_ctl."
}

variable "ssh_use_agent" {
  type        = bool
  nullable    = false
  default     = false
  description = "Use local SSH agent for auth. When true, ssh_private_key is ignored."
}

variable "ssh_private_key" {
  type        = string
  nullable    = false
  default     = ""
  sensitive   = true
  description = "SSH private key contents (not a path). Required when ssh_use_agent = false."
}

variable "ssh_port" {
  type        = number
  nullable    = false
  default     = 22
  description = "SSH port on the target host."

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535 && var.ssh_port == floor(var.ssh_port)
    error_message = "ssh_port must be an integer between 1 and 65535."
  }
}

variable "conf_d_dir" {
  type        = string
  nullable    = false
  default     = ""
  description = "Absolute path to conf.d directory on target. When empty, auto-discovered from postgresql.conf include_dir."
}

variable "pg_user" {
  type        = string
  nullable    = false
  default     = "postgres"
  description = "OS user owner applied to both conf files after delivery."
}

variable "pg_group" {
  type        = string
  nullable    = false
  default     = "postgres"
  description = "OS group owner applied to both conf files after delivery."
}

variable "pg_force_restart" {
  type        = bool
  nullable    = false
  default     = false
  description = "Always restart after config delivery, regardless of changed params."
}

variable "pg_skip_restart" {
  type        = bool
  nullable    = false
  default     = false
  description = "Never restart, even when restart-required params changed."
}
