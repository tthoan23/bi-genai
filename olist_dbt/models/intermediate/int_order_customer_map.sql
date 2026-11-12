-- Đơn → customer_id của chính đơn đó → khách thật (customer_unique_id) và mã bưu chính của đơn.
-- Không lấy một địa chỉ chung cho mọi đơn của cùng một khách.
select
  o.order_id,
  o.customer_id,
  c.customer_unique_id,
  c.zip_prefix as customer_zip_prefix,
  (case when c.customer_id is null then 1 else 0 end)::smallint as missing_customer_flag
from {{ ref('stg_orders') }} o
left join {{ ref('stg_customers') }} c on c.customer_id = o.customer_id
