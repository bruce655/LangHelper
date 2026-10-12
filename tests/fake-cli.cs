using System;
class FakeCli {
    static int Main(string[] args) {
        if (args.Length < 2 || args[0] != "-p" || !args[1].Contains("Hello \"quoted\" input")) {
            Console.Error.WriteLine("Prompt quoting was not preserved.");
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
