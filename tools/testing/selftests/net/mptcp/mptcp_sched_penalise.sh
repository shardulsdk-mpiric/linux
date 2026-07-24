#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# Double quotes to prevent globbing and word splitting is recommended in new
# code but we accept it, especially because there were too many before having
# address all other issues detected by shellcheck.
#shellcheck disable=SC2086

# MPTCP scheduler "penalise" test (issue #345). Drive data over an asymmetric
# two-path setup and observe the "penalise a slow subflow" scheduler behaviour.
# A variant of simult_flows.sh with the same netem topology, plus a small matrix
# of buffer-constraint scenarios. Per run it prints how often the scheduler
# halved a subflow cwnd and how much out-of-order data the receiver queued.
# Meant to be run on a baseline kernel and a patched one and compared.
#
# Usage (add MPTCP_LIB_IP_MPTCP=1 in front if pm_nl_ctl does not work for you):
#   SCENARIO=suite                              ./mptcp_sched_penalise.sh
#   SCENARIO=unbounded                          ./mptcp_sched_penalise.sh
#   SCENARIO=rwnd    RCVBUF=262144              ./mptcp_sched_penalise.sh
#   SCENARIO=sndbuf  SNDBUF=65536               ./mptcp_sched_penalise.sh
#   SCENARIO=both    RCVBUF=262144 SNDBUF=65536 ./mptcp_sched_penalise.sh
# RCVBUF/SNDBUF pin SO_RCVBUF/SO_SNDBUF; SLOW_DELAY=<ms> overrides the slow
# path's extra delay.
#
# The ">>>" line reports Halved and PenalCand (both need the DO-NOT-MERGE
# counters patch; read 0 without it) and OFO (MPTcpExtOFOQueue, any kernel).
# For the rwnd / sndbuf / both scenarios the simult_flows pass/fail time bound
# is not meaningful (it assumes both paths fully used): read the printed
# runtime and OFO, not OK/FAIL.

. "$(dirname "${0}")/mptcp_lib.sh"

ns1=""
ns2=""
ns3=""
capture=false
timeout_poll=30
timeout_test=$((timeout_poll * 2 + 1))
# a bit more space: because we have more to display
MPTCP_LIB_TEST_FORMAT="%02u %-60s"
ret=0
bail=0
slack=50
large=""
small=""
sout=""
cout=""
capout=""
capprefix=""
size=0

usage() {
	echo "Usage: $0 [ -b ] [ -c ] [ -d ] [ -i]"
	echo -e "\t-b: bail out after first error, otherwise runs all testcases"
	echo -e "\t-c: capture packets for each test using tcpdump (default: no capture)"
	echo -e "\t-d: debug this script"
	echo -e "\t-i: use 'ip mptcp' instead of 'pm_nl_ctl'"
}

# This function is used in the cleanup trap
#shellcheck disable=SC2317,SC2329
cleanup()
{
	rm -f "$cout" "$sout"
	rm -f "$large" "$small"
	rm -f "$capout"

	mptcp_lib_ns_exit "${ns1}" "${ns2}" "${ns3}"
}

mptcp_lib_check_mptcp
mptcp_lib_check_tools ip tc

#  "$ns1"              ns2                    ns3
#     ns1eth1    ns2eth1   ns2eth3      ns3eth1
#            netem
#     ns1eth2    ns2eth2
#            netem

