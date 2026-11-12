-- Khoá thay thế bền vững cho người bán. full_refresh=false: khoá đã cấp không bao giờ bị cấp lại.
{{ config(materialized='incremental', full_refresh=false) }}
{{ build_keymap('seller_key', ['seller_id'], ref('stg_sellers')) }}
