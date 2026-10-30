#!/bin/sh
# Type a Lisp form (or a Command Processor command) into Genera, wait, and screenshot.
#   ./geval.sh "(+ 1 2)" [shot-name] [wait-seconds]
#   ./geval.sh "Login Lisp-Machine"      (no leading paren -> Return is sent too)
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/gtype.sh" "$1" || exit 1
case "$1" in "("*) ;; *) "$HERE/gtype.sh" -k Return ;; esac
sleep "${3:-5}"
"$HERE/screenshot.sh" "${2:-eval-$(date +%H%M%S)}"
