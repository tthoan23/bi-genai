// Dựng 7 package SSIS của project OlistETL: Extract -> Validate -> Load Staging -> Transform ->
// Load Dimensions -> Load Facts -> Test. Chạy: powershell -File ssis/tools/build.ps1
// CHÚ Ý: chạy lại sẽ GHI ĐÈ các file .dtsx (mất chỉnh sửa tay trong Visual Studio).
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;

class Problems : DefaultEvents
{
    public int Count;
    public override bool OnError(DtsObject s, int c, string sub, string description, string h, int hc, string id)
    { Count++; Console.WriteLine("    LỖI [" + sub + "] " + description.Trim()); return false; }
    public override void OnWarning(DtsObject s, int c, string sub, string description, string h, int hc, string id)
    { Console.WriteLine("    cảnh báo [" + sub + "] " + description.Trim()); }
}

class BuildOlistEtl
{
    static Project project; static string repo, queries;
    static readonly Application app = new Application();
    const string Batch = "@[$Project::BatchId]";

    static string Q(string name) { return File.ReadAllText(Path.Combine(queries, name + ".sql"), Encoding.UTF8); }
    static string[] A(params string[] a) { return a; }

    static Package NewPackage(string name, string description)
    {
        var p = new Package();
        p.Name = name; p.Description = description;
        p.ProtectionLevel = DTSProtectionLevel.DontSaveSensitive;
        p.LocaleID = 1033;
        project.PackageItems.Add(p, name + ".dtsx");
        return p;
    }

    // Biểu thức SSIS: "EXEC ... N'<batch>' ..." ; sql dùng {batch} cho mã batch
    static string BatchExpr(string sql)
    {
        return "\"" + sql.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("{batch}", "N'\" + " + Batch + " + \"'") + "\"";
    }

    static TaskHost BatchSql(Package p, IDTSSequence parent, string name, string sql)
    {
        return Control.Sql(p, parent, name, sql.Replace("{batch}", "N'FULL_001'"), BatchExpr(sql));
    }

    // Thư mục của batch đang chạy: <RawDir>\<BatchId> (data\batches\FULL_001 ...)
    static string BatchDir() { return "@[$Project::RawDir] + \"\\\\\" + @[$Project::BatchId]"; }

    // Mở batch: tự chọn FULL (lần nạp đầu) hay INCREMENTAL, đọc CET từ _cutoff.txt của batch
    static TaskHost StartRun(Package p)
    {
        return Control.Sql(p, p, "SQL Bat dau batch", "EXEC audit.usp_start_run N'FULL_001';",
            "\"EXEC audit.usp_start_run N'\" + " + Batch + " + \"', N'\" + " + BatchDir() + " + \"';\"");
    }

    static TaskHost LogStep(Package p, string step, params string[] tables)
    {
        var sb = new StringBuilder();
        foreach (var t in tables) sb.Append("EXEC audit.usp_log_step {batch}, '" + step + "', '" + t + "'; ");
        return BatchSql(p, p, "SQL Ghi audit", sb.ToString().Trim());
    }

    // =====================================================================================================
    // 1. Extract, Validate, Load Staging
    // =====================================================================================================
    static Package Ingest()
    {
        var p = NewPackage("Ingest_Staging", "Extract, Validate, Load Staging: 9 file CSV -> staging.*");
        var steps = new List<Executable>();
        steps.Add(StartRun(p));
        var files = new[] {
            A("orders", "olist_orders_dataset.csv", "\n"),
            A("customers", "olist_customers_dataset.csv", "\n"),
            A("order_items", "olist_order_items_dataset.csv", "\n"),
            A("order_reviews", "olist_order_reviews_dataset.csv", "\r\n"),
            A("order_payments", "olist_order_payments_dataset.csv", "\n"),
            A("products", "olist_products_dataset.csv", "\n"),
            A("sellers", "olist_sellers_dataset.csv", "\n"),
            A("geolocation", "olist_geolocation_dataset.csv", "\n"),
            A("category_translation", "product_category_name_translation.csv", "\r\n") };
        var columns = new Dictionary<string, string> {
            {"orders", "order_id,customer_id,order_status,order_purchase_timestamp,order_approved_at,order_delivered_carrier_date,order_delivered_customer_date,order_estimated_delivery_date"},
            {"customers", "customer_id,customer_unique_id,customer_zip_code_prefix,customer_city,customer_state"},
            {"order_items", "order_id,order_item_id,product_id,seller_id,shipping_limit_date,price,freight_value"},
            {"order_reviews", "review_id,order_id,review_score,review_comment_title,review_comment_message,review_creation_date,review_answer_timestamp"},
            {"order_payments", "order_id,payment_sequential,payment_type,payment_installments,payment_value"},
            {"products", "product_id,product_category_name,product_name_lenght,product_description_lenght,product_photos_qty,product_weight_g,product_length_cm,product_height_cm,product_width_cm"},
            {"sellers", "seller_id,seller_zip_code_prefix,seller_city,seller_state"},
            {"geolocation", "geolocation_zip_code_prefix,geolocation_lat,geolocation_lng,geolocation_city,geolocation_state"},
            {"category_translation", "product_category_name,product_category_name_english"} };

        foreach (var f in files)
        {
            string table = f[0], file = f[1];
            string path = BatchDir() + " + \"\\\\" + file + "\"";
            bool watermark = table == "orders" || table == "order_reviews";
            p.Variables.Add("rows_" + table, false, "User", 0);
            p.Variables.Add("skip_" + table, false, "User", 0);
            if (watermark)
            {
                p.Variables.Add("lset_" + table, false, "User", "1900-01-01 00:00:00");
                p.Variables.Add("cet_" + table, false, "User", "9999-12-31 23:59:59");
            }
            var ffName = "FF " + table;
            Control.FlatFile(p, ffName, path, f[2], columns[table].Split(','), table == "order_reviews" ? 1000 : 255);

            var seq = (Sequence)p.Executables.Add("STOCK:SEQUENCE"); seq.Name = "SEQ " + table;
            // Validate: tiêu đề, SHA-256 (file đã nạp thì skip = 1), lấy LSET và CET vào biến
            var validate = Control.Sql(p, seq, "SQL Validate " + table, "SELECT 0 AS skip, '' AS lset, '' AS cet",
                "\"EXEC audit.usp_validate_source N'" + table + "', N'\" + " + path + " + \"', N'\" + " + Batch + " + \"';\"");
            Control.ResultRow(validate, "User::skip_" + table, watermark ? "User::lset_" + table : null,
                watermark ? "User::cet_" + table : null);

            var flow = new Flow(p, seq, "DFT " + table);
            var n = flow.FileSource("FF Source " + table, ffName);
            // Dòng lỗi -> audit.reject_row (giữ nguyên nội dung dòng), các dòng khác vẫn tiếp tục
            var bad = flow.RedirectErrors(n);
            bad = flow.Derive("DER Dong loi", bad,
                new Col("batch_id", "s100", Batch), new Col("table_name", "w128", "\"" + table + "\""),
                new Col("stage", "s20", "\"extract\""));
            bad = flow.Convert("CNV Noi dung dong", bad, "Flat File Source Error Output Column>raw_data:ntext");
            flow.Destination("DST reject_row", bad, "[audit].[reject_row]",
                A("error_code=ErrorCode", "error_column=ErrorColumn"),
                "reject_id", "run_id", "source_row_number", "error_description", "rejected_at");
            n = flow.RowCount("Row Count", n, "User::rows_" + table);
            var trace = new List<Col> {
                new Col("source_file", "w260", "\"" + file + "\""),
                new Col("source_batch_id", "s100", Batch) };
            if (watermark)
            {
                // Incremental Extract: dòng có mốc thời gian nằm trong (LSET, CET]
                var stamps = table == "orders"
                    ? A("order_purchase_timestamp", "order_approved_at", "order_delivered_carrier_date", "order_delivered_customer_date")
                    : A("review_answer_timestamp");
                var any = new List<string>();
                foreach (var c in stamps)
                    any.Add("(REPLACENULL({" + c + "},\"\") > @[User::lset_" + table + "] && REPLACENULL({" + c + "},\"\") <= @[User::cet_" + table + "])");
                trace.Add(new Col("in_window", "bool", string.Join(" || ", any.ToArray())));
            }
            n = flow.Derive("DER Cot truy vet", n, trace.ToArray());
            var skipped = new List<string> { "source_checksum", "source_row_number", "ingested_at" };
            if (!watermark) skipped.Add("in_window");
            flow.Destination("DST " + table + "_load", n, "[staging].[" + table + "_load]", null, skipped.ToArray());

            var finish = Control.Sql(p, seq, "SQL Swap va audit " + table, "SELECT 1",
                "\"EXEC audit.usp_finish_ingest N'\" + " + Batch + " + \"', N'" + table + "', N'\" + " + path +
                " + \"', \" + (DT_WSTR,20)@[User::rows_" + table + "] + \";\"");
            // File đã nạp ở batch thành công trước (skip = 1): bỏ qua Data Flow và bước chuyển
            Control.ChainIf(seq, validate, flow.Task, "@[User::skip_" + table + "] == 0");
            Control.Chain(seq, new List<Executable> { flow.Task, finish });
            steps.Add(seq);
        }
        steps.Add(BatchSql(p, p, "SQL Danh dau INGESTED", "EXEC audit.usp_finish_staging {batch};"));
        Control.Chain(p, steps);
        return p;
    }

