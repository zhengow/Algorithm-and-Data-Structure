//+------------------------------------------------------------------+
//|                                                   VersionC EA    |
//|  实现：用户描述的“版本C”15分钟结构策略（A/B + ATR Buffer + 分批） |
//|  平台：MetaTrader 5 (MQL5)                                       |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

//========================
// 输入参数
//========================
input long   InpMagic                = 20251227;   // 魔术号
input double InpLots                 = 0.10;       // 固定手数
input int    InpSlippagePoints       = 30;         // 允许滑点(点)

input ENUM_TIMEFRAMES InpTF          = PERIOD_M15; // 策略周期(建议M15)

input int    InpATRPeriod            = 14;         // ATR周期
input double InpBufferATRMult        = 0.25;       // Buffer = ATR * 0.25
input double InpMaxRiskATRMult       = 1.50;       // 风险约束：<= ATR * 1.5

input double InpMinMovePct           = 0.0001;     // 每根K线最小涨跌幅(0.01% = 0.0001)
input int    InpObserveBars          = 8;          // 观察期(8根15min=2小时)
input int    InpMaxNoNewExtremeBars  = 10;         // 无创新高/新低的最大持仓K数

input double InpPartial1Pct          = 0.40;       // 1R时平仓比例(第一段)
input double InpPartial2Pct          = 0.40;       // 结构转弱时再平仓比例(第二段)

input bool   InpUseRealVolume        = false;      // 用 real_volume(若有)；否则用 tick_volume
input bool   InpOnePositionOnly      = true;       // 单品种单仓

//========================
// 全局对象/状态
//========================
CTrade trade;
int    atr_handle = INVALID_HANDLE;

enum ESignalState
{
  SIG_NONE = 0,
  SIG_WAIT_LONG = 1,
  SIG_WAIT_SHORT = 2
};

ESignalState g_sig_state = SIG_NONE;

// 信号A/B的结构信息（等待入场时使用）
double   g_sig_A_low = 0.0;
double   g_sig_B_high = 0.0;
double   g_sig_buffer = 0.0;        // Buffer = ATR*0.25（信号生成时记录）
datetime g_sig_time = 0;            // 触发信号（第4根）K线的 time
int      g_obs_left = 0;            // 观察期剩余根数

// 持仓管理信息（入场后使用）
double   g_entry_price = 0.0;
double   g_init_volume = 0.0;
double   g_stop_price  = 0.0;       // 逻辑止损（收盘确认）
double   g_R           = 0.0;       // 初始风险R
bool     g_partial1_done = false;
bool     g_partial2_done = false;
int      g_no_new_extreme_bars = 0;  // 距离最近一次创新高/新低的bar计数
double   g_high_watermark = 0.0;     // 多单：入场后最高high
double   g_low_watermark  = 0.0;     // 空单：入场后最低low

datetime g_last_bar_time = 0;        // 用于检测新bar

//========================
// 工具函数
//========================
string GVPrefix()
{
  // 终端全局变量名：尽量唯一
  return StringFormat("VCEA_%s_%I64d_%d_", _Symbol, (long long)InpMagic, (int)InpTF);
}

void SavePositionStateToGV()
{
  string p = GVPrefix();
  GlobalVariableSet(p + "entry", g_entry_price);
  GlobalVariableSet(p + "initvol", g_init_volume);
  GlobalVariableSet(p + "stop", g_stop_price);
  GlobalVariableSet(p + "R", g_R);
  GlobalVariableSet(p + "p1", g_partial1_done ? 1.0 : 0.0);
  GlobalVariableSet(p + "p2", g_partial2_done ? 1.0 : 0.0);
  GlobalVariableSet(p + "nn", (double)g_no_new_extreme_bars);
  GlobalVariableSet(p + "hh", g_high_watermark);
  GlobalVariableSet(p + "ll", g_low_watermark);
}

void ClearPositionStateGV()
{
  string p = GVPrefix();
  GlobalVariableDel(p + "entry");
  GlobalVariableDel(p + "initvol");
  GlobalVariableDel(p + "stop");
  GlobalVariableDel(p + "R");
  GlobalVariableDel(p + "p1");
  GlobalVariableDel(p + "p2");
  GlobalVariableDel(p + "nn");
  GlobalVariableDel(p + "hh");
  GlobalVariableDel(p + "ll");
}

