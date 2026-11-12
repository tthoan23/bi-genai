-- Giữ mọi đánh giá (một đơn có thể có nhiều đánh giá; review_id có thể lặp giữa các đơn).
-- Chỉ bỏ những dòng trùng hoàn toàn mọi cột nội dung. Việc chọn một đánh giá đại diện cho mỗi đơn làm ở bước sau.
with src as (
  select *,
         row_number() over (
           partition by review_id, order_id, review_score, review_comment_title,
                        review_comment_message, review_creation_date, review_answer_timestamp
           order by source_batch_id, source_row_number
         ) as dup_rn
  from {{ source('olist', 'order_reviews') }}
)
select
  trim(review_id) as review_id,
  trim(order_id)  as order_id,
  case when regexp_full_match(trim(review_score), '[1-5]') then trim(review_score)::smallint end as review_score,
  (case when nullif(trim(review_score), '') is not null
         and not regexp_full_match(trim(review_score), '[1-5]') then 1 else 0 end)::smallint as invalid_score_flag,
  nullif(review_comment_title, '')   as review_comment_title,
  nullif(review_comment_message, '') as review_comment_message,
  {{ safe_ts('review_creation_date') }}    as review_creation_ts,
  {{ safe_ts('review_answer_timestamp') }} as review_answer_ts,
  source_file, source_row_number, source_batch_id
from src
where dup_rn = 1
