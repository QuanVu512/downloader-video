param([string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -OutputAssembly $OutputPath -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public class MockExtractor {
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        foreach (string arg in args) {
            if (arg == "--version") { Console.WriteLine("fixture-only"); return 0; }
            if (arg == "--load-info-json") {
                string tool = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "native-tool.txt");
                if (!File.Exists(tool)) { Console.Error.WriteLine("ERROR: HTTP Error 567: fixture native unavailable"); return 7; }
                var p = new System.Diagnostics.Process();
                p.StartInfo.FileName = File.ReadAllText(tool).Trim();
                p.StartInfo.Arguments = string.Join(" ", Array.ConvertAll(args, a => "\"" + a.Replace("\"", "\\\"") + "\""));
                p.StartInfo.UseShellExecute = false;
                p.StartInfo.CreateNoWindow = true;
                p.Start(); p.WaitForExit(); int code = p.ExitCode; p.Dispose(); return code;
            }
        }
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string counter = Path.Combine(root, "extract-count.txt");
        int count = File.Exists(counter) ? int.Parse(File.ReadAllText(counter)) : 0;
        count++;
        File.WriteAllText(counter, count.ToString());
        string tag = count == 1 ? "initial" : "fresh";
        File.Copy(Path.Combine(root, tag + "-dash.json"), Path.Combine(Environment.CurrentDirectory, "test-playurl.dump"), true);
        Console.WriteLine(File.ReadAllText(Path.Combine(root, tag + "-info.json"), Encoding.UTF8));
        return 0;
    }
}
'@
