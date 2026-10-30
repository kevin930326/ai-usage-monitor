using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 下拉選單沒展開時不吃滾輪（icons 第 8 部分）：捲動設定頁時游標剛好停在下拉選單上，滾輪會直接改掉選項與設定。
/// 對所有 <see cref="ComboBox"/>（含之後新增的）註冊類別處理：沒展開時把滾輪交給外層（設定頁的 ScrollViewer 照常捲動），
/// 點開選單後才在選單裡捲動。
/// </summary>
internal static class WheelGuard
{
    private static bool installed;

    public static void Install()
    {
        if (installed) return;
        installed = true;
        EventManager.RegisterClassHandler(typeof(ComboBox), UIElement.PreviewMouseWheelEvent, new MouseWheelEventHandler(OnWheel));
    }

    private static void OnWheel(object sender, MouseWheelEventArgs e)
    {
        if (sender is not ComboBox box || box.IsDropDownOpen || e.Handled) return;
        e.Handled = true;
        // 從外層再送一次（冒泡的 MouseWheel），外面的 ScrollViewer 才會捲動
        if (VisualTreeHelper.GetParent(box) is UIElement parent)
        {
            parent.RaiseEvent(new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta) { RoutedEvent = UIElement.MouseWheelEvent });
        }
    }
}
