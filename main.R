# =========================================================
# PORTAFOLIO MEAN CVAR - SCRIPT AUTOCONTENIDO
# =========================================================
# Optimización Mean-CVaR con y sin criptomonedas, asignación
# de capital con comisiones, backtest out-of-sample con costos
# de transacción y control de turnover, benchmark 1/N,
# portafolio accionable y métricas de riesgo.
#
# El historial de correcciones metodológicas está en CHANGELOG.md.
#
# ADVERTENCIA METODOLOGICA: la sección 5 (asignación según la
# frontera in-sample) usa TODA la muestra histórica para elegir
# el portafolio, por lo que sus métricas están infladas por
# construcción. La evaluación honesta es el backtest
# out-of-sample de las secciones 7-8. Esto es un ejercicio
# académico, no asesoramiento de inversión.
#
# CONVENCIONES
#  - Retornos ARITMETICOS (P_t/P_{t-1} - 1): el retorno del portafolio
#    es combinación lineal de retornos aritméticos, no de log-retornos.
#  - El RIESGO se reporta en frecuencia DIARIA. No se escala el ES por
#    sqrt(252): esa regla supone retornos i.i.d. y aproximadamente
#    normales, y con curtosis ~15 y clustering de volatilidad no se
#    conoce siquiera el signo del error. El RETORNO sí se anualiza
#    (x252), solo para interpretación económica.
#  - El ES se reporta como MAGNITUD POSITIVA de pérdida.
#  - turnover = suma de |Dw|, es decir el notional total transado
#    (compras + ventas). Un cap de 0.80 equivale a 40% one-way.

# =========================================================
# Paquetes
# =========================================================
pkgs <- c("tidyverse", "tidyquant", "xts", "PerformanceAnalytics",
          "PortfolioAnalytics", "ROI", "ROI.plugin.glpk")

faltan <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]

if (length(faltan) > 0) {
  stop("Faltan paquetes. Instalalos con:\n  install.packages(c('",
       paste(faltan, collapse = "', '"), "'))", call. = FALSE)
}

invisible(lapply(pkgs, library, character.only = TRUE))

# =========================================================
# 0) PARAMETROS DEL USUARIO (editar acá)
# =========================================================

# --- Capital y costos (VALORES DE EJEMPLO) ---
capital_inicial <- 1000000   # USD disponibles
costo_bancario  <- 0         # costo fijo de entrada (supuesto: sin transferencia)
comision_compra <- 0.003     # SUPUESTO configurable: 0.3% por operación, del
                             # orden de magnitud de un broker de bajo costo.
                             # No representa el esquema de ningún broker en
                             # particular. Con órdenes grandes el mínimo fijo
                             # por orden (~USD 1) es despreciable; para capitales
                             # chicos (~$100 por orden) el costo efectivo sube a
                             # ~1%: probar 0.005 o más como sensibilidad.

# ¿El broker permite fracciones de ETF?
# TRUE  -> cantidades fraccionarias para todos los activos
# FALSE -> ETFs en unidades enteras (floor), cripto fraccionaria
permitir_fraccionado_etf <- TRUE

# --- Universo de activos ---
tickers <- c(
  "SPY",     # Renta variable EE.UU.
  "EEM",     # Renta variable emergentes
  "AGG",     # Renta fija
  "BIL",     # Liquidez / proxy tasa libre de riesgo
  "VNQ",     # Real Estate
  "GLD",     # Oro
  "DBC",     # Commodities
  "BTC-USD", # Bitcoin
  "ETH-USD"  # Ethereum
)
tickers_sin_cripto <- c("SPY", "EEM", "AGG", "BIL", "VNQ", "GLD", "DBC")
tickers_cripto     <- c("BTC-USD", "ETH-USD")

# --- Límites de pesos ---
# OJO AL INTERPRETAR: con w_max = 0.10 por cripto y cap conjunto de
# 0.15, si el óptimo ubica BTC exactamente en 10.00%, el límite
# individual está ACTIVO mientras el cap conjunto puede permanecer
# holgado. Eso muestra que la solución está condicionada por la
# restricción individual, pero no permite afirmar por sí solo cuál
# sería el peso óptimo de BTC en ausencia de ese límite.
w_max_base <- c(
  SPY       = 0.60,
  EEM       = 0.15,
  AGG       = 0.40,
  BIL       = 0.10,
  VNQ       = 0.15,
  GLD       = 0.15,
  DBC       = 0.15,
  `BTC-USD` = 0.10,   # máximo individual de cada cripto
  `ETH-USD` = 0.10
)
crypto_cap_total <- 0.15    # máximo CONJUNTO BTC+ETH (restricción de grupo)

# --- Período y parámetros de riesgo ---
from_date  <- "2017-11-10"
to_date    <- "2026-08-06"
alpha_es   <- 0.95
n_points   <- 20        # puntos de la frontera eficiente
scale_ret  <- 252       # días hábiles por año (solo anualiza RETORNOS)

# --- Backtest out-of-sample ---
window_train    <- 252      # ventana de entrenamiento (días hábiles)
rebalance_freq  <- 63       # rebalanceo trimestral (~63 días hábiles)
max_turnover    <- 0.80     # rotación máxima por rebalanceo, = suma de |Dw|
max_dd_limit    <- 0.30     # umbral de alerta de drawdown por período

