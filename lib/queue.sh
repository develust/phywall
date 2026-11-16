#!/bin/bash
# =====================================================================
#  lib/queue.sh - contribution queue (loaded by scan.sh and contribute.sh)
#  Part of: phywall by Develust Technology
#
#  scan.sh calls queue_add for every phishing finding. Each finding is
#  cleaned (no recipients, no own domains, no long numbers, no link
#  paths) and saved once, identified by a fingerprint of its cleaned
#  content. contribute.sh shows and sends the queue.
#
#  <phywall>/contribute/
#     queue           fingerprints waiting to be sent (one per line)
#     items/<fp>.json the cleaned finding as sent to the API
#     items/<fp>.txt  the same finding, readable (for the dry run)
#     seen            "<fp> <mailfile-hash>"  -> copies = mailboxes/files with this phishing
#     sent            fingerprints already sent (never queued again)
#     .token          anonymous API token
# =====================================================================
QDIR=$ROOT/contribute
Q_QUEUE=$QDIR/queue
QITEMS=$QDIR/items
Q_SEEN=$QDIR/seen
Q_SENT=$QDIR/sent
TOKEN_FILE=$QDIR/.token
CONTENT_MIN_SCORE=${CONTENT_MIN_SCORE:-10}    # full content only for mails scoring this or more
CONTENT_MAX_BYTES=200000                      # API limit per mail (200 KB of text)

q_init() {
  mkdir -p "$QITEMS"; chmod 700 "$QDIR" "$QITEMS"
  touch "$Q_QUEUE" "$Q_SEEN" "$Q_SENT"; chmod 600 "$Q_QUEUE" "$Q_SEEN" "$Q_SENT"
}

# text on stdin -> JSON string
json_str() {
  printf '"'
  LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' \
               -e 's/[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]//g' \
    | sed -e ':a;N;$!ba;s/\n/\\n/g' | tr -d '\n'
  printf '"'
}
# lines on stdin -> JSON array of strings
json_arr() {
  local out="" l
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    out+="${out:+,}$(printf '%s' "$l" | json_str)"
  done
  printf '[%s]' "$out"
}
sedesc() { printf '%s' "$1" | sed 's/[][\.*^$/&|]/\\&/g'; }

# build the cleaning rules for one mail: recipients + own domains
q_clean_rules() {
  local f=$1 rules="" a d mb=${MAILBASE:-/var/mail/vhosts}
  # recipients: the scanned mailbox + addresses in To/Cc/Delivered-To/X-Original-To
  for a in $( { echo "$U"; for h in To Cc Delivered-To X-Original-To; do get_hdr "$f" "$h"; done; } \
              | grep -oiE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | sort -u ); do
    rules+="s/$(sedesc "$a")/[recipient]/gI;"
  done
  # own domains = every domain hosted on this server
  for d in $(ls -1 "$mb" 2>/dev/null); do
    d=$(sedesc "$d")
    rules+="s/[A-Za-z0-9._%+-]+@$d/[recipient]/gI;s/$d/[own-domain]/gI;"
  done
  # links -> host only, phone numbers and long numbers -> #
  rules+='s#https?://([^/[:space:]"'"'"'<>)]+)[^[:space:]"'"'"'<>)]*#\1#gI;'
  rules+='s/\+?[0-9][0-9 ().-]{7,}[0-9]/#/g;s/[0-9]{5,}/#/g;'
  printf '%s' "$rules"
}

# queue_add <mailfile> <rspamc output> <caught|suspicious>
queue_add() {
  local f=$1 out=$2 group=$3 R score sender env subj rules details hosts content fp fh item txt
  [ "$group" = move ] && group=caught                 # scan says "move", the API says "caught"
  R=$(q_clean_rules "$f")
  score=$(echo "$out" | awk '/^Score:/{print $2; exit}')
  [[ $score =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || score=0

  sender=$(decode "$(get_hdr "$f" From)" | sed -E "$R")
  env=$(get_hdr "$f" Return-Path | tr -d '<> ' | sed -E "$R")
  subj=$(decode "$(get_hdr "$f" Subject)" | sed -E "$R")
  rules=$(echo "$out" | grep -E "$SHOW" | sed -E 's/^Symbol: ([A-Z0-9_]+).*/\1/')
  details=$(echo "$out" | grep -E "$SHOW" | sed -E 's/^Symbol: ([A-Z0-9_]+) \([^)]*\)/\1/' | grep '\[' | sed -E "$R" | cut -c1-300)

  # link hosts (Rspamd's own parser), without our own domains
  hosts=$(rspamadm mime urls -H -u "$f" 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/[[:space:]]//g' \
          | grep -E '^(\*\.)?([a-z0-9-]{1,63}\.)+[a-z0-9-]{2,63}$' | sed -E "$R" | grep -v 'own-domain' \
          | sort -u | head -200)

  # full content only for high scores
  content=""
  if awk -v s="$score" -v m="$CONTENT_MIN_SCORE" 'BEGIN{exit !(s+0>=m+0)}'; then
    content=$(rspamadm mime extract -t -o decoded_utf "$f" 2>/dev/null | sed -E "$R" | head -c "$CONTENT_MAX_BYTES")
  fi

  # fingerprint of the cleaned phishing (same campaign in many mailboxes = same fp)
  fp=$(printf '%s\n%s\n%s\n%s' "$sender" "$subj" "$hosts" "$content" | sha256sum | cut -c1-32)
  fh=$(basename "$f" | cut -d: -f1 | sha256sum | cut -c1-16)

  grep -qx "$fp" "$Q_SENT" && return 0                 # already sent earlier
  grep -qx "$fp $fh" "$Q_SEEN" && return 0             # this mail file already counted
  echo "$fp $fh" >> "$Q_SEEN"
  grep -qx "$fp" "$Q_QUEUE" && return 0                # same phishing already queued -> only a new copy

  item="{\"group\":\"$group\",\"score\":$score"
  item+=",\"sender\":$(printf '%s' "$sender" | json_str)"
  item+=",\"envelope_sender\":$(printf '%s' "$env" | json_str)"
  item+=",\"subject\":$(printf '%s' "$subj" | json_str)"
  item+=",\"rules\":$(printf '%s\n' "$rules" | json_arr)"
  item+=",\"details\":$(printf '%s\n' "$details" | json_arr)"
  item+=",\"hosts\":$(printf '%s\n' "$hosts" | json_arr)"
  [ -n "$content" ] && item+=",\"content\":$(printf '%s' "$content" | json_str)"
  item+="}"
  printf '%s' "$item" > "$QITEMS/$fp.json"

  {
    echo "$(echo "$group" | tr 'a-z' 'A-Z')   score $score"
    echo "  Sender:   $sender"
    echo "  Envelope: $env"
    echo "  Subject:  $subj"
    echo "  Rules:    $(printf '%s\n' "$details" "$rules" | awk -F'[' '!seen[$1]++' | grep . | paste -sd, - | sed 's/,/, /g')"
    echo "  Links:    $(printf '%s\n' "$hosts" | grep . | paste -sd, - | sed 's/,/, /g')"
    if [ -n "$content" ]; then
      echo "  Content:  ($(printf '%s\n' "$content" | wc -l) lines)"
      printf '%s\n' "$content" | sed 's/^/    | /'
    fi
  } > "$QITEMS/$fp.txt"
  chmod 600 "$QITEMS/$fp.json" "$QITEMS/$fp.txt"
  echo "$fp" >> "$Q_QUEUE"
}

q_copies() { grep -c "^$1 " "$Q_SEEN"; }
