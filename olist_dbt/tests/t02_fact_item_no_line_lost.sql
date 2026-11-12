-- T02: fact item có đúng số dòng hàng hợp lệ của stg_order_items
select f.n as fact_rows, s.n as stg_rows
from (select count(*) n from {{ ref('fact_order_item') }}) f,
     (select count(*) n from {{ ref('stg_order_items') }}) s
where f.n <> s.n
