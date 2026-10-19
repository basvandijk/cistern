/*
WASI (wasi_snapshot_preview1), the system interface that wasi-libc uses, implemented with the
Internet Computer's System API (ic0.h). With it, the canister imports nothing but ic0.

How this links. wasi-libc (libc-bottom-half/sources/__wasilibc_real.c) calls each WASI function
through one that it declares, but does not define, with the attributes of a Wasm import:

  int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t, int32_t, int32_t, int32_t)
      __attribute__((__import_module__("wasi_snapshot_preview1"), __import_name__("fd_write")));

wasm-ld imports such a function only if no object file defines it, so the definitions below
replace the imports. They have exactly the declared types. With another type, wasm-ld would only
warn (hence -Wl,--fatal-warnings in the link) and call a stub that traps. A WASI function that is
missing here becomes an import, without an error from wasm-ld, which is why the build checks that
all imports are from ic0.

These are the WASI functions that the link needs, for Lean's runtime and Init, libc++ and
wasi-libc:

  environ_*         The environment is empty.
  clock_time_get    The realtime and the monotonic clock are ic0.time, the time of the current
                    block, which stays the same during a message. The CPU-time clocks are EINVAL.
  fd_fdstat_get     stdin, stdout and stderr are character devices that cannot seek or tell,
                    which is what isatty() checks, so that stdout is line buffered.
  fd_write          stdout and stderr: each line goes to the canister's log with ic0.debug_print,
                    without its newline, as one record, or, if it is longer than LINE_CAPACITY
                    bytes, as records of at most that many, cut between UTF-8 characters. The
                    rest of a line waits for its newline, for wasi_ic0_flush at the end of a
                    message, or for wasi_ic0_trap, which exit(), abort() and canister.c's failed
                    initialization call. A trap of the IC's own, such as a stack overflow, loses
                    it.
  fd_read           stdin is at its end.
  fd_seek           stdin, stdout and stderr cannot seek (ESPIPE).
  fd_close          Closing stdin, stdout or stderr does nothing.
  fd_prestat_*      There are no preopened directories: EBADF ends wasi-libc's search for them,
                    and opening a file then fails with ENOENT.
  proc_exit         ic0.trap: a canister cannot exit.
  random_get        One fixed sequence (splitmix64 from 0), the same in every canister. It
                    continues across the messages whose changes to memory the IC keeps, and starts
                    again with an upgrade, which starts with new memory: canister_init and
                    canister_post_upgrade take the first 8 bytes, for Init's random generator.
                    A query starts where the last message whose changes the IC kept left it, as
                    the IC discards a query's changes. A canister gets randomness from the
                    management canister's raw_rand, which takes a call to another canister.

Other file descriptors than 0, 1 and 2 are EBADF.
*/
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wasi/api.h> // the WASI types and constants
#include "ic0.h"
#include "wasi.h"

/* The WASI functions take addresses as i32. */
#define PTR(type, address) ((type *)(uintptr_t)(address))

static bool is_stdio(int32_t fd) { return fd >= 0 && fd <= 2; }

/* Output */

#define LINE_CAPACITY 4096

/* What stdout and stderr have written since their last newline, and not printed yet. `continued`:
   a part of the line has been printed already. */
static struct line {
    bool continued;
    size_t length;
    char text[LINE_CAPACITY];
} g_lines[2];

/* The start of the last line that stderr printed and that is not empty, for the message of a
   trap. */
#define LAST_ERROR_CAPACITY 1024
static size_t g_last_error_length;
static char g_last_error[LAST_ERROR_CAPACITY];

/* g_last_error has the start of its line, as far as it fits. */
static bool g_last_error_full;

/* How many bytes at the end of text[0, n) start a UTF-8 character that they do not complete:
   0 to 3. */
static size_t incomplete_utf8(char const * text, size_t n) {
    for (size_t k = 1; k <= 3 && k <= n; k++) {
        unsigned char c = (unsigned char)text[n - k];
        if ((c & 0xC0) == 0x80) continue; // a continuation byte
        size_t need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        return need > k ? k : 0;
    }
    return 0;
}

