{{ config(materialized='table') }}

/*
Воронка заявок по месяцу создания заявки (когорта заявки):
заявка -> одобрение -> выдача.

Допущения:
  * выдача относится к месяцу создания заявки, а не к месяцу выдачи (когортная воронка);
  * issued_loans_count / issued_amount — все фактические выдачи, включая 3 кредита
    по отклонённым заявкам (сходится с loans один в один);
  * конверсия «одобрение -> выдача» считается только по одобренным заявкам
    (issued_from_approved_count), иначе аномальные выдачи завышают конверсию;
  * среднее время до решения — по заявкам со статусом approved/rejected, в часах.
*/

with apps as (
    select * from {{ ref('stg_applications') }}
),

loans as (
    select app_id, principal from {{ ref('int_loans_validated') }}
),

app_level as (
    select
        a.created_month,
        a.app_id,
        a.status,
        a.hours_to_decision,
        l.app_id is not null as is_issued,
        l.principal
    from apps a
    left join loans l on l.app_id = a.app_id
)

select
    created_month                                                    as application_month,
    count(*)                                                         as applications_count,
    count(*) filter (where status in ('approved', 'rejected'))       as decided_count,
    count(*) filter (where status = 'approved')                      as approved_count,
    count(*) filter (where status = 'rejected')                      as rejected_count,
    count(*) filter (where status = 'new')                           as pending_count,
    count(*) filter (where is_issued)                                as issued_loans_count,
    count(*) filter (where is_issued and status = 'approved')        as issued_from_approved_count,
    count(*) filter (where is_issued and status <> 'approved')       as issued_from_not_approved_count,

    round(100.0 * count(*) filter (where status = 'approved')
          / nullif(count(*), 0), 2)                                  as conv_app_to_approved_pct,
    round(100.0 * count(*) filter (where is_issued and status = 'approved')
          / nullif(count(*) filter (where status = 'approved'), 0), 2) as conv_approved_to_issued_pct,
    round(100.0 * count(*) filter (where is_issued)
          / nullif(count(*), 0), 2)                                  as conv_app_to_issued_pct,

    round(avg(hours_to_decision), 2)                                 as avg_hours_to_decision,
    coalesce(sum(principal), 0)                                      as issued_amount
from app_level
group by created_month
order by created_month
