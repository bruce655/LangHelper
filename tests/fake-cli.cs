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
        // Mirrors Copilot CLI 1.0.97, which rejects the '*' wildcard as a --deny-tool rule.
        string[] denied = new string[0];
        for (int i = 0; i < args.Length - 1; i++) {
            if (args[i] == "--deny-tool") {
                if (args[i + 1] == "*") {
                    Console.Error.WriteLine("Invalid --deny-tool value. Error: Invalid rule format: *");
                    return 25;
                }
                Array.Resize(ref denied, denied.Length + 1);
                denied[denied.Length - 1] = args[i + 1];
            }
        }
        foreach (string tool in new string[] { "shell", "write", "read", "url" }) {
            if (Array.IndexOf(denied, tool) < 0) {
                Console.Error.WriteLine("CLI tool isolation was not preserved.");
                return 24;
            }
        }
        if (Array.IndexOf(args, "--allow-all-tools") >= 0) {
            Console.Error.WriteLine("CLI tool isolation was not preserved.");
            return 24;
        }
        Console.WriteLine("CLI translated");
        return 0;
    }
}
