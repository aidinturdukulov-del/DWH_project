#!/usr/bin/env bash
# Выгружает «портфель на дату» (30.06.2026 и 31.10.2026), сверку и сводку аномалий в results/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/results"

export PGHOST="${DB_HOST:-localhost}" PGPORT="${DB_PORT:-5432}" PGUSER="${DB_USER:-postgres}" \
       PGPASSWORD="${DB_PASSWORD:-postgres}" PGDATABASE="${DB_NAME:-credit_dwh}"

q() { psql -X -v ON_ERROR_STOP=1 --csv -c "$1" > "$ROOT/results/$2"; echo "results/$2"; }

q "select * from dm.v_portfolio_on_date where snapshot_date in ('2026-06-30', '2026-10-31') order by snapshot_date" \
  portfolio_on_date.csv
q "select * from dm.dm_application_funnel order by application_month" application_funnel.csv
q "select check_name, description, expected, actual, diff, passed from dq.dq_reconciliation order by check_name" \
  dq_reconciliation.csv
q "select anomaly_code, severity, source_table, count(*) as rows, sum(amount) as amount
   from dq.dq_source_anomalies group by 1, 2, 3 order by 2, 1" dq_anomalies_summary.csv
q "select * from dq.dq_source_anomalies where severity <> 'info' order by anomaly_code, record_id" \
  dq_anomalies_details.csv
