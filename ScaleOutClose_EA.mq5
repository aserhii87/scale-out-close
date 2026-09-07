//+------------------------------------------------------------------+
//|                                        ScaleOutClose_EA.mq5      |
//| A manual on-chart UI tool: an always-visible panel listing every |
//| open position on the chart's symbol. Each row belongs to ONE      |
//| position and shows the CURRENT remaining lot size plus FIVE        |
//| independent buttons:                                              |
//|                                                                    |
//|   [Scale out]      - market-closes part of the position, 3-step   |
//|                       cadence per ticket (click counter tracked    |
//|                       in memory only):                             |
//|                         Click 1 - closes 50% of current volume.    |
//|                         Click 2 - closes 50% of what's left        |
//|                                   (25% of the original).           |
//|                         Click 3 - closes whatever remains, the     |
//|                                   whole row disappears.            |
//|                       Dust guard: at click 1 or 2, if half of the  |
//|                       current volume - or what would remain after |
//|                       closing it - is below SYMBOL_VOLUME_MIN, the |
//|                       position is closed IN FULL right away        |
//|                       instead of leaving an unsplittable remainder|
//|                       (so 2 clicks can be enough to fully close).  |
//|                       This button has no side effect on the other |
//|                       four.                                        |
//|                                                                    |
//|   [BE]              - moves the position's SL to entry +/-         |
//|                       InpBreakevenBufferPoints points (locking in |
//|                       a small profit once price has moved that far |
//|                       past entry, the PROFIT side). ALWAYS stays   |
//|                       on the row - never auto-hides, so it can be  |
//|                       re-applied any time (e.g. after the user      |
//|                       manually moved the SL elsewhere).            |
//|                                                                    |
//|   [SL]              - sets a protective SL at entry -/+            |
//|                       InpSetSlPoints points (the normal, LOSING    |
//|                       side, unlike [BE]) - meant for a position    |
//|                       opened manually by market with no stop at   |
//|                       all. Also always stays on the row, so it can |
//|                       reset the SL back to this fixed distance at  |
//|                       any time.                                    |
//|                                                                    |
//|   [TP]              - sets a take-profit at entry +/-              |
//|                       InpSetTpPoints points (the PROFIT side, same |
//|                       direction as [BE] but as an actual TP, not a |
//|                       stop) - for a position opened with no target |
//|                       at all. Also always stays on the row.        |
//|                                                                    |
//|   [Close]           - market-closes the ENTIRE remaining position  |
//|                       immediately, regardless of the [Scale out]   |
//|                       click cadence. The row disappears once this  |
//|                       succeeds.                                    |
//|                                                                    |
//| All five actions only ever advance their own tracked state on a   |
//| CONFIRMED successful trade request - a failed attempt (rejected by |
//| the broker, blocked by permissions, etc.) never gets silently      |
//| treated as done, so re-clicking always retries safely.             |
//|                                                                    |
//| All close and SL/TP-move requests are hand-built MqlTradeRequest    |
//| structs sent directly via OrderSend() rather than through CTrade - |
//| CTrade's wrapper was observed to fail silently on this account     |
//| (false with retcode=0 and GetLastError()=0, i.e. it never reached  |
//| the trade server). The raw request path surfaces the real broker   |
//| retcode/comment so failures are actually diagnosable.               |
//|                                                                    |
//| Every click here is a single deliberate user action, not automatic |
//| per-tick/per-bar behavior - so real trade requests are appropriate |
//| here and are not "server spamming".                                |
//|                                                                    |
//| The [Scale out] click counter lives only in EA memory and resets   |
//| if the EA is removed/reattached mid-sequence.                      |
//|                                                                    |
//| This is a utility UI tool, not a strategy - it works with whatever |
//| symbol the chart it is attached to shows, with no restriction to   |
//| XAUUSD.                                                            |
//+------------------------------------------------------------------+
#property copyright "ScaleOutClose_EA"
#property version   "5.00"
#property strict

input int    InpPanelX                 = 3;   // panel X coordinate (pixels from the corner)
input int    InpPanelY                 = 100; // panel Y coordinate (pixels from the corner)
const int    RefreshSeconds            = 1;   // panel refresh interval, seconds (fixed, not user-configurable)
input int    InpDeviationPoints        = 100; // allowed price deviation for the market close, points
input double InpBreakevenBufferPoints  = 70;  // [BE] moves SL to entry +/- this many points
input double InpSetSlPoints            = 200; // [SL] sets an initial SL at entry -/+ this many points
input double InpSetTpPoints            = 300; // [TP] sets an initial TP at entry +/- this many points
input ulong  InpMagic                  = 0;   // magic number stamped on close deals (0 = leave default)

