-- T02/T04: fact cấp đơn có đúng số đơn của stg_orders (không mất, không nhân dòng)
select 'row_count_mismatch' as issue, f.n as fact_rows, s.n as stg_rows
from (select count(*) n from {{ ref('fact_order_experience') }}) f,
     (select count(*) n from {{ ref('stg_orders') }}) s
where f.n <> s.n