setup()
{
	large=$(mktemp)
	small=$(mktemp)
	sout=$(mktemp)
	cout=$(mktemp)
	capout=$(mktemp)
	size=$((2 * 2048 * 4096))

	dd if=/dev/zero of=$small bs=4096 count=20 >/dev/null 2>&1
	dd if=/dev/zero of=$large bs=4096 count=$((size / 4096)) >/dev/null 2>&1

	trap cleanup EXIT

	mptcp_lib_ns_init ns1 ns2 ns3

	if $capture; then
		capprefix="simult_flows-${ns1:4}"
		mptcp_lib_pr_info "pcap will have this prefix: ${capprefix}-"
	fi

	ip link add ns1eth1 netns "$ns1" type veth peer name ns2eth1 netns "$ns2"
	ip link add ns1eth2 netns "$ns1" type veth peer name ns2eth2 netns "$ns2"
	ip link add ns2eth3 netns "$ns2" type veth peer name ns3eth1 netns "$ns3"

	ip -net "$ns1" addr add 10.0.1.1/24 dev ns1eth1
	ip -net "$ns1" addr add dead:beef:1::1/64 dev ns1eth1 nodad
	ip -net "$ns1" link set ns1eth1 up mtu 1500 gso_max_segs 0
	ip -net "$ns1" route add default via 10.0.1.2
	ip -net "$ns1" route add default via dead:beef:1::2

	ip -net "$ns1" addr add 10.0.2.1/24 dev ns1eth2
	ip -net "$ns1" addr add dead:beef:2::1/64 dev ns1eth2 nodad
	ip -net "$ns1" link set ns1eth2 up mtu 1500 gso_max_segs 0
	ip -net "$ns1" route add default via 10.0.2.2 metric 101
	ip -net "$ns1" route add default via dead:beef:2::2 metric 101

	mptcp_lib_pm_nl_set_limits "${ns1}" 1 1
	mptcp_lib_pm_nl_add_endpoint "${ns1}" 10.0.2.1 dev ns1eth2 flags subflow

	ip -net "$ns2" addr add 10.0.1.2/24 dev ns2eth1
	ip -net "$ns2" addr add dead:beef:1::2/64 dev ns2eth1 nodad
	ip -net "$ns2" link set ns2eth1 up mtu 1500 gso_max_segs 0

	ip -net "$ns2" addr add 10.0.2.2/24 dev ns2eth2
	ip -net "$ns2" addr add dead:beef:2::2/64 dev ns2eth2 nodad
	ip -net "$ns2" link set ns2eth2 up mtu 1500 gso_max_segs 0

	ip -net "$ns2" addr add 10.0.3.2/24 dev ns2eth3
	ip -net "$ns2" addr add dead:beef:3::2/64 dev ns2eth3 nodad
	ip -net "$ns2" link set ns2eth3 up mtu 1500 gso_max_segs 0
	ip netns exec "$ns2" sysctl -q net.ipv4.ip_forward=1
	ip netns exec "$ns2" sysctl -q net.ipv6.conf.all.forwarding=1

	ip -net "$ns3" addr add 10.0.3.3/24 dev ns3eth1
	ip -net "$ns3" addr add dead:beef:3::3/64 dev ns3eth1 nodad
	ip -net "$ns3" link set ns3eth1 up mtu 1500 gso_max_segs 0
	ip -net "$ns3" route add default via 10.0.3.2
	ip -net "$ns3" route add default via dead:beef:3::2

	mptcp_lib_pm_nl_set_limits "${ns3}" 1 1

	# debug build can slow down measurably the test program
	# we use quite tight time limit on the run-time, to ensure
	# maximum B/W usage.
	# Use kmemleak/lockdep/kasan/prove_locking presence as a rough
	# estimate for this being a debug kernel and increase the
	# maximum run-time accordingly. Observed run times for CI builds
	# running selftests, including kbuild, were used to determine the
	# amount of time to add.
	grep -q ' kmemleak_init$\| lockdep_init$\| kasan_init$\| prove_locking$' /proc/kallsyms && slack=$((slack+550))
}

