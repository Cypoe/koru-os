#!/usr/bin/env bash
# run-qemu-scenario.sh [elf] [secs] — QEMU tier of the kauto scenario gate.
#
# Boots the freestanding ELF under QEMU with a filter-dump pcap on the NIC
# (captures guest TX BEFORE slirp drops the subnet broadcasts telemetry
# uses), waits for the self-driving scenario to finish, converts the pcap
# to listener.log format, and runs gate-surf-wire.py --markers-only.
#
# QEMU has no i915 -> the perf/GPU invariants cannot be measured here;
# --markers-only asserts the program/marker mechanics. The i915 tier is
# the physical T590: flash the -kauto ISO, wait ~30s, then
#   python3 gates/gate-surf-wire.py <listener.log>
#
# Defaults: elf=work/m1-vbirq9-small.elf secs=35
set -u
WORK="$(cd "$(dirname "$0")" && pwd)"
SESSION="$(cd "$WORK/.." && pwd)"
GATE="$SESSION/gates/gate-surf-wire.py"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-x86_64}"
ELF="${1:-$WORK/m1-vbirq9-small.elf}"
SECS="${2:-35}"
PCAP="$WORK/q-scen.pcap"
WLOG="$WORK/q-scen.wire.log"
SER="$WORK/q-scen.serial"

[ -f "$ELF" ] || { echo "run-qemu-scenario: no ELF at $ELF"; exit 2; }
rm -f "$PCAP" "$WLOG" "$SER"

"$QEMU" -kernel "$ELF" -m 512M -display none -serial "file:$SER" -no-reboot \
    -netdev user,id=n0 -device e1000e,netdev=n0 \
    -object filter-dump,id=d0,netdev=n0,file="$PCAP" &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT
sleep "$SECS"
kill $QPID 2>/dev/null
wait $QPID 2>/dev/null
trap - EXIT

python3 "$WORK/pcap2wire.py" "$PCAP" "$WLOG"
echo "--- serial tail ---"
tail -5 "$SER"
echo "--- gate ---"
python3 "$GATE" "$WLOG" --markers-only
