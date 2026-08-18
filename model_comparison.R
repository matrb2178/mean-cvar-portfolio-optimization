# =========================================================
# MODEL COMPARISON: MEAN-CVAR vs MARKOWITZ vs 1/N
# =========================================================
# This script extends main.R without changing the validated Mean-CVaR
# implementation. It uses the same data, constraints, transaction costs,
# turnover control, training window and OOS dates.
#
# Mean-CVaR: selected by maximum daily STARR.
# Markowitz: selected by maximum daily Sharpe.
# 1/N: naïve benchmark already produced by main.R.
#
# Run:
#   source("main.R")
#   source("model_comparison.R")
# =========================================================

if (!exists("R_all") || !exists("backtest_oos") || !exists("bt_con_full")) {
  message("Core objects not found. Running main.R first...")
  source("main.R")
}

if (!requireNamespace("quadprog", quietly = TRUE)) {
  stop(
    "The Markowitz extension requires package 'quadprog'. Install it with:\n",
    "install.packages('quadprog')",
    call. = FALSE
  )
}

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------

build_base_portfolio_spec <- function(assets, w_max,
                                      include_crypto = FALSE,
                                      crypto_cap = 0.15) {

  w_max <- w_max[assets]

  port <- portfolio.spec(assets = assets) %>%
    add.constraint(type = "full_investment") %>%
    add.constraint(
      type = "box",
      min = rep(0, length(assets)),
      max = w_max
    )

  if (include_crypto) {
    port <- port %>%
      add.constraint(
        type = "group",
        groups = list(
          tradicionales = which(!assets %in% tickers_cripto),
          cripto         = which(assets %in% tickers_cripto)
        ),
        group_min = c(0, 0),
        group_max = c(1, crypto_cap)
      )
  }

  port
}


solve_markowitz_qp <- function(R, w_max,
                               include_crypto = FALSE,
                               crypto_cap = 0.15,
                               target_return = NULL) {

  assets <- colnames(R)
  w_max  <- as.numeric(w_max[assets])
  names(w_max) <- assets

  mu <- colMeans(R)
  S  <- cov(coredata(R))

  # Small ridge for numerical positive-definiteness.
  ridge <- max(diag(S), na.rm = TRUE) * 1e-10
  if (!is.finite(ridge) || ridge <= 0) ridge <- 1e-10

  Dmat <- 2 * (S + diag(ridge, ncol(S)))
  dvec <- rep(0, length(assets))

  A_cols <- list(rep(1, length(assets)))
  bvec   <- 1
  meq    <- 1

  # Exact return target to construct the efficient frontier.
  if (!is.null(target_return)) {
    A_cols[[length(A_cols) + 1]] <- as.numeric(mu)
    bvec <- c(bvec, target_return)
    meq  <- 2
  }

  # Lower bounds: w_i >= 0
  I <- diag(length(assets))
  for (j in seq_along(assets)) {
    A_cols[[length(A_cols) + 1]] <- I[, j]
    bvec <- c(bvec, 0)
  }

  # Upper bounds: -w_i >= -w_max_i
  for (j in seq_along(assets)) {
    A_cols[[length(A_cols) + 1]] <- -I[, j]
    bvec <- c(bvec, -w_max[j])
  }

  # Aggregate crypto cap: -(w_BTC + w_ETH) >= -cap
  if (include_crypto) {
    g <- as.numeric(assets %in% tickers_cripto)
    A_cols[[length(A_cols) + 1]] <- -g
    bvec <- c(bvec, -crypto_cap)
  }

  Amat <- do.call(cbind, A_cols)

  sol <- quadprog::solve.QP(
    Dmat = Dmat,
    dvec = dvec,
    Amat = Amat,
    bvec = bvec,
    meq  = meq
  )

  w <- setNames(as.numeric(sol$solution), assets)

  # Clean only tiny numerical noise.
  w[abs(w) < 1e-10] <- 0

  w
}