/* Prints the first n bytes that fd (1 or 2) has buffered as a log record, and keeps the rest. */
static void print_part(int32_t fd, size_t n) {
    struct line * line = &g_lines[fd - 1];
    ic0_debug_print(line->text, n);
    if (fd == 2 && n > 0) {
        if (!line->continued) { // a new line
            g_last_error_length = 0;
            g_last_error_full = false;
        }
        if (!g_last_error_full) {
            size_t room = LAST_ERROR_CAPACITY - g_last_error_length;
            size_t k = n;
            if (k > room) {
                k = room - incomplete_utf8(line->text, room);
                g_last_error_full = true;
            }
            memcpy(g_last_error + g_last_error_length, line->text, k);
            g_last_error_length += k;
        }
    }
    memmove(line->text, line->text + n, line->length - n);
    line->length -= n;
}

/* Prints what fd (1 or 2) has buffered as a log record, and empties the buffer. */
static void print(int32_t fd) { print_part(fd, g_lines[fd - 1].length); }

/* Prints the part of a line that fd (1 or 2) has buffered, if there is one. */
static void print_rest(int32_t fd) {
    struct line * line = &g_lines[fd - 1];
    if (line->length > 0) {
        print(fd);
        line->continued = true;
    }
}

static void write_lines(int32_t fd, char const * p, size_t n) {
    struct line * line = &g_lines[fd - 1];
    while (n > 0) {
        char const * newline = memchr(p, '\n', n);
        size_t length = newline ? (size_t)(newline - p) : n;
        n -= length;
        while (length > 0) {
            size_t k = LINE_CAPACITY - line->length;
            if (k > length) k = length;
            memcpy(line->text + line->length, p, k);
            line->length += k;
            p += k;
            length -= k;
            if (line->length == LINE_CAPACITY) {
                // Up to the last whole character, so that each record is valid UTF-8.
                print_part(fd, LINE_CAPACITY - incomplete_utf8(line->text, LINE_CAPACITY));
                line->continued = true;
            }
        }
        if (newline) {
            // What is left of the line, or an empty line.
            if (line->length > 0 || !line->continued) print(fd);
            line->continued = false;
            p++;
            n--;
        }
    }
}

void wasi_ic0_flush(void) {
    print_rest(1);
    print_rest(2);
    g_last_error_length = 0;
    g_last_error_full = false;
}

_Noreturn void wasi_ic0_trap(char const * what) {
    print_rest(1);
    print_rest(2);
    char message[128 + LAST_ERROR_CAPACITY];
    int n = g_last_error_length == 0
        ? snprintf(message, sizeof message, "%s", what)
        : snprintf(message, sizeof message, "%s: %.*s", what, (int)g_last_error_length, g_last_error);
    ic0_trap(message, (size_t)n < sizeof message ? (size_t)n : sizeof message - 1);
}

/* abort() traps with a message, where wasi-libc's executes `unreachable`. Among others, the
   runtime's __cxa_throw (../../lean-wasm/runtime/wasi-stubs.cpp) calls it, after printing the
   exception. Unlike exit(), it does not flush stdio, so it would lose the start of a line that
   stdout has buffered; wasi-libc without threads has no lock that the fflush could wait for.
   wasi-libc's abort.c.obj defines nothing else, so this keeps it out of the link. */
_Noreturn void abort(void) {
    fflush(stdout);
    wasi_ic0_trap("abort()");
}

/* random_get: splitmix64 (Steele, Lea and Flood), with the constants of Vigna's splitmix64.c. */

static uint64_t g_random_state;

static uint64_t splitmix64(void) {
    uint64_t z = (g_random_state += UINT64_C(0x9E3779B97F4A7C15));
    z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
    return z ^ (z >> 31);
}