    // =====================================================================================================
    // 2. Transform: làm sạch
    // =====================================================================================================
    static string Trim(string c) { return "TRIM({" + c + "})"; }
    // TRIM rồi đổi chuỗi rỗng thành NULL
    static string Blank(string c, int len)
    { return "REPLACENULL(TRIM({" + c + "}),\"\") == \"\" ? NULL(DT_WSTR," + len + ") : (DT_WSTR," + len + ")TRIM({" + c + "})"; }
    static string ParseError(string raw, string converted)
    { return "!ISNULL({" + raw + "}) && ISNULL({" + converted + "}) ? 1 : 0"; }
    static string Zip(string c)
    {
        var digits = "TRIM({" + c + "})";
        for (int d = 0; d <= 9; d++) digits = "REPLACE(" + digits + ",\"" + d + "\",\"\")";
        return "ISNULL({" + c + "}) ? NULL(DT_WSTR,5) : (LEN(TRIM({" + c + "})) >= 1 && LEN(TRIM({" + c + "})) <= 5 && LEN(" + digits +
               ") == 0 ? (DT_WSTR,5)RIGHT(\"00000\" + TRIM({" + c + "}),5) : NULL(DT_WSTR,5))";
    }
    // Bước 1: chữ thường, bỏ dấu tiếng Bồ Đào Nha, tab và xuống dòng thành dấu cách
    static string CityStep1(string c)
    {
        string from = "áàâãäéèêëíìîïóòôõöúùûüç", to = "aaaaaeeeeiiiiooooouuuuc";
        var e = "LOWER(TRIM({" + c + "}))";
        for (int k = 0; k < from.Length; k++) e = "REPLACE(" + e + ",\"" + from[k] + "\",\"" + to[k] + "\")";
        foreach (var w in A("\\t", "\\n", "\\r")) e = "REPLACE(" + e + ",\"" + w + "\",\" \")";
        return e;
    }
    // Bước 2: gộp nhiều dấu cách thành một (đánh dấu bằng \x0001 \x0002), chuỗi rỗng thành NULL
    static string CityStep2(string c)
    {
        var e = "TRIM(REPLACE(REPLACE(REPLACE({" + c + "},\" \",\"\\x0001\\x0002\"),\"\\x0002\\x0001\",\"\"),\"\\x0001\\x0002\",\" \"))";
        return "REPLACENULL(" + e + ",\"\") == \"\" ? NULL(DT_WSTR,255) : (DT_WSTR,255)" + e;
    }
    static Col State(string c) { return new Col("state_c", "w255", "REPLACENULL(TRIM({" + c + "}),\"\") == \"\" ? NULL(DT_WSTR,255) : (DT_WSTR,255)UPPER(TRIM({" + c + "}))"); }

