#!/bin/bash
# MySQL/Percona Server Benchmark Script with Metrics Collection
#
# Usage: ./run_metrics.sh --server-dir=<path> [--read-only] [--binlog] [--thread-pool=0|1]
#                         [--table-rows=<n>[K|M]] [--warmup=<seconds>] [--duration=<seconds>]
#                         [--thread-list=<n,n,...>] [--pool-size-list=<n,n,...>] [--cpu-freq=<MHz>]
#                         [--runs=<n>] [--run-start=<n>]
#
# Arguments:
#   --server-dir=<path>  - (Required) Path to the server installation directory.
#                          DBMS name and version are detected from the directory name,
#                          e.g. .../Percona-Server-8.4.10-10-Linux.x86_64.glibc2.35
#                          gives name "Percona-Server" and version "8.4.10-10".
#   --read-only[=0|1]    - (Optional) Run read-only tests (default: false)
#   --binlog[=0|1]       - (Optional) Enable binary logging (default: false)
#   --thread-pool[=0|1]  - (Optional) Enable thread pool (default: true)
#   --table-rows=<n>     - (Optional) Rows per table (default: 5M).
#                          Supports K (thousands) and M (millions) suffixes, e.g. 500K, 5M.
#   --warmup=<seconds>   - (Optional) Read-write warmup time in seconds (default: 600)
#   --duration=<seconds> - (Optional) Benchmark duration in seconds (default: 900)
#   --thread-list=<list> - (Optional) Comma-separated sysbench thread counts
#                          (default: 1,4,16,32,64,128,256,512,1024)
#   --pool-size-list=<list> - (Optional) Comma-separated buffer pool sizes in GB
#                          (default: 2,12,32)
#   --cpu-freq=<MHz>     - (Optional) CPU frequency in MHz to pin all cores to (default: 2400)
#   --runs=<n>           - (Optional) Number of runs per iteration (default: 1)
#   --run-start=<n>      - (Optional) Start run number (default: 1); each run prepends
#                          "run<N>_" to the results file names
#
# Examples:
#   ./run_metrics.sh --server-dir=~/servers/Percona-Server-8.4.10-10-Linux.x86_64.glibc2.35
#   ./run_metrics.sh --server-dir=~/servers/mysql-9.7.0-linux-glibc2.28-x86_64 --read-only
#   ./run_metrics.sh --server-dir=... --binlog --thread-pool=0 --table-rows=500K --warmup=60 --duration=120
#   ./run_metrics.sh --server-dir=... --thread-list=32,64,128 --pool-size-list=12

# --- VARIABLES ---
DB_HOST="127.0.0.1"
DB_USER="root"
DB_PASS="password"
DB_DATABASE="sbtest"
DB_PORT="3306"

# Server locations
DATADIR_BASE="/home/bogdan.degtyariov/mysql-nvme/data"

# Buffer pool tiers (GB), overridden by --pool-size-list
POOL_SIZES=(2 12 32)

# Sysbench thread counts, overridden by --thread-list
THREADS=(1 4 16 32 64 128 256 512 1024)

# --- DEBUG SETTINGS ---
TABLE_ROWS=5000000
WARMUP_TIME=600
DURATION=900

# --- ARGUMENT PARSING ---
usage() {
    echo "Usage: $0 --server-dir=<path> [--read-only] [--binlog] [--thread-pool=0|1]" >&2
    echo "          [--table-rows=<n>[K|M]] [--warmup=<seconds>] [--duration=<seconds>]" >&2
    echo "          [--thread-list=<n,n,...>] [--pool-size-list=<n,n,...>] [--cpu-freq=<MHz>]" >&2
    echo "          [--runs=<n>] [--run-start=<n>]" >&2
    exit 1
}

parse_bool() {
    case "$1" in
        1|true|TRUE|yes|on)   echo "1" ;;
        0|false|FALSE|no|off) echo "0" ;;
        *) echo "ERROR: Invalid boolean value: $1" >&2; exit 1 ;;
    esac
}

# Plain integer with optional K (thousands) or M (millions) suffix, e.g. 500K, 5M
parse_rows() {
    if [[ "$1" =~ ^([0-9]+)([KkMm]?)$ ]]; then
        local NUM="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            K|k) echo $(( NUM * 1000 )) ;;
            M|m) echo $(( NUM * 1000000 )) ;;
            *)   echo "$NUM" ;;
        esac
    else
        echo "ERROR: Invalid row count: $1 (expected e.g. 5000000, 500K or 5M)" >&2
        exit 1
    fi
}

