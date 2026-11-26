-- Transform_Clean, nguồn order_reviews: giữ mọi đánh giá, chỉ bỏ dòng trùng hoàn toàn mọi cột nội dung.
-- BIN2: so từng ký tự, để hai bình luận chỉ khác hoa/thường không bị coi là trùng.
SELECT review_id, order_id, review_score, review_comment_title, review_comment_message,
       review_creation_date, review_answer_timestamp,
       source_file, source_row_number, source_batch_id
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY review_id, order_id, review_score,
                            review_comment_title COLLATE Latin1_General_100_BIN2,
                            review_comment_message COLLATE Latin1_General_100_BIN2,
                            review_creation_date, review_answer_timestamp
               ORDER BY source_batch_id, source_row_number) AS dup_rn
    FROM staging.order_reviews
) x
WHERE dup_rn = 1
