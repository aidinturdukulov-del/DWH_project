#!/usr/bin/env bash
# Полный прогон с нуля: сброс -> шаг 1 -> dbt build -> шаг 2 -> dbt build -> выгрузка результатов.
# Работает и в контейнере dbt (docker compose exec dbt bash scripts/run_pipeline.sh),
# и локально (нужны DB_HOST/DB_PORT/... и установленный requirements.txt).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python}"
export DBT_PROFILES_DIR="$ROOT/dbt_project"

step() { echo; echo "=== $*"; }

step "Сброс хранилища"
"$PY" "$ROOT/ingest/load.py" --reset

for s in 1 2; do
  step "Загрузка, шаг $s"
  "$PY" "$ROOT/ingest/load.py" --step "$s"
  step "dbt build после шага $s"
  (cd "$ROOT/dbt_project" && dbt build --quiet)
done

step "Выгрузка результатов"
"$ROOT/scripts/export_results.sh"