    static Package Clean()
    {
        var p = NewPackage("Transform_Clean", "Transform (làm sạch): staging.* -> intermediate.cln_*");
        var tables = A("orders", "customers", "order_items", "order_reviews", "order_payments", "products", "sellers", "geolocation", "category_translation");
        var truncate = "";
        foreach (var t in tables) truncate += "TRUNCATE TABLE intermediate.cln_" + t + "; ";
        var steps = new List<Executable> {
            BatchSql(p, p, "SQL Ghi dong thieu khoa", "EXEC audit.usp_log_missing_keys {batch};"),
            Control.Sql(p, p, "SQL Don bang cln", truncate.Trim(), null) };
        Func<string, Flow> flowFor = delegate(string t) { var f = new Flow(p, p, "DFT cln_" + t); steps.Add(f.Task); return f; };
        Func<Flow, string, Node> source = delegate(Flow f, string t) { return f.OleSource("SRC " + t, "OlistDW", Q("src_" + t)); };

        { // orders
            var f = flowFor("orders"); var n = source(f, "orders");
            var ts = A("purchase|order_purchase_timestamp", "approved|order_approved_at", "carrier|order_delivered_carrier_date",
                       "delivered|order_delivered_customer_date", "estimated|order_estimated_delivery_date");
            var cols = new List<Col> {
                new Col("order_id_c", "w255", Trim("order_id")), new Col("customer_id_c", "w255", Trim("customer_id")),
                new Col("order_status_c", "w255", "LOWER(TRIM({order_status}))") };
            var conv = new List<string>(); var errs = new List<Col>();
            foreach (var s in ts)
            {
                var a = s.Split('|');
                cols.Add(new Col(a[0] + "_raw", "w255", Blank(a[1], 255)));
                conv.Add(a[0] + "_raw>" + a[0] + "_ts:ts");
                errs.Add(new Col(a[0] + "_ts_parse_error", "i2", ParseError(a[0] + "_raw", a[0] + "_ts")));
            }
            n = f.Derive("DER Chuan hoa", n, cols.ToArray());
            n = f.Convert("CNV Doi kieu ngay gio", n, conv.ToArray());
            n = f.Derive("DER Co loi", n, errs.ToArray());
            f.Destination("DST cln_orders", n, "[intermediate].[cln_orders]",
                A("order_id=order_id_c", "customer_id=customer_id_c", "order_status=order_status_c"));
        }
        { // customers
            var f = flowFor("customers"); var n = source(f, "customers");
            n = f.Derive("DER Chuan hoa", n,
                new Col("customer_id_c", "w255", Trim("customer_id")), new Col("customer_unique_id_c", "w255", Trim("customer_unique_id")),
                new Col("zip_prefix", "w5", Zip("customer_zip_code_prefix")), new Col("city_step1", "w255", CityStep1("customer_city")),
                State("customer_state"));
            n = f.Derive("DER Ten thanh pho", n, new Col("city_c", "w255", CityStep2("city_step1")));
            f.Destination("DST cln_customers", n, "[intermediate].[cln_customers]",
                A("customer_id=customer_id_c", "customer_unique_id=customer_unique_id_c", "city=city_c", "state=state_c"));
        }
        { // order_items
            var f = flowFor("order_items"); var n = source(f, "order_items");
            n = f.Derive("DER Chuan hoa", n,
                new Col("order_id_c", "w255", Trim("order_id")), new Col("product_id_c", "w255", Trim("product_id")),
                new Col("seller_id_c", "w255", Trim("seller_id")), new Col("item_raw", "w255", Blank("order_item_id", 255)),
                new Col("shipping_raw", "w255", Blank("shipping_limit_date", 255)), new Col("price_raw", "w255", Blank("price", 255)),
                new Col("freight_raw", "w255", Blank("freight_value", 255)));
            n = f.Convert("CNV Doi kieu", n, "item_raw>order_item_id_n:i4", "shipping_raw>shipping_limit_ts:ts",
                "price_raw>price_amount:n18,2", "freight_raw>freight_amount:n18,2");
            n = f.Derive("DER Co loi", n,
                new Col("shipping_limit_parse_error", "i2", ParseError("shipping_raw", "shipping_limit_ts")),
                new Col("price_parse_error", "i2", ParseError("price_raw", "price_amount")),
                new Col("freight_parse_error", "i2", ParseError("freight_raw", "freight_amount")));
            f.Destination("DST cln_order_items", n, "[intermediate].[cln_order_items]",
                A("order_id=order_id_c", "order_item_id=order_item_id_n", "product_id=product_id_c", "seller_id=seller_id_c"));
        }
        { // order_reviews
            var f = flowFor("order_reviews"); var n = source(f, "order_reviews");
            var valid = "(TRIM({review_score}) == \"1\" || TRIM({review_score}) == \"2\" || TRIM({review_score}) == \"3\" || TRIM({review_score}) == \"4\" || TRIM({review_score}) == \"5\")";
            Func<string, string> keep = delegate(string c) { return "REPLACENULL(LEN({" + c + "}),0) == 0 ? NULL(DT_WSTR,1000) : {" + c + "}"; };
            n = f.Derive("DER Chuan hoa", n,
                new Col("review_id_c", "w255", Trim("review_id")), new Col("order_id_c", "w255", Trim("order_id")),
                new Col("score_raw", "w255", "REPLACENULL(" + valid + ",FALSE) ? (DT_WSTR,255)TRIM({review_score}) : NULL(DT_WSTR,255)"),
                new Col("invalid_score_flag", "i2", "REPLACENULL(TRIM({review_score}),\"\") != \"\" && !REPLACENULL(" + valid + ",FALSE) ? 1 : 0"),
                new Col("title_c", "w1000", keep("review_comment_title")), new Col("message_c", "w1000", keep("review_comment_message")),
                new Col("creation_raw", "w255", Blank("review_creation_date", 255)), new Col("answer_raw", "w255", Blank("review_answer_timestamp", 255)));
            n = f.Convert("CNV Doi kieu", n, "score_raw>review_score_n:i2", "creation_raw>review_creation_ts:ts", "answer_raw>review_answer_ts:ts");
            f.Destination("DST cln_order_reviews", n, "[intermediate].[cln_order_reviews]",
                A("review_id=review_id_c", "order_id=order_id_c", "review_score=review_score_n",
                  "review_comment_title=title_c", "review_comment_message=message_c"));
        }
        { // order_payments
            var f = flowFor("order_payments"); var n = source(f, "order_payments");
            n = f.Derive("DER Chuan hoa", n,
                new Col("order_id_c", "w255", Trim("order_id")), new Col("type_c", "w255", Blank("payment_type", 255)),
                new Col("seq_raw", "w255", Blank("payment_sequential", 255)), new Col("inst_raw", "w255", Blank("payment_installments", 255)),
                new Col("value_raw", "w255", Blank("payment_value", 255)));
            n = f.Convert("CNV Doi kieu", n, "seq_raw>payment_sequential_n:i4", "inst_raw>payment_installments_n:i4", "value_raw>payment_value_n:n18,2");
            f.Destination("DST cln_order_payments", n, "[intermediate].[cln_order_payments]",
                A("order_id=order_id_c", "payment_sequential=payment_sequential_n", "payment_type=type_c",
                  "payment_installments=payment_installments_n", "payment_value=payment_value_n"));
        }
        { // products
            var f = flowFor("products"); var n = source(f, "products");
            n = f.Derive("DER Chuan hoa", n,
                new Col("product_id_c", "w255", Trim("product_id")),
                new Col("category_name", "w255", "REPLACENULL(TRIM({product_category_name}),\"\") == \"\" ? NULL(DT_WSTR,255) : (DT_WSTR,255)LOWER(TRIM({product_category_name}))"),
                new Col("weight_raw", "w255", Blank("product_weight_g", 255)), new Col("length_raw", "w255", Blank("product_length_cm", 255)),
                new Col("height_raw", "w255", Blank("product_height_cm", 255)), new Col("width_raw", "w255", Blank("product_width_cm", 255)));
            n = f.Convert("CNV Doi kieu", n, "weight_raw>weight_n:n18,3", "length_raw>length_n:n18,3", "height_raw>height_n:n18,3", "width_raw>width_n:n18,3");
            f.Destination("DST cln_products", n, "[intermediate].[cln_products]",
                A("product_id=product_id_c", "product_weight_g=weight_n", "product_length_cm=length_n",
                  "product_height_cm=height_n", "product_width_cm=width_n"));
        }
        { // sellers
            var f = flowFor("sellers"); var n = source(f, "sellers");
            n = f.Derive("DER Chuan hoa", n,
                new Col("seller_id_c", "w255", Trim("seller_id")), new Col("zip_prefix", "w5", Zip("seller_zip_code_prefix")),
                new Col("city_step1", "w255", CityStep1("seller_city")), State("seller_state"));
            n = f.Derive("DER Ten thanh pho", n, new Col("city_c", "w255", CityStep2("city_step1")));
            f.Destination("DST cln_sellers", n, "[intermediate].[cln_sellers]", A("seller_id=seller_id_c", "city=city_c", "state=state_c"));
        }
        { // geolocation
            var f = flowFor("geolocation"); var n = source(f, "geolocation");
            n = f.Derive("DER Chuan hoa", n,
                new Col("zip_prefix", "w5", Zip("geolocation_zip_code_prefix")), new Col("city_step1", "w255", CityStep1("geolocation_city")),
                State("geolocation_state"), new Col("lat_raw", "w255", Blank("geolocation_lat", 255)), new Col("lng_raw", "w255", Blank("geolocation_lng", 255)));
            n = f.Derive("DER Ten thanh pho", n, new Col("city_c", "w255", CityStep2("city_step1")));
            n = f.Convert("CNV Toa do chinh xac", n, "lat_raw>lat_full:n38,24", "lng_raw>lng_full:n38,24");
            n = f.Derive("DER Lam tron 7 so", n, new Col("lat", "n18,7", "ROUND({lat_full},7)").AllowTruncation(), new Col("lng", "n18,7", "ROUND({lng_full},7)").AllowTruncation());
            n = f.SortDistinct("SRT Bo dong trung", n, "zip_prefix", "lat", "lng", "city_c", "state_c");
            f.Destination("DST cln_geolocation", n, "[intermediate].[cln_geolocation]", A("city=city_c", "state=state_c"));
        }
        { // category_translation
            var f = flowFor("category_translation"); var n = source(f, "category_translation");
            n = f.Derive("DER Chuan hoa", n,
                new Col("category_name", "w255", "LOWER(TRIM({product_category_name}))"),
                new Col("category_name_english", "w255", "REPLACENULL(TRIM({product_category_name_english}),\"\") == \"\" ? NULL(DT_WSTR,255) : (DT_WSTR,255)TRIM({product_category_name_english})") );
            // cột đầu ra trùng tên cột nguồn: ghép rõ ràng để lấy cột đã làm sạch
            f.Destination("DST cln_category_translation", n, "[intermediate].[cln_category_translation]", null);
        }
        var names = new List<string>(); foreach (var t in tables) names.Add("intermediate.cln_" + t);
        steps.Add(LogStep(p, "transform", names.ToArray()));
        Control.Chain(p, steps);
        return p;
    }

