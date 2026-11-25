import Foundation

/// Captured by this native store while the old domain revision is current.
/// Neither a model nor the caller can construct a prior-revision token.
public struct CapturedRecordRevision:Sendable {
    internal let session:UUID
    internal let row:StoredMemory
}
public struct SupportedFieldChange:Codable,Equatable,Sendable {
    public let field:AppointmentField
    public let previousValue:String?
    public let currentValue:String?
    public let previousEvidence:[EvidenceAnchor]
    public let currentEvidence:[EvidenceAnchor]
    /// Optional for decoding older explanation DTOs. Missing metadata means
    /// unknown provenance, never an implicit observed/photo claim.
    public let previousSupport:FieldSupport?
    public let currentSupport:FieldSupport?
}
/// Derived comparison of host-admitted revisions of the same domain record.
/// Both sets of source quotes must remain accessible; this grants no merge,
/// ownership or real-world calendar authority.
public struct SourceRecordChange:Codable,Equatable,Sendable {
    public let previous:MemoryProjection
    public let current:MemoryProjection
    internal init(previous:MemoryProjection,current:MemoryProjection){self.previous=previous;self.current=current}
    public var recordID:String {current.recordID}
    public var sources:Set<SourceReference>{previous.sources.union(current.sources)}
    public var fields:[SupportedFieldChange] {
        func value(_ a:AppointmentProjection,_ field:AppointmentField)->String? {
            switch field {
            case .title:return a.title
            case .performer:return a.performer
            case .venue:return a.venue
            case .venueAddress:return a.venueAddress
            case .provider:return a.provider
            case .kind:return a.kind.rawValue
            case .status:return a.status.rawValue
            case .date:
                let d=a.date
                // Ignore purely typographic date changes when exact civil
                // components exist; retain unparsed printed meaning otherwise.
                var values:[String:String]=["certainty":d.certainty.rawValue]
                for(k,v)in [("year",d.year),("month",d.month),("day",d.day),("hour",d.hour),("minute",d.minute),("utcOffsetSeconds",d.utcOffsetSeconds)]{if let v{values[k]=String(v)}}
                values["timeZoneID"]=d.timeZoneID
                if d.year==nil || d.month==nil || d.day==nil {values["printedDate"]=d.printedDateText}
                if d.hour==nil || d.minute==nil {values["printedTime"]=d.printedTimeText}
                let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
                return String(decoding:try! e.encode(values),as:UTF8.self)
            }
        }
        func normalized(_ value:String?)->String?{value.map{$0.lowercased().split(whereSeparator:\.isWhitespace).joined(separator:" ")}}
        return AppointmentField.allCases.compactMap {field in
            let before=value(previous.appointment,field),after=value(current.appointment,field)
            let oldSupport=previous.support.first{$0.field==field},newSupport=current.support.first{$0.field==field}
            guard normalized(before) != normalized(after) || oldSupport?.origin != newSupport?.origin else{return nil}
            return SupportedFieldChange(field:field,previousValue:before,currentValue:after,
                previousEvidence:oldSupport?.anchors ?? [],currentEvidence:newSupport?.anchors ?? [],
                previousSupport:oldSupport,currentSupport:newSupport)
        }
    }
}

public struct RecordChangeExplanation:Codable,Equatable,Sendable {
    public let recordID:String
    public let title:String
    public let fields:[SupportedFieldChange]
    public let previousSources:Set<SourceReference>
    public let currentSources:Set<SourceReference>
    public let text:String
}
extension SourceRecordChange {
    public func explanation(fields requested:Set<AppointmentField>?=nil)->RecordChangeExplanation {
        let selected=fields.filter{requested?.contains($0.field) ?? true}
        let names:[AppointmentField:String]=[.title:"Event",.performer:"Performer",.venue:"Venue",.venueAddress:"Address",.provider:"Provider",.status:"Status",.kind:"Type",.date:"Date/time"]
        func civil(_ d:EventDate)->String {
            let date=d.year.flatMap{y in d.month.flatMap{m in d.day.map{String(format:"%04d-%02d-%02d",y,m,$0)}}} ?? d.printedDateText ?? "date not supplied"
            let time=d.hour.flatMap{h in d.minute.map{String(format:"%02d:%02d",h,$0)}} ?? d.printedTimeText ?? "time not supplied"
            var zones:[String]=[]
            if let id=d.timeZoneID{zones.append(id)}
            if let offset=d.utcOffsetSeconds {
                let magnitude=offset.magnitude,hours=Int(magnitude/3600),minutes=Int((magnitude%3600)/60),seconds=Int(magnitude%60)
                let suffix=seconds==0 ? String(format:"%02ld:%02ld",hours,minutes):String(format:"%02ld:%02ld:%02ld",hours,minutes,seconds)
                zones.append("UTC"+(offset<0 ? "-":"+")+suffix)
            }
            let certainty=d.certainty == .explicit ? "":d.certainty == .inferred ? "; includes inferred date/time":"; conflicting date/time evidence"
            return date+" at "+time+" ("+(zones.isEmpty ? "timezone not supplied":zones.joined(separator:"; "))+certainty+")"
        }
        func qualified(_ value:String,support:FieldSupport?,hasValue:Bool)->String {
            guard hasValue else{return value}
            switch support?.origin {
            case .observed:return value
            case .domainCorrection:return value+" [owner correction]"
            case .inferred:return value+" [inferred]"
            case nil:return value+" [support origin not retained]"
            }
        }
        let lines=selected.map {field in
            let before=field.field == .date ? civil(previous.appointment.date):field.previousValue ?? "not supplied"
            let after=field.field == .date ? civil(current.appointment.date):field.currentValue ?? "not supplied"
            return (names[field.field] ?? field.field.rawValue)+": "+qualified(before,support:field.previousSupport,hasValue:field.previousValue != nil)+" → "+qualified(after,support:field.currentSupport,hasValue:field.currentValue != nil)
        }
        let onlyObserved=selected.allSatisfy {field in
            (field.previousValue==nil || field.previousSupport?.origin == .observed) &&
            (field.currentValue==nil || field.currentSupport?.origin == .observed) &&
            (field.field != .date || (previous.appointment.date.certainty == .explicit && current.appointment.date.certainty == .explicit))
        }
        let prefix=onlyObserved ? "According to the retained photos: ":"According to the retained evidence: "
        let text=lines.isEmpty ? "The retained source revisions show the same requested supported fields.":prefix+lines.joined(separator:"; ")
        return RecordChangeExplanation(recordID:recordID,title:current.appointment.displayTitle,fields:selected,previousSources:previous.sources,currentSources:current.sources,text:text)
    }
}
