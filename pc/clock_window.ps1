# Gecikme olcumu icin saat penceresi: verilen ekranin ust 1/8 seridine PC saatini
# (Unix ms'nin son $Bits biti) siyah/beyaz hucreler olarak cizer, surekli gunceller.
param([int]$X, [int]$Y, [int]$Width, [int]$Height, [int]$Bits = 16)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form
$f.FormBorderStyle = 'None'; $f.TopMost = $true; $f.StartPosition = 'Manual'; $f.ShowInTaskbar = $false
$f.Location = New-Object Drawing.Point($X, $Y)
$f.Size = New-Object Drawing.Size($Width, [int]($Height / 8))
$f.BackColor = 'Black'
$prop = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance')
$prop.SetValue($f, $true, $null)
$f.Add_Paint({
    param($s, $e)
    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $w = $f.ClientSize.Width / $Bits; $h = $f.ClientSize.Height
    for ($i = 0; $i -lt $Bits; $i++) {
        $bit = ($ms -shr ($Bits - 1 - $i)) -band 1
        $b = if ($bit) { [Drawing.Brushes]::White } else { [Drawing.Brushes]::Black }
        $e.Graphics.FillRectangle($b, [float]($i * $w), [float]0, [float]$w, [float]$h)
    }
})
$f.Show()
while ($f.Visible) { $f.Invalidate(); [Windows.Forms.Application]::DoEvents(); [Threading.Thread]::Sleep(1) }
