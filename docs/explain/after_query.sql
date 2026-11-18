EXPLAIN (ANALYZE, BUFFERS)


/*
loan_snapshot_daily — строка на каждый кредит и каждую дату с даты выдачи до даты актуальности
данных (as_of_date = max(loaded_at) по всем загруженным платежам).

Правила на дату среза D:
  debt_balance   = сумма всего графика - сумма платежей с paid_at <= D            (не меньше 0)
  overdue_amount = сумма графика с due_date <= D - сумма платежей с paid_at <= D  (не меньше 0)
  days_overdue   = D - due_date самого раннего непогашенного планового платежа,
                   если overdue_amount > 0 (платежи гасят график по порядку), иначе 0
  overdue_bucket = 0 / 1-30 / 31-60 / 61-90 / 90+

Как считается (оптимизация, см. docs/optimization.md).
  Состояние кредита меняется только в «события»: дата выдачи, плановая дата, дата платежа.
  1) по событиям (~36 тыс. строк) оконными суммами считаем накопленный план и факт;
  2) для каждого события находим первый непогашенный плановый платёж;
  3) разворачиваем интервал [событие, следующее событие) в дни через generate_series.
  Нет ни соединения «каждый день × каждый плановый платёж», ни сортировок полумиллиона строк.

Инкремент (опоздавшие платежи).
  Каждая строка хранит calc_load_id — максимальный raw.payments._load_id на момент расчёта.
  При следующем запуске для каждого кредита пересчитывается хвост начиная с recalc_from:
    * новые даты (после прошлого as_of_date) — для всех кредитов;
    * если пришёл платёж из новой загрузки — с его paid_at (опоздавший платёж «переписывает»
      прошлые снимки, начиная с даты платежа);
    * новый кредит — с даты выдачи.
  delete+insert по (snapshot_date, loan_id) делает повторный запуск безопасным.
*/

-- Дата актуальности и водяной знак берутся из той же таблицы, что и сами платежи,
-- чтобы они всегда были согласованы между собой.
with as_of as (
    select
        max(loaded_at) as as_of_date,
        max(load_id)   as calc_load_id
    from "credit_dwh"."core"."int_payments_clean"
),

loans as (
    select loan_id, issued_at, total_schedule_amount
    from "credit_dwh"."core"."int_loans_validated"
),

payments as (
    select loan_id, paid_at, amount, load_id
    from "credit_dwh"."core"."int_payments_clean"
),

-- С какой даты пересчитывать каждый кредит
recalc as (

    select loan_id, issued_at, total_schedule_amount, issued_at as recalc_from
    from loans

),

schedule as (
    select
        s.loan_id,
        s.due_date,
        sum(s.due_amount) over (partition by s.loan_id order by s.due_date) as cum_due
    from "credit_dwh"."staging"."stg_schedule" s
),

-- Все даты, в которые меняется состояние кредита, с приростами плана и факта
events as (
    select loan_id, event_date, sum(due_delta) as due_delta, sum(paid_delta) as paid_delta
    from (
        select loan_id, issued_at as event_date, 0 as due_delta, 0 as paid_delta from recalc
        union all
        select s.loan_id, s.due_date, s.due_amount, 0
        from "credit_dwh"."staging"."stg_schedule" s
        union all
        select loan_id, paid_at, 0, amount from payments
    ) e
    where event_date <= (select as_of_date from as_of)
    group by loan_id, event_date
),

-- Накопленные суммы на каждое событие + граница интервала
event_state as (
    select
        loan_id,
        event_date,
        lead(event_date) over w                     as next_event_date,
        sum(due_delta)  over (w rows unbounded preceding) as cum_due_to_date,
        sum(paid_delta) over (w rows unbounded preceding) as cum_paid
    from events
    window w as (partition by loan_id order by event_date)
),

-- Самый ранний непогашенный плановый платёж: первый, у которого накопленный план > накопленного факта
event_state_fifo as (
    select
        es.*,
        fu.first_unpaid_due_date
    from event_state es
    left join lateral (
        select min(s.due_date) as first_unpaid_due_date
        from schedule s
        where s.loan_id = es.loan_id
          and s.cum_due > es.cum_paid
    ) fu on true
),

-- Разворачиваем интервалы постоянного состояния в дни
daily as (
    select
        d.snapshot_date::date                                        as snapshot_date,
        r.loan_id,
        greatest(r.total_schedule_amount - es.cum_paid, 0)           as debt_balance,
        greatest(es.cum_due_to_date - es.cum_paid, 0)                as overdue_amount,
        es.first_unpaid_due_date
    from recalc r
    join event_state_fifo es on es.loan_id = r.loan_id
    cross join lateral generate_series(
        greatest(es.event_date, r.recalc_from, r.issued_at),
        least(coalesce(es.next_event_date - 1, (select as_of_date from as_of)),
              (select as_of_date from as_of)),
        interval '1 day'
    ) as d(snapshot_date)
),

final as (
    select
        snapshot_date,
        loan_id,
        round(debt_balance, 2)   as debt_balance,
        round(overdue_amount, 2) as overdue_amount,
        case when overdue_amount > 0 then snapshot_date - first_unpaid_due_date else 0 end as days_overdue
    from daily
)

select
    f.snapshot_date,
    f.loan_id,
    f.debt_balance,
    f.overdue_amount,
    f.days_overdue,
    case
        when f.days_overdue = 0  then '0'
        when f.days_overdue <= 30 then '1-30'
        when f.days_overdue <= 60 then '31-60'
        when f.days_overdue <= 90 then '61-90'
        else '90+'
    end                     as overdue_bucket,
    a.calc_load_id,
    now()                   as calculated_at
from final f
cross join as_of a;
