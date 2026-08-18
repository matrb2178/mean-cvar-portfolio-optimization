# Mean-CVaR Portfolio Optimization

An R-based multi-asset portfolio optimization project evaluating whether controlled exposure to **Bitcoin and Ethereum** can improve portfolio efficiency under different risk-modeling frameworks.

The project combines **Mean-CVaR optimization**, **Markowitz mean-variance optimization**, efficient-frontier construction, rolling out-of-sample validation, transaction costs, turnover controls, and naïve 1/N benchmarks.

> **Academic and reproducible portfolio-allocation exercise. This repository is not investment advice.**

---

## Research Question

**Can Bitcoin and Ethereum improve the risk-adjusted performance of a diversified multi-asset portfolio when portfolio risk is explicitly controlled?**

The analysis also asks:

- Does the diversification benefit of crypto persist out-of-sample?
- Does crypto reduce portfolio risk, or does it provide enough additional return to compensate for higher risk?
- Does Mean-CVaR outperform traditional Markowitz optimization when heavy-tailed cryptoassets are introduced?
- Is the choice of risk model more important than the choice of investment opportunity set?

---

## Executive Summary

The rolling out-of-sample experiment covers **13 November 2018 to 22 May 2026**, using **1,890 daily observations** and continuous return series net of modeled transaction costs.

The main findings are:

- Adding Bitcoin and Ethereum improved risk-adjusted performance under **both Mean-CVaR and Markowitz**.
- Crypto did **not** reduce absolute portfolio risk. Its contribution came through higher return relative to the additional risk assumed.
- **Markowitz + Crypto** produced the strongest overall results among the optimized portfolios.
- Mean-CVaR + Crypto remained competitive, but it did **not** outperform Markowitz in this historical OOS experiment.
- The naïve 1/N crypto portfolio produced the highest absolute return, but at the cost of substantially greater volatility, CVaR, and drawdown.
- Expanding the investment universe to include crypto had a materially larger economic effect than switching between Mean-CVaR and Markowitz.
- Crypto exposure was **time-varying and regime-dependent**, rather than mechanically positive.

The main empirical contribution is therefore not evidence that Mean-CVaR universally dominates Markowitz. Instead, the results suggest that **controlled crypto exposure improved portfolio efficiency across both frameworks, while asset-universe selection had a larger economic impact than the choice between variance and CVaR as the risk measure**.

---

## Asset Universe

| Ticker | Asset Class | Portfolio Role |
|---|---|---|
| SPY | U.S. Equities | Core growth exposure |
| EEM | Emerging-Market Equities | Geographic diversification |
| AGG | U.S. Investment-Grade Bonds | Defensive fixed income |
| BIL | U.S. Treasury Bills | Liquidity / low-risk proxy |
| VNQ | Real Estate | Real-asset exposure |
| GLD | Gold | Defensive alternative asset |
| DBC | Broad Commodities | Inflation / commodity-cycle exposure |
| BTC-USD | Bitcoin | High-risk alternative asset |
| ETH-USD | Ethereum | Digital-asset diversification |

The universe is deliberately broader than a traditional equity-bond portfolio. Cryptoassets must therefore demonstrate incremental value after the traditional opportunity set already contains equities, bonds, liquidity, real estate, gold, and commodities.

---

## Why Compare Mean-CVaR and Markowitz?

Traditional Markowitz optimization measures risk through **variance or standard deviation**, treating upside and downside deviations symmetrically.

Mean-CVaR instead focuses on **Conditional Value at Risk / Expected Shortfall**, emphasizing severe downside losses beyond a selected confidence threshold.

This distinction is especially relevant for assets such as Bitcoin and Ethereum, whose historical returns exhibit:

- substantial negative tail events;
- non-normal distributions;
- excess kurtosis;
- unstable correlations;
- large historical drawdowns.

The empirical question is therefore not only whether CVaR is theoretically attractive, but whether explicitly modeling tail risk leads to better realized out-of-sample portfolios.

---

## Risk Models and Selection Rules