# --- Carpeta de resultados ---
dir.create("output", showWarnings = FALSE)
dir.create(file.path("output", "figures"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("output", "tables"), recursive = TRUE, showWarnings = FALSE)

# El análisis principal es determinístico: depende solo de from_date y
# to_date. La sección accionable usa precios de HOY (Sys.Date()), por
# lo que NO es reproducible: queda desactivada por defecto.
run_live_portfolio <- FALSE

# =========================================================
# 1) CAPITAL DISPONIBLE
# =========================================================

capital_para_invertir <- capital_inicial - costo_bancario
# La comisión se paga sobre el monto operado:
# monto_bruto * (1 + comision) = capital  =>  ajuste conservador
capital_efectivo <- capital_para_invertir / (1 + comision_compra)
comision_entrada <- capital_para_invertir - capital_efectivo

cat("========== RESUMEN DE CAPITAL ==========\n")
cat("Capital inicial:          $", format(round(capital_inicial, 2), big.mark = ","), "\n")
cat("Costo bancario:          -$", format(round(costo_bancario, 2), big.mark = ","), "\n")
cat("Capital para invertir:    $", format(round(capital_para_invertir, 2), big.mark = ","), "\n")
cat("Comisión de entrada:     -$", format(round(comision_entrada, 2), big.mark = ","), "\n")
cat("Capital efectivo neto:    $", format(round(capital_efectivo, 2), big.mark = ","), "\n")
cat("========================================\n\n")

# =========================================================
# 2) FUNCIONES AUXILIARES
# =========================================================

port_mean <- function(R, w) sum(colMeans(R) * w)

# ES con PESOS CONSTANTES: la serie del portafolio es w'r_t, que es
# la cartera que evalúa el optimizador.
# Se devuelve como MAGNITUD POSITIVA de pérdida: ES(..., invert = TRUE)
# devuelve un número negativo, y sin abs() un "ES = -1.2%" se lee como
# ganancia en una tabla, además de que arrange(cvar) ordenaría la
# frontera de mayor a menor riesgo.
port_es <- function(R, w, p = 0.95) {
  rp <- xts(as.numeric(coredata(R) %*% as.numeric(w)), order.by = index(R))
  abs(as.numeric(ES(R = rp, p = p, method = "historical", invert = TRUE)))
}

# ES modificado (Cornish-Fisher) SOLO como métrica reportada.
# No afecta la optimización: bajo ROI, el problema Mean-ES se
# resuelve como programa lineal sobre escenarios históricos.
port_es_cornish_fisher <- function(R, w, p = 0.95) {
  rp <- xts(as.numeric(coredata(R) %*% as.numeric(w)), order.by = index(R))
  es_mod <- tryCatch(
    abs(as.numeric(ES(R = rp, p = p, method = "modified", invert = TRUE))),
    error = function(e) NA_real_
  )
  if (!is.finite(es_mod)) {
    es_mod <- abs(as.numeric(ES(R = rp, p = p, method = "historical", invert = TRUE)))
  }
  es_mod
}

# STARR en frecuencia DIARIA (consistente con el CVaR diario).
# STARR_anual (con ES escalado por raíz-t) = sqrt(252) * STARR_diario:
# transformación monótona positiva, mismo argmax. Pasar a frecuencia
# diaria corrige la etiqueta, NO la selección de portafolios.
calc_starr <- function(ret_d, cvar_d, rf_d) {
  ifelse(cvar_d == 0, NA_real_, (ret_d - rf_d) / cvar_d)
}

# Frontera eficiente Mean-CVaR (todo en frecuencia diaria).
# include_crypto = TRUE agrega la restricción de grupo BTC+ETH.
build_frontier <- function(R, w_max, include_crypto = FALSE,
                           crypto_cap = 0.15, alpha_es = 0.95, n_points = 20) {

  assets <- colnames(R)
  w_max  <- w_max[assets]
  w_min  <- rep(0, length(assets))

  port <- portfolio.spec(assets = assets) %>%
    add.constraint(type = "full_investment") %>%
    add.constraint(type = "box", min = w_min, max = w_max)

  if (include_crypto) {
    port <- port %>%
      add.constraint(
        type = "group",
        groups = list(
          tradicionales = which(!assets %in% tickers_cripto),
          cripto        = which(assets %in% tickers_cripto)
        ),
        group_min = c(0, 0),
        group_max = c(1, crypto_cap)
      )
  }

  minrisk <- optimize.portfolio(
    R = R,
    portfolio = port %>%
      add.objective(type = "risk", name = "ES", arguments = list(p = alpha_es)),
    optimize_method = "ROI"
  )

  maxret <- optimize.portfolio(
    R = R,
    portfolio = port %>%
      add.objective(type = "return", name = "mean", multiplier = -1),
    optimize_method = "ROI"
  )

  targets <- seq(
    port_mean(R, extractWeights(minrisk)),
    port_mean(R, extractWeights(maxret)),
    length.out = n_points
  )

  res <- lapply(seq_along(targets), function(i) {
    opt <- tryCatch({
      optimize.portfolio(
        R = R,
        portfolio = port %>%
          add.constraint(type = "return", return_target = targets[i]) %>%
          add.objective(type = "risk", name = "ES", arguments = list(p = alpha_es)),
        optimize_method = "ROI"
      )
    }, error = function(e) NULL)

    if (is.null(opt)) return(NULL)
    w <- extractWeights(opt)

    # data.frame con nombres EXACTOS de los activos (evita que
    # BTC-USD se convierta en BTC.USD y rompa selecciones)
    df_w <- as.data.frame(t(w))
    colnames(df_w) <- names(w)

    data.frame(
      punto          = i,
      retorno_diario = port_mean(R, w),
      cvar_diario    = port_es(R, w, p = alpha_es)   # magnitud positiva
    ) %>% bind_cols(df_w)
  })

  # cvar_diario positivo => ascendente = de menor a mayor riesgo
  bind_rows(res) %>% arrange(cvar_diario)
}

# Cap de turnover.
# Si el turnover propuesto excede el máximo, se toma la combinación
# convexa entre la cartera anterior y la nueva: ambas suman 1, y toda
# combinación convexa de carteras factibles también lo es, así que NO
# hace falta renormalizar.
# En el primer rebalanceo no hay cartera previa: se invierte completo
# y el "turnover" es la compra inicial (= 1).
aplicar_cap_turnover <- function(w_old, w_new, max_to, primer_rebalanceo = FALSE) {

  turnover <- sum(abs(w_new - w_old))

  if (primer_rebalanceo || turnover <= max_to || turnover == 0) {
    return(list(w = w_new, turnover = turnover, capado = FALSE))
  }

  a <- max_to / turnover          # fracción del movimiento permitida
  w_adj <- w_old + a * (w_new - w_old)

  list(w = w_adj, turnover = sum(abs(w_adj - w_old)), capado = TRUE)
}

# Validación ESTRICTA: se aplica a los pesos OBJETIVO del optimizador.
# Los pesos EJECUTADOS (tras el cap de turnover, que los mezcla con la
# cartera derivada por precios) pueden exceder transitoriamente un
# límite: eso se reporta, no se trata como error.
validar_pesos_vector <- function(w, w_max, crypto_cap = NULL, tol = 1e-4) {
  ok <- TRUE
  if (abs(sum(w) - 1) > tol) { warning("Los pesos no suman 1."); ok <- FALSE }
  if (any(w < -tol)) { warning("Hay pesos negativos."); ok <- FALSE }
  if (any(w > w_max[names(w)] + tol)) {
    warning("Algún activo supera su límite individual."); ok <- FALSE
  }
  if (!is.null(crypto_cap)) {
    tot_c <- sum(w[names(w) %in% tickers_cripto])
    if (tot_c > crypto_cap + tol) {
      warning("BTC+ETH superan el cap conjunto."); ok <- FALSE
    }
  }
  invisible(ok)
}

# ---------------------------------------------------------
# Métricas de performance sobre una serie DIARIA de retornos
# NETA DE COSTOS. CVaR y STARR quedan en frecuencia diaria;
# lo que se anualiza está etiquetado.
# ---------------------------------------------------------
metricas_oos <- function(r, rf_d, alpha = 0.95, ppa = scale_ret,
                         nombre = NA_character_) {

  r  <- na.omit(r)
  rn <- as.numeric(r)
  n  <- length(rn)
  if (n < 2) return(NULL)

  crecimiento <- prod(1 + rn)
  cagr        <- crecimiento^(1 / (n / ppa)) - 1

  mu_d   <- mean(rn)
  sd_d   <- sd(rn)
  dd_d   <- as.numeric(DownsideDeviation(r, MAR = rf_d))
  cvar_d <- abs(as.numeric(ES(r, p = alpha, method = "historical", invert = TRUE)))
  var_d  <- abs(as.numeric(VaR(r, p = alpha, method = "historical", invert = TRUE)))
  maxdd  <- as.numeric(maxDrawdown(r))

  data.frame(
    estrategia        = nombre,
    n_dias            = n,
    ret_acumulado_pct = (crecimiento - 1) * 100,
    CAGR_pct          = cagr * 100,
    vol_anual_pct     = sd_d * sqrt(ppa) * 100,
    Sharpe_anual      = (mu_d - rf_d) / sd_d * sqrt(ppa),
    Sortino_anual     = if (is.finite(dd_d) && dd_d > 0) (mu_d - rf_d) / dd_d * sqrt(ppa) else NA_real_,
    VaR95_diario_pct  = var_d * 100,
    CVaR95_diario_pct = cvar_d * 100,
    STARR_diario      = (mu_d - rf_d) / cvar_d,
    max_drawdown_pct  = maxdd * 100,
    Calmar            = if (maxdd > 0) cagr / maxdd else NA_real_,
    asimetria         = as.numeric(skewness(rn)),
    curtosis_exceso   = as.numeric(kurtosis(rn)),
    stringsAsFactors  = FALSE
  )
}

# Mismas métricas año por año, sobre la serie diaria.
metricas_por_anio <- function(r, rf_serie, alpha = 0.95, ppa = scale_ret) {
  r <- na.omit(r)
  map_dfr(unique(format(index(r), "%Y")), function(a) {
    rr <- r[a]
    if (nrow(rr) < 5) return(NULL)
    rf_a <- mean(as.numeric(rf_serie[index(rr)]), na.rm = TRUE)
    if (!is.finite(rf_a)) rf_a <- 0
    m <- metricas_oos(rr, rf_d = rf_a, alpha = alpha, ppa = ppa, nombre = a)
    if (is.null(m)) return(NULL)
    names(m)[names(m) == "estrategia"] <- "anio"
    m
  })
}

# Curva de capital + drawdown desde la serie diaria
curva_capital <- function(r, nombre, cap0) {
  r <- na.omit(r)
  w <- cap0 * cumprod(1 + as.numeric(r))
  data.frame(fecha = index(r), capital = w,
             drawdown = (w / cummax(w) - 1) * 100,
             estrategia = nombre, stringsAsFactors = FALSE)
}

# =========================================================
# 3) DESCARGA Y PREPARACION DE DATOS
# =========================================================
# ORDEN CORRECTO: primero se alinean los PRECIOS a las fechas
# comunes y recién después se calculan los retornos. Así el
# retorno del lunes de BTC/ETH captura viernes->lunes completo
# (calcular retornos por activo antes de alinear perdería el
# movimiento del fin de semana). Retornos ARITMETICOS.

file_cache <- "data/precios.rds"
dir.create("data", showWarnings = FALSE)

force_download <- FALSE   # TRUE para ignorar el cache y rebajar todo

# El cache guarda los parámetros con los que fue generado. Si no
# coinciden con los actuales, se vuelve a descargar: leer un cache
# viejo tras cambiar tickers o fechas devolvería resultados que no
# corresponden a los parámetros del script, en silencio.
cache_meta <- list(tickers = sort(tickers), from = from_date, to = to_date)

P_all <- NULL

if (!force_download && file.exists(file_cache)) {
  cache <- tryCatch(readRDS(file_cache), error = function(e) NULL)
  if (is.list(cache) && !is.null(cache$meta) && identical(cache$meta, cache_meta)) {
    cat("Leyendo precios desde", file_cache, "\n")
    P_all <- cache$precios
  } else {
    cat("El cache no coincide con los parámetros actuales: se rebaja.\n")
  }
}

if (is.null(P_all)) {
  cat("Descargando precios de Yahoo Finance...\n")

  precios_raw <- tq_get(tickers, from = from_date, to = to_date,
                        get = "stock.prices")

  precios_wide <- precios_raw %>%
    select(date, symbol, adjusted) %>%
    pivot_wider(names_from = symbol, values_from = adjusted)

  P_all <- xts(precios_wide[, -1], order.by = precios_wide$date)
  P_all <- na.omit(P_all)

  saveRDS(list(meta = cache_meta, precios = P_all), file_cache)
  cat("Precios guardados en", file_cache, "\n")
}

P_all <- P_all[, tickers]

R_all <- P_all / lag.xts(P_all) - 1
R_all <- na.omit(R_all)

R_sin_cripto <- R_all[, tickers_sin_cripto]

cat("Período de datos:\n")
cat("Desde:", format(start(R_all)), "| Hasta:", format(end(R_all)), "\n")
cat("Observaciones:", nrow(R_all), "\n\n")

# =========================================================
# 4) FRONTERAS EFICIENTES + STARR (frecuencia diaria)
# =========================================================

cat("Optimizando frontera CON cripto...\n")
front_c <- build_frontier(
  R = R_all, w_max = w_max_base,
  include_crypto = TRUE, crypto_cap = crypto_cap_total,
  alpha_es = alpha_es, n_points = n_points
)

cat("Optimizando frontera SIN cripto...\n")
front_sc <- build_frontier(
  R = R_sin_cripto, w_max = w_max_base[tickers_sin_cripto],
  include_crypto = FALSE,
  alpha_es = alpha_es, n_points = n_points
)

# Tasa libre de riesgo (proxy: BIL). Se guarda la SERIE, no solo el
# promedio: las métricas anuales usan la rf de cada año.
rf_serie  <- R_all[, "BIL"]
rf_daily  <- mean(as.numeric(rf_serie), na.rm = TRUE)
rf_annual <- rf_daily * scale_ret
cat("\nTasa libre de riesgo anual (proxy BIL):",
    round(rf_annual * 100, 2), "%\n\n")

tabla_final <- bind_rows(
  front_c  %>% mutate(modelo = "Con cripto"),
  front_sc %>% mutate(modelo = "Sin cripto")
) %>%
  mutate(
    # Métricas de decisión: TODAS en frecuencia diaria
    retorno_diario_pct      = retorno_diario * 100,
    cvar_diario_pct         = cvar_diario * 100,
    STARR_diario            = calc_starr(retorno_diario, cvar_diario, rf_daily),
    # Solo para interpretación económica (NO se usa para elegir)
    retorno_anual_equiv_pct = retorno_diario * scale_ret * 100
  )

# Portafolios de máximo STARR (IN-SAMPLE: ver advertencia inicial).
# with_ties = FALSE: si dos puntos de la frontera empatan en STARR,
# slice_max devolvería ambas filas y duplicaría los prints y el
# diamante del gráfico.
mejor_c  <- tabla_final %>% filter(modelo == "Con cripto") %>%
  slice_max(STARR_diario, n = 1, with_ties = FALSE)
mejor_sc <- tabla_final %>% filter(modelo == "Sin cripto") %>%
  slice_max(STARR_diario, n = 1, with_ties = FALSE)

# =========================================================
# 5) ASIGNACION DE CAPITAL (frontera in-sample, ilustrativa)
# =========================================================

calcular_asignacion <- function(mejor_fila, activos, capital) {
  pesos <- as.numeric(unlist(mejor_fila[1, activos, drop = TRUE]))
  names(pesos) <- activos

  monto_bruto <- pesos * capital / (1 + comision_compra)
  comision    <- monto_bruto * comision_compra

  data.frame(
    Activo          = activos,
    Peso_pct        = round(pesos * 100, 2),
    Monto_a_operar  = round(monto_bruto, 2),
    Comision_USD    = round(comision, 2),
    Total_con_comis = round(monto_bruto + comision, 2)
  )
}

asig_c  <- calcular_asignacion(mejor_c, tickers, capital_para_invertir)
asig_sc <- calcular_asignacion(mejor_sc, tickers_sin_cripto, capital_para_invertir)

imprimir_optimo <- function(mejor, asig, titulo) {
  cat("\n=====", titulo, "=====\n")
  cat("Retorno diario esperado:", round(mejor$retorno_diario_pct, 4), "%\n")
  cat("  (equivalente anual x252:", round(mejor$retorno_anual_equiv_pct, 2), "%)\n")
  cat("CVaR 95% diario:        ", round(mejor$cvar_diario_pct, 4), "%\n")
  cat("STARR diario:           ", round(mejor$STARR_diario, 4), "\n\n")
  print(asig)
  cat("Comisiones: $", round(sum(asig$Comision_USD), 2),
      "| Total: $", round(sum(asig$Total_con_comis), 2), "\n")
}

imprimir_optimo(mejor_c,  asig_c,  "PORTAFOLIO OPTIMO CON CRIPTO (in-sample)")
imprimir_optimo(mejor_sc, asig_sc, "PORTAFOLIO OPTIMO SIN CRIPTO (in-sample)")

# --- ¿Qué restricción ata la exposición a cripto? ---
w_opt_c     <- setNames(as.numeric(unlist(mejor_c[1, tickers, drop = TRUE])), tickers)
tot_cripto  <- sum(w_opt_c[tickers_cripto])
en_tope_ind <- tickers_cripto[abs(w_opt_c[tickers_cripto] - w_max_base[tickers_cripto]) < 1e-4]

cat("\n--- Diagnóstico de restricciones sobre cripto (in-sample) ---\n")
cat("BTC+ETH:", round(tot_cripto * 100, 2), "% de un cap conjunto de",
    crypto_cap_total * 100, "%\n")
if (length(en_tope_ind) > 0) {
  cat("En su tope INDIVIDUAL:", paste(en_tope_ind, collapse = ", "), "\n")
  cat("=> El límite individual se encuentra activo, mientras que el cap conjunto\n")
  cat("   puede permanecer holgado. Por lo tanto, la exposición total observada\n")
  cat("   está condicionada por la restricción individual y no puede atribuirse\n")
  cat("   exclusivamente a beneficios marginales decrecientes.\n")
} else {
  cat("=> Ningún cripto se encuentra en su tope individual. En este caso existe\n")
  cat("   mayor evidencia compatible con beneficios marginales decrecientes.\n")
}

# =========================================================
# 6) GRAFICOS: FRONTERA Y PESOS
# =========================================================
# Eje X: CVaR 95% DIARIO, sin escalar por sqrt(252).
# Eje Y: retorno medio anualizado (x252) solo para interpretación.
# La selección del portafolio sigue usando STARR en frecuencia diaria.

p_frontera <- ggplot(
  tabla_final,
  aes(x = cvar_diario_pct, y = retorno_anual_equiv_pct, color = modelo)
) +
  geom_line(linewidth = 1.2) +
  geom_point(size = 2) +
  geom_point(
    data = bind_rows(mejor_c, mejor_sc),
    aes(x = cvar_diario_pct, y = retorno_anual_equiv_pct),
    shape = 18, size = 5, show.legend = FALSE
  ) +
  labs(
    title    = "Frontera eficiente Mean-CVaR",
    subtitle = paste0(
      "CVaR histórico diario al 95% (magnitud positiva de pérdida); ",
      "retorno medio anualizado (x252). Diamante = máximo STARR in-sample."
    ),
    x = "CVaR 95% diario — pérdida (%)",
    y = "Retorno medio anualizado (%)",
    color = "Modelo"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )
print(p_frontera)
ggsave(file.path("output", "figures", "frontera_eficiente.png"), p_frontera,
       width = 9, height = 6, dpi = 300)

pesos_plot <- bind_rows(
  asig_c  %>% mutate(modelo = "Con cripto"),
  asig_sc %>% mutate(modelo = "Sin cripto")
)

p_pesos <- ggplot(pesos_plot,
                  aes(x = reorder(Activo, -Peso_pct), y = Peso_pct, fill = Activo)) +
  geom_col(width = 0.6, show.legend = FALSE) +
  geom_text(aes(label = paste0(Peso_pct, "%")), vjust = -0.5, size = 3.5) +
  facet_wrap(~ modelo, scales = "free_x") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.10))) +
  labs(
    title = "Peso de cada activo en el portafolio óptimo (in-sample)",
    x = "Activo", y = "Peso (%)"
  ) +
  theme_minimal(base_size = 13) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))