void TryLoadPositionStateFromGV()
{
  string p = GVPrefix();
  if(!GlobalVariableCheck(p + "stop"))
    return;

  g_entry_price = GlobalVariableGet(p + "entry");
  g_init_volume = GlobalVariableGet(p + "initvol");
  g_stop_price  = GlobalVariableGet(p + "stop");
  g_R           = GlobalVariableGet(p + "R");
  g_partial1_done = (GlobalVariableGet(p + "p1") > 0.5);
  g_partial2_done = (GlobalVariableGet(p + "p2") > 0.5);
  g_no_new_extreme_bars = (int)GlobalVariableGet(p + "nn");
  g_high_watermark = GlobalVariableGet(p + "hh");
  g_low_watermark  = GlobalVariableGet(p + "ll");
}

double NormalizeVolume(const double vol)
{
  double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if(step <= 0.0) step = vmin;

  double v = vol;
  if(v < vmin) v = vmin;
  if(v > vmax) v = vmax;

  // 向下取整到step
  v = MathFloor(v / step) * step;
  if(v < vmin) v = vmin;
  return v;
}

bool GetRates(MqlRates &rates[], const int need)
{
  ArraySetAsSeries(rates, true);
  int copied = CopyRates(_Symbol, InpTF, 0, need, rates);
  return (copied >= need);
}

double GetATR(const int shift)
{
  if(atr_handle == INVALID_HANDLE) return 0.0;
  double buf[1];
  ArraySetAsSeries(buf, true);
  int copied = CopyBuffer(atr_handle, 0, shift, 1, buf);
  if(copied != 1) return 0.0;
  return buf[0];
}

long GetBarVolume(const MqlRates &r)
{
  if(InpUseRealVolume)
    return (long)r.real_volume;
  return (long)r.tick_volume;
}

bool IsBullBar(const MqlRates &r)
{
  if(r.close <= r.open) return false;
  double pct = (r.close / r.open) - 1.0;
  return (pct >= InpMinMovePct);
}

bool IsBearBar(const MqlRates &r)
{
  if(r.close >= r.open) return false;
  double pct = (r.close / r.open) - 1.0;
  return (pct <= -InpMinMovePct);
}

// 入场触发条件（观察期内的“低点不破且高点上移/高点不破且低点下移”）
bool EntryTriggerLong(const MqlRates &cur, const MqlRates &prev)
{
  // “低点不破”：low >= prev.low；“高点上移”：high > prev.high
  // 同时按描述加一个“收盘价不破上一根低点”：close >= prev.low
  if(cur.low < prev.low) return false;
  if(cur.high <= prev.high) return false;
  if(cur.close < prev.low) return false;
  return true;
}

bool EntryTriggerShort(const MqlRates &cur, const MqlRates &prev)
{
  // “高点不破”：high <= prev.high；“低点下移”：low < prev.low
  // 同时“收盘价不破上一根高点”：close <= prev.high
  if(cur.high > prev.high) return false;
  if(cur.low >= prev.low) return false;
  if(cur.close > prev.high) return false;
  return true;
}

// 检测结构信号A/B（最近4根已收盘K线：shift=4..1）
bool DetectSignalA(MqlRates &rates[], double &A_low, double &buffer_out, datetime &sig_time)
{
  // 需要至少 rates[4]..rates[1] 为已收盘
  for(int i = 4; i >= 1; --i)
  {
    if(!IsBullBar(rates[i])) return false;
  }

  long v1 = GetBarVolume(rates[4]);
  long v4 = GetBarVolume(rates[1]);
  if(v4 <= v1) return false;

  A_low = rates[1].low;
  for(int i = 2; i <= 4; ++i)
    A_low = MathMin(A_low, rates[i].low);

  double atr = GetATR(1); // 以信号生成时（第4根收盘）对应bar的ATR
  if(atr <= 0.0) return false;
  buffer_out = atr * InpBufferATRMult;
  sig_time = rates[1].time;
  return true;
}

bool DetectSignalB(MqlRates &rates[], double &B_high, double &buffer_out, datetime &sig_time)
{
  for(int i = 4; i >= 1; --i)
  {
    if(!IsBearBar(rates[i])) return false;
  }

  long v1 = GetBarVolume(rates[4]);
  long v4 = GetBarVolume(rates[1]);
  if(v4 <= v1) return false;

  B_high = rates[1].high;
  for(int i = 2; i <= 4; ++i)
    B_high = MathMax(B_high, rates[i].high);

  double atr = GetATR(1);
  if(atr <= 0.0) return false;
  buffer_out = atr * InpBufferATRMult;
  sig_time = rates[1].time;
  return true;
}