| Framework | Risk Measure | Selection Rule |
|---|---|---|
| Mean-CVaR | Historical CVaR / Expected Shortfall | Maximum STARR |
| Markowitz | Variance / Standard Deviation | Maximum Sharpe |
| 1/N | No optimization | Equal weighting |

The Mean-CVaR and Markowitz strategies use the same asset universe, portfolio constraints, rolling windows, transaction-cost assumptions, and turnover controls.

---

## Portfolio Constraints

| Asset | Maximum Weight |
|---|---:|
| SPY | 60% |
| EEM | 15% |
| AGG | 40% |
| BIL | 10% |
| VNQ | 15% |
| GLD | 15% |
| DBC | 15% |
| BTC | 10% |
| ETH | 10% |
| BTC + ETH | **15% combined** |

Additional assumptions:

- long-only allocation;
- full investment;
- no leverage;
- 252-trading-day training window;
- 63-trading-day rebalance frequency;
- maximum executed turnover per rebalance: **0.80**;
- transaction-cost assumption: **0.30% of traded notional**;
- historical CVaR confidence level: **95%**.

The BIL cap helps prevent trivial low-risk corner solutions and forces the optimizer to construct an economically meaningful diversified portfolio.

---

## Data and Return Construction

Historical adjusted prices are downloaded from Yahoo Finance.

The data pipeline is:

```text
Adjusted prices
      ↓
Align all assets on common trading dates
      ↓
Compute arithmetic returns
      ↓
252-day rolling training window
      ↓
Estimate portfolio opportunity set
      ↓
Select portfolio
      ↓
Apply turnover constraint
      ↓
Charge transaction costs
      ↓
Evaluate next 63-day OOS period
      ↓
Repeat
```

Prices are aligned **before** returns are computed. For cryptoassets, this preserves the full Friday-to-Monday movement when the continuously traded crypto series is aligned to the weekday ETF calendar.

Arithmetic returns are used because portfolio returns are linear combinations of arithmetic asset returns.

---

## Rolling Out-of-Sample Design

At each rebalance date, the model:

1. Uses only the previous **252 trading days**.
2. Estimates the feasible portfolio opportunity set.
3. Selects the preferred portfolio:
   - maximum STARR for Mean-CVaR;
   - maximum Sharpe for Markowitz.
4. Applies the turnover constraint relative to the drifted current portfolio.
5. Charges transaction costs on the rebalance date.
6. Evaluates the allocation over the following **63 trading days**.
7. Repeats the process without look-ahead.

The daily OOS series is concatenated across all periods. Maximum drawdown is therefore calculated from the **continuous wealth path** rather than reset at each quarterly rebalance.

---

## Out-of-Sample Results

### Full strategy comparison

| Strategy | CAGR | Volatility | Sharpe | Sortino | Daily CVaR 95% | STARR | Max Drawdown | Calmar |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Mean-CVaR + Crypto | 17.02% | 13.01% | 1.076 | 1.550 | 1.904% | 0.0292 | 19.52% | 0.872 |
| Mean-CVaR ex Crypto | 10.40% | 10.22% | 0.767 | 1.072 | 1.558% | 0.0200 | 17.40% | 0.598 |
| **Markowitz + Crypto** | **17.55%** | **12.73%** | **1.132** | **1.643** | **1.860%** | **0.0307** | **18.23%** | **0.963** |
| Markowitz ex Crypto | 11.08% | 10.35% | 0.818 | 1.146 | 1.569% | 0.0214 | **16.92%** | 0.655 |
| 1/N + Crypto | **22.38%** | 19.71% | 0.994 | 1.408 | 2.887% | 0.0269 | 31.57% | 0.709 |
| 1/N ex Crypto | 10.21% | **10.16%** | 0.754 | 1.027 | **1.523%** | 0.0200 | 19.58% | 0.522 |

These results should not be reduced to a single return ranking. The strategies represent different portfolio-construction approaches and assume different risk profiles.

---

## Finding 1 — Crypto Improved Both Optimization Frameworks

The strongest empirical result is that adding Bitcoin and Ethereum improved risk-adjusted performance under **both** optimization frameworks.

