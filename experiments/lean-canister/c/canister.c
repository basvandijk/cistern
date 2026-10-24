/*
The canister's entry points: the exported functions that the IC calls.

canister_init and canister_post_upgrade initialize Lean: an upgrade starts with new memory. That
also creates the notes, the state of Canister.lean. canister_pre_upgrade refuses an upgrade while
calls to other canisters are outstanding. The query and update methods are the functions that
Canister.lean exports, which decode their Candid argument and reply or reject; they catch Lean's
errors themselves. add_then_exit traps instead, as exit() calls wasi.c's proc_exit. A method that
calls another canister returns before it replies: the reply comes from a callback, in a later
message (see ic0.c). The exports must be those of Interface.lean's methods, which the check
lean-canister-interface (nix/did.nix) compares.

Each entry point that returns ends by writing to the canister's log how many instructions its
message has taken (ic0.performance_counter), and how many ic0.time calls clock_time_get has made
for it (see wasi.c); one that traps logs no count. So does a callback (ic0.c). The harness,
measure.py, reads the log to learn what a message costs. The count cannot include the logging
itself, which takes some thousand instructions more.
*/
#include <inttypes.h>
#include <stdio.h>
#include <lean/lean.h>
#include "canister.h"
#include "ic0.h"
#include "wasi.h"

/* Runs the C++ constructors. wasm-ld generates it. As this file calls it, wasm-ld does not wrap
   every export in a function that runs the constructors and destructors on each call (lld's
   createCommandExportWrappers). */
void __wasm_call_ctors(void);

/* The Lean runtime; lean.h does not declare it. */
void lean_initialize_runtime_module(void);

/* Canister.lean */
lean_object * runtime_initialize_Canister(uint8_t builtin);
lean_object * cistern_greet(void);
lean_object * cistern_hello(void);
lean_object * cistern_probe(void);
lean_object * cistern_add(void);
lean_object * cistern_add_then_exit(void);
lean_object * cistern_add_then_throw(void);
lean_object * cistern_notes(void);
lean_object * cistern_random(void);
lean_object * cistern_greet_via(void);
lean_object * cistern_add_twice(void);
lean_object * cistern_add_both(void);
lean_object * cistern_call_raw(void);
lean_object * cistern_call_then_exit(void);
lean_object * cistern_call_then_throw(void);
lean_object * cistern_oneway_add(void);
lean_object * cistern_call_in_query(void);

/* ic0.c */
uint32_t cistern_ic0_outstanding_calls(void);

/* Ends an entry point (see canister.h). Hands what stdout has buffered (it is line buffered, so
   at most part of a line) and the rest of any line to the log, then logs
   "<entry>: <n> instructions, <k> ic0.time calls<details>". */
