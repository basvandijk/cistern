/*
A stand-in for libuv's <uv.h> when building the Lean runtime for WASI, which libuv does not
support.

Of the runtime files that use libuv, only io.cpp is built for WASI. It needs libuv's error codes
and a few synchronous file system calls, so that is all this header provides. It follows libuv's
Unix conventions: error codes are negated errno values, and the calls wrap wasi-libc directly.
*/
#pragma once
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* io.cpp picks its errno mapping by libuv version. Since our codes are negated errno values,
   the newest mapping is the exact one. */
#define UV_VERSION_HEX 0x013401

/* io.cpp translates these errno values, but WASI does not define them. WASI never reports them
   either, so any value that differs from the real ones will do. */
#ifndef ENODATA
#define ENODATA 0x1001
#endif
#ifndef ENOSR
#define ENOSR 0x1002
#endif
#ifndef ENOSTR
#define ENOSTR 0x1003
#endif
#ifndef ETIME
#define ETIME 0x1004
#endif

#define UV_E2BIG (-E2BIG)
#define UV_EACCES (-EACCES)
#define UV_EADDRINUSE (-EADDRINUSE)
#define UV_EADDRNOTAVAIL (-EADDRNOTAVAIL)
#define UV_EAFNOSUPPORT (-EAFNOSUPPORT)
#define UV_EAGAIN (-EAGAIN)
#define UV_EBADF (-EBADF)
#define UV_EBUSY (-EBUSY)
#define UV_ECONNABORTED (-ECONNABORTED)
#define UV_ECONNREFUSED (-ECONNREFUSED)
#define UV_ECONNRESET (-ECONNRESET)
#define UV_EDESTADDRREQ (-EDESTADDRREQ)
#define UV_EEXIST (-EEXIST)
#define UV_EFAULT (-EFAULT)
#define UV_EFBIG (-EFBIG)
#define UV_EHOSTUNREACH (-EHOSTUNREACH)
#define UV_EILSEQ (-EILSEQ)
#define UV_EINTR (-EINTR)
#define UV_EINVAL (-EINVAL)
#define UV_EIO (-EIO)
#define UV_EISCONN (-EISCONN)
#define UV_EISDIR (-EISDIR)
#define UV_ELOOP (-ELOOP)
#define UV_EMFILE (-EMFILE)
#define UV_EMLINK (-EMLINK)
#define UV_EMSGSIZE (-EMSGSIZE)
#define UV_ENAMETOOLONG (-ENAMETOOLONG)
#define UV_ENETDOWN (-ENETDOWN)
#define UV_ENETUNREACH (-ENETUNREACH)
#define UV_ENFILE (-ENFILE)
#define UV_ENOBUFS (-ENOBUFS)
#define UV_ENODATA (-ENODATA)
#define UV_ENODEV (-ENODEV)
#define UV_ENOENT (-ENOENT)
#define UV_ENOEXEC (-ENOEXEC)
#define UV_ENOMEM (-ENOMEM)
#define UV_ENOPROTOOPT (-ENOPROTOOPT)
#define UV_ENOSPC (-ENOSPC)
#define UV_ENOSYS (-ENOSYS)
#define UV_ENOTCONN (-ENOTCONN)
#define UV_ENOTDIR (-ENOTDIR)
#define UV_ENOTEMPTY (-ENOTEMPTY)
#define UV_ENOTSOCK (-ENOTSOCK)
#define UV_ENOTSUP (-ENOTSUP)
#define UV_ENOTTY (-ENOTTY)
#define UV_ENXIO (-ENXIO)
#define UV_EPERM (-EPERM)
#define UV_EPIPE (-EPIPE)
#define UV_EPROTO (-EPROTO)
#define UV_EPROTONOSUPPORT (-EPROTONOSUPPORT)
#define UV_EPROTOTYPE (-EPROTOTYPE)
#define UV_ERANGE (-ERANGE)
#define UV_EROFS (-EROFS)
#define UV_ESPIPE (-ESPIPE)
#define UV_ESRCH (-ESRCH)
#define UV_ETIMEDOUT (-ETIMEDOUT)
#define UV_ETXTBSY (-ETXTBSY)
#define UV_EXDEV (-EXDEV)

static inline const char * uv_strerror(int err) { return strerror(-err); }

typedef struct timespec uv_timespec_t;
typedef struct stat uv_stat_t;

typedef struct {
    ssize_t result; /* a file descriptor, or a negative error code */
    const char * path;
    uv_stat_t statbuf;
} uv_fs_t;

/* io.cpp only makes synchronous calls, which take no event loop and no callback. */
static inline int uv__fs_result(uv_fs_t * req, int ret) {
    req->result = ret < 0 ? -errno : ret;
    return (int)req->result;
}
static inline int uv_fs_stat(void * loop, uv_fs_t * req, const char * path, void * cb) {
    return uv__fs_result(req, stat(path, &req->statbuf));
}
static inline int uv_fs_lstat(void * loop, uv_fs_t * req, const char * path, void * cb) {
    return uv__fs_result(req, lstat(path, &req->statbuf));
}
static inline int uv_fs_link(void * loop, uv_fs_t * req, const char * path, const char * new_path, void * cb) {
    return uv__fs_result(req, link(path, new_path));
}
static inline int uv_fs_unlink(void * loop, uv_fs_t * req, const char * path, void * cb) {
    return uv__fs_result(req, unlink(path));
}
static inline void uv_fs_req_cleanup(uv_fs_t * req) {}

/* wasi-libc has no mkstemp or mkdtemp, and WASI has no temporary directory. */
static inline int uv_os_tmpdir(char * buffer, size_t * size) { return UV_ENOSYS; }
static inline int uv_fs_mkstemp(void * loop, uv_fs_t * req, const char * tpl, void * cb) {
    return (int)(req->result = UV_ENOSYS);
}
static inline int uv_fs_mkdtemp(void * loop, uv_fs_t * req, const char * tpl, void * cb) {
    return (int)(req->result = UV_ENOSYS);
}