string g_headerName     = "SO_Header";
string g_statusName     = "SO_Status";
string g_scaleBtnPrefix = "SO_Row_";
string g_beBtnPrefix    = "SO_BE_";
string g_setSlBtnPrefix = "SO_SETSL_";
string g_setTpBtnPrefix = "SO_SETTP_";
string g_delBtnPrefix   = "SO_DEL_";
int    g_scaleBtnWidth  = 200;
int    g_delBtnWidth    = 50;
int    g_charWidthPx    = 7;  // rough average glyph width for the default button font, px
int    g_btnPaddingPx   = 18; // left+right padding inside a button, px
int    g_btnGap         = 4;
int    g_rowHeight      = 24;
int    g_rowGap         = 2;

color  g_colorProfit      = clrSeaGreen;
color  g_colorLoss        = clrIndianRed;
color  g_colorText        = clrWhite;
color  g_colorBEButton    = clrDarkSlateGray;
color  g_colorSetSlButton = clrDarkGoldenrod;
color  g_colorSetTpButton = clrTeal;
color  g_colorDelButton   = clrFireBrick;
color  g_colorLabelText   = clrBlack; // header/status text - dark, readable on a white chart theme
int    g_statusFontSize   = 14;       // status line font size (bigger than the default Comment() font)

struct ScaleState
  {
   ulong ticket;
   int   clicks;
  };

ScaleState g_states[];

void   CreateHeader();
void   RefreshPanel();
void   ClearRows();
void   HandleScaleOutClick(const ulong ticket);
void   HandleBreakevenClick(const ulong ticket);
void   HandleSetSlClick(const ulong ticket);
void   HandleSetTpClick(const ulong ticket);
void   HandleDeleteClick(const ulong ticket);
bool   TradingAllowed(string &reasonOut);
bool   ClosePositionVolume(const ulong ticket, const double volume, int &retcodeOut, string &commentOut, int &lastErrorOut);
bool   SetBreakevenSL(const ulong ticket, const double bufferPoints, int &retcodeOut, string &commentOut, int &lastErrorOut);
bool   SetInitialSL(const ulong ticket, const double points, int &retcodeOut, string &commentOut, int &lastErrorOut);
bool   SetInitialTP(const ulong ticket, const double points, int &retcodeOut, string &commentOut, int &lastErrorOut);
int    FindOrAddState(const ulong ticket);
void   RemoveState(const ulong ticket);
void   PruneStates();
double NormalizeVolume(const double vol, const double step);
int    TextWidthPx(const string text);
ulong  TicketFromObjectName(const string name, const string prefix);
string Now();
void   LogEvent(const string event, const string details);
void   ShowStatus(const string text);

//+------------------------------------------------------------------+
int OnInit()
  {
// one-time purge of background-box objects created by an earlier version
// of this panel (now retired) - their names are no longer referenced
// anywhere in the code, so they'd otherwise sit on the chart forever.
   ObjectDelete(0, "SO_HeaderBg");
   ObjectDelete(0, "SO_Row_none_bg");

   CreateHeader();
   RefreshPanel();
   EventSetTimer(RefreshSeconds);
   LogEvent("INIT", StringFormat("symbol=%s refresh_sec=%d breakeven_buffer=%.0f set_sl_points=%.0f set_tp_points=%.0f",
            _Symbol, RefreshSeconds, InpBreakevenBufferPoints, InpSetSlPoints, InpSetTpPoints));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectDelete(0, g_headerName);
   ObjectDelete(0, g_statusName);
   ClearRows();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   RefreshPanel();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(StringFind(sparam, g_scaleBtnPrefix) == 0)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ulong ticket = TicketFromObjectName(sparam, g_scaleBtnPrefix);
      HandleScaleOutClick(ticket);
      RefreshPanel();
      return;
     }

   if(StringFind(sparam, g_beBtnPrefix) == 0)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ulong ticket = TicketFromObjectName(sparam, g_beBtnPrefix);
      HandleBreakevenClick(ticket);
      RefreshPanel();
      return;
     }

   if(StringFind(sparam, g_setSlBtnPrefix) == 0)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ulong ticket = TicketFromObjectName(sparam, g_setSlBtnPrefix);
      HandleSetSlClick(ticket);
      RefreshPanel();
      return;
     }

   if(StringFind(sparam, g_setTpBtnPrefix) == 0)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ulong ticket = TicketFromObjectName(sparam, g_setTpBtnPrefix);
      HandleSetTpClick(ticket);
      RefreshPanel();
      return;
     }

   if(StringFind(sparam, g_delBtnPrefix) == 0)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ulong ticket = TicketFromObjectName(sparam, g_delBtnPrefix);
      HandleDeleteClick(ticket);
      RefreshPanel();
      return;
     }
  }