    // =====================================================================================================
    // 3. Transform: nghiệp vụ
    // =====================================================================================================
    static Package Business()
    {
        var p = NewPackage("Transform_Business", "Transform (nghiệp vụ): intermediate.cln_* -> intermediate.int_*");
        var tables = A("int_order_customer_map", "int_order_item_summary", "int_order_payment_summary", "int_order_payment_reconciliation",
                       "int_order_timeline", "int_order_review_representative", "int_geography_canonical");
        var truncate = ""; foreach (var t in tables) truncate += "TRUNCATE TABLE intermediate." + t + "; ";
        var steps = new List<Executable> { Control.Sql(p, p, "SQL Don bang int", truncate.Trim(), null) };
        Func<string, Flow> flowFor = delegate(string t) { var f = new Flow(p, p, "DFT " + t); steps.Add(f.Task); return f; };

        {
            var f = flowFor("int_order_customer_map");
            var n = f.OleSource("SRC cln_orders", "OlistDW", "SELECT order_id, customer_id FROM intermediate.cln_orders");
            n = f.Lookup("LKP Khach cua don", n, "SELECT customer_id, customer_unique_id, zip_prefix FROM intermediate.cln_customers",
                A("customer_id=customer_id"), A("customer_id>lk_customer_id", "customer_unique_id>customer_unique_id", "zip_prefix>customer_zip_prefix"));
            n = f.Derive("DER Co thieu khach", n, new Col("missing_customer_flag", "i2", "ISNULL({lk_customer_id}) ? 1 : 0"));
            f.Destination("DST int_order_customer_map", n, "[intermediate].[int_order_customer_map]", null);
        }
        {
            var f = flowFor("int_order_item_summary");
            var n = f.OleSource("SRC cln_order_items", "OlistDW", "SELECT order_id, seller_id, price_amount, freight_amount FROM intermediate.cln_order_items");
            n = f.Derive("DER Du so tien", n, new Col("complete", "i4", "!ISNULL({price_amount}) && !ISNULL({freight_amount}) ? 1 : 0"));
            n = f.Aggregate("AGG Theo don", n, "order_id|group|order_id", "order_id|countall|line_count", "seller_id|countdistinct|seller_cnt",
                "price_amount|sum|goods_sum", "freight_amount|sum|freight_sum", "complete|min|complete_min");
            n = f.Derive("DER Kieu dich", n,
                new Col("item_line_count", "i4", "{line_count}"), new Col("seller_count", "i4", "{seller_cnt}"),
                new Col("goods_value", "n18,2", "{goods_sum}"), new Col("freight_value", "n18,2", "{freight_sum}"),
                new Col("amounts_complete", "i2", "{complete_min}"));
            f.Destination("DST int_order_item_summary", n, "[intermediate].[int_order_item_summary]", null);
        }
        {
            var f = flowFor("int_order_payment_summary");
            var n = f.OleSource("SRC cln_order_payments", "OlistDW", "SELECT order_id, payment_value FROM intermediate.cln_order_payments");
            n = f.Derive("DER Co so tien", n, new Col("complete", "i4", "ISNULL({payment_value}) ? 0 : 1"));
            n = f.Aggregate("AGG Theo don", n, "order_id|group|order_id", "payment_value|sum|total_sum", "complete|min|complete_min");
            n = f.Derive("DER Kieu dich", n, new Col("payment_total", "n18,2", "{total_sum}"), new Col("payment_complete", "i2", "{complete_min}"));
            f.Destination("DST int_order_payment_summary", n, "[intermediate].[int_order_payment_summary]", null);
        }
        {
            var f = flowFor("int_order_payment_reconciliation");
            var n = f.OleSource("SRC Thanh toan va hang", "OlistDW", Q("src_payment_reconciliation"));
            n = f.Derive("DER Tien hang va phi", n, new Col("goods_plus_freight", "n18,2", "{goods_value} + {freight_value}"));
            var both = "REPLACENULL({payment_complete},0) == 1 && REPLACENULL({amounts_complete},0) == 1";
            n = f.Derive("DER Chenh lech va co", n,
                new Col("diff_brl", "n18,2", "{payment_total} - {goods_plus_freight}"),
                new Col("mismatch_gt_threshold", "i4", both + " ? (ABS({payment_total} - {goods_plus_freight}) > 0.01 ? 1 : 0) : NULL(DT_I4)"),
                new Col("mismatch_gt_1brl", "i4", both + " ? (ABS({payment_total} - {goods_plus_freight}) > 1.00 ? 1 : 0) : NULL(DT_I4)"));
            f.Destination("DST int_order_payment_reconciliation", n, "[intermediate].[int_order_payment_reconciliation]", null);
        }
        {
            var f = flowFor("int_order_timeline");
            var n = f.OleSource("SRC cln_orders", "OlistDW",
                "SELECT order_id, customer_id, order_status, purchase_ts, approved_ts, carrier_ts, delivered_ts, estimated_ts,\r\n" +
                "       purchase_ts_parse_error, approved_ts_parse_error, carrier_ts_parse_error, delivered_ts_parse_error, estimated_ts_parse_error,\r\n" +
                "       source_batch_id\r\nFROM intermediate.cln_orders");
            Func<string, string, string> before = delegate(string a, string b)
            { return "REPLACENULL({" + a + "} < {" + b + "},FALSE) ? 1 : 0"; };
            Func<string, string, string> days = delegate(string a, string c) { return "DATEDIFF(\"day\",{" + a + "},{" + c + "})"; };
            n = f.Derive("DER Co thu tu", n,
                new Col("delivered_count", "i2", "REPLACENULL({order_status},\"\") == \"delivered\" ? 1 : 0"),
                new Col("invalid_approval_sequence", "i2", before("approved_ts", "purchase_ts")),
                new Col("invalid_handling_sequence", "i2", before("carrier_ts", "approved_ts")),
                new Col("invalid_transit_sequence", "i2", before("delivered_ts", "carrier_ts")),
                new Col("invalid_delivery_sequence", "i2", before("delivered_ts", "purchase_ts")),
                new Col("invalid_estimated_date", "i2",
                    "REPLACENULL(" + days("purchase_ts", "estimated_ts") + " < 0,FALSE) ? 1 : 0"));
            n = f.Derive("DER Du dieu kien xet giao", n,
                new Col("delivery_eligible_count", "i2",
                    "{delivered_count} == 1 && REPLACENULL(" + days("purchase_ts", "delivered_ts") + " >= 0,FALSE) && REPLACENULL(" +
                    days("purchase_ts", "estimated_ts") + " >= 0,FALSE) ? 1 : 0"));
            var late = days("estimated_ts", "delivered_ts");
            Func<string, string, string> seconds = delegate(string a, string c)
            { return "!ISNULL({" + a + "}) && !ISNULL({" + c + "}) && {" + c + "} >= {" + a + "} ? DATEDIFF(\"second\",{" + a + "},{" + c + "}) : NULL(DT_I4)"; };
            n = f.Derive("DER Tre han va thoi gian", n,
                new Col("late_count", "i2", "{delivery_eligible_count} == 1 && REPLACENULL(" + late + " > 0,FALSE) ? 1 : 0"),
                new Col("on_time_count", "i2", "{delivery_eligible_count} == 1 && REPLACENULL(" + late + " <= 0,FALSE) ? 1 : 0"),
                new Col("late_days", "i4", "{delivery_eligible_count} == 1 ? (" + late + " > 0 ? " + late + " : 0) : NULL(DT_I4)"),
                new Col("approval_seconds", "i4", seconds("purchase_ts", "approved_ts")),
                new Col("handling_seconds", "i4", seconds("approved_ts", "carrier_ts")),
                new Col("transit_seconds", "i4", seconds("carrier_ts", "delivered_ts")),
                new Col("delivery_seconds", "i4", seconds("purchase_ts", "delivered_ts")),
                new Col("outcome_code", "w20",
                    "{delivery_eligible_count} == 0 ? \"NOT_ELIGIBLE\" : (" + late + " <= 0 ? \"ON_TIME\" : (" + late + " <= 3 ? \"LATE_1_3\" : (" + late + " <= 7 ? \"LATE_4_7\" : \"LATE_GT7\")))"),
                new Col("quality_issue_count", "i4",
                    "(DT_I4){invalid_approval_sequence} + {invalid_handling_sequence} + {invalid_transit_sequence} + {invalid_delivery_sequence} + {invalid_estimated_date} + {purchase_ts_parse_error} + {approved_ts_parse_error} + {carrier_ts_parse_error} + {delivered_ts_parse_error} + {estimated_ts_parse_error}"));
            f.Destination("DST int_order_timeline", n, "[intermediate].[int_order_timeline]", null);
        }
        {
            var f = flowFor("int_order_review_representative");
            var n = f.OleSource("SRC Danh gia dai dien", "OlistDW", Q("src_order_review_representative"));
            n = f.Derive("DER Ma nguon", n, new Col("representative_review_source_id", "w300", "{source_file} + \":\" + (DT_WSTR,20){source_row_number}"));
            f.Destination("DST int_order_review_representative", n, "[intermediate].[int_order_review_representative]", null);
        }
        {
            var f = flowFor("int_geography_canonical");
            var n = f.OleSource("SRC Ma buu chinh", "OlistDW", Q("src_geography_canonical"));
            n = f.Derive("DER Nhan va co", n,
                new Col("country_code", "w2", "\"BR\""),
                new Col("city_state_label", "w520", "{city_normalized} + \" - \" + {state_code}"),
                new Col("location_conflict_flag", "i2", "{variant_count} > 1 ? 1 : 0"),
                new Col("state_conflict_flag", "i2", "{state_count} > 1 ? 1 : 0"),
                new Col("coordinate_quality_code", "w20", "{has_valid_coord} == 0 ? \"NO_VALID_COORD\" : \"MEDIAN_OF_VALID\""));
            f.Destination("DST int_geography_canonical", n, "[intermediate].[int_geography_canonical]", null);
        }
        steps.Add(BatchSql(p, p, "SQL Don hang bi anh huong", "EXEC audit.usp_build_affected_orders {batch};"));
        var names = new List<string> { "intermediate.affected_orders" }; foreach (var t in tables) names.Add("intermediate." + t);
        steps.Add(LogStep(p, "transform", names.ToArray()));
        Control.Chain(p, steps);
        return p;
    }

