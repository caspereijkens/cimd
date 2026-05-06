"""Benchmark cimd (ReleaseFast) vs pypowsybl on a CGMES → JIIDM conversion.

Honest comparison: both pipelines end with a pypowsybl Network in memory.

  Pipeline A (cimd):     cimd convert CGMES → JIIDM file → pypowsybl loads JIIDM
  Pipeline B (pypowsybl): pypowsybl loads CGMES directly

Each pipeline is run N times; per-step timings are reported with
min / median / mean / stdev, plus the totals side-by-side.

Usage:
    uv run python main.py --eq ~/data/eq.zip --eqbd ~/data/eqbd.zip
"""

from __future__ import annotations

import argparse
import io
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import pypowsybl.network as pn


REPO_ROOT = Path(__file__).resolve().parent.parent
CIMD_BIN = REPO_ROOT / "zig-out" / "bin" / "cimd-fast"
CIMD_BIN_FALLBACK = REPO_ROOT / "zig-out" / "bin" / "cimd"


def build_cimd_releasefast() -> Path:
    """Build cimd in ReleaseFast and return the binary path."""
    print("Building cimd (ReleaseFast)...")
    out_prefix = REPO_ROOT / "zig-out-fast"
    subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast", "-p", str(out_prefix)],
        cwd=REPO_ROOT,
        check=True,
    )
    binary = out_prefix / "bin" / "cimd"
    assert binary.exists(), f"build succeeded but binary missing: {binary}"
    return binary


@dataclass
class Samples:
    label: str
    values: list[float] = field(default_factory=list)

    def add(self, seconds: float) -> None:
        self.values.append(seconds)

    def summary(self) -> str:
        v = self.values
        if not v:
            return f"{self.label:<32s}  (no samples)"
        med = statistics.median(v)
        mean = statistics.fmean(v)
        sd = statistics.stdev(v) if len(v) > 1 else 0.0
        return (
            f"{self.label:<32s}  "
            f"min {min(v)*1000:8.1f}ms  "
            f"med {med*1000:8.1f}ms  "
            f"mean {mean*1000:8.1f}ms  "
            f"sd {sd*1000:7.1f}ms"
        )


def time_block(samples: Samples):
    class _T:
        def __enter__(self_inner):
            self_inner.t0 = time.perf_counter()
            return self_inner

        def __exit__(self_inner, *_):
            samples.add(time.perf_counter() - self_inner.t0)

    return _T()


