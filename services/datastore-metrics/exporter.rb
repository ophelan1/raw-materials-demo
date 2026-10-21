# Datastore metrics exporter: Redis (with Sentinel) and MySQL.
#
# Redis: INFO from every data node and SENTINEL MASTERS from every sentinel,
# so the dashboard shows memory, hit rate, replication lag, and whether the
# sentinels agree there's a healthy master (quorum, failovers).
# MySQL: SHOW GLOBAL STATUS / VARIABLES and Performance Schema's statement
# digests for the heaviest query shapes, the same views PMM is built on.
# Cumulative counters become per-interval deltas (increment_counter).
require "logger"
require "mysql2"
require "redis"
require "appsignal"

Appsignal.start
$stdout.sync = true
LOG = Logger.new($stdout)
INTERVAL = Integer(ENV.fetch("INTERVAL_SECONDS", "30"))
REDIS_NODES = ENV.fetch("REDIS_NODES", "redis-0:6379,redis-1:6379").split(",")
SENTINELS = ENV.fetch("REDIS_SENTINEL_NODES", "redis-sentinel-0:26379").split(",")
MASTER_NAME = ENV.fetch("REDIS_MASTER_NAME", "ijzerhaven")

$previous = {}
def counter(name, value, tags = {})
  key = [name, tags]
  prev = $previous[key]
  $previous[key] = value.to_f
  Appsignal.increment_counter(name, value.to_f - prev, tags) if prev && value.to_f >= prev
end

def gauge(name, value, tags = {})
  Appsignal.set_gauge(name, value.to_f, tags) unless value.nil?
end

def pct(part, whole)
  whole.to_f.positive? ? (part.to_f / whole * 100).round(2) : nil
end

def redis_info(host_port)
  host, port = host_port.split(":")
  client = Redis.new(host: host, port: port.to_i, connect_timeout: 1, read_timeout: 2)
  yield client
ensure
  client&.close
end

def collect_redis
  masters_seen = []
  REDIS_NODES.each do |node|
    redis_info(node) do |r|
      info = r.info
      tags = { redis_node: node.split(":").first }
      role = info["role"]
      masters_seen << node if role == "master"
      gauge("redis_up", 1, tags)
      gauge("redis_is_master", role == "master" ? 1 : 0, tags)
      gauge("redis_connected_clients", info["connected_clients"], tags)
      gauge("redis_blocked_clients", info["blocked_clients"], tags)
      gauge("redis_memory_used_bytes", info["used_memory"], tags)
      gauge("redis_memory_fragmentation_ratio", info["mem_fragmentation_ratio"], tags)
      maxmem = info["maxmemory"].to_i
      gauge("redis_memory_used_pct", pct(info["used_memory"], maxmem)) if maxmem.positive? && role == "master"
      gauge("redis_ops_per_sec", info["instantaneous_ops_per_sec"], tags)
      counter("redis_commands", info["total_commands_processed"], tags)
      hits = counter("redis_keyspace", info["keyspace_hits"], tags.merge(result: "hit"))
      misses = counter("redis_keyspace", info["keyspace_misses"], tags.merge(result: "miss"))
      counter("redis_evicted_keys", info["evicted_keys"], tags)
      counter("redis_expired_keys", info["expired_keys"], tags)
      counter("redis_rejected_connections", info["rejected_connections"], tags)
      gauge("redis_keys", info.select { |k, _| k.start_with?("db") }.sum { |_, v| v[/keys=(\d+)/, 1].to_i }, tags)
      gauge("redis_last_fork_ms", info["latest_fork_usec"].to_i / 1000.0, tags)
      gauge("redis_rdb_last_save_ok", info["rdb_last_bgsave_status"] == "ok" ? 1 : 0, tags)
      if role == "master"
        gauge("redis_connected_replicas", info["connected_slaves"])
        offset = info["master_repl_offset"].to_i
        info.each do |k, v|
          next unless k.match?(/\Aslave\d+\z/)
          fields = v.split(",").to_h { |kv| kv.split("=", 2) }
          gauge("redis_replication_lag_bytes", offset - fields["offset"].to_i, replica: fields["ip"].to_s)
        end
      else
        gauge("redis_replica_link_up", info["master_link_status"] == "up" ? 1 : 0, tags)
      end
    end
  rescue Redis::BaseError, Errno::ECONNREFUSED, SocketError => e
    gauge("redis_up", 0, redis_node: node.split(":").first)
    LOG.warn("Redis #{node} unreachable: #{e.class}")
  end
  gauge("redis_masters", masters_seen.size) # anything but 1 is trouble

  SENTINELS.each do |s|
    redis_info(s) do |r|
      tags = { sentinel: s.split(":").first }
      master = r.call("SENTINEL", "MASTER", MASTER_NAME).each_slice(2).to_h
      flags = master["flags"].to_s
      gauge("redis_sentinel_up", 1, tags)
      gauge("redis_sentinel_master_ok", flags.include?("down") ? 0 : 1, tags)
      gauge("redis_sentinel_known_sentinels", master["num-other-sentinels"].to_i + 1, tags)
      gauge("redis_sentinel_known_replicas", master["num-slaves"], tags)
      gauge("redis_sentinel_quorum", master["quorum"], tags)
      ok = (r.call("SENTINEL", "CKQUORUM", MASTER_NAME) rescue "NOQUORUM").to_s.start_with?("OK")
      gauge("redis_sentinel_quorum_ok", ok ? 1 : 0, tags)
      # The master's address changes on every failover; count the changes.
      addr = r.call("SENTINEL", "GET-MASTER-ADDR-BY-NAME", MASTER_NAME).join(":")
      Appsignal.increment_counter("redis_sentinel_failovers", 1, tags) if $masters&.dig(s) && $masters[s] != addr
      ($masters ||= {})[s] = addr
    end
  rescue Redis::BaseError, Errno::ECONNREFUSED, SocketError => e
    gauge("redis_sentinel_up", 0, sentinel: s.split(":").first)
    LOG.warn("Sentinel #{s} unreachable: #{e.class}")
  end
