#!/usr/bin/env bash
#############################################################################
# DupeFinder Pro - Advanced Duplicate File Manager for Linux
# Version: 1.2.4 (Final)
# Author: Seth Morrow
# License: MIT
#
# Description:
#   Production-ready duplicate file finder with comprehensive safety checks,
#   robust error handling, and reliable operation for large-scale deployments.
#
#############################################################################

# Remove errexit for explicit error handling
set -o nounset
set -o pipefail

# ═══════════════════════════════════════════════════════════════════════════
# TERMINAL COLORS AND FORMATTING
# ═══════════════════════════════════════════════════════════════════════════
# Real escape bytes, not the two-character sequence "\033". show_help() feeds
# these to `cat`, which does not interpret backslash escapes, so the whole help
# screen used to come out littered with literal \033[1m markers.
# Colour is dropped when stdout is not a terminal, so piped output and cron
# logs stay readable. NO_COLOR is honoured (https://no-color.org).
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  WHITE=$'\033[1;37m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
  BOLD=$'\033[1m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''
  CYAN=''; WHITE=''; DIM=''; NC=''; BOLD=''
fi
readonly RED GREEN YELLOW BLUE MAGENTA CYAN WHITE DIM NC BOLD

# ═══════════════════════════════════════════════════════════════════════════
# INTERNAL DELIMITERS AND CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════
# Scan records are NUL-terminated with tab-separated fields. A tab in a
# filename is legal, so the path is always the final field and is taken as
# "everything after the last delimiter" rather than by splitting.
readonly TAB=$'\t'

# ═══════════════════════════════════════════════════════════════════════════
# DEFAULT CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════
SEARCH_PATH="$(pwd)"
EXCLUDE_PATHS=("/proc" "/sys" "/dev" "/run" "/tmp" "/var/run" "/var/lock" "/mnt" "/media")
MIN_SIZE=1
MAX_SIZE=""
OUTPUT_DIR="$HOME/duplicate_reports"
HTML_REPORT="duplicates_$(date +%Y%m%d_%H%M%S).html"
CSV_REPORT=""
JSON_REPORT=""
DELETE_MODE=0
DRY_RUN=0
VERBOSE=0
QUIET=0
FOLLOW_SYMLINKS=0
HIDDEN_FILES=0
MAX_DEPTH=""
FILE_PATTERN=()
HASH_ALGORITHM="md5sum"
INTERACTIVE_DELETE=0
KEEP_NEWEST=0
KEEP_OLDEST=0
KEEP_PATH_PRIORITY=""
BACKUP_DIR=""
USE_TRASH=0
HARDLINK_MODE=0
QUARANTINE_DIR=""
DB_CACHE="$HOME/.dupefinder_cache.db"
USE_CACHE=0
THREADS=0
EMAIL_REPORT=""
CONFIG_FILE=""
FUZZY_MATCH=0
SIMILARITY_THRESHOLD=95
EXCLUDE_LIST_FILE=""
FAST_MODE=0
SMART_DELETE=0
LOG_FILE=""
VERIFY_MODE=0
RESUME_STATE=0
LSOF_CHECKS=0  # Disabled by default - lsof is slow for large file sets
TEMP_DIR=""
readonly VERSION="1.4.0"
readonly AUTHOR="Seth Morrow"
readonly HASH_TIMEOUT=30   # Timeout for hashing a single file, in seconds
HASH_WIDTH=32              # Width of a hash field; set from the algorithm
ME="$(id -un 2>/dev/null || echo "$USER")"
IONICE_PREFIX=""
NICE_PREFIX=""
if command -v ionice >/dev/null 2>&1; then IONICE_PREFIX="ionice -c 3"; fi
if command -v nice >/dev/null 2>&1; then NICE_PREFIX="nice -n 19"; fi
MAIL_BIN=""
for b in mail mailx; do command -v "$b" >/dev/null && MAIL_BIN="$b" && break; done

# ═══════════════════════════════════════════════════════════════════════════
# CRITICAL SYSTEM PROTECTION CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════
readonly -a CRITICAL_EXTENSIONS=(
  ".so" ".dll" ".dylib" ".ko" ".sys" ".elf" ".a" ".lib" ".pdb" ".exe"
)

readonly -a CRITICAL_PATHS=(
  "/boot" "/lib" "/lib64" "/usr/lib" "/usr/lib64" "/usr/bin" "/bin"
  "/sbin" "/usr/sbin" "/etc" "/usr/share/dbus-1" "/usr/share/applications"
)

readonly -a SYSTEM_FOLDERS=(
  "/boot" "/bin" "/sbin" "/lib" "/lib32" "/lib64" "/libx32" "/usr"
  "/etc" "/root" "/snap" "/sys" "/proc" "/dev" "/run" "/srv"
)

readonly -a NEVER_DELETE_PATTERNS=(
  "vmlinuz*" "initrd*" "initramfs*" "grub*" "ld-linux*" "libc.so*"
  "libpthread*" "libdl*" "libm.so*" "busybox*" "systemd*" "bash"
  "sh" "python" "perl" "awk" "sed" "find" "grep" "xargs" "ln" "rm" "mv"
)

SKIP_SYSTEM_FOLDERS=0
FORCE_SYSTEM_DELETE=0
ASSUME_YES=0   # Confirm destructive actions up front (for cron/scripts)

# ═══════════════════════════════════════════════════════════════════════════
# STATISTICS COUNTERS
# ═══════════════════════════════════════════════════════════════════════════
TOTAL_FILES=0
TOTAL_DUPLICATES=0
TOTAL_DUPLICATE_GROUPS=0
TOTAL_SPACE_WASTED=0
FILES_DELETED=0
SPACE_FREED=0
FILES_HARDLINKED=0
FILES_QUARANTINED=0
SCAN_START_TIME=""
SCAN_END_TIME=""
FILES_PROCESSED=0
HASH_ERRORS=0
CANDIDATE_FILES=0      # Files sharing a size with another file, i.e. hashed
ABORT_PROCESSING=0     # Set when the user quits out of interactive mode

# ═══════════════════════════════════════════════════════════════════════════
# SMART LOCATION PRIORITIES
# ═══════════════════════════════════════════════════════════════════════════
declare -A LOCATION_PRIORITY=(
  ["/home"]=1 ["/usr/local"]=2 ["/opt"]=3 ["/var"]=4
  ["/tmp"]=99 ["/downloads"]=90 ["/cache"]=95
)

# ═══════════════════════════════════════════════════════════════════════════
# ERROR HANDLING AND LOGGING
# ═══════════════════════════════════════════════════════════════════════════
error_exit() {
  echo -e "${RED}Error: $1${NC}" >&2
  cleanup
  exit "${2:-1}"
}

log_action() {
  local level="$1"
  local message="$2"
  
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="$HOME/.dupefinder.log"
  fi
  
  local log_dir
  log_dir=$(dirname "$LOG_FILE")
  if [[ ! -w "$log_dir" && -w "/tmp" ]]; then
    echo -e "${YELLOW}Warning: Log directory '$log_dir' not writable. Using /tmp.${NC}" >&2
    LOG_FILE="/tmp/dupefinder_$$_${ME}.log"
  fi

  if [[ ! -f "$LOG_FILE" ]]; then
    mkdir -p "$log_dir" 2>/dev/null || return
    touch "$LOG_FILE" 2>/dev/null || return
  fi
  
  local msg
  printf -v msg "%q" "$message"
  echo "$(date +'%Y-%m-%d %H:%M:%S') [${level^^}] $msg" >> "$LOG_FILE"
}

