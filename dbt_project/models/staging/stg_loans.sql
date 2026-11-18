with source as (
    select * from {{ source('raw', 'loans') }}
)

select
    loan_id::bigint as loan_id,
    app_id::bigint as app_id,
    issued_at::date as issued_at,
    date_trunc('month', issued_at)::date as issued_month,
    principal::numeric(14,2) as principal,
    term_months::int as term_months,
    rate::numeric(5,2) as rate
from source
