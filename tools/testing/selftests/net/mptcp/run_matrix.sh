#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Driver for mptcp_sched_penalise.sh. Runs EVERY spec in a config file REPEAT
# times on the CURRENTLY BOOTED kernel and prints one compact table
# (runtime / Halved / OFO / RTTmax / result) per subtest. Run the SAME command
# on each kernel you want to compare (v2 / base / guard-off / bisect builds) and
# diff the tables; each table is tagged with `uname -r` (the -gXXXXXXXX suffix
# is the kernel commit).
#
# ONE COMMAND, ALL TESTS, ONE BUILD:
#   REPEAT=3 ./run_matrix.sh                 # runs everything in runs.conf
#   ./run_matrix.sh myset.conf               # a different config
#
# Config: one run-GROUP per line, "<label>  <env...>"; # starts a comment.
# SWEEP SYNTAX: a value written KEY={a,b,c} expands into one run per value,
# with the value appended to the label. e.g.
#   rwnd   SCENARIO=rwnd RCVBUF={131072,262144,524288}
# becomes rwnd_131072 / rwnd_262144 / rwnd_524288. One sweep dimension per line
# (use multiple lines for a cross product). Halved/OFO are the busy side (max of
# ns1/ns3): Halved shows on the 16MB sender, OFO on the receiver, so max() picks
# the meaningful side automatically.

set -u
CONF="${1:-runs.conf}"
REPEAT="${REPEAT:-3}"
HARNESS="./mptcp_sched_penalise.sh"
[ -x "$HARNESS" ] || { echo "no $HARNESS here -- run from the mptcp selftests dir" >&2; exit 1; }
[ -f "$CONF" ]    || { echo "no config '$CONF'" >&2; exit 1; }

KREL="$(uname -r)"
OUTDIR="matrix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"

{
	echo "KERNEL $KREL"
	echo "CC ${CC:-cubic}   (pinned per-namespace by the harness)"
	echo "config $CONF   REPEAT $REPEAT   $(date)"
	printf '%-20s %-3s %-3s %-10s %-7s %-7s %-9s %s\n' \
		label run sub runtime_ms Halved OFO RTTmax result
} | tee "$SUMMARY"

num() { case "$1" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }

# Expand a spec: if it has one KEY={a,b,c}, emit "sublabel|subspec" per value;
# otherwise emit "|spec". sublabel is the value (for the label suffix).
expand_spec() {
	local spec="$1"
	if [[ "$spec" =~ ([A-Za-z_][A-Za-z0-9_]*)=\{([^}]+)\} ]]; then
		local key="${BASH_REMATCH[1]}" list="${BASH_REMATCH[2]}"
		local whole="${key}={${list}}"
		local before="${spec%%"$whole"*}" after="${spec#*"$whole"}"
		local IFS=',' v
		for v in $list; do
			echo "${v}|${before}${key}=${v}${after}"
		done
	else
		echo "|$spec"
	fi
}

run_one() {   # $1=rlabel  $2=subspec
	local rlabel="$1" sspec="$2" r log g t i h1 h3 o1 o3 rtt tm res
	local -a gl tl
	for r in $(seq 1 "$REPEAT"); do
		log="$OUTDIR/${rlabel}_r${r}.log"
		# shellcheck disable=SC2086
		env $sspec $HARNESS > "$log" 2>&1
		mapfile -t gl < <(grep -F '>>>' "$log")
		mapfile -t tl < <(grep -E '^(ok|not ok) [0-9]+ ' "$log")
		i=0
		while [ "$i" -lt "${#tl[@]}" ]; do
			g="${gl[$i]:-}"; t="${tl[$i]}"
			h1=$(num "$(sed -n 's/.*Halved ns1=\([0-9]*\)\/ns3=[0-9]*.*/\1/p' <<<"$g")")
			h3=$(num "$(sed -n 's/.*Halved ns1=[0-9]*\/ns3=\([0-9]*\).*/\1/p' <<<"$g")")
			o1=$(num "$(sed -n 's/.*OFO ns1=\([0-9]*\)\/ns3=[0-9]*.*/\1/p' <<<"$g")")
			o3=$(num "$(sed -n 's/.*OFO ns1=[0-9]*\/ns3=\([0-9]*\).*/\1/p' <<<"$g")")
			rtt=$(sed -n 's/.*RTTms\[[^]]*max=\([0-9.]*\).*/\1/p' <<<"$g")
			tm=$(sed -n 's/.*time=\([0-9]*\)ms.*/\1/p' <<<"$t")
			res=OK; grep -qE '^not ok ' <<<"$t" && res=FAIL
			printf '%-20s %-3s %02d  %-10s %-7s %-7s %-9s %s\n' \
				"$rlabel" "$r" "$((i+1))" "${tm:-?}" \
				"$(( h1 > h3 ? h1 : h3 ))" "$(( o1 > o3 ? o1 : o3 ))" \
				"${rtt:-?}" "$res" | tee -a "$SUMMARY"
			i=$((i+1))
		done
	done
}

while read -r label spec; do
	case "$label" in ''|\#*) continue;; esac
	while IFS='|' read -r sub sspec; do
		run_one "${label}${sub:+_$sub}" "$sspec"
	done < <(expand_spec "$spec")
done < "$CONF"

echo "full per-run logs + this table: $OUTDIR/" | tee -a "$SUMMARY"
