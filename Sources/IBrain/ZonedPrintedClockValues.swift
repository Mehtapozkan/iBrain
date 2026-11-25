import Foundation

/// Opt-in literal completion after semantic selection of the current raw start
/// line and its explicitly printed IANA zone. This accepts the exact HH:mm Zone
/// notation only. Unzoned 10:25, AM/PM, ranges, prices and conflicting values keep
/// their existing interpretation. Source/domain admission remains the host's.
public enum ZonedPrintedClockValues {
 public static let version="zoned-printed-clock-values-v1"
 public static func project(_ p:MemoryProjection,sources:[SourceSnapshot])throws->MemoryProjection{
  let a=p.appointment,d=a.date
  guard d.hour==nil,d.minute==nil,d.certainty == .explicit,d.captureYearDerivation==nil,let zone=d.timeZoneID,TimeZone(identifier:zone) != nil,let raw=d.printedTimeText,let proof=p.support.first(where:{$0.field == .date}),proof.origin == .observed else{return p}
  let pattern="^([0-9]{2}):([0-9]{2})[ \\t]+"+NSRegularExpression.escapedPattern(for:zone)+"$"
  let re=try NSRegularExpression(pattern:pattern);guard let match=re.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)),let hRange=Range(match.range(at:1),in:raw),let mRange=Range(match.range(at:2),in:raw),let h=Int(raw[hRange]),let m=Int(raw[mRange]),(0...23).contains(h),(0...59).contains(m)else{return p}
  guard Set(sources.map{$0.reference.id}).count==sources.count,sources.allSatisfy({$0.scope==p.scope})else{throw MemoryError.invalidSnapshot}
  guard proof.anchors.contains(where:{anchor in anchor.quote==raw && sources.contains(where:{s in s.reference==anchor.source && s.observations.contains(where:{$0.id==anchor.observationID && $0.kind == .text && $0.value==raw})})})else{throw MemoryError.invalidEvidence}
  let date=EventDate(year:d.year,month:d.month,day:d.day,hour:h,minute:m,timeZoneID:zone,utcOffsetSeconds:d.utcOffsetSeconds,certainty:d.certainty,printedDateText:d.printedDateText,printedTimeText:raw)
  let appointment=AppointmentProjection(title:a.title,provider:a.provider,venue:a.venue,date:date,kind:a.kind,status:a.status,performer:a.performer,venueAddress:a.venueAddress)
  let support=p.support.map{$0.field == .date ? FieldSupport(field:.date,origin:$0.origin,anchors:$0.anchors,confidence:$0.confidence,extractorVersion:$0.extractorVersion+"/"+version):$0}
  return MemoryProjection(recordID:p.recordID,recordRevision:p.recordRevision,scope:p.scope,appointment:appointment,support:support,documentOnlyWithoutDate:p.documentOnlyWithoutDate ?? false)
 }
}
