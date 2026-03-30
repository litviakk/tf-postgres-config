# Layer 1 unit tests — pgtune sizing formulas.
# Covers all rows in the SPEC.md correctness table.
# Run from modules/postgres/: terraform test -test-directory=../../tests/postgres/unit

variables {
  pg_version        = 17
  pg_hd_type        = "ssd"
  pg_connection_num = 0
  ssh_host          = "unused"
}

# wal_buffers threshold: < 4 GB → 16 MB
run "mem_0_5gb_2cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 0.5
    pg_cpu_num         = 2
  }

  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "128MB"
    error_message = "shared_buffers: expected 128MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_connections"] == "32"
    error_message = "max_connections: expected 32, got ${output.pgtune_calculated["max_connections"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "4MB"
    error_message = "work_mem: expected 4MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["wal_buffers"] == "16MB"
    error_message = "wal_buffers: expected 16MB for < 4GB RAM, got ${output.pgtune_calculated["wal_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["effective_cache_size"] == "384MB"
    error_message = "effective_cache_size: expected 384MB, got ${output.pgtune_calculated["effective_cache_size"]}"
  }
}

run "mem_1gb_2cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 1
    pg_cpu_num         = 2
  }

  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "256MB"
    error_message = "shared_buffers: expected 256MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_connections"] == "64"
    error_message = "max_connections: expected 64, got ${output.pgtune_calculated["max_connections"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "4MB"
    error_message = "work_mem: expected 4MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["wal_buffers"] == "16MB"
    error_message = "wal_buffers: expected 16MB for < 4GB RAM, got ${output.pgtune_calculated["wal_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["effective_cache_size"] == "768MB"
    error_message = "effective_cache_size: expected 768MB, got ${output.pgtune_calculated["effective_cache_size"]}"
  }
  assert {
    condition     = output.pgtune_calculated["maintenance_work_mem"] == "64MB"
    error_message = "maintenance_work_mem: expected 64MB, got ${output.pgtune_calculated["maintenance_work_mem"]}"
  }
}

run "mem_2gb_2cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 2
    pg_cpu_num         = 2
  }

  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "512MB"
    error_message = "shared_buffers: expected 512MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_connections"] == "128"
    error_message = "max_connections: expected 128, got ${output.pgtune_calculated["max_connections"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "4MB"
    error_message = "work_mem: expected 4MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["wal_buffers"] == "16MB"
    error_message = "wal_buffers: expected 16MB for < 4GB RAM, got ${output.pgtune_calculated["wal_buffers"]}"
  }
}

# wal_buffers threshold: 4–16 GB → 32 MB
run "mem_4gb_2cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 4
    pg_cpu_num         = 2
  }

  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "1024MB"
    error_message = "shared_buffers: expected 1024MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_connections"] == "200"
    error_message = "max_connections: expected 200 (capped), got ${output.pgtune_calculated["max_connections"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "5MB"
    error_message = "work_mem: expected 5MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["wal_buffers"] == "32MB"
    error_message = "wal_buffers: expected 32MB for 4–16GB RAM, got ${output.pgtune_calculated["wal_buffers"]}"
  }
}

run "mem_8gb_4cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_cpu_num         = 4
  }

  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "2048MB"
    error_message = "shared_buffers: expected 2048MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_connections"] == "200"
    error_message = "max_connections: expected 200 (capped), got ${output.pgtune_calculated["max_connections"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "5MB"
    error_message = "work_mem: expected 5MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["wal_buffers"] == "32MB"
    error_message = "wal_buffers: expected 32MB for 4–16GB RAM, got ${output.pgtune_calculated["wal_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["effective_cache_size"] == "6144MB"
    error_message = "effective_cache_size: expected 6144MB, got ${output.pgtune_calculated["effective_cache_size"]}"
  }
  assert {
    condition     = output.pgtune_calculated["maintenance_work_mem"] == "512MB"
    error_message = "maintenance_work_mem: expected 512MB, got ${output.pgtune_calculated["maintenance_work_mem"]}"
  }
}

