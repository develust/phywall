#!/bin/bash
# =====================================================================
#  lib/common.sh - shared parts of phywall (loaded by every command)
#  Part of: phywall by Develust Technology
# =====================================================================

PHYWALL_VERSION="1.0.1"

# ---------- banner (screen only, never in logs) ----------
# Colors and solid blocks only on a real terminal; plain '#' text otherwise
# (cron, pipes, logs, non-UTF-8 consoles).
banner() {
  local G="" W="" D="" N="" R1="" R2="" R3="" R4="" R5="" R6="" R7="" BLOCK=0
  if [ -t 2 ]; then
    G=$'\e[38;5;36m'; W=$'\e[1;97m'; D=$'\e[2m'; N=$'\e[0m'
    R1=$'\e[1;38;5;210m'; R2=$'\e[1;38;5;209m'; R3=$'\e[1;38;5;203m'; R4=$'\e[1;38;5;197m'
    R5=$'\e[1;38;5;196m'; R6=$'\e[1;38;5;160m'; R7=$'\e[1;38;5;124m'
    case "$(locale charmap 2>/dev/null)" in UTF-8|utf8) BLOCK=1 ;; esac
  fi
  {
  cat <<EOF_BANNER
${G}                ## #${N}
${G}           ###########${N}
${G}          ################${N}
${G}        ####################${N}
${G}       #####################${N}
${G}      #######################     ${N}${R1}########  ##     ## ##    ## ##      ##    ###    ##       ##${N}
${G}      ########################    ${N}${R2}##     ## ##     ##  ##  ##  ##  ##  ##   ## ##   ##       ##${N}
${G}      ########################    ${N}${R3}##     ## ##     ##   ####   ##  ##  ##  ##   ##  ##       ##${N}
${G}      #######################     ${N}${R4}########  #########    ##    ##  ##  ## ##     ## ##       ##${N}
${G}      ######### #### ########     ${N}${R5}##        ##     ##    ##    ##  ##  ## ######### ##       ##${N}
${G}       # #####  #### ###### #     ${N}${R6}##        ##     ##    ##    ##  ##  ## ##     ## ##       ##${N}
${G}       # #     ####  ### ###      ${N}${R7}##        ##     ##    ##     ###  ###  ##     ## ######## ########${N}
${G}              ######${N}
${G}           ##############         ${N}${W}Phishing defense for Rspamd mail servers${N}
${G}        ####################      ${N}${D}scan · move to Junk · report forwarded lures · train Bayes${N}
${G}        ##################${N}
${G}          ##############          ${N}${G}by Develust Technology${N}
${G}                ##     #${N}

   ${R5}[ PHYWALL v${PHYWALL_VERSION} ]${N}  Finds phishing in your mailboxes, moves it to Junk,
   reports lures your staff forwarded, and teaches Rspamd to catch the next wave.
   Support: support@develust.com

EOF_BANNER
  } | if [ "$BLOCK" -eq 1 ]; then sed 's/#/█/g'; else cat; fi >&2
}
