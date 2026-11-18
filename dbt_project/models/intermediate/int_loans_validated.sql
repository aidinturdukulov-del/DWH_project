{{ config(materialized='table') }}

/*
Кредиты, обогащённые заявкой и агрегатами графика.
Кредиты по отклонённым заявкам (is_rejected_app_anomaly) НЕ исключаются:
деньги фактически выданы, долг существует и должен быть в портфеле. Они помечены
флагом и учитываются в воронке отдельной колонкой.
*/

with loans as (
    select * from {{ ref('stg_loans') }}
),

apps as (
    select * from {{ ref('stg_applications') }}
),

schedule_agg as (
    select
        loan_id,
        count(*)        as planned_payments_count,
        min(due_date)   as first_due_date,
        max(due_date)   as last_due_date,
        sum(due_amount) as total_schedule_amount
    from {{ ref('stg_schedule') }}
    group by loan_id
)

select
    l.loan_id,
    l.app_id,
    a.client_id,
    l.issued_at,
    l.issued_month,
    l.principal,
    l.term_months,
    l.rate,
    a.status                               as app_status,
    coalesce(a.status = 'rejected', false) as is_rejected_app_anomaly,
    a.created_at                           as app_created_at,
    a.decided_at                           as app_decided_at,
    s.planned_payments_count,
    s.first_due_date,
    s.last_due_date,
    coalesce(s.total_schedule_amount, 0)   as total_schedule_amount
from loans l
left join apps a         on a.app_id  = l.app_id
left join schedule_agg s on s.loan_id = l.loan_id
