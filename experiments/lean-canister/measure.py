"""Installs the Lean canister in PocketIC, checks its replies and its state, and measures its
instructions.

Usage: measure.py [--pocket-ic BIN] --did FILE --hello FILE --hello-a-b FILE [--wasmtime BIN]
                  [--run-probe WASM] [--native COMMAND] [--about TEXT] [--json FILE] WASM...

Starts a PocketIC server, which BIN runs (default: pocket-ic), and uses it with pocketic-py, its
Python library (https://github.com/dfinity/pocketic-py): creates an instance with one
application subnet with the IC's production limits, installs each WASM in a canister of its own,
and calls the canister's queries (see Canister.lean):

- greet and hello, whose replies must be "Hello, world!" and what Hello.lean prints natively,
  which the --hello files have (with no arguments, and with the arguments a and b);
- greet with arguments that are not what it takes: not Candid, a nat instead of a text, a text
  that is not UTF-8, no argument, which the canister must reject with its decoder's error, and an
  extra argument, which it must ignore;
- probe without its last argument, an opt nat, which the decoder must make null;
- probe, for the instructions that each probe takes at growing sizes, until one fails.

Arguments and replies are Candid, of the types of the canister's interface, the --did file
(canister.did), which ic-py, the Python library that pocketic-py uses, parses. ic-py encodes the
arguments and decodes the replies, and checks that a method is a query in the interface if and
only if it is called as one.

Then upgrades each canister to the same module, and tries its state, the notes, with the updates
add, add_then_exit and add_then_throw and the queries add_query and notes: what an update or a
reject adds to the notes must stay, and what a query or a trap adds must not. Then upgrades the
canister again, after which there must be no notes. With --run-probe, also runs the recursion probes
under wasmtime (default: wasmtime) in that program, RunProbe.lean, for their depths there. With
--native, which is a command that runs RunProbe.lean natively, such as `lean --run RunProbe.lean`
with LEAN_PATH set, checks the probe results that have no formula, those of repr, against it.

Prints the report on standard output, and writes the measurements to the --json file. Fails if a
module does not install or upgrade, or a reply, a probe's result, the notes or the charge for the
pages that an update writes are wrong.

The canister logs how many instructions each message takes, unless it traps (c/canister.c), and
PocketIC prints the canister's log on its standard error. Queries and updates are counted with
ic0.performance_counter, which includes the System API's charges, such as the one for each
64 KiB page of memory that a message touches, and in an update for each page that it writes.
Needs pocketic-py 3, which ../../nix/pocket-ic-py.nix provides.
"""

import argparse
import base64
import gzip
import json
import mmap
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

import ic
from antlr4 import CommonTokenStream, InputStream, ParseTreeWalker
from ic.candid import Types
from ic.parser.DIDEmitter import DIDEmitter, DIDLexer, DIDParser
from pocket_ic import PocketIC, SubnetConfig

# The 1-2-5 series of ../lean-wasm/README.md, for the recursion depth.
DEPTHS = [1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000, 1_000_000,
          2_000_000, 5_000_000, 10_000_000]
# The sizes of the String.map table there, doubled further.
LENGTHS = [10_000, 20_000, 40_000, 80_000, 160_000, 320_000, 640_000, 1_280_000]

# Probes.lean's probes, the sizes to try them at, and their results. repr's has no formula: the
# length of `toString (repr (List.range n))`, with line breaks, which --native computes.
PROBES = {
    "noop": ([0], lambda n: n),
    "deep": (DEPTHS, lambda n: n),
    "countM": (DEPTHS, lambda n: n),
    "repr": (DEPTHS, None),
    "zip": (DEPTHS, lambda n: n),
    "deepK": (DEPTHS, lambda n: n),
    "deepKB": (DEPTHS, lambda n: 2**70 + n),
    "toUpper": (LENGTHS, lambda n: n),
    "toUpperNonAscii": (LENGTHS, lambda n: n),
}
# Sizes at which each probe runs twice in one query, which shows what its first run costs more.
TWICE = {"noop": 0, "deep": 1_000, "countM": 1_000, "repr": 1_000, "zip": 1_000, "deepK": 1_000,
         "deepKB": 1_000, "toUpper": 10_000, "toUpperNonAscii": 10_000}
# The probes whose depth is limited by the stack, which run under wasmtime too.
RECURSIVE = [name for name, (sizes, _) in PROBES.items() if sizes is DEPTHS]

# The IC's Wasm stack (MAX_WASM_STACK_SIZE in rs/embedders/src/lib.rs).
WASM_STACK = 5 * 1024 * 1024

# What the IC charges for the first access of a message to a 64 KiB page of Wasm memory, and in an
# update as much again for its first write to it: page_overhead (DEFAULT_PAGE_OVERHEAD in
# rs/config/src/subnet_config.rs) for each OS page of it (rs/memory_tracker/src/deterministic.rs).
# 80,000 with 4 KiB OS pages, 20,000 with macOS's 16 KiB ones.
PAGE_CHARGE = 5_000 * 65_536 // mmap.PAGESIZE


