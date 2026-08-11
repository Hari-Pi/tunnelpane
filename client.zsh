#!/bin/zsh

emulate -LR zsh
setopt pipefail no_beep

BASE_URL="${TUNNELPANE_URL:-__TUNNELPANE_URL__}"
LOCAL_DIR="${PWD:A}"
ACTIVE_PANE=local
LOCAL_SELECTED=1
SERVER_SELECTED=1
LOCAL_OFFSET=1
SERVER_OFFSET=1
STATUS='Ready.'
INTERRUPTED=0
typeset -a LOCAL_PATHS LOCAL_NAMES LOCAL_TYPES LOCAL_SIZES
typeset -a SERVER_IDS SERVER_NAMES SERVER_SIZES SERVER_DATES

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
  local payload id encoded size modified name
  SERVER_IDS=()
  SERVER_NAMES=()
  SERVER_SIZES=()
  SERVER_DATES=()
  if ! payload=$(curl -fsS -H "$AUTH_HEADER" "$BASE_URL/api/cli/files?format=tsv"); then
    return 1
  fi
  while IFS=$'\t' read -r id encoded size modified; do
    [[ -z "$id" ]] && continue
    name=$(printf '%s' "$encoded" | base64 "$BASE64_DECODE" 2>/dev/null) || name='[invalid filename]'
    name="${name//$'\n'/ }"
    name="${name//$'\t'/ }"
    SERVER_IDS+=("$id")
    SERVER_NAMES+=("$name")
    SERVER_SIZES+=("$size")
    SERVER_DATES+=("${modified[1,16]/T/ }")
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
  fit_text "Status: $STATUS" "$(( cols - 1 ))"
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

selected_local_file() {
  (( LOCAL_SELECTED > 0 )) && [[ "${LOCAL_TYPES[$LOCAL_SELECTED]}" == file ]]
}

selected_server_file() {
  (( SERVER_SELECTED > 0 ))
}

upload_selected() {
  local source_path name id rc
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
  STATUS="Uploading $name - Esc or Ctrl+C cancels."
  show_panes
  run_cancellable curl -f --progress-bar -H "$AUTH_HEADER" -T "$source_path" "$BASE_URL/api/cli/files/$id"
  rc=$TRANSFER_RC
  if (( TRANSFER_CANCELLED )); then
    STATUS='Upload cancelled.'
  elif (( rc == 0 )); then
    STATUS="Uploaded $name."
    load_server >/dev/null 2>&1
  else
    STATUS='Upload failed. Files above 95 MB must use the browser.'
  fi
}

download_selected() {
  local name destination partial rc
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
  STATUS="Downloading $name - Esc or Ctrl+C cancels."
  show_panes
  run_cancellable curl -f --progress-bar -H "$AUTH_HEADER" -o "$partial" "$BASE_URL/api/cli/files/${SERVER_IDS[$SERVER_SELECTED]}"
  rc=$TRANSFER_RC
  if (( TRANSFER_CANCELLED )); then
    command rm -f -- "$partial"
    STATUS='Download cancelled.'
  elif (( rc == 0 )); then
    command mv -f -- "$partial" "$destination"
    STATUS="Downloaded $name."
    load_local
  else
    command rm -f -- "$partial"
    STATUS='Download failed.'
  fi
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
