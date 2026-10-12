"""Command line entry point.

    python -m autotrader.cli synth   --bars 40000 --out data/synthetic_m5.csv
    python -m autotrader.cli fetch   --symbol XAUUSD --bars 100000 --out data/xauusd_m5.csv
    python -m autotrader.cli run     --csv data/xauusd_m5.csv --out-dir models
    python -m autotrader.cli parity  --mt5-csv data/mt5_features.csv

`run` does the whole chain: features -> labels -> walk forward -> distill
-> ONNX -> honest backtest -> report.
"""

from __future__ import annotations

import argparse
import json
import os

import numpy as np
import pandas as pd

from . import backtest as bt
from . import data as datamod
from .config import (
    DEFAULT_INDICATORS,
    DEFAULT_TRADE,
    FEATURE_NAMES,
    TFS,
)
from .features import atr, build_feature_frame, clean_features
from .labels import triple_barrier
from .train import distil, evaluate, feature_importance, save_report, walk_forward_probs


def _frames(m5: pd.DataFrame) -> dict:
    out = {5: m5}
    for tf in TFS[1:]:
        out[tf] = datamod.resample(m5, tf)
    return out


def cmd_synth(args):
    df = datamod.make_synthetic(bars=args.bars, seed=args.seed)
    datamod.save_csv(df, args.out)
    print(f"synthetic M5 bars written: {args.out}  ({len(df):,} rows)")


def cmd_fetch(args):
    df = datamod.from_mt5(args.symbol, "M5", args.bars)
    datamod.save_csv(df, args.out)
    print(f"fetched {len(df):,} bars -> {args.out}")


def cmd_parity(args):
    """Compare Python features against a CSV exported by MT5.

    The MQL5 side writes `<time>,f0..f23` via Scripts/Autotrader/ExportFeatures.
    """
    mt5 = pd.read_csv(args.mt5_csv)
    mt5.columns = [c.strip() for c in mt5.columns]
    timecol = mt5.columns[0]
    mt5[timecol] = pd.to_datetime(mt5[timecol], unit="s", errors="coerce")
    mt5 = mt5.dropna(subset=[timecol]).set_index(timecol)
    mt5.index = mt5.index + pd.Timedelta(minutes=5)   # bar open -> close time

    m5 = datamod.load_csv(args.csv)
    feats = clean_features(build_feature_frame(_frames(m5)))
    common = feats.index.intersection(mt5.index)
    if len(common) < 10:
        raise SystemExit("not enough overlapping rows - export the same date range from MT5")
    a = feats.loc[common, FEATURE_NAMES].to_numpy(float)
    b = mt5.loc[common, [f"f{i}" for i in range(len(FEATURE_NAMES))]].to_numpy(float)
    diff = np.abs(a - b)
    print(f"rows compared : {len(common):,}")
    print(f"max abs diff  : {diff.max():.6f}")
    print(f"mean abs diff : {diff.mean():.6f}")
    worst = np.unravel_index(np.argmax(diff), diff.shape)
    print(f"worst feature : {FEATURE_NAMES[worst[1]]} at {common[worst[0]]}")
    ok = diff.max() < args.tolerance
    print("PARITY:", "PASS" if ok else "FAIL", f"(tolerance {args.tolerance})")
    return 0 if ok else 1