bool HasOurPosition(ENUM_POSITION_TYPE &ptype, double &pvolume, double &popen)
{
  if(!PositionSelect(_Symbol)) return false;
  long magic = (long)PositionGetInteger(POSITION_MAGIC);
  if(magic != InpMagic) return false;
  ptype  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  pvolume= PositionGetDouble(POSITION_VOLUME);
  popen  = PositionGetDouble(POSITION_PRICE_OPEN);
  return true;
}

bool ClosePartialByTargetVolume(const double target_close)
{
  if(target_close <= 0.0) return false;
  ENUM_POSITION_TYPE ptype;
  double pvol, popen;
  if(!HasOurPosition(ptype, pvol, popen)) return false;

  double vol_to_close = MathMin(target_close, pvol);
  vol_to_close = NormalizeVolume(vol_to_close);

  // 如果因为步进/最小手数导致无法部分平仓，则直接全平
  double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  if(vol_to_close < vmin || (pvol - vol_to_close) < vmin)
    return trade.PositionClose(_Symbol);

  return trade.PositionClosePartial(_Symbol, vol_to_close);
}

void ResetSignal()
{
  g_sig_state = SIG_NONE;
  g_sig_A_low = 0.0;
  g_sig_B_high = 0.0;
  g_sig_buffer = 0.0;
  g_sig_time = 0;
  g_obs_left = 0;
}

void ResetPositionState()
{
  g_entry_price = 0.0;
  g_init_volume = 0.0;
  g_stop_price  = 0.0;
  g_R = 0.0;
  g_partial1_done = false;
  g_partial2_done = false;
  g_no_new_extreme_bars = 0;
  g_high_watermark = 0.0;
  g_low_watermark  = 0.0;
  ClearPositionStateGV();
}

//========================
// 核心逻辑：每根15min收盘处理
//========================
void ManageOpenPosition(MqlRates &rates[])
{
  ENUM_POSITION_TYPE ptype;
  double pvol, popen;
  if(!HasOurPosition(ptype, pvol, popen))
    return;

  // 用最近一根已收盘bar（shift=1）作为“收盘确认”
  const MqlRates &cur = rates[1];
  const MqlRates &prev= rates[2];

  // 1) 收盘确认止损（包含初始止损与移动到开仓价后的止损）
  if(ptype == POSITION_TYPE_BUY)
  {
    if(g_stop_price > 0.0 && cur.close < g_stop_price)
    {
      trade.PositionClose(_Symbol);
      ResetPositionState();
      ResetSignal();
      return;
    }
  }
  else if(ptype == POSITION_TYPE_SELL)
  {
    if(g_stop_price > 0.0 && cur.close > g_stop_price)
    {
      trade.PositionClose(_Symbol);
      ResetPositionState();
      ResetSignal();
      return;
    }
  }

  // 2) 维护创新高/新低水位与“无创新高/新低计数”
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if(point <= 0.0) point = 0.00001;

  if(ptype == POSITION_TYPE_BUY)
  {
    if(g_high_watermark <= 0.0) g_high_watermark = cur.high;
    if(cur.high > g_high_watermark + point)
    {
      g_high_watermark = cur.high;
      g_no_new_extreme_bars = 0;
    }
    else
    {
      g_no_new_extreme_bars++;
    }
  }
  else
  {
    if(g_low_watermark <= 0.0) g_low_watermark = cur.low;
    if(cur.low < g_low_watermark - point)
    {
      g_low_watermark = cur.low;
      g_no_new_extreme_bars = 0;
    }
    else
    {
      g_no_new_extreme_bars++;
    }
  }

  // 3) 1R触发：平40%，剩余止损移到开仓价（仍按收盘确认）
  if(!g_partial1_done && g_R > 0.0)
  {
    bool reach_1R = false;
    if(ptype == POSITION_TYPE_BUY)
      reach_1R = (cur.close - g_entry_price) >= g_R;
    else
      reach_1R = (g_entry_price - cur.close) >= g_R;

    if(reach_1R)
    {
      double target_close = g_init_volume * InpPartial1Pct;
      ClosePartialByTargetVolume(target_close);
      g_partial1_done = true;
      g_stop_price = g_entry_price; // 移到开仓价
      SavePositionStateToGV();
    }
  }

  // 4) 结构转弱：连续两根反向K线 + 第二根突破第一根（多：第二根更低；空：第二根更高）再平40%
  if(g_partial1_done && !g_partial2_done)
  {
    if(ptype == POSITION_TYPE_BUY)
    {
      if(IsBearBar(prev) && IsBearBar(cur) && (cur.low < prev.low))
      {
        double target_close = g_init_volume * InpPartial2Pct;
        ClosePartialByTargetVolume(target_close);
        g_partial2_done = true;
        SavePositionStateToGV();
      }
    }
    else
    {
      if(IsBullBar(prev) && IsBullBar(cur) && (cur.high > prev.high))
      {
        double target_close = g_init_volume * InpPartial2Pct;
        ClosePartialByTargetVolume(target_close);
        g_partial2_done = true;
        SavePositionStateToGV();
      }
    }
  }

  // 每根bar收盘后持久化一次（确保重启可继续按“收盘确认止损/分批/时间退出”运行）
  SavePositionStateToGV();

  // 5) 尾部退出：满足任一条件全部平仓
  // 5.1 持仓时间耗尽：超过10根且未再创新高/新低（用“距最近创新高/新低bar计数”实现）
  if(g_no_new_extreme_bars >= InpMaxNoNewExtremeBars)
  {
    trade.PositionClose(_Symbol);
    ResetPositionState();
    ResetSignal();
    return;
  }

  // 5.2 出现完整反向结构信号（多单遇到B；空单遇到A）
  double tmp_level, tmp_buf;
  datetime tmp_time;
  if(ptype == POSITION_TYPE_BUY)
  {
    if(DetectSignalB(rates, tmp_level, tmp_buf, tmp_time))
    {
      trade.PositionClose(_Symbol);
      ResetPositionState();
      ResetSignal();
      return;
    }
  }
  else
  {
    if(DetectSignalA(rates, tmp_level, tmp_buf, tmp_time))
    {
      trade.PositionClose(_Symbol);
      ResetPositionState();
      ResetSignal();
      return;
    }
  }

  // 5.3 结构跟踪止损：15min收盘有效跌破/突破最近2根K线极值
  double recent2_low  = MathMin(rates[1].low, rates[2].low);
  double recent2_high = MathMax(rates[1].high, rates[2].high);
  if(ptype == POSITION_TYPE_BUY)
  {
    if(rates[1].close < recent2_low)
    {
      trade.PositionClose(_Symbol);
      ResetPositionState();
      ResetSignal();
      return;
    }
  }
  else
  {
    if(rates[1].close > recent2_high)
    {
      trade.PositionClose(_Symbol);
      ResetPositionState();
      ResetSignal();
      return;
    }
  }
}