get_available_mb() {
  if command -v free >/dev/null 2>&1; then
    free -m | awk '/^Mem:/ {print $7}'
  elif [[ -r /proc/meminfo ]]; then
    awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo
  else
    echo "0"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP AND SIGNAL HANDLING
# ═══════════════════════════════════════════════════════════════════════════
cleanup_done=0
cleanup() {
  if [[ $cleanup_done -eq 1 ]]; then
    return
  fi
  cleanup_done=1

  local -a pids=()
  mapfile -t pids < <(jobs -p 2>/dev/null)
  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
  fi
  wait 2>/dev/null || true

  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR" 2>/dev/null || true
  fi
  
  # The cache used to be VACUUMed on every exit, which rewrites the whole
  # database and can take longer than the scan it was meant to speed up.
  
  [[ -n "$LOG_FILE" ]] && log_action "info" "Session ended"
  
  if [[ -n "$SCAN_END_TIME" ]]; then
    rm -f -- "$HOME/.dupefinder_state" "$HOME/.dupefinder_state.dups" "$HOME/.dupefinder_state.cksum" 2>/dev/null || true
  fi
}

handle_interrupt() {
  echo -e "\n${YELLOW}Interrupted!${NC}" >&2
  if [[ $TOTAL_FILES -gt 0 && $FILES_PROCESSED -gt 0 && -t 0 ]]; then
    echo "Processed $FILES_PROCESSED/$TOTAL_FILES files before interruption."
    echo -n "Save state for resume? (y/n): "
    local response=""
    read -r response
    if [[ "$response" == "y" ]]; then
      if save_state; then
        echo -e "${GREEN}State saved. Re-run with --resume to continue.${NC}"
      else
        echo -e "${YELLOW}Nothing to save yet - the scan had not reached the analysis stage.${NC}"
      fi
    fi
  fi
  cleanup
  exit 130
}

trap handle_interrupt INT TERM
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# SECURE TEMPORARY DIRECTORY CREATION (FIXED for atomic mv)
# Uses /tmp for high IOPS and proper FIFO/socket support instead of OUTPUT_DIR
# ═══════════════════════════════════════════════════════════════════════════
create_temp_dir() {
  # Named pipes, SQLite and heavy random IO behave badly on network shares, so
  # temp files live on a local filesystem rather than next to the reports.
  local temp_base=""
  local attempt=0
  local candidate

  for candidate in "${TMPDIR:-}" "/tmp" "/var/tmp"; do
    if [[ -n "$candidate" && -d "$candidate" && -w "$candidate" ]]; then
      temp_base="$candidate"
      break
    fi
  done

  if [[ -z "$temp_base" ]]; then
    temp_base="$OUTPUT_DIR"
    [[ $VERBOSE -eq 1 ]] && echo -e "${YELLOW}Warning: Using OUTPUT_DIR for temp files (no /tmp available)${NC}"
  fi

  mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || error_exit "Cannot create or access output directory: $OUTPUT_DIR"

  local perms owner p_group p_other
  owner=$(stat -c "%U" -- "$OUTPUT_DIR" 2>/dev/null || echo "?")
  perms=$(stat -c "%a" -- "$OUTPUT_DIR" 2>/dev/null || echo "777")
  # stat prints four digits when setuid/setgid/sticky are set; only the low
  # three are the user/group/other bits we care about here.
  perms="${perms: -3}"
  p_group="${perms:1:1}"
  p_other="${perms:2:1}"
  if [[ "$owner" != "$ME" || ! -O "$OUTPUT_DIR" || "$p_group" =~ [2367] || "$p_other" =~ [2367] ]]; then
    error_exit "Output directory '$OUTPUT_DIR' is unsafe (must be owned by current user and not group/other-writable)"
  fi

  while [[ $attempt -lt 5 ]]; do
    ((attempt++))
    TEMP_DIR=$(mktemp -d -p "$temp_base" dupefinder.XXXXXXXXXX 2>/dev/null) || { sleep 1; continue; }
    if [[ -d "$TEMP_DIR" ]]; then
      chmod 700 -- "$TEMP_DIR" || { rm -rf -- "$TEMP_DIR"; error_exit "Failed to secure temporary directory"; }
      log_action "info" "Created secure temp directory: $TEMP_DIR"
      return 0
    fi
  done

  error_exit "Failed to create temporary directory after $attempt attempts"
}

# ═══════════════════════════════════════════════════════════════════════════
# USER INTERFACE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
show_header() {
  [[ -t 1 ]] && clear
  echo -e "${CYAN}"
  cat << "EOF"
 ____                   _____ _           _
|  _ \ _   _ _ __   ___|  ___(_)_ __   __| | ___ _ __
| | | | | | | '_ \ / _ \ |_  | | '_ \ / _` |/ _ \ '__|
| |_| | |_| | |_) |  __/  _| | | | | | (_| |  __/ |
|____/ \__,_| .__/ \___|_|   |_|_| |_|\__,_|\___|_|
            |_|
EOF
  echo -e "${NC}"
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}      Advanced Duplicate File Manager v${VERSION}${NC}"
  echo -e "${DIM}            by ${AUTHOR}${NC}"
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"
  echo ""
}

show_help() {
  show_header
  cat << EOF
${BOLD}USAGE:${NC}
    $0 [OPTIONS]

${BOLD}BASIC OPTIONS:${NC}
    ${GREEN}-p, --path PATH${NC}       Search path (default: current directory)
    ${GREEN}-o, --output DIR${NC}      Output directory for reports
    ${GREEN}-e, --exclude PATH${NC}    Exclude path (can be used multiple times)
    ${GREEN}-m, --min-size SIZE${NC}   Min size (e.g., 100, 10K, 5M, 1G)
    ${GREEN}-M, --max-size SIZE${NC}   Max size (e.g., 100, 10K, 5M, 1G)
    ${GREEN}-h, --help${NC}            Show this help
    ${GREEN}-V, --version${NC}         Show version
    ${GREEN}--config FILE${NC}         Load options from a config file

${BOLD}SAFETY OPTIONS:${NC}
    ${GREEN}--skip-system${NC}         Skip all system folders (/usr, /lib, /bin, etc.)
    ${GREEN}--force-system${NC}        Allow deletion of system files (DANGEROUS!)

    Files are re-checked immediately before anything is removed: if the copy
    being kept has changed or disappeared since the scan, the whole group is
    left alone. Duplicates that are already hardlinks of the kept file are
    never deleted. --delete, --hardlink and --quarantine cannot be combined.

${BOLD}SEARCH:${NC}
    ${GREEN}-f, --follow-symlinks${NC} Follow symbolic links (recursively)
    ${GREEN}-z, --empty${NC}           Include empty files
    ${GREEN}-a, --all${NC}             Include hidden files
    ${GREEN}-l, --level DEPTH${NC}     Max directory depth
    ${GREEN}-t, --pattern GLOB${NC}    File pattern (e.g., "*.jpg")
    ${GREEN}--fast${NC}                Fast mode (size + first 64KB hash)
    ${GREEN}--verify${NC}              Byte-by-byte verification before deletion
    ${GREEN}--fuzzy${NC}               Fuzzy matching for similar files (requires ssdeep)
    ${GREEN}--threshold PCT${NC}       Similarity threshold for fuzzy matching (default: 95)

${BOLD}DELETION:${NC}
    ${GREEN}-d, --delete${NC}          Delete duplicates
    ${GREEN}-i, --interactive${NC}     Enhanced interactive mode with file preview
    ${GREEN}-n, --dry-run${NC}         Show actions without executing
    ${GREEN}-y, --yes${NC}             Confirm destructive actions without prompting
                                  (required for cron / non-interactive runs)
    ${GREEN}--trash${NC}               Use trash (trash-cli) if available
    ${GREEN}--hardlink${NC}            Replace duplicates with hardlinks.
                                  (Works only within the same filesystem; replaces duplicates
                                  in-place with a hardlink to the kept file's inode).
    ${GREEN}--quarantine DIR${NC}      Move duplicates to quarantine directory

${BOLD}KEEP STRATEGIES:${NC}
    ${GREEN}-k, --keep-newest${NC}     Keep newest file from each group
    ${GREEN}-K, --keep-oldest${NC}     Keep oldest file from each group
    ${GREEN}--keep-path PATH${NC}      Prefer files in PATH
    ${GREEN}--smart-delete${NC}        Use location-based priorities

${BOLD}PERFORMANCE:${NC}
    ${GREEN}--threads N${NC}           Number of threads for hashing (default: nproc)

    Only files that share a size with another file are hashed, since files of
    different sizes cannot be duplicates. On most trees that is a small
    fraction of the total, and the summary reports both counts.

${BOLD}REPORTING:${NC}
    ${GREEN}-c, --csv FILE${NC}        Generate CSV report
    ${GREEN}--json FILE${NC}           Generate JSON report
    ${GREEN}--log FILE${NC}            Log operations to FILE
    ${GREEN}-v, --verbose${NC}         Enable verbose output
    ${GREEN}-q, --quiet${NC}           Quiet mode (minimal output)
    ${GREEN}--email EMAIL${NC}         Email HTML report on completion (requires 'mail' command)

${BOLD}ADVANCED:${NC}
    ${GREEN}-s, --sha256${NC}          Use SHA256 hashing
    ${GREEN}--sha512${NC}              Use SHA512 hashing
    ${GREEN}--backup DIR${NC}          Backup files before deletion
    ${GREEN}--exclude-list FILE${NC}   File with paths to exclude
    ${GREEN}--resume${NC}              Resume from a previous interrupted scan
    ${GREEN}--cache${NC}               Use a file-based cache for faster re-scans
    ${GREEN}--enable-lsof${NC}         Enable lsof checks for open files (slow on large sets)

${BOLD}EXAMPLES:${NC}
    # Safe system-wide scan
    $0 --path / --skip-system --delete --dry-run
    
    # Interactive cleanup with enhanced UI
    $0 --path ~/Downloads --min-size 1M --interactive --verbose
    
    # Find duplicate photos and auto-select based on path priority
    $0 --path ~/Pictures --pattern "*.jpg" --pattern "*.png" --smart-delete --delete -v

    # Unattended cleanup from cron (--yes replaces the interactive prompt)
    $0 --path /data --min-size 10M --keep-newest --delete --yes --quiet

${BOLD}REQUIREMENTS:${NC}
    bash 4+, GNU coreutils (sort/uniq/cut with -z), GNU findutils.
    Optional: sqlite3 (--cache), trash-cli (--trash), ssdeep (--fuzzy),
    jq (nothing requires it), mail/mailx (--email).

${BOLD}NOTES:${NC}
    Reports are written even when nothing is deleted and even when no
    duplicates are found. Exclusions that contain the search path are ignored
    with a warning - the defaults exclude /tmp, /mnt and /media, so scanning
    an external drive still works.

EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
# Accepts 100, 10K, 5M, 1G... Prints the byte count, or fails so the caller can
# report the bad value. (It used to echo unparsable input straight through,
# which then blew up in arithmetic far away from the actual mistake.)
parse_size() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)([KkMmGgTtPp]?)[Bb]?$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]}"
    case "${u^^}" in
      K) echo $((n*1024));;
      M) echo $((n*1024*1024));;
      G) echo $((n*1024*1024*1024));;
      T) echo $((n*1024*1024*1024*1024));;
      P) echo $((n*1024*1024*1024*1024*1024));;
      *) echo "$n";;
    esac
    return 0
  fi
  return 1
}

# Pure bash arithmetic. The previous version forked bc twice per unit step, and
# it is called once per file per report.
format_size() {
  local size=${1:-0}
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  local units=(B KB MB GB TB PB)
  local u=0 frac=0
  while (( size >= 1024 && u < 5 )); do
    frac=$(( (size % 1024) * 100 / 1024 ))
    size=$(( size / 1024 ))
    ((u++))
  done
  if (( u == 0 )); then
    printf '%d %s' "$size" "${units[u]}"
  else
    printf '%d.%02d %s' "$size" "$frac" "${units[u]}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# SCAN RECORD PARSING
#
# Every scan record is NUL-terminated and laid out as
#     hash <TAB> size <TAB> mtime <TAB> path
# The path is last and is taken as "everything after the third tab", so paths
# containing tabs, newlines, '|' or '%' survive the round trip intact. Parsing
# uses parameter expansion only, so it costs no forks.
# ═══════════════════════════════════════════════════════════════════════════
REC_HASH=""; REC_SIZE=""; REC_MTIME=""; REC_PATH=""
parse_record() {
  local r="$1" rest
  [[ "$r" == *"$TAB"*"$TAB"*"$TAB"* ]] || return 1
  REC_HASH="${r%%"$TAB"*}";     rest="${r#*"$TAB"}"
  REC_SIZE="${rest%%"$TAB"*}";  rest="${rest#*"$TAB"}"
  REC_MTIME="${rest%%"$TAB"*}"; REC_PATH="${rest#*"$TAB"}"
  [[ -n "$REC_PATH" && "$REC_SIZE" =~ ^[0-9]+$ && "$REC_MTIME" =~ ^-?[0-9]+$ ]] || return 1
  return 0
}

# Members of a group in flight: size <TAB> mtime <TAB> path
MEM_SIZE=""; MEM_MTIME=""; MEM_PATH=""
parse_member() {
  local m="$1" rest
  MEM_SIZE="${m%%"$TAB"*}";     rest="${m#*"$TAB"}"
  MEM_MTIME="${rest%%"$TAB"*}"; MEM_PATH="${rest#*"$TAB"}"
}

# Escaping helpers that do not fork a sed/jq per file. Result lands in REPLY.
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  s="${s//\"/&quot;}"; s="${s//\'/&#39;}"
  REPLY="$s"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Remaining control bytes are rare enough to be worth a slow path.
  if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
    local out="" i c
    for (( i=0; i<${#s}; i++ )); do
      c="${s:i:1}"
      if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then
        printf -v c '\\u%04x' "'$c"
      fi
      out+="$c"
    done
    s="$out"
  fi
  REPLY="\"$s\""
}

# ═══════════════════════════════════════════════════════════════════════════
# SAFE FILE OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════

safe_stat() {
  local file="$1"
  local format="$2"
  
  if [[ ! -e "$file" ]]; then
    echo "0"
    return 1
  fi
  
  stat -c "$format" -- "$file" 2>/dev/null || echo "0"
}

verify_identical() {
  local file1="$1"
  local file2="$2"
  
  [[ ! -f "$file1" || ! -f "$file2" ]] && return 1
  
  local size1 size2
  size1=$(safe_stat "$file1" "%s")
  size2=$(safe_stat "$file2" "%s")
  
  [[ "$size1" != "$size2" ]] && return 1
  
  if command -v cmp >/dev/null 2>&1; then
    cmp -s -- "$file1" "$file2" 2>/dev/null
    return $?
  else
    diff -q -- "$file1" "$file2" >/dev/null 2>&1
    return $?
  fi
}

fuzzy_match() {
  local file1="$1"
  local file2="$2"
  local threshold="$3"
  
  if ! command -v ssdeep >/dev/null 2>&1; then
    log_action "warning" "Fuzzy matching requires ssdeep"
    return 1
  fi
  
  local output
  output=$(ssdeep -l -p -s "$file1" "$file2" 2>/dev/null)
  local similarity
  similarity=$(echo "$output" | grep -o '[0-9]\+%' | tr -d '%')
  [[ -z "$similarity" ]] && return 1
  
  if [[ "$similarity" -ge "$threshold" ]]; then
    return 0
  fi
  
  return 1
}

backup_file() {
  local file="$1"
  
  [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]] && {
    log_action "warning" "Backup directory not available"
    return 1
  }
  
  [[ ! -f "$file" ]] && {
    log_action "error" "File to backup does not exist: $file"
    return 1
  }
  
  local backup_name backup_path
  backup_name="$(basename -- "$file")_$(date +%Y%m%d_%H%M%S)_$(echo "$file" | sha256sum | cut -c1-8)"
  backup_path="$BACKUP_DIR/$backup_name"
  
  if cp --preserve=all -- "$file" "$backup_path" 2>/dev/null; then
    [[ $VERBOSE -eq 1 ]] && echo -e "${GREEN}  + Backed up: $file -> $backup_path${NC}"
    log_action "info" "Backed up: $file -> $backup_path"
    return 0
  else
    log_action "error" "Failed to backup: $file"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# CRITICAL SAFETY VERIFICATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
is_critical_system_file() {
  local file="$1"
  local basename_file ext path pattern
  basename_file=$(basename -- "$file")

  # NOTE: these loop variables must stay local. bash scoping is dynamic, so an
  # undeclared `for path in ...` here reassigns the caller's $path, and the
  # deletion code then operated on a CRITICAL_PATHS entry rather than on the
  # duplicate it had just checked.
  for ext in "${CRITICAL_EXTENSIONS[@]}"; do
    [[ "$file" == *"$ext" ]] && return 0
  done
  
  for path in "${CRITICAL_PATHS[@]}"; do
    [[ "$file" == "$path"/* ]] && return 0
  done
  
  for pattern in "${NEVER_DELETE_PATTERNS[@]}"; do
    # shellcheck disable=SC2053  # unquoted on purpose: these are globs
    if [[ "$basename_file" == $pattern ]]; then
      return 0
    fi
  done
  
  if [[ -x "$file" ]]; then
    case "$(dirname -- "$file")" in
      /bin|/sbin|/usr/bin|/usr/sbin|/usr/local/bin|/usr/local/sbin)
        return 0
        ;;
    esac
  fi
  
  return 1
}

verify_safe_to_delete() {
  local file="$1"
  local confirmation response

  local real_file
  real_file=$(realpath -e "$file") || return 1
  
  if is_critical_system_file "$real_file"; then
    if [[ $FORCE_SYSTEM_DELETE -eq 1 ]]; then
      if [[ -t 0 ]]; then
        echo -e "${RED}WARNING: Critical system file detected: $real_file${NC}"
        echo -ne "${RED}Type 'YES DELETE' to proceed: ${NC}"
        read -r confirmation
        [[ "$confirmation" != "YES DELETE" ]] && return 1
      else
        log_action "error" "Refusing to prompt in non-interactive mode: $real_file"
        return 1
      fi
    else
      [[ $VERBOSE -eq 1 ]] && echo -e "${RED}  X Skipping critical system file: $real_file${NC}"
      log_action "info" "Skipping critical system file: $real_file"
      return 1
    fi
  fi
  
  if [[ $LSOF_CHECKS -eq 1 ]] && command -v lsof &>/dev/null; then
    if timeout 5 lsof -- "$file" >/dev/null 2>&1; then
      echo -e "${YELLOW}  ! File is currently in use: $file${NC}"
      if [[ $INTERACTIVE_DELETE -eq 1 ]]; then
        echo -ne "${YELLOW}  Force delete anyway? (y/N): ${NC}"
        read -r response
        [[ "$response" != "y" && "$response" != "Y" ]] && return 1
      else
        log_action "info" "Skipping file in use: $file"
        return 1
      fi
    fi
  fi
  
  if [[ "$file" == *.so* ]]; then
    if grep -qF -- "$(basename -- "$file")" /proc/*/maps 2>/dev/null; then
      echo -e "${RED}  X Shared library is currently loaded: $file${NC}"
      log_action "info" "Skipping loaded shared library: $file"
      return 1
    fi
  fi
  
  local owner
  owner=$(safe_stat "$file" "%U")
  if [[ "$owner" == "root" && "$ME" != "root" ]]; then
    echo -e "${YELLOW}  ! File is owned by root: $file${NC}"
    log_action "warning" "File is owned by root: $file"
    return 1
  fi
  
  return 0
}

is_in_system_folder() {
  local file="$1" sys_folder
  # Fast path: an absolute path with no "." or ".." component cannot be
  # relocated by resolution, so no realpath fork is needed. This is called
  # once per file for each report, where it used to dominate the runtime.
  if [[ "$file" == /* && "$file" != */./* && "$file" != */../* ]]; then
    for sys_folder in "${SYSTEM_FOLDERS[@]}"; do
      [[ "$file" == "$sys_folder"/* ]] && return 0
    done
    return 1
  fi
  local real
  real=$(realpath -e -- "$file" 2>/dev/null) || real="$file"
  for sys_folder in "${SYSTEM_FOLDERS[@]}"; do
    [[ "$real" == "$sys_folder"/* ]] && return 0
  done
  return 1
}

show_safety_summary() {
  local response
  # Quarantine moves files out from under the user, so it belongs behind the
  # same confirmation as delete and hardlink.
  if [[ $DELETE_MODE -eq 1 || $HARDLINK_MODE -eq 1 || -n "$QUARANTINE_DIR" ]]; then
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}      SAFETY CHECK SUMMARY${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}System Protection:${NC}      $([ $SKIP_SYSTEM_FOLDERS -eq 1 ] && echo "ENABLED" || echo "DISABLED")"
    echo -e "${CYAN}Force System Delete:${NC}       $([ $FORCE_SYSTEM_DELETE -eq 1 ] && echo -e "${RED}ENABLED${NC}" || echo "DISABLED")"
    echo -e "${CYAN}Running as:${NC}              $ME"
    echo -e "${CYAN}Action:${NC}                  $(
      if [[ $HARDLINK_MODE -eq 1 ]]; then echo "HARDLINK"
      elif [[ -n "$QUARANTINE_DIR" ]]; then echo "QUARANTINE -> $QUARANTINE_DIR"
      elif [[ $DELETE_MODE -eq 1 ]]; then echo "DELETE"
      else echo "REPORT ONLY"; fi)"
    echo -e "${CYAN}Interactive Mode:${NC}        $([ $INTERACTIVE_DELETE -eq 1 ] && echo "ENABLED" || echo "DISABLED")"
    echo -e "${CYAN}Dry Run:${NC}                 $([ $DRY_RUN -eq 1 ] && echo "YES" || echo "NO")"
    echo -e "${CYAN}Confirmed (--yes):${NC}       $([ $ASSUME_YES -eq 1 ] && echo "YES" || echo "NO")"
    echo -e "${YELLOW}─────────────────────────────────────────────────────────${NC}"
    if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 && $INTERACTIVE_DELETE -eq 0 ]]; then
      if [[ -t 0 ]]; then
        echo -ne "${YELLOW}Proceed with these settings? (y/N): ${NC}"
        read -r response
        if [[ "$response" != "y" && "$response" != "Y" ]]; then
          # Declining used to `exit 0` here, throwing away the scan that had
          # just run. Fall through to reporting instead.
          echo -e "${YELLOW}Skipping changes; reports will still be written.${NC}"
          DELETE_MODE=0; HARDLINK_MODE=0; QUARANTINE_DIR=""
        fi
      else
        # Without a terminal there is nobody to answer the prompt. Refuse
        # rather than guess, but let scripts and cron opt in with --yes.
        echo -e "${YELLOW}No terminal to confirm on; skipping changes. Pass --yes to confirm destructive actions non-interactively.${NC}"
        log_action "warning" "Non-interactive run without --yes; destructive actions skipped"
        DELETE_MODE=0; HARDLINK_MODE=0; QUARANTINE_DIR=""
      fi
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION AND STATE MANAGEMENT (Hardened)
# ═══════════════════════════════════════════════════════════════════════════
safe_source() {
  local filename="$1"
  local line var_name
  [[ ! -f "$filename" ]] && return 1
  
  # Scalars only. EXCLUDE_PATHS and FILE_PATTERN are arrays: a `printf -v`
  # into them would overwrite element 0 and quietly drop the rest, so they are
  # configured through --exclude / --exclude-list / --pattern instead.
  local -a allowed_vars=("SEARCH_PATH" "OUTPUT_DIR" "HASH_ALGORITHM" "SCAN_START_TIME" "STATE_DUPS_FILE" "FILES_PROCESSED" "MIN_SIZE" "MAX_SIZE" "DELETE_MODE" "DRY_RUN" "VERBOSE" "QUIET" "FOLLOW_SYMLINKS" "HIDDEN_FILES" "MAX_DEPTH" "INTERACTIVE_DELETE" "KEEP_NEWEST" "KEEP_OLDEST" "KEEP_PATH_PRIORITY" "BACKUP_DIR" "USE_TRASH" "HARDLINK_MODE" "QUARANTINE_DIR" "USE_CACHE" "THREADS" "EMAIL_REPORT" "FUZZY_MATCH" "SIMILARITY_THRESHOLD" "EXCLUDE_LIST_FILE" "FAST_MODE" "SMART_DELETE" "LOG_FILE" "VERIFY_MODE" "RESUME_STATE" "LSOF_CHECKS" "DB_CACHE")

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Only strip comments if # is at start or preceded by whitespace
    # This preserves paths like /mnt/drive#1
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      # Line starts with optional whitespace then #, skip it
      continue
    fi
    # Strip inline comments only if # is preceded by whitespace
    if [[ "$line" =~ ^(.*)([[:space:]]#.*)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi
    # Trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    
    if [[ "$line" =~ ^([[:alnum:]_]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"

      # Check for unsafe shell characters in value (backticks, $, (), ;)
      local unsafe_pattern='[`$();]'
      if [[ "$val" =~ $unsafe_pattern ]]; then
          log_action "error" "Unsafe value rejected for $key in $1"
          continue
      fi

      [[ "$val" == \"*\" ]] && val="${val%\"}" && val="${val#\"}"

      local is_allowed=0
      for var_name in "${allowed_vars[@]}"; do
        if [[ "$key" == "$var_name" ]]; then
          is_allowed=1
          break
        fi
      done
      if [[ $is_allowed -eq 1 ]]; then
        printf -v "$key" "%s" "$val"
      fi
    fi
  done < "$filename"
}

parse_arguments() {
  local default_config="$HOME/.dupefinder.conf"
  if [[ -f "$default_config" ]]; then
    safe_source "$default_config"
  fi

  while [[ $# -gt 0 ]]; do
    local arg="$1"
    case "$arg" in
      -p|--path)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a path"
        SEARCH_PATH="$2"; shift 2 ;;
      -o|--output)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a directory path"
        OUTPUT_DIR="$2"; shift 2 ;;
      -e|--exclude)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a path"
        EXCLUDE_PATHS+=("$2"); shift 2 ;;
      -m|--min-size)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a size value"
        MIN_SIZE=$(parse_size "$2") || error_exit "Invalid size for $arg: '$2' (try 100, 10K, 5M, 1G)"
        shift 2 ;;
      -M|--max-size)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a size value"
        MAX_SIZE=$(parse_size "$2") || error_exit "Invalid size for $arg: '$2' (try 100, 10K, 5M, 1G)"
        shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      -V|--version) echo "DupeFinder Pro v$VERSION by $AUTHOR"; exit 0 ;;
      --skip-system) SKIP_SYSTEM_FOLDERS=1; shift ;;
      --force-system) FORCE_SYSTEM_DELETE=1; shift ;;
      -f|--follow-symlinks) FOLLOW_SYMLINKS=1; shift ;;
      -z|--empty) MIN_SIZE=0; shift ;;
      -a|--all) HIDDEN_FILES=1; shift ;;
      -l|--level)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a depth value"
        MAX_DEPTH="$2"; shift 2 ;;
      -t|--pattern)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a glob pattern"
        FILE_PATTERN+=("$2"); shift 2 ;;
      --fast) FAST_MODE=1; shift ;;
      --verify) VERIFY_MODE=1; shift ;;
      --fuzzy) FUZZY_MATCH=1; shift ;;
      --threshold)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a percentage value"
        SIMILARITY_THRESHOLD="$2"; shift 2 ;;
      -d|--delete) DELETE_MODE=1; shift ;;
      -i|--interactive) INTERACTIVE_DELETE=1; DELETE_MODE=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -y|--yes|--assume-yes) ASSUME_YES=1; shift ;;
      --trash) USE_TRASH=1; shift ;;
      --hardlink) HARDLINK_MODE=1; shift ;;
      --quarantine)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a directory path"
        QUARANTINE_DIR="$2"; shift 2 ;;
      -k|--keep-newest) KEEP_NEWEST=1; shift ;;
      -K|--keep-oldest) KEEP_OLDEST=1; shift ;;
      --keep-path)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a path"
        KEEP_PATH_PRIORITY="$2"; shift 2 ;;
      --smart-delete) SMART_DELETE=1; shift ;;
      --threads)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a number"
        THREADS="$2"; shift 2 ;;
      -c|--csv)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a filename"
        CSV_REPORT="$2"; shift 2 ;;
      --json)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a filename"
        JSON_REPORT="$2"; shift 2 ;;
      --log)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a filename"
        LOG_FILE="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      --email)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires an email address"
        EMAIL_REPORT="$2"; shift 2 ;;
      -s|--sha256) HASH_ALGORITHM="sha256sum"; shift ;;
      --sha512) HASH_ALGORITHM="sha512sum"; shift ;;
      --backup)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a directory path"
        BACKUP_DIR="$2"; shift 2 ;;
      --exclude-list)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a filename"
        EXCLUDE_LIST_FILE="$2"; shift 2 ;;
      --resume) RESUME_STATE=1; shift ;;
      --cache) USE_CACHE=1; shift ;;
      --enable-lsof) LSOF_CHECKS=1; shift ;;  # Opt-in for slow lsof checks
      --config)
        [[ $# -lt 2 || "$2" == -* ]] && error_exit "$arg requires a filename"
        safe_source "$2" || error_exit "Cannot read config file: $2"
        CONFIG_FILE="$2"; shift 2 ;;
      *)
        echo -e "${RED}Unknown option: $arg${NC}"; show_help; exit 1 ;;
    esac
  done
}

