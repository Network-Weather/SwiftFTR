// T2: try to provoke EAGAIN/ENOBUFS on unprivileged ICMP SOCK_DGRAM sockets
// under realistic and unrealistic load, and measure how long the condition lasts.
//
// usage: t2_load -t threads -b burst -r rounds -g gapus -p payload -d dest[,dest...]
//                [-i ifname] [-P] [-D ndests]
//   -P : after a transient errno, poll(POLLOUT) and report how long until writable
//   -D : instead of one dest, sweep N synthetic destinations
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/ip_icmp.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef IP_BOUND_IF
#define IP_BOUND_IF 25
#endif

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint16_t cksum(const void *b, int n) {
  const uint16_t *p = b;
  uint32_t s = 0;
  while (n > 1) { s += *p++; n -= 2; }
  if (n) s += *(const uint8_t *)p;
  s = (s >> 16) + (s & 0xffff);
  s += (s >> 16);
  return (uint16_t)~s;
}

static int nthreads = 8, burst = 40, rounds = 200, gapus = 0, payload = 56;
static int ndests = 1, dopoll = 0;
static const char *base_dest = "1.1.1.1";
static const char *ifname = NULL;
static double t_start;

#define MAXEV 4096
typedef struct {
  double t;        // when the failure happened
  int err;         // errno
  double recover;  // seconds until the next successful send on this socket
  double pollms;   // poll(POLLOUT) wait until writable, -1 if not measured
} ev_t;

typedef struct {
  int id;
  long ok, fail;
  int errhist[256];
  ev_t ev[MAXEV];
  int nev;
  double maxrecover;
} th_t;

static void *worker(void *arg) {
  th_t *st = arg;
  int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
  if (fd < 0) { perror("socket"); return NULL; }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  if (ifname) {
    unsigned idx = if_nametoindex(ifname);
    if (idx == 0) { fprintf(stderr, "bad ifname %s\n", ifname); return NULL; }
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof(idx)) != 0)
      fprintf(stderr, "IP_BOUND_IF(%s) failed: %s\n", ifname, strerror(errno));
  }

  struct in_addr base;
  inet_pton(AF_INET, base_dest, &base);
  uint32_t basehost = ntohl(base.s_addr);

  size_t len = 8 + (size_t)payload;
  unsigned char *buf = calloc(1, len);
  struct icmp *ic = (struct icmp *)buf;
  ic->icmp_type = ICMP_ECHO;
  ic->icmp_code = 0;
  ic->icmp_id = htons((uint16_t)(getpid() + st->id));

  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_len = sizeof(sa);

  int pending_ev = -1;  // index of an event awaiting a recovery measurement
  uint32_t seq = 0;

  for (int r = 0; r < rounds; r++) {
    for (int i = 0; i < burst; i++) {
      sa.sin_addr.s_addr = htonl(basehost + (uint32_t)(seq % (uint32_t)ndests));
      ic->icmp_seq = htons((uint16_t)seq++);
      ic->icmp_cksum = 0;
      ic->icmp_cksum = cksum(buf, (int)len);
      ssize_t rc = sendto(fd, buf, len, 0, (struct sockaddr *)&sa, sizeof(sa));
      double t = now() - t_start;
      if (rc >= 0) {
        st->ok++;
        if (pending_ev >= 0) {
          for (int k = pending_ev; k < st->nev; k++) {
            if (st->ev[k].recover >= 0) continue;
            st->ev[k].recover = t - st->ev[k].t;
            if (st->ev[k].recover > st->maxrecover) st->maxrecover = st->ev[k].recover;
          }
          pending_ev = -1;
        }
      } else {
        int e = errno;
        st->fail++;
        if (e < 256) st->errhist[e]++;
        if (st->nev < MAXEV) {
          ev_t *ev = &st->ev[st->nev];
          ev->t = t;
          ev->err = e;
          ev->recover = -1;
          ev->pollms = -1;
          if (dopoll) {
            struct pollfd pfd = {.fd = fd, .events = POLLOUT, .revents = 0};
            double p0 = now();
            int pr = poll(&pfd, 1, 1000);
            ev->pollms = (now() - p0) * 1000.0;
            if (pr <= 0) ev->pollms = -2;  // timed out / error
          }
          if (pending_ev < 0) pending_ev = st->nev;
          st->nev++;
        }
      }
    }
    if (gapus > 0) usleep((useconds_t)gapus);
  }
  close(fd);
  return NULL;
}

