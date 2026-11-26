-- Transform_Clean, nguồn order_payments: lấy bản mới nhất của mỗi khoá theo batch_seq (đợt nạp sau thắng đợt trước),
-- hoà thì lấy dòng nằm sau trong file. Việc làm sạch (TRIM, đổi kiểu...) làm bằng Derived Column, Data Conversion.
SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY TRIM(s.order_id), TRIM(s.payment_sequential)
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.order_payments s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.order_id), '') IS NOT NULL
) x
WHERE rn = 1
