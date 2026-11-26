-- Đối chiếu tổng tiền thanh toán với tiền hàng + phí vận chuyển của mỗi đơn. Chỉ gắn cờ, không loại đơn.
with pay as (
  select order_id,
         sum(payment_value)                  as payment_total,
         cast(min(case when payment_value is not null then 1 else 0 end) as bit) as payment_complete
  from {{ ref('stg_order_payments') }}
  group by order_id
)
select
  coalesce(p.order_id, i.order_id)                    as order_id,
  p.payment_total,
  i.goods_value + i.freight_value                     as goods_plus_freight,
  p.payment_total - (i.goods_value + i.freight_value) as diff_brl,
  case when p.payment_complete = 1 and i.amounts_complete = 1 then
       case when abs(p.payment_total - (i.goods_value + i.freight_value)) > {{ var('payment_threshold_brl') }} then 1 else 0 end
  end as mismatch_gt_threshold,
  case when p.payment_complete = 1 and i.amounts_complete = 1 then
       case when abs(p.payment_total - (i.goods_value + i.freight_value)) > 1.00 then 1 else 0 end
  end as mismatch_gt_1brl
from pay p
full outer join {{ ref('int_order_item_summary') }} i on i.order_id = p.order_id