void canister_finish(char const * entry, unsigned long time_calls, char const * details) {
    fflush(stdout);
    fflush(stderr);
    wasi_ic0_flush();
    uint64_t instructions = ic0_performance_counter(0);
    char line[256];
    int n = snprintf(line, sizeof line, "%s: %" PRIu64 " instructions, %lu ic0.time calls%s",
                     entry, instructions, wasi_ic0_time_calls - time_calls, details);
    ic0_debug_print(line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
}

/* What a Lean program does before its `main`: crt1's _start runs the C++ constructors, and
   Lean's generated `main` runs runtime_initialize_Canister, which calls
   lean_initialize_runtime_module and the runtime initializers of the imported modules,
   lean_io_mark_end_initialization, and then lean_init_task_manager. That `main` also calls
   lean_setup_args, which does nothing here (Lean's src/runtime/wasi/stubs.cpp).

   The task manager runs the tasks of Lean's `Task` and `IO.Promise`. This runtime has no threads,
   so the manager is cooperative (see lean_run_pending_tasks in lean.h): spawning a task, or
   resolving the promise that a continuation waits for, only queues it; the queue runs on this
   thread when Lean waits for a task, and when the host calls lean_run_pending_tasks. Every
   entry point and callback does that before it returns (serve below, ic0.c's on_response): so
   a callback resumes the handler that awaits its response, and the queue is empty between
   messages. The manager is created after the initializers, as in a Lean program: a constant
   that an initializer makes could not hold a promise anyway, as without a manager a task runs
   when it is made, and a wait on an unresolved promise is a panic. Memory keeps the manager
   from one message to the next, and an upgrade, which starts with new memory, creates it
   again.

   Canister.lean is a module file, and Lean generates three initializers for a module:
   runtime_initialize_Canister initializes what the program needs when it runs,
   meta_initialize_Canister what Lean needs when it compiles a file that imports the module (the
   `meta` code, such as syntax and elaborators that a module defines), and initialize_Canister
   calls both. Only the first is called, so wasm-ld leaves the others out, and with them the code
   that only they reach. That includes the deriving handler of the Candid library, which
   Interface.lean imports with `meta import`, and Lean's own modules, which the handler imports
   and the link does not have: only meta_initialize_Interface refers to them, and
   initialize_Interface, which calls it. */
static void initialize(char const * entry) {
    unsigned long time_calls = wasi_ic0_time_calls;
    uint64_t start = ic0_performance_counter(0);
    __wasm_call_ctors();
    uint64_t constructed = ic0_performance_counter(0);
    // runtime_initialize_Canister calls this too, and then it returns at once. Called first
    // here, to measure it apart.
    lean_initialize_runtime_module();
    uint64_t runtime = ic0_performance_counter(0);
    // The initializers of Canister.lean and its imports: Hello, Ic0, Probes, Interface, the
    // Candid library and all of Init. Canister.lean's `initialize` creates the notes.
    lean_object * res = runtime_initialize_Canister(1 /* builtin */);
    if (lean_io_result_is_error(res)) {
        lean_io_result_show_error(res); // "uncaught exception: ..." to stderr
        wasi_ic0_trap("runtime_initialize_Canister failed");
    }
    lean_dec_ref(res);
    lean_io_mark_end_initialization();
    uint64_t initialized = ic0_performance_counter(0);
    // Cooperative mode: tasks run on this thread, at a wait or in lean_run_pending_tasks.
    lean_init_task_manager_using(0);
    uint64_t manager = ic0_performance_counter(0);
    char details[160];
    snprintf(details, sizeof details,
             " (constructors %" PRIu64 ", runtime %" PRIu64 ", module initializers %" PRIu64
             ", task manager %" PRIu64 ")",
             constructed - start, runtime - constructed, initialized - runtime, manager - initialized);
    canister_finish(entry, time_calls, details);
}

__attribute__((export_name("canister_init"))) void canister_init(void) {
    initialize("canister_init");
}

__attribute__((export_name("canister_post_upgrade"))) void canister_post_upgrade(void) {
    initialize("canister_post_upgrade");
}

/* Before an upgrade, on the module that the upgrade replaces: refuses it, by trapping, while
   calls to other canisters are outstanding. Their responses would run the callbacks of the new
   module, with environments in the memory that the upgrade discards. Stopping the canister
   first, as dfx does, waits for the responses (see README.md). */
__attribute__((export_name("canister_pre_upgrade"))) void canister_pre_upgrade(void) {
    unsigned long time_calls = wasi_ic0_time_calls;
    uint32_t outstanding = cistern_ic0_outstanding_calls();
    if (outstanding != 0) {
        char what[96];
        snprintf(what, sizeof what,
                 "%" PRIu32 " calls are outstanding: stop the canister before upgrading it",
                 outstanding);
        wasi_ic0_trap(what);
    }
    canister_finish("canister_pre_upgrade", time_calls, "");
}

/* A query or an update of Canister.lean: a `BaseIO Unit`, which returns lean_box(0). Its
   handler runs inside `method` up to its first await of a task that has not finished, and so
   does the reply of one that never awaits (Canister.lean's `serve`). Then the queued tasks run:
   what the handler spawned, such as add_both's two tasks, each of which makes a call, and, if
   that finishes the handler, its reply. A method that awaited a call returns after making it;
   its callback replies (ic0.c). */
static void serve(char const * entry, lean_object * (*method)(void)) {
    unsigned long time_calls = wasi_ic0_time_calls;
    method();
    lean_run_pending_tasks(); // what the handler spawned, and its reply if that finishes it
    canister_finish(entry, time_calls, "");
}

__attribute__((export_name("canister_query greet"))) void canister_query_greet(void) {
    serve("canister_query greet", cistern_greet);
}

__attribute__((export_name("canister_query hello"))) void canister_query_hello(void) {
    serve("canister_query hello", cistern_hello);
}

__attribute__((export_name("canister_query probe"))) void canister_query_probe(void) {
    serve("canister_query probe", cistern_probe);
}

__attribute__((export_name("canister_update add"))) void canister_update_add(void) {
    serve("canister_update add", cistern_add);
}

/* add as a query, whose changes the IC discards. It needs a name of its own: the IC refuses a
   module that exports the same name as a query and as an update (DuplicateExport in
   rs/embedders/src/wasm_utils/validation.rs). */
__attribute__((export_name("canister_query add_query"))) void canister_query_add_query(void) {
    serve("canister_query add_query", cistern_add);
}

__attribute__((export_name("canister_update add_then_exit")))
void canister_update_add_then_exit(void) {
    serve("canister_update add_then_exit", cistern_add_then_exit);
}

__attribute__((export_name("canister_update add_then_throw")))
void canister_update_add_then_throw(void) {
    serve("canister_update add_then_throw", cistern_add_then_throw);
}

__attribute__((export_name("canister_query notes"))) void canister_query_notes(void) {
    serve("canister_query notes", cistern_notes);
}

/* The methods that call other canisters (see Canister.lean). */

__attribute__((export_name("canister_update random"))) void canister_update_random(void) {
    serve("canister_update random", cistern_random);
}

__attribute__((export_name("canister_update greet_via"))) void canister_update_greet_via(void) {
    serve("canister_update greet_via", cistern_greet_via);
}

__attribute__((export_name("canister_update add_twice"))) void canister_update_add_twice(void) {
    serve("canister_update add_twice", cistern_add_twice);
}

__attribute__((export_name("canister_update add_both"))) void canister_update_add_both(void) {
    serve("canister_update add_both", cistern_add_both);
}

__attribute__((export_name("canister_update call_raw"))) void canister_update_call_raw(void) {
    serve("canister_update call_raw", cistern_call_raw);
}

__attribute__((export_name("canister_update call_then_exit")))
void canister_update_call_then_exit(void) {
    serve("canister_update call_then_exit", cistern_call_then_exit);
}

__attribute__((export_name("canister_update call_then_throw")))
void canister_update_call_then_throw(void) {
    serve("canister_update call_then_throw", cistern_call_then_throw);
}

__attribute__((export_name("canister_update oneway_add"))) void canister_update_oneway_add(void) {
    serve("canister_update oneway_add", cistern_oneway_add);
}

__attribute__((export_name("canister_query call_in_query")))
void canister_query_call_in_query(void) {
    serve("canister_query call_in_query", cistern_call_in_query);
}
