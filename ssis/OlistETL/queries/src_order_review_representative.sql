-- Transform_Business: mỗi đơn chọn một đánh giá đại diện: điểm hợp lệ (1-5), trả lời gần nhất;
-- hoà thì xét ngày tạo, mã đánh giá, rồi vị trí dòng để kết quả luôn cố định. SSIS không có thành phần
-- ROW_NUMBER nên bước xếp hạng viết bằng SQL; ghép mã nguồn làm bằng Derived Column.
SELECT order_id, review_id AS representative_review_id, review_score AS representative_review_score,
       review_creation_ts, review_answer_ts, review_record_count,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_ts DESC, review_creation_ts DESC,
                                       review_id, source_batch_id, source_row_number) AS rk,
           COUNT(*) OVER (PARTITION BY order_id) AS review_record_count
    FROM intermediate.cln_order_reviews r
    WHERE review_score IS NOT NULL AND NULLIF(order_id, '') IS NOT NULL
) x
WHERE rk = 1
