#!/usr/bin/env python3
"""The numbers the review rubric (docs/review-rubric.md) is scored on, read from the sources: run it before a review
and paste its output into the review. `scripts/metrics.py` (from anywhere); `--json` for a machine."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)


def swift_files(*dirs):
    return [p for d in dirs for p in Path(d).rglob("*.swift")]


def lines(p):
    return p.read_text(encoding="utf-8", errors="replace").split("\n")


def code_lines(p):
    """Lines that aren't comments (a line starting with // or ///); blank ones too are left out."""
    return [l for l in lines(p) if l.strip() and not l.strip().startswith("//")]


def count_loc(*dirs):
    return sum(len(code_lines(p)) for p in swift_files(*dirs))


def grep_count(pattern, files):
    r = re.compile(pattern)
    return sum(len(r.findall("\n".join(code_lines(p)))) for p in files)


def builtin_modules():
    return sorted(p.name for p in Path("Sources/Builtins").iterdir() if p.is_dir())


def tested_builtins():
    tests = "\n".join(p.read_text(errors="replace") for p in swift_files("Tests"))
    return {m: bool(re.search(rf"\bBuiltin{m}\b", tests)) for m in builtin_modules()}


def fix_share(days=14):
    out = subprocess.run(["git", "log", f"--since={days}.days", "--format=%s"], capture_output=True, text=True).stdout.splitlines()
    fixes = [s for s in out if re.match(r"fix(\(|:)", s)]
    return len(fixes), len(out)


def main():
    sources = swift_files("Sources")
    kelpkit, builtins = count_loc("Sources/KelpKit"), count_loc("Sources/Builtins")
    package = grep_count(r"\bpackage\s+(?:static|final|override|lazy|nonisolated|convenience|required|func|var|let|class|struct|enum|protocol|typealias|subscript|actor|init)\b",
                         swift_files("Sources/KelpKit"))
    app_ext = [p for p in swift_files("Sources/KelpKit", "Sources/Builtins")
               if p.name != "AppModel.swift" and re.search(r"^extension AppModel\b", p.read_text(errors="replace"), re.M)]
    sessions_ext = grep_count(r"(?m)^extension Sessions\b", swift_files("Sources/Daemon"))
    workspaces_handlers = len(re.findall(r"workspaces: Workspaces\)", "\n".join(p.read_text(errors="replace") for p in swift_files("Sources/Daemon"))))
    sessions_handlers = len(re.findall(r"sessions: Sessions\)", "\n".join(p.read_text(errors="replace") for p in swift_files("Sources/Daemon"))))
    settings_literals = grep_count(r"""settings(?:\[|\.(?:string|bool|int|double|value)\()\s*"[a-z]+\.[\w.]+""", sources)
    long120 = sum(1 for p in sources for l in code_lines(p) if len(l) > 120)
    long160 = sum(1 for p in sources for l in code_lines(p) if len(l) > 160)
    one_letter = grep_count(r"\b(?:let|var)\s+[a-z]\b(?!\w)|\{\s*\[?[a-z](?:,\s*[a-z])*\]?\s+in\b|\(\s*[a-z]\s*:", sources)
    joined = sum(1 for p in sources for l in code_lines(p) if re.search(r";\s*\S", l) and "for (" not in l)
    big_files = sorted((len(lines(p)), str(p)) for p in sources if len(lines(p)) > 400)
    flaky = [l for l in Path("Tests/flaky.txt").read_text().splitlines() if l.strip() and not l.startswith("#")]
    sleeps = grep_count(r"Task\.sleep|usleep\(|Thread\.sleep|sleep\(for:", swift_files("Tests"))
    loops = grep_count(r"for _ in 0\.\.<\d+ where", swift_files("Tests"))
    tests = grep_count(r"@Test\b", swift_files("Tests"))
    vm_tests = grep_count(r"@Test\b", swift_files("Tests/KelpVMTests"))
    vm_loc = count_loc("Sources/KelpVM")
    tryq = grep_count(r"\btry\?", sources)
    fixes, commits = fix_share()

    m = {
        "architecture": {
            "kelpkit_loc": kelpkit, "builtins_loc": builtins, "shell_share": round(kelpkit / (kelpkit + builtins), 2),
            "kelpkit_package": package, "appmodel_extension_files": len(app_ext),
            "sessions_extensions": sessions_ext, "sessions_handlers": sessions_handlers, "workspaces_handlers": workspaces_handlers,
            "settings_key_literals": settings_literals,
        },
        "maintainability": {
            "lines_over_120": long120, "lines_over_160": long160, "one_letter_names": one_letter,
            "joined_statement_lines": joined, "files_over_400": len(big_files),
            "fix_commits_14d": f"{fixes}/{commits}",
        },
        "tests": {
            "tests": tests, "flaky_listed": len(flaky), "sleeps_in_tests": sleeps, "inline_wait_loops": loops,
            "builtins_without_tests": [k for k, v in tested_builtins().items() if not v],
            "kelpvm_tests_per_kloc": round(vm_tests / max(vm_loc, 1) * 1000, 1),
        },
        "reliability": {"try_question": tryq},
    }
    if "--json" in sys.argv:
        print(json.dumps(m, indent=2))
        return
    for section, values in m.items():
        print(f"## {section}")
        for k, v in values.items():
            print(f"  {k:28} {v}")


if __name__ == "__main__":
    main()