void ProcessSignalAndEntry(MqlRates &rates[])
{
  // 若已有仓位，则不再寻找入场（单仓模式）
  if(InpOnePositionOnly)
  {
    ENUM_POSITION_TYPE ptype;
    double pvol, popen;
    if(HasOurPosition(ptype, pvol, popen))
      return;
  }

  const MqlRates &cur = rates[1];   // 最近已收盘
  const MqlRates &prev= rates[2];   // 上一根已收盘

  // 1) 若当前无等待信号，则尝试生成信号A/B
  if(g_sig_state == SIG_NONE)
  {
    double level, buf;
    datetime stime;
    if(DetectSignalA(rates, level, buf, stime))
    {
      g_sig_state = SIG_WAIT_LONG;
      g_sig_A_low = level;
      g_sig_buffer = buf;
      g_sig_time = stime;
      g_obs_left = InpObserveBars;
      return;
    }
    if(DetectSignalB(rates, level, buf, stime))
    {
      g_sig_state = SIG_WAIT_SHORT;
      g_sig_B_high = level;
      g_sig_buffer = buf;
      g_sig_time = stime;
      g_obs_left = InpObserveBars;
      return;
    }
    return;
  }

  // 2) 观察期：信号失效 / 入场触发 / 超时
  if(g_obs_left <= 0)
  {
    ResetSignal();
    return;
  }

  if(g_sig_state == SIG_WAIT_LONG)
  {
    double stop_exec = g_sig_A_low - g_sig_buffer;

    // 观察期内尚未进场：若收盘有效跌破 A_low - Buffer，则信号失效
    if(cur.close < stop_exec)
    {
      ResetSignal();
      return;
    }

    // 入场触发
    if(EntryTriggerLong(cur, prev))
    {
      // 风险约束：开仓价 - (A_low-Buffer) <= ATR*1.5（ATR用当前bar的ATR）
      double atr_now = GetATR(1);
      if(atr_now <= 0.0)
      {
        ResetSignal();
        return;
      }

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double entry = (ask > 0.0 ? ask : cur.close);
      double risk = entry - stop_exec;

      if(risk <= 0.0 || risk > atr_now * InpMaxRiskATRMult)
      {
        ResetSignal(); // 放弃该笔交易
        return;
      }

      double vol = NormalizeVolume(InpLots);
      trade.SetExpertMagicNumber(InpMagic);
      trade.SetDeviationInPoints(InpSlippagePoints);

      if(trade.Buy(vol, _Symbol))
      {
        // 回填实际成交信息（防止与预估entry偏差）
        ENUM_POSITION_TYPE ptype;
        double pvol, popen;
        if(HasOurPosition(ptype, pvol, popen) && ptype == POSITION_TYPE_BUY)
        {
          g_entry_price = popen;
          g_init_volume = pvol;
        }
        else
        {
          g_entry_price = entry;
          g_init_volume = vol;
        }
        g_stop_price  = stop_exec;      // 收盘确认止损价
        g_R = g_entry_price - g_stop_price;
        g_partial1_done = false;
        g_partial2_done = false;
        g_no_new_extreme_bars = 0;
        g_high_watermark = cur.high;
        SavePositionStateToGV();
        ResetSignal(); // 入场后不再等待该信号
      }
      else
      {
        // 下单失败：保守起见取消本次资格
        ResetSignal();
      }
      return;
    }

    g_obs_left--;
    return;
  }

  if(g_sig_state == SIG_WAIT_SHORT)
  {
    double stop_exec = g_sig_B_high + g_sig_buffer;

    // 观察期内尚未进场：若收盘有效突破 B_high + Buffer，则信号失效
    if(cur.close > stop_exec)
    {
      ResetSignal();
      return;
    }

    // 入场触发
    if(EntryTriggerShort(cur, prev))
    {
      double atr_now = GetATR(1);
      if(atr_now <= 0.0)
      {
        ResetSignal();
        return;
      }

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double entry = (bid > 0.0 ? bid : cur.close);
      double risk = stop_exec - entry;

      if(risk <= 0.0 || risk > atr_now * InpMaxRiskATRMult)
      {
        ResetSignal();
        return;
      }

      double vol = NormalizeVolume(InpLots);
      trade.SetExpertMagicNumber(InpMagic);
      trade.SetDeviationInPoints(InpSlippagePoints);

      if(trade.Sell(vol, _Symbol))
      {
        ENUM_POSITION_TYPE ptype;
        double pvol, popen;
        if(HasOurPosition(ptype, pvol, popen) && ptype == POSITION_TYPE_SELL)
        {
          g_entry_price = popen;
          g_init_volume = pvol;
        }
        else
        {
          g_entry_price = entry;
          g_init_volume = vol;
        }
        g_stop_price  = stop_exec;
        g_R = g_stop_price - g_entry_price;
        g_partial1_done = false;
        g_partial2_done = false;
        g_no_new_extreme_bars = 0;
        g_low_watermark = cur.low;
        SavePositionStateToGV();
        ResetSignal();
      }
      else
      {
        ResetSignal();
      }
      return;
    }

    g_obs_left--;
    return;
  }
}