save_state() {
  local state_file="$HOME/.dupefinder_state"
  local state_dups="$HOME/.dupefinder_state.dups"
  local state_checksum_file="$HOME/.dupefinder_state.cksum"
  
  [[ ! -f "$TEMP_DIR/duplicates.nul" ]] && {
    log_action "warning" "No duplicates file found to save state"
    return 1
  }
  
  cp -- "$TEMP_DIR/duplicates.nul" "$state_dups" 2>/dev/null || {
    log_action "error" "Failed to save duplicates file for resume"
    return 1
  }

  {
    echo "SEARCH_PATH=\"$SEARCH_PATH\""
    echo "OUTPUT_DIR=\"$OUTPUT_DIR\""
    echo "HASH_ALGORITHM=\"$HASH_ALGORITHM\""
    echo "SCAN_START_TIME=\"$SCAN_START_TIME\""
    echo "STATE_DUPS_FILE=\"$state_dups\""
    echo "FILES_PROCESSED=\"$FILES_PROCESSED\""
  } > "$state_file"
  
  sha256sum -- "$state_file" "$state_dups" > "$state_checksum_file" 2>/dev/null || {
    log_action "error" "Failed to create checksums for resume files"
    rm -f -- "$state_file" "$state_dups"
    return 1
  }
  
  chmod 600 "$state_file" "$state_dups" "$state_checksum_file"
  [[ $VERBOSE -eq 1 ]] && echo -e "${GREEN}State saved to ~/.dupefinder_state${NC}"
  log_action "info" "State saved for resume"
}

