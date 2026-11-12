{#
  Bảng map khoá nghiệp vụ (BK) sang khoá thay thế (SK) bền vững.
  - Lần đầu: cấp khoá 1, 2, 3, … theo thứ tự BK.
  - Các lần sau (incremental): CHỈ thêm BK mới, khoá = khoá lớn nhất đang có + thứ tự; khoá đã cấp không bao giờ đổi.
  - Model gọi macro này đặt full_refresh=false, để cả `dbt build --full-refresh` cũng không cấp lại khoá.
#}
{% macro build_keymap(key_col, bk_cols, src_relation) %}
with src as (
  select distinct {{ bk_cols | join(', ') }}
  from {{ src_relation }}
  where {% for c in bk_cols %}{{ c }} is not null{% if not loop.last %} and {% endif %}{% endfor %}
)
{% if is_incremental() %}
, new_bk as (
  select s.* from src s
  where not exists (
    select 1 from {{ this }} t
    where {% for c in bk_cols %}t.{{ c }} = s.{{ c }}{% if not loop.last %} and {% endif %}{% endfor %}
  )
)
select (select coalesce(max({{ key_col }}), 0) from {{ this }})
         + row_number() over (order by {{ bk_cols | join(', ') }}) as {{ key_col }},
       {{ bk_cols | join(', ') }},
       current_timestamp::timestamp as dw_created_at
from new_bk
{% else %}
select row_number() over (order by {{ bk_cols | join(', ') }}) as {{ key_col }},
       {{ bk_cols | join(', ') }},
       current_timestamp::timestamp as dw_created_at
from src
{% endif %}
{% endmacro %}
