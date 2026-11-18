with source as (
    select * from {{ source('raw', 'applications') }}
)

select
    app_id::bigint                              as app_id,
    client_id::bigint                           as client_id,
    created_at::timestamp                       as created_at,
    created_at::date                            as created_date,
    date_trunc('month', created_at)::date       as created_month,
    amount::numeric(14,2)                       as amount,
    trim(lower(status))                         as status,
    decided_at::timestamp                       as decided_at,
    decided_at::date                            as decided_date,
    case
        when decided_at is not null and decided_at >= created_at
            then round(extract(epoch from (decided_at - created_at)) / 3600.0, 2)
    end                                         as hours_to_decision
from source
