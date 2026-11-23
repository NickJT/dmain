#!/bin/sh
# Copy the house server's capture and house log into app/house/huelog/data/. This
# copy is the backup: the server's disk is the only other.
#
# Safe while huelog is writing: a record half-copied is the last line without
# its newline, which every reader holds back, and the next pull completes it.
#
#   HUELOG_HOST=<ssh name> tools/pull.sh    # default: house, an ssh alias
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
host=${HUELOG_HOST:-house}
mkdir -p "$here/data"
rsync -a --timeout=20 "$host:huelog/data/" "$here/data/"
# One line per run, so the LaunchAgent's log shows it ran, not just that it
# did not fail.
echo "$(date '+%F %T') pulled $(ls "$here/data/house" | wc -l | tr -d ' ') day(s) from $host"