print(p_pesos)
ggsave(file.path("output", "figures", "pesos_optimos.png"), p_pesos,
       width = 11, height = 6, dpi = 300)

# =========================================================
# 7) BACKTEST OUT-OF-SAMPLE CON COSTOS Y TURNOVER
# =========================================================
# En cada rebalanceo: entrena con los últimos 'window_train' días,
# elige el portafolio de máximo STARR diario de la frontera (decisión
# tomada SOLO con información pasada), aplica el cap de turnover
# contra los pesos derivados de la cartera previa, imputa el costo el
# día del rebalanceo y evalúa en el trimestre siguiente.
#
# IMPORTANTE: los límites individuales y de grupo se imponen sobre los
# pesos OBJETIVO de cada rebalanceo. Si el cap de turnover impide llegar
# completamente al target, los pesos EJECUTADOS pueden desviarse de forma
# transitoria de esos límites. Esa desviación se reporta explícitamente.

backtest_oos <- function(R, w_max, include_crypto, crypto_cap,
                         capital_inicial, comision = 0.003,
                         window_train = 252, rebalance_freq = 63,
                         alpha_es = 0.95, n_points = 15,
                         max_turnover = 0.80, max_dd_limit = 0.30,
                         ppa = scale_ret,
                         weights_fun = NULL, validar = TRUE,
                         etiqueta = "estrategia") {

  # geometric = TRUE permite trabajar con una trayectoria patrimonial
  # encadenada multiplicativamente. verbose = TRUE devuelve BOP/EOP
  # weights, que se usan para medir el turnover contra la cartera
  # DERIVADA por precios, no contra el objetivo del rebalanceo anterior.
  #
  # El costo se imputa DENTRO de la serie diaria (día 1 del período):
  # restarlo aparte del capital deja el drawdown, el Sharpe y el CVaR
  # brutos de comisiones.
  #
  # Se guardan los pesos OBJETIVO (pre-cap) además de los EJECUTADOS:
  # para recomendarle una cartera a alguien que arranca de cero sirve
  # el objetivo, no la mezcla convexa arrastrada.
  #
  # weights_fun = NULL -> Mean-CVaR; f(train) -> regla fija (1/N).

  assets <- colnames(R)
  fechas <- index(R)
  resultados <- list()
  serie_oos  <- list()

  w_old <- setNames(rep(0, length(assets)), assets)
  primera_vez <- TRUE
  capital <- capital_inicial

  for (i in seq(window_train, nrow(R) - rebalance_freq, by = rebalance_freq)) {

    train <- R[(i - window_train + 1):i, ]
    test  <- R[(i + 1):(i + rebalance_freq), ]

    rf_d_train <- mean(as.numeric(train[, "BIL"]), na.rm = TRUE)

    # ---- 1) pesos objetivo ----
    # Si el optimizador falla NO se elimina el período: se mantiene la
    # cartera anterior (turnover 0, costo 0) y se registra el estado.
    # Saltar el trimestre con next() borraría un período OOS de la
    # historia sin dejar rastro, y el capital saltaría sin explicación.
    solver_status <- "OK"

    if (is.null(weights_fun)) {

      frontera <- tryCatch(
        build_frontier(R = train, w_max = w_max,
                       include_crypto = include_crypto, crypto_cap = crypto_cap,
                       alpha_es = alpha_es, n_points = n_points),
        error = function(e) {
          warning("build_frontier falló en ", format(fechas[i]), ": ",
                  conditionMessage(e), call. = FALSE)
          NULL
        }
      )

      if (is.null(frontera) || nrow(frontera) == 0) {
        solver_status <- "FAILED"
      } else {
        tabla_bt <- frontera %>%
          mutate(STARR_diario = calc_starr(retorno_diario, cvar_diario, rf_d_train)) %>%
          filter(!is.na(STARR_diario), is.finite(STARR_diario))

        if (nrow(tabla_bt) == 0) {
          solver_status <- "NO_STARR"
        } else {
          mejor <- tabla_bt %>% slice_max(STARR_diario, n = 1, with_ties = FALSE)
          w_obj <- setNames(as.numeric(mejor[1, assets]), assets)
        }
      }

      if (solver_status != "OK") {
        if (primera_vez) {
          stop("El optimizador falló en el PRIMER rebalanceo (", format(fechas[i]),
               "): no hay cartera previa que mantener.", call. = FALSE)
        }
        warning("Rebalanceo ", format(fechas[i]), ": ", solver_status,
                ". Se mantiene la cartera anterior.", call. = FALSE)
        w_obj <- w_old
      }

    } else {
      w_obj <- weights_fun(train)[assets]
    }

    if (validar && solver_status == "OK") {
      validar_pesos_vector(w_obj, w_max,
                           crypto_cap = if (include_crypto) crypto_cap else NULL)
    }

    # ---- 2) cap de turnover contra los pesos DERIVADOS ----
    cap_res  <- aplicar_cap_turnover(w_old, w_obj, max_turnover,
                                     primer_rebalanceo = primera_vez)
    w_exec   <- cap_res$w
    turnover <- cap_res$turnover

    # ---- 3) evaluación OOS con drift intra-trimestre ----
    rp <- Return.portfolio(R = test, weights = w_exec,
                           geometric = TRUE, verbose = TRUE)
    ret_test <- rp$returns
    colnames(ret_test) <- "portfolio"

    # ---- 4) costo DENTRO de la serie ----
    factor_costo    <- 1 - turnover * comision
    costo_operacion <- capital * turnover * comision

    ret_net <- ret_test
    ret_net[1, 1] <- (1 + as.numeric(ret_test[1, 1])) * factor_costo - 1

    capital_fin_periodo <- capital * prod(1 + as.numeric(ret_net))

    w_eop <- setNames(as.numeric(coredata(last(rp$EOP.Weight))), assets)
    w_eop <- w_eop / sum(w_eop)

    serie_oos[[length(serie_oos) + 1]] <- ret_net

    # ---- 5) métricas del período (serie NETA) ----
    dd_periodo   <- as.numeric(maxDrawdown(ret_net))
    ret_periodo  <- prod(1 + as.numeric(ret_net)) - 1
    vol_periodo  <- sd(as.numeric(ret_net)) * sqrt(ppa)
    cvar_periodo <- tryCatch(
      abs(as.numeric(ES(ret_net, p = alpha_es, method = "historical",
                        invert = TRUE))),
      error = function(e) NA_real_
    )

    df_exec <- as.data.frame(t(w_exec)); colnames(df_exec) <- assets
    df_obj  <- as.data.frame(t(w_obj));  colnames(df_obj)  <- paste0("obj_", assets)

    resultados[[length(resultados) + 1]] <- data.frame(
      estrategia            = etiqueta,
      fecha_rebalanceo      = as.Date(fechas[i]),
      fecha_fin             = as.Date(last(index(test))),
      solver_status         = solver_status,
      capital_inicio        = round(capital, 2),
      capital_fin           = round(capital_fin_periodo, 2),
      costo_operacion       = round(costo_operacion, 2),
      turnover              = round(turnover, 4),
      turnover_capado       = cap_res$capado,
      retorno_periodo_pct   = round(ret_periodo * 100, 2),
      volatilidad_anual_pct = round(vol_periodo * 100, 2),
      cvar95_diario_pct     = round(cvar_periodo * 100, 3),
      drawdown_periodo_pct  = round(dd_periodo * 100, 2),
      alerta_drawdown       = ifelse(dd_periodo > max_dd_limit, "ALERTA", "OK"),
      cripto_objetivo_pct   = round(sum(w_obj[names(w_obj) %in% tickers_cripto]) * 100, 2),
      cripto_ejecutada_pct  = round(sum(w_exec[names(w_exec) %in% tickers_cripto]) * 100, 2),
      stringsAsFactors      = FALSE
    ) %>% bind_cols(df_exec) %>% bind_cols(df_obj)

    capital     <- capital_fin_periodo
    w_old       <- w_eop
    primera_vez <- FALSE
  }

  list(tabla = bind_rows(resultados), serie = do.call(rbind, serie_oos))
}

