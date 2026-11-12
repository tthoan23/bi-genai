-- Khoá thay thế bền vững cho sản phẩm. full_refresh=false: khoá đã cấp không bao giờ bị cấp lại.
{{ config(materialized='incremental', full_refresh=false) }}
{{ build_keymap('product_key', ['product_id'], ref('stg_products')) }}
