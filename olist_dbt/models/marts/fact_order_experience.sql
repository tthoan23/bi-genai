-- Grain: MỘT DÒNG CHO MỖI ĐƠN (accumulating snapshot: dòng được cập nhật khi đơn có thêm mốc hoặc đánh giá).
-- Nạp tăng thêm: chỉ tính lại các đơn bị ảnh hưởng (int_affected_orders), xoá dòng cũ rồi chèn dòng mới theo order_id.
-- Dòng dưới khai báo phụ thuộc cho dbt, vì ref() nằm trong khối is_incremental() bị bỏ qua lúc dbt đọc code:
-- depends_on: {{ ref('int_affected_orders') }}
{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='delete+insert',
    on_schema_change='append_new_columns'
) }}

with t as (
  select * from {{ ref('int_order_timeline') }}
  {% if is_incremental() %}
  where order_id in (select order_id from {{ ref('int_affected_orders') }})
  {% endif %}
),
rv as (select * from {{ ref('int_order_review_representative') }}),
it as (select * from {{ ref('int_order_item_summary') }}),
cm as (select * from {{ ref('int_order_customer_map') }})

select
  k.order_key,
  t.order_id,
  coalesce(dc.customer_key, 0)            as customer_key,
  coalesce(dg.geography_key, 0)           as customer_geography_key,
  coalesce(ds.status_key, 0)::smallint    as status_key,
  coalesce(dout.outcome_key, 0)::smallint as outcome_key,

  -- 6 vai trò ngày: -2 ngày lỗi, -1 mốc chưa xảy ra (theo trạng thái đơn), 0 thiếu
  {{ to_date_key('t.purchase_ts',  't.purchase_ts_parse_error') }}  as purchase_date_key,
  {{ to_date_key('t.approved_ts',  't.approved_ts_parse_error',
                 "t.order_status in ('created')") }}                as approved_date_key,
  {{ to_date_key('t.carrier_ts',   't.carrier_ts_parse_error',
                 "t.order_status in ('created','approved','invoiced','processing')") }} as carrier_date_key,
  {{ to_date_key('t.delivered_ts', 't.delivered_ts_parse_error',
                 "t.order_status in ('created','approved','invoiced','processing','shipped')") }} as delivered_date_key,
  {{ to_date_key('t.estimated_ts', 't.estimated_ts_parse_error') }} as estimated_date_key,
  {{ to_date_key('rv.review_answer_ts') }}                          as review_answer_date_key,

  t.purchase_ts, t.approved_ts, t.carrier_ts, t.delivered_ts, t.estimated_ts,

  1::smallint as order_count,
  t.delivered_count,
  t.delivery_eligible_count,
  t.late_count,
  t.on_time_count,
  t.approval_seconds, t.handling_seconds, t.transit_seconds, t.delivery_seconds,
  t.late_days,

  rv.representative_review_score,
  (case when rv.representative_review_score is not null then 1 else 0 end)::smallint as reviewed_order_count,
  (case when rv.representative_review_score in (1, 2) then 1 else 0 end)::smallint   as low_review_order_count,
  coalesce(rv.review_record_count, 0)                                                as review_record_count,
  rv.representative_review_id,
  rv.representative_review_source_id,
  rv.review_creation_ts,
  rv.review_answer_ts,
  (case when rv.review_answer_ts is null or t.delivered_ts is null then null
        when rv.review_answer_ts < t.delivered_ts then 1 else 0 end)::smallint       as review_before_delivery_flag,

  coalesce(it.item_line_count, 0) as item_line_count,
  coalesce(it.seller_count, 0)    as seller_count,

  -- Cờ chất lượng dữ liệu (đếm được đơn lỗi theo từng loại)
  t.invalid_approval_sequence, t.invalid_handling_sequence, t.invalid_transit_sequence,
  t.invalid_delivery_sequence, t.invalid_estimated_date,
  t.quality_issue_count,

  coalesce({{ "'" ~ var('batch_id') ~ "'" if var('batch_id') else 'null' }}, t.source_batch_id) as source_batch_id,
  {% if is_incremental() %}coalesce(old.dw_created_at, current_timestamp::timestamp){% else %}current_timestamp::timestamp{% endif %} as dw_created_at,
  current_timestamp::timestamp as dw_updated_at

from t
left join {{ ref('km_order') }}             k    on k.order_id = t.order_id
left join cm                                     on cm.order_id = t.order_id
left join {{ ref('dim_customer') }}         dc   on dc.customer_unique_id = cm.customer_unique_id
left join {{ ref('dim_geography') }}        dg   on dg.zip_prefix = cm.customer_zip_prefix
left join {{ ref('dim_order_status') }}     ds   on ds.order_status = t.order_status
left join {{ ref('dim_delivery_outcome') }} dout on dout.outcome_code = t.outcome_code
left join rv                                     on rv.order_id = t.order_id
left join it                                     on it.order_id = t.order_id
{% if is_incremental() %}
left join {{ this }} old on old.order_id = t.order_id
{% endif %}
