-- Падает, если хотя бы одна сверка из dq.dq_reconciliation не прошла
select * from {{ ref('dq_reconciliation') }} where not passed
