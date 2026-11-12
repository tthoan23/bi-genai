-- Gộp các dòng hàng về một dòng cho mỗi đơn TRƯỚC khi nối vào fact cấp đơn (tránh nhân dòng).
select
  order_id,
  count(*)::int                  as item_line_count,
  count(distinct seller_id)::int as seller_count,
  sum(price_amount)              as goods_value,
  sum(freight_amount)            as freight_value,
  bool_and(price_amount is not null and freight_amount is not null) as amounts_complete
from {{ ref('stg_order_items') }}
group by order_id
