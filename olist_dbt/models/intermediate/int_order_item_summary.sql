-- Gộp các dòng hàng về một dòng cho mỗi đơn TRƯỚC khi nối vào fact cấp đơn (tránh nhân dòng).
select
  order_id,
  count(*)                       as item_line_count,
  count(distinct seller_id)      as seller_count,
  sum(price_amount)              as goods_value,
  sum(freight_amount)            as freight_value,
  -- bit: 1 khi mọi dòng hàng của đơn đủ giá và phí vận chuyển
  cast(min(case when price_amount is not null and freight_amount is not null then 1 else 0 end) as bit) as amounts_complete
from {{ ref('stg_order_items') }}
group by order_id
