-- Nhóm kết quả giao (đúng hạn, trễ 1–3, 4–7, trên 7 ngày, chưa đủ điều kiện); sort_order để hiển thị đúng thứ tự.
select 0::smallint as outcome_key, 'UNKNOWN' as outcome_code, 'Không xác định' as outcome_label, 99::smallint as sort_order
union all
select outcome_key::smallint, outcome_code, outcome_label, sort_order::smallint from {{ ref('seed_delivery_outcome') }}
