using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace AdClean
{
    // AdClean 启动器：内嵌 PowerShell 主程序，零依赖运行
    // 任何异常都会写入 exe 同目录 crash-log.txt 并弹窗提示，绝不静默崩溃
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string root = AppDomain.CurrentDomain.SetupInformation.ApplicationBase;
            try
            {
                Run(root);
                return 0;
            }
            catch (Exception ex)
            {
                try
                {
                    File.WriteAllText(
                        Path.Combine(root, "crash-log.txt"),
                        "[" + DateTime.Now + "]\r\n" + ex.ToString() + "\r\n\r\n",
                        Encoding.UTF8);
                }
                catch { }
                try
                {
                    System.Windows.Forms.MessageBox.Show(
                        "AdClean 启动失败：\r\n" + ex.Message + "\r\n\r\n详细信息已写入 crash-log.txt",
                        "AdClean", System.Windows.Forms.MessageBoxButtons.OK,
                        System.Windows.Forms.MessageBoxIcon.Error);
                }
                catch { }
                return 1;
            }
        }

        private static void Run(string root)
        {
            // 释放目录：优先 exe 同目录（绿色软件习惯），失败退回 %TEMP%
            string destDir = root;
            string ps1Path = Path.Combine(destDir, "AdCleanGUI.ps1");
            try
            {
                string embedded = Encoding.UTF8.GetString(Resources.AdCleanGUI);
                File.WriteAllText(ps1Path, embedded, Encoding.UTF8);

                // 自定义清单模板（可选文件，不存在才释放）
                string customPath = Path.Combine(destDir, "custom-list.json");
                if (!File.Exists(customPath))
                {
                    string custom = Encoding.UTF8.GetString(Resources.CustomList);
                    File.WriteAllText(customPath, custom, Encoding.UTF8);
                }
            }
            catch (UnauthorizedAccessException)
            {
                // exe 目录只读（如 Program Files）：退回 %TEMP%
                destDir = Path.Combine(Path.GetTempPath(), "AdClean");
                Directory.CreateDirectory(destDir);
                ps1Path = Path.Combine(destDir, "AdCleanGUI.ps1");
                string embedded = Encoding.UTF8.GetString(Resources.AdCleanGUI);
                File.WriteAllText(ps1Path, embedded, Encoding.UTF8);
            }

            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell\\v1.0\\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1Path + "\" -Root \"" + root + "\"",
                UseShellExecute = false
            };
            using (var p = Process.Start(psi))
            {
                p.WaitForExit();
            }
        }
    }

    // 构建时生成：base64 → 字节数组
    internal static class Resources
    {
        internal static byte[] AdCleanGUI { get { return Convert.FromBase64String(S1); } }
        internal static byte[] CustomList { get { return Convert.FromBase64String(S2); } }
        private const string S1 = "__PS1_B64__";
        private const string S2 = "__PS2_B64__";
    }
}
