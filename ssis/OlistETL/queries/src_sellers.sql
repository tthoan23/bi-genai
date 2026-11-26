-- Transform_Clean, nguồn sellers: lấy bản mới nhất của mỗi khoá theo batch_seq (đợt nạp sau thắng đợt trước),
-- hoà thì lấy dòng nằm sau trong file. Việc làm sạch (TRIM, đổi kiểu...) làm bằng Derived Column, Data Conversion.
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY TRIM(s.seller_id)
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.sellers s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.seller_id), '') IS NOT NULL
) x
WHERE rn = 1
