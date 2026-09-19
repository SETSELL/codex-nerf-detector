#!/bin/bash
# ============================================================
#  Codex Nerf Detector - macOS launcher
#
#  Double-click this file in Finder. It opens Terminal and runs
#  nerf-check.sh from the same folder.
#
#  FIRST RUN ON macOS:
#    Gatekeeper blocks downloaded shell scripts. Either
#      - right-click this file -> Open -> Open, or
#      - run:  xattr -d com.apple.quarantine "run-check.command"
#    and if it is still not executable:
#      - run:  chmod +x run-check.command nerf-check.sh
#
#  NOTE: this launcher has NOT been tested on a real Mac.
#  It is written against the documented macOS paths and is meant
#  as a starting point - corrections are welcome.
# ============================================================

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$HERE/nerf-check.sh" ]; then
    echo
    echo "  [ERROR] nerf-check.sh not found next to this launcher"
    echo "          $HERE/nerf-check.sh"
    echo
    printf "Press Enter to exit..."
    read -r _
    exit 1
fi

exec bash "$HERE/nerf-check.sh" "$@"
