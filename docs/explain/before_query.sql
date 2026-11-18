EXPLAIN (ANALYZE, BUFFERS)


/*
Витрина ежедневных снимков кредитного портфеля (п. 2.2 задания):
Со строкой на каждый кредит и каждую дату начиная с даты выдачи.
Поля:
  - snapshot_date: дата среза
  - loan_id: идентификатор кредита
  - debt_balance: остаток долга (сумма графика - все платежи с paid_at <= snapshot_date)
  - overdue_amount: просроченная сумма (план due_date <= snapshot_date - факт paid_at <= snapshot_date, но не < 0)
  - days_overdue: дни просрочки (от самого раннего непогашенного планового платежа по правилу FIFO)
  - overdue_bucket: бакет просрочки (0, 1–30, 31–60, 61–90, 90+)
*/

with max_date as (
    select coalesce(max(loaded_at), '2026-10-31'::date) as end_date 
    from "credit_dwh"."core"."int_payments_clean"
),

loans as (
    select
        loan_id,
        issued_at,
        total_schedule_amount
    from "credit_dwh"."core"."int_loans_validated"
),

-- Генерация календарной сетки: строка на каждый кредит и каждый день с даты выдачи
calendar as (
    select
        l.loan_id,
        l.issued_at,
        l.total_schedule_amount,
        d.snapshot_date::date as snapshot_date
    from loans l
    cross join max_date m
    cross join lateral generate_series(l.issued_at, m.end_date, interval '1 day') as d(snapshot_date)
),

-- Ежедневная агрегация чистых платежей
daily_payments as (
    select
        loan_id,
        paid_at,
        sum(amount) as paid_amount
    from "credit_dwh"."core"."int_payments_clean"
    group by 1, 2
),

-- Накопленная сумма фактически оплаченных средств на каждый день (running total)
calendar_with_payments as (
    select
        c.loan_id,
        c.snapshot_date,
        c.total_schedule_amount,
        sum(coalesce(p.paid_amount, 0)) over (
            partition by c.loan_id 
            order by c.snapshot_date
            rows between unbounded preceding and current row
        ) as cum_paid
    from calendar c
    left join daily_payments p
        on c.loan_id = p.loan_id and c.snapshot_date = p.paid_at
),

-- Накопленный график платежей (running total по плановым суммам)
sched_cum as (
    select
        loan_id,
        due_date,
        due_amount,
        sum(due_amount) over (partition by loan_id order by due_date) as cum_due
    from "credit_dwh"."staging"."stg_schedule"
),

-- Границы каждого планового платежа [prev_cum_due, cum_due)
sched_bounds as (
    select
        loan_id,
        due_date,
        due_amount,
        cum_due,
        coalesce(lag(cum_due) over (partition by loan_id order by due_date), 0::numeric) as prev_cum_due
    from sched_cum
),

-- Плановая сумма к оплате, наступившая на дату среза (due_date <= snapshot_date)
due_on_date as (
    select
        c.loan_id,
        c.snapshot_date,
        coalesce(max(s.cum_due), 0) as due_amount_as_of_date
    from calendar c
    left join sched_cum s
        on c.loan_id = s.loan_id and s.due_date <= c.snapshot_date
    group by c.loan_id, c.snapshot_date
),

-- Расчет показателей снимка с определением непогашенного платежа (FIFO)
calculated as (
    select 
        c.snapshot_date,
        c.loan_id,
        
        -- 1. Остаток долга (сумма всех плановых платежей минус факт с paid_at <= D)
        greatest(0, c.total_schedule_amount - c.cum_paid) as debt_balance,
        
        -- 2. Просроченная сумма (план due_date <= D минус факт paid_at <= D, но не меньше 0)
        greatest(0, d.due_amount_as_of_date - c.cum_paid) as overdue_amount,
        
        -- 3. Дни просрочки от самого раннего непогашенного платежа по FIFO
        case 
            -- Если просрочки нет
            when greatest(0, d.due_amount_as_of_date - c.cum_paid) = 0 then 0
            -- Если есть непогашенный платеж, срок которого уже наступил
            when s.due_date is not null and s.due_date <= c.snapshot_date then c.snapshot_date - s.due_date
            else 0
        end as days_overdue

    from calendar_with_payments c
    join due_on_date d
        on c.loan_id = d.loan_id and c.snapshot_date = d.snapshot_date
    left join sched_bounds s
        on c.loan_id = s.loan_id 
       and c.cum_paid >= s.prev_cum_due 
       and c.cum_paid < s.cum_due
)

select
    snapshot_date,
    loan_id,
    round(debt_balance, 2) as debt_balance,
    round(overdue_amount, 2) as overdue_amount,
    days_overdue,
    case
        when days_overdue = 0 or overdue_amount = 0 then '0'
        when days_overdue between 1 and 30 then '1-30'
        when days_overdue between 31 and 60 then '31-60'
        when days_overdue between 61 and 90 then '61-90'
        else '90+'
    end as overdue_bucket
from calculated;
