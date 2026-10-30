using System;
using System.IO;
using System.Text;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace AdClean
{
    // AdClean 启动器 v2：进程内托管 PowerShell 引擎
    // 不再释放脚本文件、不再启动 powershell.exe 子进程
    // （旧版"释放脚本 + 隐藏 powershell"的模式会被 360 等安全软件的行为防御静默拦截）
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
            // 自定义清单模板（可选文件，不存在才释放）
            try
            {
                string customPath = Path.Combine(root, "custom-list.json");
                if (!File.Exists(customPath))
                {
                    string custom = Encoding.UTF8.GetString(Resources.CustomList);
                    File.WriteAllText(customPath, custom, Encoding.UTF8);
                }
            }
            catch { }

            // 进程内运行主程序（WinForms 需 STA，Main 已标记）
            string script = Encoding.UTF8.GetString(Resources.AdCleanGUI);
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.Open();
                using (PowerShell engine = PowerShell.Create())
                {
                    engine.Runspace = runspace;
                    engine.AddScript(script);
                    engine.AddParameter("Root", root);
                    engine.Invoke();
                    if (engine.HadErrors && engine.Streams.Error.Count > 0)
                    {
                        var msgs = new StringBuilder();
                        int n = 0;
                        foreach (var e in engine.Streams.Error)
                        {
                            msgs.AppendLine(e.ToString());
                            if (++n >= 5) break;
                        }
                        throw new Exception("脚本执行出错：\r\n" + msgs.ToString());
                    }
                }
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