    // =====================================================================================================
    // 4. Load Dimensions
    // =====================================================================================================
    // dw_created_at, dw_updated_at không tính trong SSIS: bảng đích có DEFAULT SYSDATETIME()

    static Package Dimensions()
    {
        var p = NewPackage("Load_Dimensions", "Load Dimensions: chèn khoá nghiệp vụ mới (khoá IDENTITY không đổi), cập nhật thuộc tính (SCD 1)");
        var steps = new List<Executable>();
        Func<string, Flow> flowFor = delegate(string t) { var f = new Flow(p, p, "DFT " + t); steps.Add(f.Task); return f; };
        string seeds = "@[$Project::RawDir] + \"\\\\..\\\\..\\\\olist_dbt\\\\seeds\\\\";

        Control.FlatFile(p, "FF seed_order_status", seeds + "seed_order_status.csv\"", "\r\n", A("status_key", "order_status", "status_label", "status_group"), 50);
        Control.FlatFile(p, "FF seed_delivery_outcome", seeds + "seed_delivery_outcome.csv\"", "\r\n", A("outcome_key", "outcome_code", "outcome_label", "sort_order"), 50);
        {
            var f = flowFor("dim_order_status");
            var n = f.FileSource("FF Source seed_order_status", "FF seed_order_status");
            n = f.Convert("CNV Khoa", n, "status_key>status_key_n:i2");
            var s = f.LookupSplit("LKP Trang thai da co", n, "SELECT order_status FROM dwh.dim_order_status", A("order_status=order_status"), A());
            f.Destination("DST dim_order_status", s[1], "[dwh].[dim_order_status]", A("status_key=status_key_n"));
        }
        {
            var f = flowFor("dim_delivery_outcome");
            var n = f.FileSource("FF Source seed_delivery_outcome", "FF seed_delivery_outcome");
            n = f.Convert("CNV Khoa", n, "outcome_key>outcome_key_n:i2", "sort_order>sort_order_n:i2", "outcome_code>outcome_code_n:w20");
            var s = f.LookupSplit("LKP Nhom da co", n, "SELECT outcome_code FROM dwh.dim_delivery_outcome", A("outcome_code_n=outcome_code"), A());
            f.Destination("DST dim_delivery_outcome", s[1], "[dwh].[dim_delivery_outcome]",
                A("outcome_key=outcome_key_n", "outcome_code=outcome_code_n", "sort_order=sort_order_n"));
        }
        steps.Add(Control.Sql(p, p, "SQL Dung dim_date", "EXEC audit.usp_build_dim_date;", null));
        foreach (var d in new[] { A("dim_customer", "customer_unique_id", "cln_customers"), A("dim_seller", "seller_id", "cln_sellers") })
        {
            var f = flowFor(d[0]);
            var n = f.OleSource("SRC " + d[2], "OlistDW",
                "SELECT DISTINCT " + d[1] + " FROM intermediate." + d[2] + " WHERE " + d[1] + " IS NOT NULL ORDER BY " + d[1]);
            var s = f.LookupSplit("LKP Khoa da co", n, "SELECT " + d[1] + " FROM dwh." + d[0], A(d[1] + "=" + d[1]), A());
            n = f.Derive("DER Nguon du lieu", s[1], new Col("source_system", "w20", "\"olist_kaggle\""));
            f.Destination("DST " + d[0], n, "[dwh].[" + d[0] + "]", null, d[0].Substring(4) + "_key", "dw_created_at", "dw_updated_at");
        }
        {
            var f = flowFor("dim_product");
            var n = f.OleSource("SRC cln_products", "OlistDW",
                "SELECT product_id, category_name, product_weight_g, product_length_cm, product_height_cm, product_width_cm\r\nFROM intermediate.cln_products ORDER BY product_id");
            n = f.Lookup("LKP Ten tieng Anh", n, "SELECT category_name, category_name_english FROM intermediate.cln_category_translation",
                A("category_name=category_name"), A("category_name_english>english"));
            n = f.Derive("DER Danh muc", n,
                new Col("category_name_original", "w255", "ISNULL({category_name}) ? \"Missing Category\" : {category_name}"),
                new Col("category_name_english", "w255", "ISNULL({category_name}) ? \"Missing Category\" : (ISNULL({english}) ? {category_name} : {english})"),
                new Col("missing_category_flag", "i2", "ISNULL({category_name}) ? 1 : 0"),
                new Col("missing_translation_flag", "i2", "!ISNULL({category_name}) && ISNULL({english}) ? 1 : 0"));
            var attrs = A("category_name_original", "category_name_english", "product_weight_g", "product_length_cm",
                          "product_height_cm", "product_width_cm", "missing_category_flag", "missing_translation_flag");
            var s = f.LookupSplit("LKP San pham da co", n,
                "SELECT product_key, product_id, " + string.Join(", ", attrs) + " FROM dwh.dim_product", A("product_id=product_id"),
                OldColumns("product_key", attrs));
            f.Destination("DST dim_product (moi)", s[1], "[dwh].[dim_product]", null, "product_key", "dw_created_at", "dw_updated_at");
            var changed = f.Where("CSPL Co thay doi", s[0], "Thay doi",
                Differs("category_name_original", "s") + " || " + Differs("category_name_english", "s") + " || " +
                Differs("product_weight_g", "n18,3") + " || " + Differs("product_length_cm", "n18,3") + " || " +
                Differs("product_height_cm", "n18,3") + " || " + Differs("product_width_cm", "n18,3") + " || " +
                Differs("missing_category_flag", "i") + " || " + Differs("missing_translation_flag", "i"));
            f.Command("CMD Cap nhat SCD1", changed, UpdateSql("dwh.dim_product", "product_key", attrs), WithKey(attrs, "old_product_key"));
        }
        {
            var f = flowFor("dim_geography");
            var attrs = A("country_code", "state_code", "city_normalized", "city_state_label", "latitude", "longitude",
                          "variant_count", "location_conflict_flag", "state_conflict_flag", "coordinate_quality_code");
            var n = f.OleSource("SRC int_geography_canonical", "OlistDW",
                "SELECT zip_prefix, " + string.Join(", ", attrs) + "\r\nFROM intermediate.int_geography_canonical ORDER BY zip_prefix");
            var s = f.LookupSplit("LKP Ma buu chinh da co", n,
                "SELECT geography_key, zip_prefix, " + string.Join(", ", attrs) + " FROM dwh.dim_geography", A("zip_prefix=zip_prefix"),
                OldColumns("geography_key", attrs));
            f.Destination("DST dim_geography (moi)", s[1], "[dwh].[dim_geography]", null, "geography_key", "dw_created_at", "dw_updated_at");
            var test = new List<string>();
            foreach (var a in attrs)
                test.Add(Differs(a, a == "latitude" || a == "longitude" ? "n10,7" : (a == "variant_count" || a.EndsWith("_flag")) ? "i" : "s"));
            var changed = f.Where("CSPL Co thay doi", s[0], "Thay doi", string.Join(" || ", test.ToArray()));
            f.Command("CMD Cap nhat SCD1", changed, UpdateSql("dwh.dim_geography", "geography_key", attrs), WithKey(attrs, "old_geography_key"));
        }
        steps.Add(StampDates(p, "dwh.dim_customer", "dwh.dim_seller", "dwh.dim_product", "dwh.dim_geography"));
        steps.Add(LogStep(p, "load_dim", "dwh.dim_date", "dwh.dim_order_status", "dwh.dim_delivery_outcome", "dwh.dim_customer",
            "dwh.dim_seller", "dwh.dim_product", "dwh.dim_geography"));
        Control.Chain(p, steps);
        return p;
    }

