# Layer 1 unit tests — pg_overrides merge behaviour.
# Verifies resolved_config, pgtune_calculated, and effective_overrides outputs.

variables {
  pg_version         = 17
  pg_total_memory_gb = 8
  pg_cpu_num         = 4
  pg_hd_type         = "ssd"
  pg_connection_num  = 0
  ssh_host           = "unused"
}

# Override a reload-safe param (work_mem).
# resolved_config reflects override; pgtune_calculated retains computed value.
run "override_work_mem" {
  command = plan

  variables {
    pg_overrides = { work_mem = "32MB" }
  }

  assert {
    condition     = output.resolved_config["work_mem"] == "32MB"
    error_message = "resolved_config[work_mem]: expected override 32MB, got ${output.resolved_config["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "5MB"
    error_message = "pgtune_calculated[work_mem]: expected original 5MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.effective_overrides["work_mem"].pgtune == "5MB"
    error_message = "effective_overrides[work_mem].pgtune: expected 5MB, got ${output.effective_overrides["work_mem"].pgtune}"
  }
  assert {
    condition     = output.effective_overrides["work_mem"].override == "32MB"
    error_message = "effective_overrides[work_mem].override: expected 32MB, got ${output.effective_overrides["work_mem"].override}"
  }
  assert {
    condition     = output.effective_overrides["work_mem"].active == "32MB"
    error_message = "effective_overrides[work_mem].active: expected 32MB, got ${output.effective_overrides["work_mem"].active}"
  }
}

# Override a restart-required param (shared_buffers).
run "override_shared_buffers" {
  command = plan

  variables {
    pg_overrides = { shared_buffers = "4096MB" }
  }

  assert {
    condition     = output.resolved_config["shared_buffers"] == "4096MB"
    error_message = "resolved_config[shared_buffers]: expected override 4096MB, got ${output.resolved_config["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "2048MB"
    error_message = "pgtune_calculated[shared_buffers]: expected computed 2048MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
}

# Multiple overrides applied simultaneously.
run "multiple_overrides" {
  command = plan

  variables {
    pg_overrides = {
      work_mem     = "16MB"
      shared_buffers = "1024MB"
    }
  }

  assert {
    condition     = output.resolved_config["work_mem"] == "16MB"
    error_message = "resolved_config[work_mem]: expected 16MB, got ${output.resolved_config["work_mem"]}"
  }
  assert {
    condition     = output.resolved_config["shared_buffers"] == "1024MB"
    error_message = "resolved_config[shared_buffers]: expected 1024MB, got ${output.resolved_config["shared_buffers"]}"
  }
  assert {
    condition     = length(output.effective_overrides) == 2
    error_message = "effective_overrides: expected 2 entries, got ${length(output.effective_overrides)}"
  }
}

# No overrides: effective_overrides is empty, resolved_config equals pgtune_calculated.
run "no_overrides" {
  command = plan

  variables {
    pg_overrides = {}
  }

  assert {
    condition     = length(output.effective_overrides) == 0
    error_message = "effective_overrides: expected empty map, got ${length(output.effective_overrides)} entries"
  }
  assert {
    condition     = output.resolved_config["shared_buffers"] == output.pgtune_calculated["shared_buffers"]
    error_message = "resolved_config should equal pgtune_calculated when no overrides are set"
  }
  assert {
    condition     = output.resolved_config["work_mem"] == output.pgtune_calculated["work_mem"]
    error_message = "resolved_config should equal pgtune_calculated when no overrides are set"
  }
}

# Non-pgtune key in effective_overrides has null pgtune value.
# (The key is still emitted by effective_overrides since it comes from pg_overrides.)
# The unrecognised key also fires warn_unrecognized_override_keys — expected here.
run "override_unrecognized_key_pgtune_null" {
  command = plan

  variables {
    pg_overrides = { log_min_duration_statement = "1000" }
  }

  expect_failures = [check.warn_unrecognized_override_keys]

  # effective_overrides includes the key
  assert {
    condition     = output.effective_overrides["log_min_duration_statement"].override == "1000"
    error_message = "effective_overrides should include unrecognised override key"
  }
  # pgtune value for non-managed param is null
  assert {
    condition     = output.effective_overrides["log_min_duration_statement"].pgtune == null
    error_message = "pgtune value for unrecognised key should be null"
  }
}
