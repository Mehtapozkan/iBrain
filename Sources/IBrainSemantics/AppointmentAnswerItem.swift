import Foundation
import IBrain

/// A source-backed answer object for native presentation. Protocol/debug state
/// remains available separately; the app need not render raw stored projections.
public struct AppointmentAnswerItem:Codable,Sendable {
    public let recordID:String
    public var fieldOrigins:[String:FactOrigin]? = nil
    public var dateCertainty:DateCertainty? = nil
    public var temporalDerivation:TemporalDerivation? = nil
    public var sourcePhotoContexts:[SourcePhotoContext]? = nil
    public let what:String
    public let performer:String?
    public let date:String
    public let startTime:String
    public let whereText:String?
    public let status:AppointmentStatus
    public let whyRelevant:String
    public let missingDetails:[String]
    public let predicateUnresolved:Bool
    public let originals:[SourceReference]
}
extension EvidenceQuestionAnswer {
    public var items:[AppointmentAnswerItem] {
        let unknown=Set(unresolved.map{$0.projection.recordID})
        return (matched+unresolved).map{row in
            let a=row.projection.appointment,d=a.date
            let date=d.year.flatMap{y in d.month.flatMap{m in d.day.map{String(format:"%04d-%02d-%02d",y,m,$0)}}} ?? d.printedDateText ?? "Date not supplied"
            let clock=d.hour.flatMap{h in d.minute.map{String(format:"%02d:%02d",h,$0)}} ?? d.printedTimeText ?? "Start time not supplied"
            let messages=["unknownTimeZone":"Timezone not supplied","missingYear":"Year unresolved","missingTime":"Start time unresolved","startClockUnresolved":"Start-clock filter unresolved","dateWindowUnresolved":"Date-window membership unresolved"]
            var missing=(unresolvedDetails[row.projection.recordID] ?? []).map{messages[$0] ?? $0}
            if d.year==nil,!missing.contains("Year unresolved"){missing.append("Year unresolved")}
            if d.hour==nil || d.minute==nil {if !missing.contains("Start time unresolved"){missing.append("Start time unresolved")}}
            if d.timeZoneID==nil,!missing.contains("Timezone not supplied"){missing.append("Timezone not supplied")}
            return AppointmentAnswerItem(recordID:row.projection.recordID,what:a.displayTitle,performer:a.performer,date:date,startTime:clock,whereText:a.displayVenue,status:a.status,whyRelevant:relevance,missingDetails:missing,predicateUnresolved:unknown.contains(row.projection.recordID),originals:row.projection.sources.sorted{$0.id<$1.id})
        }
    }
}

extension EvidenceQuestionAnswer {
    /// Complete presentation opt-in: keep field absence visible even when date
    /// membership is known. Legacy `items` remains unchanged.
    public var completeItems:[AppointmentAnswerItem] {
        let records=Dictionary(uniqueKeysWithValues:(matched+unresolved).map{($0.projection.recordID,$0.projection.appointment)})
        return items.map{item in
            guard let a=records[item.recordID]else{return item}
            var missing=item.missingDetails
            if usesTemporalContextPolicy && a.date.certainty == .inferred{missing.append("Date estimated from source context; not a verified printed date")}
            if usesTemporalContextPolicy && a.date.certainty == .conflicting{missing.append("Conflicting printed date/time readings")}
            if a.venue==nil {missing.append("Venue name not supplied")}
            if a.venueAddress==nil {missing.append("Street address not supplied")}
            if a.kind == .eventTicket,a.performer==nil {missing.append("Performer not supplied")}
            var result=AppointmentAnswerItem(recordID:item.recordID,what:item.what,performer:item.performer,date:item.date,startTime:item.startTime,whereText:item.whereText,status:item.status,whyRelevant:item.whyRelevant,missingDetails:Array(Set(missing)).sorted(),predicateUnresolved:item.predicateUnresolved,originals:item.originals)
            if usesTemporalContextPolicy{
                result.dateCertainty=a.date.certainty;result.temporalDerivation=a.date.temporalDerivation
                let photos=sourcePhotoContexts.filter{item.originals.contains($0.source)};result.sourcePhotoContexts=photos.isEmpty ? nil:photos
                if a.date.year==nil || a.date.month==nil || a.date.day==nil{
                    if let photo=photos.first(where:{$0.origin == .originalPhoto || $0.origin == .originalScreenshot}),let saved=photo.capturedAt{
                        let f=ISO8601DateFormatter();result=AppointmentAnswerItem(recordID:result.recordID,what:result.what,performer:result.performer,date:result.date,startTime:result.startTime,whereText:result.whereText,status:result.status,whyRelevant:result.whyRelevant,missingDetails:result.missingDetails+["Event date incomplete; original photo saved at "+f.string(from:saved)],predicateUnresolved:result.predicateUnresolved,originals:result.originals)
                        result.dateCertainty=a.date.certainty;result.temporalDerivation=a.date.temporalDerivation;result.sourcePhotoContexts=photos
                    }
                }
            }
            if let row=(matched+unresolved).first(where:{$0.projection.recordID==item.recordID}) {result.fieldOrigins=Dictionary(uniqueKeysWithValues:row.projection.support.map{($0.field.rawValue,$0.origin)})}
            return result
        }
    }
}
/// Useful presentation data alongside the existing ephemeral answer/context.
/// A discovery gap is not a missing appointment or permission to infer one.
public struct PhotographedAppointmentAnswer:Codable,Sendable {
    public let items:[AppointmentAnswerItem]
    public let changes:[RecordChangeExplanation]
    public let authorityGaps:[WorldAnswerItem]
    public let unresolvedSources:[SourceReference]
    public let clarification:String?
    public let evidenceScope:String
    public let personalCalendarComplete:Bool
    public init(answer:EvidenceQuestionAnswer,discovery:AppointmentSourceDiscoveryResult){
        items=answer.completeItems;changes=answer.changeExplanations;authorityGaps=answer.authorityGaps;unresolvedSources=discovery.gaps
        clarification=answer.clarification;evidenceScope=answer.evidenceScope;personalCalendarComplete=false
    }
}