# --- regla ingenua 1/N (DeMiguel, Garlappi & Uppal, 2009) ---
pesos_equiponderados <- function(train) {
  a <- colnames(train)
  setNames(rep(1 / length(a), length(a)), a)
}

cat("\n[1/4] Mean-CVaR CON cripto...\n")
bt_con_full <- backtest_oos(
  R = R_all, w_max = w_max_base,
  include_crypto = TRUE, crypto_cap = crypto_cap_total,
  capital_inicial = capital_para_invertir, comision = comision_compra,
  window_train = window_train, rebalance_freq = rebalance_freq,
  alpha_es = alpha_es, n_points = 15,
  max_turnover = max_turnover, max_dd_limit = max_dd_limit,
  etiqueta = "Mean-CVaR con cripto"
)

cat("[2/4] Mean-CVaR SIN cripto...\n")
bt_sin_full <- backtest_oos(
  R = R_sin_cripto, w_max = w_max_base[tickers_sin_cripto],
  include_crypto = FALSE, crypto_cap = NULL,
  capital_inicial = capital_para_invertir, comision = comision_compra,
  window_train = window_train, rebalance_freq = rebalance_freq,
  alpha_es = alpha_es, n_points = 15,
  max_turnover = max_turnover, max_dd_limit = max_dd_limit,
  etiqueta = "Mean-CVaR sin cripto"
)

