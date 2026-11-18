{% test dbt_utils_free_unique_combination(model, columns) %}
-- Уникальность комбинации колонок без внешних пакетов
select {{ columns | join(', ') }}, count(*) as cnt
from {{ model }}
group by {{ columns | join(', ') }}
having count(*) > 1
{% endtest %}