build_frontier_markowitz <- function(R, w_max,
                                     include_crypto = FALSE,
                                     crypto_cap = 0.15,
                                     n_points = 20) {

  assets <- colnames(R)

  # Minimum-variance portfolio.
  w_minvar <- solve_markowitz_qp(
    R = R,
    w_max = w_max,
    include_crypto = include_crypto,
    crypto_cap = crypto_cap
  )

  # Maximum feasible return under exactly the same constraints.
  port_base <- build_base_portfolio_spec(
    assets = assets,
    w_max = w_max,
    include_crypto = include_crypto,
    crypto_cap = crypto_cap
  )

  maxret <- optimize.portfolio(
    R = R,
    portfolio = port_base %>%
      add.objective(type = "return", name = "mean", multiplier = -1),
    optimize_method = "ROI"
  )

  w_maxret <- extractWeights(maxret)

  ret_min <- port_mean(R, w_minvar)
  ret_max <- port_mean(R, w_maxret)

  if (!is.finite(ret_min) || !is.finite(ret_max) || ret_max < ret_min) {
    stop("Could not determine a valid Markowitz target-return range.", call. = FALSE)
  }

  targets <- seq(ret_min, ret_max, length.out = n_points)

  res <- lapply(seq_along(targets), function(i) {

    w <- tryCatch(
      solve_markowitz_qp(
        R = R,
        w_max = w_max,
        include_crypto = include_crypto,
        crypto_cap = crypto_cap,
        target_return = targets[i]
      ),
      error = function(e) NULL
    )

    if (is.null(w)) return(NULL)

    rp <- as.numeric(coredata(R) %*% w)

    df_w <- as.data.frame(t(w), check.names = FALSE)

    data.frame(
      punto          = i,
      retorno_diario = mean(rp),
      vol_diaria     = sd(rp),
      var_diaria     = var(rp)
    ) %>%
      bind_cols(df_w)
  })

  bind_rows(res) %>% arrange(vol_diaria)
}


select_markowitz_weights <- function(train, w_max,
                                     include_crypto = FALSE,
                                     crypto_cap = 0.15,
                                     n_points = 15) {

  front <- build_frontier_markowitz(
    R = train,
    w_max = w_max,
    include_crypto = include_crypto,
    crypto_cap = crypto_cap,
    n_points = n_points
  )

  if (nrow(front) == 0) {
    return(
      solve_markowitz_qp(
        R = train,
        w_max = w_max,
        include_crypto = include_crypto,
        crypto_cap = crypto_cap
      )
    )
  }

  rf_d <- mean(as.numeric(train[, "BIL"]), na.rm = TRUE)
  if (!is.finite(rf_d)) rf_d <- 0

  front <- front %>%
    mutate(
      Sharpe_diario = ifelse(
        vol_diaria > 0,
        (retorno_diario - rf_d) / vol_diaria,
        NA_real_
      )
    ) %>%
    filter(is.finite(Sharpe_diario))

  if (nrow(front) == 0) {
    return(
      solve_markowitz_qp(
        R = train,
        w_max = w_max,
        include_crypto = include_crypto,
        crypto_cap = crypto_cap
      )
    )
  }

  best <- front %>%
    slice_max(Sharpe_diario, n = 1, with_ties = FALSE)

  w <- as.numeric(best[1, colnames(train), drop = TRUE])
  setNames(w, colnames(train))
}


make_markowitz_weights_fun <- function(w_max,
                                       include_crypto = FALSE,
                                       crypto_cap = 0.15,
                                       n_points = 15) {

  force(w_max)
  force(include_crypto)
  force(crypto_cap)
  force(n_points)

  function(train) {
    select_markowitz_weights(
      train = train,
      w_max = w_max,
      include_crypto = include_crypto,
      crypto_cap = crypto_cap,
      n_points = n_points
    )
  }
}


