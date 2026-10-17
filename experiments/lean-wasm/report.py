"""Describes hello.wasm and compares it with the Internet Computer's limits for canisters.

Usage: report.py WASM OPT_WASM LINK_MAP ABOUT

WASM is the module as linked, OPT_WASM the same module after `wasm-opt -O`, LINK_MAP the
linker's map of WASM, and ABOUT a line on how they were built. Prints the report on
standard output. Needs wasm-objdump (wabt) and wasm-tools on PATH.
"""

import gzip
import re
import subprocess
import sys
import textwrap
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

KiB = 1024
MiB = 1024 * KiB
GiB = 1024 * MiB

# The Internet Computer's limits are those of replica release-2026-10-08_03-33-base, on
# mainnet since 2026-10-15. The code cited below was the same on master on 2026-10-17.
IC_CODE = "https://github.com/dfinity/ic/blob/master/"
SOURCES = {
    "resource-limits": "https://docs.internetcomputer.org/references/resource-limits.md",
    "interface-spec": "https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md",
    "large-wasm": "https://docs.internetcomputer.org/guides/canister-management/large-wasm.md",
    "validation.rs": IC_CODE + "rs/embedders/src/wasm_utils/validation.rs",
    "embedders.rs": IC_CODE + "rs/config/src/embedders.rs",
    "embedders/lib.rs": IC_CODE + "rs/embedders/src/lib.rs",
    "limits.rs": IC_CODE + "rs/limits/src/lib.rs",
    "types.rs": IC_CODE + "rs/types/types/src/lib.rs",
    "Cargo.toml": IC_CODE + "Cargo.toml",
    "wasmtime": "https://github.com/bytecodealliance/wasmtime/blob/v48.0.1/crates/wasmtime/src/config.rs",
}

# The Internet Computer's limits on a canister's Wasm module: (limit, sources).
IC_LIMITS = {
    "module size": (100 * MiB, ["resource-limits", "embedders.rs"]),
    "install message": (2 * MiB, ["resource-limits", "limits.rs", "large-wasm"]),
    "code section": (12 * MiB, ["resource-limits", "validation.rs"]),
    "defined functions": (50_000, ["interface-spec", "embedders.rs"]),
    "globals": (1_000, ["interface-spec", "embedders.rs", "validation.rs"]),
    "instructions": (1_000_000, ["resource-limits", "validation.rs"]),
    "complexity": (1_000_000, ["validation.rs"]),
    "locals": (10_000, ["validation.rs"]),
    "function name": (1 * MiB, ["resource-limits", "validation.rs"]),
    "custom sections": (1_024, ["validation.rs"]),
    "wasm32 memory": (4 * GiB, ["resource-limits", "types.rs"]),
}
FEATURE_SOURCES = ["validation.rs", "Cargo.toml", "wasmtime"]

# The proposals the Internet Computer accepts, in wasm-tools' terms: wasmtime's Wasm 2.0
# defaults plus tail calls and memory64. validation.rs turns exceptions, function
# references, GC, multi-memory, relaxed SIMD and extended constants off, and the replica's
# wasmtime is built without threads.
IC_FEATURES = ["wasm2", "tail-call", "memory64"]

# Proposals beyond the MVP: (wasm-tools name, what it adds, Internet Computer support).
# A proposal comes before the ones it includes, so that searching for the required ones
# ends with the narrowest.
PROPOSALS = [
    ("mutable-global", "mutable global import/export", "partly: no imported globals"),
    ("sign-extension", "sign-extension operators", "yes"),
    ("saturating-float-to-int", "non-trapping float-to-int", "yes"),
    ("multi-value", "several results", "yes"),
    ("bulk-memory", "passive data, table.copy, ...", "partly: no table.copy/init"),
    ("bulk-memory-opt", "memory.copy and memory.fill", "yes"),
    ("reference-types", "externref, table.set, ...", "partly: no table.set/grow/fill"),
    ("call-indirect-overlong", "call_indirect's new encoding", "yes"),
    ("relaxed-simd", "relaxed SIMD", "no"),
    ("simd", "128-bit SIMD", "yes"),
    ("tail-call", "tail calls", "yes"),
    ("extended-const", "extended constant expressions", "no"),
    ("memory64", "64-bit memory (wasm64)", "yes"),
    ("multi-memory", "several memories", "no"),
    ("threads", "atomics and shared memory", "no"),
    ("exceptions", "exception handling", "no"),
    ("legacy-exceptions", "legacy exception handling", "no"),
    ("gc", "garbage collection", "no"),
    ("function-references", "typed function references", "no"),
]

