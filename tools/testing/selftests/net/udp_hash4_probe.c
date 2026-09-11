// SPDX-License-Identifier: GPL-2.0
/*
 * Does connect(AF_UNSPEC) tear down a UDP socket's hash4 (4-tuple) entry?
 *
 * Two variants:
 *   bound   - bind() to a SPECIFIC address and port first.  Both
 *             SOCK_BINDADDR_LOCK and SOCK_BINDPORT_LOCK get set, which is
 *             the case under test.
 *   unbound - no bind().  Control: teardown is expected to happen here, so
 *             a difference between the two runs cannot be a tracing
 *             artefact.
 *
 * Writes phase markers to tracefs trace_marker so the kprobe trace can be
 * split by syscall.  Run as root inside the test VM.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <arpa/inet.h>

#define BIND_PORT  21001
#define PEER1_PORT 20001
#define PEER2_PORT 20002

static int mfd = -1;

static void mark(const char *m)
{
	if (mfd >= 0) {
		ssize_t n = write(mfd, m, strlen(m));

		(void)n;	/* best effort */
	}
	printf("%s\n", m);
	fflush(stdout);
}

static struct sockaddr_in mk(const char *ip, int port)
{
	struct sockaddr_in a;

	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	inet_pton(AF_INET, ip, &a.sin_addr);
	return a;
}

static int run6(int do_bind)
{
	struct sockaddr_in6 me, p1, p2;
	struct sockaddr unspec;
	int fd;

	memset(&unspec, 0, sizeof(unspec));
	unspec.sa_family = AF_UNSPEC;

	memset(&me, 0, sizeof(me)); me.sin6_family = AF_INET6;
	me.sin6_addr = in6addr_loopback; me.sin6_port = htons(BIND_PORT + 1);
	p1 = me; p1.sin6_port = htons(PEER1_PORT);
	p2 = me; p2.sin6_port = htons(PEER2_PORT);

	fd = socket(AF_INET6, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket6");
		return 1;
	}

	if (do_bind && bind(fd, (struct sockaddr *)&me, sizeof(me)) < 0) {
		perror("bind6");
		close(fd);
		return 1;
	}
	mark("MARK-connect1");
	if (connect(fd, (struct sockaddr *)&p1, sizeof(p1)) < 0)
		perror("connect1");
	mark("MARK-disconnect");
	if (connect(fd, &unspec, sizeof(unspec)) < 0)
		perror("disconnect");
	mark("MARK-connect2");
	if (connect(fd, (struct sockaddr *)&p2, sizeof(p2)) < 0)
		perror("connect2");
	mark("MARK-done");
	close(fd);
	return 0;
}

static int run(int do_bind)
{
	struct sockaddr_in me  = mk("127.0.0.1", BIND_PORT);
	struct sockaddr_in pe1 = mk("127.0.0.1", PEER1_PORT);
	struct sockaddr_in pe2 = mk("127.0.0.1", PEER2_PORT);
	struct sockaddr unspec;
	int fd;

	memset(&unspec, 0, sizeof(unspec));
	unspec.sa_family = AF_UNSPEC;

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("socket");
		return 1;
	}

	if (do_bind && bind(fd, (struct sockaddr *)&me, sizeof(me)) < 0) {
		perror("bind");
		close(fd);
		return 1;
	}

	mark("MARK-connect1");
	if (connect(fd, (struct sockaddr *)&pe1, sizeof(pe1)) < 0)
		perror("connect1");

	mark("MARK-disconnect");
	if (connect(fd, &unspec, sizeof(unspec)) < 0)
		perror("disconnect");

	mark("MARK-connect2");
	if (connect(fd, (struct sockaddr *)&pe2, sizeof(pe2)) < 0)
		perror("connect2");

	mark("MARK-done");
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	int do_bind = (argc > 1 && !strncmp(argv[1], "bound", 5));

	if (argc > 1 && strstr(argv[1], "6")) {
		mfd = open("/sys/kernel/tracing/trace_marker", O_WRONLY);
		if (mfd < 0)
			mfd = open("/sys/kernel/debug/tracing/trace_marker", O_WRONLY);
		return run6(do_bind);
	}

	mfd = open("/sys/kernel/tracing/trace_marker", O_WRONLY);
	if (mfd < 0)
		mfd = open("/sys/kernel/debug/tracing/trace_marker", O_WRONLY);

	return run(do_bind);
}
