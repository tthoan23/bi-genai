-- Transform_Clean, nguồn orders: lấy bản mới nhất của mỗi khoá theo batch_seq (đợt nạp sau thắng đợt trước),
-- hoà thì lấy dòng nằm sau trong file. Việc làm sạch (TRIM, đổi kiểu...) làm bằng Derived Column, Data Conversion.
SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
       order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY TRIM(s.order_id)
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.orders s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.order_id), '') IS NOT NULL
) x
WHERE rn = 1
