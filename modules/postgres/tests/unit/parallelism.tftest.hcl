# Layer 1 unit tests — parallelism parameter behaviour.
# pg_cpu_num = 1: all parallel params absent.
# pg_cpu_num >= 2: correct values, wpg_capped at 4.

variables {
  pg_version         = 17
  pg_total_memory_gb = 8
  pg_hd_type         = "ssd"
  pg_connection_num  = 0
  ssh_host           = "unused"
}

# When cpu_num = 1, all four parallelism params must be absent from pgtune_calculated.
run "cpu_1_no_parallel_params" {
  command = plan

  variables {
    pg_cpu_num = 1
  }

  assert {
    condition     = !contains(keys(output.pgtune_calculated), "max_worker_processes")
    error_message = "max_worker_processes must be absent when pg_cpu_num = 1"
  }
  assert {
    condition     = !contains(keys(output.pgtune_calculated), "max_parallel_workers_per_gather")
    error_message = "max_parallel_workers_per_gather must be absent when pg_cpu_num = 1"
  }
  assert {
    condition     = !contains(keys(output.pgtune_calculated), "max_parallel_workers")
    error_message = "max_parallel_workers must be absent when pg_cpu_num = 1"
  }
  assert {
    condition     = !contains(keys(output.pgtune_calculated), "max_parallel_maintenance_workers")
    error_message = "max_parallel_maintenance_workers must be absent when pg_cpu_num = 1"
  }
}

# cpu_num = 1 must also be absent from resolved_config
run "cpu_1_no_parallel_in_resolved" {
  command = plan

  variables {
    pg_cpu_num = 1
  }

  assert {
    condition     = !contains(keys(output.resolved_config), "max_worker_processes")
    error_message = "max_worker_processes must be absent from resolved_config when pg_cpu_num = 1"
  }
  assert {
    condition     = !contains(keys(output.resolved_config), "max_parallel_workers")
    error_message = "max_parallel_workers must be absent from resolved_config when pg_cpu_num = 1"
  }
}

# cpu_num = 2: wpg_capped = min(ceil(2/2), 4) = 1
run "cpu_2_parallel_values" {
  command = plan

  variables {
    pg_cpu_num = 2
  }

  assert {
    condition     = output.pgtune_calculated["max_worker_processes"] == "2"
    error_message = "max_worker_processes: expected 2 for cpu_num=2, got ${output.pgtune_calculated["max_worker_processes"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_workers_per_gather"] == "1"
    error_message = "max_parallel_workers_per_gather: expected 1 (wpg_capped) for cpu_num=2, got ${output.pgtune_calculated["max_parallel_workers_per_gather"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_workers"] == "2"
    error_message = "max_parallel_workers: expected 2 for cpu_num=2, got ${output.pgtune_calculated["max_parallel_workers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_maintenance_workers"] == "1"
    error_message = "max_parallel_maintenance_workers: expected 1 (wpg_capped) for cpu_num=2, got ${output.pgtune_calculated["max_parallel_maintenance_workers"]}"
  }
}

# cpu_num = 4: wpg_capped = min(ceil(4/2), 4) = 2
run "cpu_4_parallel_values" {
  command = plan

  variables {
    pg_cpu_num = 4
  }

  assert {
    condition     = output.pgtune_calculated["max_worker_processes"] == "4"
    error_message = "max_worker_processes: expected 4 for cpu_num=4, got ${output.pgtune_calculated["max_worker_processes"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_workers_per_gather"] == "2"
    error_message = "max_parallel_workers_per_gather: expected 2 (wpg_capped) for cpu_num=4, got ${output.pgtune_calculated["max_parallel_workers_per_gather"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_workers"] == "4"
    error_message = "max_parallel_workers: expected 4 for cpu_num=4, got ${output.pgtune_calculated["max_parallel_workers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_maintenance_workers"] == "2"
    error_message = "max_parallel_maintenance_workers: expected 2 (wpg_capped) for cpu_num=4, got ${output.pgtune_calculated["max_parallel_maintenance_workers"]}"
  }
}

# cpu_num = 16: wpg_capped = min(ceil(16/2), 4) = 4 (cap kicks in)
run "cpu_16_wpg_capped_at_4" {
  command = plan

  variables {
    pg_cpu_num = 16
  }

  assert {
    condition     = output.pgtune_calculated["max_worker_processes"] == "16"
    error_message = "max_worker_processes: expected 16 for cpu_num=16, got ${output.pgtune_calculated["max_worker_processes"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_workers_per_gather"] == "4"
    error_message = "max_parallel_workers_per_gather: expected 4 (capped) for cpu_num=16, got ${output.pgtune_calculated["max_parallel_workers_per_gather"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_workers"] == "16"
    error_message = "max_parallel_workers: expected 16 for cpu_num=16, got ${output.pgtune_calculated["max_parallel_workers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_maintenance_workers"] == "4"
    error_message = "max_parallel_maintenance_workers: expected 4 (capped) for cpu_num=16, got ${output.pgtune_calculated["max_parallel_maintenance_workers"]}"
  }
}

# cpu_num = 8: wpg_capped = min(ceil(8/2), 4) = 4 (cap kicks in at 8)
run "cpu_8_wpg_capped_at_4" {
  command = plan

  variables {
    pg_cpu_num = 8
  }

  assert {
    condition     = output.pgtune_calculated["max_parallel_workers_per_gather"] == "4"
    error_message = "max_parallel_workers_per_gather: expected 4 (capped) for cpu_num=8, got ${output.pgtune_calculated["max_parallel_workers_per_gather"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_parallel_maintenance_workers"] == "4"
    error_message = "max_parallel_maintenance_workers: expected 4 (capped) for cpu_num=8, got ${output.pgtune_calculated["max_parallel_maintenance_workers"]}"
  }
}
