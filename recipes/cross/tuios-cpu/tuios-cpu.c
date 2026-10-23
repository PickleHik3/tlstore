/*
 * tuios-cpu — prints the CPU counters of /proc/stat on a loop, for tuios's CPU meter.
 *
 *   tuios-cpu [interval in milliseconds, default 1000]
 *
 * A Termux uid cannot read /proc/stat on Android (Permission denied); the shell uid can. This runs
 * as that uid through Termux:Launcher's privileged lane (tl-priv; docs/maintainer/catalog.md,
 * "Privileged items") and tuios reads what it prints. Each sample is the "cpu" and "cpuN" lines of
 * /proc/stat exactly as the kernel writes them, then one line holding only ".", flushed at once.
 * Through the lane's pty the line ends are \r\n; the reader trims them.
 *
 * It ends when it cannot write any more (the reader closed its end: SIGPIPE, or EIO on the pty),
 * and when /proc/stat cannot be read (exit 1, with a message on stderr).
 *
 * Bionic only, linked -static: no prefix, so one build serves every edition.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    long ms = 1000;
    if (argc > 2) {
        fputs("usage: tuios-cpu [interval in milliseconds]\n", stderr);
        return 2;
    }
    if (argc == 2) {
        char *end;
        ms = strtol(argv[1], &end, 10);
        if (*argv[1] == '\0' || *end != '\0' || ms < 100 || ms > 60000) {
            fputs("tuios-cpu: the interval is 100 to 60000 milliseconds\n", stderr);
            return 2;
        }
    }
    for (;;) {
        FILE *f = fopen("/proc/stat", "r");
        if (!f) {
            fprintf(stderr, "tuios-cpu: /proc/stat: %s\n", strerror(errno));
            return 1;
        }
        char line[512];
        while (fgets(line, sizeof line, f)) {
            if (strncmp(line, "cpu", 3) != 0) break;   /* the cpu lines come first */
            if (fputs(line, stdout) == EOF) return 0;
        }
        fclose(f);
        if (fputs(".\n", stdout) == EOF || fflush(stdout) == EOF) return 0;
        struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
        nanosleep(&ts, NULL);
    }
}
