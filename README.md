## ScaleOutClose_EA

An always-visible on-chart panel for manual position management on MT5. One row per open position on the chart's symbol, with five independent buttons:

| Button | Action |
|---|---|
| **Scale out** | 3-click market-close cadence: 50% → 50% of what's left (25% of original) → the rest. Auto-collapses to a full close if a remaining split would fall under the symbol's minimum volume. Row shows `# ticket \| volume \| $profit`, colored green/red by PnL. |
| **BE** | Moves SL to entry ± buffer (profit side). Never auto-hides — click again anytime to re-apply, e.g. after manually moving the SL. |
| **SL** | Sets a protective SL at entry ∓ a fixed distance — for positions opened by market with no stop at all. Never auto-hides. |
| **TP** | Sets a take-profit at entry ± a fixed distance — for positions opened with no target. Never auto-hides. |
| **Close** | Full market close of whatever remains, regardless of Scale-out click state. |

**Key design points**
- Every click is one deliberate, confirmed trade request — no automatic/per-tick behavior, so this is not "server spamming."
- All close/SL/TP-modify requests are sent via hand-built `MqlTradeRequest` + raw `OrderSend()` instead of `CTrade`, since `CTrade`'s wrapper was found to fail silently on some accounts (`false`, `retcode=0`, no error) — the raw path surfaces the actual broker retcode/comment.
- Click state only advances on a **confirmed successful** trade response; a failed/rejected attempt never gets marked done, so retrying is always safe.
- Works on whatever symbol the chart shows — not limited to a specific instrument.
- Panel auto-refreshes every second from live position data (no extra server calls — reads what MT5 already has locally).

**Inputs**
- `InpPanelX`, `InpPanelY` — panel position on the chart.
- `InpDeviationPoints` (default 100) — allowed slippage for market closes.
- `InpBreakevenBufferPoints` (default 70) — BE offset from entry.
- `InpSetSlPoints` (default 200) / `InpSetTpPoints` (default 300) — fixed SL/TP distance from entry.
- `InpMagic` — magic number stamped on close deals (0 = leave default).