    // Điền thời điểm nạp cho dòng vừa chèn (dw_created_at còn trống). Không tính trong Data Flow:
    // ép GETDATE() về datetime2(0) bị SSIS coi là truncation. Cập nhật SCD1 tự đặt dw_updated_at.
    static TaskHost StampDates(Package p, params string[] tables)
    {
        var sb = new StringBuilder();
        foreach (var t in tables)
            sb.Append("UPDATE " + t + " SET dw_created_at = SYSDATETIME(), dw_updated_at = COALESCE(dw_updated_at, SYSDATETIME()) WHERE dw_created_at IS NULL; ");
        return Control.Sql(p, p, "SQL Gan thoi diem nap", sb.ToString().Trim(), null);
    }

    static string[] OldColumns(string key, string[] attrs)
    {
        var r = new List<string> { key + ">old_" + key };
        foreach (var a in attrs) r.Add(a + ">old_" + a);
        return r.ToArray();
    }
    static string Differs(string c, string type)
    {
        string empty = type == "s" ? "\"~NULL~\"" : type == "i" ? "-1" : "(DT_NUMERIC," + type.Substring(1) + ")(-999)";
        return "REPLACENULL({" + c + "}," + empty + ") != REPLACENULL({old_" + c + "}," + empty + ")";
    }
    static string UpdateSql(string table, string key, string[] attrs)
    {
        var set = new List<string>(); foreach (var a in attrs) set.Add(a + " = ?");
        return "UPDATE " + table + " SET " + string.Join(", ", set.ToArray()) + ", dw_updated_at = SYSDATETIME() WHERE " + key + " = ?";
    }
    static string[] WithKey(string[] attrs, string key) { var r = new List<string>(attrs); r.Add(key); return r.ToArray(); }

