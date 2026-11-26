-- Transform_Business: ghép tổng thanh toán với tổng tiền hàng + phí vận chuyển theo đơn (hai bảng do Aggregate tạo).
-- FULL OUTER JOIN: giữ cả đơn chỉ có thanh toán hoặc chỉ có dòng hàng. Chênh lệch và cờ tính bằng Derived Column.
SELECT COALESCE(p.order_id, i.order_id) AS order_id,
       p.payment_total, p.payment_complete,
       i.goods_value, i.freight_value, i.amounts_complete
FROM intermediate.int_order_payment_summary p
FULL OUTER JOIN intermediate.int_order_item_summary i ON i.order_id = p.order_id
