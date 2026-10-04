#!/usr/bin/env python3
"""Compare zit and VIVTC on cached real video, with fresh nodes each run.

Example:
  zig build --release=fast
  .venv/bin/python scripts/bench_vivtc.py source1.vob source2.vob \
      --vivtc-plugin /path/to/vivtc.so --json build/bench_vivtc.json

The reported rates are output frames/second. Source decoding, graph creation,
and warmup are excluded. Every run processes the same input-frame interval.
VFM has no deinterlacing fallback; zit_fps30_di0 disables zit's fallback for
the field-matching comparison. This measures throughput, not image quality.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
import os
import platform
import random
import statistics
import subprocess
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

import vapoursynth as vs

ROOT = Path(__file__).resolve().parents[1]
PIPELINES = ("source_only", "zit_fps30", "zit_fps30_di0", "vfm",
             "zit_fps24", "vfm_vdecimate")


def pull(node, start, stop, prefetch):
    """Bounded asynchronous requests; consume frames without copying pixels."""
    pending = deque()
    for n in range(start, stop):
        pending.append(node.get_frame_async(n))
        if len(pending) >= prefetch:
            pending.popleft().result(timeout=120).close()
    for future in pending:
        future.result(timeout=120).close()


def build_pipeline(core, source, name):
    if name == "source_only":
        return source
    if name == "zit_fps30":
        return core.zit.IT(source, fps=30)
    if name == "zit_fps30_di0":
        return core.zit.IT(source, fps=30, diMode=0)
    if name == "zit_fps24":
        return core.zit.IT(source, fps=24)
    if name == "vfm":
        return core.vivtc.VFM(source, order=1, field=1)
    if name == "vfm_vdecimate":
        return core.vivtc.VDecimate(core.vivtc.VFM(source, order=1, field=1))
    raise ValueError(name)


def command_output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def artifact(path):
    path = Path(path).resolve()
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="+", type=Path)
    parser.add_argument("--start", type=int, default=9000)
    parser.add_argument("--frames", type=int, default=3000, help="measured input frames")
    parser.add_argument("--warmup", type=int, default=250, help="warmup input frames")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--threads", type=int, nargs="+", default=[1, 8])
    parser.add_argument("--zit-plugin", type=Path, default=ROOT / "zig-out/lib/libzit.so")
    parser.add_argument("--vivtc-plugin", type=Path)
    parser.add_argument("--json", type=Path, default=ROOT / "build/bench_vivtc.json")
    args = parser.parse_args()
    if (args.start < 0 or args.frames <= 0 or args.frames % 5 or args.warmup < 0
            or args.warmup % 5 or args.runs < 1 or min(args.threads) < 1):
        parser.error("frames/warmup must be multiples of 5; counts and threads must be valid")

    core = vs.core
    core.max_cache_size = 4096
    core.std.LoadPlugin(str(args.zit_plugin.resolve()))
    if args.vivtc_plugin and not hasattr(core, "vivtc"):
        core.std.LoadPlugin(str(args.vivtc_plugin.resolve()))
    if not hasattr(core, "vivtc"):
        parser.error("VIVTC is not loaded; supply --vivtc-plugin")
    vivtc_path = Path(core.vivtc.plugin_path).resolve()
    if args.vivtc_plugin and vivtc_path != args.vivtc_plugin.resolve():
        parser.error(f"a different VIVTC binary is already loaded: {vivtc_path}")
    distributions = {}
    for name in ("VapourSynth", "vapoursynth-vivtc", "vapoursynth-bestsource"):
        try:
            distributions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            distributions[name] = None
    cpu = platform.processor()
    if Path("/proc/cpuinfo").exists():
        cpu = next(line.split(":", 1)[1].strip()
                   for line in Path("/proc/cpuinfo").read_text().splitlines()
                   if line.startswith("model name"))
    report = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "cpu": cpu, "platform": platform.platform(),
        "python": platform.python_version(), "vapoursynth": str(core),
        "distributions": distributions,
        "processing_device": "CPU (both plugins)",
        "zig": command_output("zig", "version"), "git_commit": command_output("git", "rev-parse", "HEAD"),
        "zit_binary": artifact(args.zit_plugin),
        "vivtc_binary": artifact(vivtc_path),
        "plugin_versions": {p.namespace: f"{p.version.major}.{p.version.minor}"
                            for p in core.plugins() if p.namespace in ("zit", "vivtc", "bs")},
        "parameters": {"start": args.start, "input_frames": args.frames,
                       "warmup_input_frames": args.warmup, "runs": args.runs,
                       "threads": args.threads, "prefetch": "equal to thread count",
                       "vfm": {"order": 1, "field": 1},
                       "cache_mib": core.max_cache_size},
        "method": "Predecoded source cache; fresh filter nodes each run; randomized run order; "
                  "warmup excluded; no pixel copies, hashing, encoding, or concurrent benchmarks.",
        "sources": [], "samples": [], "summary": [],
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.json.write_text(json.dumps(report, indent=2) + "\n")

    for path in args.sources:
        core.num_threads = max(args.threads)
        full = core.bs.VideoSource(str(path.resolve()), threads=2, cachesize=64)
        total_input = args.warmup + args.frames
        if args.start + total_input > full.num_frames:
            parser.error(f"{path}: requested interval exceeds clip length")
        decoded = full[args.start:args.start + total_input]
        evaluations = [0]

        def count_source(n, f):
            evaluations[0] += 1
            return f

        source = core.std.ModifyFrame(decoded, decoded, count_source)
        core.std.SetVideoCache(source, mode=1, fixedsize=1, maxsize=total_input)
        print(f"\n{path.name}: {source.width}x{source.height} {source.format.name}; "
              f"caching {total_input} input frames from {args.start}", flush=True)
        pull(source, 0, source.num_frames, max(args.threads))
        cache_evaluations = evaluations[0]
        report["sources"].append({"name": path.name, "width": source.width,
                                  "height": source.height, "format": source.format.name,
                                  "fps_num": source.fps_num, "fps_den": source.fps_den,
                                  "total_source_frames": full.num_frames,
                                  "cached_frames": source.num_frames,
                                  "initial_source_evaluations": cache_evaluations})
        print(f"  cached; {cache_evaluations} source evaluations", flush=True)
        for repeat in range(args.runs):
            jobs = [(threads, name) for threads in args.threads for name in PIPELINES]
            random.Random(42 + repeat).shuffle(jobs)
            for threads, name in jobs:
                core.num_threads = threads
                node = build_pipeline(core, source, name)
                decimated = name in ("zit_fps24", "vfm_vdecimate")
                warmup = args.warmup * 4 // 5 if decimated else args.warmup
                expected = total_input * 4 // 5 if decimated else total_input
                assert node.num_frames == expected, (name, node.num_frames, expected)
                pull(node, 0, warmup, threads)
                gc.collect()
                gc.disable()
                try:
                    started = time.perf_counter()
                    pull(node, warmup, node.num_frames, threads)
                    elapsed = time.perf_counter() - started
                finally:
                    gc.enable()
                assert evaluations[0] == cache_evaluations, "source cache missed during benchmark"
                count = node.num_frames - warmup
                sample = {"source": path.name, "pipeline": name, "threads": threads,
                          "repeat": repeat + 1, "output_frames": count,
                          "seconds": elapsed, "output_fps": count / elapsed,
                          "input_fps": args.frames / elapsed,
                          "load_average": os.getloadavg() if hasattr(os, "getloadavg") else None}
                report["samples"].append(sample)
                print(f"  run {repeat + 1}/{args.runs} threads={threads} "
                      f"{name:17s} {sample['output_fps']:8.1f} fps ({elapsed:.3f}s)", flush=True)
                del node
                save()
        del source, decoded, full
        gc.collect()

    for source_name in dict.fromkeys(sample["source"] for sample in report["samples"]):
        for threads in args.threads:
            for name in PIPELINES:
                values = [s["output_fps"] for s in report["samples"]
                          if (s["source"], s["threads"], s["pipeline"]) == (source_name, threads, name)]
                row = {"source": source_name, "threads": threads, "pipeline": name,
                       "median_output_fps": statistics.median(values),
                       "min_output_fps": min(values), "max_output_fps": max(values)}
                report["summary"].append(row)
                print(f"{source_name:18s} {threads:2d} threads {name:17s}: "
                      f"{row['median_output_fps']:8.1f} fps "
                      f"[{min(values):.1f}, {max(values):.1f}]")
    save()
    print(f"\nSaved {args.json}")


if __name__ == "__main__":
    main()
