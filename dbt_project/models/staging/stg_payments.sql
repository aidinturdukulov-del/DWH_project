with source as (
    select * from {{ source('raw', 'payments') }}
)

select
    payment_id::bigint      as payment_id,
    loan_id::bigint         as loan_id,
    paid_at::date           as paid_at,
    amount::numeric(14,2)   as amount,
    loaded_at::date         as loaded_at,
    _load_id                as load_id     -- номер загрузки (etl.load_log), нужен для инкремента снимков
from source