class Server:
    """A PocketIC server, with its standard output and error in files: the replica's log and the
    canisters' logs, which measure.py reads.

    pocketic-py's PocketIC starts a server of its own, whose output would go to this process's,
    unless it finds one running: one that writes the port file whose name has this process's id
    (PocketICServer). So this server writes that port file. The server that pocketic-py starts
    then finds the file, and exits at once."""

    def __init__(self, binary, workdir):
        self.binary = shutil.which(binary) or binary
        self.port_file = port_file = Path(tempfile.gettempdir(), f"pocket_ic_{os.getpid()}.port")
        # A server writes its port file only if there is none: this one would be stale, from a
        # process of the same id that has ended.
        port_file.unlink(missing_ok=True)
        self.stdout = LogFile(Path(workdir, "stdout"))
        self.stderr = LogFile(Path(workdir, "stderr"))
        # The replica logs what each install_code took on stdout, at the instance's log_level.
        # RUST_LOG would override that level, and LOG_TO_STDERR move the log to stderr.
        env = {k: v for k, v in os.environ.items() if k not in ("RUST_LOG", "LOG_TO_STDERR")}
        with open(self.stdout.path, "wb") as out, open(self.stderr.path, "wb") as err:
            self.process = subprocess.Popen(
                [self.binary, "--port-file", port_file, "--ttl", "600"], stdout=out, stderr=err,
                env=env,
            )
        try:
            # The server writes its port, followed by a newline, once it listens.
            for _ in range(600):
                if port_file.exists() and port_file.read_text().endswith("\n"):
                    break
                if self.process.poll() is not None:
                    raise RuntimeError(f"pocket-ic exited with {self.process.returncode}")
                time.sleep(0.1)
            else:
                raise RuntimeError("pocket-ic did not start")
            self.url = f"http://127.0.0.1:{int(port_file.read_text())}"
        except BaseException:
            self.process.kill()
            self.process.wait()
            port_file.unlink(missing_ok=True)
            self.show_stderr()
            raise

    def close(self):
        self.process.send_signal(signal.SIGTERM)
        try:
            self.process.wait(60)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        # The server removes its port file when it stops, but not when it is killed or crashes.
        self.port_file.unlink(missing_ok=True)

    def show_stderr(self):
        """Prints the end of the server's standard error, which says why it failed, before the
        file goes with its directory."""
        if text := self.stderr.path.read_text(errors="replace")[-4000:]:
            sys.stderr.write(f"measure.py: PocketIC's standard error ends with:\n{text}\n")

    def log(self):
        """What the canisters have logged since the last call: (canister id, line) pairs. PocketIC
        prints each ic0.debug_print on its standard error as "<time> UTC: [Canister <id>] <line>"."""
        lines = []
        for line in self.stderr.new_lines():
            if m := re.fullmatch(r"\S+ \S+ UTC: \[Canister ([a-z0-9-]+)\] (.*)", line):
                lines.append((m[1], m[2]))
        return lines


class LogFile:
    """A file that a process writes lines to."""

    def __init__(self, path):
        self.path, self.offset = path, 0

    def new_lines(self):
        """The complete lines written since the last call. Only "\\n" ends a line: a canister's
        log record may contain other line breaks."""
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            data = f.read()
        data = data[: data.rfind(b"\n") + 1]
        self.offset += len(data)
        return data.decode(errors="replace").split("\n")[:-1]


class Instance(PocketIC):
    """pocketic-py's PocketIC, whose instance measure_canisters deletes, while the server runs.
    PocketIC.__del__ would delete it when the object goes. After an error, that is after
    Server.close has stopped the server, and it would print a ConnectionError then. A server that
    stops deletes its instances itself."""

    def __del__(self):
        pass


class Subnets(SubnetConfig):
    """pocketic-py's SubnetConfig, with the replica's log at level info, where it logs what each
    install_code took."""

    def _json(self):
        return {**super()._json(), "log_level": "info"}


def pocket_ic(server):
    """An instance on the server, through pocketic-py: one application subnet with the IC's
    production limits (SubnetConfig's "instruction_config": "Production")."""
    # pocketic-py checks that the binary exists, and starts it; it exits at once (see Server).
    os.environ["POCKET_IC_BIN"] = server.binary
    os.environ["POCKET_IC_MUTE_SERVER"] = "1"
    # The server is local. requests, which pocketic-py uses, would send to an http_proxy.
    os.environ["no_proxy"] = "127.0.0.1"
    pic = Instance(Subnets(application=1))
    check(pic.server.url == server.url, f"pocketic-py uses {pic.server.url}, not {server.url}")
    # The server answers a request that takes longer than it waits, 10 seconds by default, with
    # 202, and the result has to be polled, which pocketic-py does not do. This waits 10 minutes.
    pic.server.request_client.headers["processing-timeout-ms"] = "600000"
    return pic


# pocketic-py raises a ValueError with this message for a call that the IC rejects.
REJECTION = re.compile(
    r"PocketIC returned a rejection error: reject code (\w+), reject message (.*), error code (\w+)",
    re.DOTALL,
)


def call(make_call):
    """The result of a call through pocketic-py: ("reply", bytes), or ("reject", {reject_code,
    reject_message, error_code})."""
    try:
        # A list of the reply's bytes, or bytes if they start like Candid.
        return "reply", bytes(make_call())
    except ValueError as e:
        if m := REJECTION.fullmatch(str(e)):
            return "reject", {"reject_code": m[1], "reject_message": m[2], "error_code": m[3]}
        raise


# install_code's argument, as in pocketic-py's install_code, which installs only. For "upgrade",
# whose type is opt record { ... }, null stands for that.
INSTALL_CODE_ARG = Types.Record({
    "mode": Types.Variant({"install": Types.Null, "upgrade": Types.Null}),
    "canister_id": Types.Principal,
    "wasm_module": Types.Vec(Types.Nat8),
    "arg": Types.Vec(Types.Nat8),
})

def interface(did):
    """The methods of a service's Candid interface, the text of a .did file, by name: ic-py's
    function types, with argTypes, retTypes and annotations (such as ["query"]). Parsed as ic-py's
    Canister class does (ic/canister.py), without an agent."""
    parser = DIDParser(CommonTokenStream(DIDLexer(InputStream(did))))
    emitter = DIDEmitter()
    ParseTreeWalker().walk(emitter, parser.program())
    return emitter.getActor()["methods"]


