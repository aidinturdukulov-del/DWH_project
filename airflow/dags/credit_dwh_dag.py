"""
DAG credit_dwh: загрузка -> core -> снимки и витрины -> проверки качества.

  load_raw          python ingest/load.py --step N (идемпотентно, одна транзакция)
  build_core        dbt build: staging + intermediate (+ тесты источников)
  build_marts       dbt build: витрины и инкрементальный loan_snapshot_daily
  dq_checks         dbt build: dq-модели (реестр аномалий, сверка) + singular-тесты;
                    падение сверки роняет DAG

Шаг загрузки передаётся параметром запуска (по умолчанию 2 — «ежедневная» догрузка):
  airflow dags trigger credit_dwh --conf '{"step": 1}'

Ожидается, что код проекта смонтирован в PROJECT_DIR, а переменные DB_HOST/DB_PORT/
DB_USER/DB_PASSWORD/DB_NAME заданы в окружении воркера (или через Connection + env).
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.models.param import Param
from airflow.operators.bash import BashOperator

PROJECT_DIR = os.getenv("CREDIT_DWH_PROJECT_DIR", "/opt/airflow/credit_dwh")
# cautious: тест запускается, только если выбраны все модели, на которые он ссылается
DBT = f"cd {PROJECT_DIR}/dbt_project && DBT_PROFILES_DIR=. dbt"
CAUTIOUS = "--indirect-selection cautious"

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="credit_dwh",
    description="Мини-DWH кредитного портфеля: загрузка, снимки, проверки качества",
    start_date=datetime(2026, 9, 30),
    schedule="@daily",
    catchup=False,
    max_active_runs=1,  # инкремент снимков не должен выполняться параллельно сам с собой
    default_args=default_args,
    params={"step": Param(2, type="integer", enum=[1, 2], description="Шаг загрузки")},
    tags=["credit", "dwh", "dbt"],
) as dag:

    load_raw = BashOperator(
        task_id="load_raw",
        bash_command=f"python {PROJECT_DIR}/ingest/load.py --step {{{{ params.step }}}}",
    )

    build_core = BashOperator(
        task_id="build_core",
        bash_command=f"{DBT} build {CAUTIOUS} --select path:models/staging path:models/intermediate",
    )

    build_marts = BashOperator(
        task_id="build_marts",
        bash_command=f"{DBT} build {CAUTIOUS} --select path:models/marts",
    )

    dq_checks = BashOperator(
        task_id="dq_checks",
        bash_command=f"{DBT} build --select path:models/dq path:tests",
    )

    load_raw >> build_core >> build_marts >> dq_checks
