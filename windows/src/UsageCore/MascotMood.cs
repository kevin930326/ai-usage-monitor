namespace AIUsageMonitor.Core;

// 角色平常顯示的表情、外觀、思考泡泡。和 Mac 的 UsageKit/MascotMood.swift、MascotLook.swift、MascotThinking.swift
// 是同一份規則；額度與狀態改用眼睛和眉毛表示，每種表情的眼睛形狀都不同，灰階也分得出來（ADR-0008、ADR-0016 第 1 節）。

/// <summary>正常、擔心（剩不到 20%）、用完（×）、閉眼（過期或讀取失敗），以及右鍵選單的開心、難過、生病、驚訝</summary>
public enum MascotMood { Normal, Worried, Out, Stale, Happy, Sad, Sick, Surprised }

/// <summary>眉毛：沒有、擔心（內側抬高）、難過（更斜）、驚訝（整條抬高）</summary>
public enum MascotBrow { None, Worried, Sad, Raised }

public static class MascotMoods
{
    public static string Title(this MascotMood mood) => mood switch
    {
        MascotMood.Normal => "平常",
        MascotMood.Worried => "擔心",
        MascotMood.Out => "用完",
        MascotMood.Stale => "閉眼",
        MascotMood.Happy => "開心",
        MascotMood.Sad => "難過",
        MascotMood.Sick => "生病",
        _ => "驚訝",
    };

    /// <summary>取代膠囊眼的樣子；null 表示維持膠囊（可以眨眼）</summary>
    public static MascotEyes? Eyes(this MascotMood mood) => mood switch
    {
        MascotMood.Worried or MascotMood.Surprised => MascotEyes.Dot,
        MascotMood.Out => MascotEyes.Cross,
        MascotMood.Happy => MascotEyes.Happy,
        _ => null,
    };

    /// <summary>眼皮蓋住多少（0 張開 … 1 閉成一條線）</summary>
    public static double Lid(this MascotMood mood) => mood switch
    {
        MascotMood.Stale => 1,
        MascotMood.Sick => 0.55,
        MascotMood.Sad => 0.45,
        _ => 0,
    };

    public static MascotBrow Brow(this MascotMood mood) => mood switch
    {
        MascotMood.Worried or MascotMood.Sick => MascotBrow.Worried,
        MascotMood.Sad => MascotBrow.Sad,
        MascotMood.Surprised => MascotBrow.Raised,
        _ => MascotBrow.None,
    };

    /// <summary>冒冷汗（生病）</summary>
    public static bool Sweat(this MascotMood mood) => mood == MascotMood.Sick;

    /// <summary>額度的表情（ADR-0018 第 3 節）：過期或讀取失敗（閉眼）> 用完（×）> 服務有事故（生病）>
    /// 預測會在重置前用完或剩不到 20%（擔心）> 正常。狀態等級：0 正常、1 偏高、2 用完</summary>
    public static MascotMood Quota(int level, bool unavailable, bool incident = false, bool runsOut = false)
    {
        if (unavailable) return MascotMood.Stale;
        if (level >= 2) return MascotMood.Out;
        if (incident) return MascotMood.Sick;
        return level == 1 || runsOut ? MascotMood.Worried : MascotMood.Normal;
    }

    /// <summary>服務狀態頁有進行中、有影響的事故（minor 以上；維護與 none 不算）</summary>
    public static bool HasIncident(UsageSnapshot? snapshot, string provider) =>
        snapshot?.Providers.GetValueOrDefault(provider)?.Incidents?.Any(i => i.IsDisruption) ?? false;

    /// <summary>這個服務有任何可見額度預測會在重置前用完（用快照裡收集器算好的）</summary>
    public static bool RunsOut(UsageSnapshot? snapshot, string provider, DateTimeOffset now)
    {
        if (snapshot?.Providers.GetValueOrDefault(provider) is not { Error: null } usage) return false;
        var stale = snapshot.IsStale(now);
        return usage.VisibleWindows.Any(w => QuotaForecast.Current(w, stale, now) is not null);
    }

    /// <summary>額度不明（閉眼）：還沒有資料、讀檔失敗、資料過期、選的服務沒有資料或出錯、或沒有任何看得到的額度</summary>
    public static bool IsQuotaUnavailable(UsageSnapshot? snapshot, string provider, bool readFailed, DateTimeOffset now)
    {
        if (snapshot is null || readFailed || snapshot.IsStale(now)
            || snapshot.Providers.GetValueOrDefault(provider) is not { Error: null } usage) return true;
        return usage.VisibleWindows.Count == 0;
    }

    /// <summary>加上 AI 狀態：出錯時難過；完成未看、額度正常時開心。額度偏高、用完、過期仍照額度</summary>
    public static MascotMood Agent(AgentState? state, MascotMood quota) => state switch
    {
        AgentState.Error => MascotMood.Sad,
        AgentState.Done when quota == MascotMood.Normal => MascotMood.Happy,
        _ => quota,
    };

    /// <summary>選單「表情」的動畫播的是哪個表情（沒有對應的回傳 null）</summary>
    public static MascotMood? Face(MascotAnimation animation) => animation switch
    {
        MascotAnimation.FaceHappy => MascotMood.Happy,
        MascotAnimation.FaceWorried => MascotMood.Worried,
        MascotAnimation.FaceSad => MascotMood.Sad,
        MascotAnimation.FaceSick => MascotMood.Sick,
        MascotAnimation.FaceSurprised => MascotMood.Surprised,
        MascotAnimation.FaceOut => MascotMood.Out,
        MascotAnimation.FaceStale => MascotMood.Stale,
        _ => null,
    };

    /// <summary>選單要求這個表情時送的要求（平常的表情沒有）</summary>
    public static MascotRequest? FaceRequest(this MascotMood mood) => mood switch
    {
        MascotMood.Happy => MascotRequest.FaceHappy,
        MascotMood.Worried => MascotRequest.FaceWorried,
        MascotMood.Sad => MascotRequest.FaceSad,
        MascotMood.Sick => MascotRequest.FaceSick,
        MascotMood.Surprised => MascotRequest.FaceSurprised,
        MascotMood.Out => MascotRequest.FaceOut,
        MascotMood.Stale => MascotRequest.FaceStale,
        _ => null,
    };

    /// <summary>「勿擾到明天」：明天早上 8 點（本機時區）</summary>
    public static DateTime TomorrowMorning(DateTime localNow) => localNow.Date.AddDays(1).AddHours(8);
}

/// <summary>收合時 AI 工作中的思考泡泡（ADR-0021 第 4 節）：三個小點依序亮起，三顆全亮後清空重來。
/// 每一步要能整除一輪的長度，循環播放時接回開頭才看不出斷點</summary>
public static class MascotThinking
{
    /// <summary>每多亮一顆的目標間隔（參考頁 260 毫秒）</summary>
    public const double TargetStepMs = 260;

    /// <summary>一輪 loop 毫秒裡每一步的長度：一輪走整數次「0 → 1 → 2 → 3 顆」，最接近目標間隔</summary>
    public static double StepMs(double loop) =>
        loop / (Math.Max(1, Math.Round(loop / (TargetStepMs * 4), MidpointRounding.AwayFromZero)) * 4);

    /// <summary>第 t 毫秒亮了幾顆（0…3）</summary>
    public static int Dots(long t, double loop) => (int)Math.Floor(t % loop / StepMs(loop)) % 4;
}
