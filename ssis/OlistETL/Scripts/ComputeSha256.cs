// Script Task "SCR Hash <bang>" - Task 2 / Ingest_Staging.dtsx
// Dán vào cửa sổ Edit Script của Script Task.
// ReadOnlyVariables : User::var_raw_dir, User::current_file
// ReadWriteVariables: User::checksum, User::file_rows
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Microsoft.SqlServer.Dts.Runtime;

[Microsoft.SqlServer.Dts.Tasks.ScriptTask.SSISScriptTaskEntryPointAttribute]
public class ScriptMain : Microsoft.SqlServer.Dts.Tasks.ScriptTask.VSTARTScriptObjectModelBase
{
    public void Main()
    {
        string rawDir = Convert.ToString(Dts.Variables["User::var_raw_dir"].Value);
        string file = Convert.ToString(Dts.Variables["User::current_file"].Value);
        string path = Path.Combine(rawDir, file);

        if (!File.Exists(path))
        {
            // SCR Check ở trước đã chặn trường hợp này; giữ lại để script không nuốt lỗi.
            Dts.Events.FireError(0, "SCR Hash",
                string.Format("Không tìm thấy {0}", path), string.Empty, 0);
            Dts.TaskResult = (int)ScriptResults.Failure;
            return;
        }

        try
        {
            // SHA-256 của toàn bộ file (đúng checksum của ingest_csv.py).
            using (var stream = File.OpenRead(path))
            using (var sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(stream);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash)
                    sb.Append(b.ToString("x2"));
                Dts.Variables["User::checksum"].Value = sb.ToString();
            }

            // row_count của manifest là số dòng CẢ file. Đếm bằng một vòng lặp ký tự
            // nên xuống dòng nằm trong dấu ngoặc kép (review comment) không bị tính
            // thành dòng mới, và không cần reference Microsoft.VisualBasic.
            long records = 0;
            bool inQuotes = false, sawAny = false, endedWithNewline = true;
            using (var reader = new StreamReader(path, new UTF8Encoding(false, true), true))
            {
                int value;
                while ((value = reader.Read()) != -1)
                {
                    char ch = (char)value;
                    sawAny = true;
                    endedWithNewline = false;

                    if (ch == '"')
                    {
                        if (inQuotes && reader.Peek() == '"') reader.Read();  // "" = một dấu "
                        else inQuotes = !inQuotes;
                    }
                    else if (!inQuotes && (ch == '\r' || ch == '\n'))
                    {
                        if (ch == '\r' && reader.Peek() == '\n') reader.Read();
                        records++;
                        endedWithNewline = true;
                    }
                }
            }
            if (sawAny && !endedWithNewline) records++;
            Dts.Variables["User::file_rows"].Value = Math.Max(0L, records - 1);  // trừ header

            Dts.TaskResult = (int)ScriptResults.Success;
        }
        catch (Exception ex)
        {
            Dts.Events.FireError(0, "SCR Hash",
                string.Format("Không tính được SHA-256 của {0}: {1}", path, ex.Message),
                string.Empty, 0);
            Dts.TaskResult = (int)ScriptResults.Failure;
        }
    }
}
