-- Transform_Clean, nguồn customers: lấy bản mới nhất của mỗi khoá theo batch_seq (đợt nạp sau thắng đợt trước),
-- hoà thì lấy dòng nằm sau trong file. Việc làm sạch (TRIM, đổi kiểu...) làm bằng Derived Column, Data Conversion.
SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY TRIM(s.customer_id)
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.customers s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.customer_id), '') IS NOT NULL
) x
WHERE rn = 1
