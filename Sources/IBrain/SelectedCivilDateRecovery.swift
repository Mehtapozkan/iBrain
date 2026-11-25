import Foundation

/// A separately interpreted year must describe the selected event date. Mere
/// proximity to a printed year is insufficient. This is not capture inference.
public struct PrintedDateFieldSelection:Sendable {
 public let dateAnchor:EvidenceAnchor
 public let yearAnchor:EvidenceAnchor?
 public init(dateAnchor:EvidenceAnchor,yearAnchor:EvidenceAnchor?=nil){self.dateAnchor=dateAnchor;self.yearAnchor=yearAnchor}
}
/// Parses only a semantically selected date field. Source observations and raw
/// wording stay unchanged; native calendar values carry exact source anchors.
public enum SelectedCivilDateRecovery {
 public static let version="selected-source-civil-date-v3"
 private struct Parts {let year:Int?;let month:Int;let day:Int;let weekday:Int?;let quote:String}
 private static let months=["january","february","march","april","may","june","july","august","september","october","november","december"]
 public static func standaloneYear(_ text:String)->Int? {
  let p=#"^\s*(?:[^\p{N}:\n]{1,48}:\s*)?([0-9]{4})\s*$"#
  guard let r=try? NSRegularExpression(pattern:p),let m=r.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(m.range(at:1),in:text),let y=Int(text[range]),(1...9999).contains(y)else{return nil};return y
 }
 private static func valid(_ y:Int?,_ m:Int,_ d:Int,_ weekday:Int?)->Bool {
  var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
  let parts=DateComponents(year:y ?? 2000,month:m,day:d)
  guard let v=c.date(from:parts),c.dateComponents([.year,.month,.day],from:v)==parts else{return false}
  return y==nil || weekday.map{c.component(.weekday,from:v)==$0} ?? true
 }
 private static func parse(_ text:String)->Parts? {
  let names=Array(Set(months.flatMap{[$0,String($0.prefix(3))]}+["sept"])).sorted{$0.count>$1.count}.joined(separator:"|")
  let weekdays="Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sun|Mon|Tue|Wed|Thu|Fri|Sat"
  let prefix="(?<![\\p{L}\\p{N}/.\\-])(?:("+weekdays+")\\.?[ ,]+)?"
  let year="(?:(?:\\s*[, .]\\s*|\\s+)([0-9]{4}))?(?![\\p{L}\\p{N}/.\\-])"
  let patterns=[(prefix+"("+names+")\\.?\\s*([0-9]{1,2})(?:st|nd|rd|th)?"+year,true),
                (prefix+"([0-9]{1,2})(?:st|nd|rd|th)?(?:\\s*[,.]\\s*|\\s+)("+names+")\\.?"+year,false)]
  var found:[Parts]=[]
  for (pattern,monthFirst) in patterns {
   guard let re=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive)else{return nil}
   for match in re.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
    func word(_ i:Int)->String {Range(match.range(at:i),in:text).map{String(text[$0])} ?? ""}
    guard let range=Range(match.range,in:text)else{return nil}
    let name=word(monthFirst ? 2:3).lowercased(),day=Int(word(monthFirst ? 3:2)),y=Int(word(4))
    guard let month=months.firstIndex(where:{$0==name || $0.prefix(3)==name || $0=="september" && name=="sept"}).map({$0+1}),let day else{return nil}
    let w=word(1).isEmpty ? nil:["sun","mon","tue","wed","thu","fri","sat"].firstIndex(of:String(word(1).lowercased().prefix(3))).map{$0+1}
    // Never erase a printed unsupported/misread/two-digit year by accepting
    // only its month/day prefix. Conservative holds are deliberate.
    let tail=String(text[range.upperBound...])
    if tail.range(of:y==nil ? #"^[\s,.;]*(?:[\p{L}\p{N}]{4}|[0-9]{2})(?![\p{L}\p{N}:])"# : #"^[\s,.;]*[\p{L}\p{N}]{4}(?![\p{L}\p{N}:])"#,options:.regularExpression) != nil{return nil}
    guard y.map({(1...9999).contains($0)}) ?? true,valid(y,month,day,w)else{return nil}
    found.append(Parts(year:y,month:month,day:day,weekday:w,quote:String(text[range])))
   }
  }
  // A source field containing two dates/roles requires semantic disambiguation,
  // never a convenient first date. Numeric locale ambiguity is not guessed.
  guard found.count==1 else{return nil};return found[0]
 }
 public static func project(_ p:MemoryProjection,sources:[SourceSnapshot],selection:PrintedDateFieldSelection?=nil)throws->MemoryProjection {
  guard Set(sources.map{$0.reference.id}).count==sources.count,sources.allSatisfy({$0.scope==p.scope}),p.sources.isSubset(of:Set(sources.map(\.reference)))else{throw MemoryError.invalidSnapshot}
  let a=p.appointment,d=a.date
  guard d.certainty == .explicit,d.captureYearDerivation==nil,d.temporalDerivation==nil,let proof=p.support.first(where:{$0.field == .date}),proof.origin == .observed,let raw=d.printedDateText else{return p}
  func proven(_ anchor:EvidenceAnchor)->Bool {sources.contains{s in s.reference==anchor.source && s.observations.contains{$0.id==anchor.observationID && $0.kind == .text && !$0.value.isEmpty && !anchor.quote.isEmpty && $0.value.contains(anchor.quote)}}}
  guard proof.anchors.allSatisfy(proven)else{throw MemoryError.invalidEvidence}
  guard let original=proof.anchors.first(where:{$0.quote==raw && proven($0)})else{return p}
  let focus=selection?.dateAnchor ?? original
  guard focus.source==original.source,focus.observationID==original.observationID,raw.contains(focus.quote),proven(focus)else{throw MemoryError.invalidEvidence}
  guard let parsed=parse(focus.quote)else{return p}
  var year=parsed.year ?? d.year
  var added:[EvidenceAnchor]=[]
  if let supplement=selection?.yearAnchor {
   guard supplement.source==focus.source,supplement.observationID != focus.observationID,proven(supplement),let y=standaloneYear(supplement.quote),year==nil || year==y else{throw MemoryError.invalidEvidence}
   year=y;added.append(supplement)
  }
  guard valid(year,parsed.month,parsed.day,parsed.weekday),d.year.map({$0==year}) ?? true,d.month.map({$0==parsed.month}) ?? true,d.day.map({$0==parsed.day}) ?? true else{return p}
  guard year != d.year || parsed.month != d.month || parsed.day != d.day else{return p}
  let selected=EvidenceAnchor(source:focus.source,observationID:focus.observationID,quote:parsed.quote)
  var anchors=proof.anchors
  for v in [selected]+added where !anchors.contains(v){anchors.append(v)}
  let date=EventDate(year:year,month:parsed.month,day:parsed.day,hour:d.hour,minute:d.minute,timeZoneID:d.timeZoneID,utcOffsetSeconds:d.utcOffsetSeconds,certainty:d.certainty,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText)
  return MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,appointment:AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:date,kind:a.kind,status:a.status,performer:a.performer,venueAddress:a.venueAddress),support:p.support.map{$0.field == .date ? FieldSupport(field:.date,origin:proof.origin,anchors:anchors,confidence:proof.confidence,extractorVersion:proof.extractorVersion+"/"+version):$0},documentOnlyWithoutDate:p.documentOnlyWithoutDate ?? false)
 }
}
