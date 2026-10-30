using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace AIUsageMonitor.Windows;

/// <summary>
/// 下拉選單沒展開時不吃滾輪（icons 第 8 部分）：捲動設定頁時游標剛好停在下拉選單上，滾輪會直接改掉選項與設定。
/// WPF 的 ComboBox 在有鍵盤焦點、沒展開時用滾輪換選項，而且它的處理連「已處理」的事件也收（handledEventsToo），
/// 所以把事件標成已處理擋不住。改成：對所有 <see cref="ComboBox"/>（含之後新增的）註冊類別處理，沒展開而有焦點時
/// 先把焦點移回視窗，ComboBox 就不換選項、也不吃掉滾輪，事件照常冒泡到設定頁的 ScrollViewer 捲動。
/// 點開選單後照舊在選單裡捲動。
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
        if (sender is not ComboBox box || box.IsDropDownOpen || !box.IsKeyboardFocusWithin) return;
        if (Window.GetWindow(box) is { } window) Keyboard.Focus(window);
        if (box.IsKeyboardFocusWithin) Keyboard.ClearFocus();
    }
}
