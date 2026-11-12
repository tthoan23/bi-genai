{#
  Các hàm đổi kiểu dữ liệu an toàn: giá trị sai trả về NULL thay vì làm hỏng cả câu lệnh.
  Staging giữ mọi cột dạng text, nên đây là chỗ đầu tiên dữ liệu được đổi sang ngày, số.
#}

{# Thời điểm Olist có dạng 'YYYY-MM-DD HH:MM:SS'. Ngày không tồn tại (ví dụ 30/02) cũng trả NULL. #}
{% macro safe_ts(col) -%}
  try_strptime(trim({{ col }}), '%Y-%m-%d %H:%M:%S')
{%- endmacro %}

{# 1 nếu ô có giá trị nhưng đọc không được thành thời điểm; ô trống không tính là lỗi #}
{% macro ts_parse_error(col) -%}
  (case when nullif(trim({{ col }}), '') is not null and {{ safe_ts(col) }} is null then 1 else 0 end)::smallint
{%- endmacro %}

{% macro safe_num(col, scale=2) -%}
  try_cast(trim({{ col }}) as decimal(18, {{ scale }}))
{%- endmacro %}

{% macro num_parse_error(col) -%}
  (case when nullif(trim({{ col }}), '') is not null and {{ safe_num(col) }} is null then 1 else 0 end)::smallint
{%- endmacro %}

{% macro safe_int(col) -%}
  try_cast(trim({{ col }}) as integer)
{%- endmacro %}

{# Mã bưu chính: 1 đến 5 chữ số, thêm số 0 bên trái cho đủ 5 ký tự; giá trị khác trả NULL #}
{% macro norm_zip(col) -%}
  (case when regexp_full_match(trim({{ col }}), '[0-9]{1,5}') then lpad(trim({{ col }}), 5, '0') end)
{%- endmacro %}

{# Tên thành phố: chữ thường, bỏ dấu tiếng Bồ Đào Nha, gộp khoảng trắng #}
{% macro norm_city(col) -%}
  nullif(regexp_replace(
    translate(lower(trim({{ col }})), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc'),
    '\s+', ' ', 'g'), '')
{%- endmacro %}
