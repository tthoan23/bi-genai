// Script Task "SCR Check <bang>" - Task 2 / Ingest_Staging.dtsx
// Dán toàn bộ nội dung này vào cửa sổ Edit Script của Script Task.
// ReadOnlyVariables : User::var_raw_dir, User::current_file, User::current_table
// ReadWriteVariables: User::column_list, User::rows_read, User::rows_loaded
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.SqlServer.Dts.Runtime;

[Microsoft.SqlServer.Dts.Tasks.ScriptTask.SSISScriptTaskEntryPointAttribute]
public class ScriptMain : Microsoft.SqlServer.Dts.Tasks.ScriptTask.VSTARTScriptObjectModelBase
{
    // Giống REQUIRED trong olist_bi/custom/ingest_csv.py.
    private static readonly Dictionary<string, string[]> Required =
        new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
    {
        { "orders", new[] {
            "order_id", "customer_id", "order_status", "order_purchase_timestamp",
            "order_approved_at", "order_delivered_carrier_date",
            "order_delivered_customer_date", "order_estimated_delivery_date" } },
        { "customers", new[] {
            "customer_id", "customer_unique_id", "customer_zip_code_prefix" } },
        { "order_items", new[] {
            "order_id", "order_item_id", "product_id", "seller_id", "price", "freight_value" } },
        { "order_reviews", new[] {
            "review_id", "order_id", "review_score", "review_creation_date",
            "review_answer_timestamp" } },
        { "order_payments", new string[0] },
        { "products", new string[0] },
        { "sellers", new string[0] },
        { "geolocation", new string[0] },
        { "category_translation", new string[0] }
    };

    private void Fail(string message)
    {
        Dts.Events.FireError(0, "SCR Check", message, string.Empty, 0);
        Dts.TaskResult = (int)ScriptResults.Failure;
    }

    public void Main()
    {
        string rawDir = Convert.ToString(Dts.Variables["User::var_raw_dir"].Value);
        string file = Convert.ToString(Dts.Variables["User::current_file"].Value);
        string table = Convert.ToString(Dts.Variables["User::current_table"].Value);
        string path = Path.Combine(rawDir, file);

        // Reset các biến đếm trước mỗi bảng (Script Task này đứng đầu mỗi Sequence Container).
        Dts.Variables["User::rows_read"].Value = 0L;
        Dts.Variables["User::rows_loaded"].Value = 0L;

        if (!File.Exists(path))
        {
            Fail(string.Format(
                "Không tìm thấy {0}. Đã giải nén data/olist-brazilian-ecommerce.zip vào data/raw chưa?",
                path));
            return;
        }

        try
        {
            // utf-8-sig: bỏ BOM của product_category_name_translation.csv.
            var encoding = new UTF8Encoding(false, true);
            using (var reader = new StreamReader(path, encoding, true))
            {
                string header = reader.ReadLine();
                if (string.IsNullOrEmpty(header))
                {
                    Fail(string.Format("{0} thiếu cột [{1}]", file,
                        Required.ContainsKey(table)
                            ? string.Join(", ", Required[table])
                            : "header"));
                    return;
                }

                // Các header Olist không chứa dấu phẩy trong dấu ngoặc kép,
                // nên tách đơn giản bằng ',' là đủ cho bước kiểm tra này.
                string[] columns = header.Split(',')
                    .Select(c => c.Trim().Trim('"').TrimStart('\uFEFF'))
                    .ToArray();

                string[] required = Required.ContainsKey(table) ? Required[table] : new string[0];
                string[] missing = required
                    .Where(r => !columns.Contains(r, StringComparer.OrdinalIgnoreCase))
                    .ToArray();

                if (missing.Length > 0)
                {
                    Fail(string.Format("{0} thiếu cột [{1}]", file, string.Join(", ", missing)));
                    return;
                }

                Dts.Variables["User::column_list"].Value = string.Join(",", columns);
            }
        }
        catch (Exception ex)
        {
            Fail(string.Format("Không đọc được tiêu đề {0}: {1}", path, ex.Message));
            return;
        }

        Dts.TaskResult = (int)ScriptResults.Success;
    }
}
