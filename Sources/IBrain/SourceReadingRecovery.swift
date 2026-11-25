import Foundation

public enum PrintedFactRequirement:String,Codable,Hashable,Sendable{case localDate,startClock,explicitTimeZone}
public enum SourceReadingRecoveryPolicy:Sendable{case legacy,nativeCompletionsV1,nativeCompletionsV2,nativeCompletionsV3,nativeCompletionsV4}
public struct SourceReadingRecoveryAssessment:Codable,Sendable{
 public let projection:MemoryProjection
 public let completedFromExistingEvidence:Set<PrintedFactRequirement>
 public let unresolved:Set<PrintedFactRequirement>
 /// False means the requested fields are already supported. True is a gap,
 /// not proof that the image contains the answer or permission to infer it.
 public var hasUnresolvedRequestedFields:Bool{!unresolved.isEmpty}
}
/// Run AFTER semantic field/role selection, BEFORE deciding to replace an OCR
/// source with another reader. Parser coverage is not image-reading coverage.
/// This opt-in never changes reference strings, originals or source authority.
public enum SourceReadingRecovery{
 public static let version="source-reading-native-completions-v1"
 public static let versionV2="source-reading-native-completions-v2"
 public static let versionV3="source-reading-native-completions-v3"
 public static let versionV4="source-reading-native-completions-v4"
 public static func assess(_ proposal:MemoryProjection,sources:[SourceSnapshot],required:Set<PrintedFactRequirement> = [.localDate,.startClock],policy:SourceReadingRecoveryPolicy = .legacy)throws->SourceReadingRecoveryAssessment{
  guard Set(sources.map{$0.reference.id}).count==sources.count,sources.allSatisfy({$0.scope==proposal.scope}),proposal.sources.isSubset(of:Set(sources.map(\.reference)))else{throw MemoryError.invalidSnapshot}
  if proposal.support.first(where:{$0.field == .date})?.anchors.contains(where:{a in sources.first(where:{$0.reference==a.source})?.printedStartReadConflict == true}) == true,proposal.appointment.date.certainty != .conflicting{throw MemoryError.invalidEvidence}
  for field in proposal.support{for anchor in field.anchors{
   guard let source=sources.first(where:{$0.reference==anchor.source}),let observation=source.observations.first(where:{$0.id==anchor.observationID}),!anchor.quote.isEmpty,observation.kind == .text ? observation.value.contains(anchor.quote):observation.value==anchor.quote else{throw MemoryError.invalidEvidence}
  }}
  func missing(_ p:MemoryProjection)->Set<PrintedFactRequirement>{
   let d=p.appointment.date;var unknown=Set<PrintedFactRequirement>()
   var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
   if let y=d.year,let m=d.month,let day=d.day,d.certainty == .explicit,let value=calendar.date(from:DateComponents(year:y,month:m,day:day)),calendar.dateComponents([.year,.month,.day],from:value)==DateComponents(year:y,month:m,day:day){}else{unknown.insert(.localDate)}
   if let h=d.hour,let m=d.minute,(0...23).contains(h),(0...59).contains(m),d.certainty == .explicit{}else{unknown.insert(.startClock)}
   if d.timeZoneID==nil && d.utcOffsetSeconds==nil{unknown.insert(.explicitTimeZone)}
   return unknown.intersection(required)
  }
  let before=missing(proposal),completed:MemoryProjection
  if policy == .nativeCompletionsV4,let raw=proposal.appointment.date.printedDateText,SelectedSeparatedDateRecovery.applies(to:raw) {
   // Do not let older parsers salvage another date prefix when the separated
   // field is malformed or contains competing dates. Clock repair remains a
   // separately proven stage; existing supported clock/zone values survive.
   completed=try SelectedSeparatedDateRecovery.project(ZonedPrintedClockValues.project(proposal,sources:sources),sources:sources)
  }else if policy != .legacy{
   let existing=try SelectedPrintedStartValues.project(ZonedPrintedClockValues.project(proposal,sources:sources),sources:sources,policy:policy == .nativeCompletionsV2 || policy == .nativeCompletionsV3 || policy == .nativeCompletionsV4 ? .selectedCivilDateV2:.ticketAbbreviationsV1)
   let civil = policy == .nativeCompletionsV3 || policy == .nativeCompletionsV4 ? try SelectedCivilDateRecovery.project(existing,sources:sources):existing
   completed = civil
  }else{completed=proposal}
  let after=missing(completed)
  return SourceReadingRecoveryAssessment(projection:completed,completedFromExistingEvidence:before.subtracting(after),unresolved:after)
 }
}
