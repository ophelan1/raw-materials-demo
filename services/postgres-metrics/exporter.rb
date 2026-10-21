# Postgres metrics exporter: reads Postgres's own statistics views and reports
# them to AppSignal, so the database gets the same dashboards and alerts as the
# apps and the cluster.
#
# Cumulative Postgres counters (commits, rows, blocks, scans) are turned into
# per-interval deltas and sent with increment_counter, so AppSignal shows them
# as "per minute". Point-in-time values are sent as gauges.
require "logger"
require "pg"
require "appsignal"

Appsignal.start
$stdout.sync = true
LOG = Logger.new($stdout)
INTERVAL = Integer(ENV.fetch("INTERVAL_SECONDS", "30"))
DATABASE = ENV.fetch("PGDATABASE", "orders")
TOP_QUERIES = 10

def gauge(name, value, tags = {})
  Appsignal.set_gauge(name, value.to_f, tags) unless value.nil?
end

# Previous cumulative values, keyed by metric and tags.
$previous = {}
def delta(key, value)
  prev = $previous[key]
  $previous[key] = value.to_f
  prev && value.to_f >= prev ? value.to_f - prev : nil
end

def counter(name, value, tags = {})
  d = delta([name, tags], value)
  Appsignal.increment_counter(name, d, tags) if d
  d
end

def pct(part, whole)
  whole.to_f.positive? ? (part.to_f / whole * 100).round(2) : nil
end

def connect
  conn = PG.connect(ENV.fetch("DATABASE_URL"))
  conn.exec("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
  conn
end

def collect(db)
  # Connections
  max = db.exec("SHOW max_connections").getvalue(0, 0).to_i
  states = db.exec(<<~SQL).to_a
    SELECT coalesce(state, 'background') AS state, count(*) AS n
    FROM pg_stat_activity WHERE datname = current_database() OR state IS NULL GROUP BY 1
  SQL
  total = states.sum { |r| r["n"].to_i }
  %w[active idle idle\ in\ transaction].each do |s|
    gauge("pg_connections", states.find { |r| r["state"] == s }&.fetch("n") || 0, state: s.tr(" ", "_"))
  end
  gauge("pg_connections_max", max)
  gauge("pg_connections_used_pct", pct(total, max))

  # Database-wide activity
  d = db.exec_params(<<~SQL, [DATABASE]).first
    SELECT xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched,
           tup_inserted, tup_updated, tup_deleted, deadlocks, temp_bytes, conflicts,
           pg_database_size(datname) AS size
    FROM pg_stat_database WHERE datname = $1
  SQL
  commits = counter("pg_transactions", d["xact_commit"], result: "commit")
  rollbacks = counter("pg_transactions", d["xact_rollback"], result: "rollback")
  gauge("pg_rollback_pct", pct(rollbacks, commits.to_f + rollbacks.to_f)) if commits && rollbacks
  hit = counter("pg_blocks", d["blks_hit"], source: "cache")
  read = counter("pg_blocks", d["blks_read"], source: "disk")
  gauge("pg_cache_hit_pct", pct(hit, hit.to_f + read.to_f)) if hit && read && (hit + read).positive?
  { "returned" => "tup_returned", "fetched" => "tup_fetched", "inserted" => "tup_inserted",
    "updated" => "tup_updated", "deleted" => "tup_deleted" }.each do |op, col|
    counter("pg_rows", d[col], operation: op)
  end
  Appsignal.increment_counter("pg_deadlocks", delta(:deadlocks, d["deadlocks"]) || 0)
  counter("pg_temp_bytes", d["temp_bytes"])
  gauge("pg_database_size_bytes", d["size"], database: DATABASE)

  # Long-running work and lock waits
  a = db.exec(<<~SQL).first
    SELECT
      coalesce(max(extract(epoch FROM now() - query_start)) FILTER (WHERE state = 'active' AND pid <> pg_backend_pid()), 0) AS longest_query,
      coalesce(max(extract(epoch FROM now() - xact_start)) FILTER (WHERE xact_start IS NOT NULL AND pid <> pg_backend_pid()), 0) AS longest_xact,
      coalesce(max(extract(epoch FROM now() - state_change)) FILTER (WHERE state = 'idle in transaction'), 0) AS idle_in_xact
    FROM pg_stat_activity WHERE datname = current_database()
  SQL
  gauge("pg_longest_query_seconds", a["longest_query"])
  gauge("pg_longest_transaction_seconds", a["longest_xact"])
  gauge("pg_idle_in_transaction_seconds", a["idle_in_xact"])
  gauge("pg_locks_waiting", db.exec("SELECT count(*) FROM pg_locks WHERE NOT granted").getvalue(0, 0))

  # Per table: size, bloat, scans, vacuum
  db.exec(<<~SQL).each do |t|
    SELECT relname, n_live_tup, n_dead_tup, seq_scan, coalesce(idx_scan, 0) AS idx_scan,
           pg_total_relation_size(relid) AS size,
           extract(epoch FROM now() - greatest(last_autovacuum, last_vacuum)) AS since_vacuum
    FROM pg_stat_user_tables
  SQL
    tags = { table: t["relname"] }
    gauge("pg_table_size_bytes", t["size"], tags)
    gauge("pg_table_live_rows", t["n_live_tup"], tags)
    gauge("pg_table_dead_rows", t["n_dead_tup"], tags)
    gauge("pg_table_dead_rows_pct", pct(t["n_dead_tup"], t["n_live_tup"].to_f + t["n_dead_tup"].to_f), tags)
    counter("pg_table_scans", t["seq_scan"], tags.merge(scan: "sequential"))
    counter("pg_table_scans", t["idx_scan"], tags.merge(scan: "index"))
    gauge("pg_table_seconds_since_vacuum", t["since_vacuum"], tags) if t["since_vacuum"]
  end

  # Slowest query shapes (pg_stat_statements), top 10 by total time
  db.exec(<<~SQL).each do |q|
    SELECT queryid, left(regexp_replace(query, '\\s+', ' ', 'g'), 80) AS query,
           calls, total_exec_time, mean_exec_time, rows
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      -- Only the app's own reads and writes: no monitoring, DDL, session
      -- setup or catalog lookups.
      AND query ~* '^\\s*(SELECT|INSERT|UPDATE|DELETE)'
      AND query !~* '(pg_stat|pg_locks|pg_database|pg_class|pg_attribute|pg_catalog|current_setting|pg_advisory)'
    ORDER BY total_exec_time DESC LIMIT #{TOP_QUERIES}
  SQL
    tags = { query: q["query"] }
    gauge("pg_query_mean_ms", q["mean_exec_time"].to_f.round(3), tags)
    counter("pg_query_calls", q["calls"], tags)
    counter("pg_query_total_ms", q["total_exec_time"], tags)
  end

  LOG.info("Reported Postgres metrics (#{total}/#{max} connections, #{d["size"].to_i / 1024 / 1024} MB)")
end

db = nil
loop do
  begin
    db ||= connect
    collect(db)
  rescue PG::Error => e
    LOG.error("Postgres unavailable: #{e.class}: #{e.message}")
    db&.close rescue nil
    db = nil
  end
  sleep INTERVAL
end
