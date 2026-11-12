-- Mỗi đơn chọn một đánh giá đại diện: đánh giá hợp lệ (1–5 sao) được trả lời gần nhất;
-- bằng nhau thì xét ngày tạo, rồi mã đánh giá, rồi vị trí dòng trong file, để kết quả luôn cố định.
with valid as (
  select * from {{ ref('stg_order_reviews') }}
  where review_score is not null and nullif(order_id, '') is not null
),
ranked as (
  select
    v.*,
    row_number() over (
      partition by order_id
      order by review_answer_ts desc nulls last,
               review_creation_ts desc nulls last,
               review_id, source_batch_id, source_row_number
    ) as rk,
    count(*) over (partition by order_id) as review_record_count
  from valid v
)
select
  order_id,
  review_id                                         as representative_review_id,
  source_file || ':' || source_row_number::varchar  as representative_review_source_id,
  review_score                                      as representative_review_score,
  review_creation_ts,
  review_answer_ts,
  review_record_count::int                          as review_record_count,
  source_batch_id
from ranked
where rk = 1
