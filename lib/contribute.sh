#!/bin/bash
# =====================================================================
#  lib/contribute.sh - share phishing found by phywall with Develust
#  Part of: phywall by Develust Technology
#
#  Usage: phywall contribute            -> dry run: shows exactly what would be sent
#         phywall contribute --apply    -> sends it
#
#  Only what 'phywall scan' found is sent (collected in <phywall>/contribute).
#  Cleaned before saving: recipients, own domains, long numbers, link paths.
#  Nothing about this server is sent (no hostname, IP, mailbox names).
# =====================================================================
LIB=$(dirname "$(readlink -f "$0")")
ROOT=$(dirname "$LIB")
source "$LIB/common.sh"
source "$LIB/queue.sh"
banner

API=${PHYWALL_API:-https://api.develust.com/v1/contribute/phywall}
UA="phywall/$PHYWALL_VERSION"
PART_ITEMS=200                 # max mails per request
PART_BYTES=$((4*1024*1024))    # max bytes per request

ok()   { echo "  [✓] $*"; }
warn() { echo "  [!] $*"; }
die()  { echo "  [✗] $*"; exit 1; }

MODE=dry
for a in "$@"; do
  case "$a" in
    --apply) MODE=apply ;;
    -h|--help) grep -A1 '^#  Usage:' "$0" | sed 's/^#  //'; exit 0 ;;
    *) echo "Unknown option: $a"; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root"
q_init
N=$(grep -c . "$Q_QUEUE")
if [ "$N" -eq 0 ]; then
  echo "Nothing to contribute yet."
  echo "  Findings are collected when you run: phywall scan <user@domain>"
  exit 0
fi

# ---------- show the report ----------
echo "Contribution report  (sent to: ${API%/v1/*})"
echo
i=0; CAUGHT=0; SUS=0; CONT=0
while read -r fp; do
  [ -f "$QITEMS/$fp.txt" ] || continue
  i=$((i+1)); c=$(q_copies "$fp")
  head -1 "$QITEMS/$fp.txt" | sed "s/^/[$i] /; s/\$/   copies $c/"
  tail -n +2 "$QITEMS/$fp.txt" | awk -v max=15 '
    /^  Content:/ {inc=1; print; next}
    inc && /^    \| / {n++; if (n<=max) print; next}
    {print}
    END { if (n>max) printf "    | ... (%d more lines - full text in preview.json)\n", n-max }'
  echo
  case "$(head -1 "$QITEMS/$fp.txt")" in CAUGHT*) CAUGHT=$((CAUGHT+1)) ;; *) SUS=$((SUS+1)) ;; esac
  grep -q '"content":' "$QITEMS/$fp.json" && CONT=$((CONT+1))
done < "$Q_QUEUE"

# full report exactly as it will be sent (one file, for inspection)
PREVIEW=$QDIR/preview.json
{
  printf '{"schema":1,"tool_version":"%s","items":[' "$PHYWALL_VERSION"
  first=1
  while read -r fp; do
    [ -f "$QITEMS/$fp.json" ] || continue
    [ $first -eq 1 ] || printf ','; first=0
    sed "s/^{/{\"copies\":$(q_copies "$fp"),/" "$QITEMS/$fp.json"
  done < "$Q_QUEUE"
  printf ']}\n'
} > "$PREVIEW"; chmod 600 "$PREVIEW"

echo "-----"
echo "Phishing mails: $i   caught: $CAUGHT   suspicious: $SUS   with full content: $CONT"
echo "Full report as sent: $PREVIEW"

if [ "$MODE" = dry ]; then
  echo
  echo "Dry run - nothing sent. Run 'phywall contribute --apply' to send it."
  exit 0
fi

# =====================================================================
#  SEND
# =====================================================================
echo
echo "Sending"
command -v curl >/dev/null || die "curl not found"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

api() {   # api <METHOD> <path> [file] -> prints HTTP code, body in $TMP/resp
  local args=(-s --max-time 60 -A "$UA" -o "$TMP/resp" -w '%{http_code}' -X "$1")
  [ -f "$TOKEN_FILE" ] && args+=(-H "X-Phywall-Token: $(cat "$TOKEN_FILE")")
  [ -n "$3" ] && args+=(-H "Content-Type: application/json" --data-binary "@$3")
  curl "${args[@]}" "$API$2" 2>/dev/null
}

# 1. health
code=$(api GET /health)
[ "$code" = 200 ] || die "Contribution service is not available right now (HTTP $code). Try again later - your findings stay queued."
ok "Service is up"

# 2. token
register() {
  rm -f "$TOKEN_FILE"
  code=$(api POST /register)
  [ "$code" = 201 ] || die "Could not register (HTTP $code)"
  t=$(tr -d '\n' < "$TMP/resp" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$t" ] || die "Could not read the token from the server answer"
  ( umask 077; printf '%s' "$t" > "$TOKEN_FILE" )
  ok "Registered this installation (anonymous token saved)"
}
[ -s "$TOKEN_FILE" ] || register

# 3. send in parts
send_part() {   # $1 = file with fingerprints of this part
  local body=$TMP/body.json first=1 fp
  {
    printf '{"schema":1,"tool_version":"%s","items":[' "$PHYWALL_VERSION"
    while read -r fp; do
      [ $first -eq 1 ] || printf ','; first=0
      sed "s/^{/{\"copies\":$(q_copies "$fp"),/" "$QITEMS/$fp.json"
    done < "$1"
    printf ']}'
  } > "$body"
  code=$(api POST "" "$body")
  if [ "$code" = 401 ]; then register; code=$(api POST "" "$body"); fi   # token unknown -> new token once
  if [ "$code" != 202 ]; then
    warn "Part rejected (HTTP $code): $(tr -d '\n' < "$TMP/resp" | head -c 300)"
    return 1
  fi
  id=$(tr -d '\n' < "$TMP/resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  # mark as sent: never queue these again, drop them from the queue
  cat "$1" >> "$Q_SENT"
  grep -vxF -f "$1" "$Q_QUEUE" > "$TMP/q" || true; cat "$TMP/q" > "$Q_QUEUE"
  grep -vF -f <(sed 's/$/ /' "$1") "$Q_SEEN" > "$TMP/s" || true; cat "$TMP/s" > "$Q_SEEN"
  while read -r fp; do rm -f "$QITEMS/$fp.json" "$QITEMS/$fp.txt"; done < "$1"
  ok "Sent part: $(grep -c . "$1") mails  (report $id)"
}

PARTS=0; FAILED=0; cnt=0; size=0; : > "$TMP/part"
while read -r fp; do
  [ -f "$QITEMS/$fp.json" ] || continue
  s=$(stat -c %s "$QITEMS/$fp.json")
  if [ "$cnt" -gt 0 ] && { [ "$cnt" -ge "$PART_ITEMS" ] || [ $((size+s)) -gt "$PART_BYTES" ]; }; then
    PARTS=$((PARTS+1)); send_part "$TMP/part" || FAILED=$((FAILED+1))
    cnt=0; size=0; : > "$TMP/part"
  fi
  echo "$fp" >> "$TMP/part"; cnt=$((cnt+1)); size=$((size+s))
done < <(cat "$Q_QUEUE")
if [ "$cnt" -gt 0 ]; then PARTS=$((PARTS+1)); send_part "$TMP/part" || FAILED=$((FAILED+1)); fi

echo
if [ "$FAILED" -eq 0 ]; then
  rm -f "$PREVIEW"
  echo "Done. Thank you - your findings help protect other mail servers."
else
  echo "Done with errors: $FAILED of $PARTS parts were not sent. They stay queued; run again later."
  exit 1
fi
