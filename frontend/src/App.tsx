import { useMemo, useState } from "react";

import type { ExecutionMode, OrderDraft } from "../../shared/types/order";

type SliceLog = {
  index: number;
  amountIn: number;
  amountOut: number;
  ts: string;
};

type ActiveOrder = {
  draft: OrderDraft;
  totalIn: number;
  remainingIn: number;
  totalOut: number;
  baselineOut: number;
  slices: SliceLog[];
};

const MARKET_PRICE = 2750;

const defaultDraft: OrderDraft = {
  tokenIn: "WETH",
  tokenOut: "USDC",
  amountInTotal: "50",
  mode: "BBE",
  maxSliceAmount: "10",
  minSliceAmount: "5",
  maxImpactBps: 500,
  minAmountOutPerSlice: "1"
};

function parsePositive(value: string): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

export default function App() {
  const [draft, setDraft] = useState<OrderDraft>(defaultDraft);
  const [order, setOrder] = useState<ActiveOrder | null>(null);
  const [error, setError] = useState<string>("");

  const progressPct = useMemo(() => {
    if (!order) {
      return 0;
    }
    return ((order.totalIn - order.remainingIn) / order.totalIn) * 100;
  }, [order]);

  const averageExecutionPrice = useMemo(() => {
    if (!order) {
      return 0;
    }
    const executedIn = order.totalIn - order.remainingIn;
    return executedIn > 0 ? order.totalOut / executedIn : 0;
  }, [order]);

  const baselinePrice = useMemo(() => {
    if (!order) {
      return 0;
    }
    return order.baselineOut / order.totalIn;
  }, [order]);

  const improvementBps = useMemo(() => {
    if (!order || baselinePrice === 0 || averageExecutionPrice === 0) {
      return 0;
    }
    return ((averageExecutionPrice - baselinePrice) / baselinePrice) * 10000;
  }, [order, averageExecutionPrice, baselinePrice]);

  function createOrder() {
    const totalIn = parsePositive(draft.amountInTotal);
    const maxSlice = parsePositive(draft.maxSliceAmount);
    const minSlice = parsePositive(draft.minSliceAmount);

    if (!totalIn || !maxSlice || !minSlice || minSlice > maxSlice || maxSlice > totalIn) {
      setError("Invalid size settings. Ensure minSlice <= maxSlice <= totalIn.");
      return;
    }

    const baselineImpact = 0.014;
    const baselineOut = totalIn * MARKET_PRICE * (1 - baselineImpact);

    setOrder({
      draft,
      totalIn,
      remainingIn: totalIn,
      totalOut: 0,
      baselineOut,
      slices: []
    });
    setError("");
  }

  function executeNextSlice() {
    if (!order || order.remainingIn <= 0) {
      return;
    }

    const maxSlice = parsePositive(order.draft.maxSliceAmount);
    const amountIn = Math.min(maxSlice, order.remainingIn);

    const modeFactor = order.draft.mode === "BBE" ? 1.0 : 0.8;
    const randomMicro = Math.random() * 0.0015;
    const perSliceImpact = (0.0018 + randomMicro) * modeFactor;

    const amountOut = amountIn * MARKET_PRICE * (1 - perSliceImpact);

    const nextSlice: SliceLog = {
      index: order.slices.length,
      amountIn,
      amountOut,
      ts: new Date().toLocaleTimeString()
    };

    setOrder({
      ...order,
      remainingIn: Math.max(0, order.remainingIn - amountIn),
      totalOut: order.totalOut + amountOut,
      slices: [...order.slices, nextSlice]
    });
  }

  return (
    <main className="shell">
      <section className="hero">
        <p className="eyebrow">Large-Cap Execution Hook</p>
        <h1>Block-Segmented Execution Console</h1>
        <p>
          Simulate segmented execution for large orders with cadence control, slice tracking, and baseline comparison.
        </p>
      </section>

      <section className="panel form-panel">
        <h2>Create Large Order</h2>
        <div className="grid two">
          <label>
            Token In
            <input value={draft.tokenIn} onChange={(e) => setDraft({ ...draft, tokenIn: e.target.value })} />
          </label>
          <label>
            Token Out
            <input value={draft.tokenOut} onChange={(e) => setDraft({ ...draft, tokenOut: e.target.value })} />
          </label>
          <label>
            Amount In Total
            <input value={draft.amountInTotal} onChange={(e) => setDraft({ ...draft, amountInTotal: e.target.value })} />
          </label>
          <label>
            Max Slice Amount
            <input value={draft.maxSliceAmount} onChange={(e) => setDraft({ ...draft, maxSliceAmount: e.target.value })} />
          </label>
          <label>
            Min Slice Amount
            <input value={draft.minSliceAmount} onChange={(e) => setDraft({ ...draft, minSliceAmount: e.target.value })} />
          </label>
          <label>
            Max Impact (bps)
            <input
              type="number"
              value={draft.maxImpactBps}
              onChange={(e) => setDraft({ ...draft, maxImpactBps: Number(e.target.value) })}
            />
          </label>
        </div>

        <div className="mode-row" role="radiogroup" aria-label="Execution Mode">
          {(["BBE", "SOF"] as ExecutionMode[]).map((mode) => (
            <button
              key={mode}
              className={draft.mode === mode ? "mode active" : "mode"}
              onClick={() => setDraft({ ...draft, mode })}
            >
              {mode === "BBE" ? "Block-Based Execution" : "Segmented Order Flow"}
            </button>
          ))}
        </div>

        <div className="actions">
          <button className="primary" onClick={createOrder}>
            Create Order
          </button>
          <button className="secondary" onClick={executeNextSlice} disabled={!order || order.remainingIn === 0}>
            Execute Next Slice
          </button>
        </div>

        {error && <p className="error">{error}</p>}
      </section>

      <section className="panel stats-panel">
        <h2>Execution Progress</h2>
        <div className="meter">
          <div className="meter-fill" style={{ width: `${progressPct}%` }} />
        </div>
        <div className="grid three metrics">
          <article>
            <span>Filled</span>
            <strong>{progressPct.toFixed(2)}%</strong>
          </article>
          <article>
            <span>Realized Avg Px</span>
            <strong>{averageExecutionPrice.toFixed(2)}</strong>
          </article>
          <article>
            <span>Naive Baseline Px</span>
            <strong>{baselinePrice.toFixed(2)}</strong>
          </article>
          <article>
            <span>Total Out</span>
            <strong>{order ? order.totalOut.toFixed(2) : "0.00"}</strong>
          </article>
          <article>
            <span>Slices</span>
            <strong>{order?.slices.length ?? 0}</strong>
          </article>
          <article>
            <span>Improvement (bps)</span>
            <strong className={improvementBps >= 0 ? "positive" : "negative"}>{improvementBps.toFixed(2)}</strong>
          </article>
        </div>
      </section>

      <section className="panel log-panel">
        <h2>Slice Log</h2>
        <div className="log-head">
          <span>#</span>
          <span>Amount In</span>
          <span>Amount Out</span>
          <span>Time</span>
        </div>
        {order?.slices.map((slice) => (
          <div className="log-row" key={slice.index}>
            <span>{slice.index}</span>
            <span>{slice.amountIn.toFixed(4)}</span>
            <span>{slice.amountOut.toFixed(2)}</span>
            <span>{slice.ts}</span>
          </div>
        ))}
        {!order?.slices.length && <p className="empty">No slice executions yet.</p>}
      </section>
    </main>
  );
}