end

def mysql
  @mysql ||= Mysql2::Client.new(host: ENV.fetch("MYSQL_HOST", "mysql"), username: ENV.fetch("MYSQL_USER"),
    password: ENV.fetch("MYSQL_PASSWORD"), reconnect: true)
end

def collect_mysql
  status = mysql.query("SHOW GLOBAL STATUS").to_h { |r| [r["Variable_name"], r["Value"]] }
  vars = mysql.query("SHOW GLOBAL VARIABLES WHERE Variable_name IN ('max_connections','innodb_buffer_pool_size')")
    .to_h { |r| [r["Variable_name"], r["Value"]] }

  gauge("mysql_up", 1)
  gauge("mysql_threads_connected", status["Threads_connected"])
  gauge("mysql_threads_running", status["Threads_running"])
  gauge("mysql_connections_used_pct", pct(status["Threads_connected"], vars["max_connections"]))
  gauge("mysql_max_used_connections", status["Max_used_connections"])
  counter("mysql_aborted_connects", status["Aborted_connects"])
  counter("mysql_questions", status["Questions"])
  %w[select insert update delete].each { |c| counter("mysql_commands", status["Com_#{c}"], command: c) }
  counter("mysql_slow_queries", status["Slow_queries"])
  counter("mysql_full_scans", status["Select_scan"], kind: "table_scan")
  counter("mysql_full_scans", status["Select_full_join"], kind: "full_join")
  counter("mysql_tmp_disk_tables", status["Created_tmp_disk_tables"])
  counter("mysql_bytes", status["Bytes_received"], direction: "in")
  counter("mysql_bytes", status["Bytes_sent"], direction: "out")

  # InnoDB buffer pool: hit rate over the interval, and how full/dirty it is.
  reqs = counter("mysql_innodb_buffer_pool_reads", status["Innodb_buffer_pool_read_requests"], source: "memory")
  disk = counter("mysql_innodb_buffer_pool_reads", status["Innodb_buffer_pool_reads"], source: "disk")
  gauge("mysql_innodb_buffer_pool_hit_pct", pct(reqs.to_f - disk.to_f, reqs)) if reqs && disk && reqs.positive?
  total = status["Innodb_buffer_pool_pages_total"].to_f
  gauge("mysql_innodb_buffer_pool_used_pct", pct(total - status["Innodb_buffer_pool_pages_free"].to_f, total))
  gauge("mysql_innodb_buffer_pool_dirty_pct", pct(status["Innodb_buffer_pool_pages_dirty"], total))
  counter("mysql_innodb_row_lock_waits", status["Innodb_row_lock_waits"])
  gauge("mysql_innodb_row_lock_time_avg_ms", status["Innodb_row_lock_time_avg"])
  counter("mysql_innodb_deadlocks", status["Innodb_deadlocks"]) if status["Innodb_deadlocks"]

  # Replication (zero rows on a primary; lag in seconds on a replica).
  replica = (mysql.query("SHOW REPLICA STATUS").first rescue nil)
  gauge("mysql_replication_lag_seconds", replica["Seconds_Behind_Source"]) if replica

  # Heaviest statement shapes, from Performance Schema digests (times are in picoseconds).
  mysql.query(<<~SQL).each do |d|
    SELECT LEFT(DIGEST_TEXT, 80) AS query, COUNT_STAR AS calls, SUM_TIMER_WAIT AS total_ps,
           SUM_ROWS_EXAMINED AS rows_examined, SUM_NO_INDEX_USED AS no_index
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SCHEMA_NAME = 'telemetry' AND DIGEST_TEXT REGEXP '^(SELECT|INSERT|UPDATE|DELETE)'
    ORDER BY SUM_TIMER_WAIT DESC LIMIT 10
  SQL
    tags = { query: d["query"].to_s.gsub(/\s+/, " ") }
    calls = counter("mysql_query_calls", d["calls"], tags)
    time = counter("mysql_query_total_ms", d["total_ps"].to_f / 1e9, tags)
    gauge("mysql_query_mean_ms", (time / calls).round(3), tags) if calls && time && calls.positive?
    examined = counter("mysql_query_rows_examined", d["rows_examined"], tags)
    gauge("mysql_query_rows_examined_per_call", (examined / calls).round, tags) if examined && calls&.positive?
    counter("mysql_query_no_index_used", d["no_index"], tags)
  end

  mysql.query(<<~SQL).each do |t|
    SELECT TABLE_NAME AS name, DATA_LENGTH + INDEX_LENGTH AS size, TABLE_ROWS AS row_estimate
    FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'telemetry'
  SQL
    gauge("mysql_table_size_bytes", t["size"], table: t["name"])
    gauge("mysql_table_rows", t["row_estimate"], table: t["name"])
  end
rescue Mysql2::Error => e
  gauge("mysql_up", 0)
  LOG.warn("MySQL unavailable: #{e.message}")
  @mysql = nil
end

loop do
  collect_redis
  collect_mysql
  LOG.info("Reported Redis and MySQL metrics")
  sleep INTERVAL
end