//+------------------------------------------------------------------+
void CreateHeader()
  {
   ObjectDelete(0, g_headerName);

   string headerText = StringFormat("Scale out (50%%/50%%/rest)  |  TP %.0fp  |  BE +%.0fp  |  SL %.0fp  |  Close:",
            InpSetTpPoints, InpBreakevenBufferPoints, InpSetSlPoints);

   ObjectCreate(0, g_headerName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_headerName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, g_headerName, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, g_headerName, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetString(0, g_headerName, OBJPROP_TEXT, headerText);
   ObjectSetInteger(0, g_headerName, OBJPROP_COLOR, g_colorLabelText);
   ObjectSetInteger(0, g_headerName, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, g_headerName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_headerName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, g_headerName, OBJPROP_ZORDER, 100);
  }

//+------------------------------------------------------------------+
//| Shows the latest action result as an on-chart label instead of   |
//| the native Comment() - Comment() has no font-size control, this  |
//| label does (g_statusFontSize).                                    |
//+------------------------------------------------------------------+
void ShowStatus(const string text)
  {
   if(ObjectFind(0, g_statusName) < 0)
     {
      ObjectCreate(0, g_statusName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_statusName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_statusName, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, g_statusName, OBJPROP_YDISTANCE, InpPanelY - 22);
      ObjectSetInteger(0, g_statusName, OBJPROP_COLOR, g_colorLabelText);
      ObjectSetInteger(0, g_statusName, OBJPROP_FONTSIZE, g_statusFontSize);
      ObjectSetInteger(0, g_statusName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_statusName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, g_statusName, OBJPROP_ZORDER, 100);
     }
   ObjectSetString(0, g_statusName, OBJPROP_TEXT, text);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Rebuilds the position list every call - always up to date. Safe  |
//| to call on a timer since it only touches chart objects, no       |
//| server requests.                                                  |
//+------------------------------------------------------------------+
void RefreshPanel()
  {
   PruneStates();
   ClearRows();

   int row = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);

      int rowY = InpPanelY + 18 + row * (g_rowHeight + g_rowGap);
      int beWidth    = TextWidthPx("BE");
      int setSlWidth = TextWidthPx("SL");
      int setTpWidth = TextWidthPx("TP");
      int setTpX = InpPanelX + g_scaleBtnWidth + g_btnGap;
      int beX    = setTpX + setTpWidth + g_btnGap;
      int setSlX = beX + beWidth + g_btnGap;
      int delX   = setSlX + setSlWidth + g_btnGap;

      string scaleLabel = StringFormat("# %I64u | %.2f | $%.2f", ticket, volume, profit);
      color  scaleColor = (profit >= 0) ? g_colorProfit : g_colorLoss;

      string scaleObjName = g_scaleBtnPrefix + IntegerToString(ticket);
      ObjectCreate(0, scaleObjName, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, scaleObjName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, scaleObjName, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, scaleObjName, OBJPROP_YDISTANCE, rowY);
      ObjectSetInteger(0, scaleObjName, OBJPROP_XSIZE, g_scaleBtnWidth);
      ObjectSetInteger(0, scaleObjName, OBJPROP_YSIZE, g_rowHeight);
      ObjectSetString(0, scaleObjName, OBJPROP_TEXT, scaleLabel);
      ObjectSetInteger(0, scaleObjName, OBJPROP_COLOR, g_colorText);
      ObjectSetInteger(0, scaleObjName, OBJPROP_BGCOLOR, scaleColor);
      ObjectSetInteger(0, scaleObjName, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, scaleObjName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, scaleObjName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, scaleObjName, OBJPROP_ZORDER, 100);

      string beObjName = g_beBtnPrefix + IntegerToString(ticket);
      ObjectCreate(0, beObjName, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, beObjName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, beObjName, OBJPROP_XDISTANCE, beX);
      ObjectSetInteger(0, beObjName, OBJPROP_YDISTANCE, rowY);
      ObjectSetInteger(0, beObjName, OBJPROP_XSIZE, beWidth);
      ObjectSetInteger(0, beObjName, OBJPROP_YSIZE, g_rowHeight);
      ObjectSetString(0, beObjName, OBJPROP_TEXT, "BE");
      ObjectSetInteger(0, beObjName, OBJPROP_COLOR, g_colorText);
      ObjectSetInteger(0, beObjName, OBJPROP_BGCOLOR, g_colorBEButton);
      ObjectSetInteger(0, beObjName, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, beObjName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, beObjName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, beObjName, OBJPROP_ZORDER, 100);

      string setSlObjName = g_setSlBtnPrefix + IntegerToString(ticket);
      ObjectCreate(0, setSlObjName, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, setSlObjName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, setSlObjName, OBJPROP_XDISTANCE, setSlX);
      ObjectSetInteger(0, setSlObjName, OBJPROP_YDISTANCE, rowY);
      ObjectSetInteger(0, setSlObjName, OBJPROP_XSIZE, setSlWidth);
      ObjectSetInteger(0, setSlObjName, OBJPROP_YSIZE, g_rowHeight);
      ObjectSetString(0, setSlObjName, OBJPROP_TEXT, "SL");
      ObjectSetInteger(0, setSlObjName, OBJPROP_COLOR, g_colorText);
      ObjectSetInteger(0, setSlObjName, OBJPROP_BGCOLOR, g_colorSetSlButton);
      ObjectSetInteger(0, setSlObjName, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, setSlObjName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, setSlObjName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, setSlObjName, OBJPROP_ZORDER, 100);

      string setTpObjName = g_setTpBtnPrefix + IntegerToString(ticket);
      ObjectCreate(0, setTpObjName, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, setTpObjName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, setTpObjName, OBJPROP_XDISTANCE, setTpX);
      ObjectSetInteger(0, setTpObjName, OBJPROP_YDISTANCE, rowY);
      ObjectSetInteger(0, setTpObjName, OBJPROP_XSIZE, setTpWidth);
      ObjectSetInteger(0, setTpObjName, OBJPROP_YSIZE, g_rowHeight);
      ObjectSetString(0, setTpObjName, OBJPROP_TEXT, "TP");
      ObjectSetInteger(0, setTpObjName, OBJPROP_COLOR, g_colorText);
      ObjectSetInteger(0, setTpObjName, OBJPROP_BGCOLOR, g_colorSetTpButton);
      ObjectSetInteger(0, setTpObjName, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, setTpObjName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, setTpObjName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, setTpObjName, OBJPROP_ZORDER, 100);

      string delObjName = g_delBtnPrefix + IntegerToString(ticket);
      ObjectCreate(0, delObjName, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, delObjName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, delObjName, OBJPROP_XDISTANCE, delX);
      ObjectSetInteger(0, delObjName, OBJPROP_YDISTANCE, rowY);
      ObjectSetInteger(0, delObjName, OBJPROP_XSIZE, g_delBtnWidth);
      ObjectSetInteger(0, delObjName, OBJPROP_YSIZE, g_rowHeight);
      ObjectSetString(0, delObjName, OBJPROP_TEXT, "Close");
      ObjectSetInteger(0, delObjName, OBJPROP_COLOR, g_colorText);
      ObjectSetInteger(0, delObjName, OBJPROP_BGCOLOR, g_colorDelButton);
      ObjectSetInteger(0, delObjName, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, delObjName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, delObjName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, delObjName, OBJPROP_ZORDER, 100);

      row++;
     }

   if(row == 0)
     {
      string objName   = g_scaleBtnPrefix + "none";
      string noPosText = StringFormat("(no open positions on %s)", _Symbol);

      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, InpPanelY + 18);
      ObjectSetString(0, objName, OBJPROP_TEXT, noPosText);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, g_colorLabelText);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 100);
     }

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void ClearRows()
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_scaleBtnPrefix) == 0 || StringFind(name, g_beBtnPrefix) == 0 ||
         StringFind(name, g_setSlBtnPrefix) == 0 || StringFind(name, g_setTpBtnPrefix) == 0 ||
         StringFind(name, g_delBtnPrefix) == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