parse_uint() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "$1"
    else
        echo "ERROR: Invalid ${2:-number}: $1" >&2
        exit 1
    fi
}

# Comma-separated list of integers, e.g. 32,64,128 -> "32 64 128"
parse_int_list() {
    if [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "${1//,/ }"
    else
        echo "ERROR: Invalid list: $1 (expected comma-separated integers, e.g. 32,64,128)" >&2
        exit 1
    fi
}

SERVER_DIR=""
IS_READ_ONLY="0"
ENABLE_BINLOG="0"
ENABLE_THREAD_POOL="1"
CPU_FREQ_MHZ="2400"
NUM_RUNS="1"
RUN_START="1"

for arg in "$@"; do
    case "$arg" in
        --server-dir=*)  SERVER_DIR="${arg#*=}" ;;
        --read-only)     IS_READ_ONLY="1" ;;
        --read-only=*)   IS_READ_ONLY=$(parse_bool "${arg#*=}") || exit 1 ;;
        --binlog)        ENABLE_BINLOG="1" ;;
        --binlog=*)      ENABLE_BINLOG=$(parse_bool "${arg#*=}") || exit 1 ;;
        --thread-pool)   ENABLE_THREAD_POOL="1" ;;
        --thread-pool=*) ENABLE_THREAD_POOL=$(parse_bool "${arg#*=}") || exit 1 ;;
        --table-rows=*)  TABLE_ROWS=$(parse_rows "${arg#*=}") || exit 1 ;;
        --warmup=*)      WARMUP_TIME=$(parse_uint "${arg#*=}" "number of seconds") || exit 1 ;;
        --duration=*)    DURATION=$(parse_uint "${arg#*=}" "number of seconds") || exit 1 ;;
        --cpu-freq=*)    CPU_FREQ_MHZ=$(parse_uint "${arg#*=}" "CPU frequency in MHz") || exit 1 ;;
        --runs=*)        NUM_RUNS=$(parse_uint "${arg#*=}" "number of runs") || exit 1 ;;
        --run-start=*)   RUN_START=$(parse_uint "${arg#*=}" "start run number") || exit 1 ;;
        --thread-list=*)    LIST=$(parse_int_list "${arg#*=}") || exit 1; THREADS=($LIST) ;;
        --pool-size-list=*) LIST=$(parse_int_list "${arg#*=}") || exit 1; POOL_SIZES=($LIST) ;;
        -h|--help)       usage ;;
        *) echo "ERROR: Unknown argument: $arg" >&2; usage ;;
    esac
done

if [ -z "$SERVER_DIR" ]; then
    echo "ERROR: --server-dir is required" >&2
    usage
fi

SERVER_DIR="${SERVER_DIR%/}"
if [ ! -d "$SERVER_DIR" ]; then
    echo "ERROR: Server directory not found: $SERVER_DIR" >&2
    exit 1
fi

# --- DETECT DBMS NAME & VERSION FROM SERVER DIR ---
# e.g. Percona-Server-8.4.10-10-Linux.x86_64.glibc2.35 -> name "Percona-Server", version "8.4.10-10"
#      mysql-9.7.0-linux-glibc2.28-x86_64             -> name "mysql", version "9.7.0"
DIR_BASE=$(basename "$SERVER_DIR")
STRIPPED="${DIR_BASE%%-[Ll]inux*}"
if [[ "$STRIPPED" =~ ^([A-Za-z][A-Za-z_-]*)-([0-9][0-9.-]*)$ ]]; then
    DBMS_NAME="${BASH_REMATCH[1]}"
    DBMS_VER="${BASH_REMATCH[2]}"
else
    echo "ERROR: Cannot detect DBMS name/version from directory name: $DIR_BASE" >&2
    exit 1
fi

ADMIN_TOOL="mysqladmin"

# Pin CPU frequency for stable benchmark results
sudo cpupower frequency-set -g performance -d "${CPU_FREQ_MHZ}MHz" -u "${CPU_FREQ_MHZ}MHz" > /dev/null

echo "============= Running benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="
echo "Server dir:  $SERVER_DIR"
echo "CPU freq:    ${CPU_FREQ_MHZ} MHz"
echo "Thread pool: $([ "$ENABLE_THREAD_POOL" -eq 1 ] && echo "ENABLED" || echo "DISABLED")"

MYSQLD="${SERVER_DIR}/bin/mysqld"
MYSQL_CLIENT="${SERVER_DIR}/bin/mysql"
MYSQLADMIN="${SERVER_DIR}/bin/${ADMIN_TOOL}"

if [ ! -x "$MYSQLD" ]; then
    echo "ERROR: mysqld not found or not executable: $MYSQLD"
    exit 1
