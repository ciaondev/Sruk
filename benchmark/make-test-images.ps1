Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Drawing.Drawing2D;
public static class Gen {
  public static Bitmap Make(int w, int h, int seed, int noise) {
    var rnd = new Random(seed);
    var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb);
    using (var g = Graphics.FromImage(bmp)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      using (var br = new LinearGradientBrush(new Rectangle(0,0,w,h), Color.FromArgb(30,80,160), Color.FromArgb(230,180,90), 35f)) g.FillRectangle(br, 0,0,w,h);
      for (int i = 0; i < 1500; i++) {
        var c = Color.FromArgb(rnd.Next(40,200), rnd.Next(256), rnd.Next(256), rnd.Next(256));
        int x = rnd.Next(w), y = rnd.Next(h), s = rnd.Next(10, w/6);
        using (var b = new SolidBrush(c)) {
          switch (rnd.Next(3)) {
            case 0: g.FillEllipse(b, x-s/2, y-s/2, s, (int)(s*rnd.NextDouble()+5)); break;
            case 1: g.FillRectangle(b, x, y, s, rnd.Next(5, s)); break;
            default: using (var p = new Pen(c, rnd.Next(1,12))) g.DrawBezier(p, x, y, rnd.Next(w), rnd.Next(h), rnd.Next(w), rnd.Next(h), rnd.Next(w), rnd.Next(h)); break;
          }
        }
      }
    }
    var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
    var row = new byte[d.Stride];
    for (int y = 0; y < h; y++) {
      IntPtr ptr = new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride);
      System.Runtime.InteropServices.Marshal.Copy(ptr, row, 0, d.Stride);
      for (int x = 0; x < w*3; x++) { int v = row[x] + rnd.Next(-noise, noise+1); row[x] = (byte)(v < 0 ? 0 : v > 255 ? 255 : v); }
      System.Runtime.InteropServices.Marshal.Copy(row, 0, ptr, d.Stride);
    }
    bmp.UnlockBits(d);
    return bmp;
  }
  public static void SaveJpeg(Bitmap b, string path, long q) {
    ImageCodecInfo codec = null; foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") codec = c;
    var ep = new EncoderParameters(1); ep.Param[0] = new EncoderParameter(Encoder.Quality, q);
    b.Save(path, codec, ep);
  }
}
"@
$noise = [int]$args[0]; if (-not $noise) { $noise = 18 }
$dir = Join-Path $PSScriptRoot 'img'
$b = [Gen]::Make(6000, 4000, 1, $noise); [Gen]::SaveJpeg($b, "$dir\photo-24mp.jpg", 90); $b.Dispose()
$b = [Gen]::Make(4000, 3000, 2, $noise); [Gen]::SaveJpeg($b, "$dir\photo-12mp.jpg", 90); $b.Dispose()
$b = [Gen]::Make(1920, 1080, 3, $noise); $b.Save("$dir\screen-1080p.png", [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
Get-ChildItem $dir | % { "{0} {1:N2} MB" -f $_.Name, ($_.Length/1MB) }
