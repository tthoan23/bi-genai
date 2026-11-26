-- Transform_Clean, nguồn category_translation: một dòng cho mỗi danh mục (so không phân biệt hoa thường).
SELECT product_category_name, product_category_name_english
FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY LOWER(TRIM(s.product_category_name))
                              ORDER BY b.batch_seq DESC, s.source_row_number DESC) AS rn
    FROM staging.category_translation s
    LEFT JOIN audit.etl_batch b ON b.batch_id = s.source_batch_id
    WHERE NULLIF(TRIM(s.product_category_name), '') IS NOT NULL
) x
WHERE rn = 1
