-- Transform_Clean, nguồn geolocation: đọc nguyên bảng thô. Bỏ dòng trùng làm bằng Sort (Remove duplicates)
-- SAU khi chuẩn hoá, vì hai dòng chỉ khác dấu hoặc hoa/thường sẽ trùng sau khi làm sạch.
SELECT geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city, geolocation_state
FROM staging.geolocation
