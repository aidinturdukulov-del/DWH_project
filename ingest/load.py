#!/usr/bin/env python3
"""
Загрузка CSV в слой raw в два шага, имитирующих ежедневную работу.

  Шаг 1 — данные, известные на CUTOFF (30.09.2026):
          заявки с created_at <= CUTOFF, кредиты с issued_at <= CUTOFF,
          график по этим кредитам, платежи с loaded_at <= CUTOFF.
  Шаг 2 — всё остальное (строки, не попавшие в шаг 1).

Идемпотентность:
  * у raw-таблиц есть первичные ключи, вставка идёт через
    INSERT ... ON CONFLICT DO NOTHING — повторный запуск любого шага
    (в том числе шага 1 после шага 2) ничего не удаляет и не дублирует;
  * каждый шаг выполняется в одной транзакции: либо загружено всё, либо ничего;
  * шаг 2 читает только строки, не входящие в шаг 1 (дельту), а не весь набор.

Каждая вставленная строка получает _load_id из etl.load_log. По нему dbt
понимает, какие платежи пришли после предыдущего расчёта снимков.

Использование:
  python ingest/load.py --step 1
  python ingest/load.py --step 2
  python ingest/load.py --reset          # удалить raw/etl и витрины, начать с нуля
"""

import argparse
import io
import json
import os
import sys
from pathlib import Path

import pandas as pd
import psycopg2

CUTOFF = pd.Timestamp("2026-09-30")

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.getenv("DATA_DIR", BASE_DIR / "credit_dwh_test_data"))
INIT_SQL = Path(__file__).resolve().parent / "db_init.sql"

TABLES = {
    # таблица: (колонки, ключ)
    "applications": (["app_id", "client_id", "created_at", "amount", "status", "decided_at"], ["app_id"]),
    "loans": (["loan_id", "app_id", "issued_at", "principal", "term_months", "rate"], ["loan_id"]),
    "schedule": (["loan_id", "due_date", "due_amount"], ["loan_id", "due_date"]),
    "payments": (["payment_id", "loan_id", "paid_at", "amount", "loaded_at"], ["payment_id"]),
}


def get_connection():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "5432")),
        user=os.getenv("DB_USER", "postgres"),
        password=os.getenv("DB_PASSWORD", "postgres"),
        dbname=os.getenv("DB_NAME", "credit_dwh"),
    )


def read_sources() -> dict[str, pd.DataFrame]:
    dfs = {name: pd.read_csv(DATA_DIR / f"{name}.csv", dtype=str) for name in TABLES}
    # Даты парсим только для фильтрации; в БД уходят исходные строки, тип приводит Postgres
    dfs["applications"]["_created"] = pd.to_datetime(dfs["applications"]["created_at"])
    dfs["loans"]["_issued"] = pd.to_datetime(dfs["loans"]["issued_at"])
    dfs["payments"]["_loaded"] = pd.to_datetime(dfs["payments"]["loaded_at"])
    return dfs


def split_by_step(dfs: dict[str, pd.DataFrame], step: int) -> dict[str, pd.DataFrame]:
    """Возвращает строки, относящиеся к шагу. Шаг 2 — строгое дополнение шага 1."""
    apps, loans, sched, pmts = (dfs[t] for t in TABLES)

    in_step1 = {
        "applications": apps["_created"].dt.normalize() <= CUTOFF,
        "loans": loans["_issued"] <= CUTOFF,
        "payments": pmts["_loaded"] <= CUTOFF,
    }
    step1_loan_ids = set(loans.loc[in_step1["loans"], "loan_id"])
    in_step1["schedule"] = sched["loan_id"].isin(step1_loan_ids)

    result = {}
    for name, (cols, _) in TABLES.items():
        mask = in_step1[name] if step == 1 else ~in_step1[name]
        result[name] = dfs[name].loc[mask, cols]
    return result


def insert_idempotent(cur, table: str, df: pd.DataFrame, load_id: int) -> int:
    cols, key = TABLES[table]
    if df.empty:
        return 0
    tmp = f"tmp_{table}"
    cur.execute(
        f"CREATE TEMP TABLE {tmp} ON COMMIT DROP AS SELECT {', '.join(cols)} FROM raw.{table} WITH NO DATA"
    )
    buf = io.StringIO()
    df.to_csv(buf, index=False, header=False)
    buf.seek(0)
    cur.copy_expert(f"COPY {tmp} ({', '.join(cols)}) FROM STDIN WITH (FORMAT csv)", buf)
    col_list = ", ".join(cols)
    cur.execute(
        f"""
        INSERT INTO raw.{table} ({col_list}, _load_id)
        SELECT {col_list}, %s FROM {tmp}
        ON CONFLICT ({', '.join(key)}) DO NOTHING
        """,
        (load_id,),
    )
    return cur.rowcount


def reset(conn):
    with conn, conn.cursor() as cur:
        for schema in ("dq", "dm", "core", "staging", "raw", "etl"):
            cur.execute(f"DROP SCHEMA IF EXISTS {schema} CASCADE")
    print("Схемы raw, etl, staging, core, dm, dq удалены.")


def run_step(conn, step: int):
    dfs = split_by_step(read_sources(), step)
    with conn, conn.cursor() as cur:  # одна транзакция на весь шаг
        cur.execute(INIT_SQL.read_text())
        cur.execute(
            "INSERT INTO etl.load_log (step, cutoff_date, rows_in_batch) VALUES (%s, %s, %s) RETURNING load_id",
            (step, CUTOFF.date(), json.dumps({t: len(df) for t, df in dfs.items()})),
        )
        load_id = cur.fetchone()[0]
        inserted = {t: insert_idempotent(cur, t, df, load_id) for t, df in dfs.items()}
        cur.execute(
            "UPDATE etl.load_log SET finished_at = now(), rows_inserted = %s WHERE load_id = %s",
            (json.dumps(inserted), load_id),
        )

    print(f"Шаг {step} (load_id={load_id}, cutoff={CUTOFF.date()}):")
    for t, df in dfs.items():
        print(f"  raw.{t:<13} в пачке {len(df):>6}, вставлено новых {inserted[t]:>6}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--step", type=int, choices=[1, 2])
    group.add_argument("--reset", action="store_true")
    args = parser.parse_args()

    if not DATA_DIR.exists():
        sys.exit(f"Папка с данными не найдена: {DATA_DIR}")

    conn = get_connection()
    try:
        if args.reset:
            reset(conn)
        else:
            run_step(conn, args.step)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
