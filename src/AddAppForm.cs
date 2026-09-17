// Dialog for adding an owned-but-not-installed game by AppID.
using System;
using System.Drawing;
using System.Windows.Forms;

class AddAppForm : Form
{
    readonly TextBox _idBox = new TextBox();
    readonly TextBox _nameBox = new TextBox();

    public uint AppId { get; private set; }
    public string GameName { get; private set; }

    public AddAppForm()
    {
        Text = "Add game by AppID";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(380, 180);
        Font = new Font("Segoe UI", 9f);

        var hint = new Label
        {
            Text = "You can idle any game your account owns, installed or not.\n" +
                   "The AppID is the number in the store URL:\n" +
                   "store.steampowered.com/app/440/  ->  440",
            Location = new Point(12, 10),
            Size = new Size(356, 52),
            ForeColor = Color.FromArgb(90, 90, 90)
        };

        var idLabel = new Label { Text = "AppID:", Location = new Point(12, 72), Size = new Size(60, 20) };
        _idBox.Location = new Point(78, 69);
        _idBox.Size = new Size(120, 24);

        var nameLabel = new Label { Text = "Name:", Location = new Point(12, 104), Size = new Size(60, 20) };
        _nameBox.Location = new Point(78, 101);
        _nameBox.Size = new Size(280, 24);

        var ok = new Button { Text = "Add", Size = new Size(85, 28), Location = new Point(188, 140) };
        ok.Click += OnOk;

        var cancel = new Button
        {
            Text = "Cancel",
            Size = new Size(85, 28),
            Location = new Point(280, 140),
            DialogResult = DialogResult.Cancel
        };

        Controls.AddRange(new Control[] { hint, idLabel, _idBox, nameLabel, _nameBox, ok, cancel });
        AcceptButton = ok;
        CancelButton = cancel;
    }

    void OnOk(object sender, EventArgs e)
    {
        uint id;
        if (!uint.TryParse(_idBox.Text.Trim(), out id) || id == 0)
        {
            MessageBox.Show(this, "Enter a numeric AppID.", "Add game",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        AppId = id;
        GameName = _nameBox.Text.Trim();
        DialogResult = DialogResult.OK;
        Close();
    }
}
