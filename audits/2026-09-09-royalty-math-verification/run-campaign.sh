#!/bin/bash
R="$(cd "$(dirname "$0")" && pwd)"; export R
cd "$R/royalty-sim" || exit 1
date +%s > "$R/fuzz-start.txt"
xargs -P 30 -I{} -d'\n' bash -c '{}' < "$R/fuzz-jobs.txt"
date +%s > "$R/fuzz-end.txt"
echo DONE > "$R/fuzz-status.txt"
