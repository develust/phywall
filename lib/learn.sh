#!/bin/bash
# =====================================================================
#  lib/learn.sh - trains Rspamd Bayes from mail folders
#  Part of: phywall by Develust Technology
#
#  Usage: phywall learn albahotel.az                   -> dry run, all accounts of the domain
#         phywall learn info@albahotel.az              -> dry run, one account
#         phywall learn albahotel.az --learn           -> really trains Bayes
#         phywall learn info@albahotel.az --learn      -> really trains, one account
#  Options: --days N            only mails from the last N days (faster repeat runs)
#           --exclude a,b,c     skip these accounts (e.g. tech,webmaster,services)
#
#  Learns:  Sent -> ham      Junk -> spam
#  (Inbox is never used: it is full of marketing mail people did not ask for.)
#  Sent mails are scanned first: if a phishing rule fires (e.g. staff forwarded
#  a phishing mail), the mail is NOT learned and is listed as suspicious.
#
#  Speed: PHYWALL_JOBS mails are processed at once (default 6); results are
#  counted and logged in the original order afterwards.
# =====================================================================
LIB=$(dirname "$(readlink -f "$0")")     # .../phywall/lib
ROOT=$(dirname "$LIB")                   # .../phywall
source "$LIB/common.sh"
banner

# ---------- paths ----------
MAILBASE=${MAILBASE:-/var/mail/vhosts}
LOGDIR=${LOGDIR:-$ROOT/logs}

# phishing rules that make a Sent mail "suspicious" (same scoring rules as detector.sh)
SUSPECT='^Symbol: (PHISH_LINK_AND_TEXT|PHISH_DEFAULT_PLUS_CUSTOM|PHISHING|PHISHED_OPENPHISH|PHISHED_PHISHTANK|DBL_PHISH|DBL_ABUSE_PHISH|HACKED_WP_PHISHING) \('

# get one header (handles folded multi-line headers)
get_hdr() {
  awk -v h="$(echo "$2" | tr 'A-Z' 'a-z')" '
    /^\r?$/ { exit }
    /^[ \t]/ { if (p) { sub(/^[ \t]+/, " "); v = v $0 }; next }
    { if (p) exit
      i = index($0, ":")
      if (tolower(substr($0, 1, i - 1)) == h) { p = 1; v = substr($0, i + 1) } }
    END { gsub(/\r/, "", v); sub(/^ +/, "", v); print v }' "$1"
}

# decode =?charset?B?...?= and =?charset?Q?...?=
decode() {
  local s out="" pre cs enc data dec
  s=$(echo "$1" | sed -E 's/\?=[[:space:]]+=\?/?==?/g')
  while [[ $s =~ =\?([^?]+)\?([BbQq])\?([^?]*)\?= ]]; do
    pre=${s%%"${BASH_REMATCH[0]}"*}
    cs=${BASH_REMATCH[1]}; enc=${BASH_REMATCH[2]}; data=${BASH_REMATCH[3]}
    if [[ $enc == [Bb] ]]; then
      dec=$(echo "$data" | base64 -d 2>/dev/null | iconv -c -f "$cs" -t UTF-8 2>/dev/null)
    else
      dec=$(printf '%b' "$(echo "$data" | sed 's/_/ /g; s/=\([0-9A-Fa-f]\{2\}\)/\\x\1/g')" | iconv -c -f "$cs" -t UTF-8 2>/dev/null)
    fi
    out+="$pre$dec"
    s=${s#*"${BASH_REMATCH[0]}"}
  done
  echo "$out$s"
}

ok()   { echo "  [✓] $*"; }
warn() { echo "  [!] $*"; }
die()  { echo "  [✗] $*"; exit 1; }
usage(){ grep -A5 '^#  Usage:' "$0" | sed 's/^#  //'; exit 1; }

# ---------- arguments ----------
TARGET=""; MODE=dry; DAYS=""; EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --learn)    MODE=learn; shift ;;
    --days)     DAYS="$2"; shift 2 ;;
    --exclude)  EXCLUDE="$2"; shift 2 ;;
    --exclude=*) EXCLUDE="${1#*=}"; shift ;;
    -h|--help)  usage ;;
    -*)         echo "Unknown option: $1"; usage ;;
    *)          TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
[ -z "$DAYS" ] || [[ $DAYS =~ ^[0-9]+$ ]] || die "--days needs a number"