int main(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "t:b:r:g:p:d:i:D:P")) != -1) {
    switch (c) {
      case 't': nthreads = atoi(optarg); break;
      case 'b': burst = atoi(optarg); break;
      case 'r': rounds = atoi(optarg); break;
      case 'g': gapus = atoi(optarg); break;
      case 'p': payload = atoi(optarg); break;
      case 'd': base_dest = optarg; break;
      case 'i': ifname = optarg; break;
      case 'D': ndests = atoi(optarg); break;
      case 'P': dopoll = 1; break;
      default: fprintf(stderr, "bad arg\n"); return 2;
    }
  }
  printf("threads=%d burst=%d rounds=%d gap=%dus payload=%d dest=%s ndests=%d if=%s poll=%d\n",
         nthreads, burst, rounds, gapus, payload, base_dest, ndests,
         ifname ? ifname : "(default)", dopoll);

  th_t *st = calloc((size_t)nthreads, sizeof(th_t));
  pthread_t *th = calloc((size_t)nthreads, sizeof(pthread_t));
  t_start = now();
  for (int i = 0; i < nthreads; i++) {
    st[i].id = i;
    pthread_create(&th[i], NULL, worker, &st[i]);
  }
  for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
  double dt = now() - t_start;

  long ok = 0, fail = 0;
  int tot[256];
  memset(tot, 0, sizeof(tot));
  double maxrec = 0;
  for (int i = 0; i < nthreads; i++) {
    ok += st[i].ok;
    fail += st[i].fail;
    for (int e = 0; e < 256; e++) tot[e] += st[i].errhist[e];
    if (st[i].maxrecover > maxrec) maxrec = st[i].maxrecover;
  }
  printf("elapsed %.3fs  sends=%ld  ok=%ld  fail=%ld  rate=%.0f pkt/s\n",
         dt, ok + fail, ok, fail, (double)(ok + fail) / dt);
  for (int e = 0; e < 256; e++)
    if (tot[e]) printf("  errno %d (%s): %d\n", e, strerror(e), tot[e]);
  if (fail == 0) { printf("  no send errors\n"); return 0; }
  printf("  longest gap from a failure to the next success on that socket: %.6fs\n", maxrec);

  // recovery-time distribution
  int nrec = 0;
  for (int i = 0; i < nthreads; i++)
    for (int j = 0; j < st[i].nev; j++)
      if (st[i].ev[j].recover >= 0) nrec++;
  if (nrec > 0) {
    double *rec = malloc((size_t)nrec * sizeof(double));
    int k = 0;
    for (int i = 0; i < nthreads; i++)
      for (int j = 0; j < st[i].nev; j++)
        if (st[i].ev[j].recover >= 0) rec[k++] = st[i].ev[j].recover;
    for (int a = 1; a < nrec; a++) {  // insertion sort, small n
      double v = rec[a];
      int b = a - 1;
      while (b >= 0 && rec[b] > v) { rec[b + 1] = rec[b]; b--; }
      rec[b + 1] = v;
    }
    printf("  recovery (s) over %d measured failures: p50=%.6f p90=%.6f p99=%.6f max=%.6f\n",
           nrec, rec[nrec / 2], rec[(int)(nrec * 0.9)], rec[(int)(nrec * 0.99)], rec[nrec - 1]);
    int over250 = 0;
    for (int a = 0; a < nrec; a++)
      if (rec[a] > 0.25) over250++;
    printf("  failures whose recovery exceeded 250 ms: %d / %d (%.2f%%)\n", over250, nrec,
           100.0 * over250 / nrec);
  }

  printf("  first 25 failure events (t=s since start, recover=s to next success, poll=ms):\n");
  int shown = 0;
  for (int i = 0; i < nthreads && shown < 25; i++)
    for (int j = 0; j < st[i].nev && shown < 25; j++, shown++)
      printf("    th%d t=%.6f errno=%d recover=%.6f poll=%.3f\n", i, st[i].ev[j].t,
             st[i].ev[j].err, st[i].ev[j].recover, st[i].ev[j].pollms);
  return 0;
}
