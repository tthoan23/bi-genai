{#
  Các hàm đổi kiểu dữ liệu an toàn (T-SQL): giá trị sai trả về NULL thay vì làm hỏng cả câu lệnh.
  Staging giữ mọi cột dạng text, nên đây là chỗ đầu tiên dữ liệu được đổi sang ngày, số.
  Lưu ý: SQL Server đổi chuỗi rỗng thành 0 (số) hoặc 1900-01-01 (ngày), nên luôn bọc NULLIF(..., '') trước khi đổi.
#}

{% macro blank_to_null(col) -%}
  nullif(trim({{ col }}), '')
{%- endmacro %}

{# Thời điểm Olist có dạng 'YYYY-MM-DD HH:MM:SS' (style 120). Ngày không tồn tại (ví dụ 30/02) trả NULL. #}
{% macro safe_ts(col) -%}
  try_convert(datetime2(0), {{ blank_to_null(col) }}, 120)
{%- endmacro %}

{# 1 nếu ô có giá trị nhưng đọc không được thành thời điểm; ô trống không tính là lỗi #}
{% macro ts_parse_error(col) -%}
  cast(case when {{ blank_to_null(col) }} is not null and {{ safe_ts(col) }} is null then 1 else 0 end as smallint)
{%- endmacro %}

{% macro safe_num(col, scale=2) -%}
  try_cast({{ blank_to_null(col) }} as decimal(18, {{ scale }}))
{%- endmacro %}

{% macro num_parse_error(col) -%}
  cast(case when {{ blank_to_null(col) }} is not null and {{ safe_num(col) }} is null then 1 else 0 end as smallint)
{%- endmacro %}

{% macro safe_int(col) -%}
  try_cast({{ blank_to_null(col) }} as int)
{%- endmacro %}

{# Mã bưu chính: 1 đến 5 chữ số, thêm số 0 bên trái cho đủ 5 ký tự; giá trị khác trả NULL #}
{% macro norm_zip(col) -%}
  cast(case when trim({{ col }}) not like '%[^0-9]%' and len(trim({{ col }})) between 1 and 5
            then right('00000' + trim({{ col }}), 5) end as varchar(5))
{%- endmacro %}

{#
  Tên thành phố: chữ thường, bỏ dấu tiếng Bồ Đào Nha, gộp khoảng trắng.
  T-SQL trước bản 2025 không có regexp_replace: đổi tab và xuống dòng thành dấu cách,
  rồi gộp nhiều dấu cách thành một bằng 3 lần replace (dùng cặp ký tự đánh dấu char(1), char(2)).
#}
{% macro norm_city(col) -%}
  nullif(trim(
    replace(replace(replace(
      translate(lower(trim({{ col }})),
                N'áàâãäéèêëíìîïóòôõöúùûüç' + nchar(9) + nchar(10) + nchar(13),
                N'aaaaaeeeeiiiiooooouuuuc' + N'   '),
      N' ', nchar(1) + nchar(2)), nchar(2) + nchar(1), N''), nchar(1) + nchar(2), N' ')
  ), N'')
{%- endmacro %}

{#
  Khoá ngày cho fact: YYYYMMDD khi có ngày hợp lệ; -2 = ngày bị lỗi; -1 = mốc chưa xảy ra (theo trạng thái đơn);
  0 = thiếu hoặc không rõ. Ba khoá đặc biệt có sẵn trong dim_date.
#}
{% macro to_date_key(ts, parse_err=none, not_yet=none) -%}
  (case
    {% if parse_err %}when {{ parse_err }} = 1 then -2{% endif %}
    when {{ ts }} is not null then year({{ ts }}) * 10000 + month({{ ts }}) * 100 + day({{ ts }})
    {% if not_yet %}when {{ not_yet }} then -1{% endif %}
    else 0
  end)
{%- endmacro %}