### Mean-CVaR

| Metric | With Crypto | Without Crypto |
|---|---:|---:|
| CAGR | **17.02%** | 10.40% |
| Sharpe | **1.076** | 0.767 |
| Sortino | **1.550** | 1.072 |
| STARR | **0.0292** | 0.0200 |
| Calmar | **0.872** | 0.598 |

### Markowitz

| Metric | With Crypto | Without Crypto |
|---|---:|---:|
| CAGR | **17.55%** | 11.08% |
| Sharpe | **1.132** | 0.818 |
| Sortino | **1.643** | 1.146 |
| STARR | **0.0307** | 0.0214 |
| Calmar | **0.963** | 0.655 |

The favorable crypto result therefore does **not** appear to be an artifact of choosing CVaR as the risk measure.

> **Controlled crypto exposure improved the return-to-risk trade-off under both Mean-CVaR and Markowitz over the historical OOS period.**

---

## Finding 2 — Crypto Improved Efficiency, Not Absolute Safety

For Mean-CVaR, adding crypto increased:

- annualized volatility from **10.22% to 13.01%**;
- daily CVaR from **1.56% to 1.90%**;
- maximum drawdown from **17.40% to 19.52%**.

The additional return was nevertheless large enough to improve Sharpe, Sortino, STARR, and Calmar.

The correct interpretation is therefore:

> **Crypto improved compensation per unit of risk rather than reducing absolute portfolio risk.**

---

## Finding 3 — Markowitz Outperformed Mean-CVaR in This OOS Experiment

Contrary to what might be expected from a tail-risk optimization framework, Mean-CVaR did **not** outperform Markowitz in the rolling OOS experiment.

### Crypto universe

| Metric | Mean-CVaR | Markowitz |
|---|---:|---:|
| CAGR | 17.02% | **17.55%** |
| Volatility | 13.01% | **12.73%** |
| Sharpe | 1.076 | **1.132** |
| Sortino | 1.550 | **1.643** |
| Daily CVaR 95% | 1.904% | **1.860%** |
| STARR | 0.0292 | **0.0307** |
| Max Drawdown | 19.52% | **18.23%** |
| Calmar | 0.872 | **0.963** |

Markowitz + Crypto achieved slightly higher return while simultaneously producing lower realized volatility, lower CVaR, and a smaller maximum drawdown.

The theoretical appeal of directly minimizing Expected Shortfall therefore **did not translate into superior realized OOS performance in this historical experiment**.

This does not imply that variance is universally a superior risk measure. It only means that, under this sample, asset universe, and constraint structure, Markowitz produced the stronger realized result.

---

## Finding 4 — Markowitz Required Less Turnover

Implementation efficiency matters because optimization gains can be eroded by trading activity.

| Strategy | Average Turnover | Total Transaction Costs |
|---|---:|---:|
| Mean-CVaR + Crypto | 34.76% | $60,203 |
| **Markowitz + Crypto** | **28.88%** | **$51,035** |
| Mean-CVaR ex Crypto | 29.71% | $38,609 |
| **Markowitz ex Crypto** | **26.41%** | **$35,756** |

Markowitz required less portfolio turnover in both opportunity sets and therefore incurred lower modeled transaction costs.

This strengthens its OOS result because the improvement was not obtained through more aggressive trading.

---

## Finding 5 — Asset-Universe Choice Mattered More Than Risk-Model Choice

This is one of the most important conclusions of the project.

In CAGR terms:

- Mean-CVaR: adding crypto increased CAGR from **10.40% to 17.02%**, approximately **+6.62 percentage points**.
- Markowitz: adding crypto increased CAGR from **11.08% to 17.55%**, approximately **+6.48 percentage points**.
- Within the crypto universe, switching from Mean-CVaR to Markowitz changed CAGR from **17.02% to 17.55%**, approximately **+0.53 percentage points**.

The economic impact of changing the opportunity set was therefore materially larger than changing the optimization risk measure.

> **Within this historical sample, asset-universe selection had a larger effect on realized portfolio performance than the choice between variance and CVaR.**

