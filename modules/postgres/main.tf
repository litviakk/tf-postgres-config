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

# ---------------------------------------------------------------------------
# Non-fatal advisory warnings (check blocks, TF/OpenTofu >= 1.6)
# ---------------------------------------------------------------------------

check "warn_memory_range" {
  assert {
    condition     = var.pg_total_memory_gb >= 0.25 && var.pg_total_memory_gb <= 100
    error_message = "pg_total_memory_gb ${var.pg_total_memory_gb} is outside the recommended 0.25–100 GB range."
  }
}

check "warn_low_work_mem" {
  assert {
    condition     = !(var.pg_connection_num > 0 && local._work_mem_raw < 4)
    error_message = "With pg_connection_num = ${var.pg_connection_num}, work_mem would be ${local._work_mem_raw}MB (< 4MB). Consider reducing pg_connection_num."
  }
}

check "warn_unrecognized_override_keys" {
  assert {
    condition = length([
      for k in keys(var.pg_overrides) : k
      if !contains(local.managed_params, k)
    ]) == 0
    error_message = "pg_overrides contains unrecognised keys: ${join(", ", [for k in keys(var.pg_overrides) : k if !contains(local.managed_params, k)])}."
  }
}

# ---------------------------------------------------------------------------
# pg_preflight — environment validation
# Runs when SSH target, user/group, pg_version, or conf_d_dir changes.
# Writes /tmp/pg_discovered.json on the remote; local-exec scps it back so
# DATA_DIR and CONF_D_DIR are available to the delivery script at render time.
# ---------------------------------------------------------------------------

locals {
  _preflight_script = templatefile("${path.module}/templates/preflight.sh.tftpl", {
    pg_version     = var.pg_version
    conf_d_dir     = var.conf_d_dir
    pg_user        = var.pg_user
    pg_group       = var.pg_group
    managed_params = local.managed_params
  })

  # scp command — handles both agent and private-key auth.
  # The discovered JSON lands in .terraform/ which is already gitignored.
  _scp_cmd = var.ssh_use_agent ? (
    "scp -o StrictHostKeyChecking=no -o BatchMode=yes -P '${var.ssh_port}' '${var.ssh_user}@${var.ssh_host}:/tmp/pg_discovered.json' '${path.root}/.terraform/pg_discovered.json'"
    ) : (
    "KEY=$(mktemp) && printf '%s' '${nonsensitive(var.ssh_private_key)}' > \"$KEY\" && chmod 600 \"$KEY\" && scp -o StrictHostKeyChecking=no -o BatchMode=yes -i \"$KEY\" -P '${var.ssh_port}' '${var.ssh_user}@${var.ssh_host}:/tmp/pg_discovered.json' '${path.root}/.terraform/pg_discovered.json' ; RC=$? ; rm -f \"$KEY\" ; exit $RC"
  )
}

resource "null_resource" "pg_preflight" {
  triggers = {
    ssh_host   = var.ssh_host
    ssh_port   = var.ssh_port
    ssh_user   = var.ssh_user
    pg_version = var.pg_version
    conf_d_dir = var.conf_d_dir
    pg_user    = var.pg_user
    pg_group   = var.pg_group
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_use_agent ? null : var.ssh_private_key
    agent       = var.ssh_use_agent
  }

  provisioner "remote-exec" {
    inline = [
      "printf '%s' '${base64encode(local._preflight_script)}' | base64 -d > /tmp/pg_preflight.sh",
      "chmod +x /tmp/pg_preflight.sh",
      "/tmp/pg_preflight.sh",
    ]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = local._scp_cmd
  }
}

# Reads the JSON written by preflight and scp'd back by local-exec.
# depends_on defers this data source to apply time whenever preflight re-runs.
data "local_file" "pg_discovered" {
  filename   = "${path.root}/.terraform/pg_discovered.json"
  depends_on = [null_resource.pg_preflight]
}

# ---------------------------------------------------------------------------
# pg_config — config delivery and apply
# Runs when any managed parameter or override changes, or SSH target changes.
# ---------------------------------------------------------------------------

locals {
  _tune_conf = templatefile("${path.module}/templates/postgresql_tune.conf.tftpl", {
    pg_version         = var.pg_version
    pg_total_memory_gb = var.pg_total_memory_gb
    pg_cpu_num         = var.pg_cpu_num
    pg_hd_type         = var.pg_hd_type
    params             = local.pgtune
    parallel_enabled   = local._parallel_enabled
  })

  _overrides_conf = templatefile("${path.module}/templates/postgresql_overrides.conf.tftpl", {
    overrides = var.pg_overrides
  })

  _pg_discovered = jsondecode(data.local_file.pg_discovered.content)

  _delivery_script = templatefile("${path.module}/templates/config_delivery.sh.tftpl", {
    pg_user            = var.pg_user
    pg_group           = var.pg_group
    pg_force_restart   = var.pg_force_restart
    pg_skip_restart    = var.pg_skip_restart
    data_dir           = local._pg_discovered.data_dir
    conf_d_dir         = local._pg_discovered.conf_d_dir
    tune_conf_b64      = base64encode(local._tune_conf)
    overrides_conf_b64 = base64encode(local._overrides_conf)
  })
}

resource "null_resource" "pg_config" {
  triggers = {
    # Captures any change to pgtune output or pg_overrides.
    config_hash             = sha256(jsonencode(local.resolved))
    # Exposes restart-required param diffs in terraform plan output.
    restart_params_snapshot = jsonencode(local.restart_params_snapshot)
    ssh_host                = var.ssh_host
  }

  depends_on = [null_resource.pg_preflight]

  lifecycle {
    precondition {
      condition     = !(var.pg_force_restart && var.pg_skip_restart)
      error_message = "pg_force_restart and pg_skip_restart cannot both be true."
    }
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_use_agent ? null : var.ssh_private_key
    agent       = var.ssh_use_agent
  }

  provisioner "remote-exec" {
    inline = [
      "printf '%s' '${base64encode(local._delivery_script)}' | base64 -d > /tmp/pg_config_delivery.sh",
      "chmod +x /tmp/pg_config_delivery.sh",
      "/tmp/pg_config_delivery.sh",
    ]
  }
}
