# Install and first run

## A. The EA only (5 minutes, no Python needed)

The EA ships with the full rule engine, so this already gives you M5/M15/M30
direction, levels, lot sizes and the dashboard.

1. In MT5: **File → Open Data Folder**.
2. Copy the repo folders into it:
   ```
   mql5/Experts/Autotrader/Autotrader.mq5   ->  MQL5\Experts\Autotrader\
   mql5/Include/Autotrader/*.mqh            ->  MQL5\Include\Autotrader\
   mql5/Scripts/Autotrader/*.mq5            ->  MQL5\Scripts\Autotrader\
   ```
3. Open **MetaEditor** (F4), open `Autotrader.mq5`, press **Compile** (F7).
   0 errors expected.
4. Back in MT5: open an **M5 chart** of your symbol (XAUUSD, EURUSD, ...),
   drag `Autotrader` from the Navigator onto the chart.
5. In the dialog:
   * `Mode` = **SIGNAL ONLY** for now
   * `Max spread` = e.g. 30 points for XAUUSD (0 = off)
   * `Use session` = true (London + New York only)
   * untick `Use AI model` until you have trained one
6. Leave AutoTrading **off** while you watch the panel for a day.

The panel is clickable: `AUTO` / `SIGNAL ONLY` / `CLOSE ALL` / `HIDE`.

Metrics to watch on the map:

* **CHECKLIST 10/10** — a trade only ever fires on a full row
* **Measured signal hit rate** — the journal scoring every past signal.
  It starts at n=0 and fills up as time passes; this is the number that
  decides whether the system is worth trading, not the backtest.

Journal output: `MQL5\Files\Common\autotrader_journal.csv` (open in Excel).

## B. Add the AI model (needs Python once)

On any machine (Windows pulls data straight from the terminal, Linux/macOS
from a CSV):

```bash
# 1. environment
python -m venv .venv && source .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r python/requirements.txt

# 2. data - either export M5 candles from MT5 to CSV, or pull directly:
python -m autotrader.cli fetch --symbol XAUUSD --bars 300000 --out data/xauusd_m5.csv

# 3. train + export + honest backtest (writes models/report.json)
cd python && python -m autotrader.cli run --csv ../data/xauusd_m5.csv --out-dir ../models

# 4. parity check: MT5 and Python must compute identical features
python -m autotrader.cli parity --mt5-csv <common files>\autotrader_features_XAUUSD.csv --csv ../data/xauusd_m5.csv
```

Then copy `models/autotrader_m5.onnx` into
`MQL5\Files\Common\` and set the EA input `Model file in Common\Files`
to `autotrader_m5.onnx`.

Requirements for ONNX inside MT5: **terminal build 3620 or newer**
(Help → About). If you are on an older build, set
`AUTOTRADER_USE_ONNX 0` at the top of `Types.mqh` (or leave the model
unticked in the EA inputs) - everything else keeps working.

## C. Retraining rhythm

Direction models drift. The recommended loop:

* **weekly**: pull a fresh CSV, run `run`, look at `models/report.json`
* **monthly**: replace the `.onnx` file if holdout metrics held up
* **always**: keep the EA in SIGNAL ONLY for the first two weeks after any
  model swap so the journal can compare live vs backtest

## D. Practical settings that matter more than the model

| setting | why |
|---|---|
| `Max spread (points)` | on XAUUSD the spread can triple at news; the gate pays for itself |
| `Use session filter` | Asian chop on gold produces the worst M5 signals |
| `Risk per trade` 0.25–0.5% | at 0.5% and a 3% daily loss cap you survive 6 bad trades in a row, which happens |
| `Max trades/day` | stops revenge-trading logic when the regime is wrong |
| `Max open positions` = 1 | three correlated positions is not diversification |
| symbol choice | compare two brokers in the journal; a 0.6 point spread difference moves expectancy more than any indicator |
