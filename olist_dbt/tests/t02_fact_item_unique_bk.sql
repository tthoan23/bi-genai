-- T02: cặp BK (order_id, order_item_id) duy nhất trên fact item
select order_id, order_item_id, count(*) as n
from {{ ref('fact_order_item') }}
group by order_id, order_item_id
having count(*) > 1