# NOTA para el texto: 1/N sobre 9 activos implica ~22% en cripto, por
# encima del cap de 15% que se le impone al optimizador. Es el
# benchmark estándar y se reporta tal cual, pero NO es una cartera
# factible bajo las restricciones del problema: aclararlo al citarlo.
cat("[3/4] Benchmark 1/N CON cripto...\n")
bt_1n_con_full <- backtest_oos(
  R = R_all, w_max = w_max_base,
  include_crypto = TRUE, crypto_cap = crypto_cap_total,
  capital_inicial = capital_para_invertir, comision = comision_compra,
  window_train = window_train, rebalance_freq = rebalance_freq,
  alpha_es = alpha_es, max_turnover = max_turnover, max_dd_limit = max_dd_limit,
  weights_fun = pesos_equiponderados, validar = FALSE,
  etiqueta = "1/N con cripto"
)

cat("[4/4] Benchmark 1/N SIN cripto...\n")
bt_1n_sin_full <- backtest_oos(
  R = R_sin_cripto, w_max = w_max_base[tickers_sin_cripto],
  include_crypto = FALSE, crypto_cap = NULL,
  capital_inicial = capital_para_invertir, comision = comision_compra,
  window_train = window_train, rebalance_freq = rebalance_freq,
  alpha_es = alpha_es, max_turnover = max_turnover, max_dd_limit = max_dd_limit,
  weights_fun = pesos_equiponderados, validar = FALSE,
  etiqueta = "1/N sin cripto"
)

