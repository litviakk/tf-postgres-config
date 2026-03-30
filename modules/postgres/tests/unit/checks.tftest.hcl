# Layer 1 unit tests — check block warnings.
# Uses expect_failures to assert that advisory check blocks fire on bad inputs
# and do NOT fire on valid inputs.

variables {
  pg_version = 17
  pg_cpu_num = 2
  ssh_host   = "unused"
}

# ---------------------------------------------------------------------------
# warn_memory_range
# ---------------------------------------------------------------------------

run "warn_memory_range_fires_below_minimum" {
  command = plan

  variables {
    pg_total_memory_gb = 0.1
  }

  expect_failures = [check.warn_memory_range]
}

run "warn_memory_range_fires_above_maximum" {
  command = plan

  variables {
    pg_total_memory_gb = 200
  }

  expect_failures = [check.warn_memory_range]
}

run "warn_memory_range_silent_at_lower_bound" {
  command = plan

  variables {
    pg_total_memory_gb = 0.25
  }

  # No expect_failures — check must not fire at the lower boundary.
}

run "warn_memory_range_silent_at_upper_bound" {
  command = plan

  variables {
    pg_total_memory_gb = 100
  }

  # No expect_failures — check must not fire at the upper boundary.
}

run "warn_memory_range_silent_for_normal_value" {
  command = plan

  variables {
    pg_total_memory_gb = 8
  }

  # No expect_failures.
}

# ---------------------------------------------------------------------------
# warn_low_work_mem
# ---------------------------------------------------------------------------

# Explicit connection count that drives raw work_mem below 4 MB:
# 1 GB RAM, 2 CPUs, 1000 connections →
#   shared_buffers = 256 MB
#   work_mem_raw   = floor((1024 - 256) / (1000 * 3) / 1) = floor(0.256) = 0 MB < 4
run "warn_low_work_mem_fires_with_high_connection_count" {
  command = plan

  variables {
    pg_total_memory_gb = 1
    pg_connection_num  = 1000
  }

  expect_failures = [check.warn_low_work_mem]
}

# Auto connections (pg_connection_num = 0): formula guarantees work_mem >= 4 MB,
# so the check must not fire.
run "warn_low_work_mem_silent_for_auto_connections" {
  command = plan

  variables {
    pg_total_memory_gb = 1
    pg_connection_num  = 0
  }

  # No expect_failures.
}

# Explicit connection count that still leaves work_mem >= 4 MB.
# 8 GB RAM, 4 CPUs, 50 connections →
#   shared_buffers = 2048 MB, _wm_parallel_factor = 2
#   work_mem_raw   = floor((8192 - 2048) / (50 * 3) / 2) = floor(6144/300) = 20 MB ≥ 4
run "warn_low_work_mem_silent_for_reasonable_connection_count" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_cpu_num         = 4
    pg_connection_num  = 50
  }

  # No expect_failures.
}

# ---------------------------------------------------------------------------
# warn_unrecognized_override_keys
# ---------------------------------------------------------------------------

run "warn_unrecognized_override_keys_fires_for_unknown_key" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_overrides       = { totally_made_up_param = "yes" }
  }

  expect_failures = [check.warn_unrecognized_override_keys]
}

run "warn_unrecognized_override_keys_silent_for_managed_key" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_overrides       = { work_mem = "32MB" }
  }

  # No expect_failures — work_mem is a managed param.
}

run "warn_unrecognized_override_keys_silent_for_empty_overrides" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_overrides       = {}
  }

  # No expect_failures.
}

# Mixed: one recognised key and one unrecognised key → check fires.
run "warn_unrecognized_override_keys_fires_for_mixed_keys" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_overrides = {
      work_mem          = "32MB"
      log_rotation_size = "100MB"
    }
  }

  expect_failures = [check.warn_unrecognized_override_keys]
}
