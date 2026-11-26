-- Load_Facts, nguồn fact_order_item: grain một dòng cho mỗi dòng hàng (order_id, order_item_id).
-- Lấy thêm ngày mua của đơn, khách thật và mã bưu chính của đơn, mã bưu chính người bán.
SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id,
       i.shipping_limit_ts, i.shipping_limit_parse_error, i.price_amount, i.freight_amount, i.source_batch_id,
       o.purchase_ts, o.purchase_ts_parse_error,
       cm.customer_unique_id, cm.customer_zip_prefix,
       s.zip_prefix AS seller_zip_prefix
FROM intermediate.cln_order_items i
LEFT JOIN intermediate.cln_orders o              ON o.order_id = i.order_id
LEFT JOIN intermediate.int_order_customer_map cm ON cm.order_id = i.order_id
LEFT JOIN intermediate.cln_sellers s             ON s.seller_id = i.seller_id
