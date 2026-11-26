-- Transform_Business: một dòng cho mỗi mã bưu chính.
-- Thành phố, bang: cặp xuất hiện nhiều nhất (gộp khách, người bán, bảng toạ độ); hoà thì ưu tiên khách, rồi người bán.
-- Toạ độ: trung vị các toạ độ nằm trong khung gần đúng của Brazil. SSIS không có hàm trung vị nên phần này viết bằng SQL;
-- nhãn, cờ xung đột và mã chất lượng toạ độ làm bằng Derived Column.
WITH decl AS (
    SELECT zip_prefix, state, city, 1 AS src_rank FROM intermediate.cln_customers
    UNION ALL SELECT zip_prefix, state, city, 2 FROM intermediate.cln_sellers
    UNION ALL SELECT zip_prefix, state, city, 3 FROM intermediate.cln_geolocation
), zips AS (
    SELECT DISTINCT zip_prefix FROM decl WHERE zip_prefix IS NOT NULL
), pairs AS (
    SELECT zip_prefix, state, city, COUNT(*) AS n, MIN(src_rank) AS best_src
    FROM decl
    WHERE zip_prefix IS NOT NULL AND state IS NOT NULL AND city IS NOT NULL
    GROUP BY zip_prefix, state, city
), ranked AS (
    SELECT p.*,
           ROW_NUMBER() OVER (PARTITION BY zip_prefix
                              ORDER BY n DESC, best_src, state, city COLLATE Latin1_General_100_BIN2) AS rk,
           COUNT(*) OVER (PARTITION BY zip_prefix) AS variant_count
    FROM pairs p
), state_variants AS (
    SELECT zip_prefix, COUNT(DISTINCT state) AS state_count FROM pairs GROUP BY zip_prefix
), coords AS (
    SELECT DISTINCT zip_prefix,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lat) OVER (PARTITION BY zip_prefix) AS lat,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lng) OVER (PARTITION BY zip_prefix) AS lng
    FROM intermediate.cln_geolocation
    WHERE zip_prefix IS NOT NULL AND lat BETWEEN -34 AND 6 AND lng BETWEEN -74 AND -34
)
SELECT z.zip_prefix,
       r.state AS state_code,
       r.city  AS city_normalized,
       CAST(ROUND(c.lat, 7) AS decimal(10, 7)) AS latitude,
       CAST(ROUND(c.lng, 7) AS decimal(10, 7)) AS longitude,
       ISNULL(r.variant_count, 0) AS variant_count,
       ISNULL(sv.state_count, 0)  AS state_count,
       CAST(CASE WHEN c.zip_prefix IS NULL THEN 0 ELSE 1 END AS smallint) AS has_valid_coord
FROM zips z
LEFT JOIN ranked r          ON r.zip_prefix = z.zip_prefix AND r.rk = 1
LEFT JOIN state_variants sv ON sv.zip_prefix = z.zip_prefix
LEFT JOIN coords c          ON c.zip_prefix = z.zip_prefix
