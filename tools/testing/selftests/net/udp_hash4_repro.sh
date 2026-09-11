#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Run INSIDE the test VM, as root.
#
# Verdict script for: does connect(AF_UNSPEC) tear down a bound UDP
# socket's hash4 entry?
#
# Method: kprobe udp_lib_hash4 / udp_lib_unhash / udp_lib_rehash.
# udp_unhash4() is static and not directly probeable, but it is reachable
# ONLY from udp_lib_unhash() and udp_lib_rehash(), so tracing those two is
# equivalent and uses exported symbols.
set -u

PROBE=${PROBE:-./udp_hash4_probe}
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
[ -d "$T" ] || { echo "FATAL: no tracefs; need CONFIG_KPROBE_EVENTS"; exit 2; }
[ -x "$PROBE" ] || { echo "FATAL: $PROBE not found or not executable"; exit 2; }

setup() {
	echo 0 > "$T/tracing_on"
	echo 0 > "$T/events/kprobes/enable" 2>/dev/null
	: > "$T/trace"
	echo > "$T/kprobe_events"
	# arg1 = %di (struct sock *), arg2 = %si (u16 hash) on x86-64
	echo "p:h4  udp_lib_hash4  sk=%di:x64 newhash=%si:u16" >> "$T/kprobe_events" || return 1
	echo "p:unh udp_lib_unhash sk=%di:x64"                 >> "$T/kprobe_events" || return 1
	echo "p:reh udp_lib_rehash sk=%di:x64"                 >> "$T/kprobe_events" || return 1
	echo 1 > "$T/events/kprobes/enable"
}

capture() { # $1 = bound|unbound  -> writes /tmp/trace.$1
	: > "$T/trace"
	echo 1 > "$T/tracing_on"
	"$PROBE" "$1" > /dev/null 2>&1
	echo 0 > "$T/tracing_on"
	grep -E "MARK-|h4:|unh:|reh:" "$T/trace" | grep -v '^#' | sed 's/.*: //' > "/tmp/trace.$1"
}

# lines between MARK-disconnect and MARK-connect2
window() { awk '/MARK-disconnect/{f=1;next} /MARK-connect2/{f=0} f' "$1"; }

setup || { echo "FATAL: could not install kprobes"; exit 2; }

echo "=== kernel: $(uname -r) ==="
grep -q "^CONFIG_BASE_SMALL=1" /boot/config-$(uname -r) 2>/dev/null \
	&& echo "WARNING: CONFIG_BASE_SMALL=1 -> hash4 compiled out, test is meaningless"

capture bound
capture unbound

echo
echo "--- BOUND (bind to specific addr+port) ---";   cat /tmp/trace.bound
echo
echo "--- UNBOUND (control) ---";                    cat /tmp/trace.unbound
echo

# NB: count on function names, not kprobe labels -- capture()'s sed strips
# the label along with the timestamp prefix.
# NB: count on function names, not kprobe labels -- capture()'s sed strips
# the label along with the timestamp prefix.
b_teardown=$(window /tmp/trace.bound   | grep -cE 'udp_lib_unhash|udp_lib_rehash')
u_teardown=$(window /tmp/trace.unbound | grep -cE 'udp_lib_unhash|udp_lib_rehash')
mapfile -t hashes < <(grep -o 'newhash=[0-9]*' /tmp/trace.bound | cut -d= -f2)

echo "=========== MECHANISM (trace evidence) ==========="
echo "bound   : teardown calls during connect(AF_UNSPEC) = $b_teardown"
echo "unbound : teardown calls during connect(AF_UNSPEC) = $u_teardown  (control, expect >0)"
if [ "${#hashes[@]}" -ge 2 ]; then
	echo "bound   : hash requested at connect1=${hashes[0]}" \
	     "at connect2=${hashes[1]}"
fi
echo

if [ "$u_teardown" -eq 0 ]; then
	echo "INCONCLUSIVE: the control did not tear down either."
	echo "Tracing or the test itself is wrong; do not draw conclusions."
	exit 2
fi

# The trace alone CANNOT decide fixed vs unfixed.  udp_unhash4() and
# udp_rehash4() are static and inlined, so a fix that relocates the socket
# at re-connect is invisible here, and teardown stays absent at disconnect
# either way.  The verdict therefore comes from behaviour.
BENCH=${BENCH:-./udp_hash4_bench}
if [ ! -x "$BENCH" ]; then
	echo "NO VERDICT: $BENCH not found."
	echo "The trace above shows the mechanism but cannot distinguish a fixed"
	echo "kernel from an unfixed one. Build udp_hash4_bench and re-run."
	exit 2
fi

echo "=========== VERDICT (behaviour) ==========="
h=$("$BENCH" healthy 500 200000 | grep -o '[0-9]* pps' | cut -d' ' -f1)
b=$("$BENCH" buggy   500 200000 | grep -o '[0-9]* pps' | cut -d' ' -f1)
echo "n=500  healthy=${h} pps   after disconnect/reconnect=${b} pps"

if [ -z "$h" ] || [ -z "$b" ] || [ "$h" -lt 100000 ]; then
	echo "INCONCLUSIVE: implausible healthy rate; check the machine is idle."
	exit 2
fi

# a misfiled socket falls back to an O(N) scan; at N=500 that is several
# times slower.  Half the healthy rate is a wide, safe threshold.
if [ "$b" -lt $((h / 2)) ]; then
	echo
	echo "BUG PRESENT: after connect(AF_UNSPEC) + reconnect the socket is"
	echo "filed under the previous peer's hash, so lookups miss the 4-tuple"
	echo "table and fall back to the per-slot scan."
	exit 1
fi
echo
echo "NOT REPRODUCED: the reconnected socket performs like a healthy one."
echo "Either the kernel carries the fix, or the defect is absent here."
exit 0
