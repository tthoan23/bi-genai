-- Khoá thay thế bền vững cho mã bưu chính. full_refresh=false: khoá đã cấp không bao giờ bị cấp lại.
{{ config(materialized='incremental', full_refresh=false) }}
{{ build_keymap('geography_key', ['zip_prefix'], ref('int_geography_canonical')) }}