# wal_buffers threshold: > 16 GB → 64 MB
run "mem_32gb_16cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 32
    pg_cpu_num         = 16
  }

  assert {
    condition     = output.pgtune_calculated["shared_buffers"] == "8192MB"
    error_message = "shared_buffers: expected 8192MB, got ${output.pgtune_calculated["shared_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_connections"] == "200"
    error_message = "max_connections: expected 200 (capped), got ${output.pgtune_calculated["max_connections"]}"
  }
  assert {
    condition     = output.pgtune_calculated["work_mem"] == "10MB"
    error_message = "work_mem: expected 10MB, got ${output.pgtune_calculated["work_mem"]}"
  }
  assert {
    condition     = output.pgtune_calculated["wal_buffers"] == "64MB"
    error_message = "wal_buffers: expected 64MB for > 16GB RAM, got ${output.pgtune_calculated["wal_buffers"]}"
  }
  assert {
    condition     = output.pgtune_calculated["maintenance_work_mem"] == "2048MB"
    error_message = "maintenance_work_mem: expected 2048MB (capped), got ${output.pgtune_calculated["maintenance_work_mem"]}"
  }
}

# Fixed params — verify against the 8GB/4CPU case
run "fixed_params_8gb_4cpu" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_cpu_num         = 4
  }

  assert {
    condition     = output.pgtune_calculated["min_wal_size"] == "1024MB"
    error_message = "min_wal_size: expected 1024MB, got ${output.pgtune_calculated["min_wal_size"]}"
  }
  assert {
    condition     = output.pgtune_calculated["max_wal_size"] == "4096MB"
    error_message = "max_wal_size: expected 4096MB, got ${output.pgtune_calculated["max_wal_size"]}"
  }
  assert {
    condition     = output.pgtune_calculated["checkpoint_completion_target"] == "0.9"
    error_message = "checkpoint_completion_target: expected 0.9, got ${output.pgtune_calculated["checkpoint_completion_target"]}"
  }
  assert {
    condition     = output.pgtune_calculated["default_statistics_target"] == "100"
    error_message = "default_statistics_target: expected 100, got ${output.pgtune_calculated["default_statistics_target"]}"
  }
  assert {
    condition     = output.pgtune_calculated["huge_pages"] == "try"
    error_message = "huge_pages: expected try, got ${output.pgtune_calculated["huge_pages"]}"
  }
}

# Storage type: hdd
run "hd_type_hdd" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_cpu_num         = 4
    pg_hd_type         = "hdd"
  }

  assert {
    condition     = output.pgtune_calculated["random_page_cost"] == "4"
    error_message = "random_page_cost: expected 4 for hdd, got ${output.pgtune_calculated["random_page_cost"]}"
  }
  assert {
    condition     = output.pgtune_calculated["effective_io_concurrency"] == "2"
    error_message = "effective_io_concurrency: expected 2 for hdd, got ${output.pgtune_calculated["effective_io_concurrency"]}"
  }
}

# Storage type: san
run "hd_type_san" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_cpu_num         = 4
    pg_hd_type         = "san"
  }

  assert {
    condition     = output.pgtune_calculated["random_page_cost"] == "1.1"
    error_message = "random_page_cost: expected 1.1 for san, got ${output.pgtune_calculated["random_page_cost"]}"
  }
  assert {
    condition     = output.pgtune_calculated["effective_io_concurrency"] == "300"
    error_message = "effective_io_concurrency: expected 300 for san, got ${output.pgtune_calculated["effective_io_concurrency"]}"
  }
}

# Explicit pg_connection_num overrides auto formula
run "explicit_connection_num" {
  command = plan

  variables {
    pg_total_memory_gb = 8
    pg_cpu_num         = 4
    pg_connection_num  = 50
  }

  assert {
    condition     = output.pgtune_calculated["max_connections"] == "50"
    error_message = "max_connections: expected explicit value 50, got ${output.pgtune_calculated["max_connections"]}"
  }
}

# maintenance_work_mem cap: > 32GB RAM should cap at 2048MB
run "maintenance_work_mem_cap" {
  command = plan

  variables {
    pg_total_memory_gb = 64
    pg_cpu_num         = 16
  }

  assert {
    condition     = output.pgtune_calculated["maintenance_work_mem"] == "2048MB"
    error_message = "maintenance_work_mem: expected 2048MB cap, got ${output.pgtune_calculated["maintenance_work_mem"]}"
  }
}
