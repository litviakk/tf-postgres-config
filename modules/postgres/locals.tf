# All intermediate memory values are in MB.

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

  restart_required_params = [
    "shared_buffers",
    "max_connections",
    "wal_buffers",
    "max_worker_processes",
    "huge_pages",
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  _total_memory_mb    = var.pg_total_memory_gb * 1024
  _parallel_enabled   = var.pg_cpu_num >= 2
  _wpg_capped         = min(ceil(var.pg_cpu_num / 2), 4)
  _wm_parallel_factor = local._parallel_enabled ? local._wpg_capped : 1

  # ---------------------------------------------------------------------------
  # Intermediate values (MB)
  # ---------------------------------------------------------------------------

  _shared_buffers_mb       = floor(local._total_memory_mb / 4)
  _effective_cache_size_mb = floor(local._total_memory_mb * 0.75)
  _maintenance_work_mem_mb = min(floor(local._total_memory_mb / 16), 2048)

  # Auto max_connections: guarantees work_mem >= 4 MB per connection slot.
  # Explicit pg_connection_num bypasses this entirely.
  _max_connections = var.pg_connection_num > 0 ? var.pg_connection_num : min(200, floor(
    (local._total_memory_mb - local._shared_buffers_mb) / (3 * local._wm_parallel_factor * 4)
  ))

  # Raw work_mem before max(4,...) floor — used only by warn_low_work_mem check.
  # When pg_connection_num = 0 the auto formula guarantees >= 4, so raw = 4 (no warning).
  _work_mem_raw = var.pg_connection_num > 0 ? floor(
    (local._total_memory_mb - local._shared_buffers_mb) /
    (var.pg_connection_num * 3) /
    local._wm_parallel_factor
  ) : 4

  _work_mem_mb = max(4, floor(
    (local._total_memory_mb - local._shared_buffers_mb) /
    (local._max_connections * 3) /
    local._wm_parallel_factor
  ))

  # Stepped: 16 MB (< 4 GB), 32 MB (4–16 GB), 64 MB (> 16 GB).
  _wal_buffers_mb = var.pg_total_memory_gb > 16 ? 64 : var.pg_total_memory_gb >= 4 ? 32 : 16

  _random_page_cost        = var.pg_hd_type == "hdd" ? 4 : 1.1
  _effective_io_concurrency = var.pg_hd_type == "hdd" ? 2 : var.pg_hd_type == "ssd" ? 200 : 300

  # ---------------------------------------------------------------------------
  # pgtune: all computed values as strings, parallelism params omitted when cpu = 1
  # ---------------------------------------------------------------------------

  pgtune = merge(
    {
      max_connections              = tostring(local._max_connections)
      shared_buffers               = "${local._shared_buffers_mb}MB"
      effective_cache_size         = "${local._effective_cache_size_mb}MB"
      maintenance_work_mem         = "${local._maintenance_work_mem_mb}MB"
      work_mem                     = "${local._work_mem_mb}MB"
      huge_pages                   = "try"
      wal_buffers                  = "${local._wal_buffers_mb}MB"
      min_wal_size                 = "1024MB"
      max_wal_size                 = "4096MB"
      checkpoint_completion_target = "0.9"
      default_statistics_target    = "100"
      random_page_cost             = tostring(local._random_page_cost)
      effective_io_concurrency     = tostring(local._effective_io_concurrency)
    },
    local._parallel_enabled ? {
      max_worker_processes             = tostring(var.pg_cpu_num)
      max_parallel_workers_per_gather  = tostring(local._wpg_capped)
      max_parallel_workers             = tostring(var.pg_cpu_num)
      max_parallel_maintenance_workers = tostring(local._wpg_capped)
    } : {}
  )

  # resolved: pgtune merged with pg_overrides. Override keys take precedence.
  resolved = merge(local.pgtune, var.pg_overrides)

  # Restart-required subset of resolved — JSON-encoded as a null_resource trigger
  # so terraform plan shows a diff when any restart param changes.
  restart_params_snapshot = {
    for k, v in local.resolved : k => v
    if contains(local.restart_required_params, k)
  }
}