---

## Finding 6 — 1/N Captured More Upside but Much More Risk

The equal-weight crypto benchmark generated the highest CAGR at **22.38%**.

However, it also produced:

- annualized volatility of **19.71%**;
- daily CVaR of **2.89%**;
- maximum drawdown of **31.57%**.

By comparison, Markowitz + Crypto generated:

- CAGR of **17.55%**;
- volatility of **12.73%**;
- CVaR of **1.86%**;
- maximum drawdown of **18.23%**.

The naïve portfolio therefore captured more upside, while optimization produced a substantially more controlled risk profile.

### Benchmark caveat

The 1/N crypto portfolio assigns roughly **22% combined exposure to BTC and ETH** because it equally weights all nine assets.

It is therefore **not subject to the same 15% aggregate crypto cap** imposed on the optimized portfolios.

The 1/N strategy is retained as a standard naïve benchmark, but it should not be interpreted as an alternative portfolio operating under an identical feasible set.

---

## In-Sample Mean-CVaR Interpretation

The Mean-CVaR efficient frontier indicates that allowing Bitcoin and Ethereum expands the historical investment opportunity set.

The maximum-STARR in-sample allocation is approximately:

| Asset | Weight |
|---|---:|
| SPY | 37.35% |
| AGG | 19.74% |
| BIL | 10.00% |
| GLD | 15.00% |
| DBC | 7.03% |
| BTC | 10.00% |
| ETH | 0.89% |

Total crypto exposure is approximately **10.89%**.

Bitcoin reaches its individual **10% upper bound**, while the combined BTC+ETH allocation remains below the 15% group cap.

The observed crypto weight is therefore **constraint-dependent** and should not be interpreted as an unconstrained estimate of the naturally optimal BTC allocation.

The in-sample analysis is descriptive. The rolling OOS experiment remains the primary source of performance evidence.

---

## Regime Dependence

The contribution of crypto was not constant through time.

The Mean-CVaR crypto strategy generated particularly strong relative performance during several periods, including 2020–2021 and 2023–2024, while the advantage weakened or reversed during other environments.

Most importantly, the final Mean-CVaR rolling training window selected **no crypto exposure**.

This means:

> **The model does not mechanically allocate to crypto. The portfolio contribution of Bitcoin and Ethereum is time-varying and regime-dependent.**

The empirical evidence therefore does not support a permanent positive crypto allocation solely because crypto improved full-period performance.

---

## Tail-Risk Evidence

The Mean-CVaR + Crypto OOS return series remains clearly non-normal.

Key diagnostics include:

- skewness: approximately **-0.28**;
- excess kurtosis: approximately **7.22**;
- historical daily ES 95%: approximately **1.90%**;
- modified / Cornish-Fisher daily ES 95%: approximately **2.25%**.

The modified ES estimate is roughly **18% larger** than the historical ES estimate.

These characteristics justify evaluating portfolio risk using more than standard deviation alone, even though Mean-CVaR did not ultimately outperform Markowitz in the OOS comparison.

A risk measure can be economically well motivated without necessarily producing the best realized portfolio in every historical sample.

---

## Conclusion

This project examined whether Bitcoin and Ethereum can improve a diversified multi-asset portfolio and whether explicitly modeling downside tail risk through Mean-CVaR produces better portfolio outcomes than traditional Markowitz optimization.

The evidence supports several conclusions.

First, controlled access to Bitcoin and Ethereum improved out-of-sample risk-adjusted performance under **both Mean-CVaR and Markowitz**.

Second, the improvement did not come from lower absolute risk. Crypto generally increased volatility and tail exposure. Its historical value came from providing enough incremental return to improve the compensation received for the additional risk assumed.

Third, **Mean-CVaR did not outperform Markowitz** in this experiment. Markowitz + Crypto achieved the strongest overall results among the optimized portfolios, combining a 17.55% CAGR with lower volatility, lower realized CVaR, a smaller maximum drawdown, lower turnover, and lower modeled transaction costs than Mean-CVaR + Crypto.

