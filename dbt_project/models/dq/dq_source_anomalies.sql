{{ config(materialized='table') }}

/*
Реестр найденных в источнике ошибок и аномалий: одна строка на затронутую запись.
  severity = excluded — строка исключена из core/dm (остаётся в raw);
  severity = flagged  — строка оставлена, но помечена / учитывается отдельно;
  severity = info     — особенность данных, на расчёты не влияет.
Сводка: select anomaly_code, severity, count(*), sum(amount) from dq.dq_source_anomalies group by 1, 2;
*/

with apps     as (select * from {{ ref('stg_applications') }}),
     loans    as (select * from {{ ref('stg_loans') }}),
     payments as (select * from {{ ref('stg_payments') }}),
     as_of    as (select max(loaded_at) as as_of_date from payments),

pay_checked as (
    select
        p.*,
        l.issued_at,
        row_number() over (
            partition by p.loan_id, p.paid_at, p.amount, p.loaded_at order by p.payment_id
        ) as dup_rn,
        min(p.payment_id) over (
            partition by p.loan_id, p.paid_at, p.amount, p.loaded_at
        ) as dup_of_payment_id
    from payments p
    left join loans l on l.loan_id = p.loan_id
)

select 'payment_orphan' as anomaly_code, 'excluded' as severity, 'payments' as source_table,
       payment_id as record_id, amount,
       'loan_id=' || loan_id || ' отсутствует в loans' as details
from pay_checked where issued_at is null

union all
select 'payment_non_positive', 'excluded', 'payments', payment_id, amount,
       'amount=' || amount || ' (loan_id=' || loan_id || ', paid_at=' || paid_at || ')'
from pay_checked where issued_at is not null and amount <= 0

union all
select 'payment_before_issue', 'excluded', 'payments', payment_id, amount,
       'paid_at=' || paid_at || ' раньше issued_at=' || issued_at || ' (loan_id=' || loan_id || ')'
from pay_checked where issued_at is not null and amount > 0 and paid_at < issued_at

union all
select 'payment_duplicate', 'excluded', 'payments', payment_id, amount,
       'дубль payment_id=' || dup_of_payment_id || ' (loan_id, paid_at, amount, loaded_at совпадают)'
from pay_checked where issued_at is not null and amount > 0 and paid_at >= issued_at and dup_rn > 1

union all
select 'payment_late_arrival', 'info', 'payments', payment_id, amount,
       'loaded_at - paid_at = ' || (loaded_at - paid_at) || ' дн.'
       || case when paid_at <= date '2026-09-30' and loaded_at > date '2026-09-30'
               then '; пришёл после среза 30.09 и пересчитал прошлые снимки' else '' end
from pay_checked where loaded_at - paid_at > 2

union all
select 'loan_on_rejected_application', 'flagged', 'loans', l.loan_id, l.principal,
       'app_id=' || l.app_id || ' в статусе ' || a.status || ', решение ' || a.decided_at
from loans l join apps a on a.app_id = l.app_id
where a.status <> 'approved'

union all
select 'loan_without_application', 'flagged', 'loans', l.loan_id, l.principal,
       'app_id=' || l.app_id || ' отсутствует в applications'
from loans l left join apps a on a.app_id = l.app_id
where a.app_id is null

union all
select 'application_stuck_new', 'info', 'applications', a.app_id, a.amount,
       'статус new, создана ' || a.created_date || ', без решения ' || (s.as_of_date - a.created_date) || ' дн.'
from apps a cross join as_of s
where a.status = 'new' and s.as_of_date - a.created_date > 30

union all
select 'application_inconsistent_decision', 'flagged', 'applications', app_id, amount,
       'status=' || coalesce(status, 'NULL') || ', decided_at=' || coalesce(decided_at::text, 'NULL')
from apps
where (status = 'new' and decided_at is not null)
   or (status in ('approved', 'rejected') and decided_at is null)
   or decided_at < created_at
   or status not in ('new', 'approved', 'rejected') or status is null