bt_con    <- bt_con_full$tabla
bt_sin    <- bt_sin_full$tabla
serie_con <- bt_con_full$serie
serie_sin <- bt_sin_full$serie

lista_bt   <- list(bt_con_full, bt_sin_full, bt_1n_con_full, bt_1n_sin_full)
nombres_bt <- c("Mean-CVaR con cripto", "Mean-CVaR sin cripto",
                "1/N con cripto", "1/N sin cripto")

# Ningún período OOS debe haberse resuelto con la cartera anterior
cat("\nEstado del optimizador por rebalanceo:\n")
print(table(bt_con$solver_status))

# =========================================================
# 8) COMPARACION OOS: METRICAS AJUSTADAS POR RIESGO
# =========================================================
# Todas las métricas salen de la SERIE DIARIA neta de costos, no de
# los retornos trimestrales.

fechas_oos <- index(serie_con)
rf_d_oos   <- mean(as.numeric(rf_serie[fechas_oos]), na.rm = TRUE)

tabla_oos <- map2_dfr(lista_bt, nombres_bt, function(bt, nom) {

  # RF alineada a las fechas efectivamente presentes en cada estrategia.
  fechas_bt <- index(bt$serie)
  rf_bt <- mean(as.numeric(rf_serie[fechas_bt]), na.rm = TRUE)
  if (!is.finite(rf_bt)) rf_bt <- 0

  m <- metricas_oos(bt$serie, rf_d = rf_bt, alpha = alpha_es, nombre = nom)

  # El primer turnover (= 1) corresponde al despliegue inicial de capital,
  # no a un rebalanceo. Se excluye del promedio reportado, pero sus costos
  # sí permanecen incluidos en costos_totales_usd.
  m$turnover_promedio_pct <- if (nrow(bt$tabla) > 1) {
    round(mean(bt$tabla$turnover[-1], na.rm = TRUE) * 100, 2)
  } else {
    NA_real_
  }

  m$costos_totales_usd <- round(sum(bt$tabla$costo_operacion, na.rm = TRUE), 2)
  m$capital_final_usd  <- round(last(bt$tabla$capital_fin), 2)
  m
}) %>%
  mutate(across(where(is.numeric), \(x) round(x, 4)))

tabla_oos_texto <- tabla_oos %>%
  select(estrategia, CAGR_pct, vol_anual_pct, Sharpe_anual, Sortino_anual,
         CVaR95_diario_pct, STARR_diario, max_drawdown_pct, Calmar,
         turnover_promedio_pct, costos_totales_usd, capital_final_usd)

cat("\n========== METRICAS OOS (serie diaria, neta de costos) ==========\n")
cat("Ventana:", format(min(fechas_oos)), "a", format(max(fechas_oos)),
    "|", length(fechas_oos), "días | rf diaria:", round(rf_d_oos * 100, 4), "%\n\n")
print(as.data.frame(tabla_oos_texto))

cat("\n--- Tabla completa (transpuesta, para el anexo) ---\n")
print(as.data.frame(t(tabla_oos)))

cat("\nADVERTENCIA INFERENCIAL:\n")
cat("Las diferencias observadas en las métricas ajustadas por riesgo deben\n")
cat("interpretarse con cautela dada la longitud limitada de la muestra OOS\n")
cat("y la existencia de un único path histórico. Establecer significancia\n")
cat("estadística requeriría un procedimiento inferencial específico, como\n")
cat("un bootstrap por bloques.\n")

# ---------------------------------------------------------
# SANITY CHECKS DEL BACKTEST
# ---------------------------------------------------------
# 1) Los períodos deben estar ordenados y sin fechas duplicadas.
# 2) El capital reconstruido desde la serie diaria debe reconciliar
#    con el capital final reportado por el backtest.
# 3) Los pesos OBJETIVO deben sumar 1.
# 4) Salvo la compra inicial, el turnover ejecutado no puede exceder
#    el cap configurado (tolerancia por redondeo a 4 decimales).
validar_backtest <- function(bt, nombre, capital0, max_to, tol_capital = 1) {

  if (is.null(bt$serie) || NROW(bt$serie) == 0 || nrow(bt$tabla) == 0) {
    stop(nombre, ": backtest vacío.", call. = FALSE)
  }

  idx <- index(bt$serie)
  idx_num <- as.numeric(idx)
  if (anyDuplicated(idx) > 0 || any(diff(idx_num) <= 0)) {
    stop(nombre, ": la serie OOS tiene fechas duplicadas o desordenadas.", call. = FALSE)
  }

  cap_serie <- capital0 * prod(1 + as.numeric(bt$serie))
  cap_tabla <- as.numeric(last(bt$tabla$capital_fin))
  if (!is.finite(cap_serie) || abs(cap_serie - cap_tabla) > tol_capital) {
    stop(nombre, ": el capital de la serie y el de la tabla no reconcilian.", call. = FALSE)
  }

  obj_cols <- grep("^obj_", names(bt$tabla), value = TRUE)
  if (length(obj_cols) > 0) {
    suma_obj <- rowSums(bt$tabla[, obj_cols, drop = FALSE])
    if (any(abs(suma_obj - 1) > 1e-4)) {
      stop(nombre, ": hay pesos objetivo que no suman 1.", call. = FALSE)
    }
  }

  if (nrow(bt$tabla) > 1) {
    to_rebalances <- bt$tabla$turnover[-1]
    if (any(to_rebalances > max_to + 1e-4, na.rm = TRUE)) {
      stop(nombre, ": se excedió el cap de turnover.", call. = FALSE)
    }
  }

  invisible(TRUE)
}

walk2(lista_bt, nombres_bt, ~ validar_backtest(
  bt = .x,
  nombre = .y,
  capital0 = capital_para_invertir,
  max_to = max_turnover
))

# Los dos modelos Mean-CVaR deben haber resuelto todos los rebalanceos.
if (!all(bt_con$solver_status == "OK")) {
  warning("Mean-CVaR con cripto tuvo rebalanceos sin solución óptima.", call. = FALSE)
}
if (!all(bt_sin$solver_status == "OK")) {
  warning("Mean-CVaR sin cripto tuvo rebalanceos sin solución óptima.", call. = FALSE)
}

cat("\nSanity checks del backtest: OK\n")

curvas <- map2_dfr(lista_bt, nombres_bt,
                   ~ curva_capital(.x$serie, .y, capital_para_invertir)) %>%
  mutate(
    # Base 100 facilita la comparación entre estrategias y evita que el
    # gráfico dependa del capital inicial elegido para el ejercicio.
    indice_riqueza = capital / capital_para_invertir * 100
  )