# How the Internet Computer weighs instructions when it computes a function's complexity
# (`wasm_function_complexity` in validation.rs), in wasm-objdump's names. Others weigh 1.
WEIGHTS = {
    **dict.fromkeys("block loop if br br_if br_table call call_indirect memory.grow".split(), 50),
    "table.get": 14,
    "ref.func": 8,
    "ref.is_null": 6,
    **dict.fromkeys(
        """i32.trunc_f32_s i32.trunc_f32_u i32.trunc_f64_s i32.trunc_f64_u i64.extend_i32_s
        i64.extend_i32_u i64.trunc_f32_s i64.trunc_f32_u i64.trunc_f64_s i64.trunc_f64_u
        f32.convert_i32_s f32.convert_i32_u f32.convert_i64_s f32.convert_i64_u f32.demote_f64
        f64.convert_i32_s f64.convert_i32_u f64.convert_i64_s f64.convert_i64_u""".split(),
        5,
    ),
    **dict.fromkeys("f32.neg f32.abs f64.neg f64.abs memory.copy".split(), 4),
    **dict.fromkeys(
        """f32.copysign f64.copysign f64.eq i32.rem_u i32.rem_s i64.rem_u i64.rem_s i32.div_u
        i32.div_s i64.div_u i64.div_s memory.fill i32.load i64.load f32.load f64.load
        i32.load8_s i32.load8_u i32.load16_s i32.load16_u i64.load8_s i64.load8_u i64.load16_s
        i64.load16_u i64.load32_s i64.load32_u i32.trunc_sat_f32_s i32.trunc_sat_f32_u
        i32.trunc_sat_f64_s i32.trunc_sat_f64_u i64.trunc_sat_f32_s i64.trunc_sat_f32_u
        i64.trunc_sat_f64_s i64.trunc_sat_f64_u""".split(),
        3,
    ),
    **dict.fromkeys(
        """global.get i32.popcnt i64.popcnt select memory.size i32.store i32.store16 i32.store8
        i64.store i64.store32 i64.store16 i64.store8 f64.store f32.store i32.eqz i32.eq i32.ne
        i32.lt_s i32.lt_u i32.gt_s i32.gt_u i32.le_s i32.le_u i32.ge_s i32.ge_u i64.eqz i64.eq
        i64.ne i64.lt_s i64.lt_u i64.gt_s i64.gt_u i64.le_s i64.le_u i64.ge_s i64.ge_u f32.eq
        f32.ne f32.lt f32.gt f32.le f32.ge f64.ne f64.lt f64.gt f64.le f64.ge f32.ceil f64.ceil
        f32.floor f64.floor f32.sqrt f64.sqrt f32.trunc f64.trunc i32.reinterpret_f32
        i64.reinterpret_f64 f32.reinterpret_i32 f64.reinterpret_i64 i32.wrap_i64 i32.extend8_s
        i32.extend16_s i64.extend8_s i64.extend16_s i64.extend32_s f64.promote_f32""".split(),
        2,
    ),
}
# Instructions that the Internet Computer rejects (validation.rs).
REJECTED = ["table.grow", "table.set", "table.fill", "table.copy", "table.init"]

# Names for the inputs of the link, by file name.
ORIGINS = {
    "Hello.o": "Hello.lean",
    "libInit.a": "Lean's Init library",
    "libleanrt.a": "Lean runtime",
    "libc++.a": "libc++ and libc++abi",
    "libc++abi.a": "libc++ and libc++abi",
    "libc.a": "wasi-libc",
    "crt1-command.o": "wasi-libc",
    "libclang_rt.builtins-wasm32.a": "compiler-rt",
    "<internal>": "generated by wasm-ld",
}

WIDTH = 92


@dataclass
class Function:
    name: str
    body_bytes: int = 0
    instructions: int = 0
    complexity: int = 0
    locals: int = 0
    stack: bool = False  # whether it has a frame in the stack in linear memory


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def validates(wasm, features):
    """Whether wasm-tools accepts the module with exactly these proposals enabled."""
    flag = "--features=" + ",".join(["-all", *features])
    result = subprocess.run(
        ["wasm-tools", "validate", flag, wasm], capture_output=True, check=False
    )
    return result.returncode == 0