int TextWidthPx(const string text)
  {
   return StringLen(text) * g_charWidthPx + g_btnPaddingPx;
  }

//+------------------------------------------------------------------+
//| Checks every permission layer that can silently block a trade    |
//| request - EA algo-trading permission, terminal AutoTrading,       |
//| account trade permission, account expert-advisor permission.      |
//+------------------------------------------------------------------+
bool TradingAllowed(string &reasonOut)
  {
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      reasonOut = "EA algo-trading not allowed (chart Expert Advisors properties -> Common -> Allow Algo Trading)";
      return false;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      reasonOut = "AutoTrading is OFF in the terminal (toolbar button)";
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      reasonOut = "account does not allow trading (read-only / investor login?)";
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      reasonOut = "account does not allow Expert Advisor / algo trading";
      return false;
     }
   reasonOut = "";
   return true;
  }

//+------------------------------------------------------------------+
//| [Scale out] click: advances this ticket's click counter by one    |
//| and performs the corresponding action against the LIVE remaining |
//| volume. The counter only commits on a CONFIRMED successful close,|
//| so a failed click can simply be retried.                          |
//+------------------------------------------------------------------+
void HandleScaleOutClick(const ulong ticket)
  {
   string blockReason;
   if(!TradingAllowed(blockReason))
     {
      ShowStatus(StringFormat("[%s] Scale-out #%I64u: BLOCKED - %s", Now(), ticket, blockReason));
      LogEvent("SO_CLICK_BLOCKED", StringFormat("ticket=%I64u reason=%s", ticket, blockReason));
      return;
     }

   if(!PositionSelectByTicket(ticket))
     {
      ShowStatus(StringFormat("[%s] Scale-out: position #%I64u no longer exists", Now(), ticket));
      LogEvent("SO_CLICK_FAILED", StringFormat("ticket=%I64u reason=position_not_found", ticket));
      return;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   int idx          = FindOrAddState(ticket);
   int tentativeNum = g_states[idx].clicks + 1;

   bool   fullClose = false;
   double closeVol  = 0;

   if(tentativeNum >= 3)
     {
      fullClose = true;
      closeVol  = volume;
     }
   else
     {
      double half      = NormalizeVolume(volume / 2.0, step);
      double remainder = volume - half;

      if(half < minVol - 1e-8 || remainder < minVol - 1e-8)
        {
         fullClose = true;
         closeVol  = volume;
        }
      else
         closeVol = half;
     }

   int    retcode;
   string brokerComment;
   int    lastError;
   bool   ok = ClosePositionVolume(ticket, closeVol, retcode, brokerComment, lastError);

   string eventName = ok ? (fullClose ? "SO_CLOSED_FULL" : "SO_CLOSED_PARTIAL")
                          : (fullClose ? "SO_CLOSE_FAILED" : "SO_CLOSE_PARTIAL_FAILED");

   LogEvent(eventName, StringFormat("ticket=%I64u click=%d full=%d close_vol=%.2f volume_before=%.2f retcode=%d broker_comment=%s mql_error=%d",
            ticket, tentativeNum, fullClose, closeVol, volume, retcode, brokerComment, lastError));

   if(!ok)
     {
      ShowStatus(StringFormat("[%s] Scale-out #%I64u: close FAILED (retcode=%d, %s, err=%d) - click again to retry",
              Now(), ticket, retcode, brokerComment, lastError));
      return;
     }

   g_states[idx].clicks = tentativeNum;

   ShowStatus(StringFormat("[%s] Scale-out #%I64u: closed %.2f lots (click %d)%s", Now(), ticket, closeVol, tentativeNum,
           fullClose ? " - position fully closed" : ""));

   if(fullClose)
      RemoveState(ticket);
  }

//+------------------------------------------------------------------+
//| [BE] click: moves the position's SL to entry +/-                  |
//| InpBreakevenBufferPoints. Never auto-hides - can be re-clicked at |
//| any time (e.g. after the user manually moved the SL elsewhere).   |
//+------------------------------------------------------------------+
void HandleBreakevenClick(const ulong ticket)
  {
   string blockReason;
   if(!TradingAllowed(blockReason))
     {
      ShowStatus(StringFormat("[%s] BE #%I64u: BLOCKED - %s", Now(), ticket, blockReason));
      LogEvent("SO_BE_CLICK_BLOCKED", StringFormat("ticket=%I64u reason=%s", ticket, blockReason));
      return;
     }

   int    retcode;
   string brokerComment;
   int    lastError;
   bool   ok = SetBreakevenSL(ticket, InpBreakevenBufferPoints, retcode, brokerComment, lastError);

   LogEvent(ok ? "SO_BREAKEVEN_SET" : "SO_BREAKEVEN_SKIPPED",
            StringFormat("ticket=%I64u retcode=%d broker_comment=%s mql_error=%d", ticket, retcode, brokerComment, lastError));

   ShowStatus(ok
           ? StringFormat("[%s] BE #%I64u: SL moved to entry +/- %.0fp", Now(), ticket, InpBreakevenBufferPoints)
           : StringFormat("[%s] BE #%I64u: NOT set (%s) - click again to retry", Now(), ticket, brokerComment));
  }

//+------------------------------------------------------------------+
//| [SL] click: sets a protective SL at entry -/+ InpSetSlPoints (the |
//| normal, losing side) - meant for a position opened by market with |
//| no stop at all. Never auto-hides.                                  |
//+------------------------------------------------------------------+
void HandleSetSlClick(const ulong ticket)
  {
   string blockReason;
   if(!TradingAllowed(blockReason))
     {
      ShowStatus(StringFormat("[%s] SL #%I64u: BLOCKED - %s", Now(), ticket, blockReason));
      LogEvent("SO_SETSL_CLICK_BLOCKED", StringFormat("ticket=%I64u reason=%s", ticket, blockReason));
      return;
     }

   int    retcode;
   string brokerComment;
   int    lastError;
   bool   ok = SetInitialSL(ticket, InpSetSlPoints, retcode, brokerComment, lastError);

   LogEvent(ok ? "SO_SETSL_SET" : "SO_SETSL_SKIPPED",
            StringFormat("ticket=%I64u retcode=%d broker_comment=%s mql_error=%d", ticket, retcode, brokerComment, lastError));

   ShowStatus(ok
           ? StringFormat("[%s] SL #%I64u: SL set to entry -/+ %.0fp", Now(), ticket, InpSetSlPoints)
           : StringFormat("[%s] SL #%I64u: NOT set (%s) - click again to retry", Now(), ticket, brokerComment));
  }

//+------------------------------------------------------------------+
//| [TP] click: sets a take-profit at entry +/- InpSetTpPoints (the   |
//| profit side) - meant for a position opened with no target at all.|
//| Never auto-hides.                                                  |
//+------------------------------------------------------------------+
void HandleSetTpClick(const ulong ticket)
  {
   string blockReason;
   if(!TradingAllowed(blockReason))
     {
      ShowStatus(StringFormat("[%s] TP #%I64u: BLOCKED - %s", Now(), ticket, blockReason));
      LogEvent("SO_SETTP_CLICK_BLOCKED", StringFormat("ticket=%I64u reason=%s", ticket, blockReason));
      return;
     }

   int    retcode;
   string brokerComment;
   int    lastError;
   bool   ok = SetInitialTP(ticket, InpSetTpPoints, retcode, brokerComment, lastError);

   LogEvent(ok ? "SO_SETTP_SET" : "SO_SETTP_SKIPPED",
            StringFormat("ticket=%I64u retcode=%d broker_comment=%s mql_error=%d", ticket, retcode, brokerComment, lastError));

   ShowStatus(ok
           ? StringFormat("[%s] TP #%I64u: TP set to entry +/- %.0fp", Now(), ticket, InpSetTpPoints)
           : StringFormat("[%s] TP #%I64u: NOT set (%s) - click again to retry", Now(), ticket, brokerComment));
  }

//+------------------------------------------------------------------+
//| [Close] click: closes the ENTIRE remaining position immediately,  |
//| regardless of the [Scale out] click cadence. Only removes the     |
//| row's tracked state on a CONFIRMED success.                       |
//+------------------------------------------------------------------+
void HandleDeleteClick(const ulong ticket)
  {
   string blockReason;
   if(!TradingAllowed(blockReason))
     {
      ShowStatus(StringFormat("[%s] Close #%I64u: BLOCKED - %s", Now(), ticket, blockReason));
      LogEvent("SO_DEL_CLICK_BLOCKED", StringFormat("ticket=%I64u reason=%s", ticket, blockReason));
      return;
     }

   if(!PositionSelectByTicket(ticket))
     {
      ShowStatus(StringFormat("[%s] Close: position #%I64u no longer exists", Now(), ticket));
      LogEvent("SO_DEL_CLICK_FAILED", StringFormat("ticket=%I64u reason=position_not_found", ticket));
      return;
     }

   double volume = PositionGetDouble(POSITION_VOLUME);

   int    retcode;
   string brokerComment;
   int    lastError;
   bool   ok = ClosePositionVolume(ticket, volume, retcode, brokerComment, lastError);

   LogEvent(ok ? "SO_DELETE_CLOSED" : "SO_DELETE_FAILED",
            StringFormat("ticket=%I64u volume=%.2f retcode=%d broker_comment=%s mql_error=%d", ticket, volume, retcode, brokerComment, lastError));

   if(ok)
     {
      ShowStatus(StringFormat("[%s] Close #%I64u: position fully closed", Now(), ticket));
      RemoveState(ticket);
     }
   else
      ShowStatus(StringFormat("[%s] Close #%I64u: close FAILED (retcode=%d, %s, err=%d) - click again to retry",
              Now(), ticket, retcode, brokerComment, lastError));
  }

//+------------------------------------------------------------------+
//| Closes `volume` lots of `ticket` with a hand-built market order   |
//| sent directly via OrderSend() (bypassing CTrade, which was seen   |
//| to fail silently - false, retcode 0, GetLastError() 0 - on this   |
//| account/symbol without ever reaching the trade server).           |
//+------------------------------------------------------------------+
bool ClosePositionVolume(const ulong ticket, const double volume, int &retcodeOut, string &commentOut, int &lastErrorOut)
  {
   retcodeOut = 0;
   commentOut = "";
   lastErrorOut = 0;

   if(!PositionSelectByTicket(ticket))
     {
      commentOut = "position not found";
      return false;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   long   type    = PositionGetInteger(POSITION_TYPE);
   double posVol  = PositionGetDouble(POSITION_VOLUME);
   int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double closeVolume = MathMin(volume, posVol);

   int fillingFlags = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING fillingType = ORDER_FILLING_RETURN;
   if((fillingFlags & SYMBOL_FILLING_FOK) != 0)
      fillingType = ORDER_FILLING_FOK;
   else if((fillingFlags & SYMBOL_FILLING_IOC) != 0)
      fillingType = ORDER_FILLING_IOC;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.position      = ticket;
   request.symbol        = symbol;
   request.volume         = closeVolume;
   request.deviation      = InpDeviationPoints;
   request.type_filling   = fillingType;
   if(InpMagic != 0)
      request.magic = InpMagic;

   if(type == POSITION_TYPE_BUY)
     {
      request.type  = ORDER_TYPE_SELL;
      request.price  = NormalizeDouble(SymbolInfoDouble(symbol, SYMBOL_BID), digits);
     }
   else
     {
      request.type  = ORDER_TYPE_BUY;
      request.price  = NormalizeDouble(SymbolInfoDouble(symbol, SYMBOL_ASK), digits);
     }

   bool sent = OrderSend(request, result);
   lastErrorOut = GetLastError();
   retcodeOut   = (int)result.retcode;
   commentOut   = result.comment;

   bool success = sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
   return success;
  }

//+------------------------------------------------------------------+
//| Moves the SL of `ticket` to entry +/- bufferPoints (the PROFIT     |
//| side) via a raw TRADE_ACTION_SLTP request (TP is left untouched). |
//| Skips - without sending anything - if the resulting SL would      |
//| already be on the wrong side of the current market (broker would  |
//| reject it), i.e. price hasn't moved far enough past entry yet.    |
//+------------------------------------------------------------------+
bool SetBreakevenSL(const ulong ticket, const double bufferPoints, int &retcodeOut, string &commentOut, int &lastErrorOut)
  {
   retcodeOut = 0;
   commentOut = "";
   lastErrorOut = 0;

   if(!PositionSelectByTicket(ticket))
     {
      commentOut = "position not found";
      return false;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   double tp     = PositionGetDouble(POSITION_TP);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   double newSL;
   if(type == POSITION_TYPE_BUY)
     {
      newSL = NormalizeDouble(entry + bufferPoints * point, digits);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(newSL >= bid)
        {
         commentOut = "price not far enough past entry yet";
         return false;
        }
     }
   else
     {
      newSL = NormalizeDouble(entry - bufferPoints * point, digits);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(newSL <= ask)
        {
         commentOut = "price not far enough past entry yet";
         return false;
        }
     }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol    = symbol;
   request.sl         = newSL;
   request.tp         = tp;

   bool sent = OrderSend(request, result);
   lastErrorOut = GetLastError();
   retcodeOut   = (int)result.retcode;
   commentOut   = result.comment;

   return (sent && result.retcode == TRADE_RETCODE_DONE);
  }

//+------------------------------------------------------------------+
//| Sets a protective SL at entry -/+ points (the LOSING side, unlike |
//| SetBreakevenSL) via a raw TRADE_ACTION_SLTP request (TP is left   |
//| untouched). Skips - without sending anything - if that level is   |
//| already on the wrong side of the current market (broker would     |
//| reject it) - e.g. price has already moved past where the SL would |
//| land.                                                              |
//+------------------------------------------------------------------+
bool SetInitialSL(const ulong ticket, const double points, int &retcodeOut, string &commentOut, int &lastErrorOut)
  {
   retcodeOut = 0;
   commentOut = "";
   lastErrorOut = 0;

   if(!PositionSelectByTicket(ticket))
     {
      commentOut = "position not found";
      return false;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   double tp     = PositionGetDouble(POSITION_TP);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   double newSL;
   if(type == POSITION_TYPE_BUY)
     {
      newSL = NormalizeDouble(entry - points * point, digits);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(newSL >= bid)
        {
         commentOut = "computed SL is not below the current price";
         return false;
        }
     }
   else
     {
      newSL = NormalizeDouble(entry + points * point, digits);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(newSL <= ask)
        {
         commentOut = "computed SL is not above the current price";
         return false;
        }
     }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol    = symbol;
   request.sl         = newSL;
   request.tp         = tp;

   bool sent = OrderSend(request, result);
   lastErrorOut = GetLastError();
   retcodeOut   = (int)result.retcode;
   commentOut   = result.comment;

   return (sent && result.retcode == TRADE_RETCODE_DONE);
  }

//+------------------------------------------------------------------+
//| Sets a take-profit at entry +/- points (the PROFIT side) via a    |
//| raw TRADE_ACTION_SLTP request (SL is left untouched). Skips -     |
//| without sending anything - if that level is already on the wrong  |
//| side of the current market (broker would reject it).              |
//+------------------------------------------------------------------+
bool SetInitialTP(const ulong ticket, const double points, int &retcodeOut, string &commentOut, int &lastErrorOut)
  {
   retcodeOut = 0;
   commentOut = "";
   lastErrorOut = 0;

   if(!PositionSelectByTicket(ticket))
     {
      commentOut = "position not found";
      return false;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl     = PositionGetDouble(POSITION_SL);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   double newTP;
   if(type == POSITION_TYPE_BUY)
     {
      newTP = NormalizeDouble(entry + points * point, digits);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(newTP <= bid)
        {
         commentOut = "computed TP is not above the current price";
         return false;
        }
     }
   else
     {
      newTP = NormalizeDouble(entry - points * point, digits);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(newTP >= ask)
        {
         commentOut = "computed TP is not below the current price";
         return false;
        }
     }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol    = symbol;
   request.sl         = sl;
   request.tp         = newTP;

   bool sent = OrderSend(request, result);
   lastErrorOut = GetLastError();
   retcodeOut   = (int)result.retcode;
   commentOut   = result.comment;

   return (sent && result.retcode == TRADE_RETCODE_DONE);
  }

//+------------------------------------------------------------------+
double NormalizeVolume(const double vol, const double step)
  {
   if(step <= 0)
      return NormalizeDouble(vol, 2);
   return NormalizeDouble(MathRound(vol / step) * step, 8);
  }

//+------------------------------------------------------------------+
int FindOrAddState(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_states); i++)
      if(g_states[i].ticket == ticket)
         return i;

   int idx = ArraySize(g_states);
   ArrayResize(g_states, idx + 1);
   g_states[idx].ticket = ticket;
   g_states[idx].clicks = 0;
   return idx;
  }

//+------------------------------------------------------------------+
void RemoveState(const ulong ticket)
  {
   for(int i = ArraySize(g_states) - 1; i >= 0; i--)
     {
      if(g_states[i].ticket == ticket)
        {
         ArrayRemove(g_states, i, 1);
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| Drops click-counter entries whose position is no longer open, so |
//| the tracking array doesn't grow forever.                          |
//+------------------------------------------------------------------+
void PruneStates()
  {
   for(int i = ArraySize(g_states) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_states[i].ticket))
         ArrayRemove(g_states, i, 1);
     }
  }

//+------------------------------------------------------------------+
ulong TicketFromObjectName(const string name, const string prefix)
  {
   string ticketStr = StringSubstr(name, StringLen(prefix));
   return (ulong)StringToInteger(ticketStr);
  }

//+------------------------------------------------------------------+
string Now()
  {
   return TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
  }

//+------------------------------------------------------------------+
void LogEvent(const string event, const string details)
  {
   PrintFormat("[%s] %s %s", Now(), event, details);

   int fh = FileOpen("ScaleOutClose_EA_Log.csv", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
      return;
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, Now(), event, details);
   FileClose(fh);
  }
//+------------------------------------------------------------------+
