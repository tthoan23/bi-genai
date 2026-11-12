-- 8 trạng thái đơn của Olist (lấy từ seed) và dòng Unknown khoá 0.
select 0::smallint as status_key, 'unknown' as order_status, 'Unknown' as status_label, 'Unknown' as status_group
union all
select status_key::smallint, order_status, status_label, status_group from {{ ref('seed_order_status') }}
