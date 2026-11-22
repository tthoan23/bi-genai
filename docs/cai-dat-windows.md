# Cài đặt môi trường SSIS (Windows)

SSIS chỉ chạy trên **Windows x64**. macOS và Linux chạy được SQL Server bằng Docker
(mục 7) nhưng không mở được trình thiết kế SSIS.

## 1. SQL Server 2022 Developer
1. Vào microsoft.com/sql-server/sql-server-downloads, mục **Developer**, bấm **Download now**.
2. Chạy file tải về, chọn **Basic**, bấm **Accept**, rồi **Install**.
3. Màn hình cuối, bấm **Install SSMS** nếu chưa có SSMS.
Mặc định: instance `localhost`, đăng nhập Windows Authentication.

## 2. SSMS 22
Mở SSMS, kết nối: Server name `localhost`, Authentication **Windows Authentication**,
tick **Trust server certificate**, bấm **Connect**.

## 3. Visual Studio 2022 và SSIS
Dùng bản 2022. Visual Studio 2026 dùng chung extension nhưng có người báo lỗi khi triển khai.
1. Cài Visual Studio 2022 Community (workload nào cũng được).
2. Mở VS, menu **Extensions > Manage Extensions > Online**, tìm
   **SQL Server Integration Services Projects 2022+**, bấm **Download**.
3. Đóng hết VS, cửa sổ VSIX Installer hiện ra, bấm **Modify**.
4. Kiểm tra: **File > New > Project**, gõ "Integration Services" phải thấy template.

## 4. Python và dbt-sqlserver
1. Cài Python 3.11 từ python.org, tick **Add python.exe to PATH**.
2. Trong thư mục repo:
       python -m venv .venv
       .venv\Scripts\activate
       pip install dbt-sqlserver
   (nếu có nhiều bản dbt-core, chọn bản dbt-sqlserver ổn định khớp phiên bản dbt-core)
3. Kiểm tra: `dbt --version` phải liệt kê plugin `sqlserver`.

## 5. ODBC Driver 18
Tải "Microsoft ODBC Driver 18 for SQL Server" (msodbcsql.msi) từ trang Microsoft và cài.
Kiểm tra (PowerShell): `Get-OdbcDriver -Name "ODBC Driver 18*"`

## 6. Giới hạn bộ nhớ SQL Server (khuyến nghị cho máy ~8 GB)
Trong SSMS, New Query, chạy:

    EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
    EXEC sp_configure 'max server memory (MB)', 2048; RECONFIGURE;

## 7. Không có Windows: chạy SQL Server bằng Docker
Chỉ chạy được database. Mở và sửa project SSIS vẫn cần Windows.
1. Copy `.env.example` thành `.env`, đặt `MSSQL_SA_PASSWORD` đủ mạnh. Không commit `.env`.
2. `docker compose -f sql_server/docker-compose.yml --env-file .env up -d`
3. Chạy file SQL (làm lần lượt 00, 01, 02):
       docker cp sql_server olist_sqlserver:/tmp/sql
       docker exec olist_sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<mật khẩu>" -C -i /tmp/sql/00_database.sql