    // =====================================================================================================
    // 5. Load Facts
    // =====================================================================================================
    // Khoá ngày YYYYMMDD; -2 ngày lỗi; -1 mốc chưa xảy ra (theo trạng thái đơn); 0 thiếu
    static string DateKey(string ts, string error, string[] notYet)
    {
        var tail = "0";
        if (notYet != null)
        {
            var any = new List<string>(); foreach (var s in notYet) any.Add("REPLACENULL({order_status},\"\") == \"" + s + "\"");
            tail = "(" + string.Join(" || ", any.ToArray()) + " ? -1 : 0)";
        }
        var key = "ISNULL({" + ts + "}) ? " + tail + " : YEAR({" + ts + "}) * 10000 + MONTH({" + ts + "}) * 100 + DAY({" + ts + "})";
        return error == null ? key : "{" + error + "} == 1 ? -2 : (" + key + ")";
    }
    static Col Key(string name, string from, string type) { return new Col(name, type, "REPLACENULL({" + from + "},0)"); }

    static Package Facts()
    {
        var p = NewPackage("Load_Facts", "Load Facts: dòng của các đơn bị ảnh hưởng -> bảng stage (Lookup khoá dimension, không khớp -> 0) -> MERGE vào fact");
        var steps = new List<Executable> { Control.Sql(p, p, "SQL Don stage",
            "TRUNCATE TABLE dwh.fact_order_experience_stage; TRUNCATE TABLE dwh.fact_order_item_stage;", null) };
        const string customers = "SELECT customer_unique_id, customer_key FROM dwh.dim_customer";
        const string geography = "SELECT zip_prefix, geography_key FROM dwh.dim_geography";
        {
            var f = new Flow(p, p, "DFT fact_order_experience"); steps.Add(f.Task);
            var n = f.OleSource("SRC Don hang", "OlistDW", Q("src_fact_order_experience"));
            n = f.Lookup("LKP dim_customer", n, customers, A("customer_unique_id=customer_unique_id"), A("customer_key>lk_customer_key"));
            n = f.Lookup("LKP dim_geography", n, geography, A("customer_zip_prefix=zip_prefix"), A("geography_key>lk_geography_key"));
            n = f.Lookup("LKP dim_order_status", n, "SELECT order_status, status_key FROM dwh.dim_order_status", A("order_status=order_status"), A("status_key>lk_status_key"));
            n = f.Lookup("LKP dim_delivery_outcome", n, "SELECT outcome_code, outcome_key FROM dwh.dim_delivery_outcome", A("outcome_code=outcome_code"), A("outcome_key>lk_outcome_key"));
            n = f.Derive("DER Khoa dimension", n,
                Key("customer_key", "lk_customer_key", "i4"), Key("customer_geography_key", "lk_geography_key", "i4"),
                Key("status_key", "lk_status_key", "i2"), Key("outcome_key", "lk_outcome_key", "i2"));
            var created = A("created"); var beforeCarrier = A("created", "approved", "invoiced", "processing");
            var beforeDelivery = A("created", "approved", "invoiced", "processing", "shipped");
            n = f.Derive("DER Khoa ngay", n,
                new Col("purchase_date_key", "i4", DateKey("purchase_ts", "purchase_ts_parse_error", null)),
                new Col("approved_date_key", "i4", DateKey("approved_ts", "approved_ts_parse_error", created)),
                new Col("carrier_date_key", "i4", DateKey("carrier_ts", "carrier_ts_parse_error", beforeCarrier)),
                new Col("delivered_date_key", "i4", DateKey("delivered_ts", "delivered_ts_parse_error", beforeDelivery)),
                new Col("estimated_date_key", "i4", DateKey("estimated_ts", "estimated_ts_parse_error", null)),
                new Col("review_answer_date_key", "i4", DateKey("review_answer_ts", null, null)));
            var cols = new List<Col> {
                new Col("order_count", "i2", "1"),
                new Col("reviewed_order_count", "i2", "ISNULL({representative_review_score}) ? 0 : 1"),
                new Col("low_review_order_count", "i2", "REPLACENULL({representative_review_score},0) == 1 || REPLACENULL({representative_review_score},0) == 2 ? 1 : 0"),
                new Col("review_record_count_f", "i4", "REPLACENULL({review_record_count},0)"),
                new Col("review_before_delivery_flag", "i2", "ISNULL({review_answer_ts}) || ISNULL({delivered_ts}) ? NULL(DT_I2) : (DT_I2)({review_answer_ts} < {delivered_ts} ? 1 : 0)"),
                new Col("item_line_count_f", "i4", "REPLACENULL({item_line_count},0)"),
                new Col("seller_count_f", "i4", "REPLACENULL({seller_count},0)") };
            n = f.Derive("DER Measure", n, cols.ToArray());
            f.Destination("DST fact_order_experience_stage", n, "[dwh].[fact_order_experience_stage]",
                A("review_record_count=review_record_count_f", "item_line_count=item_line_count_f", "seller_count=seller_count_f"),
                "dw_created_at", "dw_updated_at");
        }
        {
            var f = new Flow(p, p, "DFT fact_order_item"); steps.Add(f.Task);
            var n = f.OleSource("SRC Dong hang", "OlistDW", Q("src_fact_order_item"));
            n = f.Lookup("LKP dim_customer", n, customers, A("customer_unique_id=customer_unique_id"), A("customer_key>lk_customer_key"));
            n = f.Lookup("LKP dia chi khach", n, geography, A("customer_zip_prefix=zip_prefix"), A("geography_key>lk_customer_geo"));
            n = f.Lookup("LKP dim_product", n, "SELECT product_id, product_key FROM dwh.dim_product", A("product_id=product_id"), A("product_key>lk_product_key"));
            n = f.Lookup("LKP dim_seller", n, "SELECT seller_id, seller_key FROM dwh.dim_seller", A("seller_id=seller_id"), A("seller_key>lk_seller_key"));
            n = f.Lookup("LKP dia chi nguoi ban", n, geography, A("seller_zip_prefix=zip_prefix"), A("geography_key>lk_seller_geo"));
            var cols = new List<Col> {
                Key("customer_key", "lk_customer_key", "i4"), Key("customer_geography_key", "lk_customer_geo", "i4"),
                Key("product_key", "lk_product_key", "i4"), Key("seller_key", "lk_seller_key", "i4"), Key("seller_geography_key", "lk_seller_geo", "i4"),
                new Col("purchase_date_key", "i4", DateKey("purchase_ts", "purchase_ts_parse_error", null).Replace("{purchase_ts_parse_error} == 1", "REPLACENULL({purchase_ts_parse_error},0) == 1")),
                new Col("shipping_limit_date_key", "i4", DateKey("shipping_limit_ts", "shipping_limit_parse_error", null)),
                new Col("item_line_count", "i2", "1"),
                new Col("item_total_amount", "n18,2", "{price_amount} + {freight_amount}") };
            n = f.Derive("DER Khoa va measure", n, cols.ToArray());
            f.Destination("DST fact_order_item_stage", n, "[dwh].[fact_order_item_stage]", null, "dw_created_at", "dw_updated_at");
        }
        steps.Add(Control.Sql(p, p, "SQL MERGE vao fact", "EXEC audit.usp_merge_facts;", null));
        steps.Add(LogStep(p, "load_fact", "dwh.fact_order_experience", "dwh.fact_order_item"));
        Control.Chain(p, steps);
        return p;
    }

