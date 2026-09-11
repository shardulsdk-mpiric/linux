// SPDX-License-Identifier: GPL-2.0
/*
 * Cost of the hash4 misfiling, measured as UDP receive-path lookup rate.
 *
 *   healthy : N reuseport sockets bound to one addr:port, each connect()ed
 *             once to a distinct peer.  All correctly filed in hash4.
 *   buggy   : same, but each socket additionally does
 *             connect(AF_UNSPEC) + connect(same peer), which leaves it
 *             filed under the first connect's hash.
 *
 * Then blast packets at ONE victim socket's 4-tuple and time the send
 * loop.  Every packet pays __udp4_lib_lookup() in the receive path whether
 * or not it is ultimately queued, so the send loop time tracks lookup cost.
 * The receiver is deliberately not drained; rcvbuf is left small.
 *
 * Usage: udp_hash4_bench <healthy|buggy> <nsockets> <npackets>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <arpa/inet.h>

#define SRV_PORT   34000
#define PEER_BASE  40000
#define DECOY_BASE 50000

static struct sockaddr_in mk(int port)
{
	struct sockaddr_in a;

	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	return a;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	int buggy, n, pkts, i, sndbuf = 1 << 20, one = 1, rcv = 4096;
	struct sockaddr_in srv = mk(SRV_PORT), peer, unspec_holder;
	struct sockaddr unspec;
	char buf[64] = {0};
	double t0, t1;
	int *fds, victim, tx;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <healthy|buggy> <nsockets> <npackets>\n", argv[0]);
		return 2;
	}
	buggy = !strcmp(argv[1], "buggy");
	n     = atoi(argv[2]);
	pkts  = atoi(argv[3]);

	memset(&unspec, 0, sizeof(unspec));
	unspec.sa_family = AF_UNSPEC;
	(void)unspec_holder;

	fds = calloc(n, sizeof(int));
	if (!fds)
		return 2;

	for (i = 0; i < n; i++) {
		fds[i] = socket(AF_INET, SOCK_DGRAM, 0);
		if (fds[i] < 0) {
			perror("socket");
			return 2;
		}
		setsockopt(fds[i], SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
		setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv));
		/* specific addr + specific port: sets BINDADDR_LOCK|BINDPORT_LOCK */
		if (bind(fds[i], (struct sockaddr *)&srv, sizeof(srv)) < 0) {
			perror("bind");
			return 2;
		}
		peer = mk(PEER_BASE + i);
		if (buggy) {
			/* Connect to a DECOY peer first so the hash4 entry is
			 * filed under a different 4-tuple, then disconnect
			 * (teardown is skipped for a specifically-bound
			 * socket) and connect to the real peer.  The socket
			 * stays filed under the decoy's hash.  Reconnecting
			 * to the SAME peer would leave the stale hash equal
			 * to the correct one and measure nothing.
			 */
			struct sockaddr_in decoy = mk(DECOY_BASE + i);

			if (connect(fds[i], (struct sockaddr *)&decoy, sizeof(decoy)) < 0)
				perror("decoy connect");
			if (connect(fds[i], &unspec, sizeof(unspec)) < 0)
				perror("disconnect");
		}
		if (connect(fds[i], (struct sockaddr *)&peer, sizeof(peer)) < 0) {
			perror("connect");
			return 2;
		}
	}

	victim = n / 2;
	peer   = mk(PEER_BASE + victim);

	tx = socket(AF_INET, SOCK_DGRAM, 0);
	if (tx < 0) {
		perror("tx socket");
		return 2;
	}
	setsockopt(tx, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
	if (bind(tx, (struct sockaddr *)&peer, sizeof(peer)) < 0) {
		perror("tx bind");
		return 2;
	}
	if (connect(tx, (struct sockaddr *)&srv, sizeof(srv)) < 0) {
		perror("tx connect");
		return 2;
	}

	/* warm up */
	for (i = 0; i < 2000; i++)
		if (send(tx, buf, sizeof(buf), 0) < 0 && errno != ENOBUFS)
			break;

	t0 = now();
	for (i = 0; i < pkts; i++) {
		if (send(tx, buf, sizeof(buf), 0) < 0 && errno != ENOBUFS) {
			perror("send");
			break;
		}
	}
	t1 = now();

	printf("%-8s n=%-5d pkts=%-8d elapsed=%.4fs  %.0f pps\n",
	       buggy ? "buggy" : "healthy", n, pkts, t1 - t0, pkts / (t1 - t0));

	for (i = 0; i < n; i++)
		close(fds[i]);
	close(tx);
	return 0;
}