# ---------------------------------------------------------
# Evolución acumulada OOS
# ---------------------------------------------------------
p_bt <- ggplot(curvas, aes(x = fecha, y = indice_riqueza, color = estrategia)) +
  geom_line(linewidth = 1) +
  labs(
    title = "Backtest out-of-sample: Mean-CVaR vs. benchmark 1/N",
    subtitle = "Índice de riqueza base 100; serie diaria neta de costos y con control de turnover",
    x = NULL,
    y = "Índice de riqueza (base = 100)",
    color = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )
print(p_bt)
ggsave(file.path("output", "figures", "backtest_capital.png"), p_bt,
       width = 10, height = 6, dpi = 300)

# ---------------------------------------------------------
# Drawdown OOS — figura principal de tesis
# ---------------------------------------------------------
# Para evitar una figura excesivamente cargada, el gráfico principal
# compara únicamente las dos estrategias Mean-CVaR. El drawdown se
# calcula sobre la serie OOS COMPLETA: el máximo histórico no se
# reinicia en cada rebalanceo trimestral.
curvas_dd_mcv <- curvas %>%
  filter(estrategia %in% c("Mean-CVaR con cripto", "Mean-CVaR sin cripto"))

p_dd <- ggplot(curvas_dd_mcv,
               aes(x = fecha, y = drawdown, color = estrategia)) +
  geom_hline(yintercept = 0, linewidth = 0.4, color = "grey45") +
  geom_line(linewidth = 0.95) +
  labs(
    title = "Drawdown out-of-sample — Mean-CVaR",
    subtitle = paste0(
      "Serie diaria neta de costos. El máximo histórico se mantiene ",
      "entre rebalanceos trimestrales."
    ),
    x = NULL,
    y = "Drawdown (%)",
    color = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )
print(p_dd)
ggsave(file.path("output", "figures", "backtest_drawdown.png"), p_dd,
       width = 10, height = 6, dpi = 300)

# Versión completa con los benchmarks, útil para anexo o diagnóstico.
p_dd_all <- ggplot(curvas, aes(x = fecha, y = drawdown, color = estrategia)) +
  geom_hline(yintercept = 0, linewidth = 0.4, color = "grey45") +
  geom_line(linewidth = 0.75) +
  labs(
    title = "Drawdown out-of-sample — todas las estrategias",
    subtitle = "Serie diaria neta de costos; drawdown continuo entre rebalanceos",
    x = NULL,
    y = "Drawdown (%)",
    color = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )
ggsave(file.path("output", "figures", "backtest_drawdown_todas.png"), p_dd_all,
       width = 10, height = 6, dpi = 300)

# =========================================================
# 9) PORTAFOLIO ACCIONABLE (último objetivo del backtest)
# =========================================================
# Cantidades a comprar hoy. NO es reproducible: usa precios de la
# fecha de ejecución. Desactivado por defecto.

# Pesos OBJETIVO (pre-cap de turnover): quien arranca de cero no tiene
# cartera previa con la cual promediar, compra el target directamente.
cols_obj      <- paste0("obj_", tickers)
ultimo_peso   <- bt_con %>% slice_tail(n = 1) %>% select(all_of(cols_obj))
pesos_finales <- setNames(as.numeric(ultimo_peso), tickers)

if (sum(pesos_finales[tickers_cripto]) < 1e-6) {
  cat("\nNOTA: la asignación vigente al cierre de la muestra no incluye cripto.\n")
  cat("No es un error: la última ventana de entrenamiento no la seleccionó.\n")
  cat("Conviene anticiparlo en el texto como dependencia de régimen.\n")
}

asignacion_real <- NULL