def cmd_run(args):
    os.makedirs(args.out_dir, exist_ok=True)
    report: dict = {"inputs": vars(args)}

    # ---- data ---------------------------------------------------------
    m5 = datamod.make_synthetic(bars=args.bars, seed=args.seed) if args.synthetic \
        else datamod.load_csv(args.csv)
    frames = _frames(m5)
    atr_m5 = atr(m5, DEFAULT_INDICATORS["atr_period"])
    print(f"M5 bars: {len(m5):,}  from {m5.index[0]} to {m5.index[-1]}")

    # ---- features -----------------------------------------------------
    feats_all = clean_features(build_feature_frame(frames))
    report["feature_contract_rows"] = len(feats_all)

    # ---- cost model ---------------------------------------------------
    if args.spread_points > 0:
        point = args.point
        risk_px = DEFAULT_TRADE["sl_atr_mult"] * float(np.nanmedian(atr_m5.to_numpy(float)))
        cost_r = (args.spread_points * point + args.commission_r) / max(risk_px, 1e-9)
    else:
        cost_r = args.cost_r
    report["cost_r_per_trade"] = round(float(cost_r), 4)
    print(f"cost assumed: {cost_r:.3f} R per trade")

    # ---- labels -------------------------------------------------------
    lab = triple_barrier(m5, atr_m5, DEFAULT_TRADE, cost_r=cost_r)
    labels = lab.labels.copy()
    labels.index = labels.index + pd.to_timedelta(int(m5["bar_minutes"].iloc[0]), unit="m")

    common = feats_all.index.intersection(labels.index)
    X = feats_all.loc[common]
    y = labels.loc[common, "label"].astype(int)
    labels = labels.loc[common]
    report["label_stats"] = lab.stats
    report["rows_usable"] = len(X)
    print(f"usable rows: {len(X):,}   class balance: "
          f"up {lab.stats['base_rate_up']:.3f} hold {lab.stats['base_rate_hold']:.3f} "
          f"down {lab.stats['base_rate_down']:.3f}")

    if len(X) < 500:
        raise SystemExit("not enough rows after warm up - export more history")

    # ---- development / holdout split ----------------------------------
    # The tail is never touched by the teacher OR the student, so the
    # backtest on it is a genuine out-of-sample result.
    dev_end = int(len(X) * (1.0 - args.test_frac))
    X_dev, y_dev = X.iloc[:dev_end], y.iloc[:dev_end]
    X_hold, y_hold = X.iloc[dev_end:], y.iloc[dev_end:]
    report["split"] = {
        "development_rows": len(X_dev), "holdout_rows": len(X_hold),
        "development_until": str(X.index[dev_end - 1]),
        "holdout_from": str(X.index[dev_end]),
    }
    print(f"development {len(X_dev):,} rows | untouched holdout {len(X_hold):,} rows "
          f"from {X.index[dev_end]}")

    # ---- teacher, walk forward (development only) ----------------------
    print("walk forward training (this is the only honest test):")
    oof, mask, folds = walk_forward_probs(X_dev, y_dev, n_splits=args.folds, gap=args.gap)
    report["folds"] = folds
    report["oof_metrics"] = evaluate(y_dev.to_numpy(float)[mask], oof[mask])
    print(f"out-of-fold: acc {report['oof_metrics']['accuracy']:.3f}  "
          f"dir-acc {report['oof_metrics']['directional_accuracy']:.3f}  "
          f"coverage {report['oof_metrics']['coverage']:.3f}")

    # ---- student ------------------------------------------------------
    net = distil(X_dev, oof, mask, hidden=(64, 32), epochs=args.epochs,
                 seed=args.seed, verbose=args.verbose)
    report["student_metrics_on_development"] = evaluate(
        y_dev.to_numpy(float)[mask], net.predict_proba(X_dev.to_numpy(float)[mask])
    )

    # ---- true out-of-sample view --------------------------------------
    probs_hold = net.predict_proba(X_hold.to_numpy(float))
    report["holdout_metrics"] = evaluate(y_hold.to_numpy(float), probs_hold)
    print(f"HOLDOUT (never seen): acc {report['holdout_metrics']['accuracy']:.3f}  "
          f"dir-acc {report['holdout_metrics']['directional_accuracy']:.3f}  "
          f"coverage {report['holdout_metrics']['coverage']:.3f}")

    # ---- ONNX ---------------------------------------------------------
    from .model import export_onnx, verify_onnx

    onnx_path = os.path.join(args.out_dir, args.model_name)
    export_onnx(net, onnx_path, opset=args.opset)
    check = verify_onnx(onnx_path, net, X.to_numpy(float)[:20])
    report["onnx"] = check
    print(f"ONNX written: {onnx_path} ({os.path.getsize(onnx_path)/1024:.1f} KB)  "
          f"runtime diff {check['max_abs_diff']:.2e}  ok={check['ok']}")

    # ---- backtest on the untouched tail --------------------------------
    bt_res = bt.run(
        probs_hold,
        labels.loc[X_hold.index],
        X_hold.index,
        min_prob=args.min_prob,
        min_edge=args.min_edge,
        risk_per_trade=args.risk,
        max_trades_per_day=args.max_trades_day,
    )
    report["backtest"] = bt_res.metrics
    report["backtest_window"] = {
        "from": str(X_hold.index[0]), "to": str(X_hold.index[-1]),
        "note": "untouched holdout tail - teacher and student never saw these rows",
    }
    print("backtest:", json.dumps(bt_res.metrics, indent=2, default=str))

    if args.importance:
        report["feature_importance"] = feature_importance(X, y)
        print("top features:", ", ".join(f"{d['feature']} ({d['importance']:.0f})"
                                         for d in report["feature_importance"][:6]))

    if len(bt_res.trades):
        bt_res.trades.to_csv(os.path.join(args.out_dir, "trades.csv"), index=False)
    save_report(os.path.join(args.out_dir, "report.json"), report)
    print(f"report: {os.path.join(args.out_dir, 'report.json')}")
    print("\nNEXT STEP: copy the .onnx file into\n"
          "  <terminal data folder>\\MQL5\\Files\\Common\\\n"
          "and keep the EA input 'Model file in Common\\Files' pointing at it.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="autotrader", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("synth", help="write synthetic M5 data (smoke test only)")
    s.add_argument("--bars", type=int, default=40000)
    s.add_argument("--seed", type=int, default=7)
    s.add_argument("--out", default="data/synthetic_m5.csv")
    s.set_defaults(func=cmd_synth)

    f = sub.add_parser("fetch", help="pull M5 candles from the MT5 terminal")
    f.add_argument("--symbol", default="XAUUSD")
    f.add_argument("--bars", type=int, default=200000)
    f.add_argument("--out", default="data/m5.csv")
    f.set_defaults(func=cmd_fetch)

    r = sub.add_parser("run", help="full pipeline: train, export ONNX, backtest")
    r.add_argument("--csv", default=None)
    r.add_argument("--synthetic", action="store_true", help="use synthetic data (smoke test)")
    r.add_argument("--bars", type=int, default=40000)
    r.add_argument("--seed", type=int, default=7)
    r.add_argument("--out-dir", default="models")
    r.add_argument("--model-name", default="autotrader_m5.onnx")
    r.add_argument("--folds", type=int, default=5)
    r.add_argument("--gap", type=int, default=50)
    r.add_argument("--epochs", type=int, default=600)
    r.add_argument("--opset", type=int, default=15)
    r.add_argument("--min-prob", type=float, default=0.45)
    r.add_argument("--min-edge", type=float, default=0.05)
    r.add_argument("--risk", type=float, default=0.005, help="fraction of equity per trade in the backtest")
    r.add_argument("--test-frac", type=float, default=0.25)
    r.add_argument("--cost-r", type=float, default=0.05)
    r.add_argument("--spread-points", type=float, default=0.0,
                   help="derive cost in R from the spread instead of --cost-r")
    r.add_argument("--commission-r", type=float, default=0.0)
    r.add_argument("--point", type=float, default=0.01)
    r.add_argument("--max-trades-day", type=int, default=0)
    r.add_argument("--importance", action="store_true")
    r.add_argument("--verbose", action="store_true")
    r.set_defaults(func=cmd_run)

    q = sub.add_parser("parity", help="compare python features with an MT5 export")
    q.add_argument("--mt5-csv", required=True)
    q.add_argument("--csv", required=True, help="the same M5 candles as a CSV")
    q.add_argument("--tolerance", type=float, default=1e-3)
    q.set_defaults(func=cmd_parity)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if getattr(args, "csv", None) is None and getattr(args, "func", None) is cmd_run \
            and not args.synthetic:
        raise SystemExit("give --csv <file> or --synthetic")
    return args.func(args) or 0


if __name__ == "__main__":
    raise SystemExit(main())
