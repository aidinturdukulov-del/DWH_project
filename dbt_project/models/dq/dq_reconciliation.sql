{{ config(materialized='table') }}

/*
Сверка итогов витрин с исходными таблицами. Одна строка — одна проверка.
passed = (abs(diff) <= tolerance). Тест tests/assert_reconciliation_passed.sql падает,
если хотя бы одна проверка не прошла.
*/

with
raw_apps   as (select count(*) as cnt from {{ source('raw', 'applications') }}),
raw_loans  as (select count(*) as cnt, sum(principal) as amt from {{ source('raw', 'loans') }}),
raw_sched  as (select sum(due_amount) as amt from {{ source('raw', 'schedule') }}),
raw_pay    as (select count(*) as cnt, sum(amount) as amt from {{ source('raw', 'payments') }}),
clean_pay  as (select count(*) as cnt, sum(amount) as amt, max(loaded_at) as as_of_date
               from {{ ref('int_payments_clean') }}),
excl_pay   as (select count(*) as cnt, coalesce(sum(amount), 0) as amt
               from {{ ref('dq_source_anomalies') }}
               where source_table = 'payments' and severity = 'excluded'),
funnel     as (select sum(applications_count) as apps, sum(issued_loans_count) as loans,
                      sum(issued_amount) as amt
               from {{ ref('dm_application_funnel') }}),
loans_v    as (select sum(total_schedule_amount) as sched_amt from {{ ref('int_loans_validated') }}),
snap       as (select * from {{ ref('dm_loan_snapshot_daily') }}),
snap_last  as (
    select count(*) as loans,
           sum(l.total_schedule_amount - s.debt_balance) as repaid
    from snap s
    join {{ ref('int_loans_validated') }} l using (loan_id)
    where s.snapshot_date = (select as_of_date from clean_pay)
),
snap_rows  as (
    select (select count(*) from snap) as actual,
           (select sum((select as_of_date from clean_pay) - issued_at + 1)
              from {{ ref('int_loans_validated') }}) as expected
),
portfolio  as (
    select total_debt_balance, loans_count
    from {{ ref('v_portfolio_on_date') }}
    where snapshot_date = (select as_of_date from clean_pay)
),
snap_total as (select sum(debt_balance) as bal from snap
               where snapshot_date = (select as_of_date from clean_pay)),

checks (check_name, description, expected, actual, tolerance) as (
    select 'funnel_applications_count', 'Заявок в воронке = заявок в raw.applications',
           (select cnt from raw_apps)::numeric, (select apps from funnel)::numeric, 0::numeric
    union all
    select 'funnel_loans_count', 'Выдач в воронке = строк в raw.loans',
           (select cnt from raw_loans), (select loans from funnel), 0
    union all
    select 'funnel_issued_amount', 'Сумма выдач в воронке = sum(principal) в raw.loans',
           (select amt from raw_loans), (select amt from funnel), 0.01
    union all
    select 'core_schedule_amount', 'Сумма графиков в core = sum(due_amount) в raw.schedule',
           (select amt from raw_sched), (select sched_amt from loans_v), 0.01
    union all
    select 'payments_count_balance', 'Платежей в raw = очищенные + исключённые (dq)',
           (select cnt from raw_pay), (select cnt from clean_pay) + (select cnt from excl_pay), 0
    union all
    select 'payments_amount_balance', 'Сумма платежей в raw = очищенные + исключённые (dq)',
           (select amt from raw_pay), (select amt from clean_pay) + (select amt from excl_pay), 0.01
    union all
    select 'snapshot_repaid_vs_payments', 'Погашено по снимку на as_of (график - остаток) = сумма очищенных платежей',
           (select amt from clean_pay), (select repaid from snap_last), 0.01
    union all
    select 'snapshot_loans_on_as_of', 'Кредитов в снимке на as_of = строк в raw.loans',
           (select cnt from raw_loans), (select loans from snap_last), 0
    union all
    select 'snapshot_row_count', 'Строк в снимке = сумма (as_of - issued_at + 1) по кредитам',
           (select expected from snap_rows), (select actual from snap_rows), 0
    union all
    select 'portfolio_view_balance', 'Остаток в v_portfolio_on_date = сумма остатков снимка на as_of',
           (select bal from snap_total), (select total_debt_balance from portfolio), 0.01
)

select
    check_name,
    description,
    expected,
    actual,
    actual - expected                                   as diff,
    coalesce(abs(actual - expected) <= tolerance, false) as passed,
    now()                                               as checked_at
from checks