load_state() {
  local state_file="$HOME/.dupefinder_state"
  local state_checksum_file="$HOME/.dupefinder_state.cksum"
  
  [[ ! -f "$state_file" ]] && return 1
  
  local owner perm
  owner=$(safe_stat "$state_file" "%U")
  perm=$(safe_stat "$state_file" "%a")
  
  if [[ "$owner" != "$ME" || "$perm" != "600" ]]; then
    log_action "warning" "Unsafe resume file permissions/ownership"
    echo -e "${RED}Unsafe resume file permissions/ownership${NC}"
    return 1
  fi
  
  safe_source "$state_file"
  
  [[ -n "${STATE_DUPS_FILE:-}" && -f "$STATE_DUPS_FILE" ]] || return 1
  
  (cd "$(dirname "$state_file")" && sha256sum -c "$(basename "$state_checksum_file")") &>/dev/null || {
    log_action "error" "Resume file checksum mismatch"
    echo -e "${RED}Error: Resume file checksum mismatch${NC}"
    return 1
  }
  
  cp -- "$STATE_DUPS_FILE" "$TEMP_DIR/duplicates.nul"
  echo -e "${GREEN}Resuming previous scan...${NC}"
  log_action "info" "Resume state loaded successfully"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# INITIALIZATION AND VALIDATION
# ═══════════════════════════════════════════════════════════════════════════
init_logging() {
  if [[ -n "$LOG_FILE" ]]; then
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ ! -w "$log_dir" && -w "/tmp" ]]; then
      echo -e "${YELLOW}Warning: Log directory '$log_dir' not writable. Using /tmp.${NC}" >&2
      LOG_FILE="/tmp/dupefinder_$$_${ME}.log"
    fi
    
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="$HOME/.dupefinder.log"
    {
      echo "$(date): DupeFinder Pro v$VERSION started by $ME"
      echo "$(date): Search path: $SEARCH_PATH"
      echo "$(date): System protection: $([ $SKIP_SYSTEM_FOLDERS -eq 1 ] && echo "ENABLED" || echo "DISABLED")"
    } >> "$LOG_FILE" 2>/dev/null || true
  fi
}

init_cache() {
  [[ $USE_CACHE -ne 1 ]] && return
  mkdir -p -- "$(dirname -- "$DB_CACHE")" 2>/dev/null || true
  # The cache key includes the algorithm. The old schema keyed on path alone,
  # so a --cache run with --sha256 happily reused md5 hashes from an earlier
  # run and silently missed every duplicate.
  sqlite3 "$DB_CACHE" "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS file_hashes(
      path  TEXT NOT NULL,
      algo  TEXT NOT NULL,
      hash  TEXT NOT NULL,
      size  INTEGER NOT NULL,
      mtime INTEGER NOT NULL,
      PRIMARY KEY (path, algo)
    );
    DROP TABLE IF EXISTS files;" 2>/dev/null || {
      echo -e "${YELLOW}Warning: cache DB init failed; disabling cache.${NC}"; USE_CACHE=0; }
}

check_dependencies() {
  local cmd
  if ! command -v "$HASH_ALGORITHM" &>/dev/null; then
    error_exit "$HASH_ALGORITHM not found. Try: sudo apt install coreutils"
  fi

  for cmd in find stat sort uniq cut tr xargs; do
    if ! command -v "$cmd" &>/dev/null; then
      error_exit "$cmd command not found"
    fi
  done

  # The scan pipeline is NUL-safe end to end so filenames containing spaces,
  # tabs or newlines survive it. That relies on the GNU zero-terminated
  # options, so check for them here instead of producing wrong results later.
  # (This replaces the old hard requirement on gawk, which is not installed by
  # default on Debian/Ubuntu and made the script refuse to start there.)
  if ! printf 'a\0a\0' | uniq -z -D -w 1 >/dev/null 2>&1; then
    error_exit "GNU uniq with --zero-terminated is required (coreutils >= 8.23)."
  fi
  if ! printf 'a\tb\0' | cut -z -d"$TAB" -f2- >/dev/null 2>&1; then
    error_exit "GNU cut with --zero-terminated is required (coreutils >= 8.25)."
  fi
  if ! printf 'a\0' | sort -z >/dev/null 2>&1; then
    error_exit "GNU sort with --zero-terminated is required."
  fi
  if ! find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
    error_exit "GNU find with -printf is required (findutils)."
  fi

  command -v timeout >/dev/null 2>&1 || error_exit "'timeout' not found (usually in coreutils)."
  command -v md5sum >/dev/null 2>&1 || error_exit "'md5sum' not found (used by --fast)."

  if [[ $USE_TRASH -eq 1 ]] && ! command -v trash-put &>/dev/null; then
    echo -e "${YELLOW}Warning: trash-cli not installed. Falling back to rm.${NC}"
    USE_TRASH=0
  fi

  if [[ $FUZZY_MATCH -eq 1 ]] && ! command -v ssdeep &>/dev/null; then
    echo -e "${YELLOW}Warning: ssdeep not found. Fuzzy matching disabled.${NC}"
    FUZZY_MATCH=0
  fi

  if [[ -n "$EMAIL_REPORT" && -z "$MAIL_BIN" ]]; then
    echo -e "${YELLOW}Warning: 'mail' or 'mailx' not found. Email reports disabled.${NC}"
    EMAIL_REPORT=""
  fi

  if [[ $USE_CACHE -eq 1 ]] && ! command -v sqlite3 &>/dev/null; then
    echo -e "${YELLOW}Warning: sqlite3 not found. File cache disabled.${NC}"
    USE_CACHE=0
  fi
}

