import Foundation

public enum CaptureTimestampOrigin:String,Codable,Sendable{case originalPhoto,originalScreenshot,importOrEdit}
public enum TemporalInferenceStrength:String,Codable,Sendable{case supportedContext,assumedContext}
public enum DerivedDateComponent:String,Codable,Hashable,Sendable{case year,month,day}
public enum TemporalInferenceRule:String,Codable,Sendable{case nearestPrintedMonthDayToOriginalCapture,explicitRelativeDayFromOriginalCapture}
public struct OriginalCaptureContext:Sendable{
 public let source:SourceReference
 public let capturedAt:Date
 public let origin:CaptureTimestampOrigin
 public let timeZoneID:String
 public let localeIdentifier:String
 public let relativeDayContemporaneous:Bool
 public let importedAt:Date?
 public init(source:SourceReference,capturedAt:Date,origin:CaptureTimestampOrigin,timeZoneID:String,localeIdentifier:String="en_US_POSIX",relativeDayContemporaneous:Bool=false,importedAt:Date?=nil){self.source=source;self.capturedAt=capturedAt;self.origin=origin;self.timeZoneID=timeZoneID;self.localeIdentifier=localeIdentifier;self.relativeDayContemporaneous=relativeDayContemporaneous;self.importedAt=importedAt}
}
public struct TemporalDerivation:Codable,Equatable,Sendable{
 public let policyVersion:String
 public let rule:TemporalInferenceRule
 public let source:SourceReference
 public let originalCapturedAt:Date
 public let captureOrigin:CaptureTimestampOrigin
 public let contextTimeZoneID:String
 public let localeIdentifier:String
 public let dateAnchor:EvidenceAnchor
 public let printedWeekday:Int?
 public let relativeDayOffset:Int?
 public let components:Set<DerivedDateComponent>
 public let strength:TemporalInferenceStrength
 private enum CodingKeys:String,CodingKey{case policyVersion,rule,source,originalCapturedAt,captureOrigin,contextTimeZoneID,localeIdentifier,dateAnchor,printedWeekday,relativeDayOffset,components,strength}
 public func encode(to encoder:Encoder)throws{
  var c=encoder.container(keyedBy:CodingKeys.self)
  try c.encode(policyVersion,forKey:.policyVersion);try c.encode(rule,forKey:.rule);try c.encode(source,forKey:.source);try c.encode(originalCapturedAt,forKey:.originalCapturedAt);try c.encode(captureOrigin,forKey:.captureOrigin);try c.encode(contextTimeZoneID,forKey:.contextTimeZoneID);try c.encode(localeIdentifier,forKey:.localeIdentifier);try c.encode(dateAnchor,forKey:.dateAnchor);try c.encodeIfPresent(printedWeekday,forKey:.printedWeekday);try c.encodeIfPresent(relativeDayOffset,forKey:.relativeDayOffset)
  // A proof's set is semantically unordered. Its canonical wire order must be
  // stable across independent processes and cold decoding for receipt hashes.
  try c.encode(components.sorted{$0.rawValue<$1.rawValue},forKey:.components);try c.encode(strength,forKey:.strength)
 }
}
public enum TemporalDateMeaning:Sendable{case printed,relativeDay(offset:Int,anchor:EvidenceAnchor),absent,unclear}
public enum PrintedYearEvidence:String,Sendable{case notPrinted,presentOrUnreadable,unclear}
public enum TemporalResolutionPolicy:Sendable{case explicitOnly,captureContextV1}
public struct ResolvedTemporalEvidence:Sendable{
 public let projection:MemoryProjection
 public let originalCaptureAt:Date?
 public let importedAt:Date?
 public let explanation:String
 public let eligibleForLabelledDateFiltering:Bool
 /// Interpretation never grants notifications, bookings or other effects.
 public let authorizesExternalAction:Bool=false
}
/// One boundary for useful partial facts, source-backed literal completion and
/// opt-in capture-context estimates. Import/current time is never an eventdate.
public enum TemporalResolution{
 public static let version="source-temporal-context-v1"
 public static func resolve(_ input:MemoryProjection,sources:[SourceSnapshot],meaning:TemporalDateMeaning = .printed,context:OriginalCaptureContext?=nil,printedWeekday:Int?=nil,printedYearEvidence:PrintedYearEvidence = .notPrinted,policy:TemporalResolutionPolicy = .explicitOnly)throws->ResolvedTemporalEvidence{
  var raw=input
  // Recompute a previous estimate from its original printed components when
  // the caller supplies current original-capture context. Never rebind anchors.
  if policy == .captureContextV1,context != nil,input.appointment.date.certainty == .inferred{
   let a=input.appointment,d=a.date
   let parts=d.temporalDerivation?.components ?? (d.captureYearDerivation == nil ? []:[.year])
   if !parts.isEmpty{
    let date=EventDate(year:parts.contains(.year) ? nil:d.year,month:parts.contains(.month) ? nil:d.month,day:parts.contains(.day) ? nil:d.day,hour:d.hour,minute:d.minute,timeZoneID:d.timeZoneID,utcOffsetSeconds:d.utcOffsetSeconds,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText)
    raw=MemoryProjection(recordID:input.recordID,recordRevision:input.recordRevision,scope:input.scope,appointment:AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:date,kind:a.kind,status:a.status,performer:a.performer,venueAddress:a.venueAddress),support:input.support.map{$0.field == .date ? FieldSupport(field:.date,origin:.observed,anchors:$0.anchors,confidence:$0.confidence,extractorVersion:$0.extractorVersion):$0},documentOnlyWithoutDate:input.documentOnlyWithoutDate ?? false)
   }
  }
  let assessed=try SourceReadingRecovery.assess(raw,sources:sources,policy:.nativeCompletionsV1),p=assessed.projection,d=p.appointment.date
  let source=context.flatMap{c in sources.first{$0.reference==c.source && $0.capturedAt==c.capturedAt && c.origin != .importOrEdit && ($0.captureTimestampOrigin==nil || $0.captureTimestampOrigin==c.origin)}}
  let capture=source?.capturedAt
  func result(_ projection:MemoryProjection,_ explanation:String,_ eligible:Bool)->ResolvedTemporalEvidence{ResolvedTemporalEvidence(projection:projection,originalCaptureAt:capture,importedAt:context?.importedAt,explanation:explanation,eligibleForLabelledDateFiltering:eligible)}
  if d.year != nil && d.month != nil && d.day != nil{return result(p,d.certainty == .explicit ? "Printed date retained.":"Derived or conflicting date retained with its certainty.",d.certainty == .explicit && !assessed.unresolved.contains(.localDate) || validates(d) && d.temporalDerivation?.strength == .supportedContext)}
  guard d.certainty == .explicit,policy == .captureContextV1,let context,let source,let zone=TimeZone(identifier:context.timeZoneID)else{return result(p,"Appointment date is not fully shown; available provider, location and time remain useful.",false)}
  let proof=p.support.first{$0.field == .date}
  let rule:TemporalInferenceRule,anchor:EvidenceAnchor,offset:Int?,strength:TemporalInferenceStrength
  var y=d.year,m=d.month,day=d.day,components=Set<DerivedDateComponent>()
  switch meaning{
  case .printed:
   guard printedYearEvidence == .notPrinted else{return result(p,"A printed or uncertain year needs field-scoped source recovery; capture context is not a replacement for it.",false)}
   guard d.year==nil,let raw=d.printedDateText,let a=proof?.anchors.first(where:{$0.source==source.reference && $0.quote==raw})else{return result(p,"Appointment date not shown; original capture is available as saved-on context only.",false)}
   let temporary=EventDate(year:nil,month:d.month,day:d.day,hour:d.hour,minute:d.minute,timeZoneID:context.timeZoneID,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText)
   guard let proposed=CaptureYearPolicy.propose(printed:temporary,originalCaptureSource:source,printedWeekday:printedWeekday)else{return result(p,"Missing year remains unresolved; capture context does not select one safely.",false)}
   y=proposed.year;components=[.year];rule = .nearestPrintedMonthDayToOriginalCapture;anchor=a;offset=nil;strength = .supportedContext
  case .relativeDay(let n,let a):
   guard (-31...31).contains(n),d.year==nil,a.source==source.reference,source.observations.contains(where:{$0.id==a.observationID && $0.kind == .text && $0.value.contains(a.quote)}),proof?.anchors.contains(a)==true else{return result(p,"Relative date meaning lacks current source support.",false)}
   var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone;calendar.locale=Locale(identifier:context.localeIdentifier)
   guard let value=calendar.date(byAdding:.day,value:n,to:calendar.startOfDay(for:context.capturedAt))else{return result(p,"Relative day cannot be resolved.",false)}
   let yy=calendar.component(.year,from:value),mm=calendar.component(.month,from:value),dd=calendar.component(.day,from:value)
   guard d.month.map({$0==mm}) ?? true,d.day.map({$0==dd}) ?? true else{return result(p,"Relative date conflicts with related printed components.",false)}
   components=[.year];if d.month==nil{components.insert(.month)};if d.day==nil{components.insert(.day)}
   y=yy;m=mm;day=dd
   if let printedWeekday,calendar.component(.weekday,from:value) != printedWeekday{return result(p,"Relative day conflicts with the printed weekday.",false)}
   rule = .explicitRelativeDayFromOriginalCapture;anchor=a;offset=n;strength=context.relativeDayContemporaneous && source.relativeDayAnchorContemporaneous == true ? .supportedContext:.assumedContext
  case .absent,.unclear:return result(p,"Appointment date not shown; saved-on context does not establish an event date.",false)
  }
  let derivation=TemporalDerivation(policyVersion:version,rule:rule,source:source.reference,originalCapturedAt:context.capturedAt,captureOrigin:context.origin,contextTimeZoneID:context.timeZoneID,localeIdentifier:context.localeIdentifier,dateAnchor:anchor,printedWeekday:printedWeekday,relativeDayOffset:offset,components:components,strength:strength)
  let inferred=EventDate(year:y,month:m,day:day,hour:d.hour,minute:d.minute,timeZoneID:d.timeZoneID,utcOffsetSeconds:d.utcOffsetSeconds,certainty:.inferred,printedDateText:d.printedDateText,printedTimeText:d.printedTimeText,temporalDerivation:derivation)
  guard validates(inferred)else{throw MemoryError.invalidEvidence}
  let a=p.appointment,appointment=AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:inferred,kind:a.kind,status:a.status,performer:a.performer,venueAddress:a.venueAddress)
  let support=p.support.map{$0.field == .date ? FieldSupport(field:.date,origin:.inferred,anchors:$0.anchors,confidence:$0.confidence,extractorVersion:$0.extractorVersion+"/"+version):$0}
  return result(MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,appointment:appointment,support:support),strength == .supportedContext ? "Date estimated from original capture context; printed components and missing timezone retained.":"Date estimate assumes the relative wording was current when captured; calendar membership remains unresolved.",strength == .supportedContext)
 }
 public static func validates(_ d:EventDate)->Bool{
  guard d.certainty == .inferred,d.captureYearDerivation==nil,let v=d.temporalDerivation,v.policyVersion==version,v.captureOrigin != .importOrEdit,v.source==v.dateAnchor.source,!v.dateAnchor.quote.isEmpty,let zone=TimeZone(identifier:v.contextTimeZoneID),let y=d.year,let m=d.month,let day=d.day else{return false}
  var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone;calendar.locale=Locale(identifier:v.localeIdentifier)
  guard let value=calendar.date(from:DateComponents(year:y,month:m,day:day)),calendar.dateComponents([.year,.month,.day],from:value)==DateComponents(year:y,month:m,day:day),v.printedWeekday.map({calendar.component(.weekday,from:value)==$0}) ?? true else{return false}
  switch v.rule{
  case .nearestPrintedMonthDayToOriginalCapture:
   guard v.components==[.year],v.relativeDayOffset==nil,v.strength == .supportedContext else{return false}
   let source=SourceSnapshot(reference:v.source,scope:MemoryScope(ownerID:"mechanical-validation",namespace:"not-authority"),observations:[],capturedAt:v.originalCapturedAt)
   return CaptureYearPolicy.propose(printed:EventDate(year:nil,month:m,day:day,hour:d.hour,minute:d.minute,timeZoneID:v.contextTimeZoneID),originalCaptureSource:source,printedWeekday:v.printedWeekday)?.year==y
  case .explicitRelativeDayFromOriginalCapture:
   guard !v.components.isEmpty,v.components.isSubset(of:[.year,.month,.day]),v.components.contains(.year),let n=v.relativeDayOffset,(-31...31).contains(n),let target=calendar.date(byAdding:.day,value:n,to:calendar.startOfDay(for:v.originalCapturedAt))else{return false}
   return calendar.isDate(value,inSameDayAs:target)
  }
 }
 public static func allowsFiltering(_ d:EventDate,policy:InferredDatePolicy)->Bool{
  policy == .labelledCaptureYear && CaptureYearPolicy.validates(d) || policy == .labelledTemporalContext && (CaptureYearPolicy.validates(d) || validates(d) && d.temporalDerivation?.strength == .supportedContext)
 }
}
