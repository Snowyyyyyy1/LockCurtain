// PairingForm.cs —— 「配对手机」窗口（对应 Mac 的 PairingWindow.swift，文案按 Windows 版 brief §8，用「电脑」）
//
// 托盘菜单「配对手机」打开：6 位码、一句告诉人在手机上做什么、脚注、「换一个码」「关闭」。
// 关掉窗口码就作废（没配过手机的话也不再找手机）；配上时窗口自己留着，让人看清「已和这台手机配上。」再关。
// 「撤销配对」的确认框也在这里（ConfirmUnpair）。

using System.Drawing;
using LockCurtain.Phone;

namespace LockCurtain;

internal sealed class PairingForm : Form
{
    readonly PhoneLink link;
    readonly Label above = new(), code = new(), below = new(), footnote = new(), headline = new(), detail = new(), liftLine = new();
    readonly Button refresh = new() { Text = "换一个码", AutoSize = true, MinimumSize = new Size(96, 32) };
    readonly Button close = new() { Text = "关闭", AutoSize = true, MinimumSize = new Size(96, 32) };

    public PairingForm(PhoneLink link)
    {
        this.link = link;
        Text = "配对手机";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(440, 340);
        Font = new Font("Microsoft YaHei UI", 9.75f);
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch (Exception) { }

        var secondary = SystemColors.GrayText;
        Style(above, 10.5f, FontStyle.Regular, null);
        Style(code, 30f, FontStyle.Bold, null, "Consolas");
        Style(below, 9.75f, FontStyle.Regular, secondary);
        Style(footnote, 9f, FontStyle.Regular, secondary);
        Style(headline, 13f, FontStyle.Bold, null);
        Style(detail, 9.75f, FontStyle.Regular, secondary);
        Style(liftLine, 9.75f, FontStyle.Regular, secondary);
        code.AccessibleName = "配对码";

        var stack = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            Padding = new Padding(22, 18, 22, 8),
        };
        stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var l in new[] { headline, above, code, below, detail, liftLine, footnote })
        {
            stack.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            stack.Controls.Add(l);
        }
        stack.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Padding = new Padding(16, 6, 16, 14),
        };
        buttons.Controls.Add(close);
        buttons.Controls.Add(refresh);
        Controls.Add(stack);
        Controls.Add(buttons);
        AcceptButton = close;
        CancelButton = close;

        refresh.Click += (_, _) => link.RefreshCode();
        close.Click += (_, _) => Close();
        link.Changed += Render;
        FormClosed += (_, _) =>
        {
            link.Changed -= Render;
            link.Stop();
        };
        Render();
    }

    static void Style(Label l, float size, FontStyle style, Color? color, string family = "Microsoft YaHei UI")
    {
        l.AutoSize = true;
        l.Dock = DockStyle.Fill;
        l.TextAlign = ContentAlignment.MiddleCenter;
        l.Font = new Font(family, size, style);
        l.MaximumSize = new Size(390, 0);
        l.Margin = new Padding(0, 4, 0, 4);
        if (color is { } c) l.ForeColor = c;
    }

    /// 打开窗口：生成新码，开始找手机
    public void Open()
    {
        link.Start();
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
    }

    void Show(Label l, string text)
    {
        l.Text = text;
        l.Visible = text.Length > 0;
    }

    void Render()
    {
        if (IsDisposed) return;
        foreach (var l in new[] { headline, above, code, below, detail, liftLine, footnote }) Show(l, "");
        refresh.Visible = false;
        switch (link.Phase)
        {
            case PhonePhase.Waiting or PhonePhase.Idle when link.Code.Length == 6:
                Show(above, "在手机上输入这 6 位");
                Show(code, string.Join(" ", link.Code.ToCharArray()));
                code.AccessibleDescription = string.Join(" ", link.Code.ToCharArray());
                Show(below, "输入后两台就认上了，以后同一台手机再来不用输码。");
                Show(footnote, "关掉这个窗口，这 6 位就作废。");
                refresh.Visible = true;
                break;
            case PhonePhase.Waiting or PhonePhase.Idle or PhonePhase.CodeDead:
                Show(headline, "这几个数作废了，点「换一个码」重新来。");
                Show(footnote, "关掉这个窗口，这 6 位就作废。");
                refresh.Visible = true;
                break;
            case PhonePhase.Paired:
                Show(headline, "已和这台手机配上。");
                Show(detail, "手机那边等一下就是已连接。");
                Show(liftLine, "这台手机走近、并且此刻是解锁着的，就能撤下幕布。");
                break;
            case PhonePhase.BluetoothOff:
                Show(headline, "蓝牙没开");
                Show(detail, "配对要用蓝牙。到 Windows 设置里的「蓝牙和其他设备」打开蓝牙，回来看，配对码就在这儿。");
                break;
            case PhonePhase.Unsupported:
                Show(headline, "这台电脑的蓝牙用不了");
                Show(detail, "配对手机要支持低功耗蓝牙的蓝牙适配器（蓝牙 4.0 以上），这台电脑上的不行。");
                break;
            case PhonePhase.Revoked:
                Show(headline, "已经撤销了。");
                Show(detail, "手机那边会回到没配对。");
                break;
        }
    }

    /// 「撤销配对」：先确认，撤销后告诉人手机那边会怎样
    public static void ConfirmUnpair(PhoneLink link)
    {
        var cancel = new TaskDialogButton("取消");
        var revoke = new TaskDialogButton("撤销配对");
        var page = new TaskDialogPage
        {
            Caption = "撤销配对",
            Heading = "撤销这台手机的配对？",
            Text = "撤销后要在这台手机上重新输码，才能再盖上幕布。",
            Buttons = { cancel, revoke },
            DefaultButton = cancel,
            Icon = TaskDialogIcon.Warning,
        };
        if (TaskDialog.ShowDialog(page, TaskDialogStartupLocation.CenterScreen) != revoke) return;
        link.UnpairAll();
        TaskDialog.ShowDialog(new TaskDialogPage
        {
            Caption = "撤销配对",
            Heading = "已经撤销了。",
            Text = "手机那边会回到没配对。",
            Buttons = { TaskDialogButton.OK },
        }, TaskDialogStartupLocation.CenterScreen);
    }
}
