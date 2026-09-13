#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Defect 2: a disconnected socket bound to a specific address and port is
# left in the 4-tuple hash table, and an unprivileged SO_BINDTODEVICE then
# relocates it to the zero-peer bucket instead of removing it.
#
# The relocation itself cannot be traced (udp_rehash4() and udp_unhash4()
# are static and inlined), so the verdict is read from what IS visible:
#
#   unfixed  disconnect does nothing, then SO_BINDTODEVICE calls
#            udp_lib_rehash() with a hash4 different from the one the
#            connect filed it under -- so the entry is moved
#   fixed    udp_disconnect_unhash4() runs at disconnect; by the time
#            SO_BINDTODEVICE calls udp_lib_rehash() there is nothing left
#            in the table to move
set -u

PROBE=${PROBE:-./udp_hash4_probe}
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
[ -d "$T" ] || { echo "FATAL: no tracefs; need CONFIG_KPROBE_EVENTS"; exit 2; }
[ -x "$PROBE" ] || { echo "FATAL: $PROBE not found"; exit 2; }

echo 0 > "$T/tracing_on"
echo 0 > "$T/events/kprobes/enable" 2>/dev/null
: > "$T/trace"
echo > "$T/kprobe_events"

echo "p:h4  udp_lib_hash4  sk=%di:x64 newhash=%si:u16" >> "$T/kprobe_events" || exit 2
echo "p:reh udp_lib_rehash sk=%di:x64 newhash4=%dx:u16" >> "$T/kprobe_events" || exit 2
echo "p:unh udp_lib_unhash sk=%di:x64" >> "$T/kprobe_events" || exit 2
# only present on a fixed kernel; absence is not an error
have_fix=0
if echo "p:dis udp_disconnect_unhash4 sk=%di:x64" >> "$T/kprobe_events" 2>/dev/null; then
	have_fix=1
fi
echo 1 > "$T/events/kprobes/enable"

echo "=== kernel: $(uname -r) ==="
echo 1 > "$T/tracing_on"
"$PROBE" btd
echo 0 > "$T/tracing_on"

grep -E "MARK-|h4:|reh:|unh:|dis:" "$T/trace" | grep -v '^#' | sed 's/.*: //' > /tmp/trace.btd
echo
cat /tmp/trace.btd
echo

window() { awk "/$1/{f=1;next} /$2/{f=0} f" /tmp/trace.btd; }

teardown_at_disconnect=$(window MARK-disconnect MARK-bindtodevice |
			 grep -cE 'udp_lib_unhash|udp_lib_rehash|udp_disconnect_unhash4')
mapfile -t connect_hash  < <(window MARK-connect1 MARK-disconnect |
			     grep -o 'newhash=[0-9]*' | cut -d= -f2)
mapfile -t rehash_hash   < <(window MARK-bindtodevice MARK-done |
			     grep -o 'newhash4=[0-9]*' | cut -d= -f2)

echo "================ VERDICT ================"
echo "teardown during connect(AF_UNSPEC) : $teardown_at_disconnect"
[ "${#connect_hash[@]}" -ge 1 ] && echo "filed under hash at connect        : ${connect_hash[0]}"
[ "${#rehash_hash[@]}" -ge 1 ]  && echo "hash requested by SO_BINDTODEVICE  : ${rehash_hash[0]}"
echo

if [ "${#rehash_hash[@]}" -eq 0 ]; then
	echo "INCONCLUSIVE: SO_BINDTODEVICE did not reach udp_lib_rehash()."
	echo "It may have been refused; check the probe output above."
	exit 2
fi

if [ "$teardown_at_disconnect" -gt 0 ]; then
	echo "NOT REPRODUCED: the entry is removed at connect(AF_UNSPEC), so the"
	echo "later SO_BINDTODEVICE has nothing in the table to relocate."
	exit 0
fi

if [ "${#connect_hash[@]}" -ge 1 ] && [ "${connect_hash[0]}" != "${rehash_hash[0]}" ]; then
	echo "BUG PRESENT: the entry survives connect(AF_UNSPEC), and"
	echo "SO_BINDTODEVICE then asks udp_lib_rehash() for hash ${rehash_hash[0]}"
	echo "while the entry is filed under ${connect_hash[0]}, so it is moved to the"
	echo "zero-peer bucket rather than removed. That destination is the same"
	echo "for every socket sharing this address and port."
	exit 1
fi

echo "INCONCLUSIVE: no teardown seen, but the two hashes match."
exit 2