def cimd_convert(binary: Path, eq, eqbd, ssh, tp, output: Path) -> None:
    cmd = [str(binary), "convert", str(eq), "--output", str(output)]
    if eqbd:
        cmd += ["--boundary", str(eqbd)]
    if tp:
        cmd += ["--topology", str(tp)]
    if ssh:
        cmd += ["--ssh", str(ssh)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise RuntimeError("cimd convert failed")


def pypow_load_cgmes(eq, eqbd, ssh, tp):
    buffers = [io.BytesIO(Path(eq).read_bytes())]
    for extra in (eqbd, tp, ssh):
        if extra:
            buffers.append(io.BytesIO(Path(extra).read_bytes()))
    if len(buffers) > 1:
        return pn.load_from_binary_buffers(buffers)
    return pn.load(str(eq))


def pypow_load_jiidm(path: Path):
    return pn.load(str(path))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eq", type=Path, required=True)
    parser.add_argument("--eqbd", type=Path, default=None)
    parser.add_argument("--ssh", type=Path, default=None)
    parser.add_argument("--tp", type=Path, default=None)
    parser.add_argument("-n", "--runs", type=int, default=10)
    parser.add_argument(
        "--no-build", action="store_true",
        help="skip rebuild, use existing zig-out-fast/bin/cimd or zig-out/bin/cimd",
    )
    parser.add_argument(
        "--out-dir", type=Path,
        default=Path(__file__).parent / "output",
    )
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    jiidm_path = args.out_dir / "cimd.jiidm"

    if args.no_build:
        binary = REPO_ROOT / "zig-out-fast" / "bin" / "cimd"
        if not binary.exists():
            binary = CIMD_BIN_FALLBACK
        if not binary.exists():
            print(f"ERROR: no cimd binary at {binary}", file=sys.stderr)
            return 1
    else:
        binary = build_cimd_releasefast()

    print(f"\ncimd binary: {binary}")
    print(f"EQ:    {args.eq}")
    if args.eqbd:
        print(f"EQBD:  {args.eqbd}")
    if args.ssh:
        print(f"SSH:   {args.ssh}")
    if args.tp:
        print(f"TP:    {args.tp}")
    print(f"Runs:  {args.runs}\n")

    cimd_convert_t = Samples("cimd: convert CGMES→JIIDM")
    cimd_load_t = Samples("cimd: pypow load JIIDM")
    cimd_total_t = Samples("cimd: TOTAL")
    pypow_total_t = Samples("pypow: load CGMES")

    # First cimd run is discarded entirely — the freshly-built binary pays
    # one-time costs (dyld, code-signing cache, page-in) that aren't part
    # of steady-state conversion time.
    print("Priming cimd binary (discarded)...")
    cimd_convert(binary, args.eq, args.eqbd, args.ssh, args.tp, jiidm_path)

    # warmup (excluded) — primes pypowsybl JVM and disk caches
    print("Warmup...")
    cimd_convert(binary, args.eq, args.eqbd, args.ssh, args.tp, jiidm_path)
    pypow_load_jiidm(jiidm_path)
    pypow_load_cgmes(args.eq, args.eqbd, args.ssh, args.tp)

    print("Benchmarking...")
    for run in range(1, args.runs + 1):
        # Pipeline A: cimd convert + pypowsybl load JIIDM
        with time_block(cimd_total_t):
            with time_block(cimd_convert_t):
                cimd_convert(binary, args.eq, args.eqbd, args.ssh, args.tp, jiidm_path)
            with time_block(cimd_load_t):
                pypow_load_jiidm(jiidm_path)

        # Pipeline B: pypowsybl load CGMES
        with time_block(pypow_total_t):
            pypow_load_cgmes(args.eq, args.eqbd, args.ssh, args.tp)

        a_ms = cimd_total_t.values[-1] * 1000
        b_ms = pypow_total_t.values[-1] * 1000
        ratio = b_ms / a_ms if a_ms else float("inf")
        print(f"  run {run}: cimd-pipe {a_ms:8.1f}ms   pypow {b_ms:8.1f}ms   ({ratio:.2f}x)")

    print("\n" + "=" * 84)
    print("BREAKDOWN")
    print("=" * 84)
    for s in (cimd_convert_t, cimd_load_t, cimd_total_t, pypow_total_t):
        print(s.summary())

    a_med = statistics.median(cimd_total_t.values)
    b_med = statistics.median(pypow_total_t.values)
    print("\n" + "=" * 84)
    print(f"Median totals: cimd-pipe {a_med*1000:.1f}ms   pypow {b_med*1000:.1f}ms")
    if a_med:
        print(f"Speedup: {b_med / a_med:.2f}x  (cimd-pipe vs pypowsybl direct)")
    print("=" * 84)

    svg_path = args.out_dir / "benchmark.svg"
    write_svg(svg_path, cimd_seconds=a_med, pypow_seconds=b_med)
    print(f"\nSVG: {svg_path}")
    return 0


def _nice_step(max_value: float) -> float:
    """Pick a 'nice' tick step (1, 2, 2.5, 5 × 10^n) giving 3–5 ticks."""
    import math
    if max_value <= 0:
        return 1.0
    rough = max_value / 3.0
    magnitude = 10 ** math.floor(math.log10(rough))
    for candidate in (1, 2, 2.5, 5, 10):
        step = candidate * magnitude
        if max_value / step <= 4:
            return step
    return 10 * magnitude


def write_svg(path: Path, cimd_seconds: float, pypow_seconds: float) -> None:
    """Render a horizontal-bar comparison chart in the docs/benchmark.svg style."""
    width = 600
    height = 110
    label_end_x = 88
    chart_x0 = 96
    chart_x1 = 544
    chart_w = chart_x1 - chart_x0

    max_seconds = max(cimd_seconds, pypow_seconds)
    step = _nice_step(max_seconds)
    n_ticks = int(max_seconds / step) + 1
    if n_ticks * step < max_seconds * 1.05:
        n_ticks += 1
    axis_max = n_ticks * step

    def x_for(seconds: float) -> float:
        return chart_x0 + chart_w * (seconds / axis_max)

    def fmt_tick(value: float) -> str:
        if value >= 1 or value == 0:
            return f"{value:g}s"
        return f"{int(round(value * 1000))}ms"

    def fmt_value(seconds: float) -> str:
        if seconds >= 1:
            return f"{seconds:.3f}s"
        return f"{int(round(seconds * 1000))}ms"

    rows = [
        ("cimd",      cimd_seconds,  "#F26522", 18.0, 33.5),
        ("pypowsybl", pypow_seconds, "#8B5CF6", 54.0, 69.5),
    ]

    parts: list[str] = []
    parts.append(
        f'<svg viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg"'
        ' font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', '
        'Helvetica, Arial, sans-serif">'
    )
    for i in range(n_ticks + 1):
        tx = chart_x0 + chart_w * (i / n_ticks)
        parts.append(
            f'<line x1="{tx:.1f}" y1="12" x2="{tx:.1f}" y2="82" '
            'stroke="#E5E7EB" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{tx:.1f}" y="104" text-anchor="middle" '
            f'font-size="11" fill="#6B7280">{fmt_tick(i * step)}</text>'
        )
    for label, seconds, color, rect_y, text_y in rows:
        bar_w = max(1.0, x_for(seconds) - chart_x0)
        parts.append(
            f'<text x="{label_end_x}" y="{text_y}" text-anchor="end" '
            f'font-size="13" font-weight="500" fill="#111827">{label}</text>'
        )
        parts.append(
            f'<rect x="{chart_x0}" y="{rect_y}" width="{bar_w:.1f}" '
            f'height="22" fill="{color}" rx="3"/>'
        )
        parts.append(
            f'<text x="{chart_x0 + bar_w + 6:.1f}" y="{text_y}" '
            f'font-size="13" fill="#111827">{fmt_value(seconds)}</text>'
        )
    parts.append("</svg>")
    path.write_text("\n".join(parts) + "\n")


if __name__ == "__main__":
    sys.exit(main())
