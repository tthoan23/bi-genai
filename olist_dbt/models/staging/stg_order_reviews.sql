-- Giữ mọi đánh giá (một đơn có thể có nhiều đánh giá; review_id có thể lặp giữa các đơn).
-- Chỉ bỏ những dòng trùng hoàn toàn mọi cột nội dung. Việc chọn một đánh giá đại diện cho mỗi đơn làm ở bước sau.
with src as (
  select *,
         row_number() over (
           -- BIN2: so từng ký tự, để hai bình luận chỉ khác hoa/thường không bị coi là trùng (giống DuckDB)
           partition by review_id, order_id, review_score,
                        review_comment_title collate Latin1_General_100_BIN2,
                        review_comment_message collate Latin1_General_100_BIN2,
                        review_creation_date, review_answer_timestamp
           order by source_batch_id, source_row_number
         ) as dup_rn
  from {{ source('olist', 'order_reviews') }}
)
select
  trim(review_id) as review_id,
  trim(order_id)  as order_id,
  case when trim(review_score) in ('1', '2', '3', '4', '5') then cast(trim(review_score) as smallint) end as review_score,
  cast(case when nullif(trim(review_score), '') is not null
             and trim(review_score) not in ('1', '2', '3', '4', '5') then 1 else 0 end as smallint) as invalid_score_flag,
  -- Không dùng nullif(x, ''): collation mặc định coi chuỗi chỉ có emoji hoặc dấu cách bằng chuỗi rỗng. datalength đếm byte.
  case when datalength(review_comment_title) > 0 then review_comment_title end     as review_comment_title,
  case when datalength(review_comment_message) > 0 then review_comment_message end as review_comment_message,
  {{ safe_ts('review_creation_date') }}    as review_creation_ts,
  {{ safe_ts('review_answer_timestamp') }} as review_answer_ts,
  source_file, source_row_number, source_batch_id
from src
where dup_rn = 1
