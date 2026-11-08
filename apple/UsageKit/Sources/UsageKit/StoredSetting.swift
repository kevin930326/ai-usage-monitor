import Foundation

/// 啟動時讀到的設定（中繼網址、讀取密鑰）是空的時，改用重新讀取的值。
/// iOS／watchOS 可能在開機後第一次解鎖前就在背景啟動 App，那時 Keychain（`AfterFirstUnlock`）與 App Group 都還讀不到；
/// 只在啟動時讀一次的話，解鎖後同一個程序都會顯示「尚未設定中繼」。已有值時不重讀：設定畫面剛存的值不會被蓋掉。
public enum StoredSetting {
    public static func reloaded(_ current: String, read: () -> String?) -> String {
        guard current.isEmpty, let value = read(), !value.isEmpty else { return current }
        return value
    }
}
