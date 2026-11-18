{{ config(materialized='view') }}

/*
«Портфель на дату»: одна строка на дату среза.
Использование:  select * from dm.v_portfolio_on_date where snapshot_date = '2026-06-30';
Фильтр по snapshot_date — колонке группировки — Postgres опускает ниже агрегации,
поэтому читаются только строки нужной даты (индекс по snapshot_date, loan_id).

  loans_count          — кредиты, выданные не позже даты среза (включая погашенные);
  active_loans_count   — кредиты с ненулевым остатком;
  total_debt_balance   — общий остаток;
  balance_bucket_*     — распределение остатка по бакетам просрочки (+ количество кредитов и доля).
*/

select
    snapshot_date,
    count(*)                                              as loans_count,
    count(*) filter (where debt_balance > 0)              as active_loans_count,
    sum(debt_balance)                                     as total_debt_balance,
    sum(overdue_amount)                                   as total_overdue_amount,

    sum(debt_balance) filter (where overdue_bucket = '0')     as balance_bucket_0,
    sum(debt_balance) filter (where overdue_bucket = '1-30')  as balance_bucket_1_30,
    sum(debt_balance) filter (where overdue_bucket = '31-60') as balance_bucket_31_60,
    sum(debt_balance) filter (where overdue_bucket = '61-90') as balance_bucket_61_90,
    sum(debt_balance) filter (where overdue_bucket = '90+')   as balance_bucket_90_plus,

    count(*) filter (where debt_balance > 0 and overdue_bucket = '0')     as loans_bucket_0,
    count(*) filter (where overdue_bucket = '1-30')                       as loans_bucket_1_30,
    count(*) filter (where overdue_bucket = '31-60')                      as loans_bucket_31_60,
    count(*) filter (where overdue_bucket = '61-90')                      as loans_bucket_61_90,
    count(*) filter (where overdue_bucket = '90+')                        as loans_bucket_90_plus,

    round(100.0 * sum(debt_balance) filter (where overdue_bucket <> '0')
          / nullif(sum(debt_balance), 0), 2)              as overdue_balance_share_pct
from {{ ref('dm_loan_snapshot_daily') }}
group by snapshot_date
