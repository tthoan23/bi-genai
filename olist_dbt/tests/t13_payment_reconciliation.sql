-- T13 (warn): đơn lệch payment so với hàng + freight vượt ngưỡng; chỉ cảnh báo, không loại đơn
{{ config(severity='warn') }}
select order_id, payment_total, goods_plus_freight, diff_brl
from {{ ref('int_order_payment_reconciliation') }}
where mismatch_gt_threshold = 1