summarise_backtest <- function(bt, label) {

  dates <- index(bt$serie)
  rf_bt <- mean(as.numeric(rf_serie[dates]), na.rm = TRUE)
  if (!is.finite(rf_bt)) rf_bt <- 0

  m <- metricas_oos(
    bt$serie,
    rf_d = rf_bt,
    alpha = alpha_es,
    nombre = label
  )

  m$turnover_promedio_pct <- if (nrow(bt$tabla) > 1) {
    round(mean(bt$tabla$turnover[-1], na.rm = TRUE) * 100, 2)
  } else {
    NA_real_
  }

  m$costos_totales_usd <- round(sum(bt$tabla$costo_operacion, na.rm = TRUE), 2)
  m$capital_final_usd  <- round(last(bt$tabla$capital_fin), 2)

  m
}


md_table <- function(df) {

  vals <- lapply(df, function(x) {
    if (is.numeric(x)) format(round(x, 4), trim = TRUE, scientific = FALSE)
    else as.character(x)
  })
  df2 <- as.data.frame(vals, stringsAsFactors = FALSE)

  header <- paste0("| ", paste(names(df2), collapse = " | "), " |")
  sep    <- paste0("| ", paste(rep("---", ncol(df2)), collapse = " | "), " |")

  rows <- apply(df2, 1, function(x) {
    paste0("| ", paste(x, collapse = " | "), " |")
  })

  c(header, sep, rows)
}


# =========================================================
# 1) IN-SAMPLE MARKOWITZ FRONTIERS
# =========================================================

cat("\nBuilding Markowitz frontier WITH crypto...\n")
front_mv_c <- build_frontier_markowitz(
  R = R_all,
  w_max = w_max_base,
  include_crypto = TRUE,
  crypto_cap = crypto_cap_total,
  n_points = n_points
)

cat("Building Markowitz frontier WITHOUT crypto...\n")
front_mv_sc <- build_frontier_markowitz(
  R = R_sin_cripto,
  w_max = w_max_base[tickers_sin_cripto],
  include_crypto = FALSE,
  crypto_cap = crypto_cap_total,
  n_points = n_points
)

front_mv_all <- bind_rows(
  front_mv_c %>% mutate(universo = "Con cripto"),
  front_mv_sc %>% mutate(universo = "Sin cripto")
) %>%
  mutate(
    retorno_anual_equiv_pct = retorno_diario * scale_ret * 100,
    vol_anual_pct           = vol_diaria * sqrt(scale_ret) * 100,
    Sharpe_diario           = (retorno_diario - rf_daily) / vol_diaria
  )

best_mv_c <- front_mv_all %>%
  filter(universo == "Con cripto") %>%
  slice_max(Sharpe_diario, n = 1, with_ties = FALSE)

best_mv_sc <- front_mv_all %>%
  filter(universo == "Sin cripto") %>%
  slice_max(Sharpe_diario, n = 1, with_ties = FALSE)

# ---------------------------------------------------------
# Markowitz efficient frontier plot
# ---------------------------------------------------------

p_mv_front <- ggplot(
  front_mv_all,
  aes(x = vol_anual_pct, y = retorno_anual_equiv_pct, color = universo)
) +
  geom_line(linewidth = 1.2) +
  geom_point(size = 2) +
  geom_point(
    data = bind_rows(best_mv_c, best_mv_sc),
    aes(x = vol_anual_pct, y = retorno_anual_equiv_pct),
    shape = 18, size = 5, show.legend = FALSE
  ) +
  labs(
    title = "Frontera eficiente Markowitz",
    subtitle = "Volatilidad anualizada y retorno medio anualizado. Diamante = máximo Sharpe in-sample.",
    x = "Volatilidad anualizada (%)",
    y = "Retorno medio anualizado (%)",
    color = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )

ggsave(
  file.path("output", "figures", "frontera_markowitz.png"),
  p_mv_front,
  width = 9, height = 6, dpi = 300
)

