with source as (
    select * from {{ source('raw', 'schedule') }}
)

select
    loan_id::bigint as loan_id,
    due_date::date as due_date,
    due_amount::numeric(14,2) as due_amount
from source
