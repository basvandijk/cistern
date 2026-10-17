/*
Replacements for the parts of the Lean runtime that are not built for WASI.

process.cpp, stack_overflow.cpp, openssl.cpp, and libuv.cpp with the files in uv/ need
processes, signals, OpenSSL and libuv, none of which exist on WASI or the Internet Computer.
This file defines those of their symbols that the rest of the runtime and Lean's `Init` library
refer to. Operations that cannot work return an IO error rather than abort.

It also stands in for the C++ exception runtime, see `__cxa_throw` below.
*/
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cxxabi.h> // declares the __cxa_* functions defined below
#include <typeinfo>
#include <unistd.h>
#include <lean/lean.h>
#include "runtime/exception.h"

static lean_obj_res unsupported(char const * what) {
    return lean_io_result_mk_error(lean_mk_io_error_unsupported_operation(ENOSYS, lean_mk_string(what)));
}

/* process.cpp. WASI keeps a current directory, so that part works. */

extern "C" LEAN_EXPORT lean_obj_res lean_io_process_get_current_dir() {
    char path[PATH_MAX];
    if (getcwd(path, PATH_MAX)) {
        return lean_io_result_mk_ok(lean_mk_string(path));
    } else {
        return lean_io_result_mk_error(lean_decode_io_error(errno, nullptr));
    }
}

extern "C" LEAN_EXPORT lean_obj_res lean_io_process_set_current_dir(b_lean_obj_arg path) {
    if (!chdir(lean_string_cstr(path))) {
        return lean_io_result_mk_ok(lean_box(0));
    } else {
        return lean_io_result_mk_error(lean_decode_io_error(errno, path));
    }
}

// WASI has neither process nor thread identifiers.
extern "C" LEAN_EXPORT uint32_t lean_io_process_get_pid() { return 0; }
extern "C" LEAN_EXPORT uint64_t lean_io_get_tid() { return 0; }

extern "C" LEAN_EXPORT lean_obj_res lean_io_process_spawn(lean_obj_arg args) {
    lean_dec(args);
    return unsupported("spawning processes is not supported on WASI");
}

// As spawning always fails, the remaining functions never receive a child.
extern "C" LEAN_EXPORT lean_obj_res lean_io_process_child_wait(b_lean_obj_arg, b_lean_obj_arg) {
    return unsupported("there are no child processes on WASI");
}

extern "C" LEAN_EXPORT lean_obj_res lean_io_process_child_try_wait(b_lean_obj_arg, b_lean_obj_arg) {
    return unsupported("there are no child processes on WASI");
}

extern "C" LEAN_EXPORT lean_obj_res lean_io_process_child_kill(b_lean_obj_arg, b_lean_obj_arg) {
    return unsupported("there are no child processes on WASI");
}

extern "C" LEAN_EXPORT lean_obj_res lean_io_process_child_take_stdin(b_lean_obj_arg, lean_obj_arg child) {
    lean_dec(child);
    return unsupported("there are no child processes on WASI");
}

extern "C" LEAN_EXPORT uint32_t lean_io_process_child_pid(b_lean_obj_arg, b_lean_obj_arg) {
    lean_internal_panic("there are no child processes on WASI");
}

/* libuv.cpp. The generated `main` calls this; libuv only copies `argv` so that it can change
   the process title. */
extern "C" LEAN_EXPORT char ** lean_setup_args(int, char ** argv) { return argv; }

namespace lean {
void initialize_process() {}
void finalize_process() {}
// A stack overflow traps instead (the stack sits at the bottom of linear memory, see `ldflags`).
void initialize_stack_overflow() {}
void finalize_stack_overflow() {}
}

/* io.cpp locks files with `flock`, which wasi-libc declares but does not define. Weak, in case
   a later wasi-libc does. */
extern "C" __attribute__((weak)) int flock(int, int) {
    errno = ENOSYS;
    return -1;
}

/* The C++ exception runtime.

   The runtime is compiled with -fexceptions so that its `throw`s compile. Without WebAssembly
   exception handling (which the Internet Computer does not support), LLVM drops all `catch`
   blocks, so a `throw` can only end the program, as an uncaught exception would. libc++abi for
   WASI is built without exception support, so we define the entry points that the compiled
   `throw`s and (unreachable) handlers call: they report what was thrown and abort, which traps.
   On the Internet Computer a trap rolls back the current message. */

extern "C" void * __cxa_allocate_exception(size_t size) noexcept {
    // Never freed: the program is about to end.
    void * p = malloc(size);
    if (!p) abort();
    return p;
}

// The message of the Lean runtime's own exceptions; `type` is the exact type of `obj`.
static char const * lean_exception_message(void * obj, std::type_info const & type) {
    if (type == typeid(lean::exception)) return static_cast<lean::exception *>(obj)->what();
    if (type == typeid(lean::stack_space_exception)) return static_cast<lean::stack_space_exception *>(obj)->what();
    if (type == typeid(lean::memory_exception)) return static_cast<lean::memory_exception *>(obj)->what();
    if (type == typeid(lean::heartbeat_exception)) return static_cast<lean::heartbeat_exception *>(obj)->what();
    return nullptr;
}

// (In the WebAssembly C++ ABI, destructors return `this`.)
extern "C" void __cxa_throw(void * obj, std::type_info * type, void * (*)(void *)) {
    char const * msg = lean_exception_message(obj, *type);
    // The type name stays mangled: the demangler would add over 100 KB of code.
    fprintf(stderr, "uncaught C++ exception of type %s%s%s\n", type->name(), msg ? ": " : "", msg ? msg : "");
    abort();
}

extern "C" void * __cxa_begin_catch(void *) noexcept {
    abort();
}