if (!run_live_portfolio) {

  cat("\n[Seccion 9 omitida: run_live_portfolio = FALSE]\n")

} else {

  precios_actuales <- tryCatch(
    tq_get(tickers, from = Sys.Date() - 10, to = Sys.Date(),
           get = "stock.prices"),
    error = function(e) {
      warning("No se pudieron bajar precios actuales: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(precios_actuales) || nrow(precios_actuales) == 0) {

    cat("\n[Seccion 9 omitida: sin precios actuales disponibles]\n")

  } else {

    precios_actuales <- precios_actuales %>%
      group_by(symbol) %>%
      slice_tail(n = 1) %>%
      ungroup() %>%
      select(symbol, adjusted)

    capital_neto_hoy <- capital_para_invertir / (1 + comision_compra)

    asignacion_real <- data.frame(
      Activo         = tickers,
      Peso_pct       = round(pesos_finales * 100, 2),
      Monto_objetivo = round(pesos_finales * capital_neto_hoy, 2)
    ) %>%
      left_join(precios_actuales, by = c("Activo" = "symbol")) %>%
      mutate(
        Precio_actual   = round(adjusted, 2),
        Es_cripto       = Activo %in% tickers_cripto,
        Cantidad_exacta = Monto_objetivo / adjusted,
        # Con fracciones habilitadas, todo a 6 decimales;
        # si no, ETFs en unidades enteras y cripto fraccionaria.
        Cantidad_sugerida = ifelse(Es_cripto | permitir_fraccionado_etf,
                                   round(Cantidad_exacta, 6),
                                   floor(Cantidad_exacta)),
        Monto_estimado  = round(Cantidad_sugerida * adjusted, 2),
        Comision_est    = round(Monto_estimado * comision_compra, 2)
      ) %>%
      select(Activo, Peso_pct, Monto_objetivo, Precio_actual,
             Cantidad_sugerida, Monto_estimado, Comision_est)

    total_invertido <- sum(asignacion_real$Monto_estimado, na.rm = TRUE)
    total_comision  <- sum(asignacion_real$Comision_est, na.rm = TRUE)
    cash_remanente  <- capital_para_invertir - total_invertido - total_comision

    cat("\n========== PORTAFOLIO ACCIONABLE ==========\n")
    print(asignacion_real)
    cat("Total invertido:  $", round(total_invertido, 2), "\n")
    cat("Total comisiones: $", round(total_comision, 2), "\n")
    cat("Cash remanente:   $", round(cash_remanente, 2),
        ifelse(permitir_fraccionado_etf,
               " (residual por redondeo)\n",
               " (por redondeo a unidades enteras de ETF)\n"))
    cat("===========================================\n")
  }
}

# =========================================================
# 10) PERFORMANCE ANUAL (desde la serie diaria)
# =========================================================
# Antes: sd(retorno_trimestral) * sqrt(4), o sea 4 observaciones por
# año, y drawdown máximo trimestral que no podía cruzar el corte de
# calendario. Ahora: ~252 observaciones por año y drawdown continuo.

performance_anual <- map2_dfr(lista_bt, nombres_bt, function(bt, nom) {
  metricas_por_anio(bt$serie, rf_serie = rf_serie, alpha = alpha_es) %>%
    mutate(estrategia = nom)
}) %>%
  select(estrategia, anio, n_dias, ret_acumulado_pct, vol_anual_pct,
         Sharpe_anual, Sortino_anual, CVaR95_diario_pct, max_drawdown_pct) %>%
  mutate(across(where(is.numeric), \(x) round(x, 3)))

cat("\n========== PERFORMANCE ANUAL (serie diaria OOS) ==========\n")
print(as.data.frame(performance_anual))
cat("\nNota: el primer y el último año pueden ser parciales (ver n_dias).\n")

datos_anual_plot <- performance_anual %>%
  filter(estrategia %in% c("Mean-CVaR con cripto", "Mean-CVaR sin cripto")) %>%
  group_by(anio) %>%
  mutate(
    # Un año con claramente menos observaciones que un año bursátil completo
    # se marca como parcial. Esto identifica, en particular, los extremos
    # de la muestra OOS sin hardcodear fechas.
    anio_parcial = max(n_dias, na.rm = TRUE) < 200,
    anio_etiqueta = if_else(anio_parcial, paste0(anio, "*"), as.character(anio))
  ) %>%
  ungroup() %>%
  mutate(anio_etiqueta = factor(anio_etiqueta,
                                levels = unique(anio_etiqueta[order(as.integer(anio))])))

p_anual <- ggplot(
  datos_anual_plot,
  aes(x = anio_etiqueta, y = ret_acumulado_pct, fill = estrategia)
) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  geom_hline(yintercept = 0, linewidth = 0.4) +
  labs(
    title = "Retorno anual out-of-sample — Mean-CVaR",
    subtitle = "Serie diaria neta de costos. * Período anual parcial.",
    x = NULL,
    y = "Retorno acumulado del año (%)",
    fill = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    legend.position = "bottom",
    plot.title.position = "plot"
  )
print(p_anual)
ggsave(file.path("output", "figures", "performance_anual.png"), p_anual,
       width = 10, height = 5.5, dpi = 300)

# =========================================================
# 11) DISTRIBUCION DE RETORNOS Y METRICAS DE RIESGO (OOS)
# =========================================================
# La distribución y las métricas de riesgo se calculan sobre la serie
# DIARIA OOS neta de costos, no sobre los últimos pesos aplicados a
# toda la muestra (eso sería in-sample).

ret_gauss <- data.frame(retorno = as.numeric(serie_con)) %>% na.omit()
media_ret <- mean(ret_gauss$retorno)
sd_ret    <- sd(ret_gauss$retorno)
var_emp   <- as.numeric(quantile(ret_gauss$retorno, 1 - alpha_es))

p_gauss <- ggplot(ret_gauss, aes(x = retorno)) +
  geom_histogram(aes(y = after_stat(density)), bins = 60,
                 fill = "steelblue", alpha = 0.60) +
  stat_function(
    fun = dnorm,
    args = list(mean = media_ret, sd = sd_ret),
    color = "red",
    linewidth = 1.2
  ) +
  # Media diaria observada.
  geom_vline(xintercept = media_ret, linetype = "dashed", linewidth = 1) +
  # Cuantil empírico del 5%: VaR histórico al 95% expresado en retorno.
  geom_vline(xintercept = var_emp, linetype = "dotted", linewidth = 0.9) +
  scale_x_continuous(labels = scales::label_percent(accuracy = 0.1)) +
  labs(
    title = "Distribución de retornos OOS — Mean-CVaR con cripto",
    subtitle = paste0(
      "Histograma diario vs. normal teórica con igual media y desvío. ",
      "Discontinua = media; punteada = VaR histórico 95%."
    ),
    x = "Retorno diario",
    y = "Densidad"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title.position = "plot")
print(p_gauss)
ggsave(file.path("output", "figures", "distribucion_retornos.png"), p_gauss,
       width = 9, height = 6, dpi = 300)

cat("\n========== ESTADISTICAS DE LA SERIE OOS ==========\n")
print(table.Stats(serie_con))

es_hist <- abs(as.numeric(ES(serie_con, p = alpha_es,
                             method = "historical", invert = TRUE)))
es_cf   <- tryCatch(
  abs(as.numeric(ES(serie_con, p = alpha_es, method = "modified", invert = TRUE))),
  error = function(e) NA_real_
)

cat("\nES histórico vs. Cornish-Fisher (diario, ", alpha_es * 100, "%):\n", sep = "")
cat("  Histórico:      ", round(es_hist * 100, 3), "%\n")
cat("  Cornish-Fisher: ", round(es_cf * 100, 3), "%\n")
cat("  Brecha CF/Hist: ", round(es_cf / es_hist, 2), "x\n")
cat("  => Esta brecha, junto con la curtosis y la asimetría de arriba, es el\n")
cat("     argumento empírico para (a) usar CVaR en vez de varianza y (b) no\n")
cat("     escalar el ES por sqrt(252).\n")

spy_oos   <- R_all[fechas_oos, "SPY"]
beta_port <- CAPM.beta(serie_con, spy_oos)
cor_port  <- cor(as.numeric(serie_con), as.numeric(spy_oos))

cat("\nBeta vs. SPY (OOS):        ", round(as.numeric(beta_port), 4), "\n")
cat("Correlación vs. SPY (OOS): ", round(cor_port, 4), "\n")
cat("  => Beta baja con correlación alta: el portafolio diversifica MAGNITUD,\n")
cat("     no DIRECCION. Sigue siendo esencialmente renta variable desapalancada.\n")

cat("\n========== DOWNSIDE RISK (serie OOS) ==========\n")
print(table.DownsideRisk(serie_con,
                         Rf  = round(rf_d_oos, 6),
                         MAR = round(rf_d_oos, 6),
                         p   = alpha_es))

# =========================================================
# 12) EXPORTACION
# =========================================================
# CSV portable: coma como separador y UTF-8 explícito.
# (write.csv2 usa ";" y coma decimal: cómodo en Excel en español,
# incómodo para cualquier otro lector del repo.)

exportar <- function(x, nombre) {
  if (is.null(x) || nrow(x) == 0) return(invisible(NULL))
  write.csv(x, file.path("output", "tables", nombre),
            row.names = FALSE, fileEncoding = "UTF-8")
}

series_todas <- do.call(merge, map(lista_bt, ~ .x$serie))
colnames(series_todas) <- nombres_bt
df_series <- data.frame(fecha = index(series_todas),
                        coredata(series_todas), check.names = FALSE)

periodos_todos <- bind_rows(map(lista_bt, ~ .x$tabla))

exportar(tabla_final,       "frontera_eficiente.csv")
exportar(asig_c,            "asignacion_con_cripto.csv")
exportar(asig_sc,           "asignacion_sin_cripto.csv")
exportar(periodos_todos,    "backtest_periodos.csv")
exportar(tabla_oos,         "metricas_oos.csv")
exportar(tabla_oos_texto,   "metricas_oos_resumen.csv")
exportar(performance_anual, "performance_anual.csv")
exportar(asignacion_real,   "portafolio_accionable.csv")
exportar(df_series,         "series_diarias_oos.csv")

cat("\nArchivos exportados a output/tables y output/figures:\n")
cat("  frontera_eficiente.csv, asignacion_con/sin_cripto.csv,\n")
cat("  backtest_periodos.csv, metricas_oos(.resumen).csv,\n")
cat("  performance_anual.csv, portafolio_accionable.csv,\n")
cat("  series_diarias_oos.csv + 6 gráficos PNG\n")

writeLines(capture.output(sessionInfo()), "output/session_info.txt")
cat("Entorno de ejecución guardado en output/session_info.txt\n")

cat("\nProceso finalizado correctamente.\n")
