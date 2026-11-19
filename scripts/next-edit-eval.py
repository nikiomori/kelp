#!/usr/bin/env python3
"""How good the editor's next edit is, measured on this repository's own history: run it before and after a change to
how the model is asked (Sources/Daemon/Suggest/NextEditServer.swift, Sources/EditorKit/NextEdit.swift).

It takes commits that made two edits near each other in one Swift file, shows the model the first as just made, the
way Kelp does, and compares what it offers with the second. It starts llama-server as kelpd does (llama.cpp from
Homebrew; the first run downloads the model, 1.5 GB) and stops it at the end.

  scripts/next-edit-eval.py                 150 commits
  scripts/next-edit-eval.py --cases 60

Prints how often an edit is offered, how many of those were exactly the edit made, how many nearly (similarity of
the lines changed ≥ 0.8), and the wait. A strict test: a commit's second edit often has nothing to do with its first.
About 40 edits are offered in 150 commits, so ±15 points is noise: other commits gave 21 % to 43 % exactly.
"""
import argparse
import difflib
import json
import random
import re
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# What Kelp does; keep in step with the sources named.
HALF = 8              # NextEdit.half
MOST = 12             # NextEdit.most
SURE = -0.5           # NextEditServer.sureEnough
ARGUMENTS = [         # NextEditServer.arguments
    "--hf-repo", "sweepai/sweep-next-edit-1.5B", "--hf-file", "sweep-next-edit-1.5b.q8_0.v2.gguf", "--host",
    "127.0.0.1", "-c", "8192", "-np", "1", "-ngl", "99", "--spec-type", "ngram-simple",
    "--spec-ngram-simple-size-n", "4", "--spec-ngram-simple-size-m", "32",
]
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True).stdout


def hunks(diff):
    found, hunk = [], None
    for line in diff.split("\n"):
        m = HUNK.match(line)
        if m:
            start, count = int(m.group(1)), int(m.group(2) or 1)
            hunk = {"start": start if count else start + 1, "count": count, "old": [], "new": []}
            found.append(hunk)
        elif hunk and line.startswith("-") and not line.startswith("---"):
            hunk["old"].append(line[1:])
        elif hunk and line.startswith("+") and not line.startswith("+++"):
            hunk["new"].append(line[1:])
    return found


def apply(lines, edits):
    out, at = [], 1
    for h in edits:
        out += lines[at - 1:h["start"] - 1]
        at = h["start"]
        out += h["new"]
        at += h["count"]
    return out + lines[at - 1:]


def cases(count, seed=3):
    # Commits up to a fixed day, so a run next month asks about the same ones: before and after compare.
    shas = git("log", "--no-merges", "--until=2026-11-18", "--format=%H", "-n", "1500", "--", "Sources").split()
    random.Random(seed).shuffle(shas)
    found = []
    for sha in shas:
        for path in git("diff-tree", "--no-commit-id", "--name-only", "-r", sha).split():
            if not path.endswith(".swift"):
                continue
            edits = hunks(git("diff", "-U0", f"{sha}^", sha, "--", path))
            if len(edits) < 2:
                continue
            first, second = edits[0], edits[1]
            if not (first["old"] or first["new"]) or not (second["old"] or second["new"]) \
                    or second["start"] - (first["start"] + first["count"]) > HALF - 3 \
                    or len(first["old"]) + len(first["new"]) > 12 or len(second["old"]) + len(second["new"]) > 12:
                continue
            before = git("show", f"{sha}^:{path}").split("\n")
            now, then = apply(before, [first]), apply(before, [first, second])
            cursor = first["start"] + len(first["new"]) - 1
            low, high = max(0, cursor - HALF), min(len(now), cursor + HALF + 1)
            moved = len(first["new"]) - first["count"]
            found.append({
                "path": path, "old": "\n".join(first["old"]), "new": "\n".join(first["new"]),
                "original": "\n".join(before[low:high - moved]), "current": "\n".join(now[low:high]),
                "next": "\n".join(then[low:high + len(second["new"]) - second["count"]]),
            })
            break
        if len(found) >= count:
            break
    return found