do_transfer()
{
	local cin=$1
	local sin=$2
	local max_time=$3
	local port
	port=$((10000+MPTCP_LIB_TEST_COUNTER))

	:> "$cout"
	:> "$sout"
	:> "$capout"

	if $capture; then
		local capuser
		if [ -z $SUDO_USER ] ; then
			capuser=""
		else
			capuser="-Z $SUDO_USER"
		fi

		local capfile="${capprefix}-${port}"
		local capopt="-i any -s 108 -B 32768 ${capuser}"

		ip netns exec ${ns3}  tcpdump ${capopt} -w "${capfile}-listener.pcap"  >> "${capout}" 2>&1 &
		local cappid_listener=$!

		ip netns exec ${ns1} tcpdump ${capopt} -w "${capfile}-connector.pcap" >> "${capout}" 2>&1 &
		local cappid_connector=$!

		sleep 1
	fi

	mptcp_lib_nstat_init "${ns3}"
	mptcp_lib_nstat_init "${ns1}"

	ip netns exec ${ns3} \
		./mptcp_connect -jt ${timeout_poll} -l -p $port -T $max_time ${RCVBUF:+-R ${RCVBUF}} ${SNDBUF:+-S ${SNDBUF}} \
			0.0.0.0 < "$sin" > "$sout" &
	local spid=$!

	mptcp_lib_wait_local_port_listen "${ns3}" "${port}"

	ip netns exec ${ns1} \
		./mptcp_connect -jt ${timeout_poll} -p $port -T $max_time ${RCVBUF:+-R ${RCVBUF}} ${SNDBUF:+-S ${SNDBUF}} \
			10.0.3.3 < "$cin" > "$cout" &
	local cpid=$!

	mptcp_lib_wait_timeout "${timeout_test}" "${ns3}" "${ns1}" "${port}" \
		"${cpid}" "${spid}" &
	local timeout_pid=$!

	wait $cpid
	local retc=$?
	wait $spid
	local rets=$?

	if kill -0 $timeout_pid; then
		# Finished before the timeout: kill the background job
		mptcp_lib_kill_group_wait $timeout_pid
		timeout_pid=0
	fi

	if $capture; then
		sleep 1
		kill ${cappid_listener}
		kill ${cappid_connector}
	fi

	mptcp_lib_nstat_get "${ns3}"
	mptcp_lib_nstat_get "${ns1}"
	# Per-run instrumentation. Halved = times a subflow cwnd was halved,
	# PenalCand = times a slow subflow was picked as a candidate (both need the
	# DEBUG counters patch; read 0 without it). OFO = MPTcpExtOFOQueue, the
	# out-of-order data queued at the receiver; lower means less head-of-line
	# blocking. All read on any kernel, so baseline vs patched is comparable.
	gc() { mptcp_lib_get_counter "$1" "$2" 2>/dev/null || echo 0; }
	echo "   >>> PenalCand ns1=$(gc ${ns1} MPTcpExtPenalCandidate)/ns3=$(gc ${ns3} MPTcpExtPenalCandidate)  Halved ns1=$(gc ${ns1} MPTcpExtCwndPenalized)/ns3=$(gc ${ns3} MPTcpExtCwndPenalized)  OFO ns1=$(gc ${ns1} MPTcpExtOFOQueue)/ns3=$(gc ${ns3} MPTcpExtOFOQueue)"

	cmp $sin $cout > /dev/null 2>&1
	local cmps=$?
	cmp $cin $sout > /dev/null 2>&1
	local cmpc=$?

	if [ $retc -eq 0 ] && [ $rets -eq 0 ] &&
	   [ $cmpc -eq 0 ] && [ $cmps -eq 0 ] &&
	   [ $timeout_pid -eq 0 ]; then
		printf "%-16s" " max $max_time "
		mptcp_lib_pr_ok
		cat "$capout"
		return 0
	fi

	mptcp_lib_pr_fail "client exit code $retc, server $rets"
	mptcp_lib_pr_err_stats "${ns3}" "${ns1}" "${port}"
	ls -l $sin $cout
	ls -l $cin $sout

	cat "$capout"
	return 1
}

run_test()
{
	local rate1=$1
	local rate2=$2
	local delay1=$3
	local delay2=$4
	local limit1=$5
	local limit2=$6
	local lret
	local dev
	shift 6
	local msg=$*

	[ $delay1 -gt 0 ] && delay1="delay ${delay1}ms" || delay1=""
	[ $delay2 -gt 0 ] && delay2="delay ${delay2}ms" || delay2=""

	for dev in ns1eth1 ns1eth2; do
		tc -n $ns1 qdisc del dev $dev root >/dev/null 2>&1
	done
	for dev in ns2eth1 ns2eth2; do
		tc -n $ns2 qdisc del dev $dev root >/dev/null 2>&1
	done

	# keep the queued pkts number low, or the RTT estimator will see
	# increasing latency over time.
	tc -n $ns1 qdisc add dev ns1eth1 root netem rate ${rate1}mbit $delay1 limit ${limit1}
	tc -n $ns1 qdisc add dev ns1eth2 root netem rate ${rate2}mbit $delay2 limit ${limit2}
	tc -n $ns2 qdisc add dev ns2eth1 root netem rate ${rate1}mbit $delay1 limit ${limit1}
	tc -n $ns2 qdisc add dev ns2eth2 root netem rate ${rate2}mbit $delay2 limit ${limit2}

	# time is measured in ms, account for transfer size, aggregated link speed
	# and header overhead (10%)
	#              ms    byte -> bit   10%        mbit      -> kbit -> bit  10%
	local time=$((1000 * size  *  8  * 10 / ((rate1 + rate2) * 1000 * 1000 * 9) ))

	# mptcp_connect will do some sleeps to allow the mp_join handshake
	# completion (see mptcp_connect): 200ms on each side, add some slack
	time=$((time + 400 + slack))

	mptcp_lib_print_title "$msg"
	do_transfer $small $large $time
	lret=$?
	mptcp_lib_result_code "${lret}" "${msg}"
	if [ $lret -ne 0 ] && ! mptcp_lib_subtest_is_flaky; then
		ret=$lret
		[ $bail -eq 0 ] || exit $ret
	fi

	msg+=" - reverse direction"
	mptcp_lib_print_title "${msg}"
	do_transfer $large $small $time
	lret=$?
	mptcp_lib_result_code "${lret}" "${msg}"
	if [ $lret -ne 0 ] && ! mptcp_lib_subtest_is_flaky; then
		ret=$lret
		[ $bail -eq 0 ] || exit $ret
	fi
}

