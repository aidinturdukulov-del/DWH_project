-- Инициализация хранилища. Скрипт идемпотентен: можно выполнять повторно,
-- существующие данные не удаляются (полный сброс — ingest/load.py --reset).

CREATE SCHEMA IF NOT EXISTS raw;     -- данные источника «как есть» + технические поля загрузки
CREATE SCHEMA IF NOT EXISTS etl;     -- журнал загрузок
-- staging / core / dm / dq создаёт dbt

-- Журнал загрузок: одна строка на (запуск, таблица)
CREATE TABLE IF NOT EXISTS etl.load_log (
    load_id        BIGSERIAL PRIMARY KEY,
    step           SMALLINT    NOT NULL,          -- 1 или 2
    cutoff_date    DATE        NOT NULL,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at    TIMESTAMPTZ,
    rows_in_batch  JSONB,                          -- сколько строк попало в пачку шага
    rows_inserted  JSONB                           -- сколько из них реально новые
);

-- Первичные ключи нужны для идемпотентности (INSERT ... ON CONFLICT DO NOTHING).
-- В исходных данных дублей ключей нет — это проверяется в dq (сверка количества строк с CSV).

CREATE TABLE IF NOT EXISTS raw.applications (
    app_id      BIGINT PRIMARY KEY,
    client_id   BIGINT,
    created_at  TIMESTAMP,
    amount      NUMERIC(14,2),
    status      TEXT,          -- new / approved / rejected
    decided_at  TIMESTAMP,     -- пусто для status = new
    _load_id    BIGINT NOT NULL REFERENCES etl.load_log (load_id)
);

CREATE TABLE IF NOT EXISTS raw.loans (
    loan_id      BIGINT PRIMARY KEY,
    app_id       BIGINT,
    issued_at    DATE,
    principal    NUMERIC(14,2),
    term_months  INT,
    rate         NUMERIC(5,2),
    _load_id     BIGINT NOT NULL REFERENCES etl.load_log (load_id)
);

CREATE TABLE IF NOT EXISTS raw.schedule (
    loan_id     BIGINT,
    due_date    DATE,
    due_amount  NUMERIC(14,2),
    _load_id    BIGINT NOT NULL REFERENCES etl.load_log (load_id),
    PRIMARY KEY (loan_id, due_date)
);

CREATE TABLE IF NOT EXISTS raw.payments (
    payment_id  BIGINT PRIMARY KEY,
    loan_id     BIGINT,
    paid_at     DATE,
    amount      NUMERIC(14,2),
    loaded_at   DATE,
    _load_id    BIGINT NOT NULL REFERENCES etl.load_log (load_id)
);

CREATE INDEX IF NOT EXISTS ix_raw_payments_load_id ON raw.payments (_load_id);