# The messages with which the canister rejects the arguments that greet does not take: those of
# the decoder of the Candid library (../../candid/Candid/Decode.lean), which serve in
# Canister.lean passes on. They start with "Candid:".
REJECTS = {
    "not Candid": "Candid: wrong magic at byte 0",
    "nat": "Candid: nat cannot be deserialized to text at byte 7",
    "not UTF-8": "Candid: invalid utf8 at byte 7",
    "no argument": "Candid: No more values on the wire, the expected type text is not opt, null,"
                   " or reserved at byte 6",
}

# What c/canister.c logs at the end of each entry point.
ENTRY_LINE = re.compile(
    r"(canister_init|canister_post_upgrade|canister_(?:query|update) \w+): (\d+) instructions,"
    r" (\d+) ic0\.time calls(?: \((.*)\))?"
)


class Canister:
    def __init__(self, server, pic, wasm, methods):
        self.server, self.pic, self.name, self.methods = server, pic, Path(wasm).name, methods
        self.module = Path(wasm).read_bytes()
        self.id = pic.create_canister()
        self.text_id = self.id.to_str()

    def expect_reply(self, result):
        kind, value = result
        if kind != "reply":
            raise RuntimeError(f"{self.name}: unexpected reject: {value}")
        return value

    def time(self):
        """The instance's time, in nanoseconds. As nothing sets it, each round advances it by 1."""
        return self.pic.get_time()["nanos_since_epoch"]

    def _entry(self, make_call, entry):
        """Makes the call, and returns its result with what the canister logged. The log ends
        with c/canister.c's line for the entry point, unless the message trapped."""
        result = call(make_call)
        reached_end = result[0] == "reply" or result[1]["error_code"] == "CanisterRejectedMessage"
        lines, deadline = [], time.monotonic() + 10
        while True:
            lines += [line for id, line in self.server.log() if id == self.text_id]
            if not reached_end or (lines and ENTRY_LINE.fullmatch(lines[-1])) or time.monotonic() > deadline:
                break
            time.sleep(0.01)
        m = ENTRY_LINE.fullmatch(lines[-1]) if lines else None
        if reached_end and not (m and m[1] == entry):
            raise RuntimeError(f"{self.name}: no log line for {entry} after {result}: {lines}")
        measured = None
        if m:
            lines.pop()
            measured = {"instructions": int(m[2]), "ic0.time calls": int(m[3])}
            for part in (m[4] or "").split(", ") if m[4] else []:
                what, n = part.rsplit(" ", 1)
                measured[what] = int(n)
        return result, lines, measured

    def install(self, mode):
        """Installs the module gzipped, which the IC accepts: in one message, which may have at
        most 2 MiB, with room to spare.

        The IC charges the instructions of an install_code to the canister, and refuses the
        next until the rounds have paid them off, at 2 billion per round. So this tries again
        until the IC accepts. pocketic-py executes rounds until a call is done, and the rounds
        are counted by the instance's time.

        The canister's own argument is the empty Candid sequence, (), as dfx sends for a canister
        that takes no init arguments. canister_init does not decode it."""
        arg = ic.encode([{"type": INSTALL_CODE_ARG, "value": {
            "mode": {mode: None},
            "canister_id": self.id.bytes,
            "wasm_module": gzip.compress(self.module, 9, mtime=0),
            "arg": ic.encode([]),
        }}])
        # The management canister routes the call by the canister id in its argument.
        effective = {"CanisterId": base64.b64encode(self.id.bytes).decode()}
        entry = "canister_init" if mode == "install" else "canister_post_upgrade"
        self.server.stdout.new_lines()
        start, refused = self.time(), 0
        while True:
            tried = self.time()
            result, lines, measured = self._entry(
                lambda: self.pic.update_call_with_effective_principal(None, effective, "install_code", arg),
                entry,
            )
            if result[0] == "reply" or result[1]["error_code"] != "CanisterInstallCodeRateLimited":
                break
            refused += 1
            check(refused < 100, f"{self.name}: install_code still rate limited after 100 tries")
        self.expect_reply(result)
        rounds = {
            "refused tries": refused,
            # Counted from the last round before this call: for the first upgrade, the install's.
            "refusing rounds": tried - start,
            "accepted in round": tried - start + 1,
            # More than one if the IC splits it into slices (deterministic time slicing).
            "rounds taken": self.time() - tried,
        }
        # What the replica logs about the install, on PocketIC's standard output.
        replica, deadline = {}, time.monotonic() + 10
        while len(replica) < 2 and time.monotonic() < deadline:
            for line in self.server.stdout.new_lines():
                if m := re.search(rf"Executing \({entry}\) on canister {self.text_id} consumed (\d+) instructions", line):
                    replica[entry] = int(m[1])
                if m := re.search(rf"Finished executing install_code message on canister {self.text_id} .*instructions consumed: ([\d_]+)$", line):
                    replica["install_code"] = int(m[1].replace("_", ""))
            time.sleep(0.01)
        check(len(replica) == 2, f"{self.name}: the replica's log of the install is {replica}")
        return {"log": lines, **measured, **rounds, "replica": replica}

    def query(self, method, args):
        return self._method("query", method, args)

    def update(self, method, args):
        """An update call, which pocketic-py makes by executing rounds until it is done."""
        return self._method("update", method, args)

    def _method(self, kind, method, args):
        """Calls the method with `args`, a list of Python values of its argument types in the
        interface, which ic-py encodes, or bytes, which are sent as they are. The reply is
        decoded at the method's result types: the value of the result if there is one, such as
        a str for a text, an int for a nat, a list for a vec and a dict by field name for a
        record, and None if there is none."""
        func = self.methods[method]
        check(("query" in func.annotations) == (kind == "query"),
              f"{method} is called as {kind}, but its type is {func.annotations}")
        if isinstance(args, bytes):
            payload = args
        else:
            payload = ic.encode([{"type": t, "value": v}
                                 for t, v in zip(func.argTypes, args, strict=True)])
        make_call = self.pic.query_call if kind == "query" else self.pic.update_call
        result, lines, measured = self._entry(
            lambda: make_call(self.id, method, payload), f"canister_{kind} {method}"
        )
        outcome, value = result
        reply = None
        if outcome == "reply":
            values = [item["value"] for item in ic.decode(value, func.retTypes)]
            check(len(values) == len(func.retTypes), f"{method}: the reply {value!r} has {values}")
            reply = values[0] if len(values) == 1 else values or None
        return {
            "reply": reply,
            "reject": None if outcome == "reply" else value["reject_message"],
            "reject_code": None if outcome == "reply" else value["reject_code"],
            "error_code": None if outcome == "reply" else value["error_code"],
            "log": lines,
            **(measured or {}),
        }


