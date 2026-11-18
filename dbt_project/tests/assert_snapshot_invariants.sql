-- Внутренняя согласованность снимков: каждая возвращённая строка — нарушение
select snapshot_date, loan_id, 'negative values' as problem
from {{ ref('dm_loan_snapshot_daily') }}
where debt_balance < 0 or overdue_amount < 0 or days_overdue < 0
union all
select snapshot_date, loan_id, 'overdue > balance'
from {{ ref('dm_loan_snapshot_daily') }}
where overdue_amount > debt_balance
union all
-- дни просрочки без просроченной суммы невозможны; обратное допустимо:
-- в саму плановую дату сумма уже в overdue_amount (due_date <= D), но дней просрочки 0
select snapshot_date, loan_id, 'days without overdue amount'
from {{ ref('dm_loan_snapshot_daily') }}
where days_overdue > 0 and overdue_amount = 0
union all
select s.snapshot_date, s.loan_id, 'snapshot before issue'
from {{ ref('dm_loan_snapshot_daily') }} s
join {{ ref('int_loans_validated') }} l using (loan_id)
where s.snapshot_date < l.issued_at
