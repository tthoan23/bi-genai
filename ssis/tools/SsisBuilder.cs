// Hàm dùng chung để dựng package SSIS bằng object model chính thức (cùng thư viện mà Visual Studio dùng).
// Biên dịch cùng BuildOlistEtl.cs bằng ssis/tools/build.ps1. Chỉ là công cụ phát triển, không phải một phần của ETL.
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using RW = Microsoft.SqlServer.Dts.Runtime.Wrapper;

// Kiểu dữ liệu viết gọn: w255 (DT_WSTR), s100 (DT_STR), i2, i4, n18,2 (DT_NUMERIC), date, ts (DT_DBTIMESTAMP2(0))
public class TypeSpec
{
    public RW.DataType Type; public int Length, Precision, Scale, CodePage; public string Cast;

    public static TypeSpec Parse(string s)
    {
        var t = new TypeSpec();
        if (s == "i2") { t.Type = RW.DataType.DT_I2; t.Cast = "(DT_I2)"; }
        else if (s == "i4") { t.Type = RW.DataType.DT_I4; t.Cast = "(DT_I4)"; }
        else if (s == "date") { t.Type = RW.DataType.DT_DBDATE; t.Cast = "(DT_DBDATE)"; }
        else if (s == "ts") { t.Type = RW.DataType.DT_DBTIMESTAMP2; t.Scale = 0; t.Cast = "(DT_DBTIMESTAMP2,0)"; }
        else if (s.StartsWith("w")) { t.Type = RW.DataType.DT_WSTR; t.Length = int.Parse(s.Substring(1)); t.Cast = "(DT_WSTR," + t.Length + ")"; }
        else if (s.StartsWith("s")) { t.Type = RW.DataType.DT_STR; t.Length = int.Parse(s.Substring(1)); t.CodePage = 1252; t.Cast = "(DT_STR," + t.Length + ",1252)"; }
        else if (s.StartsWith("n"))
        {
            var p = s.Substring(1).Split(',');
            t.Type = RW.DataType.DT_NUMERIC; t.Precision = int.Parse(p[0]); t.Scale = int.Parse(p[1]);
            t.Cast = "(DT_NUMERIC," + t.Precision + "," + t.Scale + ")";
        }
        else throw new ArgumentException("Kiểu không biết: " + s);
        return t;
    }
}

// Một cột mới của Derived Column: tên, kiểu, biểu thức SSIS. Cột đầu vào viết trong ngoặc nhọn: {order_id}
public class Col
{
    public string Name, Type, Expr;
    public bool Truncate;
    public Col(string name, string type, string expr) { Name = name; Type = type; Expr = expr; }
    // Chỉ dùng khi phần bị cắt chắc chắn không mang thông tin
    public Col AllowTruncation() { Truncate = true; return this; }
}

public class Node
{
    public IDTSComponentMetaData100 Comp; public IDTSOutput100 Output;
    public Node(IDTSComponentMetaData100 c, IDTSOutput100 o) { Comp = c; Output = o; }
}

public class Flow
{
    const int Locale = 1033;   // en-US: số thập phân dùng dấu chấm, không phụ thuộc ngôn ngữ máy
    public readonly TaskHost Task; readonly Package pkg; readonly MainPipe pipe;

    public Flow(Package p, IDTSSequence parent, string name)
    {
        pkg = p;
        Task = (TaskHost)parent.Executables.Add("STOCK:PipelineTask");
        Task.Name = name;
        Task.Properties["LocaleID"].SetValue(Task, Locale);
        pipe = (MainPipe)Task.InnerObject;
    }

    IDTSComponentMetaData100 Add(string classId, string name, string connection, out CManagedComponentWrapper inst)
    {
        var c = pipe.ComponentMetaDataCollection.New();
        c.ComponentClassID = classId;
        inst = c.Instantiate();
        inst.ProvideComponentProperties();
        c.Name = name;
        c.LocaleID = Locale;
        if (connection != null)
        {
            var cm = pkg.Connections[connection];
            c.RuntimeConnectionCollection[0].ConnectionManager = DtsConvert.GetExtendedInterface(cm);
            c.RuntimeConnectionCollection[0].ConnectionManagerID = cm.ID;
        }
        return c;
    }

