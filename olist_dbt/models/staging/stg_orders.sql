-- Một dòng cho mỗi đơn hàng. Nếu một đơn có nhiều phiên bản (từ nhiều đợt nạp),
-- lấy phiên bản của đợt mới nhất theo batch_seq (không theo giờ nạp: chạy lại đợt cũ sẽ làm sai).
with src as (
  select s.*,
         row_number() over (partition by trim(s.order_id)
                            order by b.batch_seq desc nulls last, s.source_row_number desc) as rn
  from {{ source('olist', 'orders') }} s
  left join {{ source('audit', 'etl_batch') }} b on b.batch_id = s.source_batch_id
  where nullif(trim(s.order_id), '') is not null
)
select
  trim(order_id)            as order_id,
  trim(customer_id)         as customer_id,
  lower(trim(order_status)) as order_status,
  {{ safe_ts('order_purchase_timestamp') }}      as purchase_ts,
  {{ safe_ts('order_approved_at') }}             as approved_ts,
  {{ safe_ts('order_delivered_carrier_date') }}  as carrier_ts,
  {{ safe_ts('order_delivered_customer_date') }} as delivered_ts,
  {{ safe_ts('order_estimated_delivery_date') }} as estimated_ts,
  {{ ts_parse_error('order_purchase_timestamp') }}      as purchase_ts_parse_error,
  {{ ts_parse_error('order_approved_at') }}             as approved_ts_parse_error,
  {{ ts_parse_error('order_delivered_carrier_date') }}  as carrier_ts_parse_error,
  {{ ts_parse_error('order_delivered_customer_date') }} as delivered_ts_parse_error,
  {{ ts_parse_error('order_estimated_delivery_date') }} as estimated_ts_parse_error,
  source_file, source_row_number, source_batch_id
from src
where rn = 1
