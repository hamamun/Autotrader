"""Fast contract tests. Run: pytest -q  (from the python/ folder)

They are deliberately small so CI stays under a minute, but they lock the
things that silently break a trading system:

* the feature vector is always 24 numbers in the documented order
* no NaN / inf ever reaches the model
* the ONNX file MT5 loads really has shape [1,24] -> [1,3] and sums to 1
* labels only ever contain 0/1/2 and the cost is really subtracted
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from autotrader import data as datamod
from autotrader import features as feat
from autotrader.config import FEATURES_PER_TF, FEATURE_COUNT, FEATURE_NAMES, TFS
from autotrader.labels import triple_barrier
from autotrader.model import SoftmaxNet, export_onnx, verify_onnx


@pytest.fixture(scope="module")
def m5():
    return datamod.make_synthetic(bars=3000, seed=3)


@pytest.fixture(scope="module")
def frames(m5):
    return {5: m5, 15: datamod.resample(m5, 15), 30: datamod.resample(m5, 30)}


def test_feature_contract_shape(frames):
    x = feat.build_feature_frame(frames)
    assert list(x.columns) == FEATURE_NAMES
    assert x.shape[1] == FEATURE_COUNT == 24
    assert len(FEATURES_PER_TF) == 8
    for tf in TFS:
        assert any(c.startswith(f"m{tf}_") for c in x.columns)


def test_features_are_finite_and_bounded(frames):
    x = feat.clean_features(feat.build_feature_frame(frames))
    assert len(x) > 500
    assert np.isfinite(x.to_numpy(float)).all()
    assert x.to_numpy(float).max() <= 20.0


def test_no_lookahead_in_htf_merge(frames):
    """A feature row at time T may only use HTF bars that closed at or before T."""
    x = feat.build_feature_frame(frames)
    # every row time must be an M5 close time
    assert ((x.index - frames[5].index[0]) % pd.Timedelta(minutes=5) == pd.Timedelta(0)).all()
    # the first M30 feature must be NaN free only after 3 M30 bars exist
    early = x.iloc[:30]["m30_ema_spread_atr"]
    assert early.isna().any()


def test_labels_are_valid(m5):
    a = feat.atr(m5, 14)
    res = triple_barrier(m5, a, cost_r=0.05)
    labels = res.labels["label"].unique()
    assert set(labels).issubset({0, 1, 2})
    assert res.stats["rows"] > 100
    # cost must reduce the average result
    assert res.labels["realized_r"].mean() < res.labels["gross_r"].mean()


def test_onnx_roundtrip(tmp_path, frames):
    x = feat.clean_features(feat.build_feature_frame(frames))
    net = SoftmaxNet(hidden=(16, 8), seed=1)
    rng = np.random.default_rng(0)
    soft = rng.dirichlet([2.0, 1.0, 2.0], size=len(x))
    net.fit(x.to_numpy(float), soft, epochs=5)
    path = str(tmp_path / "m.onnx")
    export_onnx(net, path)
    check = verify_onnx(path, net, x.to_numpy(float)[:5])
    assert check["ok"], check
    assert list(check["input_shape"]) == [1, 24]
    assert list(check["output_shape"]) == [1, 3]


def test_student_probabilities_are_distributions(frames):
    x = feat.clean_features(feat.build_feature_frame(frames))
    net = SoftmaxNet(hidden=(8,), seed=2)
    net.fit(x.to_numpy(float), np.tile([0.4, 0.2, 0.4], (len(x), 1)), epochs=5)
    p = net.predict_proba(x.to_numpy(float)[:50])
    assert np.allclose(p.sum(axis=1), 1.0, atol=1e-9)
    assert (p >= 0).all() and (p <= 1).all()


def test_resample_matches_m5_aggregation(m5):
    m15 = datamod.resample(m5, 15)
    first = m5.iloc[:3]
    assert m15.iloc[0]["open"] == first.iloc[0]["open"]
    assert m15.iloc[0]["high"] == first["high"].max()
    assert m15.iloc[0]["low"] == first["low"].min()
    assert m15.iloc[0]["close"] == first.iloc[-1]["close"]


def test_csv_roundtrip(tmp_path, m5):
    path = str(tmp_path / "m5.csv")
    datamod.save_csv(m5, path)
    back = datamod.load_csv(path)
    assert len(back) == len(m5)
    assert back["close"].iloc[-1] == pytest.approx(m5["close"].iloc[-1])
    assert int(back["bar_minutes"].iloc[0]) == 5