while getopts "bcdhi" option;do
	case "$option" in
	"h")
		usage $0
		exit ${KSFT_PASS}
		;;
	"b")
		bail=1
		;;
	"c")
		capture=true
		;;
	"d")
		set -x
		;;
	"i")
		mptcp_lib_set_ip_mptcp
		;;
	"?")
		usage $0
		exit ${KSFT_FAIL}
		;;
	esac
done

setup
mptcp_lib_subtests_last_ts_reset
# Scenario matrix. Select with SCENARIO=<name>; default runs the stock
# simult_flows throughput suite. Run each on a baseline kernel and a patched
# one and compare the ">>>" line. All non-suite scenarios use a 10 mbit / 3 mbit
# asymmetric-bandwidth pair. More than two subflows and backup subflows would
# need a wider topology and are not covered here.
case "${SCENARIO:-suite}" in
suite)
	# Stock simult_flows suite. Expect: passes on both baseline and patched,
	# identical within timing noise.
	run_test 10 10 0 0  20 20 "balanced bwidth"
	run_test 10 10 1 25 20 50 "balanced bwidth with unbalanced delay"

	# we still need some additional infrastructure to pass the following test-cases
	MPTCP_LIB_SUBTEST_FLAKY=1 run_test 10 3 0 0  30 20 "unbalanced bwidth"
	run_test 10 3 1 25 40 30 "unbalanced bwidth with unbalanced delay"
	run_test 10 3 25 1 50 30 "unbalanced bwidth with opposed, unbalanced delay"
	;;
unbounded)
	# Autotuned buffers (neither SO_SNDBUF nor SO_RCVBUF pinned), slow path with
	# extra delay: neither send-buffer- nor receive-window-limited. Compare OFO
	# patched vs baseline.
	run_test 10 3 0 ${SLOW_DELAY:-30} 100 100 "autotuned, slow +${SLOW_DELAY:-30}ms"
	;;
rwnd)
	# Receive-window-limited: small SO_RCVBUF on the receiver (set RCVBUF=<bytes>,
	# e.g. 262144), slow path with extra delay. Compare runtime patched vs
	# baseline.
	: "${RCVBUF:?rwnd scenario needs RCVBUF=<bytes>, e.g. 262144}"
	run_test 10 3 0 ${SLOW_DELAY:-50} 100 100 "receive-window-limited, slow +${SLOW_DELAY:-50}ms, SO_RCVBUF=${RCVBUF}"
	;;
sndbuf)
	# Send-buffer-limited: small SO_SNDBUF on the sender (set SNDBUF=<bytes>,
	# e.g. 65536). Compare OFO patched vs baseline.
	: "${SNDBUF:?sndbuf scenario needs SNDBUF=<bytes>, e.g. 65536}"
	run_test 10 3 0 0 30 20 "send-buffer-limited, SO_SNDBUF=${SNDBUF}"
	;;
both)
	# Send-buffer- and receive-window-limited at once (set both RCVBUF and
	# SNDBUF): the sender is backlogged but the receiver is still the
	# bottleneck. Compare runtime patched vs baseline.
	: "${RCVBUF:?both scenario needs RCVBUF=<bytes>, e.g. 262144}"
	: "${SNDBUF:?both scenario needs SNDBUF=<bytes>, e.g. 65536}"
	run_test 10 3 0 ${SLOW_DELAY:-50} 100 100 "send-buffer + receive-window limited, slow +${SLOW_DELAY:-50}ms, SO_RCVBUF=${RCVBUF} SO_SNDBUF=${SNDBUF}"
	;;
*)
	echo "unknown SCENARIO='${SCENARIO}' (use: suite | unbounded | rwnd | sndbuf | both)" >&2
	exit 1
	;;
esac

mptcp_lib_result_print_all_tap
exit $ret