    static void Refresh(CManagedComponentWrapper inst)
    {
        inst.AcquireConnections(null);
        try { inst.ReinitializeMetaData(); }
        finally { inst.ReleaseConnections(); }
    }

    void Link(Node from, IDTSInput100 to)
    {
        pipe.PathCollection.New().AttachPathAndPropagateNotifications(from.Output, to);
    }

    static IDTSVirtualInputColumn100 Find(IDTSVirtualInput100 vin, string name, string where)
    {
        IDTSVirtualInputColumn100 found = null; int n = 0;
        foreach (IDTSVirtualInputColumn100 c in vin.VirtualInputColumnCollection)
            if (string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) { found = c; n++; }
        if (n != 1) throw new Exception(where + ": cột '" + name + "' xuất hiện " + n + " lần trong luồng");
        return found;
    }

    static IDTSCustomProperty100 Property(IDTSCustomPropertyCollection100 all, string name)
    {
        foreach (IDTSCustomProperty100 x in all) if (x.Name == name) return x;
        var added = all.New(); added.Name = name; return added;
    }

    static void SetExpression(IDTSCustomPropertyCollection100 all, string resolved, string friendly)
    {
        var e = Property(all, "Expression"); e.ContainsID = true; e.Value = resolved;
        var f = Property(all, "FriendlyExpression"); f.ContainsID = true; f.Value = friendly;
    }