This is an important empirical result: the theoretical appeal of directly penalizing Expected Shortfall did not automatically translate into superior realized performance.

Fourth, the choice of investment opportunity set had a larger economic effect than the choice of optimization framework. Adding crypto increased CAGR by roughly 6.5 percentage points under both Mean-CVaR and Markowitz, while switching between the two risk models inside the crypto universe changed CAGR by only about half a percentage point.

The main conclusion is therefore:

> **The strongest empirical result is not that Mean-CVaR universally dominates Markowitz, but that controlled crypto exposure improved portfolio efficiency across both frameworks, while asset-universe selection had a larger economic impact than the choice of risk measure itself.**

Finally, the contribution of crypto was regime-dependent. Bitcoin and Ethereum were valuable in some estimation windows and unattractive in others.

A more useful portfolio-management question is therefore not:

> Should every diversified portfolio contain crypto?

but rather:

> **Under what market conditions, constraints, and risk assumptions does crypto provide enough expected return to compensate for its additional downside and tail risk?**

---

## Limitations

The analysis should be interpreted subject to several limitations:

- results are based on one realized historical path;
- expected returns and risks are estimated from rolling historical windows;
- the sample contains a limited number of distinct market regimes;
- portfolio outcomes depend on the selected asset universe and constraints;
- transaction costs are simplified and exclude market impact;
- taxes are excluded;
- historical CVaR does not guarantee future tail behavior;
- expected-return estimation remains a major source of model risk;
- no formal statistical-significance test is currently applied to strategy differences;
- the 1/N crypto benchmark does not share the optimizer's 15% aggregate crypto constraint;
- crypto market structure and correlations may change materially over time.

A block bootstrap or another time-series resampling procedure would be a natural extension for evaluating whether the observed differences in risk-adjusted performance are statistically robust.

---

## Repository Structure

```text
mean-cvar-portfolio-optimization/
├── mean-cvar-portfolio-optimization.Rproj
├── main.R
├── model_comparison.R
├── README.md
├── CHANGELOG.md
├── data/
└── output/
    ├── figures/
    └── tables/
```

---

## Main Script

Run the original Mean-CVaR analysis with:

```r
source("main.R")
```

The script:

- downloads and prepares historical prices;
- builds Mean-CVaR efficient frontiers;
- performs the rolling OOS backtest;
- applies transaction costs and turnover controls;
- evaluates 1/N benchmarks;
- exports figures and tables.

---

## Model Comparison

Run:

```r
source("main.R")
source("model_comparison.R")
```

The comparison script adds:

- Markowitz efficient frontiers;
- maximum-Sharpe portfolio selection;
- rolling Markowitz OOS backtests with and without crypto;
- six-strategy comparison across Mean-CVaR, Markowitz, and 1/N;
- comparative risk-return metrics;
- turnover and cost comparisons;
- additional figures and CSV outputs.

---

## Requirements

Core packages include:

```r
c(
  "tidyverse",
  "tidyquant",
  "xts",
  "PerformanceAnalytics",
  "PortfolioAnalytics",
  "ROI",
  "ROI.plugin.glpk",
  "quadprog"
)
```

Install missing packages with:

```r
install.packages(c(
  "tidyverse",
  "tidyquant",
  "xts",
  "PerformanceAnalytics",
  "PortfolioAnalytics",
  "ROI",
  "ROI.plugin.glpk",
  "quadprog"
))
```

---

## Reproducibility

The historical analysis is deterministic conditional on:

- selected tickers;
- configured start and end dates;
- adjusted-price history returned by the data source;
- portfolio constraints;
- transaction-cost assumptions;
- turnover cap;
- training-window length;
- rebalance frequency;
- optimizer configuration.

The optional actionable-portfolio section is disabled by default because it uses current market prices and is therefore time-dependent.

---

## Disclaimer

This repository is an academic and research-oriented portfolio-allocation exercise.

Historical results do not guarantee future performance. Nothing in this repository should be interpreted as personalized investment advice or as a recommendation to buy or sell any financial instrument.
