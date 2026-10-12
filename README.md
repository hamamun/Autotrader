# Autotrader

A fully automated MT5 trading robot that answers one question on every bar:

> **For M5, M15 and M30 — is this a BUY, a SELL, or a HOLD?**

* **M5** → scalping trade direction
* **M15** → short term trade setup
* **M30** → intraday bias

It lives where you asked it to live: an **MQL5 Expert Advisor** attached to a
MetaTrader 5 chart. No Python process to keep alive, no DLL, no socket.
Python is used once, offline, to *train* the AI brain; the EA then runs it
inside MT5 through the built-in ONNX engine.

---

## The idea in plain language

Three layers, each one only allowed to do its own job:

1. **One timeframe is not a decision.** A 5-minute chart screams BUY while the
   30-minute chart is still falling — that is how retail traders get chopped.
   So we read all three and let the bigger one veto the smaller one.
2. **Rules first, AI second.** The EA carries a complete rule engine
   (trend + momentum + structure votes, 10 gates per timeframe). It works
   today, with zero setup. The AI model is an *extra* gate on top: it can
   only make the robot **more selective**, never more reckless.
3. **Execution is boring on purpose.** Fixed fractional risk, ATR stop,
   take profit at 1.5R and 3R, break-even move, trailing stop, daily loss
   cap, spread gate, session gate. Boring execution is what keeps a good
   signal alive long enough to pay.

And one more, which matters more than the other three: **every signal is
written down and scored against what price actually did.** The panel shows
the measured hit rate per timeframe. We do not claim accuracy — we log it.

---

## Honest note on the 98% goal

Read `docs/ACCURACY_AND_RISK.md` before betting money on any robot,
including this one. The summary:

* **98% TP-hit rate** is not a skill, it is a knob. Geometry says a target
  at 0.02R is reached before a 1R stop 98% of the time — with exactly zero
  expectancy before costs and negative after spread. High win rate and high
  profit are different goals.
* **98% directional accuracy** does not exist on 5-minute data. A real,
  tradable edge lives at **53–60%**. At 1.5R you only need **42%** to make
  money, and that is the number we engineer against.
* The 98% we *do* target, and can measure: **plan compliance** — a stop and
  target on every trade, risk never above the configured %, no trade when
  the gates say no, nothing repainting, and 100% of signals journalled.

---

## Architecture

```
   PYTHON (offline, any machine)                  MQL5 (inside MT5, 24/5)
   ┌───────────────────────────────┐              ┌──────────────────────────────┐
   │ 1. M5/M15/M30 candles (CSV/MT5)│              │ 4. DASHBOARD panel on chart  │
   │ 2. 24 features (frozen order)  │              │    BUY/SELL/HOLD · conf      │
   │ 3. triple-barrier labels       │              │    entry · SL · TP · lot     │
   │ 4. LightGBM teacher, walk-fwd  │              │    checklist · measured rate │
   │ 5. distilled 24→64→32→3 net    │  .onnx file  │ 3. RISK: sizing, caps, stops │
   │ 6. honest backtest + report    │ ───────────► │ 2. AI gate: P(up/hold/down)  │
   └───────────────────────────────┘              │ 1. RULE ENGINE + checklist   │
                                                  └──────────────────────────────┘
```

| file | role |
|---|---|
| `mql5/Experts/Autotrader/Autotrader.mq5` | the EA you attach to a chart |
| `mql5/Include/Autotrader/SignalEngine.mqh` | multi-timeframe direction engine |
| `mql5/Include/Autotrader/RiskManager.mqh` | sizing, guards, order execution |
| `mql5/Include/Autotrader/Panel.mqh` | the dashboard |
| `mql5/Include/Autotrader/Journal.mqh` | writes every signal, scores its real outcome |
| `mql5/Include/Autotrader/OnnxBrain.mqh` | runs the trained model inside MT5 |
| `mql5/Scripts/Autotrader/ExportFeatures.mq5` | parity proof: dumps the 24 inputs |
| `python/autotrader/*` | training pipeline + backtest |
| `docs/*` | architecture, feature contract, accuracy math, panel spec, install |

---

## Quick start

### 1. Just see it work (no Python)

Copy `mql5/Experts` and `mql5/Include` into your MT5 data folder
(`File → Open Data Folder`), compile `Autotrader.mq5` in MetaEditor (F7),
drag it onto an **M5** chart, and leave `Mode = SIGNAL ONLY`.

### 2. Train the AI brain (Python, once)

```bash
pip install -r python/requirements.txt
cd python

# real data (Windows + MT5 terminal running):
python -m autotrader.cli fetch --symbol XAUUSD --bars 300000 --out ../data/xauusd_m5.csv
# or use an M5 CSV exported from MT5's History Center
python -m autotrader.cli run --csv ../data/xauusd_m5.csv --out-dir ../models
```

That prints an untouched-holdout report and writes `models/autotrader_m5.onnx`
(~15 KB). Copy it to `MQL5\Files\Common\`, set the EA input
`Model file in Common\Files`, and the panel footer switches to
"AI model loaded".

### 3. Verify the two sides agree

```bash
# attach Scripts/Autotrader/ExportFeatures to an M5 chart first
python -m autotrader.cli parity --mt5-csv autotrader_features_XAUUSD.csv --csv ../data/xauusd_m5.csv
```

`PARITY: PASS` means Python and MQL5 compute identical inputs. Run this
before trusting any backtest — it is the single most common silent killer
of home-built robots.

### 4. Forward test before money

SIGNAL ONLY for 2–4 weeks, 200+ signals, then compare the panel's measured
hit rate with `models/report.json`. Then go live with 0.1–0.25% risk.
Details in `docs/INSTALL_MT5.md` and `docs/ACCURACY_AND_RISK.md`.

---

## Tests

```bash
cd python && pytest -q          # 8 contract tests
```

The tests lock the things that quietly break trading systems: feature count
and order, no NaN/inf, no lookahead in the higher-timeframe merge, labels
containing only 0/1/2, and the ONNX file really being `[1,24] → [1,3]`
with outputs that sum to 1.

---

## Status

Working and tested: rule engine, checklist, risk layer, dashboard, journal,
ONNX pipeline, backtest harness. See `docs/ROADMAP.md`.

Still needed from you to finish the interface: **the screenshot of your old
interface did not upload** — nothing was attached to the message. The panel
is built as a skin over a fixed data model, so matching it is a layout change
in one file (`docs/PANEL_SPEC.md` explains exactly what to send).

This is a trading tool, not financial advice. Test on demo first.