    // =====================================================================================================
    // 6. Test  và  7. Master
    // =====================================================================================================
    static Package Test()
    {
        var p = NewPackage("Test_DW", "Test: kiểm thử kho (T02-T13); có kiểm tra mức ERROR không đạt thì package báo lỗi");
        BatchSql(p, p, "SQL Kiem thu kho", "EXEC audit.usp_check_dw @batch_id = {batch};");
        return p;
    }

    static Package Master()
    {
        var p = NewPackage("Master", "Điều phối: Ingest -> Transform -> Load Dimensions -> Load Facts -> Test, ghi trạng thái batch");
        var steps = new List<Executable> { StartRun(p) };
        foreach (var child in A("Ingest_Staging", "Transform_Clean", "Transform_Business", "Load_Dimensions", "Load_Facts", "Test_DW"))
        {
            var t = (TaskHost)p.Executables.Add("Microsoft.ExecutePackageTask");
            t.Name = "EPT " + child;
            t.Properties["UseProjectReference"].SetValue(t, true);
            t.Properties["PackageName"].SetValue(t, child + ".dtsx");
            steps.Add(t);
        }
        steps.Add(BatchSql(p, p, "SQL Ket thuc SUCCESS", "EXEC audit.usp_finish_run {batch}, 'SUCCESS';"));
        Control.Chain(p, steps);

        var handler = (DtsEventHandler)p.EventHandlers.Add("OnError");
        var fail = Control.Sql(p, handler, "SQL Danh dau FAILED", "SELECT 1", null);
        fail.SetExpression("SqlStatementSource",
            "\"EXEC audit.usp_finish_run N'\" + " + Batch + " + \"', 'FAILED', N'\" + REPLACE(SUBSTRING(@[System::ErrorDescription],1,1000),\"'\",\"''\") + \"';\"");
        return p;
    }

    // =====================================================================================================
    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        repo = args[0];
        string server = args[1];
        string output = args[2];       // thư mục ghi .dtsx
        queries = Path.Combine(repo, "ssis", "OlistETL", "queries");
        string projectDir = Path.Combine(repo, "ssis", "OlistETL", "OlistETL");

        project = Project.CreateProject();
        project.Name = "OlistETL";
        project.ProtectionLevel = DTSProtectionLevel.DontSaveSensitive;
        Func<string, string, Parameter> param = delegate(string n, string v)
        { var x = project.Parameters.Add(n, TypeCode.String); x.Value = v; return x; };
        param("SqlServerName", server); param("DatabaseName", "OlistDW");
        param("RawDir", Path.Combine(repo, "data", "batches")); param("BatchId", "FULL_001"); param("BatchType", "FULL");

        // Dùng đúng connection manager OlistDW của project (cùng ID) để package tham chiếu tới nó
        var item = project.ConnectionManagerItems.Add("OLEDB", "OlistDW.conmgr");
        using (var stream = File.OpenRead(Path.Combine(projectDir, "OlistDW.conmgr"))) item.Load(null, stream);

        var builders = new Func<Package>[] { Ingest, Clean, Business, Dimensions, Facts, Test, Master };
        var only = args.Length > 3 ? args[3] : null;
        int failed = 0;
        Directory.CreateDirectory(output);
        foreach (var build in builders)
        {
            if (only != null && !build.Method.Name.Equals(only, StringComparison.OrdinalIgnoreCase)) continue;
            Console.WriteLine("== " + build.Method.Name);
            try
            {
                var p = build();
                var events = new Problems();
                var result = p.Validate(null, null, events, null);
                Console.WriteLine("  Validate: " + result);
                if (result != DTSExecResult.Success) failed++;
                // Bảng đích và nguồn được nạp bởi bước trước: kiểm tra lại lúc chạy tới task đó
                foreach (var e in p.Executables) DelayDataFlows(e);
                app.SaveToXml(Path.Combine(output, p.Name + ".dtsx"), p, null);
            }
            catch (Exception ex)
            {
                failed++;
                var inner = ex; while (inner.InnerException != null) inner = inner.InnerException;
                Console.WriteLine("  DỰNG THẤT BẠI: " + inner.Message);
                var com = inner as System.Runtime.InteropServices.COMException;
                if (com != null) Console.WriteLine("  HRESULT 0x" + com.ErrorCode.ToString("X8"));
                Console.WriteLine(inner.StackTrace);
            }
        }
        Console.WriteLine(failed == 0 ? "TẤT CẢ PACKAGE ĐẠT" : "CÓ " + failed + " PACKAGE LỖI");
        return failed == 0 ? 0 : 1;
    }

    static void DelayDataFlows(Executable e)
    {
        var host = e as TaskHost;
        if (host != null && host.InnerObject is MainPipe) host.DelayValidation = true;
        var seq = e as Sequence;
        if (seq != null) foreach (var child in seq.Executables) DelayDataFlows(child);
    }
}