fi

CONFIG_DIR="$HOME/configs"
CONFIG_NAME="my.cnf"
CONFIG_PATH="${CONFIG_DIR}/${CONFIG_NAME}"

# PID file for server management
PID_FILE="/tmp/mysql_benchmark.pid"

server_wait() {
  echo "Waiting for DB Server to initialize..."
  sleep 5

  # Check if mysqld process is running
  if [ -f "$PID_FILE" ]; then
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Fatal error: mysqld process is not running (PID: $pid). Terminating script."
      exit 1
    fi
  else
    echo "Fatal error: PID file not found. Terminating script."
    exit 1
  fi

  until "$MYSQLADMIN" ping --host=$DB_HOST --port=$DB_PORT -u"$DB_USER" -p"$DB_PASS" 2>/dev/null; do
    echo "Waiting for server to respond..."
    sleep 2
  done
  echo "Server is ready!"
}

stop_server() {
  echo "Stopping MySQL server..."
  if [ -f "$PID_FILE" ]; then
    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      "$MYSQLADMIN" --host=$DB_HOST --port=$DB_PORT -u"$DB_USER" -p"$DB_PASS" shutdown 2>/dev/null
      sleep 3
      # Force kill if still running
      if kill -0 "$pid" 2>/dev/null; then
        echo "Force killing mysqld (PID: $pid)"
        kill -9 "$pid" 2>/dev/null
      fi
    fi
    rm -f "$PID_FILE"
  fi
  sleep 2
}

start_server() {
  local DATADIR=$1
  local CONFIG=$2

  echo "Starting MySQL server..."
  echo "  Server: $MYSQLD"
  echo "  Datadir: $DATADIR"
  echo "  Config: $CONFIG"
  echo "  Command: $MYSQLD --defaults-file=$CONFIG --datadir=$DATADIR --pid-file=$PID_FILE --user=$(whoami)"

  # Start mysqld in background
  "$MYSQLD" --defaults-file="$CONFIG" --datadir="$DATADIR" --pid-file="$PID_FILE" \
    --user=$(whoami) &

  # Wait a moment for PID file to be created
  sleep 15

  cat $PID_FILE

  if [ ! -f "$PID_FILE" ]; then
    echo "ERROR: Failed to start mysqld (PID file not created)"
    exit 1
  fi

  echo "mysqld started with PID: $(cat $PID_FILE)"
}

initialize_datadir() {
  local DATADIR=$1

  echo "Initializing clean data directory: $DATADIR"

  # Remove old datadir if exists
  if [ -d "$DATADIR" ]; then
    echo "Removing old datadir..."
    rm -rf "$DATADIR"
  fi

  # Create fresh datadir
  mkdir -p "$DATADIR"

  # Initialize MySQL data directory
  echo "Running mysqld --initialize-insecure..."
  "$MYSQLD" --initialize-insecure --datadir="$DATADIR" --user=$(whoami)

  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to initialize data directory"
    exit 1
  fi

  echo "Data directory initialized successfully"
}

# Make sure no server is running at this stage
stop_server

# --- DETECT VERSION & VENDOR ---
echo "Starting server to detect version..."

if [[ "$IS_READ_ONLY" == "1" ]]; then
    BENCH_DIR="./benchmark_logs_read_only"
elif [[ "$ENABLE_BINLOG" == "1" ]]; then
    BENCH_DIR="./benchmark_logs_binlog"
else
    BENCH_DIR="./benchmark_logs"
fi

echo "Removing old config if exists: $CONFIG_PATH"
rm -rf "$CONFIG_PATH"

# Create temporary minimal config for version detection
TMP_DATADIR="${DATADIR_BASE}/tmp_init"
initialize_datadir "$TMP_DATADIR"

# Create minimal config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_PATH" << EOF
[mysqld]
port=$DB_PORT
socket=/tmp/mysql_benchmark.sock
datadir=$TMP_DATADIR
EOF

start_server "$TMP_DATADIR" "$CONFIG_PATH"
server_wait

# Set root password and grant TCP/IP access (use socket for initial connection)
"$MYSQLADMIN" --socket=/tmp/mysql_benchmark.sock -u"$DB_USER" password "$DB_PASS" 2>/dev/null

# Grant access from 127.0.0.1
"$MYSQL_CLIENT" --socket=/tmp/mysql_benchmark.sock -u"$DB_USER" -p"$DB_PASS" -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$DB_PASS'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null

