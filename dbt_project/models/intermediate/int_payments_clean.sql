{{ config(materialized='table') }}

/*
Очищенные платежи — единственный источник фактических оплат для снимков.
Правила (подробно и с количеством строк — README, раздел «Аномалии», и dq.dq_source_anomalies):
  1. payment_orphan       — кредита нет в loans: исключаем (не к чему привязать).
  2. payment_non_positive — amount <= 0 (сторно/ошибка знака): исключаем.
  3. payment_before_issue — paid_at < issued_at: исключаем (до выдачи долга нет).
  4. payment_duplicate    — та же связка loan_id + paid_at + amount + loaded_at под другим payment_id
                            (технический дубль выгрузки): оставляем запись с минимальным payment_id.
Все исключённые строки остаются в raw и перечислены в dq.dq_source_anomalies.
*/

with payments as (
    select * from {{ ref('stg_payments') }}
),

loans as (
    select loan_id, issued_at from {{ ref('stg_loans') }}
),

ranked as (
    select
        p.*,
        row_number() over (
            partition by p.loan_id, p.paid_at, p.amount, p.loaded_at
            order by p.payment_id
        ) as dup_rn
    from payments p
    join loans l on l.loan_id = p.loan_id
    where p.amount > 0
      and p.paid_at >= l.issued_at
)

select payment_id, loan_id, paid_at, amount, loaded_at, load_id
from ranked
where dup_rn = 1
