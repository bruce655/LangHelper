using System;
using System.IO;
using System.Text;
class FakeCli {
    static int Main(string[] args) {
        Console.InputEncoding = new UTF8Encoding(false);
        string prompt = args.Length >= 2 && args[0] == "-p" ? args[1] : Console.In.ReadToEnd();
        string expected = File.ReadAllText(Environment.GetEnvironmentVariable("LANGHELPER_TEST_INPUT"));
        if (!prompt.Contains(expected)) {
            Console.Error.WriteLine("Prompt quoting was not preserved: " + String.Join(" | ", args));
            return 23;
        }
        if (Array.IndexOf(args, "--deny-tool") < 0 || Array.IndexOf(args, "--allow-all-tools") >= 0) {
            Console.Error.WriteLine("CLI tool isolation was not preserved.");
            return 24;
        }
        Console.WriteLine("CLI translated");
        return 0;
    }
}
