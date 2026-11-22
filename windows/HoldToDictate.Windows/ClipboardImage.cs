using System.Windows;
using System.Windows.Media.Imaging;

namespace HoldToDictate.WindowsApp;

internal static class ClipboardImage
{
    // Browsers and image editors may offer a PNG stream without a Win32 bitmap.
    public static byte[]? Read(IDataObject item)
    {
        foreach (string format in new[] { "PNG", "image/png" })
        {
            if (!item.GetDataPresent(format, autoConvert: false)) continue;
            switch (item.GetData(format, autoConvert: false))
            {
                case MemoryStream stream: return stream.ToArray();
                case byte[] bytes: return bytes;
            }
        }

        if (item.GetData(DataFormats.Bitmap) is not BitmapSource bitmap) return null;
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    public static DataObject ForCopy(byte[] png)
    {
        using var source = new MemoryStream(png);
        var bitmap = BitmapFrame.Create(source, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        bitmap.Freeze();
        var item = new DataObject();
        item.SetImage(bitmap);
        item.SetData("PNG", new MemoryStream(png, writable: false), autoConvert: false);
        return item;
    }
}
