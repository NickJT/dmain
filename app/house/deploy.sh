#!/bin/sh
# Deploys one house program to a host:  ./deploy.sh <host> <program> [--config]
#
#   host      the server, as ssh names it (an alias in ~/.ssh/config)
#   program   huelog, dmain or hub
#   --config  also overwrite the host's copies of the program's tracked config
#
# Builds for whatever the host says it is (uname -m), refuses a binary of the
# wrong architecture, keeps the previous binary as <program>.prev, installs the
# systemd user unit and restarts it, then checks it stayed up.
#
# Tracked config is copied only where the host has none, unless --config: hub's
# running config changes through `adopt`, and a deploy must not undo that.
# Secrets (huelog.json, bridge.json, hub-coordinator*.json) are never copied or
# printed; they are made on the host.
#
# Restarting hub interrupts the Zigbee network for about 25 s.
set -eu

usage() { echo "usage: $0 <host> <huelog|dmain|hub> [--config]" >&2; exit 2; }
[ $# -ge 2 ] || usage
host=$1
prog=$2
force_config=${3:-}
[ -z "$force_config" ] || [ "$force_config" = --config ] || usage

case $prog in
huelog) config="" ;;
dmain) config="dmain.json display.json power-on.json" ;;
hub) config="devices.json rules.json groups.json schedule.json leak-alert.json" ;;
*) usage ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
src=$here/$prog
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$@"; }

arch=$(ssh_ uname -m)
case $arch in
x86_64) target="-Dtarget=x86_64-linux-gnu" want="x86-64" ;;
armv7l) target="-Dtarget=arm-linux-gnueabihf -Dcpu=cortex_a53" want="ARM" ;;
*) echo "deploy: $host is $arch, which nothing here builds for" >&2; exit 1 ;;
esac

out=$(mktemp -d "${TMPDIR:-/tmp}/house-deploy.XXXXXX")
trap 'rm -rf "$out"' EXIT
echo "deploy: building $prog for $host ($arch)"
# shellcheck disable=SC2086 # $target is two words on purpose
(cd "$src" && zig build $target -Doptimize=ReleaseSafe --prefix "$out")
bin=$out/bin/$prog
file "$bin" | grep -q "$want" || {
	echo "deploy: built $(file -b "$bin"), not $want: refusing to copy it" >&2
	exit 1
}

ssh_ "mkdir -p ~/$prog ~/.config/systemd/user"
scp -q "$bin" "$host:$prog/$prog.new"
for f in $config; do
	if [ "$force_config" = --config ] || ! ssh_ "test -e ~/$prog/$f"; then
		scp -q "$src/$f" "$host:$prog/$f"
		echo "deploy: copied $f"
	fi
done
scp -q "$src/deploy/$prog.service" "$host:.config/systemd/user/$prog.service"
ssh_ "cd ~/$prog && { [ ! -e $prog ] || cp -p $prog $prog.prev; } && mv $prog.new $prog \
	&& systemctl --user daemon-reload && systemctl --user enable -q $prog && systemctl --user restart $prog"

# A crash loop looks active between restarts, so wait past one RestartSec (5 s)
# and judge by the restart count as well.
sleep 8
# One property per call: `show -p A -p B --value` prints them in systemd's order, not this one's.
active=$(ssh_ "systemctl --user show $prog -p ActiveState --value")
restarts=$(ssh_ "systemctl --user show $prog -p NRestarts --value")
echo "deploy: $prog on $host is $active, restarted $restarts times since the deploy"
case "$active $restarts" in
"active 0") ;;
*)
	echo "deploy: $prog is not running cleanly. Its log:" >&2
	ssh_ "journalctl _SYSTEMD_USER_UNIT=$prog.service -n 20 -o cat --no-pager" >&2 || true
	exit 1
	;;
esac