def prompt(case):   # NextEditServer.prompt
    p = case["path"]
    return "\n".join([f"<|file_sep|>{p}.diff", "original:", case["old"], "updated:", case["new"],
                      f"<|file_sep|>original/{p}", case["original"], f"<|file_sep|>current/{p}", case["current"],
                      f"<|file_sep|>updated/{p}", ""])


def ask(base, case):
    body = {"prompt": prompt(case), "n_predict": 512, "temperature": 0, "cache_prompt": True, "n_probs": 1,
            "stop": ["<|file_sep|>", "</s>"]}
    request = urllib.request.Request(base + "/completion", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=60) as r:
        answer = json.load(r)
    least = min([t["logprob"] for t in answer.get("completion_probabilities") or []] or [0])
    return (answer["content"] if least >= SURE else None), time.time() - started


def offered(answer, current):
    """The lines the answer changes, as NextEdit.proposal finds them; None when it offers nothing."""
    if answer is None:
        return None
    now, got = current.split("\n"), answer.split("\n")
    blank = lambda line: line.strip() == ""
    while len(got) > 1 and blank(got[-1]) and not blank(now[-1]):
        got.pop()
    same = lambda a, b: a.rstrip() == b.rstrip()
    start = 0
    while start < len(now) and start < len(got) and same(now[start], got[start]):
        start += 1
    if start == len(now) == len(got):
        return None
    end = 0
    while end < len(now) - start and end < len(got) - start and same(now[-1 - end], got[-1 - end]):
        end += 1
    old, new = now[start:len(now) - end], got[start:len(got) - end]
    if len(old) > MOST or len(new) > MOST or (end == 0 and len(new) < len(old)):
        return None
    return got


def norm(text):   # what the eye sees: no spaces at a line's end, no blank lines around
    return "\n".join(line.rstrip() for line in text.split("\n")).strip("\n")


def changed(lines, current):
    return [l for l in difflib.ndiff(current.split("\n"), lines) if l[:1] in "+-"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cases", type=int, default=150)
    args = parser.parse_args()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = subprocess.Popen(["llama-server", *ARGUMENTS, "--port", str(port)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}"
    try:
        while True:   # the first run downloads the model
            try:
                with urllib.request.urlopen(base + "/health", timeout=1) as r:
                    if r.status == 200:
                        break
            except OSError:
                if server.poll() is not None:
                    raise SystemExit("llama-server stopped: brew install llama.cpp")
            time.sleep(0.5)
        rows = []
        for case in cases(args.cases):
            answer, wait = ask(base, case)
            got = offered(answer, case["current"])
            mine, real = (changed(got, case["current"]) if got else []), changed(case["next"].split("\n"),
                                                                                 case["current"])
            rows.append({"offered": got is not None, "wait": wait,
                         "exact": got is not None and norm("\n".join(got)) == norm(case["next"]),
                         "near": got is not None and difflib.SequenceMatcher(
                             None, "\n".join(mine), "\n".join(real)).ratio() >= 0.8})
    finally:
        server.terminate()
    shown = [r for r in rows if r["offered"]]
    waits = sorted(r["wait"] for r in rows)
    share = lambda key: sum(r[key] for r in shown) / max(len(shown), 1)
    print(f"Sweep Next-Edit 1.5B, {len(rows)} commits of this repository: offers an edit after {len(shown) / len(rows):.0%}"
          f"   exactly the next {share('exact'):.0%}   nearly {share('near'):.0%}   "
          f"wait {waits[len(waits) // 2] * 1000:.0f} ms (p90 {waits[int(len(waits) * 0.9)] * 1000:.0f})")


if __name__ == "__main__":
    main()
