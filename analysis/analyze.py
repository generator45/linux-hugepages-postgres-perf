#!/usr/bin/env python3
"""Parse raw sysbench + perf logs and produce tidy CSVs and comparison plots.

Everything is recomputed from the raw logs under data/, so the numbers in
results/ never depend on the (fragile) one-line summaries the shell scripts
print at the end of a run.

Usage:
    python3 analysis/analyze.py            # from the repo root
    python3 analysis/analyze.py --data data --out results
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

PAGE_MODES = ("4k", "2mb")
MODE_LABEL = {"4k": "4 KB pages", "2mb": "2 MB huge pages"}

# --------------------------------------------------------------------------
# Generic sysbench output parsing
# --------------------------------------------------------------------------
_NUM = r"([0-9][0-9,]*\.?[0-9]*)"


def _num(s: str) -> float:
    return float(s.replace(",", ""))


def _search(pattern: str, text: str) -> float | None:
    m = re.search(pattern, text, flags=re.MULTILINE)
    return _num(m.group(1)) if m else None


def parse_sysbench(text: str) -> dict:
    """Extract the final-report statistics from a sysbench run log."""
    out = {
        "tps": _search(r"^\s*transactions:\s+\d+\s+\(" + _NUM + r" per sec\.\)", text),
        "qps": _search(r"^\s*queries:\s+\d+\s+\(" + _NUM + r" per sec\.\)", text),
        "reads": _search(r"^\s*read:\s+" + _NUM, text),
        "writes": _search(r"^\s*write:\s+" + _NUM, text),
        "other": _search(r"^\s*other:\s+" + _NUM, text),
        "ignored_errors": _search(r"^\s*ignored errors:\s+" + _NUM, text),
        "reconnects": _search(r"^\s*reconnects:\s+" + _NUM, text),
        "lat_avg_ms": _search(r"^\s*avg:\s+" + _NUM, text),
        "lat_p95_ms": _search(r"^\s*95th percentile:\s+" + _NUM, text),
        "lat_max_ms": _search(r"^\s*max:\s+" + _NUM, text),
        "elapsed_s": _search(r"^\s*(?:total time|time elapsed):\s+" + _NUM + r"s", text),
    }
    return out


def parse_perf(text: str) -> dict:
    """Extract `perf stat` counters (raw counts, already scaled by perf)."""
    events = {
        "dtlb_loads": r"dTLB-loads?",
        "dtlb_load_misses": r"dTLB-load-misses",
        "itlb_loads": r"iTLB-loads?",
        "itlb_load_misses": r"iTLB-load-misses",
        "cycles": r"cycles",
        "instructions": r"instructions",
        "cache_misses": r"cache-misses",
    }
    out = {}
    for key, ev in events.items():
        out[key] = _search(r"^\s*" + _NUM + r"\s+" + ev + r"\b(?!-)", text)
    return out


# --------------------------------------------------------------------------
# Experiment 1: oltp_point_select + perf stat (TLB counters)
# --------------------------------------------------------------------------
def load_point_select(data_dir: Path) -> pd.DataFrame:
    rows = []
    for mode in PAGE_MODES:
        for f in sorted((data_dir / "point_select_perf" / mode).glob("r_*.txt")):
            text = f.read_text()
            hdr = {
                k: (re.search(rf"^{k}\s*:\s*(.+)$", text, re.MULTILINE) or [None, None])[1]
                for k in ("Dataset", "Tables", "Rows/Table", "shared_buffers", "Threads")
            }
            row = {
                "page_mode": mode,
                "dataset": hdr["Dataset"].strip(),
                "tables": int(hdr["Tables"]),
                "rows_per_table": int(hdr["Rows/Table"]),
                "shared_buffers": hdr["shared_buffers"].strip(),
                "threads": int(hdr["Threads"]),
                "file": str(f.relative_to(data_dir.parent)),
            }
            row.update(parse_sysbench(text))
            row.update(parse_perf(text))
            rows.append(row)

    df = pd.DataFrame(rows)
    df["dtlb_miss_pct"] = 100 * df["dtlb_load_misses"] / df["dtlb_loads"]
    df["dtlb_mpki"] = 1000 * df["dtlb_load_misses"] / df["instructions"]
    df["itlb_mpki"] = 1000 * df["itlb_load_misses"] / df["instructions"]
    df["cache_mpki"] = 1000 * df["cache_misses"] / df["instructions"]
    df["ipc"] = df["instructions"] / df["cycles"]
    df["_ds_order"] = df["dataset"].map(_size_mb)
    df["_sb_order"] = df["shared_buffers"].map(_size_mb)
    return df.sort_values(["page_mode", "_ds_order", "_sb_order", "threads"]).reset_index(drop=True)


def _size_mb(s: str) -> float:
    m = re.fullmatch(r"([0-9.]+)\s*(MB|GB)", s.strip(), re.IGNORECASE)
    if not m:
        return float("nan")
    return float(m.group(1)) * (1024 if m.group(2).upper() == "GB" else 1)


def pair_configs(df: pd.DataFrame, keys: list[str], metrics: list[str]) -> pd.DataFrame:
    """Join 4k and 2mb rows on identical configuration keys and compute deltas."""
    a = df[df.page_mode == "4k"].set_index(keys)[metrics]
    b = df[df.page_mode == "2mb"].set_index(keys)[metrics]
    paired = a.join(b, lsuffix="_4k", rsuffix="_2mb", how="inner")
    for m in metrics:
        paired[f"{m}_delta_pct"] = 100 * (paired[f"{m}_2mb"] - paired[f"{m}_4k"]) / paired[f"{m}_4k"]
    return paired.reset_index()


# --------------------------------------------------------------------------
# Experiment 2: oltp_read_write throughput/latency sweep
# --------------------------------------------------------------------------
def load_oltp_rw(data_dir: Path) -> pd.DataFrame:
    rows = []
    for mode in PAGE_MODES:
        for f in sorted((data_dir / "oltp_read_write" / mode).glob("run_ts*_th*.log")):
            m = re.match(r"run_ts(\d+)_th(\d+)\.log", f.name)
            row = {
                "page_mode": mode,
                "rows_per_table": int(m.group(1)),
                "tables": 10,
                "threads": int(m.group(2)),
                "file": str(f.relative_to(data_dir.parent)),
            }
            row.update(parse_sysbench(f.read_text()))
            rows.append(row)
    df = pd.DataFrame(rows)
    for kind in ("reads", "writes", "other"):
        df[f"{kind}_per_s"] = df[kind] / df["elapsed_s"]
    return df.sort_values(["page_mode", "rows_per_table", "threads"]).reset_index(drop=True)


# --------------------------------------------------------------------------
# Plots
# --------------------------------------------------------------------------
def _grouped_bars(ax, labels, series: dict[str, list[float]], ylabel: str, title: str):
    n = len(series)
    width = 0.8 / n
    xs = range(len(labels))
    for i, (name, vals) in enumerate(series.items()):
        ax.bar([x + (i - (n - 1) / 2) * width for x in xs], vals, width, label=name)
    ax.set_xticks(list(xs))
    ax.set_xticklabels(labels, rotation=30, ha="right", fontsize=8)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend()


def plot_point_select(paired: pd.DataFrame, out: Path):
    labels = [
        f"{r.dataset} / sb={r.shared_buffers} / {r.threads}t" for r in paired.itertuples()
    ]
    fig, axes = plt.subplots(1, 3, figsize=(17, 5))
    _grouped_bars(
        axes[0], labels,
        {MODE_LABEL["4k"]: paired.dtlb_mpki_4k, MODE_LABEL["2mb"]: paired.dtlb_mpki_2mb},
        "dTLB load misses / 1k instructions", "dTLB MPKI (lower is better)",
    )
    _grouped_bars(
        axes[1], labels,
        {MODE_LABEL["4k"]: paired.dtlb_miss_pct_4k, MODE_LABEL["2mb"]: paired.dtlb_miss_pct_2mb},
        "dTLB-load-misses / dTLB-loads (%)", "dTLB miss rate (lower is better)",
    )
    axes[2].bar(range(len(labels)), paired.tps_delta_pct,
                color=["tab:green" if v >= 0 else "tab:red" for v in paired.tps_delta_pct])
    axes[2].axhline(0, color="black", lw=0.8)
    axes[2].set_xticks(range(len(labels)))
    axes[2].set_xticklabels(labels, rotation=30, ha="right", fontsize=8)
    axes[2].set_ylabel("TPS change with 2 MB pages (%)")
    axes[2].set_title("Throughput delta (2 MB vs 4 KB)")
    axes[2].grid(True, axis="y", alpha=0.3)
    fig.suptitle("oltp_point_select: identical configurations, 4 KB vs 2 MB pages")
    fig.tight_layout()
    fig.savefig(out / "point_select_tlb_vs_tps.png", dpi=150)
    plt.close(fig)


def plot_point_select_threads(df: pd.DataFrame, out: Path):
    g = df.groupby(["page_mode", "threads"], as_index=False)[["dtlb_miss_pct", "dtlb_mpki", "tps", "ipc"]].mean()
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    for mode in PAGE_MODES:
        s = g[g.page_mode == mode]
        axes[0].plot(s.threads, s.dtlb_mpki, marker="o", label=MODE_LABEL[mode])
        axes[1].plot(s.threads, s.tps, marker="o", label=MODE_LABEL[mode])
        axes[2].plot(s.threads, s.ipc, marker="o", label=MODE_LABEL[mode])
    for ax, yl in zip(axes, ("dTLB MPKI", "TPS", "IPC")):
        ax.set_xscale("log", base=2)
        ax.set_xticks([4, 16, 64])
        ax.set_xticklabels(["4", "16", "64"])
        ax.set_xlabel("sysbench threads")
        ax.set_ylabel(yl)
        ax.grid(True, alpha=0.3)
        ax.legend()
    fig.suptitle("oltp_point_select: mean over all runs, by thread count")
    fig.tight_layout()
    fig.savefig(out / "point_select_by_threads.png", dpi=150)
    plt.close(fig)


def plot_oltp_rw(df: pd.DataFrame, out: Path):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.5))
    for mode in PAGE_MODES:
        for ts, ls in zip(sorted(df.rows_per_table.unique()), ("-", "--")):
            s = df[(df.page_mode == mode) & (df.rows_per_table == ts)]
            lbl = f"{MODE_LABEL[mode]}, {ts:,} rows/table"
            axes[0].plot(s.threads, s.tps, ls, marker="o", label=lbl)
            axes[1].plot(s.threads, s.lat_p95_ms, ls, marker="o", label=lbl)
    for ax, yl in zip(axes, ("Transactions / s", "p95 latency (ms)")):
        ax.set_xlabel("sysbench threads")
        ax.set_ylabel(yl)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8)
    fig.suptitle("oltp_read_write (10 tables, 120 s per run)")
    fig.tight_layout()
    fig.savefig(out / "oltp_read_write.png", dpi=150)
    plt.close(fig)


# --------------------------------------------------------------------------
def main():
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=root / "data")
    ap.add_argument("--out", type=Path, default=root / "results")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    # ---- Experiment 1 ----
    ps = load_point_select(args.data)
    missing = ps[ps[["tps", "dtlb_loads", "instructions"]].isna().any(axis=1)]
    if not missing.empty:
        raise SystemExit(f"Unparseable point_select logs:\n{missing.file.to_list()}")
    ps.drop(columns=["_ds_order", "_sb_order"]).to_csv(args.out / "point_select_perf.csv", index=False, float_format="%.4f")

    keys = ["dataset", "shared_buffers", "threads"]
    metrics = ["tps", "lat_avg_ms", "lat_p95_ms", "dtlb_miss_pct", "dtlb_mpki", "itlb_mpki", "ipc", "cache_mpki"]
    paired = pair_configs(ps, keys, metrics)
    paired["_ds"] = paired.dataset.map(_size_mb)
    paired["_sb"] = paired.shared_buffers.map(_size_mb)
    paired = paired.sort_values(["_ds", "_sb", "threads"]).drop(columns=["_ds", "_sb"]).reset_index(drop=True)
    paired.to_csv(args.out / "point_select_paired.csv", index=False, float_format="%.4f")

    unpaired = ps.merge(paired[keys], on=keys, how="left", indicator=True)
    unpaired = unpaired[unpaired._merge == "left_only"]

    plot_point_select(paired, args.out)
    plot_point_select_threads(ps, args.out)

    # ---- Experiment 2 ----
    rw = load_oltp_rw(args.data)
    rw.to_csv(args.out / "oltp_read_write.csv", index=False, float_format="%.4f")
    rw_paired = pair_configs(rw, ["rows_per_table", "threads"], ["tps", "lat_avg_ms", "lat_p95_ms"])
    rw_paired.to_csv(args.out / "oltp_read_write_paired.csv", index=False, float_format="%.4f")
    plot_oltp_rw(rw, args.out)

    # ---- Console report (Markdown, pasteable into README) ----
    pd.set_option("display.width", 200)
    print("## oltp_point_select, matched configurations (2 MB vs 4 KB)\n")
    cols = ["dataset", "shared_buffers", "threads",
            "dtlb_mpki_4k", "dtlb_mpki_2mb", "dtlb_mpki_delta_pct",
            "tps_4k", "tps_2mb", "tps_delta_pct", "ipc_delta_pct"]
    print(paired[cols].to_markdown(index=False, floatfmt=".2f"))
    for stat in ("mean", "median"):
        print(f"\n{stat.capitalize()} change with 2 MB pages: "
              f"dTLB MPKI {paired.dtlb_mpki_delta_pct.agg(stat):+.1f}% | "
              f"TPS {paired.tps_delta_pct.agg(stat):+.2f}% | "
              f"IPC {paired.ipc_delta_pct.agg(stat):+.2f}%")
    print(f"\n{len(unpaired)} point_select runs have no counterpart with identical "
          f"shared_buffers in the other page mode and are excluded from the paired comparison.")
    print("\n## oltp_read_write (2 MB vs 4 KB)\n")
    rw_show = rw_paired.astype({"rows_per_table": str, "threads": str})
    print(rw_show[["rows_per_table", "threads", "tps_4k", "tps_2mb", "tps_delta_pct",
                     "lat_p95_ms_4k", "lat_p95_ms_2mb"]].to_markdown(index=False, floatfmt=".2f"))
    print(f"\nResults written to {args.out}/")


if __name__ == "__main__":
    main()
