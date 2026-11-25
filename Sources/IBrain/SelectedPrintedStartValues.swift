import Foundation

public enum SelectedPrintedStartPolicy:Sendable {case legacy,ticketAbbreviationsV1,selectedCivilDateV2}
/// Opt-in parsing of exact semantically selected raw ticket fields. No glyph
/// substitution, year expansion, timezone inference or identifier normalization.
public enum SelectedPrintedStartValues {
 public static let version="selected-printed-ticket-start-v1"
 public static let versionV2="selected-printed-civil-date-v2"
 public static func project(_ p:MemoryProjection,sources:[SourceSnapshot],policy:SelectedPrintedStartPolicy = .legacy)throws->MemoryProjection{
  guard policy != .legacy,policy == .selectedCivilDateV2 || p.appointment.kind == .eventTicket else{return p}
  let a=p.appointment,d=a.date
  guard d.certainty == .explicit,d.captureYearDerivation==nil,let proof=p.support.first(where:{$0.field == .date}),proof.origin == .observed else{return p}
  guard Set(sources.map{$0.reference.id}).count==sources.count,sources.allSatisfy({$0.scope==p.scope})else{throw MemoryError.invalidSnapshot}
  func proven(_ raw:String)->Bool{proof.anchors.contains{anchor in anchor.quote==raw && sources.contains{s in s.reference==anchor.source && s.observations.contains{$0.id==anchor.observationID && $0.kind == .text && $0.value==raw}}}}
  var year=d.year,month=d.month,day=d.day,hour=d.hour,minute=d.minute
  if policy == .selectedCivilDateV2,year==nil,let raw=d.printedDateText,proven(raw),
     let parsed=SelectedPrintedCivilDate.parse(raw),month==nil || month==parsed.month,day==nil || day==parsed.day {
   year=parsed.year;month=parsed.month;day=parsed.day
  }
  if year==nil,let raw=d.printedDateText,proven(raw){
   let months=["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
   let pattern=#"^(?:(SUN(?:DAY)?|MON(?:DAY)?|TUE(?:SDAY)?|WED(?:NESDAY)?|THU(?:RSDAY)?|FRI(?:DAY)?|SAT(?:URDAY)?)[ ,]+)?(JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?)\s+([0-9]{1,2})[.,]\s*([0-9]{4})$"#
   let regex=try NSRegularExpression(pattern:pattern,options:.caseInsensitive)
   if let match=regex.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)){
    func v(_ i:Int)->String{Range(match.range(at:i),in:raw).map{String(raw[$0])} ?? ""}
    if let y=Int(v(4)),(1...9999).contains(y),let m=months.firstIndex(of:String(v(2).lowercased().prefix(3))).map({$0+1}),let n=Int(v(3)),month==nil || month==m,day==nil || day==n {
     var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
     let parts=DateComponents(year:y,month:m,day:n)
     if let date=c.date(from:parts),c.dateComponents([.year,.month,.day],from:date)==parts {
      let weekdays=["sun","mon","tue","wed","thu","fri","sat"]
      if v(1).isEmpty || weekdays[c.component(.weekday,from:date)-1]==String(v(1).lowercased().prefix(3)){year=y;month=m;day=n}
     }
    }
   }
  }
  if hour==nil,minute==nil,let raw=d.printedTimeText,proven(raw){
   let re=try NSRegularExpression(pattern:#"^([0-9]{1,2}):([0-9]{2})\s+([AP])$"#,options:.caseInsensitive)
   if let match=re.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)),let hr=Range(match.range(at:1),in:raw),let mr=Range(match.range(at:2),in:raw),let ar=Range(match.range(at:3),in:raw),let h=Int(raw[hr]),let m=Int(raw[mr]),(1...12).contains(h),(0...59).contains(m){hour=h%12+(raw[ar].uppercased()=="P" ? 12:0);minute=m}
  }
  guard year != d.year || month != d.month || day != d.day || hour != d.hour || minute != d.minute else{return p}
  let date=EventDate(year:year,month:month,day:day,hour:hour,minute:minute,timeZoneID:d.timeZoneID,utcOffsetSeconds:d.utcOffsetSeconds,certainty:d.certainty,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText)
  let appointment=AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:date,kind:a.kind,status:a.status,performer:a.performer,venueAddress:a.venueAddress)
  let support=p.support.map{$0.field == .date ? FieldSupport(field:.date,origin:$0.origin,anchors:$0.anchors,confidence:$0.confidence,extractorVersion:$0.extractorVersion+"/"+(policy == .selectedCivilDateV2 ? versionV2:version)):$0}
  return MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,appointment:appointment,support:support,documentOnlyWithoutDate:p.documentOnlyWithoutDate ?? false)
 }
}

/// Complete selected-field grammar: punctuation and spacing are separators,
/// never a reason to erase an explicit year. Exact source proof is checked by
/// the caller. This does not scan arbitrary source text or interpret its role.
private enum SelectedPrintedCivilDate {
 struct Parts {let year:Int;let month:Int;let day:Int}
 static func parse(_ raw:String)->Parts? {
  let names=["january","february","march","april","may","june","july","august","september","october","november","december"]
  let months=names.flatMap{[$0,String($0.prefix(3))]}+["sept"]
  let month=Array(Set(months)).sorted{$0.count>$1.count}.joined(separator:"|")
  let weekdays="Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sun|Mon|Tue|Wed|Thu|Fri|Sat"
  let prefix="^\\s*(?:("+weekdays+")\\.?[ ,]+)?"
  let clock="(?:\\s*[,;]?\\s*([0-9]{1,2}):([0-9]{2})(?:\\s*([AP])\\.?M\\.?)?)?\\s*$"
  // Each pattern has the same capture order after the optional weekday:
  // month/day/year or day/month/year, then optional clock fields.
  let patterns=[("("+month+")\\.?\\s*([0-9]{1,2})(?:\\s*[, .]\\s*|\\s+)([0-9]{4})",true),
                ("([0-9]{1,2})(?:\\s*[,.]\\s*|\\s+)("+month+")\\.?(?:\\s*[, .]\\s*|\\s+)([0-9]{4})",false)]
  for (body,monthFirst) in patterns {
   guard let re=try?NSRegularExpression(pattern:prefix+body+clock,options:.caseInsensitive),let match=re.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw))else{continue}
   func value(_ i:Int)->String{Range(match.range(at:i),in:raw).map{String(raw[$0])} ?? ""}
   let word=value(monthFirst ? 2:3).lowercased()
   guard let m=names.firstIndex(where:{$0==word || $0.prefix(3)==word || word=="sept" && $0=="september"}).map({$0+1}),let d=Int(value(monthFirst ? 3:2)),let y=Int(value(4)),(1...9999).contains(y)else{return nil}
   var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
   let parts=DateComponents(year:y,month:m,day:d)
   guard let date=cal.date(from:parts),cal.dateComponents([.year,.month,.day],from:date)==parts else{return nil}
   let days=["sun","mon","tue","wed","thu","fri","sat"]
   guard value(1).isEmpty || days[cal.component(.weekday,from:date)-1]==String(value(1).lowercased().prefix(3))else{return nil}
   if !value(5).isEmpty {
    guard let h=Int(value(5)),let minute=Int(value(6)),(0...59).contains(minute),value(7).isEmpty ? (0...23).contains(h):(1...12).contains(h)else{return nil}
   }
   return Parts(year:y,month:m,day:d)
  }
  return nil
 }
}