/* The WASI functions, with the types of __wasilibc_real.c. All but proc_exit return a
   __wasi_errno_t (a uint16_t) as i32. */

unsigned long wasi_ic0_time_calls;

int32_t __imported_wasi_snapshot_preview1_clock_time_get(int32_t id, int64_t precision,
                                                         int32_t time) {
    (void)precision;
    if (id != __WASI_CLOCKID_REALTIME && id != __WASI_CLOCKID_MONOTONIC) return __WASI_ERRNO_INVAL;
    wasi_ic0_time_calls++;
    *PTR(__wasi_timestamp_t, time) = ic0_time();
    return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_environ_get(int32_t environ, int32_t environ_buf) {
    (void)environ;
    (void)environ_buf;
    return __WASI_ERRNO_SUCCESS; // there is nothing to write
}

int32_t __imported_wasi_snapshot_preview1_environ_sizes_get(int32_t count, int32_t buf_size) {
    *PTR(__wasi_size_t, count) = 0;
    *PTR(__wasi_size_t, buf_size) = 0;
    return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_close(int32_t fd) {
    return is_stdio(fd) ? __WASI_ERRNO_SUCCESS : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_get(int32_t fd, int32_t stat) {
    if (!is_stdio(fd)) return __WASI_ERRNO_BADF;
    __wasi_fdstat_t * s = PTR(__wasi_fdstat_t, stat);
    s->fs_filetype = __WASI_FILETYPE_CHARACTER_DEVICE;
    s->fs_flags = 0;
    // Without __WASI_RIGHTS_FD_SEEK and __WASI_RIGHTS_FD_TELL.
    s->fs_rights_base = fd == 0 ? __WASI_RIGHTS_FD_READ : __WASI_RIGHTS_FD_WRITE;
    s->fs_rights_inheriting = 0;
    return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_prestat_get(int32_t fd, int32_t prestat) {
    (void)fd;
    (void)prestat;
    return __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_prestat_dir_name(int32_t fd, int32_t path,
                                                              int32_t path_len) {
    (void)fd;
    (void)path;
    (void)path_len;
    return __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_read(int32_t fd, int32_t iovs, int32_t iovs_len,
                                                  int32_t nread) {
    (void)iovs;
    (void)iovs_len;
    if (fd != 0) return __WASI_ERRNO_BADF;
    *PTR(__wasi_size_t, nread) = 0;
    return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_seek(int32_t fd, int64_t offset, int32_t whence,
                                                  int32_t newoffset) {
    (void)offset;
    (void)whence;
    (void)newoffset;
    return is_stdio(fd) ? __WASI_ERRNO_SPIPE : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t fd, int32_t iovs, int32_t iovs_len,
                                                   int32_t nwritten) {
    if (fd != 1 && fd != 2) return __WASI_ERRNO_BADF;
    __wasi_ciovec_t const * iov = PTR(__wasi_ciovec_t const, iovs);
    size_t total = 0;
    for (int32_t i = 0; i < iovs_len; i++) {
        write_lines(fd, (char const *)iov[i].buf, iov[i].buf_len);
        total += iov[i].buf_len;
    }
    *PTR(__wasi_size_t, nwritten) = total;
    return __WASI_ERRNO_SUCCESS;
}

_Noreturn void __imported_wasi_snapshot_preview1_proc_exit(int32_t code) {
    char what[sizeof "exit(4294967295)"];
    snprintf(what, sizeof what, "exit(%" PRIu32 ")", (uint32_t)code);
    wasi_ic0_trap(what);
}

int32_t __imported_wasi_snapshot_preview1_random_get(int32_t buf, int32_t buf_len) {
    uint8_t * p = PTR(uint8_t, buf);
    for (size_t n = (uint32_t)buf_len; n > 0;) {
        uint64_t r = splitmix64();
        size_t k = n < sizeof r ? n : sizeof r;
        memcpy(p, &r, k);
        p += k;
        n -= k;
    }
    return __WASI_ERRNO_SUCCESS;
}