validate_inputs() {
  local line sys_folder ex
  [[ ! -d "$SEARCH_PATH" ]] && error_exit "Search path does not exist: $SEARCH_PATH"
  [[ ! -r "$SEARCH_PATH" ]] && error_exit "Search path is not readable: $SEARCH_PATH"

  mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || error_exit "Cannot create output directory: $OUTPUT_DIR"
  [[ ! -w "$OUTPUT_DIR" ]] && error_exit "Cannot write to output directory: $OUTPUT_DIR"

  [[ "$THREADS" =~ ^[0-9]+$ ]] || error_exit "--threads expects a non-negative integer, got: $THREADS"
  if [[ "$THREADS" -eq 0 ]]; then
    THREADS=$(nproc 2>/dev/null || echo 4)
    [[ "$THREADS" =~ ^[0-9]+$ ]] || THREADS=4
  fi
  [[ "$THREADS" -lt 1 ]] && THREADS=1

  if [[ -n "$MAX_DEPTH" ]] && ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]]; then
    error_exit "--level expects a non-negative integer, got: $MAX_DEPTH"
  fi
  if ! [[ "$SIMILARITY_THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$SIMILARITY_THRESHOLD" -gt 100 ]]; then
    error_exit "--threshold expects a value between 0 and 100, got: $SIMILARITY_THRESHOLD"
  fi
  if [[ -n "$MAX_SIZE" && "$MAX_SIZE" -lt "$MIN_SIZE" ]]; then
    error_exit "--max-size ($MAX_SIZE) is smaller than --min-size ($MIN_SIZE)"
  fi

  [[ $KEEP_NEWEST -eq 1 && $KEEP_OLDEST -eq 1 ]] && \
    error_exit "Cannot use both --keep-newest and --keep-oldest"

  # Silently picking one of these used to depend on the order of a few ifs.
  local modes=0
  [[ $DELETE_MODE -eq 1 && $INTERACTIVE_DELETE -eq 0 ]] && modes=$((modes+1))
  [[ $HARDLINK_MODE -eq 1 ]] && modes=$((modes+1))
  [[ -n "$QUARANTINE_DIR" ]] && modes=$((modes+1))
  [[ $modes -gt 1 ]] && \
    error_exit "--delete, --hardlink and --quarantine are mutually exclusive; pick one"

  # Duplicate detection groups records by a fixed-width hash prefix, so the
  # width has to be known before the scan starts.
  if [[ $FAST_MODE -eq 1 ]]; then
    HASH_WIDTH=53   # 20-digit zero-padded size + '_' + 32-char md5 of the first 64K
  else
    case "$HASH_ALGORITHM" in
      md5sum)    HASH_WIDTH=32 ;;
      sha256sum) HASH_WIDTH=64 ;;
      sha512sum) HASH_WIDTH=128 ;;
      *)
        HASH_WIDTH=$(printf '' | "$HASH_ALGORITHM" 2>/dev/null | cut -d' ' -f1 | tr -d '\n' | wc -c)
        [[ "$HASH_WIDTH" =~ ^[0-9]+$ && "$HASH_WIDTH" -gt 0 ]] || \
          error_exit "Cannot determine hash width for $HASH_ALGORITHM"
        ;;
    esac
  fi

  if [[ -n "$QUARANTINE_DIR" ]]; then
    mkdir -p -- "$QUARANTINE_DIR" 2>/dev/null || error_exit "Cannot create quarantine directory"
    [[ ! -w "$QUARANTINE_DIR" ]] && error_exit "Quarantine directory not writable"
  fi

  if [[ -n "$BACKUP_DIR" ]]; then
    mkdir -p -- "$BACKUP_DIR" 2>/dev/null || error_exit "Cannot create backup directory"
    [[ ! -w "$BACKUP_DIR" ]] && error_exit "Backup directory not writable"
  fi

  if [[ -n "$EXCLUDE_LIST_FILE" ]]; then
    [[ -r "$EXCLUDE_LIST_FILE" ]] || error_exit "Exclude list not readable: $EXCLUDE_LIST_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && EXCLUDE_PATHS+=("$line")
    done < "$EXCLUDE_LIST_FILE"
  fi

  if [[ $SKIP_SYSTEM_FOLDERS -eq 1 ]]; then
    for sys_folder in "${SYSTEM_FOLDERS[@]}"; do
      if [[ -d "$sys_folder" ]]; then
        local already_excluded=0
        for ex in ${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}; do
          [[ "$ex" == "$sys_folder" ]] && already_excluded=1 && break
        done
        [[ $already_excluded -eq 0 ]] && EXCLUDE_PATHS+=("$sys_folder")
      fi
    done
    [[ $VERBOSE -eq 1 ]] && echo -e "${CYAN}Excluding system folders${NC}"
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# FILE DISCOVERY (IMPROVED)
# ═══════════════════════════════════════════════════════════════════════════
find_files() {
  [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Searching filesystem for files...${NC}"

  # Drop any exclusion that contains the search path. The defaults exclude
  # /tmp, /mnt and /media, so "--path /media/usb" used to find nothing at all
  # and say only "No files matched criteria."
  local abs_search ex exn
  local -a kept=()
  abs_search=$(realpath -m -- "$SEARCH_PATH" 2>/dev/null || printf '%s' "$SEARCH_PATH")
  for ex in ${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}; do
    exn="${ex%/}"
    if [[ -n "$exn" && ( "$abs_search" == "$exn" || "$abs_search" == "$exn"/* ) ]]; then
      [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Note: ignoring exclusion '$exn' - the search path is inside it${NC}"
      log_action "info" "Ignored exclusion containing the search path: $exn"
      continue
    fi
    kept+=("$ex")
  done
  EXCLUDE_PATHS=(${kept[@]+"${kept[@]}"})

  local -a args=()
  [[ $FOLLOW_SYMLINKS -eq 1 ]] && args+=(-L)
  args+=("$SEARCH_PATH")
  # -mindepth 1 stops the prune expression from matching the starting
  # directory itself: "--path ~/.cache" or "--path ." matched -name '.*',
  # pruned the whole tree and always reported zero files.
  args+=(-mindepth 1)
  [[ -n "$MAX_DEPTH" ]] && args+=(-maxdepth "$MAX_DEPTH")

  local -a prune=()
  local first=1
  if [[ $HIDDEN_FILES -eq 0 ]]; then
    prune+=( -name '.*' )
    first=0
  fi
  for ex in ${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}; do
    ex="${ex%/}"
    [[ -z "$ex" ]] && continue
    [[ $first -eq 0 ]] && prune+=( -o )
    first=0
    prune+=( -path "$ex" -o -path "$ex/*" )
  done
  [[ ${#prune[@]} -gt 0 ]] && args+=( '(' "${prune[@]}" ')' -prune -o )

  args+=(-type f)
  # -size +Nc is "strictly greater than N", so subtract one to keep files of
  # exactly MIN_SIZE; likewise -size -Nc is "strictly less than N".
  [[ $MIN_SIZE -gt 0 ]] && args+=(-size "+$((MIN_SIZE - 1))c")
  [[ -n "$MAX_SIZE" ]] && args+=(-size "-$((MAX_SIZE + 1))c")

  if [[ ${#FILE_PATTERN[@]} -gt 0 ]]; then
    args+=( '(' )
    local firstp=1 pat
    for pat in "${FILE_PATTERN[@]}"; do
      [[ $firstp -eq 0 ]] && args+=( -o )
      firstp=0
      args+=(-name "$pat")
    done
    args+=( ')' )
  fi

  # find reports the size itself, so the scan no longer forks a stat per file.
  # The size is padded to a fixed width so the pre-filter below can group on it
  # with `uniq -z -w`.
  args+=(-printf "%020s${TAB}%p\0")

  if ! find "${args[@]}" 2>/dev/null > "$TEMP_DIR/files.sizes"; then
    log_action "warning" "find reported errors; unreadable directories were skipped"
    [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Warning: Some directories could not be accessed${NC}"
  fi

  : > "$TEMP_DIR/files.list"
  TOTAL_FILES=$(tr -cd '\0' < "$TEMP_DIR/files.sizes" | wc -c)
  CANDIDATE_FILES=0

  if [[ $TOTAL_FILES -eq 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}No files matched criteria.${NC}"
    return 1
  fi

  # Two files can only be duplicates if they are the same size, so only files
  # whose size occurs more than once are worth hashing. On a real tree that
  # removes the large majority of the reads.
  sort -z -- "$TEMP_DIR/files.sizes" \
    | uniq -z -D -w 20 \
    | cut -z -d"$TAB" -f2- > "$TEMP_DIR/files.list"

  CANDIDATE_FILES=$(tr -cd '\0' < "$TEMP_DIR/files.list" | wc -c)
  [[ $QUIET -eq 0 ]] && \
    echo -e "${GREEN}Found $TOTAL_FILES files; $CANDIDATE_FILES share a size and will be hashed${NC}"

  [[ $CANDIDATE_FILES -eq 0 ]] && return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# HASH CALCULATION - Standalone worker for xargs parallel processing
# ═══════════════════════════════════════════════════════════════════════════

# SQL escape helper - must be exported for xargs worker
# SQL escape helper - must be exported for the xargs worker
_sql_escape() {
  printf '%s' "${1//\'/\'\'}"
}
export -f _sql_escape

# Hash worker driven by xargs -P. Each invocation handles a batch of files, so
# one bash (and, with --cache, one sqlite3) is started per batch instead of per
# file. Emits  hash <TAB> size <TAB> mtime <TAB> path <NUL>  per file.
_hash_worker() {
  local algo="${DUPEFINDER_ALGO:-md5sum}"
  local fast="${DUPEFINDER_FAST:-0}"
  local use_cache="${DUPEFINDER_USE_CACHE:-0}"
  local db_cache="${DUPEFINDER_DB_CACHE:-}"
  local timeout_s="${DUPEFINDER_TIMEOUT:-30}"
  local delim=$'\t'
  # Fast hashes cover only the first 64K, so they must never be confused with
  # a full hash from the same algorithm when reading or writing the cache.
  local cache_algo="$algo"
  [[ "$fast" == "1" ]] && cache_algo="fast64k-md5"

  local -a paths=() sizes=() mtimes=()
  local file stat_out mtime size i

  for file in "$@"; do
    [[ -f "$file" ]] || continue
    stat_out=$(stat -c "%Y %s" -- "$file" 2>/dev/null) || continue
    read -r mtime size <<< "$stat_out"
    paths+=("$file"); mtimes+=("$mtime"); sizes+=("$size")
  done
  [[ ${#paths[@]} -eq 0 ]] && return 0

  # One cache lookup for the whole batch. Results come back keyed by batch
  # index so paths never have to be parsed back out of sqlite's output.
  local -A cached=()
  if [[ "$use_cache" == "1" && -n "$db_cache" && -f "$db_cache" ]]; then
    local values="" idx hash_out
    for i in "${!paths[@]}"; do
      [[ -n "$values" ]] && values+=","
      values+="($i,'$(_sql_escape "${paths[$i]}")',${mtimes[$i]},${sizes[$i]})"
    done
    while IFS='|' read -r idx hash_out; do
      [[ -n "$idx" && -n "$hash_out" ]] && cached["$idx"]="$hash_out"
    done < <(sqlite3 "$db_cache" "
      PRAGMA busy_timeout=10000;
      WITH q(i,p,m,s) AS (VALUES $values)
      SELECT q.i, f.hash FROM q JOIN file_hashes f
        ON f.path=q.p AND f.algo='$cache_algo' AND f.mtime=q.m AND f.size=q.s;" 2>/dev/null)
  fi

  local -a out=() new_paths=() new_hashes=() new_sizes=() new_mtimes=()
  local hash_val partial
  for i in "${!paths[@]}"; do
    file="${paths[$i]}"; size="${sizes[$i]}"; mtime="${mtimes[$i]}"
    hash_val="${cached[$i]:-}"

    if [[ -z "$hash_val" ]]; then
      if [[ "$fast" == "1" ]]; then
        # Size plus the first 64K, zero-padded so every hash has one width.
        partial=$(head -c 65536 -- "$file" 2>/dev/null | md5sum 2>/dev/null)
        partial="${partial%% *}"
        [[ -z "$partial" ]] && continue
        printf -v hash_val '%020d_%s' "$size" "$partial"
      else
        # Feed the file on stdin: with the filename as an argument, coreutils
        # escapes names containing backslashes or newlines and prefixes the
        # line with '\', which would change the hash width.
        hash_val=$(timeout "$timeout_s" "$algo" < "$file" 2>/dev/null)
        hash_val="${hash_val%% *}"
        [[ -z "$hash_val" ]] && continue
      fi
      new_paths+=("$file"); new_hashes+=("$hash_val")
      new_sizes+=("$size"); new_mtimes+=("$mtime")
    fi

    out+=("${hash_val}${delim}${size}${delim}${mtime}${delim}${file}")
  done

  [[ ${#out[@]} -gt 0 ]] && printf '%s\0' "${out[@]}"

  # One transaction per batch. Without busy_timeout, concurrent workers simply
  # lost their writes to SQLITE_BUSY and the cache never filled up.
  if [[ "$use_cache" == "1" && -n "$db_cache" && ${#new_paths[@]} -gt 0 ]]; then
    {
      printf 'PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\n'
      for i in "${!new_paths[@]}"; do
        printf "INSERT OR REPLACE INTO file_hashes(path,algo,hash,size,mtime) VALUES ('%s','%s','%s',%s,%s);\n" \
          "$(_sql_escape "${new_paths[$i]}")" "$cache_algo" "${new_hashes[$i]}" "${new_sizes[$i]}" "${new_mtimes[$i]}"
      done
      printf 'COMMIT;\n'
    } | sqlite3 "$db_cache" >/dev/null 2>&1 || true
  fi
  return 0
}
export -f _hash_worker

calculate_hashes() {
  : > "$TEMP_DIR/hashes.txt"
  [[ ${CANDIDATE_FILES:-0} -eq 0 ]] && return 0

  local mode_text="standard"
  [[ $FAST_MODE -eq 1 ]] && mode_text="fast"
  [[ $QUIET -eq 0 ]] && \
    echo -e "${YELLOW}Hashing $CANDIDATE_FILES files ($mode_text mode, $THREADS threads)...${NC}"

  local available_mb
  available_mb=$(get_available_mb 2>/dev/null || echo 0)
  [[ "$available_mb" =~ ^[0-9]+$ ]] || available_mb=0
  if [[ "$available_mb" -gt 0 && "$available_mb" -lt 500 ]]; then
    THREADS=$(( THREADS > 1 ? THREADS / 2 : 1 ))
    [[ $VERBOSE -eq 1 ]] && \
      echo -e "${YELLOW}Reduced to $THREADS threads due to low memory (${available_mb}MB free).${NC}"
  fi

  local hashes_temp="$TEMP_DIR/hashes.temp"
  : > "$hashes_temp"

  export DUPEFINDER_ALGO="$HASH_ALGORITHM"
  export DUPEFINDER_FAST="$FAST_MODE"
  export DUPEFINDER_TIMEOUT="$HASH_TIMEOUT"
  export DUPEFINDER_USE_CACHE="$USE_CACHE"
  export DUPEFINDER_DB_CACHE="$DB_CACHE"

  [[ $VERBOSE -eq 1 && $QUIET -eq 0 && $USE_CACHE -eq 1 ]] && echo -e "${DIM}Cache: $DB_CACHE${NC}"

  # -n 32 hands each worker a batch; the old -n 1 started a fresh bash (and two
  # sqlite3 processes, with --cache) for every single file.
  # $NICE_PREFIX/$IONICE_PREFIX were computed at startup but never applied;
  # hashing is the disk-bound stage, so run the pool at idle priority.
  $NICE_PREFIX $IONICE_PREFIX \
    xargs -0 -P "$THREADS" -n 32 bash -c '_hash_worker "$@"' _ \
    < "$TEMP_DIR/files.list" > "$hashes_temp" 2>/dev/null &
  local xargs_pid=$!

  # A long scan used to look like a hang; show progress on a terminal.
  if [[ $QUIET -eq 0 && -t 1 ]]; then
    local done_n=0
    while kill -0 "$xargs_pid" 2>/dev/null; do
      sleep 1
      kill -0 "$xargs_pid" 2>/dev/null || break
      done_n=$(tr -cd '\0' < "$hashes_temp" 2>/dev/null | wc -c)
      printf '\r  %b%s/%s hashed%b   ' "$DIM" "$done_n" "$CANDIDATE_FILES" "$NC"
    done
    printf '\r%-50s\r' ""
  fi

  wait "$xargs_pid" || log_action "warning" "Some files could not be hashed"

  unset DUPEFINDER_ALGO DUPEFINDER_FAST DUPEFINDER_TIMEOUT DUPEFINDER_USE_CACHE DUPEFINDER_DB_CACHE

  mv -- "$hashes_temp" "$TEMP_DIR/hashes.txt"

  local hashed_count
  hashed_count=$(tr -cd '\0' < "$TEMP_DIR/hashes.txt" | wc -c)
  FILES_PROCESSED=$hashed_count
  HASH_ERRORS=$(( CANDIDATE_FILES - hashed_count ))
  (( HASH_ERRORS < 0 )) && HASH_ERRORS=0
  if [[ $HASH_ERRORS -gt 0 && $QUIET -eq 0 ]]; then
    echo -e "${YELLOW}Warning: $HASH_ERRORS files could not be hashed (unreadable, or removed mid-scan)${NC}"
  fi

  [[ $QUIET -eq 0 ]] && echo -e "${GREEN}Hash calculation completed${NC}"

  # Explicit: the function used to end on the "HASH_ERRORS > 0" test, so a run
  # in which everything hashed cleanly returned 1 and main() aborted with
  # "Hash calculation failed" every single time.
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# DUPLICATE DETECTION (IMPROVED AWK PROCESSING)
# ═══════════════════════════════════════════════════════════════════════════
find_duplicates() {
  [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Analyzing duplicates...${NC}"

  : > "$TEMP_DIR/duplicates.nul"
  TOTAL_DUPLICATES=0
  TOTAL_DUPLICATE_GROUPS=0
  TOTAL_SPACE_WASTED=0

  if [[ ! -s "$TEMP_DIR/hashes.txt" ]]; then
    [[ $QUIET -eq 0 ]] && echo -e "${GREEN}No duplicate groups found${NC}"
    return 1
  fi

  # Records begin with a fixed-width hash, so sorting whole records puts equal
  # hashes next to each other and `uniq -w` keeps only the runs longer than
  # one. This replaces the old gawk RS='\0' stage, which required gawk and
  # passed filenames to awk's printf as a format string - any name containing
  # a '%' came out corrupted.
  sort -z -- "$TEMP_DIR/hashes.txt" \
    | uniq -z -D -w "$HASH_WIDTH" > "$TEMP_DIR/duplicates.nul"

  compute_duplicate_stats

  if [[ ${TOTAL_DUPLICATE_GROUPS:-0} -eq 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo -e "${GREEN}No duplicate groups found${NC}"
    return 1
  fi

  [[ $QUIET -eq 0 ]] && \
    echo -e "${GREEN}Found ${TOTAL_DUPLICATE_GROUPS} groups with ${TOTAL_DUPLICATES} duplicate files${NC}"
  return 0
}

# Recompute the summary counters from duplicates.nul. Also used after --resume,
# which previously restored the duplicate list but reported zeroes everywhere.
compute_duplicate_stats() {
  TOTAL_DUPLICATES=0
  TOTAL_DUPLICATE_GROUPS=0
  TOTAL_SPACE_WASTED=0
  local prev_hash="" rec
  while IFS= read -r -d '' rec; do
    parse_record "$rec" || continue
    if [[ "$REC_HASH" != "$prev_hash" ]]; then
      prev_hash="$REC_HASH"
      TOTAL_DUPLICATE_GROUPS=$(( TOTAL_DUPLICATE_GROUPS + 1 ))
    else
      TOTAL_DUPLICATES=$(( TOTAL_DUPLICATES + 1 ))
      TOTAL_SPACE_WASTED=$(( TOTAL_SPACE_WASTED + REC_SIZE ))
    fi
  done < "$TEMP_DIR/duplicates.nul"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SMART DELETION STRATEGIES
# ═══════════════════════════════════════════════════════════════════════════
get_location_priority() {
  # Compared case-insensitively: the table holds "/downloads" and "/cache",
  # while real paths are "Downloads" and "Cache", so nothing ever matched.
  # Also takes the best (lowest) match rather than whichever key the
  # associative array happened to yield first.
  local path="${1,,}"
  local best=50 matched=0 loc pri
  for loc in "${!LOCATION_PRIORITY[@]}"; do
    if [[ "$path" == *"${loc,,}"* ]]; then
      pri=${LOCATION_PRIORITY[$loc]}
      if [[ $matched -eq 0 || $pri -lt $best ]]; then
        best=$pri
        matched=1
      fi
    fi
  done
  echo "$best"
}

# Index (into the member list passed as "$@") of the file --smart-delete keeps.
select_keep_index() {
  local -a members=("$@")
  local best_idx=0 best=1000 i pri
  for i in "${!members[@]}"; do
    parse_member "${members[$i]}"
    pri=$(get_location_priority "$MEM_PATH")
    if (( pri < best )); then
      best=$pri
      best_idx=$i
    fi
  done
  echo "$best_idx"
}

# ═══════════════════════════════════════════════════════════════════════════
# ENHANCED VERBOSE OUTPUT
# ═══════════════════════════════════════════════════════════════════════════
show_duplicate_details() {
  [[ $VERBOSE -eq 0 || $QUIET -eq 1 ]] && return 0
  if [[ ${TOTAL_DUPLICATE_GROUPS:-0} -eq 0 ]]; then
    echo -e "${YELLOW}No duplicate groups found to display.${NC}"
    return 0
  fi

  echo ""
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}      DUPLICATE GROUPS FOUND${NC}"
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"

  local gid=0 prev_hash="" rec tag
  while IFS= read -r -d '' rec; do
    parse_record "$rec" || continue
    if [[ "$REC_HASH" != "$prev_hash" ]]; then
      prev_hash="$REC_HASH"
      gid=$(( gid + 1 ))
      echo -e "${BOLD}${CYAN}Group $gid${NC} ${DIM}(${REC_HASH:0:16}...)${NC}"
    fi
    tag=""
    is_in_system_folder "$REC_PATH" && tag=" ${YELLOW}(system)${NC}"
    echo -e "  - $(format_size "$REC_SIZE")   ${REC_PATH}${tag}"
  done < "$TEMP_DIR/duplicates.nul"
  echo ""
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# FILE PROCESSING AND DELETION
# ═══════════════════════════════════════════════════════════════════════════
# Picks the member of a duplicate group to keep, then applies the requested
# action to the others. Members are "size <TAB> mtime <TAB> path" strings.
process_duplicate_group() {
  local -a members=("$@")
  [[ ${#members[@]} -lt 2 ]] && return 0

  local keep_idx=0 i

  if [[ $SMART_DELETE -eq 1 ]]; then
    keep_idx=$(select_keep_index "${members[@]}")
  elif [[ -n "$KEEP_PATH_PRIORITY" ]]; then
    for i in "${!members[@]}"; do
      parse_member "${members[$i]}"
      if [[ "$MEM_PATH" == "$KEEP_PATH_PRIORITY"* ]]; then keep_idx=$i; break; fi
    done
  elif [[ $KEEP_NEWEST -eq 1 ]]; then
    local newest=""
    for i in "${!members[@]}"; do
      parse_member "${members[$i]}"
      if [[ -z "$newest" || $MEM_MTIME -gt $newest ]]; then newest=$MEM_MTIME; keep_idx=$i; fi
    done
  elif [[ $KEEP_OLDEST -eq 1 ]]; then
    # Seeded from the first member instead of a fixed 9999999999, which any
    # file dated after 2286 would have beaten.
    local oldest=""
    for i in "${!members[@]}"; do
      parse_member "${members[$i]}"
      if [[ -z "$oldest" || $MEM_MTIME -lt $oldest ]]; then oldest=$MEM_MTIME; keep_idx=$i; fi
    done
  fi

  parse_member "${members[$keep_idx]}"
  local keep_file="$MEM_PATH" keep_size="$MEM_SIZE" keep_mtime="$MEM_MTIME"

  # Scanning and deleting are separated in time. Re-check the file we are about
  # to keep: if it vanished or changed, removing its "duplicates" would destroy
  # the last copy of the content.
  local keep_stat k_size k_mtime k_dev k_ino
  keep_stat=$(stat -c '%s %Y %d %i' -- "$keep_file" 2>/dev/null) || {
    echo -e "${YELLOW}  ! Group skipped - the file to keep is gone: $keep_file${NC}"
    log_action "warning" "Kept file vanished, group skipped: $keep_file"
    return 0
  }
  read -r k_size k_mtime k_dev k_ino <<< "$keep_stat"
  if [[ "$k_size" != "$keep_size" || "$k_mtime" != "$keep_mtime" ]]; then
    echo -e "${YELLOW}  ! Group skipped - the file to keep changed since the scan: $keep_file${NC}"
    log_action "warning" "Kept file changed since scan, group skipped: $keep_file"
    return 0
  fi

  [[ $VERBOSE -eq 1 ]] && echo -e "${GREEN}  + Keeping: $keep_file${NC}"

  for i in "${!members[@]}"; do
    [[ $i -eq $keep_idx ]] && continue
    parse_member "${members[$i]}"
    local path="$MEM_PATH" size="$MEM_SIZE" mtime="$MEM_MTIME"

    local dup_stat d_size d_mtime d_dev d_ino
    dup_stat=$(stat -c '%s %Y %d %i' -- "$path" 2>/dev/null) || {
      [[ $VERBOSE -eq 1 ]] && echo -e "${YELLOW}  ! Skipped (gone): $path${NC}"
      continue
    }
    read -r d_size d_mtime d_dev d_ino <<< "$dup_stat"
    if [[ "$d_size" != "$size" || "$d_mtime" != "$mtime" ]]; then
      echo -e "${YELLOW}  ! Skipped (changed since the scan): $path${NC}"
      log_action "warning" "Changed since scan, skipped: $path"
      continue
    fi
    # Two names for one inode are not wasted space: deleting one frees nothing
    # and `ln` would refuse to relink it anyway.
    if [[ "$d_dev" == "$k_dev" && "$d_ino" == "$k_ino" ]]; then
      [[ $VERBOSE -eq 1 ]] && echo -e "${DIM}  = Already a hardlink to the kept file: $path${NC}"
      continue
    fi

    if ! verify_safe_to_delete "$path"; then
      [[ $VERBOSE -eq 1 ]] && echo -e "${YELLOW}  ! Skipped (safety): $path${NC}"
      continue
    fi

    if [[ $SKIP_SYSTEM_FOLDERS -eq 1 ]] && is_in_system_folder "$path"; then
      [[ $VERBOSE -eq 1 ]] && echo -e "${YELLOW}  ! Skipped (system): $path${NC}"
      continue
    fi

    if [[ $VERIFY_MODE -eq 1 ]] && ! verify_identical "$keep_file" "$path"; then
      if [[ $FUZZY_MATCH -eq 1 ]] && fuzzy_match "$keep_file" "$path" "$SIMILARITY_THRESHOLD"; then
        [[ $VERBOSE -eq 1 ]] && echo -e "${YELLOW}  ~ Matched (fuzzy): $path${NC}"
      else
        echo -e "${RED}  ! Skipped (content differs): $path${NC}"
        log_action "warning" "Content differs, skipped: $path"
        continue
      fi
    fi

    local action="skip"
    if [[ $INTERACTIVE_DELETE -eq 1 ]]; then
      if [[ ! -t 0 ]]; then
        log_action "warning" "Interactive mode without a terminal; skipped $path"
        continue
      fi
      echo -e "${DIM}Keep:${NC} $keep_file"
      echo -e "${DIM}Dup :${NC} $path  ($(format_size "$size"))"
      echo -ne "${BOLD}[d]elete, [h]ardlink, [s]kip, [q]uit? [s]: ${NC}"
      local response=""
      read -r response
      case "${response,,}" in
        q*) ABORT_PROCESSING=1; return 0 ;;
        d*) action="delete" ;;
        h*) action="hardlink" ;;
        *)  action="skip" ;;
      esac
    elif [[ $HARDLINK_MODE -eq 1 ]]; then
      action="hardlink"
    elif [[ -n "$QUARANTINE_DIR" ]]; then
      action="quarantine"
    elif [[ $DELETE_MODE -eq 1 ]]; then
      action="delete"
    fi

    [[ "$action" == "skip" ]] && continue

    if [[ $DRY_RUN -eq 1 ]]; then
      case "$action" in
        hardlink)   echo -e "${YELLOW}  Would hardlink: $path -> $keep_file${NC}"
                    FILES_HARDLINKED=$(( FILES_HARDLINKED + 1 )) ;;
        quarantine) echo -e "${YELLOW}  Would quarantine: $path${NC}"
                    FILES_QUARANTINED=$(( FILES_QUARANTINED + 1 )) ;;
        delete)     echo -e "${YELLOW}  Would delete: $path${NC}"
                    FILES_DELETED=$(( FILES_DELETED + 1 )) ;;
      esac
      SPACE_FREED=$(( SPACE_FREED + size ))
      continue
    fi

    case "$action" in
      hardlink)
        local parent
        parent=$(dirname -- "$path")
        if [[ ! -w "$parent" ]]; then
          echo -e "${YELLOW}  ! Skipped (directory not writable): $path${NC}"
          log_action "warning" "Directory not writable: $parent"
          continue
        fi
        if [[ "$k_dev" != "$d_dev" ]]; then
          echo -e "${RED}  - Cannot hardlink across filesystems: $path${NC}"
          log_action "warning" "Cross-filesystem hardlink skipped: $path"
          continue
        fi
        # Link to a temporary name and rename over the duplicate. `ln -f`
        # unlinks the target first, so if the link then fails the file is gone.
        local tmplink="$parent/.dupefinder.$$.$RANDOM.tmp"
        if ln -- "$keep_file" "$tmplink" 2>/dev/null && mv -f -- "$tmplink" "$path" 2>/dev/null; then
          FILES_HARDLINKED=$(( FILES_HARDLINKED + 1 ))
          SPACE_FREED=$(( SPACE_FREED + size ))
          [[ $VERBOSE -eq 1 ]] && echo -e "${BLUE}  - Hardlinked: $path${NC}"
          log_action "info" "Hardlinked: $path -> $keep_file"
        else
          rm -f -- "$tmplink" 2>/dev/null
          echo -e "${RED}  - Failed to hardlink: $path${NC}"
          log_action "error" "Failed to hardlink: $path"
        fi
        ;;
      quarantine)
        local qfile
        qfile="$QUARANTINE_DIR/$(basename -- "$path").$$.$RANDOM"
        if mv -- "$path" "$qfile" 2>/dev/null; then
          FILES_QUARANTINED=$(( FILES_QUARANTINED + 1 ))
          SPACE_FREED=$(( SPACE_FREED + size ))
          [[ $VERBOSE -eq 1 ]] && echo -e "${YELLOW}  - Quarantined: $path${NC}"
          log_action "info" "Quarantined: $path -> $qfile"
        else
          echo -e "${RED}  - Failed to quarantine: $path${NC}"
          log_action "error" "Failed to quarantine: $path"
        fi
        ;;
      delete)
        # A failed backup used to be ignored and the file deleted anyway.
        if [[ -n "$BACKUP_DIR" ]] && ! backup_file "$path"; then
          echo -e "${RED}  - Backup failed, not deleting: $path${NC}"
          log_action "error" "Backup failed, delete skipped: $path"
          continue
        fi
        local removed=1
        if [[ $USE_TRASH -eq 1 ]] && command -v trash-put >/dev/null 2>&1; then
          trash-put -- "$path" 2>/dev/null || removed=0
        else
          rm -f -- "$path" 2>/dev/null || removed=0
        fi
        if [[ $removed -eq 1 ]]; then
          FILES_DELETED=$(( FILES_DELETED + 1 ))
          SPACE_FREED=$(( SPACE_FREED + size ))
          [[ $VERBOSE -eq 1 ]] && echo -e "${RED}  - Deleted: $path${NC}"
          log_action "info" "Deleted: $path"
        else
          # Silently ignored before, so the summary claimed files were removed
          # that were still on disk.
          echo -e "${RED}  - Failed to delete: $path${NC}"
          log_action "error" "Failed to delete: $path"
        fi
        ;;
    esac
  done
  return 0
}

delete_duplicates() {
  if [[ $DELETE_MODE -eq 0 && $HARDLINK_MODE -eq 0 && -z "$QUARANTINE_DIR" ]]; then
    return 0
  fi
  [[ -s "$TEMP_DIR/duplicates.nul" ]] || return 0

  [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Processing duplicate files...${NC}"

  local gid=0 prev_hash="" rec
  local -a group=()

  # The record stream is read on fd 3, not stdin. With `done < file`, every
  # group flushed from inside the loop inherited the duplicates file as stdin,
  # so the interactive prompt (and the --force-system confirmation) read its
  # answer out of that file instead of from the user. Keeping stdin free also
  # means the "is there a terminal?" check actually tests the terminal.
  # Group boundaries are simply a change of hash in the sorted record stream.
  while IFS= read -r -d '' rec <&3; do
    [[ $ABORT_PROCESSING -eq 1 ]] && break
    parse_record "$rec" || continue
    if [[ "$REC_HASH" != "$prev_hash" ]]; then
      if [[ ${#group[@]} -gt 1 ]]; then
        gid=$(( gid + 1 ))
        [[ $VERBOSE -eq 1 ]] && echo -e "${CYAN}Processing group $gid...${NC}"
        process_duplicate_group "${group[@]}"
      fi
      group=()
      prev_hash="$REC_HASH"
    fi
    group+=("${REC_SIZE}${TAB}${REC_MTIME}${TAB}${REC_PATH}")
  done 3< "$TEMP_DIR/duplicates.nul"

  if [[ $ABORT_PROCESSING -eq 0 && ${#group[@]} -gt 1 ]]; then
    gid=$(( gid + 1 ))
    [[ $VERBOSE -eq 1 ]] && echo -e "${CYAN}Processing group $gid...${NC}"
    process_duplicate_group "${group[@]}"
  fi

  # Quitting out of interactive mode used to `exit 0` from inside the loop, so
  # no report was ever written for the scan that had just finished.
  [[ $ABORT_PROCESSING -eq 1 && $QUIET -eq 0 ]] && \
    echo -e "${YELLOW}Stopped at your request. Reports still cover the whole scan.${NC}"

  if [[ $QUIET -eq 0 ]]; then
    echo -e "${GREEN}Processing completed:${NC}"
    echo -e "  ${GREEN}Files deleted: ${FILES_DELETED}${NC}"
    echo -e "  ${GREEN}Files hardlinked: ${FILES_HARDLINKED}${NC}"
    echo -e "  ${GREEN}Files quarantined: ${FILES_QUARANTINED}${NC}"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo -e "  ${GREEN}Space that would be freed: $(format_size "${SPACE_FREED}")${NC}"
    else
      echo -e "  ${GREEN}Space freed: $(format_size "${SPACE_FREED}")${NC}"
    fi
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# REPORT GENERATION
# ═══════════════════════════════════════════════════════════════════════════
generate_html_report() {
  [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Generating HTML report...${NC}"
  local report_file="$OUTPUT_DIR/$HTML_REPORT"

  cat > "$report_file" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DupeFinder Pro Report</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;background:#f1f3f5;margin:0;color:#212529}
.container{max-width:1200px;margin:40px auto;background:#fff;border-radius:12px;box-shadow:0 20px 60px rgba(0,0,0,0.1);overflow:hidden}
header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:24px 28px}
h1{margin:0;font-size:28px}
.subtitle{opacity:.9;margin-top:6px}
.safety-badge{background:#4caf50;color:#fff;padding:4px 8px;border-radius:4px;font-size:12px;margin-left:10px;vertical-align:middle}
.safety-warning{background:#ff9800}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;padding:20px;background:#f8f9fa}
.card{background:#fff;border:1px solid #eceff1;border-radius:8px;padding:16px;text-align:center}
.val{font-size:22px;color:#667eea;font-weight:700}
.label{color:#6c757d;text-transform:uppercase;font-size:12px;margin-top:4px}
.group{border-top:1px solid #f1f3f5}
.group .hdr{padding:12px 16px;font-weight:600;cursor:pointer;user-select:none}
.group .hdr:hover{background:#fafbfc}
.group .files{padding:6px 16px 16px 32px;display:none}
.group.show .files{display:block}
.file{padding:8px 0;border-bottom:1px solid #f6f7f8;font-family:monospace;font-size:12px;word-break:break-all}
.file:last-child{border-bottom:0}
.keep{color:#2e7d32}
.system-file{color:#d32f2f}
.meta{color:#6c757d}
.empty{padding:40px 20px;text-align:center;color:#6c757d}
.footer{padding:16px 20px;background:#fff;border-top:1px solid #eceff1;text-align:center;color:#6c757d;font-size:12px}
</style>
<script>
function toggle(id){var el=document.getElementById(id);if(el){el.classList.toggle('show');}}
function toggleAll(open){var g=document.getElementsByClassName('group');
for(var i=0;i<g.length;i++){if(open){g[i].classList.add('show');}else{g[i].classList.remove('show');}}}
</script>
</head>
<body>
<div class="container">
HTMLHEAD

  local badge
  if [[ $SKIP_SYSTEM_FOLDERS -eq 1 ]]; then
    badge='<span class="safety-badge">System Protected</span>'
  else
    badge='<span class="safety-badge safety-warning">Full Scan</span>'
  fi

  cat >> "$report_file" << EOF
<header>
  <h1>DupeFinder Pro Report $badge</h1>
  <div class="subtitle">by ${AUTHOR} | Generated: $(date '+%B %d, %Y %H:%M:%S')</div>
</header>
<div class="stats">
  <div class="card"><div class="val">${TOTAL_FILES:-0}</div><div class="label">Files Scanned</div></div>
  <div class="card"><div class="val">${TOTAL_DUPLICATES:-0}</div><div class="label">Redundant Copies</div></div>
  <div class="card"><div class="val">${TOTAL_DUPLICATE_GROUPS:-0}</div><div class="label">Duplicate Groups</div></div>
  <div class="card"><div class="val">$(format_size "${TOTAL_SPACE_WASTED:-0}")</div><div class="label">Recoverable Space</div></div>
</div>
<div>
EOF

  if [[ ${TOTAL_DUPLICATE_GROUPS:-0} -eq 0 ]]; then
    echo '<div class="empty">No duplicate files were found.</div>' >> "$report_file"
  else
    echo '<div style="padding:12px 16px"><a href="#" onclick="toggleAll(true);return false;">Expand all</a> &middot; <a href="#" onclick="toggleAll(false);return false;">Collapse all</a></div>' >> "$report_file"

    local gid=0 prev_hash="" opened=0 rec cls note
    {
      while IFS= read -r -d '' rec; do
        parse_record "$rec" || continue

        if [[ "$REC_HASH" != "$prev_hash" ]]; then
          [[ $opened -eq 1 ]] && printf '</div></div>\n'
          prev_hash="$REC_HASH"
          gid=$(( gid + 1 ))
          opened=1
          html_escape "$REC_HASH"
          printf '<div id="g%s" class="group">\n' "$gid"
          printf '<div class="hdr" onclick="toggle(%s%s%s)">Group %s <span class="meta">(%s, %s)</span></div>\n' \
            "'" "g$gid" "'" "$gid" "$(format_size "$REC_SIZE")" "${REPLY:0:16}..."
          printf '<div class="files">\n'
          note=' <span class="meta">[first copy]</span>'
        else
          note=''
        fi

        cls="file"
        is_in_system_folder "$REC_PATH" && cls="file system-file"
        html_escape "$REC_PATH"
        printf '<div class="%s">%s%s</div>\n' "$cls" "$REPLY" "$note"
      done < "$TEMP_DIR/duplicates.nul"
      [[ $opened -eq 1 ]] && printf '</div></div>\n'
    } >> "$report_file"
  fi

  cat >> "$report_file" << EOF
</div>
<div class="footer">
  DupeFinder Pro v${VERSION} | Hash: ${HASH_ALGORITHM%%sum}$([ $FAST_MODE -eq 1 ] && echo " (fast)") | System protection: $([ $SKIP_SYSTEM_FOLDERS -eq 1 ] && echo "enabled" || echo "disabled")
</div>
</div>
</body>
</html>
EOF

  [[ $QUIET -eq 0 ]] && echo -e "${GREEN}HTML report saved: $report_file${NC}"
  return 0
}

generate_csv_report() {
  [[ -z "$CSV_REPORT" ]] && return 0
  [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Generating CSV report...${NC}"

  local csv="$OUTPUT_DIR/$CSV_REPORT"
  {
    echo 'Group ID,Hash,File Path,Size (bytes),Size (human),Role,System File'

    local gid=0 prev_hash="" rec role is_system esc
    while IFS= read -r -d '' rec; do
      parse_record "$rec" || continue
      if [[ "$REC_HASH" != "$prev_hash" ]]; then
        prev_hash="$REC_HASH"
        gid=$(( gid + 1 ))
        role="original"
      else
        role="duplicate"
      fi
      is_system="No"
      is_in_system_folder "$REC_PATH" && is_system="Yes"
      # CSV quoting: double the double quotes. Embedded newlines are legal
      # inside a quoted field, so paths containing them stay intact.
      esc="${REC_PATH//\"/\"\"}"
      printf '%s,%s,"%s",%s,"%s",%s,%s\n' \
        "$gid" "$REC_HASH" "$esc" "$REC_SIZE" "$(format_size "$REC_SIZE")" "$role" "$is_system"
    done < "$TEMP_DIR/duplicates.nul"
  } > "$csv"

  [[ $QUIET -eq 0 ]] && echo -e "${GREEN}CSV report saved: $csv${NC}"
  return 0
}

generate_json_report() {
  [[ -z "$JSON_REPORT" ]] && return 0
  [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Generating JSON report...${NC}"

  local json="$OUTPUT_DIR/$JSON_REPORT"
  local esc_search esc_author
  json_escape "$SEARCH_PATH"; esc_search="$REPLY"
  json_escape "$AUTHOR";      esc_author="$REPLY"

  {
    cat << EOF
{
  "metadata": {
    "version": "$VERSION",
    "author": $esc_author,
    "generated": "$(date -Iseconds 2>/dev/null || date)",
    "search_path": $esc_search,
    "total_files": ${TOTAL_FILES:-0},
    "files_hashed": ${CANDIDATE_FILES:-0},
    "total_duplicates": ${TOTAL_DUPLICATES:-0},
    "total_groups": ${TOTAL_DUPLICATE_GROUPS:-0},
    "space_wasted": ${TOTAL_SPACE_WASTED:-0},
    "hash_algorithm": "${HASH_ALGORITHM%%sum}",
    "fast_mode": $([ $FAST_MODE -eq 1 ] && echo "true" || echo "false"),
    "system_protection": $([ $SKIP_SYSTEM_FOLDERS -eq 1 ] && echo "true" || echo "false")
  },
  "groups": [
EOF

    local gid=0 prev_hash="" rec is_system first_file=1 esc_hash
    while IFS= read -r -d '' rec; do
      parse_record "$rec" || continue

      if [[ "$REC_HASH" != "$prev_hash" ]]; then
        if [[ $gid -gt 0 ]]; then
          printf '\n      ]\n    },\n'
        fi
        prev_hash="$REC_HASH"
        gid=$(( gid + 1 ))
        first_file=1
        json_escape "$REC_HASH"; esc_hash="$REPLY"
        printf '    {\n      "id": %s,\n      "hash": %s,\n      "size": %s,\n      "files": [\n' \
          "$gid" "$esc_hash" "$REC_SIZE"
      fi

      is_system="false"
      is_in_system_folder "$REC_PATH" && is_system="true"
      json_escape "$REC_PATH"
      [[ $first_file -eq 0 ]] && printf ',\n'
      first_file=0
      printf '        {"path": %s, "size": %s, "mtime": %s, "system": %s}' \
        "$REPLY" "$REC_SIZE" "$REC_MTIME" "$is_system"
    done < "$TEMP_DIR/duplicates.nul"

    [[ $gid -gt 0 ]] && printf '\n      ]\n    }\n'
    printf '  ]\n}\n'
  } > "$json"

  [[ $QUIET -eq 0 ]] && echo -e "${GREEN}JSON report saved: $json${NC}"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY AND STATISTICS
# ═══════════════════════════════════════════════════════════════════════════
calculate_duration() {
  local duration=$((SCAN_END_TIME - SCAN_START_TIME))
  local hours=$((duration/3600))
  local minutes=$(((duration%3600)/60))
  local seconds=$((duration%60))
  if (( hours > 0 )); then 
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
  elif (( minutes > 0 )); then 
    printf "%dm %ds" "$minutes" "$seconds"
  else 
    printf "%ds" "$seconds"
  fi
}

send_email_report() {
  if [[ -n "$EMAIL_REPORT" && -f "$OUTPUT_DIR/$HTML_REPORT" ]]; then
    if [[ -n "$MAIL_BIN" ]]; then
      if "$MAIL_BIN" -a "Content-Type: text/html; charset=UTF-8" -s "DupeFinder Pro Report" "$EMAIL_REPORT" < "$OUTPUT_DIR/$HTML_REPORT" 2>/dev/null; then
        log_action "info" "Report emailed to $EMAIL_REPORT"
        [[ $QUIET -eq 0 ]] && echo -e "${GREEN}✓ Email report sent to $EMAIL_REPORT${NC}"
      else
        log_action "error" "Failed to email report to $EMAIL_REPORT"
        [[ $QUIET -eq 0 ]] && echo -e "${RED}✗ Failed to send email report.${NC}"
      fi
    else
      log_action "warning" "Email report failed: 'mail' or 'mailx' command not found"
      [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Warning: 'mail' command not found. Email reports disabled.${NC}"
    fi
  fi
}

show_summary() {
  [[ $QUIET -eq 1 ]] && return 0

  echo ""
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}      SCAN SUMMARY${NC}"
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}Search Path:${NC}         $SEARCH_PATH"
  echo -e "${CYAN}System Protection:${NC}   $([ $SKIP_SYSTEM_FOLDERS -eq 1 ] && echo "ENABLED" || echo "DISABLED")"
  echo -e "${CYAN}Files Scanned:${NC}       ${TOTAL_FILES:-0}"
  echo -e "${CYAN}Files Hashed:${NC}        ${CANDIDATE_FILES:-0} ${DIM}(files with a unique size cannot have duplicates)${NC}"
  echo -e "${CYAN}Duplicate Groups:${NC}    ${TOTAL_DUPLICATE_GROUPS:-0}"
  echo -e "${CYAN}Redundant Copies:${NC}    ${TOTAL_DUPLICATES:-0}"
  echo -e "${CYAN}Recoverable Space:${NC}   $(format_size "${TOTAL_SPACE_WASTED:-0}")"

  if [[ ${FILES_DELETED:-0} -gt 0 || ${FILES_HARDLINKED:-0} -gt 0 || ${FILES_QUARANTINED:-0} -gt 0 ]]; then
    echo -e "${WHITE}─────────────────────────────────────────────────────────${NC}"
    [[ $DRY_RUN -eq 1 ]] && echo -e "${YELLOW}(dry run - nothing was changed)${NC}"
    echo -e "${CYAN}Files Processed:${NC}     $(( ${FILES_DELETED:-0} + ${FILES_HARDLINKED:-0} + ${FILES_QUARANTINED:-0} ))"
    echo -e "${CYAN}Space Freed:${NC}         $(format_size "${SPACE_FREED:-0}")"
    [[ ${FILES_DELETED:-0} -gt 0 ]]     && echo -e "${DIM}  - Deleted: ${FILES_DELETED}${NC}"
    [[ ${FILES_HARDLINKED:-0} -gt 0 ]]  && echo -e "${DIM}  - Hardlinked: ${FILES_HARDLINKED}${NC}"
    [[ ${FILES_QUARANTINED:-0} -gt 0 ]] && echo -e "${DIM}  - Quarantined: ${FILES_QUARANTINED}${NC}"
  fi

  echo -e "${WHITE}─────────────────────────────────────────────────────────${NC}"
  [[ -n "$SCAN_START_TIME" && -n "$SCAN_END_TIME" ]] && \
    echo -e "${CYAN}Scan Duration:${NC}       $(calculate_duration)"
  echo -e "${CYAN}Hash Algorithm:${NC}      ${HASH_ALGORITHM%%sum}$([ $FAST_MODE -eq 1 ] && echo " (fast: size + first 64KB)")"
  echo -e "${CYAN}Threads Used:${NC}        $THREADS"
  [[ ${HASH_ERRORS:-0} -gt 0 ]] && echo -e "${YELLOW}Hash Errors:${NC}         $HASH_ERRORS"
  echo -e "${WHITE}─────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}HTML Report:${NC}         $OUTPUT_DIR/$HTML_REPORT"
  [[ -n "$CSV_REPORT" ]]  && echo -e "${CYAN}CSV Report:${NC}          ${OUTPUT_DIR}/$CSV_REPORT"
  [[ -n "$JSON_REPORT" ]] && echo -e "${CYAN}JSON Report:${NC}         ${OUTPUT_DIR}/$JSON_REPORT"
  [[ -n "$LOG_FILE" ]]    && echo -e "${CYAN}Log File:${NC}            ${LOG_FILE}"
  echo -e "${WHITE}═══════════════════════════════════════════════════════════${NC}"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════
main() {
  # Byte-wise collation so `sort` and the hash grouping agree everywhere.
  export LC_ALL=C

  parse_arguments "$@"
  check_dependencies

  if [[ $FAST_MODE -eq 1 && ( $DELETE_MODE -eq 1 || $HARDLINK_MODE -eq 1 || -n "$QUARANTINE_DIR" ) && $VERIFY_MODE -eq 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}Fast mode with deletion detected; enabling --verify for safety.${NC}"
    VERIFY_MODE=1
  fi

  if [[ $FAST_MODE -eq 1 && $VERIFY_MODE -eq 0 && $QUIET -eq 0 ]]; then
    echo -e "${YELLOW}Warning: Fast mode compares only the first 64KB and may report false positives.${NC}"
  fi

  create_temp_dir
  : > "$TEMP_DIR/duplicates.nul"

  SCAN_START_TIME=$(date +%s)
  init_logging

  [[ $QUIET -eq 0 ]] && show_header

  validate_inputs
  init_cache

  local scan_status=0
  if [[ $RESUME_STATE -eq 1 ]] && load_state; then
    compute_duplicate_stats
    [[ $QUIET -eq 0 ]] && \
      echo -e "${GREEN}Resumed: ${TOTAL_DUPLICATE_GROUPS} groups with ${TOTAL_DUPLICATES} duplicate files${NC}"
  else
    if find_files; then
      calculate_hashes || scan_status=1
      find_duplicates || true
    fi
  fi

  # Reports are written whatever the outcome. Previously the run exited early
  # when there were no duplicates, yet still printed a report path that did not
  # exist.
  show_duplicate_details
  show_safety_summary
  delete_duplicates
  generate_html_report
  generate_csv_report
  generate_json_report
  send_email_report

  SCAN_END_TIME=$(date +%s)
  show_summary

  if [[ $scan_status -ne 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo -e "\n${RED}Scan completed with errors.${NC}"
    return 1
  fi

  [[ $QUIET -eq 0 ]] && echo -e "\n${GREEN}Scan completed successfully!${NC}"
  [[ $QUIET -eq 0 ]] && echo -e "${DIM}DupeFinder Pro v$VERSION by $AUTHOR${NC}\n"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════
main "$@"
exit 0
