-- Grain: MỘT DÒNG CHO MỖI DÒNG HÀNG (order_id, order_item_id) - transaction fact.
-- Không mang thời gian chờ hay điểm đánh giá xuống đây (tránh đếm một đơn nhiều lần).
-- depends_on: {{ ref('int_affected_orders') }}
{{ config(
    materialized='incremental',
    unique_key=['order_id', 'order_item_id'],
    incremental_strategy='delete+insert',
    on_schema_change='append_new_columns'
) }}

with i as (
  select * from {{ ref('stg_order_items') }}
  {% if is_incremental() %}
  where order_id in (select order_id from {{ ref('int_affected_orders') }})
  {% endif %}
)
select
  k.order_item_key,
  i.order_id,
  i.order_item_id,
  {{ to_date_key('o.purchase_ts', 'o.purchase_ts_parse_error') }}          as purchase_date_key,
  {{ to_date_key('i.shipping_limit_ts', 'i.shipping_limit_parse_error') }} as shipping_limit_date_key,
  coalesce(dc.customer_key, 0)  as customer_key,
  coalesce(cg.geography_key, 0) as customer_geography_key,
  coalesce(dp.product_key, 0)   as product_key,
  coalesce(dse.seller_key, 0)   as seller_key,
  coalesce(sg.geography_key, 0) as seller_geography_key,
  i.shipping_limit_ts,
  1::smallint                   as item_line_count,
  i.price_amount,
  i.freight_amount,
  (case when i.price_amount is not null and i.freight_amount is not null
        then i.price_amount + i.freight_amount end)::decimal(18, 2) as item_total_amount,
  coalesce({{ "'" ~ var('batch_id') ~ "'" if var('batch_id') else 'null' }}, i.source_batch_id) as source_batch_id,
  {% if is_incremental() %}coalesce(old.dw_created_at, current_timestamp::timestamp){% else %}current_timestamp::timestamp{% endif %} as dw_created_at,
  current_timestamp::timestamp as dw_updated_at
from i
left join {{ ref('km_order_item') }}          k   on k.order_id = i.order_id and k.order_item_id = i.order_item_id
left join {{ ref('stg_orders') }}             o   on o.order_id = i.order_id
left join {{ ref('int_order_customer_map') }} cm  on cm.order_id = i.order_id
left join {{ ref('dim_customer') }}           dc  on dc.customer_unique_id = cm.customer_unique_id
left join {{ ref('dim_geography') }}          cg  on cg.zip_prefix = cm.customer_zip_prefix
left join {{ ref('dim_product') }}            dp  on dp.product_id = i.product_id
left join {{ ref('dim_seller') }}             dse on dse.seller_id = i.seller_id
left join {{ ref('stg_sellers') }}            s   on s.seller_id = i.seller_id
left join {{ ref('dim_geography') }}          sg  on sg.zip_prefix = s.zip_prefix
{% if is_incremental() %}
left join {{ this }} old on old.order_id = i.order_id and old.order_item_id = i.order_item_id
{% endif %}
