// T1: Can a small SO_SNDBUF produce EAGAIN on an unprivileged ICMP SOCK_DGRAM socket?
// usage: t1_sndbuf [sndbuf] [count] [payload] [dest]
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/ip_icmp.h>
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
  int want = argc > 1 ? atoi(argv[1]) : 128;
  int n = argc > 2 ? atoi(argv[2]) : 2000;
  int payload = argc > 3 ? atoi(argv[3]) : 56;
  const char *dst = argc > 4 ? argv[4] : "1.1.1.1";

  int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
  if (fd < 0) { perror("socket"); return 1; }
  int got = 0;
  socklen_t sl = sizeof(got);
  getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &got, &sl);
  printf("default SO_SNDBUF = %d\n", got);
  if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &want, sizeof(want)) != 0)
    printf("setsockopt SO_SNDBUF(%d) failed: %s\n", want, strerror(errno));
  sl = sizeof(got);
  getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &got, &sl);
  printf("requested SO_SNDBUF = %d, kernel reports = %d\n", want, got);
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
  ic->icmp_code = 0;
  ic->icmp_id = htons((uint16_t)getpid());

  int errcount[256];
  memset(errcount, 0, sizeof(errcount));
  int ok = 0, othererr = 0;
  double t0 = now();
  for (int i = 0; i < n; i++) {
    ic->icmp_seq = htons((uint16_t)i);
    ic->icmp_cksum = 0;
    ic->icmp_cksum = cksum(buf, (int)len);
    ssize_t r = sendto(fd, buf, len, 0, (struct sockaddr *)&sa, sizeof(sa));
    if (r >= 0) ok++;
    else { int e = errno; if (e < 256) errcount[e]++; else othererr++; }
  }
  double dt = now() - t0;
  printf("msg = %zu bytes, sends = %d, ok = %d, elapsed = %.4fs (%.0f sends/s)\n",
         len, n, ok, dt, n / dt);
  for (int e = 0; e < 256; e++)
    if (errcount[e]) printf("  errno %d (%s): %d\n", e, strerror(e), errcount[e]);
  if (othererr) printf("  errno >=256: %d\n", othererr);
  close(fd);
  return 0;
}