# ---------------------------------------------------------
# In-sample selected weights: Mean-CVaR vs Markowitz
# ---------------------------------------------------------

extract_selected_weights <- function(row, assets, framework, universe) {
  data.frame(
    Activo = assets,
    Peso_pct = as.numeric(row[1, assets, drop = TRUE]) * 100,
    Framework = framework,
    Universo = universe,
    stringsAsFactors = FALSE
  )
}

weights_models <- bind_rows(
  extract_selected_weights(mejor_c, tickers, "Mean-CVaR", "Con cripto"),
  extract_selected_weights(mejor_sc, tickers_sin_cripto, "Mean-CVaR", "Sin cripto"),
  extract_selected_weights(best_mv_c, tickers, "Markowitz", "Con cripto"),
  extract_selected_weights(best_mv_sc, tickers_sin_cripto, "Markowitz", "Sin cripto")
)

p_weights_models <- ggplot(
  weights_models,
  aes(x = reorder(Activo, -Peso_pct), y = Peso_pct, fill = Activo)
) +
  geom_col(show.legend = FALSE) +
  facet_grid(Framework ~ Universo, scales = "free_x") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.08))) +
  labs(
    title = "Pesos seleccionados in-sample: Mean-CVaR vs Markowitz",
    x = NULL,
    y = "Peso (%)"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    plot.title.position = "plot"
  )

ggsave(
  file.path("output", "figures", "pesos_modelos_in_sample.png"),
  p_weights_models,
  width = 12, height = 7, dpi = 300
)


# =========================================================
# 2) MARKOWITZ ROLLING OOS
# =========================================================

cat("\nRunning Markowitz OOS WITH crypto...\n")
bt_mv_con_full <- backtest_oos(
  R = R_all,
  w_max = w_max_base,
  include_crypto = TRUE,
  crypto_cap = crypto_cap_total,
  capital_inicial = capital_para_invertir,
  comision = comision_compra,
  window_train = window_train,
  rebalance_freq = rebalance_freq,
  alpha_es = alpha_es,
  n_points = 15,
  max_turnover = max_turnover,
  max_dd_limit = max_dd_limit,
  weights_fun = make_markowitz_weights_fun(
    w_max = w_max_base,
    include_crypto = TRUE,
    crypto_cap = crypto_cap_total,
    n_points = 15
  ),
  validar = TRUE,
  etiqueta = "Markowitz con cripto"
)

cat("Running Markowitz OOS WITHOUT crypto...\n")
bt_mv_sin_full <- backtest_oos(
  R = R_sin_cripto,
  w_max = w_max_base[tickers_sin_cripto],
  include_crypto = FALSE,
  crypto_cap = NULL,
  capital_inicial = capital_para_invertir,
  comision = comision_compra,
  window_train = window_train,
  rebalance_freq = rebalance_freq,
  alpha_es = alpha_es,
  n_points = 15,
  max_turnover = max_turnover,
  max_dd_limit = max_dd_limit,
  weights_fun = make_markowitz_weights_fun(
    w_max = w_max_base[tickers_sin_cripto],
    include_crypto = FALSE,
    crypto_cap = crypto_cap_total,
    n_points = 15
  ),
  validar = TRUE,
  etiqueta = "Markowitz sin cripto"
)


# =========================================================
# 3) SIX-STRATEGY COMPARISON
# =========================================================

comparison_bts <- list(
  bt_con_full,
  bt_sin_full,
  bt_mv_con_full,
  bt_mv_sin_full,
  bt_1n_con_full,
  bt_1n_sin_full
)

comparison_labels <- c(
  "Mean-CVaR con cripto",
  "Mean-CVaR sin cripto",
  "Markowitz con cripto",
  "Markowitz sin cripto",
  "1/N con cripto",
  "1/N sin cripto"
)

