{# Dùng đúng tên schema khai báo (staging, intermediate, dwh), không ghép thành "main_staging" như mặc định của dbt #}
{% macro generate_schema_name(custom_schema_name, node) -%}
  {{ custom_schema_name if custom_schema_name else target.schema }}
{%- endmacro %}