if [[ $TARGET == *@* ]]; then DOM=${TARGET#*@}; ONE=${TARGET%@*}; else DOM=$TARGET; ONE=""; fi
DOMDIR=$MAILBASE/$DOM

# ---------- preflight ----------
echo "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "Run as root"
command -v rspamc >/dev/null || die "rspamc not found"
systemctl is-active --quiet rspamd || die "Rspamd is not running"
[ -d "$DOMDIR" ] || die "Domain folder not found: $DOMDIR"
rspamc stat >/dev/null 2>&1 || die "Cannot reach the Rspamd controller (rspamc stat failed). Check the controller password / secure_ip."
ok "Rspamd is running, controller reachable"

# accounts
if [ -n "$ONE" ]; then
  [ -d "$DOMDIR/$ONE/cur" ] || die "Mailbox not found: $DOMDIR/$ONE"
  ACCOUNTS="$ONE"
else
  ACCOUNTS=$(for d in "$DOMDIR"/*/; do [ -d "$d/cur" ] && basename "$d"; done)
fi
[ -n "$ACCOUNTS" ] || die "No mailboxes found in $DOMDIR"

# --exclude: accept "tech" or "tech@domain", comma separated
if [ -n "$EXCLUDE" ]; then
  EXL=$(echo "$EXCLUDE" | tr 'A-Z' 'a-z' | tr ', ' '\n\n' | sed 's/@.*//' | grep -v '^$' | sort -u)
  SKIPPED=""; KEEP=""
  for a in $ACCOUNTS; do
    if echo "$EXL" | grep -qx "$(echo "$a" | tr 'A-Z' 'a-z')"; then SKIPPED+="$a "; else KEEP+="$a "; fi
  done
  for x in $EXL; do echo " $ACCOUNTS " | tr '\n' ' ' | grep -qi " $x " || warn "Exclude: no such account '$x' (ignored)"; done
  ACCOUNTS=$KEEP
  [ -n "$SKIPPED" ] && ok "Excluded: $(echo $SKIPPED | tr ' ' ',')"
  [ -n "$ACCOUNTS" ] || die "All accounts are excluded - nothing to do"
fi
NACC=$(echo "$ACCOUNTS" | wc -w)
ok "Accounts: $NACC"
[ -n "$DAYS" ] && ok "Only mails from the last $DAYS days"

# folder list for an account: "label|class|path"
folders() {
  local a=$DOMDIR/$1
  echo "Sent|ham|$a/.Sent/cur"
  echo "Junk|spam|$a/.Junk/cur"
}
files_in() {   # list mail files in a folder (respects --days)
  [ -d "$1" ] || return 0
  if [ -n "$DAYS" ]; then find "$1" -maxdepth 1 -type f -mtime -"$DAYS"; else find "$1" -maxdepth 1 -type f; fi
}
count_in() { files_in "$1" | wc -l; }
# ---------- parallel processing ----------
JOBS=${PHYWALL_JOBS:-6}; [[ $JOBS =~ ^[1-9][0-9]?$ ]] || JOBS=6
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
# one mail: Sent (ham) is checked for phishing first, then learned.
# Output line 1 = SUS (phishing rule fired, not learned) or LEARN, then rspamc output.
learn_one() {
  local f=$1 cls=$2 chk
  if [ "$cls" = ham ]; then
    chk=$(rspamc "$f" 2>/dev/null)
    if echo "$chk" | grep -qE "$SUSPECT"; then echo SUS; echo "$chk"; return; fi
  fi
  echo LEARN; rspamc "learn_$cls" "$f" 2>&1
}
# plearn <list> <outdir> <cls> <progress label>: result of line N -> <outdir>/N
plearn() {
  local list=$1 dir=$2 cls=$3 label=$4 tot k=0 f
  mkdir -p "$dir"; tot=$(grep -c . "$list")
  printf '\r\033[K  %s ... starting %d mails (%d at a time)' "$label" "$tot" "$JOBS" >&2
  while IFS= read -r f <&3; do
    k=$((k+1))
    learn_one "$f" "$cls" > "$dir/$k" < /dev/null &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    [ $((k % 10)) -eq 0 ] && printf '\r\033[K  %s ... %d/%d (%d%%)' "$label" "$k" "$tot" $((k*100/tot)) >&2
  done 3< "$list"
  wait
}
bayes() { rspamc stat 2>/dev/null | awk -v c="$1" '$0 ~ "Statfile: "c" " {for(i=1;i<=NF;i++) if($i=="learned:") {gsub(/;/,"",$(i+1)); print $(i+1)}}' | head -1; }

# ---------- Bayes before ----------
HAM0=$(bayes BAYES_HAM); SPAM0=$(bayes BAYES_SPAM)
echo
echo "Bayes now:  ham learned ${HAM0:-?}   spam learned ${SPAM0:-?}"

# ---------- dry run: table ----------
echo
echo "  (Sent mails are checked for phishing during --learn; suspicious ones are not learned)"
printf '  %-22s %10s %11s\n' "Account" "Sent(ham)" "Junk(spam)"
TH=0; TS=0
for a in $ACCOUNTS; do
  s=$(count_in "$DOMDIR/$a/.Sent/cur"); j=$(count_in "$DOMDIR/$a/.Junk/cur")
  printf '  %-22s %10s %11s\n' "$a" "$s" "$j"
  TH=$((TH+s)); TS=$((TS+j))
done
echo "  -----"
echo "  Accounts: $NACC   Ham: $TH   Spam: $TS"

if [ "$MODE" = dry ]; then
  echo
  echo "Dry run - nothing learned. Run again with --learn."
  exit 0
fi

# =====================================================================
#  LEARN
# =====================================================================
mkdir -p "$LOGDIR"; chmod 700 "$LOGDIR"
LOG=$LOGDIR/learn_${TARGET}_$(date +%F_%H%M).log
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
clr() { printf '\r\033[K' >&2; }

echo
say "===== $(date '+%F %T')  Learn: $TARGET  Accounts: $NACC  Ham: $TH  Spam: $TS ====="
GL=0; GS=0; GE=0; GX=0; GT=0; GXN=0; n=0; FIRSTERR=""; SUSLIST=""
for a in $ACCOUNTS; do
  n=$((n+1))
  while IFS='|' read -r label cls path; do
    files_in "$path" > "$TMPD/list"
    tot=$(grep -c . "$TMPD/list"); [ "$tot" -eq 0 ] && continue
    rm -rf "$TMPD/res"
    plearn "$TMPD/list" "$TMPD/res" "$cls" "[$n/$NACC] $a  $label($cls)"
    l=0; s=0; e=0; x=0; t=0; k=0
    while IFS= read -r f <&3; do
      k=$((k+1))
      kind=$(head -1 "$TMPD/res/$k" 2>/dev/null)
      if [ "$kind" = SUS ]; then
          chk=$(tail -n +2 "$TMPD/res/$k")
          x=$((x+1))
          GXN=$((GXN+1))
          to=$(decode "$(get_hdr "$f" To)"); cc=$(decode "$(get_hdr "$f" Cc)")
          subj=$(decode "$(get_hdr "$f" Subject)"); date=$(get_hdr "$f" Date)
          rules=$(echo "$chk" | grep -oE "$SUSPECT" | sed 's/^Symbol: //; s/ ($//' | paste -sd, - | sed 's/,/, /g')
          SUSLIST+="  [S$GXN] $a@$DOM → $to${cc:+, $cc}"$'\n'
          SUSLIST+="       Subject: $subj"$'\n'
          SUSLIST+="       Date:    $date"$'\n'
          SUSLIST+="       Rules:   $rules"$'\n\n'
          continue
      fi
      r=$(tail -n +2 "$TMPD/res/$k" 2>/dev/null)
      if echo "$r" | grep -qi 'already'; then s=$((s+1))
      elif echo "$r" | grep -qiE 'less tokens than required|too (short|few tokens)'; then t=$((t+1))
      elif echo "$r" | grep -qiE 'success[^a-z]*(=|:)[[:space:]]*true|"success"[[:space:]]*:[[:space:]]*true'; then l=$((l+1))
      else e=$((e+1)); [ -z "$FIRSTERR" ] && FIRSTERR=$(echo "$r" | grep -v '^Results for' | head -2 | tr '\n' ' ')
        if echo "$r" | grep -qiE 'unauthori[sz]ed|password|forbidden'; then clr; say "Controller refused learning (password required): $r"; exit 1; fi
      fi
    done 3< "$TMPD/list"
    clr
    if [ "$cls" = ham ]; then
      say "  [$n/$NACC] $(printf '%-20s %-6s %-5s' "$a" "$label" "$cls")  learned $l   skipped $s   too short $t   suspicious $x   errors $e"
    else
      say "  [$n/$NACC] $(printf '%-20s %-6s %-5s' "$a" "$label" "$cls")  learned $l   skipped $s   too short $t   errors $e"
    fi
    GL=$((GL+l)); GS=$((GS+s)); GE=$((GE+e)); GX=$((GX+x)); GT=$((GT+t))
  done < <(folders "$a")
done
clr

HAM1=$(bayes BAYES_HAM); SPAM1=$(bayes BAYES_SPAM)
say "-----"
say "Learned: $GL   Skipped (already learned): $GS   Too short: $GT   Suspicious (not learned): $GX   Errors: $GE"
[ "$GT" -gt 0 ] && echo "  (Too short = fewer than 11 words, e.g. attachment-only mails. Bayes cannot learn them - harmless.)"
if [ -n "$SUSLIST" ]; then
  say "Suspicious Sent mails (not learned - phishing rule fired):"
  printf '%s' "$SUSLIST" | tee -a "$LOG"
fi
[ -n "$FIRSTERR" ] && say "First error: $FIRSTERR"
say "Bayes before: ham ${HAM0:-?}  spam ${SPAM0:-?}"
say "Bayes after:  ham ${HAM1:-?}  spam ${SPAM1:-?}"
if [[ $HAM0$HAM1$SPAM0$SPAM1 =~ ^[0-9]+$ ]]; then
  say "Bayes grew:   ham +$((HAM1-HAM0))  spam +$((SPAM1-SPAM0))   (should be close to 'Learned: $GL')"
fi
[ -n "$HAM1" ] && [ "$HAM1" -lt 200 ] && say "[!] Ham is below 200 - Bayes stays inactive until it reaches min_learns."
[ -n "$SPAM1" ] && [ "$SPAM1" -lt 200 ] && say "[!] Spam is below 200 - Bayes stays inactive until it reaches min_learns."
echo "Log: $LOG"
