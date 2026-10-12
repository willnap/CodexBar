import Foundation

/// Provider adapters supply amounts and deadlines; these examples do not fetch account limits.
public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
 public enum Recovery: String, Codable, Sendable { case reset, nextRecovery, none }
 public var id: String
 public var label: String
 public var period: TimeInterval
 public var used: Double?
 public var limit: Double?
 public var unit: String
 public var countdown: ResetCountdown?
 public var recovery: Recovery
 public init(id:String,label:String,period:TimeInterval,used:Double?,limit:Double?=1,unit:String="fraction",countdown:ResetCountdown?=nil,recovery:Recovery = .reset) {
  self.id=id;self.label=label;self.period=period;self.used=used;self.limit=limit;self.unit=unit;self.countdown=countdown;self.recovery=recovery
 }
 public var usedFraction:Double? {
  guard let used,used.isFinite,used>=0,let limit,limit.isFinite,limit>0 else{return nil}
  return min(1,used/limit)
 }
 public var amountDescription:String {
  guard let usedFraction else{return "Usage unknown"}
  if unit == "fraction" {return "\(Int((usedFraction*100).rounded()))% used"}
  return "\(used!.formatted(.number.precision(.fractionLength(0...1)))) / \(limit!.formatted(.number.precision(.fractionLength(0...1)))) \(unit) used"
 }
 public func recoveryDescription(at now:Date)->String {
  guard recovery != .none else{return "No scheduled reset"}
  let action=recovery == .nextRecovery ? "Next recovery":"Reset"
  guard let countdown,countdown.isReliable,let date=countdown.nextReset else{return "\(action) time unknown"}
  let seconds=date.timeIntervalSince(now)
  guard seconds>0 else{return "\(action) due · awaiting provider update"}
  let minutes=Int(ceil(seconds/60)),days=minutes/1440,hours=(minutes%1440)/60,mins=minutes%60
  let time=days>0 ? "\(days)d \(hours)h":hours>0 ? "\(hours)h \(mins)m":"\(mins)m"
  return "\(action) in \(time)"
 }
 public var segmentDescription:String {
  guard recovery != .none,let countdown else{return "No countdown"}
  let seconds=countdown.secondsPerUnit
  let unit=seconds>=86400 ? "\((seconds/86400).formatted())d":"\((seconds/3600).formatted())h"
  return "\(countdown.units) × \(unit)"
 }
}

public extension ComputeGauge.State {
 /// Longest window is outermost. Invalid configurations are visibly unknown;
 /// they never silently hide an additional limit or manufacture a reset.
 var resolvedWindows:[UsageWindow] {
  guard let windows else {
   return [UsageWindow(id:"weekly",label:"Weekly",period:Double(weeklyReset.units)*weeklyReset.secondsPerUnit,used:weeklyUsed,countdown:weeklyReset),
           UsageWindow(id:"session",label:"Session",period:Double(fiveHourReset.units)*fiveHourReset.secondsPerUnit,used:fiveHourUsed,countdown:fiveHourReset)]
  }
  guard (1...3).contains(windows.count),Set(windows.map(\.id)).count == windows.count,
        windows.allSatisfy({$0.period.isFinite && $0.period>0 && ($0.countdown == nil || ((1...24).contains($0.countdown!.units) && $0.countdown!.secondsPerUnit.isFinite && $0.countdown!.secondsPerUnit>0))}) else {
   return [UsageWindow(id:"invalid",label:"Unsupported usage configuration",period:1,used:nil,recovery:.none)]
  }
  return windows.sorted {
   if $0.period != $1.period { return $0.period > $1.period }
   // Model-specific weekly quotas sit inside the all-model weekly quota.
   let leftScoped = $0.id == "tertiary" || $0.id.hasPrefix("claude-weekly-scoped-")
   let rightScoped = $1.id == "tertiary" || $1.id.hasPrefix("claude-weekly-scoped-")
   if leftScoped != rightScoped { return !leftScoped }
   return $0.id < $1.id
  }
 }
 func usageSummary(at now:Date)->String {
  resolvedWindows.map { "\($0.label): \($0.amountDescription), \($0.recoveryDescription(at:now))" }.joined(separator:". ")
 }
}

/// Illustrative configurations, not authoritative descriptions of provider plans.
public enum UsagePreset:String,CaseIterable,Identifiable {
 case legacy,weekly,dual,triple,credits,rolling
 public var id:String{rawValue}
 public var title:String {
  switch self {
  case .legacy:return "Existing two-window settings"
  case .weekly:return "Codex · 7d only"
  case .dual:return "Claude Code · 5h + 7d"
  case .triple:return "Kimi Code · 5h + 7d + 30d"
  case .credits:return "Monthly credit allowance"
  case .rolling:return "Rolling 24h quota"
  }
 }
 public func apply(to state:inout ComputeGauge.State,at now:Date) {
  func window(_ id:String,_ label:String,_ period:Double,_ units:Int,_ used:Double,_ remaining:Double)->UsageWindow {
   UsageWindow(id:id,label:label,period:period,used:used,countdown:ResetCountdown(units:units,secondsPerUnit:period/Double(units),nextReset:now.addingTimeInterval(remaining)))
  }
  let week=window("weekly","7-day",7*86400,7,0.65,5*86400)
  let session=window("session","5-hour",5*3600,5,0.35,3*3600)
  let month=window("monthly","30-day",30*86400,6,0.42,18*86400)
  switch self {
   case .legacy:state.windows=nil
   case .weekly:state.provider="codex";state.windows=[week]
   case .dual:state.provider="claudecode";state.windows=[week,session]
   case .triple:state.provider="kimi";state.windows=[month,week,session]
   case .credits:
    var credit=month;credit.label="30-day credits";credit.used=4200;credit.limit=10000;credit.unit="credits"
    state.windows=[credit]
   case .rolling:
    var quota=window("rolling","Rolling 24h",86400,6,0.55,10*3600)
    quota.used=550;quota.limit=1000;quota.unit="requests";quota.recovery = .nextRecovery
    state.windows=[quota]
  }
 }
}

/// Product identity is distinct from the company that operates its quota backend.
public enum UsageProduct {
 public static func canonicalID(_ id:String)->String {
  switch id {
   case "chatgpt":return "openai"
   case "claude","anthropic":return "claudecode"
   case "geminicli":return "gemini"
   default:return id
  }
 }
 public static func name(_ id:String)->String {
  ServiceIdentity.find(canonicalID(id))?.name ?? id
 }

}
public extension ComputeGauge.State {
 var productID:String{UsageProduct.canonicalID(provider)}
 var productName:String{UsageProduct.name(provider)}
}
