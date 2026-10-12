"""The exported model: a small softmax network, trained on soft targets.

Why a neural net and not the gradient boosting model itself? MT5 loads
ONNX with the standard opset. A network of MatMul / Add / Relu / Softmax
runs everywhere. Tree ensembles need the ai.onnx.ml domain, which is not
guaranteed on every MT5 build.

So we keep the strong model (LightGBM) as the *teacher* and distil it
into a tiny student that MT5 can run in microseconds.
"""

from __future__ import annotations

import numpy as np

from .config import FEATURE_COUNT


# ----------------------------------------------------------------------
# student model
# ----------------------------------------------------------------------
class SoftmaxNet:
    """Fully connected net: in -> relu -> relu -> softmax."""

    def __init__(self, hidden=(64, 32), seed=0):
        self.hidden = tuple(hidden)
        self.seed = seed
        self.mean: np.ndarray | None = None
        self.std: np.ndarray | None = None
        self.W: list[np.ndarray] = []
        self.b: list[np.ndarray] = []

    # -- forward -------------------------------------------------------
    def _forward(self, X: np.ndarray):
        h = X
        acts = [h]
        for i, (w, b) in enumerate(zip(self.W, self.b)):
            z = h @ w + b
            h = np.maximum(z, 0.0) if i < len(self.W) - 1 else z
            acts.append(h)
        return acts

    def predict_proba(self, X: np.ndarray) -> np.ndarray:
        X = np.asarray(X, dtype=np.float64)
        Xn = (X - self.mean) / self.std
        z = self._forward(Xn)[-1]
        z = z - z.max(axis=1, keepdims=True)
        e = np.exp(z)
        return e / e.sum(axis=1, keepdims=True)

    # -- training ------------------------------------------------------
    def fit(self, X, Y_soft, epochs=600, lr=3e-3, l2=1e-4, batch=512,
            val_frac=0.15, patience=60, class_weight=None, verbose=False):
        X = np.asarray(X, dtype=np.float64)
        Y_soft = np.asarray(Y_soft, dtype=np.float64)
        Y_soft = Y_soft / Y_soft.sum(axis=1, keepdims=True)
        self.mean = X.mean(axis=0)
        self.std = X.std(axis=0)
        self.std[self.std < 1e-8] = 1.0
        Xn = (X - self.mean) / self.std

        # walk forward split: validate on the tail of the sample
        cut = int(len(Xn) * (1.0 - val_frac))
        Xtr, Ytr, Xva, Yva = Xn[:cut], Y_soft[:cut], Xn[cut:], Y_soft[cut:]

        if class_weight is not None:
            w = np.asarray(class_weight, dtype=np.float64)
            w = w / w.mean()
            Ytr = Ytr * w[None, :]
            Yva = Yva * w[None, :]

        rng = np.random.default_rng(self.seed)
        dims = [FEATURE_COUNT, *self.hidden, Y_soft.shape[1]]
        self.W, self.b = [], []
        mW, vW, mb, vb = [], [], [], []
        for i in range(len(dims) - 1):
            lim = np.sqrt(6.0 / (dims[i] + dims[i + 1]))
            self.W.append(rng.uniform(-lim, lim, size=(dims[i], dims[i + 1])))
            self.b.append(np.zeros(dims[i + 1]))
            mW.append(np.zeros_like(self.W[-1])); vW.append(np.zeros_like(self.W[-1]))
            mb.append(np.zeros_like(self.b[-1])); vb.append(np.zeros_like(self.b[-1]))

        best = np.inf
        best_state = None
        bad = 0
        t = 0
        for epoch in range(epochs):
            order = rng.permutation(len(Xtr))
            for start in range(0, len(Xtr), batch):
                idx = order[start:start + batch]
                xb, yb = Xtr[idx], Ytr[idx]
                grads = self._backward(xb, yb)
                t += 1
                for i in range(len(self.W)):
                    gW = grads["W"][i] + l2 * self.W[i]
                    gb = grads["b"][i]
                    mW[i] = 0.9 * mW[i] + 0.1 * gW
                    vW[i] = 0.999 * vW[i] + 0.001 * gW ** 2
                    mb[i] = 0.9 * mb[i] + 0.1 * gb
                    vb[i] = 0.999 * vb[i] + 0.001 * gb ** 2
                    mhat = mW[i] / (1 - 0.9 ** t)
                    vhat = vW[i] / (1 - 0.999 ** t)
                    self.W[i] -= lr * mhat / (np.sqrt(vhat) + 1e-8)
                    mhatb = mb[i] / (1 - 0.9 ** t)
                    vhatb = vb[i] / (1 - 0.999 ** t)
                    self.b[i] -= lr * mhatb / (np.sqrt(vhatb) + 1e-8)

            if len(Xva):
                loss = self._loss(Xva, Yva)
                if loss < best - 1e-5:
                    best = loss
                    best_state = ([w.copy() for w in self.W], [b.copy() for b in self.b])
                    bad = 0
                else:
                    bad += 1
                    if bad >= patience:
                        break
            if verbose and epoch % 50 == 0:
                print(f"  epoch {epoch:4d} loss {self._loss(Xva, Yva) if len(Xva) else float('nan'):.5f}")

        if best_state is not None:
            self.W, self.b = best_state
        return self

    # -- internals -----------------------------------------------------
    def _loss(self, Xn, Y):
        z = self._forward(Xn)[-1]
        z = z - z.max(axis=1, keepdims=True)
        logp = z - np.log(np.exp(z).sum(axis=1, keepdims=True))
        return float(-(Y * logp).sum(axis=1).mean())

    def _backward(self, xb, yb):
        acts = self._forward(xb)
        z = acts[-1]
        z = z - z.max(axis=1, keepdims=True)
        p = np.exp(z)
        p = p / p.sum(axis=1, keepdims=True)
        delta = (p - yb) / len(xb)
        gW, gb = [None] * len(self.W), [None] * len(self.b)
        for i in reversed(range(len(self.W))):
            gW[i] = acts[i].T @ delta
            gb[i] = delta.sum(axis=0)
            if i > 0:
                delta = (delta @ self.W[i].T) * (acts[i] > 0)
        return {"W": gW, "b": gb}


