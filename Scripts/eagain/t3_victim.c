// T3: model SwiftFTR's send-retry loop against background interface congestion.
//
// One socket, one 40-probe unpaced burst every `gap` ms, exactly like a trace.
// On a transient errno it retries the way SendRetry.swift does: poll(POLLOUT)
// for EAGAIN, a 1 ms nap for ENOBUFS, giving up at `budget` seconds shared
// across the whole burst. Reports, per burst, how much of the budget was spent
// and whether the burst would have been aborted.
//
// Run alongside a load generator (t2_load) to create the congestion.
//
// usage: t3_victim -b burst -r rounds -g gapms -p payload -d dest -B budget_s
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/ip_icmp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

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

int main(int argc, char **argv) {
  int burst = 40, rounds = 100, gapms = 200, payload = 56;
  double budget = 0.25;
  const char *dst = "1.1.1.1";
  int c;
  while ((c = getopt(argc, argv, "b:r:g:p:d:B:")) != -1) {
    switch (c) {
      case 'b': burst = atoi(optarg); break;
      case 'r': rounds = atoi(optarg); break;
      case 'g': gapms = atoi(optarg); break;
      case 'p': payload = atoi(optarg); break;
      case 'd': dst = optarg; break;
      case 'B': budget = atof(optarg); break;
      default: return 2;
    }
  }
  printf("victim: burst=%d rounds=%d gap=%dms payload=%d dest=%s budget=%.3fs\n",
         burst, rounds, gapms, payload, dst, budget);

  int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
  if (fd < 0) { perror("socket"); return 1; }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_len = sizeof(sa);
  inet_pton(AF_INET, dst, &sa.sin_addr);

  size_t len = 8 + (size_t)payload;
  unsigned char *buf = calloc(1, len);
  struct icmp *ic = (struct icmp *)buf;
  ic->icmp_type = ICMP_ECHO;
  ic->icmp_id = htons((uint16_t)getpid());

  int clean = 0, retried = 0, aborted = 0;
  long probes = 0, retries = 0;
  int errhist[256];
  memset(errhist, 0, sizeof(errhist));
  double worst_spent = 0, sum_spent = 0;
  double *spent_list = calloc((size_t)rounds, sizeof(double));
  int nspent = 0;
  uint16_t seq = 0;

  for (int r = 0; r < rounds; r++) {
    double t0 = now();
    double deadline = t0 + budget;
    int burst_retried = 0, burst_aborted = 0;

    for (int i = 0; i < burst && !burst_aborted; i++) {
      ic->icmp_seq = htons(seq++);
      ic->icmp_cksum = 0;
      ic->icmp_cksum = cksum(buf, (int)len);
      for (;;) {
        ssize_t rc = sendto(fd, buf, len, 0, (struct sockaddr *)&sa, sizeof(sa));
        probes++;
        if (rc >= 0) break;
        int e = errno;
        if (e < 256) errhist[e]++;
        if (e != EAGAIN && e != EWOULDBLOCK && e != ENOBUFS) {
          fprintf(stderr, "hard error %d (%s)\n", e, strerror(e));
          burst_aborted = 1;
          break;
        }
        burst_retried = 1;
        retries++;
        double remaining = deadline - now();
        if (remaining <= 0) { burst_aborted = 1; break; }
        if (e == ENOBUFS) {
          double nap = remaining < 0.001 ? remaining : 0.001;
          usleep((useconds_t)(nap * 1e6) > 0 ? (useconds_t)(nap * 1e6) : 1);
        } else {
          struct pollfd pfd = {.fd = fd, .events = POLLOUT, .revents = 0};
          int ms = (int)(remaining * 1000 + 0.999);
          poll(&pfd, 1, ms < 1 ? 1 : ms);
        }
      }
    }
    double spent = now() - t0;
    if (burst_retried) {
      sum_spent += spent;
      spent_list[nspent++] = spent;
      if (spent > worst_spent) worst_spent = spent;
    }
    if (burst_aborted) aborted++;
    else if (burst_retried) retried++;
    else clean++;
    if (gapms > 0) usleep((useconds_t)gapms * 1000);
  }

  printf("bursts: %d clean, %d completed after retrying, %d ABORTED (budget exhausted)\n",
         clean, retried, aborted);
  printf("probes attempted (incl. retries): %ld, retry attempts: %ld\n", probes, retries);
  for (int e = 0; e < 256; e++)
    if (errhist[e]) printf("  errno %d (%s): %d\n", e, strerror(e), errhist[e]);
  if (nspent > 0) {
    for (int a = 1; a < nspent; a++) {
      double v = spent_list[a];
      int b = a - 1;
      while (b >= 0 && spent_list[b] > v) { spent_list[b + 1] = spent_list[b]; b--; }
      spent_list[b + 1] = v;
    }
    printf("burst wall time when retries happened (s): p50=%.4f p90=%.4f max=%.4f mean=%.4f\n",
           spent_list[nspent / 2], spent_list[(int)(nspent * 0.9)], worst_spent,
           sum_spent / nspent);
  }
  close(fd);
  return 0;
}