def check(ok, what):
    if not ok:
        raise SystemExit(f"measure.py: check failed: {what}")


def check_result(where, name, n, result):
    expected = PROBES[name][1]
    check(expected is None or result == expected(n), f"{where}: probe {name} {n}: {result}")


def largest(sizes, attempt):
    """Runs attempt(n) at growing sizes until it fails, and then finds the largest size at which
    it works, by bisection. attempt returns a dict with "n", and "failure" if it failed. Returns
    the runs at the sizes, and {"works", "fails", "bisection"}: the runs at the largest size that
    worked and at the next size, which failed, and those of the bisection; or None if none failed
    or the first did."""
    runs = []
    for n in sizes:
        runs.append(attempt(n))
        if "failure" in runs[-1]:
            break
    if "failure" not in runs[-1] or len(runs) == 1:
        return runs, None
    works, fails = runs[-2], runs[-1]
    bisection = []
    while fails["n"] - works["n"] > 1:
        run = attempt((works["n"] + fails["n"]) // 2)
        bisection.append(run)
        works, fails = (works, run) if "failure" in run else (run, fails)
    return runs, {"works": works, "fails": fails, "bisection": bisection}


def measure(canister, expected_hello):
    """Everything about one canister, as a dict for the JSON file."""
    out = {"module": canister.name, "canister": canister.text_id, "install": canister.install("install")}
    check(not out["install"]["log"], f"{canister.name}: canister_init logged {out['install']['log']}")

    # Each argument is new for its method: the replica answers a query that it has answered
    # before from its cache, without executing it.
    queries = out["queries"] = {
        "greet world": canister.query("greet", ["world"]),
        "greet not Candid": canister.query("greet", b"\xff"),
        "greet nat": canister.query("greet", ic.encode([{"type": Types.Nat, "value": 1}])),
        # The text 0xff, which is not UTF-8.
        "greet not UTF-8": canister.query("greet", b"DIDL\x00\x01\x71\x01\xff"),
        "greet no argument": canister.query("greet", ic.encode([])),
        "greet extra": canister.query("greet", ic.encode([{"type": Types.Text, "value": "extra"},
                                                          {"type": Types.Nat, "value": 1}])),
        "hello": canister.query("hello", [[]]),
        "hello a b": canister.query("hello", [["a", "b"]]),
        "probe nosuch 1": canister.query("probe", ["nosuch", 1, []]),
        # Without the third argument, an opt nat, which the decoder makes null: one run.
        "probe noop 0": canister.query("probe", ic.encode([{"type": Types.Text, "value": "noop"},
                                                           {"type": Types.Nat, "value": 0}])),
    }
    check(queries["greet world"]["reply"] == "Hello, world!", f"greet: {queries['greet world']}")
    check(queries["greet world"]["log"] == ["greeting world"], f"greet's log: {queries['greet world']}")
    for what, message in REJECTS.items():
        q = queries[f"greet {what}"]
        check(q["reject"] == message, f"greet {what}: {q} instead of the reject {message!r}")
    check(queries["greet extra"]["reply"] == "Hello, extra!", f"greet extra: {queries['greet extra']}")
    for key, expected in expected_hello.items():
        check(queries[key]["reply"] == expected, f"{key}: {queries[key]['reply']!r} instead of {expected!r}")
    check(queries["probe nosuch 1"]["reject"] == "there is no probe nosuch", f"probe: {queries['probe nosuch 1']}")
    q = queries["probe noop 0"]
    check(q["reply"] is not None and q["reply"]["result"] == 0 and len(q["reply"]["instructions"]) == 1,
          f"probe noop 0 without its third argument: {q}")

    # Each probe at growing sizes, until it fails, and then the largest size that works, by
    # bisection. Each argument is new: the replica answers a query that it has answered before
    # from its cache, without executing it.
    out["probes"], out["largest"] = {}, {}
    for name, (sizes, _) in PROBES.items():

        def probe(n):
            q = canister.query("probe", [name, n, []])
            run = {"n": n, "total": q.get("instructions")}
            if q["reply"] is None:
                run["failure"] = q["reject"]
            else:
                reply = q["reply"]
                check_result(canister.name, name, n, reply["result"])
                run.update(result=reply["result"], instructions=reply["instructions"][0])
            return run

        out["probes"][name], largest_run = largest(sizes, probe)
        if largest_run:
            out["largest"][name] = largest_run

    out["twice"] = {}
    for name, n in TWICE.items():
        q = canister.query("probe", [name, n, [2]])
        check(q["reply"] is not None, f"probe {name} {n} 2: {q}")
        reply = q["reply"]
        check_result(canister.name, name, n, reply["result"])
        out["twice"][name] = {"n": n, "result": reply["result"], "instructions": reply["instructions"]}

    # After the upgrade, the canister runs canister_post_upgrade, in new memory.
    out["upgrade"] = canister.install("upgrade")
    check(not out["upgrade"]["log"], f"{canister.name}: canister_post_upgrade logged {out['upgrade']['log']}")
    check_initialized(canister, out, "upgrade")
    out["queries"]["greet upgraded"] = q = canister.query("greet", ["upgraded"])
    check(q["reply"] == "Hello, upgraded!", f"greet after the upgrade: {q}")
    measure_state(canister, out)
    return out


def check_initialized(canister, out, upgrade):
    """canister_post_upgrade starts with new memory, as canister_init does, and runs the same
    initializers, so it takes as many instructions, part by part. One that skipped Canister.lean's
    initializer, which creates the notes, would take fewer, and the notes' reference would be a
    null pointer, which reads as an empty array: the address 0 is in the C stack, and readable."""
    for part in ("instructions", "ic0.time calls", "constructors", "runtime", "module initializers"):
        check(out[upgrade][part] == out["install"][part],
              f"{canister.name}: {upgrade}: canister_post_upgrade's {part} {out[upgrade][part]},"
              f" canister_init's {out['install'][part]}")


def measure_state(canister, out):
    """The notes of Canister.lean, which its updates change. Sets out["state"], the calls in their
    order, with the second upgrade among them; out["write charge"], what add ("b") took more as an
    update than as a query; and out["upgrade again"], the second upgrade.

    The calls come after the first upgrade: an update executes rounds, and the install_code debit
    goes down by 2 billion at the end of each, so that updates before it would change the rounds
    that refused it. Each argument is new for its method, as the replica answers a query that it
    has answered before from its cache, also after an update that trapped, which leaves the
    canister's version as it was."""
    steps = out["state"] = []

    def step(kind, method, arg):
        r = {"call": f"{method} ({candid_text(arg)})", "kind": kind,
             **getattr(canister, kind)(method, [arg])}
        steps.append(r)
        check(not r["log"], f"{canister.name}: {r['call']} logged {r['log']}")
        return r

    def expect(kind, method, arg, reply):
        r = step(kind, method, arg)
        check(r["reply"] == reply, f"{canister.name}: {r['call']}: {r} instead of the reply {reply!r}")
        return r

    expect("update", "add", "a", 1)
    # add ("b") below runs the same code with the same argument, from the same memory: the IC
    # discards what the queries in between change.
    as_query = expect("query", "add_query", "b", 2)
    expect("query", "notes", "1", ["a"])
    as_update = expect("update", "add", "b", 2)
    expect("query", "notes", "2", ["a", "b"])
    # The exit code is the number of notes: the note was added before the trap. Only the gist of
    # the message is compared, as only canister.wasm's has a backtrace (the module's name section).
    r = step("update", "add_then_exit", "c")
    check((r["reject_code"], r["error_code"]) == ("CanisterError", "CanisterCalledTrap")
          and failure(r["reject"]) == "ic0.trap: exit(3)", f"{canister.name}: {r['call']}: {r}")
    expect("query", "notes", "3", ["a", "b"])
    r = step("update", "add_then_throw", "d")
    check((r["reject_code"], r["error_code"], r["reject"])
          == ("CanisterReject", "CanisterRejectedMessage", "added d, then threw"),
          f"{canister.name}: {r['call']}: {r}")
    expect("query", "notes", "4", ["a", "b", "d"])

    # The update pays for the pages that it writes, before c/canister.c reads the counter.
    difference = as_update["instructions"] - as_query["instructions"]
    check(difference > 0 and difference % PAGE_CHARGE == 0,
          f"{canister.name}: add \"b\" took {difference} instructions more as an update than as a query,"
          f" which is not a positive multiple of {PAGE_CHARGE}")
    out["write charge"] = {"instructions": difference, "pages": difference // PAGE_CHARGE}

    # A second upgrade, after which there must be no notes: canister_post_upgrade starts with new
    # memory again. With the old memory, the module initializers would not run again, as their
    # _G_initialized flags would be set. The first upgrade's instructions were paid off at the
    # end of its own round.
    first = out["upgrade"]
    again = out["upgrade again"] = canister.install("upgrade")
    check(not again["log"], f"{canister.name}: the second canister_post_upgrade logged {again['log']}")
    check(again["refused tries"] == 0, f"{canister.name}: the second upgrade was refused {again['refused tries']} times")
    check_initialized(canister, out, "upgrade again")
    check(again["replica"]["canister_post_upgrade"] == first["replica"]["canister_post_upgrade"],
          f"{canister.name}: the replica's count of the second canister_post_upgrade: {again['replica']}")
    steps.append({"call": "upgrade", "kind": "install_code", "accepted in round": again["accepted in round"],
                  "instructions": again["instructions"], "ic0.time calls": again["ic0.time calls"]})
    expect("query", "notes", "5", [])


def measure_canisters(server, wasms, methods, expected_hello):
    """Each module in a canister of its own, in one instance, which this deletes at the end."""
    pic = pocket_ic(server)
    canisters = [Canister(server, pic, wasm, methods) for wasm in wasms]
    results = [measure(c, expected_hello) for c in canisters]
    pic.server.delete_instance(pic.instance_id)
    return results


# wasmtime


class Wasmtime:
    """run-probe.wasm under wasmtime, with the IC's Wasm stack, compiled once with `options`."""

    def __init__(self, binary, wasm, cwasm, options):
        self.binary, self.cwasm = binary, cwasm
        # Without wasmtime's cache, which would be in $HOME.
        subprocess.run([binary, "compile", "-C", "cache=n", *options, wasm, "-o", cwasm], check=True)

    def attempt(self, name, n):
        p = subprocess.run(
            [self.binary, "run", "-C", "cache=n", "--allow-precompiled", "-W",
             f"max-wasm-stack={WASM_STACK}", self.cwasm, name, str(n)],
            capture_output=True, text=True,
        )
        if p.returncode == 0:
            result = int(p.stdout)
            check_result("run-probe.wasm", name, n, result)
            return {"n": n, "result": result}
        # Anything but a stack overflow is an error, so that it does not pass for one.
        check("wasm trap: call stack exhausted" in p.stderr, f"run-probe.wasm {name} {n}: {p.stderr}")
        return {"n": n, "failure": "stack overflow"}


def measure_wasmtime(binary, wasm, workdir):
    """The recursion probes' depths under wasmtime, with Cranelift's default optimizations, and
    with them off, as the IC compiles."""
    version = subprocess.run([binary, "--version"], capture_output=True, text=True, check=True).stdout
    out = {"version": version.strip(), "configurations": {}}
    for label, options in [("wasmtime", []), ("wasmtime -O opt-level=0", ["-O", "opt-level=0"])]:
        engine = Wasmtime(binary, wasm, Path(workdir, f"run-probe-{len(out['configurations'])}.cwasm"), options)
        probes = out["configurations"][label] = {}
        for name in RECURSIVE:
            runs, largest_run = largest(DEPTHS, lambda n: engine.attempt(name, n))
            probes[name] = {"runs": runs, "largest": largest_run}
    return out


def check_natively(command, results, wasmtime):
    """Checks the probe results that have no formula against those of `command`, which runs
    RunProbe.lean natively."""
    for name, (_, expected) in PROBES.items():
        if expected is not None:
            continue
        found = []  # (where, n, result)
        for r in results:
            runs = r["probes"][name] + (r["largest"][name]["bisection"] if name in r["largest"] else [])
            found += [(r["module"], run["n"], run["result"]) for run in runs if "result" in run]
            found.append((r["module"], r["twice"][name]["n"], r["twice"][name]["result"]))
        for label, probes in (wasmtime or {}).get("configurations", {}).items():
            if name in probes:
                p = probes[name]
                runs = p["runs"] + (p["largest"]["bisection"] if p["largest"] else [])
                found += [(label, run["n"], run["result"]) for run in runs if "result" in run]
        sizes = sorted({n for _, n, _ in found})
        # `lean --run` prints its errors on standard output.
        p = subprocess.run([*shlex.split(command), name, *map(str, sizes)], capture_output=True,
                           text=True)
        check(p.returncode == 0, f"{command} {name}: exit {p.returncode}: {p.stdout}{p.stderr}")
        values = p.stdout.split()
        check(len(values) == len(sizes), f"{command} {name}: {p.stdout!r}")
        native = dict(zip(sizes, map(int, values)))
        for where, n, result in found:
            check(result == native[n], f"{where}: probe {name} {n}: {result}, natively {native[n]}")


# The report


WIDTH = 92


def fill(text, indent=""):
    return textwrap.fill(text, WIDTH, initial_indent=indent, subsequent_indent=indent,
                         break_on_hyphens=False)


def heading(title):
    print(f"\n{title}\n{'-' * len(title)}")


def table(header, rows, text=(0,)):
    """Prints rows of cells. The columns in `text` are left-aligned, the others right-aligned."""
    rows = [header, *rows]
    widths = [max(len(row[i]) for row in rows) for i in range(len(header))]
    for row in rows:
        cells = [c.ljust(w) if i in text else c.rjust(w) for i, (c, w) in enumerate(zip(row, widths))]
        print("  " + "  ".join(cells).rstrip())


def number(n):
    return "" if n is None else f"{n:,}"


def candid_text(value):
    """A value as ic-py decodes it, in Candid's text format, as far as the replies here need it:
    text, nat, vec and record (ic-py's opt, a list of zero or one values, does not occur)."""
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "vec { " + "; ".join(map(candid_text, value)) + " }" if value else "vec {}"
    if isinstance(value, dict):
        return "record { " + "; ".join(f"{k} = {candid_text(v)}" for k, v in value.items()) + " }"
    if value is None:
        return "()"
    raise TypeError(f"no Candid text for {value!r}")


def failure(message):
    """The gist of a reject message, as the replica phrases it."""
    for pattern, gist in [
        (r"Canister trapped: stack overflow", "stack overflow"),
        (r"Canister exceeded the limit of \d+ instructions", "instruction limit"),
        (r"Canister trapped: (.*?)\.?\n", lambda m: f"trap: {m[1]}"),
        (r"Canister called `ic0.trap` with message: '(.*?)'", lambda m: f"ic0.trap: {m[1]}"),
    ]:
        if m := re.search(pattern, message):
            return gist if isinstance(gist, str) else gist(m)
    return message.splitlines()[0]


def report(about, modules, results, wasmtime):
    names = [r["module"] for r in results]
    title = "Report on " + " and ".join(names)
    print(f"{title}\n{'=' * len(title)}\n")
    print(fill(about))

    heading("Modules")
    table(["module", "bytes", "gzipped"],
          [[r["module"], number(len(m)), number(len(gzip.compress(m, 9, mtime=0)))]
           for r, m in zip(results, modules)])
    print(fill("Each was installed in a canister of its own: "
               + ", ".join(f"{r['module']} in {r['canister']}" for r in results) + ".", "  "))

    heading("Installation and upgrade")
    print(fill("Instructions. install_code is the replica's count for the whole message, from its"
               " log; it includes compiling the module. canister_init is what"
               " ic0.performance_counter counts at its end, before canister.c logs it, with the"
               " parts that canister.c measures: the C++ constructors,"
               " lean_initialize_runtime_module, and runtime_initialize_Canister, which runs"
               " the runtime initializers of Canister.lean and its imports (not those of the"
               " meta phase, which only the compiler needs). ic0.time calls are those of"
               " clock_time_get (c/wasi.c). Then a first upgrade to the same module, which runs"
               " canister_post_upgrade, tried right after the install and then again until the IC"
               " accepts it: it refuses install_code for a canister"
               " (CanisterInstallCodeRateLimited) until the rounds have paid off the"
               " instructions of its last one. The rounds are counted from the install's, by the"
               " instance's time. The second upgrade came after the updates, in Updates and"
               " state below.", "  "))
    print()
    rows = []
    for label, get in [
        ("install_code", lambda r: r["install"]["replica"]["install_code"]),
        ("  canister_init (replica)", lambda r: r["install"]["replica"]["canister_init"]),
        ("  canister_init", lambda r: r["install"]["instructions"]),
        ("    C++ constructors", lambda r: r["install"]["constructors"]),
        ("    Lean runtime", lambda r: r["install"]["runtime"]),
        ("    module initializers", lambda r: r["install"]["module initializers"]),
        ("    ic0.time calls", lambda r: r["install"]["ic0.time calls"]),
        ("rounds that refused the first upgrade", lambda r: r["upgrade"]["refusing rounds"]),
        ("round that accepted it", lambda r: r["upgrade"]["accepted in round"]),
        ("rounds that it took", lambda r: r["upgrade"]["rounds taken"]),
        ("install_code (first upgrade)", lambda r: r["upgrade"]["replica"]["install_code"]),
        ("  canister_post_upgrade (replica)", lambda r: r["upgrade"]["replica"]["canister_post_upgrade"]),
        ("  canister_post_upgrade", lambda r: r["upgrade"]["instructions"]),
        ("install_code (second upgrade)", lambda r: r["upgrade again"]["replica"]["install_code"]),
    ]:
        rows.append([label] + [number(get(r)) for r in results])
    table([""] + names, rows)

    heading("Queries")
    print(fill("Instructions of each query up to its end, as c/canister.c logs them there; the"
               " logging itself takes some thousand more, which the count cannot include (for"
               " canister_init, the difference to the replica's count above). Arguments and"
               " replies are Candid, encoded and decoded by ic-py with the types of canister.did;"
               " the arguments below are in Candid's text format. The replies are checked:"
               " greet's against \"Hello, <argument>!\", hello's against what Hello.lean prints"
               " natively, and the rejects against the decoder's messages (Canister.lean's serve"
               " rejects a message whose argument it cannot decode). An extra argument is"
               " ignored, and a missing opt argument is null.", "  "))
    print()
    rows = []
    for key, label in [("greet world", 'greet ("world")'), ("greet upgraded", 'greet ("upgraded") (after the first upgrade)'),
                       ("greet extra", 'greet ("extra", 1) (an extra argument)'),
                       ("greet not Candid", "greet 0xff (rejected: not Candid)"),
                       ("greet nat", "greet (1) (rejected: a nat, not a text)"),
                       ("greet not UTF-8", "greet with a text 0xff (rejected: not UTF-8)"),
                       ("greet no argument", "greet () (rejected: no argument)"),
                       ("hello", "hello (vec {})"), ("hello a b", 'hello (vec { "a"; "b" })'),
                       ("probe nosuch 1", 'probe ("nosuch", 1, null) (rejected)'),
                       ("probe noop 0", 'probe ("noop", 0) (no third argument)')]:
        rows.append([label] + [number(r["queries"][key].get("instructions")) for r in results])
    table(["query"] + names, rows)

    heading("Updates and state")
    print(fill("The notes of Canister.lean, an IO.Ref (Array String) that its initialize creates in"
               " canister_init and canister_post_upgrade, tried after the first upgrade, as"
               " updates execute rounds, which would have paid off the install's instructions"
               " before it. The methods: add adds its argument to the notes and replies with how"
               " many there are, add_query is add as a query, add_then_exit adds and then exits"
               " with that number, which traps, add_then_throw adds and then throws, which"
               " rejects, and notes replies with the notes. The table has the calls in their"
               " order, with the second upgrade, which the IC accepted at once. Every reply and"
               " reject is checked, and each canister_post_upgrade against canister_init, part by"
               " part, as they run the same initializers in new memory. Instructions as"
               " c/canister.c logs them, as for the queries above; a call that traps logs none.",
               "  "))
    print()
    rows = []
    for i, step in enumerate(results[0]["state"]):
        if step["kind"] == "install_code":
            accepted = step["accepted in round"]
            label = "second upgrade (canister_post_upgrade)"
            outcome = "accepted at once" if accepted == 1 else f"accepted in round {accepted}"
        else:
            label = f"{step['call']} ({step['kind']})"
            if step["reply"] is not None:
                outcome = candid_text(step["reply"])
            elif step["error_code"] == "CanisterRejectedMessage":
                outcome = f"rejected: {step['reject']}"
            else:
                outcome = f"trapped: {failure(step['reject'])}"
        times = [r["state"][i].get("ic0.time calls") for r in results]
        rows.append([label, outcome] + [number(r["state"][i].get("instructions")) for r in results]
                    + [" / ".join(map(number, times)) if len(set(times)) > 1 else number(times[0])])
    table(["call", "reply or outcome"] + names + ["ic0.time calls"], rows, text=(0, 1))
    print()
    charges = "; ".join(f"{r['module']} {number(r['write charge']['instructions'])}, that is"
                        f" {r['write charge']['pages']} pages" for r in results)
    print(fill('add ("b") took more instructions as an update than add_query ("b"), the same code'
               " with the same argument from the same memory, as a query. The IC charges an update"
               f" another {number(PAGE_CHARGE)} for each 64 KiB page that it writes, on top of the"
               " same for the first access, which a query pays too: here for the pages that it"
               f" wrote before c/canister.c read the counter. {charges}. The difference is"
               " checked to be a multiple of the charge.", "  "))

    heading("Limits")
    text = ("The largest size at which each probe worked, and why it failed at the next size:"
            " the 5 MiB Wasm stack, or the limit of 5,000,000,000 instructions for a query."
            " Found by bisection, after the sizes of the table below. The other probes worked"
            " at every size there.")
    if wasmtime:
        text += (f" The last columns are the depths of run-probe.wasm, the same probes in a"
                 f" WASI program, under {wasmtime['version']} with the same stack"
                 f" (-W max-wasm-stack={WASM_STACK}): with Cranelift's default optimizations,"
                 f" and with -O opt-level=0, which is how the IC compiles. There the next depth"
                 f" ran out of stack (\"call stack exhausted\").")
    print(fill(text, "  "))
    print()
    configurations = (wasmtime or {}).get("configurations", {})
    rows = []
    for name in PROBES:
        if not any(name in r["largest"] for r in results):
            continue
        largest_run = [r["largest"].get(name) for r in results]
        reasons = {failure(l["fails"]["failure"]) for l in largest_run if l}
        cells = [name] + [number(l["works"]["n"]) if l else "none failed" for l in largest_run]
        cells.append(" / ".join(sorted(reasons)))
        for probes in configurations.values():
            l = probes.get(name, {}).get("largest")
            cells.append(number(l["works"]["n"]) if l else "")
        rows.append(cells)
    table(["probe"] + names + ["then"] + list(configurations), rows, text=(0, len(names) + 1))

    heading("Instructions of the probes")
    print(fill("The instructions that each probe took in a query of its own, as"
               " Ic0.countInstructions counts them: the work, without preparing the input."
               " In brackets, those of the query, as above.", "  "))
    for name, (sizes, _) in PROBES.items():
        print()
        rows = []
        for i, n in enumerate(sizes):
            if all(i >= len(r["probes"][name]) for r in results):
                break
            cells = [f"{name} {n:,}"]
            for r in results:
                runs = r["probes"][name]
                if i >= len(runs):
                    cells.append("")
                elif "failure" in runs[i]:
                    cells.append(failure(runs[i]["failure"]))
                else:
                    cells.append(f"{number(runs[i]['instructions'])} [{number(runs[i]['total'])}]")
            rows.append(cells)
        table(["probe, n"] + names, rows)

    heading("First and second run")
    print(fill("Each probe twice in one query. The first run also pays for what the second finds"
               " ready: the IC's charge for each 64 KiB page of memory that the message has not"
               " touched yet, and Lean's lazily initialized constants (closed terms), which a"
               " query recomputes, as it discards its changes to memory.", "  "))
    print()
    rows = []
    for name, twice in results[0]["twice"].items():
        cells = [f"{name} {twice['n']:,}"]
        for r in results:
            first, second = r["twice"][name]["instructions"]
            cells.append(f"{number(first)} / {number(second)}")
        rows.append(cells)
    table(["probe, n"] + [f"{n}: first / second" for n in names], rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--pocket-ic", default="pocket-ic")
    parser.add_argument("--did", required=True, type=Path)
    parser.add_argument("--hello", required=True, type=Path)
    parser.add_argument("--hello-a-b", required=True, type=Path)
    parser.add_argument("--wasmtime", default="wasmtime")
    parser.add_argument("--run-probe", type=Path)
    parser.add_argument("--native")
    parser.add_argument("--about", default="")
    parser.add_argument("--json", type=Path)
    parser.add_argument("wasm", nargs="+", type=Path)
    args = parser.parse_args()
    expected_hello = {"hello": args.hello.read_text(), "hello a b": args.hello_a_b.read_text()}
    methods = interface(args.did.read_text())

    with tempfile.TemporaryDirectory() as workdir:
        server = Server(args.pocket_ic, workdir)
        try:
            results = measure_canisters(server, args.wasm, methods, expected_hello)
        except Exception:  # not a failed check (SystemExit), or Ctrl-C
            server.show_stderr()
            raise
        finally:
            server.close()
        wasmtime = args.run_probe and measure_wasmtime(args.wasmtime, args.run_probe, workdir)

    # The modules must agree, also where the expected result is not known.
    for name in PROBES:
        sets = [{run["n"]: run["result"] for run in r["probes"][name] if "result" in run} for r in results]
        common = set.intersection(*(set(s) for s in sets))
        check(all(len({s[n] for s in sets}) == 1 for n in common), f"probe {name}: modules disagree")
    if args.native:
        check_natively(args.native, results, wasmtime)

    report(args.about, [w.read_bytes() for w in args.wasm], results, wasmtime)
    if args.json:
        measurements = {"modules": results, "wasmtime": wasmtime or None}
        args.json.write_text(json.dumps(measurements, indent=2) + "\n")


if __name__ == "__main__":
    main()
