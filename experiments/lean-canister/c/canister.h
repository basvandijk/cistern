/*
What canister.c offers the other C files.
*/
#pragma once

/* Ends an entry point or a callback: hands what stdout and stderr have buffered to the log, then
   logs "<entry>: <n> instructions, <k> ic0.time calls<details>", where n is the message's
   ic0.performance_counter(0) and k the ic0.time calls since `time_calls`, a value of
   wasi_ic0_time_calls (wasi.h). The harness, measure.py, reads these lines. */
void canister_finish(char const * entry, unsigned long time_calls, char const * details);