# ----------------------------------------------------------------------
# ONNX export (baked in standardisation, so MT5 feeds raw features)
# ----------------------------------------------------------------------
def export_onnx(net: SoftmaxNet, path: str, opset: int = 15) -> str:
    import onnx
    from onnx import TensorProto, helper, numpy_helper

    def init(name, array):
        return numpy_helper.from_array(np.asarray(array, dtype=np.float32), name=name)

    # bake normalisation into the first layer so MT5 needs no scaler
    W0 = net.W[0] / net.std[:, None]
    b0 = net.b[0] - (net.mean / net.std) @ net.W[0]

    weights = [W0] + list(net.W[1:])
    biases = [b0] + list(net.b[1:])

    nodes = []
    initializers = []
    prev = "features"
    for i, (w, b) in enumerate(zip(weights, biases)):
        wn, bn, zn = f"W{i}", f"B{i}", f"Z{i}"
        initializers.append(init(wn, w))
        initializers.append(init(bn, b))
        nodes.append(helper.make_node("MatMul", [prev, wn], [f"M{i}"]))
        nodes.append(helper.make_node("Add", [f"M{i}", bn], [zn]))
        if i < len(weights) - 1:
            nodes.append(helper.make_node("Relu", [zn], [f"R{i}"]))
            prev = f"R{i}"
        else:
            prev = zn
    nodes.append(helper.make_node("Softmax", [prev], ["probabilities"], axis=1))

    graph = helper.make_graph(
        nodes,
        "autotrader_direction",
        [helper.make_tensor_value_info("features", TensorProto.FLOAT, [1, FEATURE_COUNT])],
        [helper.make_tensor_value_info("probabilities", TensorProto.FLOAT, [1, 3])],
        initializer=initializers,
    )
    model = helper.make_model(
        graph,
        producer_name="autotrader",
        opset_imports=[helper.make_opsetid("", opset)],
    )
    model.ir_version = 8
    onnx.checker.check_model(model)
    onnx.save(model, path)
    return path


def verify_onnx(path: str, net: SoftmaxNet, X_sample: np.ndarray,
                atol: float = 1e-4) -> dict:
    """Load the exported file in a real runtime and compare with numpy."""
    import onnxruntime as ort

    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    out = sess.get_outputs()[0]
    max_diff = 0.0
    for row in X_sample:
        x = row.reshape(1, -1).astype(np.float32)
        got = sess.run([out.name], {inp.name: x})[0][0]
        want = net.predict_proba(row.reshape(1, -1))[0]
        max_diff = max(max_diff, float(np.max(np.abs(got - want))))
    return {
        "input_name": inp.name,
        "input_shape": inp.shape,
        "output_name": out.name,
        "output_shape": out.shape,
        "max_abs_diff": max_diff,
        "ok": max_diff <= atol,
    }
