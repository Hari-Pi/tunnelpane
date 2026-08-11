#!/bin/zsh

emulate -LR zsh
setopt pipefail no_beep
zmodload zsh/datetime 2>/dev/null

BASE_URL="${TUNNELPANE_URL:-__TUNNELPANE_URL__}"
LOCAL_DIR="${PWD:A}"
ACTIVE_PANE=local
LOCAL_SELECTED=1
SERVER_SELECTED=1
LOCAL_OFFSET=1
SERVER_OFFSET=1
STATUS='Ready.'
INTERRUPTED=0
TRANSFER_WORKERS="${TUNNELPANE_TRANSFERS:-4}"
TRANSFER_PART_SIZE=8388608
[[ "$TRANSFER_WORKERS" != <-> || "$TRANSFER_WORKERS" -lt 1 ]] && TRANSFER_WORKERS=4
(( TRANSFER_WORKERS > 8 )) && TRANSFER_WORKERS=8
typeset -a LOCAL_PATHS LOCAL_NAMES LOCAL_TYPES LOCAL_SIZES
typeset -a SERVER_IDS SERVER_NAMES SERVER_SIZES SERVER_DATES SERVER_BYTES
typeset -a WORKER_PIDS

if ! exec 3</dev/tty; then
  printf 'TunnelPane needs an interactive terminal.\n' >&2
  exit 1
fi

if printf '' | base64 --decode >/dev/null 2>&1; then
  BASE64_DECODE='--decode'
else
  BASE64_DECODE='-D'
fi

TRAPINT() {
  INTERRUPTED=1
}

file_id() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

format_size() {
  local size="$1"
  if (( size < 1024 )); then
    REPLY="${size} B"
  elif (( size < 1048576 )); then
    REPLY="$(( size / 1024 )) KB"
  elif (( size < 1073741824 )); then
    REPLY="$(( size / 1048576 )) MB"
  else
    REPLY="$(( size / 1073741824 )) GB"
  fi
}

local_file_size() {
  local value
  if value=$(stat -f '%z' -- "$1" 2>/dev/null); then
    REPLY="$value"
  elif value=$(stat -c '%s' -- "$1" 2>/dev/null); then
    REPLY="$value"
  else
    REPLY=0
  fi
}

