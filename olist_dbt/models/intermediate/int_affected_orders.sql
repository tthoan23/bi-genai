-- Các đơn cần tính lại khi nạp tăng thêm (dùng ở bước dựng fact).
-- Không lọc theo "ngày mua mới hơn": đơn mua từ trước vẫn có thể nhận thêm mốc giao hoặc đánh giá mới.
-- Khi không truyền batch_id (chạy toàn bộ), mọi đơn đều được tính lại.
{% set b = var('batch_id') %}
{% if b %}
select order_id from {{ ref('stg_orders') }}        where source_batch_id = '{{ b }}'
union
select order_id from {{ ref('stg_order_items') }}   where source_batch_id = '{{ b }}'
union
select order_id from {{ ref('stg_order_reviews') }} where source_batch_id = '{{ b }}'
union
select o.order_id                                   -- khách đổi địa chỉ
from {{ ref('stg_orders') }} o
join {{ ref('stg_customers') }} c on c.customer_id = o.customer_id
where c.source_batch_id = '{{ b }}'
union
select i.order_id                                   -- người bán đổi địa chỉ
from {{ ref('stg_order_items') }} i
join {{ ref('stg_sellers') }} s on s.seller_id = i.seller_id
where s.source_batch_id = '{{ b }}'
{% else %}
select order_id from {{ ref('stg_orders') }}
{% endif %}