comparison_metrics <- map2_dfr(
  comparison_bts,
  comparison_labels,
  summarise_backtest
) %>%
  mutate(
    framework = case_when(
      grepl("^Mean-CVaR", estrategia) ~ "Mean-CVaR",
      grepl("^Markowitz", estrategia) ~ "Markowitz",
      TRUE ~ "1/N"
    ),
    universo = ifelse(grepl("sin cripto", estrategia), "Sin cripto", "Con cripto")
  ) %>%
  mutate(across(where(is.numeric), \(x) round(x, 4)))

comparison_summary <- comparison_metrics %>%
  select(
    estrategia,
    CAGR_pct,
    vol_anual_pct,
    Sharpe_anual,
    Sortino_anual,
    CVaR95_diario_pct,
    STARR_diario,
    max_drawdown_pct,
    Calmar,
    turnover_promedio_pct,
    costos_totales_usd,
    capital_final_usd
  )

cat("\n========== MODEL COMPARISON — OOS ==========\n")
print(as.data.frame(comparison_summary))


# =========================================================
# 4) COMPARISON FIGURES
# =========================================================

curves_models <- map2_dfr(
  comparison_bts,
  comparison_labels,
  ~ curva_capital(.x$serie, .y, capital_para_invertir)
) %>%
  mutate(indice_riqueza = capital / capital_para_invertir * 100)

p_models_wealth <- ggplot(
  curves_models,
  aes(x = fecha, y = indice_riqueza, color = estrategia)
) +
  geom_line(linewidth = 0.85) +
  labs(
    title = "Comparación out-of-sample: Mean-CVaR, Markowitz y 1/N",
    subtitle = "Índice de riqueza base 100; serie diaria neta de costos y con control de turnover",
    x = NULL,
    y = "Índice de riqueza (base = 100)",
    color = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )

ggsave(
  file.path("output", "figures", "comparacion_modelos_capital.png"),
  p_models_wealth,
  width = 11, height = 7, dpi = 300
)

p_risk_return <- ggplot(
  comparison_metrics,
  aes(
    x = max_drawdown_pct,
    y = CAGR_pct,
    color = framework,
    shape = universo,
    label = estrategia
  )
) +
  geom_point(size = 4) +
  geom_text(
    vjust = -0.8,
    size = 3,
    check_overlap = TRUE,
    show.legend = FALSE
  ) +
  labs(
    title = "Retorno vs. drawdown — comparación de estrategias",
    subtitle = "Más arriba = mayor CAGR; más a la izquierda = menor maximum drawdown",
    x = "Maximum drawdown (%)",
    y = "CAGR (%)",
    color = "Framework",
    shape = "Universo"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )

ggsave(
  file.path("output", "figures", "comparacion_riesgo_retorno.png"),
  p_risk_return,
  width = 10, height = 6, dpi = 300
)


# =========================================================
# 5) EXPORT TABLES
# =========================================================

exportar(front_mv_all, "frontera_markowitz.csv")
exportar(weights_models, "pesos_markowitz_in_sample.csv")
exportar(comparison_metrics, "comparacion_modelos_oos.csv")


# =========================================================
# 6) AUTO-GENERATED MARKDOWN SUMMARY
# =========================================================

summary_for_md <- comparison_summary %>%
  transmute(
    Strategy = estrategia,
    CAGR = paste0(round(CAGR_pct, 2), "%"),
    Volatility = paste0(round(vol_anual_pct, 2), "%"),
    Sharpe = round(Sharpe_anual, 3),
    Sortino = round(Sortino_anual, 3),
    `Daily CVaR 95%` = paste0(round(CVaR95_diario_pct, 3), "%"),
    STARR = round(STARR_diario, 4),
    `Max Drawdown` = paste0(round(max_drawdown_pct, 2), "%"),
    Calmar = round(Calmar, 3)
  )

get_row <- function(name) {
  comparison_metrics %>% filter(estrategia == name) %>% slice(1)
}

mc_c  <- get_row("Mean-CVaR con cripto")
mv_c  <- get_row("Markowitz con cripto")
mc_sc <- get_row("Mean-CVaR sin cripto")
mv_sc <- get_row("Markowitz sin cripto")

