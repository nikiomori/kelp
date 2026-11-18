#!/usr/bin/env python3
"""How good the editor's gray text is, measured on this repository's own Swift code: run it before and after a change
to how a model is asked (Sources/Daemon/Suggest, Sources/EditorKit/InlineSuggestion.swift).

It picks places in Sources (the same ones each run), hides the rest of a line, or a whole line as after Return, asks
a model in Ollama on this Mac the way Kelp asks it, and compares the answer's first line with what was there.
It asks each place twice, a few keys apart, as typing does, and times the second ask, which finds Ollama's cache warm.

  scripts/suggest-eval.py                                  qwen2.5-coder:1.5b-base, 200 places
  scripts/suggest-eval.py --model hf.co/mradermacher/Seed-Coder-8B-Base-GGUF:Q4_K_M --places 100

Prints, for every answer and for those Kelp shows (the model sure of each token): how many came exactly as written,
how many were nearly (similarity ≥ 0.8), and the wait. ±5 points is the noise of 100 places. Needs only Ollama.
"""
import argparse
import difflib
import json
import random
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# What Kelp does; keep in step with the sources named.
PREFIX, SUFFIX, STEP = 6000, 2000, 1500   # InlineSuggestion.prefixLimit, suffixLimit, windowStep
SURE = -0.8                               # FillIn.sureEnough
# FillIn's prompts for the families measured: the model's markers and stops (three, then "\n" for one line).
FAMILIES = {
    "qwen": ("<|fim_prefix|>{p}<|fim_suffix|>{s}<|fim_middle|>", ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>"]),
    "seed-coder": ("<[fim-suffix]>{s}<[fim-prefix]>{p}<[fim-middle]>",
                   ["<[end~of~sentence]>", "<[fim-suffix]>", "<[fim-prefix]>"]),
}


def places(count, seed=7):
    rng = random.Random(seed)
    files = sorted(ROOT.joinpath("Sources").rglob("*.swift"))
    found = []
    while len(found) < count:
        path = rng.choice(files)
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        i = rng.randrange(len(lines))
        line = lines[i]
        if len(line.strip()) < 15 or line.strip().startswith("//"):
            continue
        indent = len(line) - len(line.lstrip())
        cut = rng.randrange(indent + 4, len(line) - 3) if len(found) % 2 == 0 else indent
        at = sum(len(l) + 1 for l in lines[:i]) + cut
        found.append({"text": text, "at": at, "truth": line[cut:].rstrip()})
    return found


def window_start(text, at):
    back = at - PREFIX
    if back <= 0:
        return 0
    snapped = back // STEP * STEP
    return text.rfind("\n", 0, snapped) + 1


def window_end(text, at):
    forward = at + SUFFIX
    if forward >= len(text):
        return len(text)
    snapped = -(-forward // STEP) * STEP
    if snapped >= len(text):
        return len(text)
    nl = text.find("\n", snapped)
    return len(text) if nl < 0 else nl + 1


def one_line(prefix):
    lines = prefix.split("\n")
    if lines[-1].strip():
        return True
    above = next((l.strip() for l in reversed(lines[:-1]) if l.strip()), "")
    return not (above.endswith("{") or above.endswith(":"))


def ask(model, text, at, tokens=None):
    prefix = text[window_start(text, at):at]
    suffix = text[at:window_end(text, at)]
    suffix = suffix[suffix.find("\n"):] if "\n" in suffix else ""   # the editor asks with the line's rest gone
    single = one_line(prefix)
    template, stops = FAMILIES["seed-coder" if "seed-coder" in model.lower() else "qwen"]
    body = {"model": model, "prompt": template.format(p=prefix, s=suffix), "raw": True,
            "stream": False, "logprobs": True,
            "options": {"num_predict": tokens or (48 if single else 128), "temperature": 0,
                        "stop": stops + (["\n"] if single else [])}}
    req = urllib.request.Request("http://127.0.0.1:11434/api/generate", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        answer = json.load(r)
    wait = time.time() - started
    first_line = []
    for token in answer.get("logprobs") or []:
        if "\n" in token["token"]:
            break
        first_line.append(token["logprob"])
    sure = not first_line or min(first_line) >= SURE
    return answer["response"].split("\n")[0].rstrip(), sure, wait


def report(label, rows, total):
    if not rows:
        return print(f"{label:8} none")
    exact = sum(r["got"].strip() == r["truth"].strip() for r in rows) / len(rows)
    near = sum(difflib.SequenceMatcher(None, r["got"].strip(), r["truth"].strip()).ratio() >= 0.8
               for r in rows) / len(rows)
    waits = sorted(r["wait"] for r in rows)
    print(f"{label:8} {len(rows) / total:4.0%} of places   exactly {exact:4.0%}   nearly {near:4.0%}   "
          f"wait {waits[len(waits) // 2] * 1000:4.0f} ms (p90 {waits[int(len(waits) * 0.9)] * 1000:4.0f})")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model", default="qwen2.5-coder:1.5b-base")
    parser.add_argument("--places", type=int, default=200)
    args = parser.parse_args()
    rows = []
    for place in places(args.places):
        ask(args.model, place["text"], place["at"] - 3, tokens=1)   # three keys earlier: what Ollama holds now
        got, sure, wait = ask(args.model, place["text"], place["at"])
        rows.append({"got": got, "truth": place["truth"], "sure": sure, "wait": wait})
    print(f"{args.model}, {args.places} places in {ROOT.name}/Sources")
    report("all", rows, len(rows))
    report("shown", [r for r in rows if r["sure"]], len(rows))


if __name__ == "__main__":
    main()
