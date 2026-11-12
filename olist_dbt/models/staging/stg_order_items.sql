-- Một dòng cho mỗi sản phẩm trong đơn. Khoá là (order_id, order_item_id):
-- không dùng (order_id, product_id) vì một sản phẩm có thể lặp lại trong cùng đơn.
with src as (
  select s.*,
         row_number() over (partition by trim(s.order_id), trim(s.order_item_id)
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'order_items') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.order_id), '') is not null
)
select
  trim(order_id)                  as order_id,
  {{ safe_int('order_item_id') }} as order_item_id,
  trim(product_id)                as product_id,
  trim(seller_id)                 as seller_id,
  {{ safe_ts('shipping_limit_date') }}        as shipping_limit_ts,
  {{ ts_parse_error('shipping_limit_date') }} as shipping_limit_parse_error,
  {{ safe_num('price') }}         as price_amount,
  {{ safe_num('freight_value') }} as freight_amount,
  {{ num_parse_error('price') }}         as price_parse_error,
  {{ num_parse_error('freight_value') }} as freight_parse_error,
  source_file, source_row_number, source_batch_id
from src
where rn = 1
