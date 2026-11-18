-- Исходные таблицы (PostgreSQL). Загрузка: \copy src.applications from 'applications.csv' csv header
create schema if not exists src;

create table src.applications (
    app_id      bigint,
    client_id   bigint,
    created_at  timestamp,
    amount      numeric(14,2),
    status      text,          -- new / approved / rejected
    decided_at  timestamp      -- пусто для status = new
);

create table src.loans (
    loan_id      bigint,
    app_id       bigint,
    issued_at    date,
    principal    numeric(14,2),
    term_months  int,
    rate         numeric(5,2)  -- годовая ставка, %
);

create table src.schedule (
    loan_id     bigint,
    due_date    date,
    due_amount  numeric(14,2)
);

create table src.payments (
    payment_id  bigint,
    loan_id     bigint,
    paid_at     date,          -- дата фактического платежа
    amount      numeric(14,2),
    loaded_at   date           -- дата, когда запись появилась в источнике
);