load_local() {
  local item name
  LOCAL_PATHS=()
  LOCAL_NAMES=()
  LOCAL_TYPES=()
  LOCAL_SIZES=()

  if [[ "$LOCAL_DIR" != / ]]; then
    LOCAL_PATHS+=("${LOCAL_DIR:h}")
    LOCAL_NAMES+=('..')
    LOCAL_TYPES+=('dir')
    LOCAL_SIZES+=('-')
  fi

  for item in "$LOCAL_DIR"/*(DN); do
    name="${item:t}"
    name="${name//$'\n'/ }"
    name="${name//$'\t'/ }"
    LOCAL_PATHS+=("$item")
    if [[ -d "$item" ]]; then
      LOCAL_NAMES+=("$name/")
      LOCAL_TYPES+=('dir')
      LOCAL_SIZES+=('-')
    else
      LOCAL_NAMES+=("$name")
      LOCAL_TYPES+=('file')
      local_file_size "$item"
      format_size "$REPLY"
      LOCAL_SIZES+=("$REPLY")
    fi
  done

  (( ${#LOCAL_PATHS} == 0 )) && LOCAL_SELECTED=0
  (( LOCAL_SELECTED < 1 && ${#LOCAL_PATHS} > 0 )) && LOCAL_SELECTED=1
  (( LOCAL_SELECTED > ${#LOCAL_PATHS} )) && LOCAL_SELECTED=${#LOCAL_PATHS}
  return 0
}

load_server() {
  local payload id encoded size modified bytes name
  SERVER_IDS=()
  SERVER_NAMES=()
  SERVER_SIZES=()
  SERVER_DATES=()
  SERVER_BYTES=()
  if ! payload=$(curl -fsS -H "$AUTH_HEADER" "$BASE_URL/api/cli/files?format=tsv2"); then
    return 1
  fi
  while IFS=$'\t' read -r id encoded size modified bytes; do
    [[ -z "$id" ]] && continue
    name=$(printf '%s' "$encoded" | base64 "$BASE64_DECODE" 2>/dev/null) || name='[invalid filename]'
    name="${name//$'\n'/ }"
    name="${name//$'\t'/ }"
    SERVER_IDS+=("$id")
    SERVER_NAMES+=("$name")
    SERVER_SIZES+=("$size")
    SERVER_DATES+=("${modified[1,16]/T/ }")
    SERVER_BYTES+=("$bytes")
  done <<< "$payload"
  (( ${#SERVER_IDS} == 0 )) && SERVER_SELECTED=0
  (( SERVER_SELECTED < 1 && ${#SERVER_IDS} > 0 )) && SERVER_SELECTED=1
  (( SERVER_SELECTED > ${#SERVER_IDS} )) && SERVER_SELECTED=${#SERVER_IDS}
  return 0
}

fit_text() {
  local value="$1" width="$2"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  if (( ${#value} > width )); then
    if (( width > 3 )); then
      value="${value[1,$(( width - 3 ))]}..."
    else
      value="${value[1,$width]}"
    fi
  fi
  printf -v REPLY '%-*s' "$width" "$value"
}

repeat_char() {
  printf -v REPLY '%*s' "$2" ''
  REPLY="${REPLY// /$1}"
}

adjust_offsets() {
  if (( LOCAL_SELECTED > 0 )); then
    (( LOCAL_SELECTED < LOCAL_OFFSET )) && LOCAL_OFFSET=$LOCAL_SELECTED
    (( LOCAL_SELECTED >= LOCAL_OFFSET + VIEW_ROWS )) && LOCAL_OFFSET=$(( LOCAL_SELECTED - VIEW_ROWS + 1 ))
  else
    LOCAL_OFFSET=1
  fi
  if (( SERVER_SELECTED > 0 )); then
    (( SERVER_SELECTED < SERVER_OFFSET )) && SERVER_OFFSET=$SERVER_SELECTED
    (( SERVER_SELECTED >= SERVER_OFFSET + VIEW_ROWS )) && SERVER_OFFSET=$(( SERVER_SELECTED - VIEW_ROWS + 1 ))
  else
    SERVER_OFFSET=1
  fi
}

show_panes() {
  local cols lines pane_width inner row li si left right marker title_left title_right
  cols=$(tput cols 2>/dev/null || printf 80)
  lines=$(tput lines 2>/dev/null || printf 24)
  (( cols < 64 )) && cols=64
  pane_width=$(( (cols - 1) / 2 ))
  inner=$(( pane_width - 2 ))
  VIEW_ROWS=$(( lines - 10 ))
  (( VIEW_ROWS < 6 )) && VIEW_ROWS=6
  adjust_offsets

  clear
  fit_text "TUNNELPANE  Local: $LOCAL_DIR" "$(( cols - 1 ))"
  printf '%s\n' "$REPLY"
  repeat_char '-' "$pane_width"
  printf '%s %s\n' "$REPLY" "$REPLY"

  title_left=' LOCAL'
  title_right=' SERVER'
  [[ "$ACTIVE_PANE" == local ]] && title_left='>LOCAL'
  [[ "$ACTIVE_PANE" == server ]] && title_right='>SERVER'
  fit_text "$title_left" "$inner"; left="$REPLY"
  fit_text "$title_right  ${#SERVER_IDS} file(s)" "$inner"; right="$REPLY"
  printf '|%s| |%s|\n' "$left" "$right"

  for (( row = 0; row < VIEW_ROWS; row++ )); do
    li=$(( LOCAL_OFFSET + row ))
    si=$(( SERVER_OFFSET + row ))
    left=''
    right=''
    if (( li <= ${#LOCAL_PATHS} )); then
      marker=' '
      (( li == LOCAL_SELECTED )) && marker=$([[ "$ACTIVE_PANE" == local ]] && printf '>' || printf '*')
      fit_text "$marker ${LOCAL_NAMES[$li]}  ${LOCAL_SIZES[$li]}" "$inner"
      left="$REPLY"
    else
      fit_text '' "$inner"; left="$REPLY"
    fi
    if (( si <= ${#SERVER_IDS} )); then
      marker=' '
      (( si == SERVER_SELECTED )) && marker=$([[ "$ACTIVE_PANE" == server ]] && printf '>' || printf '*')
      fit_text "$marker ${SERVER_NAMES[$si]}  ${SERVER_SIZES[$si]}" "$inner"
      right="$REPLY"
    else
      fit_text '' "$inner"; right="$REPLY"
    fi
    printf '|%s| |%s|\n' "$left" "$right"
  done

  repeat_char '-' "$pane_width"
  printf '%s %s\n' "$REPLY" "$REPLY"
  printf '%s\n' '[Tab/Left/Right] Pane  [Up/Down or j/k] Select  [Enter] Open folder'
  printf '%s\n' '[u] Upload selected  [d] Download selected  [x] Delete server file  [r] Refresh'
  printf '%s\n' '[Esc/Ctrl+C] Cancel  [q] Quit'
  fit_text "Workers: $TRANSFER_WORKERS  |  Status: $STATUS" "$(( cols - 1 ))"
  printf '%s' "$REPLY"
}

read_key() {
  local key next code
  KEY=''
  INTERRUPTED=0
  if ! read -rsk 1 key <&3; then
    if (( INTERRUPTED )); then KEY='CANCEL'; return 0; fi
    return 1
  fi
  case "$key" in
    $'\e')
      if read -t 0.06 -rsk 1 next <&3 && [[ "$next" == '[' ]] && read -t 0.06 -rsk 1 code <&3; then
        case "$code" in
          A) KEY='UP' ;;
          B) KEY='DOWN' ;;
          C) KEY='RIGHT' ;;
          D) KEY='LEFT' ;;
          *) KEY='CANCEL' ;;
        esac
      else
        KEY='CANCEL'
      fi
      ;;
    $'\t') KEY='TAB' ;;
    $'\r'|$'\n') KEY='ENTER' ;;
    *) KEY="${key:l}" ;;
  esac
}

confirm_action() {
  local prompt="$1"
  STATUS="$prompt [y/N, Esc cancels]"
  show_panes
  read_key || return 1
  [[ "$KEY" == y ]]
}

run_cancellable() {
  local pid transfer_key
  INTERRUPTED=0
  TRANSFER_CANCELLED=0
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    transfer_key=''
    if read -t 0.1 -rsk 1 transfer_key <&3 && [[ "$transfer_key" == $'\e' ]]; then
      TRANSFER_CANCELLED=1
      kill -TERM "$pid" 2>/dev/null
    elif (( INTERRUPTED )); then
      TRANSFER_CANCELLED=1
      kill -TERM "$pid" 2>/dev/null
    fi
  done
  wait "$pid" 2>/dev/null
  TRANSFER_RC=$?
}

progress_line() {
  local action="$1" name="$2" transferred="$3" total="$4" workers="$5" started="$6"
  local percent elapsed rate done_label total_label rate_label bar_width filled empty bar
  if (( total > 0 )); then percent=$(( transferred * 100 / total )); else percent=100; fi
  (( percent > 100 )) && percent=100
  elapsed=$(( EPOCHSECONDS - started ))
  (( elapsed < 1 )) && elapsed=1
  rate=$(( transferred / elapsed ))
  format_size "$transferred"; done_label="$REPLY"
  format_size "$total"; total_label="$REPLY"
  format_size "$rate"; rate_label="$REPLY/s"
  bar_width=24
  filled=$(( percent * bar_width / 100 ))
  empty=$(( bar_width - filled ))
  printf -v bar '%*s' "$filled" ''; bar="${bar// /#}"
  printf -v REPLY '%*s' "$empty" ''; bar+="${REPLY// /-}"
  printf '\r\033[K%s %-18s [%s] %3d%%  %s/%s  %s  %d workers  Esc/Ctrl+C cancels' "$action" "${name[1,18]}" "$bar" "$percent" "$done_label" "$total_label" "$rate_label" "$workers"
}

stop_workers() {
  local pid
  for pid in "${WORKER_PIDS[@]}"; do
    command pkill -TERM -P "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
  done
  for pid in "${WORKER_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
}

monitor_workers() {
  local state_dir="$1" action="$2" name="$3" total="$4" workers="$5"
  local started=$EPOCHSECONDS pid alive transfer_key file value transferred failed worker_rc
  INTERRUPTED=0
  TRANSFER_CANCELLED=0
  while true; do
    alive=0
    for pid in "${WORKER_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && (( alive++ )); done
    transferred=0
    for file in "$state_dir"/done.*(N); do
      IFS= read -r value < "$file"
      (( transferred += value ))
    done
    progress_line "$action" "$name" "$transferred" "$total" "$workers" "$started"
    (( alive == 0 )) && break
    transfer_key=''
    if read -t 0.12 -rsk 1 transfer_key <&3 && [[ "$transfer_key" == $'\e' ]]; then
      TRANSFER_CANCELLED=1
    elif (( INTERRUPTED )); then
      TRANSFER_CANCELLED=1
    fi
    if (( TRANSFER_CANCELLED )); then
      stop_workers
      printf '\n'
      return 130
    fi
  done
  failed=0
  for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null
    worker_rc=$?
    (( worker_rc != 0 )) && failed=1
  done
  [[ -e "$state_dir/fail" ]] && failed=1
  printf '\n'
  (( failed == 0 ))
}

selected_local_file() {
  (( LOCAL_SELECTED > 0 )) && [[ "${LOCAL_TYPES[$LOCAL_SELECTED]}" == file ]]
}

selected_server_file() {
  (( SERVER_SELECTED > 0 ))
}

upload_selected() {
  local source_path name id size session_info session part_size part_count state_dir worker_count worker part expected rc
  if [[ "$ACTIVE_PANE" != local ]] || ! selected_local_file; then
    STATUS='Select a file in the local pane to upload.'
    return
  fi
  source_path="${LOCAL_PATHS[$LOCAL_SELECTED]}"
  name="${source_path:t}"
  if [[ "$name" == .* ]]; then
    STATUS='Server filenames cannot begin with a dot.'
    return
  fi
  confirm_action "Upload \"$name\"?" || { STATUS='Upload cancelled.'; return; }
  id=$(file_id "$name")
  local_file_size "$source_path"
  size="$REPLY"
  if ! session_info=$(curl -fsS -H "$AUTH_HEADER" -X POST "$BASE_URL/api/cli/uploads/$id?size=$size&partSize=$TRANSFER_PART_SIZE&format=tsv"); then
    STATUS='Could not start the parallel upload.'
    return
  fi
  IFS=$'\t' read -r session part_size part_count <<< "$session_info"
  if [[ -z "$session" || "$part_count" != <-> ]]; then
    STATUS='Server returned an invalid upload session.'
    return
  fi
  state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnelpane-upload.XXXXXX") || { STATUS='Could not create transfer workspace.'; return; }
  worker_count=$TRANSFER_WORKERS
  (( worker_count > part_count )) && worker_count=$part_count
  WORKER_PIDS=()
  for (( worker = 0; worker < worker_count; worker++ )); do
    (
      for (( part = worker; part < part_count; part += worker_count )); do
        expected=$part_size
        (( part == part_count - 1 )) && expected=$(( size - part * part_size ))
        if dd if="$source_path" bs="$part_size" skip="$part" count=1 2>/dev/null | curl -fsS -o /dev/null -H "$AUTH_HEADER" -H 'Content-Type: application/octet-stream' --data-binary @- -X PUT "$BASE_URL/api/cli/uploads/$session/parts/$part"; then
          printf '%s\n' "$expected" > "$state_dir/done.$part"
        else
          : > "$state_dir/fail"
          exit 1
        fi
      done
    ) &
    WORKER_PIDS+=("$!")
  done
  STATUS="Parallel upload: $worker_count workers."
  show_panes
  monitor_workers "$state_dir" 'UPLOAD  ' "$name" "$size" "$worker_count"
  rc=$?
  if (( rc == 130 )); then
    curl -fsS -o /dev/null -H "$AUTH_HEADER" -X DELETE "$BASE_URL/api/cli/uploads/$session" 2>/dev/null
    STATUS='Upload cancelled.'
  elif (( rc == 0 )) && curl -fsS -o /dev/null -H "$AUTH_HEADER" -X POST "$BASE_URL/api/cli/uploads/$session/finish"; then
    STATUS="Uploaded $name with $worker_count workers."
    load_server >/dev/null 2>&1 || true
  else
    curl -fsS -o /dev/null -H "$AUTH_HEADER" -X DELETE "$BASE_URL/api/cli/uploads/$session" 2>/dev/null
    STATUS='Parallel upload failed.'
  fi
  command rm -rf -- "$state_dir"
}

download_selected() {
  local name destination partial total state_dir part_size part_count worker_count worker part start end expected actual rc
  if [[ "$ACTIVE_PANE" != server ]] || ! selected_server_file; then
    STATUS='Select a file in the server pane to download.'
    return
  fi
  name="${SERVER_NAMES[$SERVER_SELECTED]}"
  destination="$LOCAL_DIR/$name"
  if [[ -e "$destination" ]]; then
    confirm_action "Replace local \"$name\"?" || { STATUS='Download cancelled.'; return; }
  else
    confirm_action "Download \"$name\" here?" || { STATUS='Download cancelled.'; return; }
  fi
  partial="$destination.tunnelpane-part.$$"
  total="${SERVER_BYTES[$SERVER_SELECTED]}"
  if [[ "$total" != <-> ]]; then STATUS='Server did not provide a valid file size.'; return; fi
  if (( total == 0 )); then
    : > "$partial"
    command mv -f -- "$partial" "$destination"
    load_local
    STATUS="Downloaded empty file $name."
    return
  fi
  part_size=$TRANSFER_PART_SIZE
  part_count=$(( (total + part_size - 1) / part_size ))
  worker_count=$TRANSFER_WORKERS
  (( worker_count > part_count )) && worker_count=$part_count
  state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnelpane-download.XXXXXX") || { STATUS='Could not create transfer workspace.'; return; }
  WORKER_PIDS=()
  for (( worker = 0; worker < worker_count; worker++ )); do
    (
      for (( part = worker; part < part_count; part += worker_count )); do
        start=$(( part * part_size ))
        end=$(( start + part_size - 1 ))
        (( end >= total )) && end=$(( total - 1 ))
        expected=$(( end - start + 1 ))
        if curl -fsS -H "$AUTH_HEADER" -r "$start-$end" -o "$state_dir/part.$part" "$BASE_URL/api/cli/files/${SERVER_IDS[$SERVER_SELECTED]}"; then
          actual=$(wc -c < "$state_dir/part.$part" | tr -d ' ')
          if (( actual == expected )); then
            printf '%s\n' "$actual" > "$state_dir/done.$part"
          else
            : > "$state_dir/fail"; exit 1
          fi
        else
          : > "$state_dir/fail"; exit 1
        fi
      done
    ) &
    WORKER_PIDS+=("$!")
  done
  STATUS="Parallel download: $worker_count workers."
  show_panes
  monitor_workers "$state_dir" 'DOWNLOAD' "$name" "$total" "$worker_count"
  rc=$?
  if (( rc == 130 )); then
    STATUS='Download cancelled.'
  elif (( rc == 0 )); then
    : > "$partial"
    for (( part = 0; part < part_count; part++ )); do command cat -- "$state_dir/part.$part" >> "$partial"; done
    actual=$(wc -c < "$partial" | tr -d ' ')
    if (( actual == total )); then
      command mv -f -- "$partial" "$destination"
      STATUS="Downloaded $name with $worker_count workers."
      load_local
    else
      command rm -f -- "$partial"
      STATUS='Download verification failed.'
    fi
  else
    STATUS='Parallel download failed.'
  fi
  command rm -rf -- "$state_dir"
}

delete_selected() {
  local name rc
  if [[ "$ACTIVE_PANE" != server ]] || ! selected_server_file; then
    STATUS='Select a server file to delete.'
    return
  fi
  name="${SERVER_NAMES[$SERVER_SELECTED]}"
  confirm_action "Delete \"$name\" from the server?" || { STATUS='Delete cancelled.'; return; }
  run_cancellable curl -fsS -o /dev/null -H "$AUTH_HEADER" -X DELETE "$BASE_URL/api/cli/files/${SERVER_IDS[$SERVER_SELECTED]}"
  rc=$TRANSFER_RC
  if (( TRANSFER_CANCELLED )); then
    STATUS='Delete cancelled.'
  elif (( rc == 0 )); then
    STATUS="Deleted $name."
    load_server >/dev/null 2>&1
  else
    STATUS='Delete failed.'
  fi
}

printf 'Username: '
IFS= read -r username <&3
if [[ -z "$username" ]]; then
  printf 'Username is required.\n' >&2
  exit 1
fi
printf 'Password: '
IFS= read -rs password <&3
printf '\n'
AUTH_HEADER="Authorization: Basic $(printf '%s' "$username:$password" | base64 | tr -d '\n')"

load_local
if ! load_server; then
  printf 'Authentication failed or the service is unavailable.\n' >&2
  unset password AUTH_HEADER
  exit 1
fi

while true; do
  show_panes
  read_key || break
  case "$KEY" in
    TAB|LEFT|RIGHT)
      [[ "$ACTIVE_PANE" == local ]] && ACTIVE_PANE=server || ACTIVE_PANE=local
      STATUS="Active pane: ${ACTIVE_PANE:u}."
      ;;
    UP|k)
      if [[ "$ACTIVE_PANE" == local ]]; then
        (( LOCAL_SELECTED > 1 )) && (( LOCAL_SELECTED-- ))
      else
        (( SERVER_SELECTED > 1 )) && (( SERVER_SELECTED-- ))
      fi
      ;;
    DOWN|j)
      if [[ "$ACTIVE_PANE" == local ]]; then
        (( LOCAL_SELECTED < ${#LOCAL_PATHS} )) && (( LOCAL_SELECTED++ ))
      else
        (( SERVER_SELECTED < ${#SERVER_IDS} )) && (( SERVER_SELECTED++ ))
      fi
      ;;
    ENTER)
      if [[ "$ACTIVE_PANE" == local && $LOCAL_SELECTED -gt 0 && "${LOCAL_TYPES[$LOCAL_SELECTED]}" == dir ]]; then
        LOCAL_DIR="${LOCAL_PATHS[$LOCAL_SELECTED]:A}"
        LOCAL_SELECTED=1
        LOCAL_OFFSET=1
        load_local
        STATUS="Opened $LOCAL_DIR."
      else
        STATUS='Enter opens folders in the local pane.'
      fi
      ;;
    u) upload_selected ;;
    d) download_selected ;;
    x) delete_selected ;;
    r)
      load_local
      if load_server; then STATUS='Both panes refreshed.'; else STATUS='Server refresh failed.'; fi
      ;;
    CANCEL) STATUS='Cancelled.' ;;
    q) break ;;
  esac
done

unset password AUTH_HEADER
clear
printf 'Signed out of TunnelPane.\n'