def required_proposals(wasm):
    """Proposals beyond the MVP that the module validates with, none of which can be left
    out. None if the module needs a proposal that is not in PROPOSALS."""
    required = [name for name, _, _ in PROPOSALS]
    if not validates(wasm, ["mvp", *required]):
        return None
    for name, _, _ in PROPOSALS:
        fewer = [p for p in required if p != name]
        if validates(wasm, ["mvp", *fewer]):
            required = fewer
    return required


def sections(wasm):
    """(name, size in bytes, number of entries or None) per section, from `wasm-objdump -h`."""
    result = []
    pattern = r'\s*(\w+) start=\S+ end=\S+ \(size=0x([0-9a-f]+)\)(?: count: (\d+))?(?: "(.*)")?'
    for line in run("wasm-objdump", "-h", wasm).splitlines():
        if m := re.fullmatch(pattern, line):
            name = f'Custom "{m[4]}"' if m[1] == "Custom" else m[1]
            result.append((name, int(m[2], 16), int(m[3]) if m[3] else None))
    return result


def details(wasm):
    """The entries that `wasm-objdump -x` lists per section, and the target features."""
    text = run("wasm-objdump", "-x", wasm)
    entries, section = {}, None
    for line in text.splitlines():
        if m := re.fullmatch(r"(\w+)(?:\[\d+\])?:", line):
            section = m[1]
            entries.setdefault(section, [])
        elif section and line.startswith(" - "):
            entries[section].append(line[3:])
    features = re.findall(r"^  - \[\+\] (\S+)$", text, re.MULTILINE)
    return entries, features


def imports_exports(entries):
    """[(kind, module, name)] and [(kind, name)]."""
    imports = [
        re.fullmatch(r"(\w+)\[\d+\] .*<- ([^.]+)\.(.*)", e).groups()
        for e in entries.get("Import", [])
    ]
    exports = [
        re.fullmatch(r'(\w+)\[\d+\](?: <.*>)? -> "(.*)"', e).groups()
        for e in entries.get("Export", [])
    ]
    return imports, exports


def functions(wasm, entries):
    """The defined functions, and how often each instruction occurs, from the disassembly."""
    funcs, ops = {}, Counter()
    for line in run("wasm-objdump", "-d", wasm).splitlines():
        if m := re.fullmatch(r"[0-9a-f]+ func\[(\d+)\](?: <(.*)>)?:", line):
            f = funcs[int(m[1])] = Function(m[2] or f"func[{m[1]}]")
        elif (m := re.fullmatch(r" [0-9a-f]+: [0-9a-f ]*\| *(.*)", line)) and m[1]:
            # (An empty text continues the bytes of a long instruction.)
            if local := re.fullmatch(r"local\[(\d+)(?:\.\.(\d+))?\] type=\S+", m[1]):
                f.locals += int(local[2] or local[1]) - int(local[1]) + 1
            else:
                op = m[1].split()[0]
                ops[op] += 1
                f.instructions += 1
                f.complexity += WEIGHTS.get(op, 1)
                f.stack |= m[1].endswith(" <__stack_pointer>")
    for e in entries["Code"]:
        m = re.fullmatch(r"func\[(\d+)\] size=(\d+).*", e)
        funcs[int(m[1])].body_bytes = int(m[2])
    return list(funcs.values()), ops


@dataclass
class Origin:
    code_bytes: int = 0
    functions: int = 0
    data_bytes: int = 0
    objects: set = field(default_factory=set)
    stack_users: int = 0


def origins(link_map, funcs):
    """What each input of the link contributes to the module, from wasm-ld's map. The map
    lists the functions in the order of the Code section, which is the order of `funcs`."""
    result = {}
    output = None
    code = iter(funcs)
    for line in Path(link_map).read_text().splitlines()[1:]:
        m = re.fullmatch(r"\s*\S+\s+[0-9a-f]+\s+([0-9a-f]+) (\s*)(.*)", line)
        size, indent, text = int(m[1], 16), len(m[2]), m[3]
        if indent == 0:
            output = text  # an output section, or a data segment within DATA
        elif indent == 8 and output in ("CODE", ".rodata", ".data"):
            # An input chunk: `file:(symbol)`, where the file may be `archive(member)`.
            obj = text.split(":(")[0]
            file = re.sub(r"\(.*\)$", "", obj).rsplit("/", 1)[-1]
            origin = result.setdefault(ORIGINS.get(file, file), Origin())
            origin.objects.add(obj)
            if output == "CODE":
                origin.code_bytes += size
                origin.functions += 1
                origin.stack_users += next(code).stack
            else:
                origin.data_bytes += size
    assert next(code, None) is None, "the map lists fewer functions than the module has"
    return result