pct <- function(x) paste0(round(x, 2), "%")
num <- function(x, d = 3) format(round(x, d), nsmall = d)

comparison_lines <- c(
  "# Mean-CVaR vs. Markowitz — Generated Results",
  "",
  "This file is generated automatically by `model_comparison.R` from the actual out-of-sample run.",
  "",
  "## Full OOS Comparison",
  "",
  md_table(summary_for_md),
  "",
  "## Direct Model Comparison — Crypto Universe",
  "",
  paste0(
    "- Mean-CVaR CAGR: **", pct(mc_c$CAGR_pct),
    "** vs. Markowitz: **", pct(mv_c$CAGR_pct), "**."
  ),
  paste0(
    "- Mean-CVaR Sharpe: **", num(mc_c$Sharpe_anual),
    "** vs. Markowitz: **", num(mv_c$Sharpe_anual), "**."
  ),
  paste0(
    "- Mean-CVaR daily CVaR 95%: **", pct(mc_c$CVaR95_diario_pct),
    "** vs. Markowitz: **", pct(mv_c$CVaR95_diario_pct), "**."
  ),
  paste0(
    "- Mean-CVaR maximum drawdown: **", pct(mc_c$max_drawdown_pct),
    "** vs. Markowitz: **", pct(mv_c$max_drawdown_pct), "**."
  ),
  "",
  "## Direct Model Comparison — Traditional Universe",
  "",
  paste0(
    "- Mean-CVaR CAGR: **", pct(mc_sc$CAGR_pct),
    "** vs. Markowitz: **", pct(mv_sc$CAGR_pct), "**."
  ),
  paste0(
    "- Mean-CVaR Sharpe: **", num(mc_sc$Sharpe_anual),
    "** vs. Markowitz: **", num(mv_sc$Sharpe_anual), "**."
  ),
  paste0(
    "- Mean-CVaR daily CVaR 95%: **", pct(mc_sc$CVaR95_diario_pct),
    "** vs. Markowitz: **", pct(mv_sc$CVaR95_diario_pct), "**."
  ),
  paste0(
    "- Mean-CVaR maximum drawdown: **", pct(mc_sc$max_drawdown_pct),
    "** vs. Markowitz: **", pct(mv_sc$max_drawdown_pct), "**."
  ),
  "",
  "## Interpretation Guide",
  "",
  "The comparison should not be reduced to which strategy has the highest CAGR.",
  "",
  "- If Markowitz achieves higher return but materially worse CVaR or drawdown, the result suggests that variance-based optimization accepted more tail risk.",
  "- If Mean-CVaR achieves better STARR or similar return with lower CVaR, this supports the economic value of explicitly modeling tail losses.",
  "- If both models produce similar results without crypto but diverge after crypto is introduced, the risk measure becomes more economically important in the presence of heavy-tailed assets.",
  "- If Markowitz and Mean-CVaR remain similar even with crypto, the empirical evidence would suggest that the choice of risk measure mattered less than the constraints and opportunity set in this sample.",
  "",
  "These results should be interpreted as historical OOS evidence rather than proof of persistent future superiority of either model."
)

writeLines(
  comparison_lines,
  file.path("output", "model_comparison_summary.md"),
  useBytes = TRUE
)

cat("\nModel comparison completed.\n")
cat("Generated:\n")
cat("  output/tables/comparacion_modelos_oos.csv\n")
cat("  output/tables/frontera_markowitz.csv\n")
cat("  output/tables/pesos_markowitz_in_sample.csv\n")
cat("  output/figures/frontera_markowitz.png\n")
cat("  output/figures/pesos_modelos_in_sample.png\n")
cat("  output/figures/comparacion_modelos_capital.png\n")
cat("  output/figures/comparacion_riesgo_retorno.png\n")
cat("  output/model_comparison_summary.md\n")
