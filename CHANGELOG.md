# Changelog

## 2026-08-18 — Public-repository version

### Methodology and implementation

- Uses arithmetic asset returns after aligning adjusted-price histories on common dates.
- Reports historical Expected Shortfall / CVaR as a positive loss magnitude.
- Keeps CVaR at daily frequency rather than mechanically scaling it by `sqrt(252)`.
- Annualizes mean return only for economic interpretation.
- Uses a 252-trading-day rolling training window and approximately quarterly OOS rebalancing.
- Charges transaction costs inside the daily OOS return stream.
- Applies turnover control relative to drifted portfolio weights.
- Preserves a continuous OOS wealth path across rebalance periods.
- Adds sanity checks for dates, capital reconciliation, portfolio weights and turnover.

### Visualizations

- Efficient-frontier labels now clarify that CVaR is a positive loss magnitude.
- OOS performance is shown as a wealth index with base 100 rather than nominal starting capital.
- The primary drawdown figure compares only Mean-CVaR with vs. without crypto for readability.
- A second all-strategy drawdown figure is exported for appendix/diagnostic use.
- Annual-return charts flag partial calendar years.
- The OOS return-distribution plot labels the empirical 95% VaR and the observed daily mean explicitly.