RAW_VERSION=$("$MYSQL_CLIENT" -h $DB_HOST --port=$DB_PORT -u $DB_USER -p$DB_PASS -N -e "SELECT VERSION();" 2>/dev/null)
MAJOR_VER=$(echo $RAW_VERSION | cut -d'.' -f1,2)

LOG_DIR="${BENCH_DIR}/${DBMS_NAME}/${RAW_VERSION}"
mkdir -p "$LOG_DIR"

echo "Detected: $RAW_VERSION (Major: $MAJOR_VER)"
[ "$ENABLE_BINLOG" == "1" ] && echo "Binary logging: ENABLED"
[ "$ENABLE_BINLOG" != "1" ] && echo "Binary logging: DISABLED"
[ "$ENABLE_THREAD_POOL" == "1" ] && echo "Thread pool: ENABLED"
[ "$ENABLE_THREAD_POOL" != "1" ] && echo "Thread pool: DISABLED"

stop_server
rm -rf "$TMP_DATADIR"

check_innodb_buffer() {
    local EXPECTED_GB=$1
    echo ">>> Verifying InnoDB Buffer Pool: ${EXPECTED_GB}GB..."

    local ACTUAL_BYTES=$("$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -s -e "SELECT @@innodb_buffer_pool_size;")
    local ACTUAL_GB=$(( ACTUAL_BYTES / 1024 / 1024 / 1024 ))

    if [ "$ACTUAL_GB" -ne "$EXPECTED_GB" ]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "CRITICAL ERROR: Buffer Pool is ${ACTUAL_GB}GB (Expected ${EXPECTED_GB}GB)"
        echo "Aborting entire benchmark script immediately."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        exit 1
    fi

    echo "Verification successful: Buffer Pool is ${ACTUAL_GB}GB."
}

check_vars_status() {
    local FILE_PREFIX=$1
    echo ">>> Capturing server variables and status..."

    "$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW VARIABLES;" > "${FILE_PREFIX}.vars.txt" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "    Variables saved to: ${FILE_PREFIX}.vars.txt"
    else
        echo "    ERROR: Failed to capture variables"
    fi

    "$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW STATUS;" > "${FILE_PREFIX}.status.txt" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "    Status saved to: ${FILE_PREFIX}.status.txt"
    else
        echo "    ERROR: Failed to capture status"
    fi
}

run_mysql_summary() {
    local FILE_PREFIX=$1
    ./pt-mysql-summary --host="$DB_HOST" --port=$DB_PORT --user="$DB_USER" --password="$DB_PASS" > "${FILE_PREFIX}-pt-mysql-summary.txt"
    if [ $? -eq 0 ]; then
        echo "    Server summary saved to: ${FILE_PREFIX}-pt-mysql-summary.txt"
    else
        echo "    ERROR: Failed to server summary with pt-mysql-summary"
    fi
}

# --- CONFIGURATION GENERATOR ---
generate_config() {
    local SIZE=$1
    local DATADIR=$2
    local CFG="/tmp/$CONFIG_NAME"
    rm -f "$CFG"

    # 1. Start Base Config
    echo "[mysqld]" > "$CFG"
    echo "port                            = $DB_PORT" >> "$CFG"
    echo "socket                          = /tmp/mysql_benchmark.sock" >> "$CFG"
    echo "datadir                         = $DATADIR" >> "$CFG"
    echo "log_error_verbosity             = 3" >> "$CFG"
    echo "log_error                       = ${DATADIR}/mysql-error.log" >> "$CFG"

    echo "# --- General -------------------------------------------------------------------" >> "$CFG"
    echo "user                            = $(whoami)" >> "$CFG"
    echo "bind-address                    = 0.0.0.0" >> "$CFG"
    echo "skip-name-resolve               = ON" >> "$CFG"
    #echo "performance_schema              = OFF" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Connection & Threading ----------------------------------------------------" >> "$CFG"
    echo "max_connections                 = 2000" >> "$CFG"
    echo "max_connect_errors              = 1000000" >> "$CFG"
    echo "max_prepared_stmt_count         = 1000000" >> "$CFG"
    echo "thread_stack                    = 512K" >> "$CFG"
    echo "thread_cache_size               = 256" >> "$CFG"
    echo "back_log                        = 4096" >> "$CFG"
    echo "wait_timeout                    = 300" >> "$CFG"
    echo "interactive_timeout             = 300" >> "$CFG"
    echo "connect_timeout                 = 60" >> "$CFG"
    echo "" >> "$CFG"

    if [ "$ENABLE_THREAD_POOL" -eq 1 ]; then
        echo "" >> "$CFG"
        echo "# --- Thread Pool (Percona Server) ------------------------------------------" >> "$CFG"
        echo "thread_handling                 = pool-of-threads" >> "$CFG"
        echo "thread_pool_size                = 80                # match physical core count" >> "$CFG"
        echo "thread_pool_max_threads         = 2000" >> "$CFG"
        echo "thread_pool_oversubscribe       = 3" >> "$CFG"
        echo "" >> "$CFG"
    fi

    echo "# --- InnoDB - Buffer pool Tier -------------------------------------------------" >> "$CFG"
    echo "innodb_buffer_pool_size         = ${SIZE}G" >> "$CFG"
    echo "innodb_buffer_pool_load_at_startup  = OFF" >> "$CFG"
    echo "innodb_buffer_pool_dump_at_shutdown = OFF" >> "$CFG"

    echo "" >> "$CFG"
    echo "# --- InnoDB – I/O (NVMe can saturate many threads) ----------------------------" >> "$CFG"
    echo "innodb_io_capacity              = 10000" >> "$CFG"
    echo "innodb_io_capacity_max          = 20000" >> "$CFG"
    echo "innodb_read_io_threads          = 16" >> "$CFG"
    echo "innodb_write_io_threads         = 16" >> "$CFG"
    echo "innodb_use_native_aio           = ON" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- InnoDB – Log / Durability -------------------------------------------------" >> "$CFG"
    echo "innodb_log_buffer_size          = 256M" >> "$CFG"
    echo "innodb_flush_log_at_trx_commit  = 1          # full ACID; use 2 for ~10 % more speed" >> "$CFG"
    echo "innodb_doublewrite              = ON" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- InnoDB – Concurrency & OLTP Tuning ---------------------------------------" >> "$CFG"
    echo "innodb_stats_on_metadata        = OFF" >> "$CFG"
    echo "innodb_open_files               = 65536" >> "$CFG"
    echo "innodb_lock_wait_timeout        = 50" >> "$CFG"
    echo "innodb_rollback_on_timeout      = ON" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Per-Session Buffers (keep modest; many connections × this = RAM) ----------" >> "$CFG"
    echo "sort_buffer_size                = 4M" >> "$CFG"
    echo "join_buffer_size                = 4M" >> "$CFG"
    echo "read_buffer_size                = 2M" >> "$CFG"
    echo "read_rnd_buffer_size            = 4M" >> "$CFG"
    echo "tmp_table_size                  = 256M" >> "$CFG"
    echo "max_heap_table_size             = 256M" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Table & File Handles ------------------------------------------------------" >> "$CFG"
    echo "table_open_cache                = 65536" >> "$CFG"
    echo "table_definition_cache          = 65536" >> "$CFG"
    echo "open_files_limit                = 1000000" >> "$CFG"
    echo "table_open_cache_instances      = 64" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Binary Log ----------------------------------------------------------------" >> "$CFG"
    if [ "$ENABLE_BINLOG" == "1" ]; then
        echo "# Binary logging ENABLED" >> "$CFG"
        echo "server_id                       = 1" >> "$CFG"
        echo "log_bin                         = ${DATADIR}/mysql-bin" >> "$CFG"
        echo "binlog_format                   = ROW" >> "$CFG"
        echo "binlog_row_image                = MINIMAL" >> "$CFG"
        echo "sync_binlog                     = 1" >> "$CFG"
        echo "binlog_cache_size               = 4M" >> "$CFG"
        echo "max_binlog_size                 = 512M" >> "$CFG"
    else
        echo "# Binary logging DISABLED for benchmarking" >> "$CFG"
        echo "disable_log_bin                 = ON" >> "$CFG"
    fi
    echo "" >> "$CFG"

    echo "# --- Slow Query Log ------------------------------------------------------------" >> "$CFG"
    echo "slow_query_log                  = ON" >> "$CFG"
    echo "slow_query_log_file             = ${DATADIR}/slow.log" >> "$CFG"
    echo "long_query_time                 = 1" >> "$CFG"
    echo "log_queries_not_using_indexes   = OFF" >> "$CFG"
    echo "min_examined_row_limit          = 1000" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Character Set -------------------------------------------------------------" >> "$CFG"
    echo "character_set_server            = utf8mb4" >> "$CFG"
    echo "collation_server                = utf8mb4_unicode_ci" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Misc ----------------------------------------------------------------------" >> "$CFG"
    echo "max_allowed_packet              = 64M" >> "$CFG"
    echo "bulk_insert_buffer_size         = 256M" >> "$CFG"
    echo "myisam_sort_buffer_size         = 128M" >> "$CFG"
    echo "key_buffer_size                 = 64M        # MyISAM only; keep small for OLTP" >> "$CFG"
    echo "" >> "$CFG"

    echo "# --- Version specific settings -------------------------------------------------" >> "$CFG"

    # 3. VERSION SPECIFIC LOGIC
    INSTANCES=$(( SIZE / 5 ))
    [ "$INSTANCES" -lt 1 ] && INSTANCES=1
    [ "$INSTANCES" -gt 8 ] && INSTANCES=8

    # MySQL 8.4+ / 9.x
    echo "innodb_redo_log_capacity = 4G" >> "$CFG"
    echo "innodb_change_buffering = none" >> "$CFG"
    echo "innodb_flush_method = O_DIRECT" >> "$CFG"
    echo "innodb_buffer_pool_instances    = $INSTANCES" >> "$CFG"

    # Percona Server specific settings
    # if [[ "$DBMS_NAME" == "percona-server" ]]; then
    #     echo "innodb_empty_free_list_algorithm = backoff" >> "$CFG"
    # fi

    # 4. Deploy Config
    mkdir -p "$CONFIG_DIR"
    cp "$CFG" "$CONFIG_PATH"
    cp "$CFG" "${LOG_DIR}/Tier${SIZE}G.cnf.txt"

    chmod 644 "$CONFIG_PATH"
}

copy_server_logs() {
    local SIZE=$1
    local DATADIR=$2
    local DEST_DIR="${LOG_DIR}"

    echo "Copying server logs to ${DEST_DIR}..."
    if [ -f "${DATADIR}/mysql-error.log" ]; then
        cp "${DATADIR}/mysql-error.log" "${DEST_DIR}/Tier${SIZE}G.errlog.txt"
    fi
}

# --- TELEMETRY FUNCTIONS ---
start_innodb_metrics() {
    local PREFIX=$1
    local OUT="${PREFIX}.innodb.txt"
    echo "innodb metrics -> ${OUT}"

    (
        # Header: one column per metric NAME, sorted
        HEADER=$("$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -B \
            -e "SELECT NAME FROM information_schema.INNODB_METRICS ORDER BY NAME" 2>/dev/null \
            | paste -sd,)
        echo "timestamp,${HEADER}" > "$OUT"

        while :; do
            TS=$(date +%s.%3N)
            VALS=$("$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -B \
                -e "SELECT COUNT FROM information_schema.INNODB_METRICS ORDER BY NAME" 2>/dev/null \
                | paste -sd,)
            echo "${TS},${VALS}" >> "$OUT"
            sleep 1
        done
    ) &
    echo $! > /tmp/innodb.pid
}

start_lru_metrics() {
    local PREFIX=$1
    local OUT="${PREFIX}.lru_metrics.csv"
    echo "all enabled InnoDB metrics (long format) -> ${OUT}"

    # Get the directory of this script
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local COLLECTOR="${SCRIPT_DIR}/collect_lru_metrics.sh"

    if [ ! -x "$COLLECTOR" ]; then
        echo "WARNING: InnoDB metrics collector not found or not executable: $COLLECTOR"
        return 1
    fi

    # Start the collector in the background
    "$COLLECTOR" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$OUT" 2>/dev/null &
    local pid=$!
    echo $pid > /tmp/lru_metrics.pid

    # Verify it started successfully
    sleep 0.5
    if ! kill -0 $pid 2>/dev/null; then
        echo "WARNING: Failed to start InnoDB metrics collector"
        rm -f /tmp/lru_metrics.pid
        return 1
    fi

    return 0
}

start_mutex_metrics() {
    local PREFIX=$1
    local OUT="${PREFIX}.mutex_metrics.csv"
    echo "InnoDB mutex metrics -> ${OUT}"

    # Get the directory of this script
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local COLLECTOR="${SCRIPT_DIR}/collect_mutex_metrics.sh"

    if [ ! -x "$COLLECTOR" ]; then
        echo "WARNING: Mutex metrics collector not found or not executable: $COLLECTOR"
        return 1
    fi

    # Start the collector in the background
    "$COLLECTOR" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$OUT" 2>/dev/null &
    local pid=$!
    echo $pid > /tmp/mutex_metrics.pid

    # Verify it started successfully
    sleep 0.5
    if ! kill -0 $pid 2>/dev/null; then
        echo "WARNING: Failed to start mutex metrics collector"
        rm -f /tmp/mutex_metrics.pid
        return 1
    fi

    return 0
}

enable_innodb_metrics() {
    echo ">>> Enabling all InnoDB metrics counters..."
    "$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N \
        -e "SET GLOBAL innodb_monitor_enable = 'latch';" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "    innodb_monitor_enable = 'latch'"
    else
        echo "    ERROR: Failed to set innodb_monitor_enable"
    fi

    # Note: 'all' enables all available metrics including buffer_LRU_% if present
}

start_gdb_snapshots() {
    local PREFIX=$1
    local OUT="${PREFIX}.pt-pmp.txt"
    local DELAY=$((DURATION / 2))

    echo "pt-pmp stack profiling -> ${OUT} (will start after ${DELAY}s)"

    (
        # Wait for half of benchmark duration before starting profiling
        echo "Waiting ${DELAY} seconds before starting pt-pmp profiling..." > "$OUT"
        sleep $DELAY

        echo "" >> "$OUT"
        echo "Starting stack trace collection at $(date)" >> "$OUT"
        echo "Collecting stack traces using pt-pmp (auto-detecting mysqld)" >> "$OUT"
        echo "================================================" >> "$OUT"
        echo "" >> "$OUT"

        # Get absolute path to current directory for pt-eustack-resolver
        local SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

        # Run pt-pmp with sudo, providing PATH so it can find pt-eustack-resolver
        # Collect 30 snapshots with pt-pmp (auto-detects mysqld process)
        sudo env "PATH=$SCRIPT_DIR:$PATH" "$SCRIPT_DIR/pt-pmp" -i 30 -d pteu >> "$OUT" 2>&1

        echo "" >> "$OUT"
        echo "Profiling completed at $(date)" >> "$OUT"
    ) &
    echo $! > /tmp/gdb.pid
}

start_thread_status() {
    local PREFIX=$1
    local OUT_THPOOL="${PREFIX}.stat-thpool.txt"
    local OUT_THR="${PREFIX}.stat-thr.txt"
    echo "Thread pool status -> ${OUT_THPOOL}"
    echo "Threads status -> ${OUT_THR}"

    (
        while :; do
            TS=$(date +%s.%3N)
            "$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW GLOBAL STATUS LIKE 'Threadpool%';" 2>/dev/null | awk -v ts="$TS" '{print ts"\t"$0}' >> "$OUT_THPOOL"
            sleep 1
        done
    ) &
    echo $! > /tmp/thread_status_thpool.pid

    (
        while :; do
            TS=$(date +%s.%3N)
            "$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW GLOBAL STATUS LIKE 'Threads%';" 2>/dev/null | awk -v ts="$TS" '{print ts"\t"$0}' >> "$OUT_THR"
            sleep 1
        done
    ) &
    echo $! > /tmp/thread_status_thr.pid
}

start_metrics() {
    local PREFIX=$1
    echo " --- START METRICS ---"

    iostat -dxm 1 > "${PREFIX}.iostat.txt" & echo $! > /tmp/iostat.pid
    vmstat 1 > "${PREFIX}.vmstat.txt" & echo $! > /tmp/vmstat.pid
    mpstat -P ALL 1 > "${PREFIX}.mpstat.txt" & echo $! > /tmp/mpstat.pid
    dstat -t 1 > "${PREFIX}.dstat.txt" & echo $! > /tmp/dstat.pid

    start_innodb_metrics "$PREFIX"
    start_lru_metrics "$PREFIX"
    start_mutex_metrics "$PREFIX"
    start_gdb_snapshots "$PREFIX"
    start_thread_status "$PREFIX"
}

stop_metrics() {
    # Stop all monitoring processes
    local pids_to_kill=""

    for pidfile in /tmp/iostat.pid /tmp/vmstat.pid /tmp/mpstat.pid /tmp/dstat.pid /tmp/innodb.pid /tmp/lru_metrics.pid /tmp/mutex_metrics.pid /tmp/gdb.pid /tmp/thread_status_thpool.pid /tmp/thread_status_thr.pid; do
        if [ -f "$pidfile" ]; then
            pids_to_kill="$pids_to_kill $(cat $pidfile)"
        fi
    done

    if [ -n "$pids_to_kill" ]; then
        kill $pids_to_kill 2>/dev/null
    fi

    # Give GDB snapshot a moment to finish if still running
    if [ -f /tmp/gdb.pid ]; then
        local gdb_pid=$(cat /tmp/gdb.pid)
        if kill -0 "$gdb_pid" 2>/dev/null; then
            echo "Waiting for GDB snapshots to complete..."
            sleep 2
        fi
    fi

    # Clean up PID files
    rm -f /tmp/iostat.pid /tmp/vmstat.pid /tmp/mpstat.pid /tmp/dstat.pid /tmp/innodb.pid /tmp/lru_metrics.pid /tmp/mutex_metrics.pid /tmp/gdb.pid /tmp/thread_status_thpool.pid /tmp/thread_status_thr.pid
}

trap 'stop_metrics; stop_server' EXIT
trap 'stop_metrics; stop_server; exit 1' INT TERM

init_data() {
  echo ">>> Create tables and insert data..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-port=$DB_PORT --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --mysql-db=$DB_DATABASE --tables=20 --table-size=$TABLE_ROWS --threads=64 prepare
}

# --- EXECUTION LOOP ---
for SIZE in "${POOL_SIZES[@]}"; do
  echo "========================================================="
  echo ">>> TIER: ${SIZE}GB | VER: $RAW_VERSION <<<"
  echo "========================================================="

  # 1. Create clean datadir for this tier
  TIER_DATADIR="${DATADIR_BASE}/${DBMS_NAME}_${RAW_VERSION}_tier${SIZE}G"
  if [ "$ENABLE_BINLOG" == "1" ]; then
      TIER_DATADIR="${TIER_DATADIR}_binlog"
  fi
  if [ "$ENABLE_THREAD_POOL" == "1" ]; then
      TIER_DATADIR="${TIER_DATADIR}_threadpool"
  fi

  initialize_datadir "$TIER_DATADIR"

  # 2. Generate config
  generate_config $SIZE "$TIER_DATADIR"

  echo "Starting server with the new config..."
  start_server "$TIER_DATADIR" "$CONFIG_PATH"
  server_wait

  # Set root password and grant TCP/IP access (use socket for initial connection after fresh init)
  "$MYSQLADMIN" --socket=/tmp/mysql_benchmark.sock -u"$DB_USER" password "$DB_PASS" 2>/dev/null

  # Grant access from 127.0.0.1
  "$MYSQL_CLIENT" --socket=/tmp/mysql_benchmark.sock -u"$DB_USER" -p"$DB_PASS" -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$DB_PASS'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null

  # Create database
  "$MYSQL_CLIENT" -h "$DB_HOST" --port=$DB_PORT -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS ${DB_DATABASE};" 2>/dev/null

  echo "Server started with custom config."
  check_innodb_buffer $SIZE
  enable_innodb_metrics
  check_vars_status "${LOG_DIR}/Tier${SIZE}G"
  init_data
  run_mysql_summary "${LOG_DIR}/Tier${SIZE}G"

  # 2. WARMUP
  if [ "$IS_READ_ONLY" == "1" ]; then
    echo ">>> Warmup: Read-Only (${WARMUP_TIME}s)..."
    sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-port=$DB_PORT --mysql-user=$DB_USER --mysql-password=$DB_PASS \
      --mysql-db=$DB_DATABASE --tables=20 --table-size=$TABLE_ROWS --threads=16 --time=$WARMUP_TIME run
    TEST_TYPE="oltp_read_only"
  else
    echo ">>> Warmup: Dirty Writes (${WARMUP_TIME}s)..."
    sysbench oltp_read_write --mysql-host=$DB_HOST --mysql-port=$DB_PORT --mysql-user=$DB_USER --mysql-password=$DB_PASS \
        --mysql-db=$DB_DATABASE --tables=20 --table-size=$TABLE_ROWS --threads=64 --time=$WARMUP_TIME run
    TEST_TYPE="oltp_read_write"
  fi

  # 3. MEASUREMENT (NUM_RUNS runs per thread count for stability)
  RUN_END=$(( RUN_START + NUM_RUNS - 1 ))
  for THREAD in "${THREADS[@]}"; do
    for (( RUN=RUN_START; RUN<=RUN_END; RUN++ )); do
      FILE_PREFIX="${LOG_DIR}/run${RUN}_Tier${SIZE}G_RW_${THREAD}th"
      echo "   >>> Testing ${THREAD} Threads (run ${RUN} of ${RUN_START}..${RUN_END})..."

      start_metrics "$FILE_PREFIX"

      sysbench $TEST_TYPE \
        --mysql-host=$DB_HOST \
        --mysql-port=$DB_PORT \
        --mysql-user=$DB_USER \
        --mysql-password=$DB_PASS \
        --mysql-db=$DB_DATABASE \
        --tables=20 \
        --table-size=$TABLE_ROWS \
        --threads=$THREAD \
        --time=$DURATION \
        --report-interval=1 \
        --rand-type=uniform \
        --mysql-ssl=off \
        run > "${FILE_PREFIX}.sysbench.txt"

      stop_metrics
      sleep 10
    done
  done

  copy_server_logs $SIZE "$TIER_DATADIR"

  stop_server
done

echo "============= Finished benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="