    // ---------- Nguồn ----------
    public Node OleSource(string name, string connection, string sql)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.OLEDBSource", name, connection, out i);
        i.SetComponentProperty("AccessMode", 2);
        i.SetComponentProperty("SqlCommand", sql);
        Refresh(i);
        return new Node(c, c.OutputCollection[0]);
    }

    public Node FileSource(string name, string connection)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.FlatFileSource", name, connection, out i);
        i.SetComponentProperty("RetainNulls", true);   // ô trống trong file là NULL, không phải chuỗi rỗng
        Refresh(i);
        return new Node(c, c.OutputCollection[0]);
    }

    // ---------- Derived Column: luôn thêm cột mới ----------
    public Node Derive(string name, Node prev, params Col[] cols)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.DerivedColumn", name, null, out i);
        var input = c.InputCollection[0];
        Link(prev, input);
        var vin = input.GetVirtualInput();
        var output = c.OutputCollection[0];
        var used = new HashSet<int>();
        foreach (var col in cols)
        {
            var t = TypeSpec.Parse(col.Type);
            var friendly = t.Cast + "(" + col.Expr + ")";
            var resolved = Regex.Replace(friendly, @"\{([A-Za-z_][A-Za-z0-9_]*)\}", delegate(Match m)
            {
                var vc = Find(vin, m.Groups[1].Value, name);
                if (used.Add(vc.LineageID)) i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
                return "#" + vc.LineageID;
            });
            var oc = i.InsertOutputColumnAt(output.ID, output.OutputColumnCollection.Count, col.Name, "");
            i.SetOutputColumnDataTypeProperties(output.ID, oc.ID, t.Type, t.Length, t.Precision, t.Scale, t.CodePage);
            oc.ErrorRowDisposition = DTSRowDisposition.RD_FailComponent;
            oc.TruncationRowDisposition = col.Truncate ? DTSRowDisposition.RD_IgnoreFailure : DTSRowDisposition.RD_FailComponent;
            SetExpression(oc.CustomPropertyCollection, resolved, Regex.Replace(friendly, @"\{([A-Za-z_][A-Za-z0-9_]*)\}", "$1"));
        }
        return new Node(c, output);
    }

    // ---------- Data Conversion: giá trị sai thành NULL (Ignore failure), cờ lỗi tính ở Derived Column sau ----------
    // spec: "cột_vào>cột_ra:kiểu"
    public Node Convert(string name, Node prev, params string[] specs)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.DataConvert", name, null, out i);
        var input = c.InputCollection[0];
        Link(prev, input);
        var vin = input.GetVirtualInput();
        var output = c.OutputCollection[0];
        foreach (var s in specs)
        {
            var m = Regex.Match(s, @"^(\w+)>(\w+):(.+)$");
            var vc = Find(vin, m.Groups[1].Value, name);
            i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
            var t = TypeSpec.Parse(m.Groups[3].Value);
            var oc = i.InsertOutputColumnAt(output.ID, output.OutputColumnCollection.Count, m.Groups[2].Value, "");
            i.SetOutputColumnDataTypeProperties(output.ID, oc.ID, t.Type, t.Length, t.Precision, t.Scale, t.CodePage);
            i.SetOutputColumnProperty(output.ID, oc.ID, "SourceInputColumnLineageID", vc.LineageID);
            oc.ErrorRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
            oc.TruncationRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
        }
        return new Node(c, output);
    }

    // ---------- Lookup (Full cache). joins: "cột_luồng=cột_tham_chiếu"; returns: "cột_tham_chiếu>tên_mới" ----------
    IDTSComponentMetaData100 LookupCore(string name, Node prev, string sql, string[] joins, string[] returns, int noMatch)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.Lookup", name, "OlistDW", out i);
        i.SetComponentProperty("SqlCommand", sql);
        i.SetComponentProperty("NoMatchBehavior", noMatch);   // 0 = theo error disposition, 1 = ra No Match Output
        Refresh(i);
        var input = c.InputCollection[0];
        Link(prev, input);
        var vin = input.GetVirtualInput();
        foreach (var j in joins)
        {
            var p = j.Split('=');
            var vc = Find(vin, p[0], name);
            var ic = i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
            i.SetInputColumnProperty(input.ID, ic.ID, "JoinToReferenceColumn", p[1]);
        }
        var match = c.OutputCollection[0];
        foreach (var r in returns)
        {
            var p = r.Split('>');
            var oc = i.InsertOutputColumnAt(match.ID, match.OutputColumnCollection.Count, p[p.Length - 1], "");
            i.SetOutputColumnProperty(match.ID, oc.ID, "CopyFromReferenceColumn", p[0]);
        }
        return c;
    }

    // Không tìm thấy thì các cột trả về là NULL và dòng đi tiếp (sau đó REPLACENULL thành khoá 0)
    public Node Lookup(string name, Node prev, string sql, string[] joins, string[] returns)
    {
        var c = LookupCore(name, prev, sql, joins, returns, 0);
        var match = c.OutputCollection[0];
        match.ErrorRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
        return new Node(c, match);
    }

    // Tách hai nhánh: khớp (đã có trong dimension) và không khớp (mới, cần chèn)
    public Node[] LookupSplit(string name, Node prev, string sql, string[] joins, string[] returns)
    {
        var c = LookupCore(name, prev, sql, joins, returns, 1);
        Node matched = null, unmatched = null;
        foreach (IDTSOutput100 o in c.OutputCollection)
        {
            if (o.Name == "Lookup Match Output") matched = new Node(c, o);
            if (o.Name == "Lookup No Match Output") unmatched = new Node(c, o);
        }
        return new[] { matched, unmatched };
    }

    // ---------- Sort, bỏ dòng trùng theo toàn bộ khoá ----------
    public Node SortDistinct(string name, Node prev, params string[] keys)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.Sort", name, null, out i);
        i.SetComponentProperty("EliminateDuplicates", true);
        var input = c.InputCollection[0];
        Link(prev, input);
        var vin = input.GetVirtualInput();
        for (int k = 0; k < keys.Length; k++)
        {
            var vc = Find(vin, keys[k], name);
            var ic = i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
            i.SetInputColumnProperty(input.ID, ic.ID, "NewSortKeyPosition", k + 1);
        }
        return new Node(c, c.OutputCollection[0]);
    }

    // ---------- Aggregate. spec: "cột_vào|phép|tên_ra", phép: group, countall, countdistinct, sum, min ----------
    public Node Aggregate(string name, Node prev, params string[] specs)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.Aggregate", name, null, out i);
        var input = c.InputCollection[0];
        Link(prev, input);
        var vin = input.GetVirtualInput();
        var output = c.OutputCollection[0];
        var used = new HashSet<int>();
        foreach (var s in specs)
        {
            var p = s.Split('|');
            int op = p[1] == "group" ? 0 : p[1] == "countall" ? 2 : p[1] == "countdistinct" ? 3 : p[1] == "sum" ? 4 : 6;
            int lineage = 0; IDTSVirtualInputColumn100 vc = null;
            if (op != 2)
            {
                vc = Find(vin, p[0], name); lineage = vc.LineageID;
                if (used.Add(lineage)) i.SetUsageType(input.ID, vin, lineage, DTSUsageType.UT_READONLY);
            }
            IDTSOutputColumn100 oc = null;
            // SetUsageType tự tạo sẵn một cột ra cho cột vừa chọn: dùng lại cột đó nếu có
            foreach (IDTSOutputColumn100 x in output.OutputColumnCollection)
                if (lineage != 0 && (int)x.CustomPropertyCollection["AggregationColumnId"].Value == lineage && x.Description != "set") { oc = x; break; }
            if (oc == null) oc = i.InsertOutputColumnAt(output.ID, output.OutputColumnCollection.Count, p[2], "");
            oc.Name = p[2]; oc.Description = "set";
            i.SetOutputColumnProperty(output.ID, oc.ID, "AggregationColumnId", lineage);
            i.SetOutputColumnProperty(output.ID, oc.ID, "AggregationType", op);
        }
        return new Node(c, output);
    }

    public Node RowCount(string name, Node prev, string variable)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.RowCount", name, null, out i);
        i.SetComponentProperty("VariableName", variable);
        Link(prev, c.InputCollection[0]);
        return new Node(c, c.OutputCollection[0]);
    }

    // ---------- Conditional Split: một nhánh theo điều kiện ----------
    public Node Where(string name, Node prev, string outputName, string expr)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.ConditionalSplit", name, null, out i);
        var input = c.InputCollection[0];
        Link(prev, input);
        var vin = input.GetVirtualInput();
        var used = new HashSet<int>();
        var resolved = Regex.Replace(expr, @"\{([A-Za-z_][A-Za-z0-9_]*)\}", delegate(Match m)
        {
            var vc = Find(vin, m.Groups[1].Value, name);
            if (used.Add(vc.LineageID)) i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
            return "#" + vc.LineageID;
        });
        IDTSOutput100 def = null;
        foreach (IDTSOutput100 o in c.OutputCollection) if (!o.IsErrorOut) def = o;
        var output = i.InsertOutput(DTSInsertPlacement.IP_BEFORE, def.ID);
        output.Name = outputName;
        output.SynchronousInputID = input.ID;
        output.ExclusionGroup = def.ExclusionGroup;
        output.ErrorRowDisposition = DTSRowDisposition.RD_FailComponent;
        output.TruncationRowDisposition = DTSRowDisposition.RD_FailComponent;
        SetExpression(output.CustomPropertyCollection, resolved, Regex.Replace(expr, @"\{([A-Za-z_][A-Za-z0-9_]*)\}", "$1"));
        Property(output.CustomPropertyCollection, "EvaluationOrder").Value = 0;
        return new Node(c, output);
    }

    // ---------- OLE DB Command: mỗi dòng chạy một câu lệnh; columns theo đúng thứ tự dấu ? ----------
    public void Command(string name, Node prev, string sql, params string[] columns)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.OLEDBCommand", name, "OlistDW", out i);
        i.SetComponentProperty("SqlCommand", sql);
        var input = c.InputCollection[0];
        Link(prev, input);
        Refresh(i);
        var vin = input.GetVirtualInput();
        for (int k = 0; k < columns.Length; k++)
        {
            var vc = Find(vin, columns[k], name);
            var ic = i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
            i.MapInputColumn(input.ID, ic.ID, input.ExternalMetadataColumnCollection[k].ID);
        }
    }

    // ---------- OLE DB Destination (fast load) ----------
    // Mặc định ghép cột cùng tên. renames: "cột_đích=cột_luồng". skip: cột đích để SQL Server tự điền.
    public void Destination(string name, Node prev, string table, string[] renames, params string[] skip)
    {
        CManagedComponentWrapper i; var c = Add("Microsoft.OLEDBDestination", name, "OlistDW", out i);
        i.SetComponentProperty("AccessMode", 3);
        i.SetComponentProperty("OpenRowset", table);
        // Keep nulls tắt khi để SQL Server tự điền cột (DEFAULT), bật trong các trường hợp còn lại
        i.SetComponentProperty("FastLoadKeepNulls", Array.IndexOf(skip, "dw_created_at") < 0);
        var input = c.InputCollection[0];
        Link(prev, input);
        Refresh(i);
        var vin = input.GetVirtualInput();
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in renames ?? new string[0]) { var p = r.Split('='); map[p[0]] = p[1]; }
        var skipped = new HashSet<string>(skip, StringComparer.OrdinalIgnoreCase);
        foreach (IDTSExternalMetadataColumn100 ext in input.ExternalMetadataColumnCollection)
        {
            if (skipped.Contains(ext.Name)) continue;
            string source = map.ContainsKey(ext.Name) ? map[ext.Name] : ext.Name;
            var vc = Find(vin, source, name + " -> " + table + "." + ext.Name);
            var ic = i.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
            i.MapInputColumn(input.ID, ic.ID, ext.ID);
        }
    }
}

