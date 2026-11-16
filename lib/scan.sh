#!/bin/bash
# =====================================================================
#  lib/scan.sh - finds phishing in a mailbox
#  Part of: phywall by Develust Technology
#
#  Usage: phywall scan <user@domain>          -> dry run: Inbox + Sent report
#         phywall scan <user@domain> --move   -> moves Inbox phishing to Junk
#                                                (Sent is only reported, never moved)
# =====================================================================
LIB=$(dirname "$(readlink -f "$0")")     # .../phywall/lib
ROOT=$(dirname "$LIB")                   # .../phywall
source "$LIB/common.sh"
source "$LIB/queue.sh"     # findings are collected for 'phywall contribute'
banner

U="$1"; MODE="$2"
DOM=${U#*@}; USR=${U%@*}
BASE=${MAILBASE:-/var/mail/vhosts}/$DOM/$USR
SRC=$BASE/cur
DST=$BASE/.Junk/cur
# STRONG rules: the mail is moved
STRONG='^Symbol: (PHISH_LINK_AND_TEXT|PHISH_DEFAULT_PLUS_CUSTOM|PHISHED_OPENPHISH|PHISHED_PHISHTANK|DBL_PHISH|DBL_ABUSE_PHISH|HACKED_WP_PHISHING) \('
# WEAK rule: Rspamd's link check alone (link text != real link). Newsletters with
# click-tracking links trigger it too, so alone it only moves a mail when the
# total score is at least PHISHING_MIN_SCORE; otherwise it is shown as SUSPICIOUS.
WEAK='^Symbol: PHISHING \('
PHISHING_MIN_SCORE=${PHISHING_MIN_SCORE:-3.0}
# any phishing rule (used for the Sent report)
TRIGGER='^Symbol: (PHISH_LINK_AND_TEXT|PHISH_DEFAULT_PLUS_CUSTOM|PHISHING|PHISHED_OPENPHISH|PHISHED_PHISHTANK|DBL_PHISH|DBL_ABUSE_PHISH|HACKED_WP_PHISHING) \('
# shown in the Rules output: triggers + 0-point signals (what matched)
SHOW='^Symbol: (PHISH_URL|PHISH_TEXT|PHISH_SUBJECT|PHISH_LINK_AND_TEXT|PHISH_DEFAULT_PLUS_CUSTOM|PHISHING|PHISHED_OPENPHISH|PHISHED_PHISHTANK|DBL_PHISH|DBL_ABUSE_PHISH|HACKED_WP_PHISHING) \('

[[ $U =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] || { echo "Usage: $0 user@domain [--move]"; exit 1; }
doveadm user "$U" >/dev/null 2>&1 || { echo "Mailbox not found in Dovecot: $U"; exit 1; }
[ -d "$SRC" ] && [ -d "$DST" ] || { echo "Folder missing: $SRC or $DST"; exit 1; }

# log: <project>/logs/<user@domain>_<date>_<dryrun|move>.log
LOGDIR=${LOGDIR:-$ROOT/logs}
mkdir -p "$LOGDIR"; chmod 700 "$LOGDIR"
[ "$MODE" = "--move" ] && M=move || M=dryrun
LOG=$LOGDIR/${U}_$(date +%F_%H%M)_$M.log

say()   { printf '%s\n' "$*" | tee -a "$LOG"; }   # screen + log
clr()   { printf '\r\033[K' >&2; }                # clear progress line (screen only)

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

# rspamc scan with the real sender data from our Postfix Received header
# (accurate SPF/DMARC/hostname checks; Sent mails usually have none -> content rules only)
scan_mail() {
  local f=$1 rcv ip helo rdns mfrom args=()
  rcv=$(awk '/^\r?$/{exit} /^Received: from /' "$f" | grep -vE '\[(127\.0\.0\.1|::1)\]' | grep -m1 -E '\[[0-9a-fA-F.:]+\]')
  ip=$(echo "$rcv" | grep -oE '\[[0-9a-fA-F.:]+\]' | tail -1 | tr -d '[]')
  helo=$(echo "$rcv" | awk '{print $3}')
  rdns=$(echo "$rcv" | sed -nE 's/.*\(([^ ]+) \[.*/\1/p')
  mfrom=$(get_hdr "$f" Return-Path | tr -d '<> ')
  [ -n "$ip" ]    && args+=(--ip "$ip")
  [ -n "$helo" ]  && args+=(--helo "$helo")
  [ -n "$rdns" ]  && args+=(--hostname "$rdns")
  [ -n "$mfrom" ] && args+=(--from "$mfrom")
  rspamc "${args[@]}" "$f"
}

# classify a scan result: prints move / suspicious / none
classify() {
  local out=$1 sc
  if echo "$out" | grep -qE "$STRONG"; then echo move; return; fi
  if echo "$out" | grep -qE "$WEAK"; then
    sc=$(echo "$out" | awk '/^Score:/{print $2; exit}')
    awk -v s="$sc" -v m="$PHISHING_MIN_SCORE" 'BEGIN{exit !(s+0>=m+0)}' && echo move || echo suspicious
    return
  fi
  echo none
}

SENT=$BASE/.Sent/cur
q_init
T=$(find "$SRC" -maxdepth 1 -type f | wc -l)
TS=$( [ -d "$SENT" ] && find "$SENT" -maxdepth 1 -type f | wc -l || echo 0)
say "===== $(date '+%F %T')  Mailbox: $U  Mode: $M  Inbox: $T  Sent: $TS ====="
say ""

# =====================================================================
#  PASS 1: INBOX - phishing is moved to Junk (with --move)
# =====================================================================
say "===== Inbox ====="
say ""
i=0; n=0; ok=0; err=0; sus=0
for f in "$SRC"/*; do
  [ -f "$f" ] || continue
  i=$((i+1))
  [ $((i % 10)) -eq 0 ] && printf '\r\033[K... Inbox progress: %d/%d (%d%%), found: %d' "$i" "$T" $((i*100/T)) "$n" >&2

  out=$(scan_mail "$f")
  s=$(echo "$out" | awk '/^Score:/{print $2; exit}')
  awk -v s="$s" 'BEGIN{exit !(s<0)}' && continue          # trusted (whitelist etc.) -> skip
  verdict=$(classify "$out")
  [ "$verdict" = none ] && continue                         # no phishing rule -> skip
  rules=$(echo "$out" | grep -E "$SHOW" | sed 's/^Symbol: //')
  n=$((n+1))
  queue_add "$f" "$out" "$verdict" 2>/dev/null || true    # collect for 'phywall contribute' (before moving)
  score=$(echo "$out" | grep -m1 '^Score:' | cut -d' ' -f2-)
  from=$(decode "$(get_hdr "$f" From)")
  subj=$(decode "$(get_hdr "$f" Subject)")
  date=$(get_hdr "$f" Date)

  if [ "$verdict" = suspicious ]; then
    status="SUSPICIOUS - not moved (link check only)"; sus=$((sus+1))
  elif [ "$MODE" = "--move" ]; then
    if e=$(mv "$f" "$DST/" 2>&1); then status="MOVED OK"; ok=$((ok+1))
    else status="MOVE ERROR: $e"; err=$((err+1)); fi
  else
    status="WOULD MOVE (dry run)"
  fi

  clr
  say "[$n] $status"
  say "  From:    $from"
  say "  Subject: $subj"
  say "  Date:    $date"
  say "  Score:   $score"
  echo "$rules" | sed '1s/^/  Rules:   /; 2,$s/^/           /' | tee -a "$LOG"
  say ""
done
clr
[ "$n" -eq 0 ] && say "  No phishing found in Inbox." && say ""

# =====================================================================
#  PASS 2: SENT - report only, never moved
#  A phishing mail in Sent = an employee forwarded it. The sender and the
#  recipients may have clicked the link -> check with them.
# =====================================================================
say "===== Sent (report only - never moved) ====="
say ""
j=0; x=0; RCPTS=""
if [ -d "$SENT" ]; then
  for f in "$SENT"/*; do
    [ -f "$f" ] || continue
    j=$((j+1))
    [ $((j % 10)) -eq 0 ] && printf '\r\033[K... Sent progress: %d/%d (%d%%), suspicious: %d' "$j" "$TS" $((j*100/TS)) "$x" >&2

    out=$(scan_mail "$f")
    [ "$(classify "$out")" = move ] || continue           # no whitelist skip here: own domain may be whitelisted
    x=$((x+1))
    rules=$(echo "$out" | grep -E "$TRIGGER" | sed 's/^Symbol: //; s/\[.*//' | paste -sd, - | sed 's/,/, /g')
    to=$(decode "$(get_hdr "$f" To)")
    cc=$(decode "$(get_hdr "$f" Cc)")
    subj=$(decode "$(get_hdr "$f" Subject)")
    date=$(get_hdr "$f" Date)
    RCPTS+="$to${cc:+, $cc}, "

    clr
    say "[S$x] FORWARDED PHISHING"
    say "  To:      $to"
    [ -n "$cc" ] && say "  Cc:      $cc"
    say "  Subject: $subj"
    say "  Date:    $date"
    say "  Rules:   $rules"
    say ""
  done
  clr
  [ "$x" -eq 0 ] && say "  No phishing found in Sent." && say ""
else
  say "  No Sent folder ($SENT)."
  say ""
fi

# =====================================================================
#  SUMMARY
# =====================================================================
say "-----"
if [ "$MODE" = "--move" ]; then
  say "Inbox: scanned $i, moved $ok, suspicious $sus (not moved), errors $err"
else
  say "Inbox: scanned $i, would move $((n-sus)), suspicious $sus (not moved)"
fi
say "Sent:  scanned $j, suspicious $x"
if [ "$x" -gt 0 ]; then
  R=$(echo "$RCPTS" | tr ',' '\n' | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | sort -u | paste -sd, - | sed 's/,/, /g')
  say "  -> Check with $U and the recipients: $R"
  say "     (did they click the link or enter a password?)"
fi
if [ "$MODE" = "--move" ] && [ "$ok" -gt 0 ]; then
  doveadm force-resync -u "$U" INBOX && doveadm force-resync -u "$U" Junk && say "Dovecot resync OK"
fi
echo "Log: $LOG"