//========================
// EA生命周期
//========================
int OnInit()
{
  trade.SetExpertMagicNumber(InpMagic);
  trade.SetDeviationInPoints(InpSlippagePoints);

  atr_handle = iATR(_Symbol, InpTF, InpATRPeriod);
  if(atr_handle == INVALID_HANDLE)
    return INIT_FAILED;

  ResetSignal();
  ResetPositionState();

  // 若EA重启且已有本EA仓位，尝试从终端全局变量恢复状态
  ENUM_POSITION_TYPE ptype;
  double pvol, popen;
  if(HasOurPosition(ptype, pvol, popen))
  {
    TryLoadPositionStateFromGV();
    // 若未能恢复（例如全局变量不存在），至少回填成交信息
    if(g_entry_price <= 0.0) g_entry_price = popen;
    if(g_init_volume <= 0.0) g_init_volume = pvol;
  }

  g_last_bar_time = iTime(_Symbol, InpTF, 0);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  if(atr_handle != INVALID_HANDLE)
    IndicatorRelease(atr_handle);
}

void OnTick()
{
  // 仅在新bar出现后，对“上一根bar收盘”做一次处理
  datetime t0 = iTime(_Symbol, InpTF, 0);
  if(t0 == 0) return;
  if(t0 == g_last_bar_time) return;
  g_last_bar_time = t0;

  MqlRates rates[60];
  if(!GetRates(rates, 30)) return; // 至少保证有足够历史用于4根结构+2根跟踪+ATR

  // 先管理已有持仓（止损/分批/退出）
  ManageOpenPosition(rates);

  // 再处理信号与可能的入场（若单仓且已持仓会自动跳过）
  ProcessSignalAndEntry(rates);
}