def human(n):
    for unit, size in (("GiB", GiB), ("MiB", MiB), ("KiB", KiB)):
        if n >= size:
            return f"{n / size:.3g} {unit}"
    return f"{n} bytes"


def refs(sources):
    keys = list(SOURCES)
    return "[" + ",".join(str(n) for n in sorted(keys.index(s) + 1 for s in sources)) + "]"


def fill(text, indent="", subsequent=""):
    return textwrap.fill(
        text, WIDTH, initial_indent=indent, subsequent_indent=subsequent, break_on_hyphens=False
    )


def heading(title):
    print(f"\n{title}\n{'-' * len(title)}")


def main(wasm, opt_wasm, link_map, about):
    name = Path(wasm).name
    secs = sections(wasm)
    entries, target_features = details(wasm)
    imports, exports = imports_exports(entries)
    funcs, ops = functions(wasm, entries)
    required = required_proposals(wasm)
    kinds = Counter(kind for kind, _, _ in imports)
    globals_ = [
        re.match(r"global\[\d+\] (\S+) mutable=(\d)", g).groups() for g in entries.get("Global", [])
    ]
    tables = [
        re.match(r"table\[\d+\] type=(\S+) initial=(\d+)", t).groups()
        for t in entries.get("Table", [])
    ]
    memories = [
        re.match(r"memory\[\d+\] pages: initial=(\d+)(?: max=(\d+))?", m).groups()
        for m in entries.get("Memory", [])
    ]
    data = [
        re.match(r"segment\[\d+\](?: <(.*?)>)? (\S+) size=(\d+)(?: - init (.*))?", d).groups()
        for d in entries.get("Data", [])
    ]
    largest = max(funcs, key=lambda f: f.instructions)
    most_complex = max(funcs, key=lambda f: f.complexity)
    most_locals = max(funcs, key=lambda f: f.locals)
    longest_name = max(len(f.name.encode()) for f in funcs)

    title = f"Report on {name}"
    print(f"{title}\n{'=' * len(title)}\n")
    print(fill(about))

    heading("Size")
    print(f"  {'':16} {'file':>11} {'gzipped':>11} {'Code section':>13} {'name section':>13}")
    for path in (wasm, opt_wasm):
        contents = Path(path).read_bytes()
        sizes = {section: size for section, size, _ in sections(path)}
        names = sizes.get('Custom "name"', 0)
        print(
            f"  {Path(path).name:16} {len(contents):>11,} {len(gzip.compress(contents, 9, mtime=0)):>11,}"
            f" {sizes['Code']:>13,} {names:>13,}"
        )
    opt_imports, opt_exports = imports_exports(details(opt_wasm)[0])
    same = sorted(opt_imports) == sorted(imports) and sorted(opt_exports) == sorted(exports)
    print(
        fill(
            f"(In bytes, gzipped at level 9. {Path(opt_wasm).name} is {name} after `wasm-opt -O`,"
            " which also drops the name section. It has"
            f" {'the same' if same else 'DIFFERENT'} imports and exports.)",
            "  ",
            "  ",
        )
    )

    heading(f"Sections of {name}")
    print(f"  {'section':26} {'bytes':>11} {'entries':>8}")
    for section, size, count in secs:
        print(f"  {section:26} {size:>11,} {'' if count is None else f'{count:,}':>8}".rstrip())

    heading("Contents")
    print(f"  functions         {kinds['func']:,} imported, {len(funcs):,} defined")
    print(
        f"  globals           {kinds['global']} imported, {len(globals_)} defined: "
        + ", ".join(f"{t}{' (mutable)' if m == '1' else ''}" for t, m in globals_)
    )
    print(
        f"  tables            {kinds['table']} imported, {len(tables)} defined: "
        + ", ".join(f"{t} with {int(n):,} entries" for t, n in tables)
    )
    for initial, maximum in memories:
        print(
            f"  memories          {kinds['memory']} imported, {len(memories)} defined: {int(initial):,} pages"
            f" ({int(initial) * 64 * KiB:,} bytes) at first, "
            + ("no maximum" if maximum is None else f"at most {int(maximum):,} pages")
        )
    print(
        f"  data segments     {len(data)}: "
        + ", ".join(f"{n or '?'} {int(s):,} bytes" for n, _, s, _ in data)
    )
    print(f"  element segments  {len(entries.get('Elem', []))}")
    print(f"  start function    {'yes' if entries.get('Start') else 'none'}")
    print(
        f"  most instructions {largest.instructions:,} in {largest.name} ({largest.body_bytes:,} bytes)"
    )
    print(
        f"  most complex      {most_complex.name}, with a complexity of {most_complex.complexity:,}"
    )
    print(f"  most locals       {most_locals.locals:,} in {most_locals.name}")
    print(f"  longest name      {longest_name:,} bytes")

    heading("Code and data by origin, from the link map")
    print(
        f"  {'':22} {'code bytes':>11} {'functions':>10} {'data bytes':>11} {'object files':>13}"
        f" {'stack users':>12}"
    )
    rows = sorted(origins(link_map, funcs).items(), key=lambda item: -item[1].code_bytes)
    total = Origin()
    for _, o in rows:
        total.code_bytes += o.code_bytes
        total.functions += o.functions
        total.data_bytes += o.data_bytes
        total.objects |= o.objects
        total.stack_users += o.stack_users
    for origin, o in [*rows, ("total", total)]:
        print(
            f"  {origin:22} {o.code_bytes:>11,} {o.functions:>10,} {o.data_bytes:>11,} {len(o.objects):>13,}"
            f" {o.stack_users:>12,}"
        )
    print(
        fill(
            "(Data is .rodata and .data, without the padding between the pieces. An object file"
            " is a file or archive member that contributes code or data. A stack user is a"
            " function with a frame in the stack in linear memory (it uses __stack_pointer); the"
            " others keep all their locals in Wasm locals.)",
            "  ",
            "  ",
        )
    )

    heading(f"Imports ({len(imports)})")
    for module in sorted({m for _, m, _ in imports}):
        names = [
            f"{n}{'' if kind == 'func' else f' ({kind})'}" for kind, m, n in imports if m == module
        ]
        print(f"  {module} ({len(names)}):")
        print(fill(", ".join(names), "    ", "    "))

    heading(f"Exports ({len(exports)})")
    for kind, export in exports:
        print(f"  {export:20} {kind}")

    heading("Wasm features")
    print(
        fill(
            "Enabled when compiling (target_features section): " + ", ".join(target_features) + "."
        )
    )
    print()
    if required is None:
        print(
            fill("Used: not determined, as the module needs a proposal that is not listed below.")
        )
    else:
        print(
            fill(
                "Used: wasm-tools validate accepts the module with these proposals beyond the MVP, and"
                " rejects it when any one of them is left out: "
                + (", ".join(required) or "none")
                + "."
            )
        )
    print()
    print(
        f"  {'proposal':24} {'used':5} {'what it adds':31} Internet Computer {refs(FEATURE_SOURCES)}"
    )
    for proposal, what, ic in PROPOSALS:
        used = "?" if required is None else "yes" if proposal in required else "no"
        print(f"  {proposal:24} {used:5} {what:31} {ic}")

    heading("Compared with the Internet Computer's limits")
    checks = []

    def check(ok, text, sources, otherwise="OVER LIMIT"):
        checks.append(("OK" if ok else otherwise, text, sources))

    def within(limit_name, what, value, unit=""):
        limit, sources = IC_LIMITS[limit_name]
        shown = f"{limit:,}{unit}" + (f" ({human(limit)})" if unit else "")
        check(value <= limit, f"{what}: {value:,}{unit}; the limit is {shown}.", sources)

    size = Path(wasm).stat().st_size
    gzipped = len(gzip.compress(Path(wasm).read_bytes(), 9, mtime=0))
    within("module size", "Module size", size, " bytes")
    limit, sources = IC_LIMITS["install message"]
    check(
        gzipped <= limit,
        f"Upload: {gzipped:,} bytes gzipped ({size:,} uncompressed), sent in an install_code message of"
        f" at most {limit:,} bytes ({human(limit)}). Larger modules are uploaded in chunks.",
        sources,
        "NEEDS WORK",
    )
    within("code section", "Code section", {s: n for s, n, _ in secs}["Code"], " bytes")
    within("defined functions", "Defined functions", len(funcs))
    limit, sources = IC_LIMITS["globals"]
    numeric = all(t in ("i32", "i64", "f32", "f64", "v128") for t, _ in globals_)
    check(
        len(globals_) <= limit and numeric and not kinds["global"],
        f"Globals: {len(globals_)} ({', '.join(t for t, _ in globals_)}), {kinds['global']} imported; the"
        f" limit is {limit:,}, each of type i32, i64, f32, f64 or v128, and none imported.",
        sources,
    )
    within("instructions", "Most instructions in a function", largest.instructions)
    within("complexity", "Highest complexity of a function", most_complex.complexity)
    within("locals", "Most locals in a function", most_locals.locals)
    within("function name", "Longest function name", longest_name, " bytes")
    custom = [s for s, _, _ in secs if s.startswith("Custom")]
    icp = [s for s in custom if s.startswith('Custom "icp:')]
    within("custom sections", f"Custom sections ({len(icp)} of them icp: sections)", len(custom))
    rejected = {op: ops[op] for op in REJECTED if ops[op]}
    check(
        all(t == "funcref" for t, _ in tables) and not rejected,
        "Tables: "
        + (", ".join(t for t, _ in tables) or "none")
        + ", and "
        + (", ".join(f"{n:,} {op}" for op, n in rejected.items()) or "no " + ", ".join(REJECTED))
        + " instructions; the Internet Computer requires funcref tables and rejects those instructions.",
        ["validation.rs"],
        "NEEDS WORK",
    )
    check(
        len(memories) + kinds["memory"] <= 1,
        f"Memories: {len(memories)} defined, {kinds['memory']} imported; at most one is allowed.",
        ["interface-spec", "validation.rs"],
    )
    fixed = [d for d in data if d[1] == "passive" or re.fullmatch(r"i32=-?\d+", d[3] or "")]
    check(
        len(fixed) == len(data),
        f"Data segments: {len(fixed)} of {len(data)} are passive or start at an i32.const offset, as"
        " required.",
        ["validation.rs"],
        "NEEDS WORK",
    )
    within("wasm32 memory", "Initial memory", sum(int(i) for i, _ in memories) * 64 * KiB, " bytes")
    accepted = validates(wasm, IC_FEATURES)
    check(
        accepted,
        f"Wasm features: wasm-tools validate {'accepts' if accepted else 'REJECTS'} the module with"
        " only the proposals that the Internet Computer accepts (--features="
        + ",".join(["-all", *IC_FEATURES])
        + ").",
        FEATURE_SOURCES,
        "NEEDS WORK",
    )
    foreign = Counter(module for _, module, _ in imports if module != "ic0")
    check(
        not foreign,
        f"Imports: {sum(foreign.values())} of {len(imports)} are not from ic0 ("
        + ", ".join(f"{n} from {m}" for m, n in sorted(foreign.items()))
        + "). A canister may only import functions of the ic0 System API; install_code rejects"
        " any other import.",
        ["interface-spec", "validation.rs"],
        "NEEDS WORK",
    )
    entry_points = [e for _, e in exports if e.startswith("canister_")]
    others = [e for _, e in exports if not e.startswith("canister_")]
    check(
        entry_points,
        f"Exports: {len(entry_points)} canister entry points (canister_init, canister_update <name>,"
        " canister_query <name>, ...). The Internet Computer only calls those, and ignores the"
        " others: " + (", ".join(others) or "none") + ".",
        ["interface-spec"],
        "NEEDS WORK",
    )
    for status, text, sources in checks:
        print(fill(f"{status:10}  {text} {refs(sources)}", "", " " * 12))

    print("\nNot checked here, as they depend on what the code does when it runs:")
    instructions = (
        "Instructions: at most 40 billion per update call, 5 billion per query and 300 billion"
        " per install or upgrade, which includes canister_init."
    )
    stack = (
        "Stack: wasmtime gets 5 MiB of native stack for Wasm frames on the Internet Computer."
        " The stack in linear memory, which only stack users need, is separate."
    )
    print(fill(f"- {instructions} {refs(['resource-limits'])}", "  ", "    "))
    print(fill(f"- {stack} {refs(['embedders/lib.rs'])}", "  ", "    "))

    heading("Sources")
    print(
        fill(
            "The Internet Computer's limits are those of replica release-2026-10-08_03-33-base, on"
            " mainnet since 2026-10-15. The cited code on master was the same on 2026-10-17."
        )
    )
    for i, url in enumerate(SOURCES.values(), 1):
        print(f"  [{i}] {url}")


if __name__ == "__main__":
    main(*sys.argv[1:])