public static class Control
{
    public static TaskHost Sql(Package pkg, IDTSSequence parent, string name, string statement, string expression)
    {
        var t = (TaskHost)parent.Executables.Add("STOCK:SQLTask");
        t.Name = name;
        t.Properties["Connection"].SetValue(t, pkg.Connections["OlistDW"].ID);
        t.Properties["SqlStatementSource"].SetValue(t, statement);
        if (expression != null) t.SetExpression("SqlStatementSource", expression);
        return t;
    }

    public static void Chain(IDTSSequence parent, IList<Executable> steps)
    {
        for (int k = 1; k < steps.Count; k++) parent.PrecedenceConstraints.Add(steps[k - 1], steps[k]);
    }

    // Flat File connection UTF-8, mọi cột dạng chuỗi. Đường dẫn tính từ tham số project.
    public static void FlatFile(Package pkg, string name, string pathExpression, string rowDelimiter, string[] columns, int width)
    {
        var cm = pkg.Connections.Add("FLATFILE");
        cm.Name = name;
        cm.SetExpression("ConnectionString", pathExpression);
        cm.Properties["Format"].SetValue(cm, "Delimited");
        cm.Properties["LocaleID"].SetValue(cm, 1033);
        cm.Properties["Unicode"].SetValue(cm, false);
        cm.Properties["CodePage"].SetValue(cm, 65001);
        cm.Properties["TextQualifier"].SetValue(cm, "\"");
        cm.Properties["HeaderRowDelimiter"].SetValue(cm, rowDelimiter);
        cm.Properties["ColumnNamesInFirstDataRow"].SetValue(cm, true);
        var ff = (RW.IDTSConnectionManagerFlatFile100)cm.InnerObject;
        for (int k = 0; k < columns.Length; k++)
        {
            var col = ff.Columns.Add();
            col.ColumnType = "Delimited";
            col.ColumnDelimiter = k == columns.Length - 1 ? rowDelimiter : ",";
            col.DataType = RW.DataType.DT_WSTR;
            // width chỉ áp cho cột bình luận khi lớn hơn 255, để cột mã không rộng hơn cột đích
            col.MaximumWidth = width > 255 && !columns[k].StartsWith("review_comment") ? 255 : width;
            col.TextQualified = true;
            ((RW.IDTSName100)col).Name = columns[k];
        }
        // Bình luận có xuống dòng nằm trong dấu nháy: không coi ký tự xuống dòng giữa chừng là hết dòng
        cm.Properties["AlwaysCheckForRowDelimiters"].SetValue(cm, false);
    }
}
